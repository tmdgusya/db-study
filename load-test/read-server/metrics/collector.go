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
	QPS             float64       `json:"qps"`
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
	maxLatencies    int
}

func NewCollector() *Collector {
	return &Collector{
		latencies:    make([]time.Duration, 0, 100000),
		startTime:    time.Now(),
		maxLatencies: 100000,
	}
}

func (c *Collector) RecordSuccess(latency time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.totalRequests++
	c.successRequests++

	if len(c.latencies) < c.maxLatencies {
		c.latencies = append(c.latencies, latency)
	}
}

func (c *Collector) RecordFailure() {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.totalRequests++
	c.failedRequests++
}

func (c *Collector) GetMetrics() Metrics {
	c.mu.RLock()
	defer c.mu.RUnlock()

	elapsed := time.Since(c.startTime).Seconds()
	qps := 0.0
	if elapsed > 0 {
		qps = float64(c.totalRequests) / elapsed
	}

	avgLatency := 0.0
	p50Latency := 0.0
	p95Latency := 0.0
	p99Latency := 0.0

	if len(c.latencies) > 0 {
		var sum time.Duration
		for _, lat := range c.latencies {
			sum += lat
		}
		avgLatency = float64(sum.Milliseconds()) / float64(len(c.latencies))

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
		QPS:             qps,
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
