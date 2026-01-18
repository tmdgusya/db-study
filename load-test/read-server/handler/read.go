package handler

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"read-server/metrics"
	"strconv"
	"time"
)

type ReadHandler struct {
	db        *sql.DB
	collector *metrics.Collector
}

func NewReadHandler(db *sql.DB, collector *metrics.Collector) *ReadHandler {
	return &ReadHandler{
		db:        db,
		collector: collector,
	}
}

type LogEntry struct {
	ID        int64     `json:"id"`
	Timestamp time.Time `json:"timestamp"`
	Level     string    `json:"level"`
	Service   string    `json:"service"`
	Message   string    `json:"message"`
	Metadata  string    `json:"metadata,omitempty"`
}

type StatsEntry struct {
	Level     string    `json:"level"`
	Count     int64     `json:"count"`
	FirstSeen time.Time `json:"first_seen"`
	LastSeen  time.Time `json:"last_seen"`
}

// GET /logs - 로그 조회 (페이징)
func (h *ReadHandler) GetLogs(w http.ResponseWriter, r *http.Request) {
	limitStr := r.URL.Query().Get("limit")
	limit := 100
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	query := `
		SELECT id, timestamp, level, service, message
		FROM logs
		ORDER BY timestamp DESC
		LIMIT $1
	`

	start := time.Now()
	rows, err := h.db.Query(query, limit)
	if err != nil {
		h.collector.RecordFailure()
		http.Error(w, fmt.Sprintf("Failed to query logs: %v", err), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	logs := make([]LogEntry, 0, limit)
	for rows.Next() {
		var log LogEntry
		if err := rows.Scan(&log.ID, &log.Timestamp, &log.Level, &log.Service, &log.Message); err != nil {
			h.collector.RecordFailure()
			http.Error(w, fmt.Sprintf("Failed to scan row: %v", err), http.StatusInternalServerError)
			return
		}
		logs = append(logs, log)
	}

	if err := rows.Err(); err != nil {
		h.collector.RecordFailure()
		http.Error(w, fmt.Sprintf("Row iteration error: %v", err), http.StatusInternalServerError)
		return
	}

	latency := time.Since(start)
	h.collector.RecordSuccess(latency)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"logs":  logs,
		"count": len(logs),
	})
}

// GET /logs/search - 로그 검색 (필터)
func (h *ReadHandler) SearchLogs(w http.ResponseWriter, r *http.Request) {
	level := r.URL.Query().Get("level")
	service := r.URL.Query().Get("service")
	limitStr := r.URL.Query().Get("limit")

	limit := 100
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	query := `
		SELECT id, timestamp, level, service, message
		FROM logs
		WHERE 1=1
	`
	args := []interface{}{}
	argCount := 1

	if level != "" {
		query += fmt.Sprintf(" AND level = $%d", argCount)
		args = append(args, level)
		argCount++
	}

	if service != "" {
		query += fmt.Sprintf(" AND service = $%d", argCount)
		args = append(args, service)
		argCount++
	}

	query += fmt.Sprintf(" AND timestamp > NOW() - INTERVAL '1 hour' ORDER BY timestamp DESC LIMIT $%d", argCount)
	args = append(args, limit)

	start := time.Now()
	rows, err := h.db.Query(query, args...)
	if err != nil {
		h.collector.RecordFailure()
		http.Error(w, fmt.Sprintf("Failed to search logs: %v", err), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	logs := make([]LogEntry, 0, limit)
	for rows.Next() {
		var log LogEntry
		if err := rows.Scan(&log.ID, &log.Timestamp, &log.Level, &log.Service, &log.Message); err != nil {
			h.collector.RecordFailure()
			http.Error(w, fmt.Sprintf("Failed to scan row: %v", err), http.StatusInternalServerError)
			return
		}
		logs = append(logs, log)
	}

	if err := rows.Err(); err != nil {
		h.collector.RecordFailure()
		http.Error(w, fmt.Sprintf("Row iteration error: %v", err), http.StatusInternalServerError)
		return
	}

	latency := time.Since(start)
	h.collector.RecordSuccess(latency)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"logs":  logs,
		"count": len(logs),
	})
}

// GET /logs/stats - 로그 통계 (집계)
func (h *ReadHandler) GetStats(w http.ResponseWriter, r *http.Request) {
	query := `
		SELECT
			level,
			COUNT(*) as count,
			MIN(timestamp) as first_seen,
			MAX(timestamp) as last_seen
		FROM logs
		WHERE timestamp > NOW() - INTERVAL '1 hour'
		GROUP BY level
		ORDER BY count DESC
	`

	start := time.Now()
	rows, err := h.db.Query(query)
	if err != nil {
		h.collector.RecordFailure()
		http.Error(w, fmt.Sprintf("Failed to get stats: %v", err), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	stats := make([]StatsEntry, 0)
	for rows.Next() {
		var stat StatsEntry
		if err := rows.Scan(&stat.Level, &stat.Count, &stat.FirstSeen, &stat.LastSeen); err != nil {
			h.collector.RecordFailure()
			http.Error(w, fmt.Sprintf("Failed to scan row: %v", err), http.StatusInternalServerError)
			return
		}
		stats = append(stats, stat)
	}

	if err := rows.Err(); err != nil {
		h.collector.RecordFailure()
		http.Error(w, fmt.Sprintf("Row iteration error: %v", err), http.StatusInternalServerError)
		return
	}

	latency := time.Since(start)
	h.collector.RecordSuccess(latency)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"stats": stats,
	})
}
