package handler

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
	"write-server/metrics"
)

type WriteHandler struct {
	db        *sql.DB
	collector *metrics.Collector
}

func NewWriteHandler(db *sql.DB, collector *metrics.Collector) *WriteHandler {
	return &WriteHandler{
		db:        db,
		collector: collector,
	}
}

type LogEntry struct {
	Level    string `json:"level"`
	Service  string `json:"service"`
	Message  string `json:"message"`
	Metadata string `json:"metadata"`
}

type BatchLogRequest struct {
	Logs []LogEntry `json:"logs"`
}

// POST /logs - 단일 로그 INSERT
func (h *WriteHandler) InsertLog(w http.ResponseWriter, r *http.Request) {
	var log LogEntry
	if err := json.NewDecoder(r.Body).Decode(&log); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	start := time.Now()
	_, err := h.db.Exec(
		"INSERT INTO logs (level, service, message, metadata) VALUES ($1, $2, $3, $4)",
		log.Level,
		log.Service,
		log.Message,
		log.Metadata,
	)
	latency := time.Since(start)

	if err != nil {
		h.collector.RecordFailure(1)
		http.Error(w, fmt.Sprintf("Failed to insert log: %v", err), http.StatusInternalServerError)
		return
	}

	h.collector.RecordSuccess(latency, 1)

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{
		"status": "success",
	})
}

// POST /logs/batch - 배치 로그 INSERT
func (h *WriteHandler) InsertBatchLogs(w http.ResponseWriter, r *http.Request) {
	var req BatchLogRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	if len(req.Logs) == 0 {
		http.Error(w, "Empty logs array", http.StatusBadRequest)
		return
	}

	start := time.Now()

	tx, err := h.db.Begin()
	if err != nil {
		h.collector.RecordFailure(len(req.Logs))
		http.Error(w, fmt.Sprintf("Failed to begin transaction: %v", err), http.StatusInternalServerError)
		return
	}
	defer tx.Rollback()

	// 배치 INSERT 쿼리 생성
	query := "INSERT INTO logs (level, service, message, metadata) VALUES "
	args := make([]interface{}, 0, len(req.Logs)*4)

	for i, log := range req.Logs {
		if i > 0 {
			query += ", "
		}
		offset := i * 4
		query += fmt.Sprintf("($%d, $%d, $%d, $%d)", offset+1, offset+2, offset+3, offset+4)

		args = append(args, log.Level, log.Service, log.Message, log.Metadata)
	}

	_, err = tx.Exec(query, args...)
	if err != nil {
		h.collector.RecordFailure(len(req.Logs))
		http.Error(w, fmt.Sprintf("Failed to insert logs: %v", err), http.StatusInternalServerError)
		return
	}

	if err := tx.Commit(); err != nil {
		h.collector.RecordFailure(len(req.Logs))
		http.Error(w, fmt.Sprintf("Failed to commit transaction: %v", err), http.StatusInternalServerError)
		return
	}

	latency := time.Since(start)
	h.collector.RecordSuccess(latency, len(req.Logs))

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":   "success",
		"inserted": len(req.Logs),
	})
}
