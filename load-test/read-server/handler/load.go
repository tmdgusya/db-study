package handler

import (
	"encoding/json"
	"net/http"
	"read-server/load"
	"read-server/metrics"
)

type LoadHandler struct {
	generator *load.Generator
	collector *metrics.Collector
}

func NewLoadHandler(generator *load.Generator, collector *metrics.Collector) *LoadHandler {
	return &LoadHandler{
		generator: generator,
		collector: collector,
	}
}

// POST /load/start - 부하 생성 시작
func (h *LoadHandler) Start(w http.ResponseWriter, r *http.Request) {
	if h.generator.IsRunning() {
		http.Error(w, "Load generator is already running", http.StatusBadRequest)
		return
	}

	if err := h.generator.Start(); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "started",
		"message": "Load generation started successfully",
	})
}

// POST /load/stop - 부하 생성 중지
func (h *LoadHandler) Stop(w http.ResponseWriter, r *http.Request) {
	if !h.generator.IsRunning() {
		http.Error(w, "Load generator is not running", http.StatusBadRequest)
		return
	}

	h.generator.Stop()

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "stopped",
		"message": "Load generation stopped successfully",
	})
}

// GET /load/config - 현재 부하 설정 조회
func (h *LoadHandler) GetConfig(w http.ResponseWriter, r *http.Request) {
	config := h.generator.GetConfig()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"config":  config,
		"running": h.generator.IsRunning(),
	})
}

// POST /load/config - 부하 설정 변경
func (h *LoadHandler) UpdateConfig(w http.ResponseWriter, r *http.Request) {
	if h.generator.IsRunning() {
		http.Error(w, "Cannot update config while generator is running. Stop it first.", http.StatusBadRequest)
		return
	}

	var config load.Config
	if err := json.NewDecoder(r.Body).Decode(&config); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	if err := config.Validate(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if err := h.generator.UpdateConfig(&config); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "updated",
		"config": config,
	})
}

// GET /load/status - 부하 생성 상태 조회
func (h *LoadHandler) GetStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"running": h.generator.IsRunning(),
		"config":  h.generator.GetConfig(),
		"metrics": h.collector.GetMetrics(),
	})
}

// GET /metrics - 메트릭 조회
func (h *LoadHandler) GetMetrics(w http.ResponseWriter, r *http.Request) {
	metrics := h.collector.GetMetrics()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(metrics)
}

// POST /metrics/reset - 메트릭 초기화
func (h *LoadHandler) ResetMetrics(w http.ResponseWriter, r *http.Request) {
	if h.generator.IsRunning() {
		http.Error(w, "Cannot reset metrics while generator is running", http.StatusBadRequest)
		return
	}

	h.collector.Reset()

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "reset",
		"message": "Metrics reset successfully",
	})
}
