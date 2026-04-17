package main

// supervisor-http: HTTP sidecar for the CDI supervisor.
//
// Runs alongside supervisor.sh as a systemd service on each cluster instance.
// Listens on CONTAINER_PORT and:
//   - GET /health/local  — per-instance health (used by the GCP LB health check)
//   - GET /health        — cluster-wide health (200 if ≥1 instance healthy)
//   - GET /metadata      — full cluster state aggregated from Redis
//   - everything else    — reverse-proxied to the app container on APP_PORT
//
// Each instance publishes its own InstanceState to Redis every 10 s (TTL 30 s).
// Any instance can answer cluster-wide queries by scanning those keys.
//
// Environment (from /etc/supervisor/env via systemd EnvironmentFile):
//   CONTAINER_NAME, CLUSTER_NAME, INSTANCE_ID
//   CONTAINER_PORT, APP_PORT
//   REDIS_HOST, REDIS_PORT, REDIS_PREFIX  (empty → no cluster aggregation)

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

// InstanceState is published to Redis by each supervisor instance.
type InstanceState struct {
	InstanceID         string    `json:"instance_id"`
	ContainerRunning   bool      `json:"container_running"`
	MainProcessRunning bool      `json:"main_process_running"`
	ContainerCommit    string    `json:"container_commit,omitempty"`
	Building           bool      `json:"building"`
	BuildCommit        string    `json:"build_commit,omitempty"`
	LastSeen           time.Time `json:"last_seen"`
}

type clusterMetadata struct {
	Cluster        string          `json:"cluster"`
	ClusterHealthy bool            `json:"cluster_healthy"`
	Instances      []InstanceState `json:"instances"`
}

var (
	mu            sync.RWMutex
	localState    InstanceState
	containerName string
	clusterName   string
	redisPrefix   string
	rdb           *redis.Client
)

func main() {
	containerName  = mustEnv("CONTAINER_NAME")
	clusterName    = mustEnv("CLUSTER_NAME")
	instanceID    := mustEnv("INSTANCE_ID")
	containerPort := mustEnv("CONTAINER_PORT")
	appPort       := mustEnv("APP_PORT")

	redisHost    := os.Getenv("REDIS_HOST")
	redisPortStr := os.Getenv("REDIS_PORT")
	redisPrefix   = os.Getenv("REDIS_PREFIX")

	if redisHost != "" {
		redisPortNum, _ := strconv.Atoi(redisPortStr)
		if redisPortNum == 0 {
			redisPortNum = 6379
		}
		rdb = redis.NewClient(&redis.Options{
			Addr:         fmt.Sprintf("%s:%d", redisHost, redisPortNum),
			DialTimeout:  5 * time.Second,
			ReadTimeout:  3 * time.Second,
			WriteTimeout: 3 * time.Second,
		})
	}

	localState = InstanceState{InstanceID: instanceID}

	// Ensure the shared state directory exists (supervisor.sh writes build-state here).
	if err := os.MkdirAll("/run/supervisor", 0755); err != nil {
		log.Printf("[supervisor-http] warning: mkdir /run/supervisor: %v", err)
	}

	go pollContainerState()
	go publishToRedis()

	appURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%s", appPort))
	proxy := httputil.NewSingleHostReverseProxy(appURL)

	mux := http.NewServeMux()
	mux.HandleFunc("/health/local", handleHealthLocal)
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/metadata", handleMetadata)
	mux.Handle("/", proxy)

	addr := fmt.Sprintf("0.0.0.0:%s", containerPort)
	log.Printf("[supervisor-http] listening on :%s, proxying app on :%s", containerPort, appPort)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("[supervisor-http] required env var %s is not set", key)
	}
	return v
}

// ── State polling ──────────────────────────────────────────────────────────────

func pollContainerState() {
	for {
		updateLocalState()
		time.Sleep(5 * time.Second)
	}
}

type dockerInspectResult struct {
	State struct {
		Running bool `json:"Running"`
		Pid     int  `json:"Pid"`
	} `json:"State"`
	Config struct {
		Labels map[string]string `json:"Labels"`
	} `json:"Config"`
}

func updateLocalState() {
	out, err := exec.Command("docker", "inspect", containerName).Output()

	mu.Lock()
	defer mu.Unlock()

	localState.LastSeen = time.Now()
	localState.Building, localState.BuildCommit = readBuildState()

	if err != nil {
		localState.ContainerRunning = false
		localState.MainProcessRunning = false
		localState.ContainerCommit = ""
		return
	}

	var results []dockerInspectResult
	if jsonErr := json.Unmarshal(out, &results); jsonErr != nil || len(results) == 0 {
		localState.ContainerRunning = false
		localState.MainProcessRunning = false
		return
	}

	r := results[0]
	localState.ContainerRunning = r.State.Running
	localState.ContainerCommit = r.Config.Labels["git-commit"]

	// Independently verify PID 1 of the container is alive in the host process table.
	// This is distinct from Docker's Running flag and catches zombie/stuck PID 1 cases.
	if r.State.Running && r.State.Pid > 0 {
		_, statErr := os.Stat(fmt.Sprintf("/proc/%d", r.State.Pid))
		localState.MainProcessRunning = statErr == nil
	} else {
		localState.MainProcessRunning = false
	}
}

