package metrics

import (
	"sort"
	"sync"
	"time"
)

type Metrics struct {
	TotalRequests   int64         `json:"total_requests"`
	SuccessRequests int64         `json:"success_requests"`
	FailedRequests  int64         `json:"failed_requests"`
	TPS             float64       `json:"tps"`
	AvgLatency      float64       `json:"avg_latency_ms"`
	P50Latency      float64       `json:"p50_latency_ms"`
	P95Latency      float64       `json:"p95_latency_ms"`
	P99Latency      float64       `json:"p99_latency_ms"`
	StartTime       time.Time     `json:"start_time"`
	Elapsed         float64       `json:"elapsed_seconds"`
}

type Collector struct {
	mu              sync.RWMutex
	totalRequests   int64
	successRequests int64
	failedRequests  int64
	latencies       []time.Duration
	startTime       time.Time
	maxLatencies    int // 메모리 제한을 위해 최대 저장 개수 설정
}

func NewCollector() *Collector {
	return &Collector{
		latencies:    make([]time.Duration, 0, 100000),
		startTime:    time.Now(),
		maxLatencies: 100000, // 최대 10만개 지연시간 저장
	}
}

func (c *Collector) RecordSuccess(latency time.Duration, count int) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.totalRequests += int64(count)
	c.successRequests += int64(count)

	// 지연시간 저장 (메모리 제한 고려)
	if len(c.latencies) < c.maxLatencies {
		c.latencies = append(c.latencies, latency)
	}
}

func (c *Collector) RecordFailure(count int) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.totalRequests += int64(count)
	c.failedRequests += int64(count)
}

func (c *Collector) GetMetrics() Metrics {
	c.mu.RLock()
	defer c.mu.RUnlock()

	elapsed := time.Since(c.startTime).Seconds()
	tps := 0.0
	if elapsed > 0 {
		tps = float64(c.totalRequests) / elapsed
	}

	// 지연시간 계산
	avgLatency := 0.0
	p50Latency := 0.0
	p95Latency := 0.0
	p99Latency := 0.0

	if len(c.latencies) > 0 {
		// 평균 계산
		var sum time.Duration
		for _, lat := range c.latencies {
			sum += lat
		}
		avgLatency = float64(sum.Milliseconds()) / float64(len(c.latencies))

		// 백분위수 계산을 위해 정렬 (복사본 사용)
		sortedLatencies := make([]time.Duration, len(c.latencies))
		copy(sortedLatencies, c.latencies)
		sort.Slice(sortedLatencies, func(i, j int) bool {
			return sortedLatencies[i] < sortedLatencies[j]
		})

		p50Latency = float64(sortedLatencies[len(sortedLatencies)*50/100].Milliseconds())
		p95Latency = float64(sortedLatencies[len(sortedLatencies)*95/100].Milliseconds())
		p99Latency = float64(sortedLatencies[len(sortedLatencies)*99/100].Milliseconds())
	}

	return Metrics{
		TotalRequests:   c.totalRequests,
		SuccessRequests: c.successRequests,
		FailedRequests:  c.failedRequests,
		TPS:             tps,
		AvgLatency:      avgLatency,
		P50Latency:      p50Latency,
		P95Latency:      p95Latency,
		P99Latency:      p99Latency,
		StartTime:       c.startTime,
		Elapsed:         elapsed,
	}
}

func (c *Collector) Reset() {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.totalRequests = 0
	c.successRequests = 0
	c.failedRequests = 0
	c.latencies = make([]time.Duration, 0, 100000)
	c.startTime = time.Now()
}
