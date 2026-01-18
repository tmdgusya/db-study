package load

import (
	"time"
)

type Config struct {
	TPS            int           `json:"tps"`             // 목표 TPS (0 = 무제한)
	BatchSize      int           `json:"batch_size"`      // 배치 INSERT 크기 (1 = 단일)
	Workers        int           `json:"workers"`         // 동시 워커 수
	Duration       time.Duration `json:"duration"`        // 테스트 지속 시간 (0 = 무제한)
	IsolationLevel string        `json:"isolation_level"` // READ COMMITTED, REPEATABLE READ, SERIALIZABLE
}

func DefaultConfig() *Config {
	return &Config{
		TPS:            1000,
		BatchSize:      10,
		Workers:        5,
		Duration:       0, // 무제한
		IsolationLevel: "READ COMMITTED",
	}
}

func (c *Config) Validate() error {
	if c.TPS < 0 {
		c.TPS = 0 // 무제한
	}
	if c.BatchSize < 1 {
		c.BatchSize = 1
	}
	if c.Workers < 1 {
		c.Workers = 1
	}
	if c.Duration < 0 {
		c.Duration = 0
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
