package main

import (
	"net/http"
	"time"

	"github.com/google/uuid"
)

type kafkaEvent struct {
	EventID    string `json:"event_id"`
	EventType  string `json:"event_type"`
	Timestamp  string `json:"timestamp"`
	Source     string `json:"source"`
	Method     string `json:"method"`
	Path       string `json:"path"`
	Status     int    `json:"status"`
	LatencyMs  int64  `json:"latency_ms"`
	RemoteAddr string `json:"remote_addr"`
	UserAgent  string `json:"user_agent"`
}

func kafkaMiddleware(pub *kafkaPublisher, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		if !pub.enabled {
			return
		}
		if r.URL.Path == "/metrics" || r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			return
		}
		evt := kafkaEvent{
			EventID:    uuid.NewString(),
			EventType:  "http_request",
			Timestamp:  time.Now().UTC().Format(time.RFC3339Nano),
			Source:     "platform-api",
			Method:     r.Method,
			Path:       r.URL.Path,
			Status:     rec.status,
			LatencyMs:  time.Since(start).Milliseconds(),
			RemoteAddr: r.RemoteAddr,
			UserAgent:  r.UserAgent(),
		}
		pub.publish(evt.EventID, evt)
	})
}
