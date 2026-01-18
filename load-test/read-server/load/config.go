package load

import (
	"fmt"
	"time"
)

type QueryMix struct {
	Simple    int `json:"simple"`    // 단순 조회 (%)
	Filter    int `json:"filter"`    // 필터 조회 (%)
	Aggregate int `json:"aggregate"` // 집계 쿼리 (%)
}

type Config struct {
	QPS            int           `json:"qps"`             // 목표 QPS (0 = 무제한)
	Workers        int           `json:"workers"`         // 동시 워커 수
	Duration       time.Duration `json:"duration"`        // 테스트 지속 시간 (0 = 무제한)
	QueryMix       QueryMix      `json:"query_mix"`       // 쿼리 타입 비율
	IsolationLevel string        `json:"isolation_level"` // READ COMMITTED, REPEATABLE READ, SERIALIZABLE
}

func DefaultConfig() *Config {
	return &Config{
		QPS:     1000,
		Workers: 10,
		Duration: 0,
		QueryMix: QueryMix{
			Simple:    60, // 60%
			Filter:    30, // 30%
			Aggregate: 10, // 10%
		},
		IsolationLevel: "READ COMMITTED",
	}
}

func (c *Config) Validate() error {
	if c.QPS < 0 {
		c.QPS = 0
	}
	if c.Workers < 1 {
		c.Workers = 1
	}
	if c.Duration < 0 {
		c.Duration = 0
	}

	// QueryMix 정규화
	total := c.QueryMix.Simple + c.QueryMix.Filter + c.QueryMix.Aggregate
	if total != 100 {
		return fmt.Errorf("query_mix percentages must sum to 100, got %d", total)
	}

	if c.QueryMix.Simple < 0 || c.QueryMix.Filter < 0 || c.QueryMix.Aggregate < 0 {
		return fmt.Errorf("query_mix percentages must be non-negative")
	}

	// 격리 수준 정규화
	switch c.IsolationLevel {
	case "READ COMMITTED", "REPEATABLE READ", "SERIALIZABLE":
		// 유효한 값
	default:
		c.IsolationLevel = "READ COMMITTED"
	}

	return nil
}
