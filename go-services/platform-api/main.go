package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type HealthResponse struct {
	Status    string    `json:"status"`
	Timestamp time.Time `json:"timestamp"`
	Version   string    `json:"version"`
	Host      string    `json:"host"`
}

type InfoResponse struct {
	Service     string `json:"service"`
	Description string `json:"description"`
	Version     string `json:"version"`
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", healthzHandler)
	mux.HandleFunc("/readyz", readyzHandler)
	mux.HandleFunc("/info", infoHandler)
	mux.Handle("/metrics", promhttp.Handler())
	mux.HandleFunc("/", rootHandler)

	addr := fmt.Sprintf(":%s", port)
	log.Printf("platform-api starting on %s", addr)

	server := &http.Server{
		Addr:         addr,
		Handler:      instrumentingMiddleware(loggingMiddleware(mux)),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func healthzHandler(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	resp := HealthResponse{
		Status:    "ok",
		Timestamp: time.Now().UTC(),
		Version:   "0.1.0",
		Host:      hostname,
	}
	writeJSON(w, http.StatusOK, resp)
}

func readyzHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func infoHandler(w http.ResponseWriter, r *http.Request) {
	resp := InfoResponse{
		Service:     "platform-api",
		Description: "Internal platform API — running on local kind cluster",
		Version:     "0.1.0",
	}
	writeJSON(w, http.StatusOK, resp)
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"message": "platform-api is running",
		"docs":    "/info",
		"health":  "/healthz",
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("error encoding response: %v", err)
	}
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}