// readBuildState parses /run/supervisor/build-state written by supervisor.sh.
// File contains either "BUILDING <commit>" or "IDLE".
func readBuildState() (building bool, buildCommit string) {
	data, err := os.ReadFile("/run/supervisor/build-state")
	if err != nil {
		return false, ""
	}
	parts := strings.SplitN(strings.TrimSpace(string(data)), " ", 2)
	if len(parts) >= 1 && parts[0] == "BUILDING" {
		commit := ""
		if len(parts) == 2 {
			commit = strings.TrimSpace(parts[1])
		}
		return true, commit
	}
	return false, ""
}

// ── Redis heartbeat ────────────────────────────────────────────────────────────

func publishToRedis() {
	if rdb == nil {
		return
	}
	for {
		publishState()
		time.Sleep(10 * time.Second)
	}
}

func publishState() {
	mu.RLock()
	state := localState
	mu.RUnlock()

	data, err := json.Marshal(state)
	if err != nil {
		return
	}

	key := fmt.Sprintf("%s_supervisor:%s", redisPrefix, state.InstanceID)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Set(ctx, key, data, 30*time.Second).Err(); err != nil {
		log.Printf("[supervisor-http] redis publish failed: %v", err)
	}
}

// getClusterStates reads all supervisor state keys from Redis.
// Falls back to local state only if Redis is unavailable or returns nothing.
func getClusterStates() []InstanceState {
	if rdb == nil {
		mu.RLock()
		state := localState
		mu.RUnlock()
		return []InstanceState{state}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	pattern := fmt.Sprintf("%s_supervisor:*", redisPrefix)
	var keys []string
	var cursor uint64
	for {
		batch, next, err := rdb.Scan(ctx, cursor, pattern, 100).Result()
		if err != nil {
			break
		}
		keys = append(keys, batch...)
		cursor = next
		if cursor == 0 {
			break
		}
	}

	if len(keys) == 0 {
		mu.RLock()
		state := localState
		mu.RUnlock()
		return []InstanceState{state}
	}

	vals, err := rdb.MGet(ctx, keys...).Result()
	if err != nil {
		mu.RLock()
		state := localState
		mu.RUnlock()
		return []InstanceState{state}
	}

	var states []InstanceState
	for _, v := range vals {
		if v == nil {
			continue
		}
		var s InstanceState
		if jsonErr := json.Unmarshal([]byte(v.(string)), &s); jsonErr == nil {
			states = append(states, s)
		}
	}

	if len(states) == 0 {
		mu.RLock()
		state := localState
		mu.RUnlock()
		return []InstanceState{state}
	}
	return states
}

func isHealthy(s InstanceState) bool {
	return s.ContainerRunning && s.MainProcessRunning
}

// ── HTTP handlers ──────────────────────────────────────────────────────────────

// handleHealthLocal is the per-instance health endpoint used by the GCP LB health check.
// Returns 200 only when THIS instance's container is running with a live PID 1.
func handleHealthLocal(w http.ResponseWriter, _ *http.Request) {
	mu.RLock()
	state := localState
	mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	ok := isHealthy(state)
	if ok {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	json.NewEncoder(w).Encode(map[string]any{ //nolint:errcheck
		"ok":          ok,
		"instance_id": state.InstanceID,
	})
}

// handleHealth is the cluster-level health endpoint.
// Returns 200 as long as at least one instance in the cluster is healthy.
func handleHealth(w http.ResponseWriter, _ *http.Request) {
	states := getClusterStates()
	healthy := 0
	for _, s := range states {
		if isHealthy(s) {
			healthy++
		}
	}

	w.Header().Set("Content-Type", "application/json")
	ok := healthy > 0
	if ok {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	json.NewEncoder(w).Encode(map[string]any{ //nolint:errcheck
		"ok":                ok,
		"instances_healthy": healthy,
		"instances_total":   len(states),
	})
}

// handleMetadata returns the full cluster state aggregated from Redis.
func handleMetadata(w http.ResponseWriter, _ *http.Request) {
	states := getClusterStates()
	clusterHealthy := false
	for _, s := range states {
		if isHealthy(s) {
			clusterHealthy = true
			break
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(clusterMetadata{ //nolint:errcheck
		Cluster:        clusterName,
		ClusterHealthy: clusterHealthy,
		Instances:      states,
	})
}
