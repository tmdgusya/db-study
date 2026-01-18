package load

import (
	"database/sql"
	"fmt"
	"math/rand"
	"sync"
	"sync/atomic"
	"time"
	"write-server/metrics"
)

type Generator struct {
	db        *sql.DB
	config    *Config
	collector *metrics.Collector
	running   atomic.Bool
	wg        sync.WaitGroup
	stopCh    chan struct{}
}

func NewGenerator(db *sql.DB, config *Config, collector *metrics.Collector) *Generator {
	return &Generator{
		db:        db,
		config:    config,
		collector: collector,
		stopCh:    make(chan struct{}),
	}
}

func (g *Generator) Start() error {
	if g.running.Load() {
		return fmt.Errorf("generator already running")
	}

	g.running.Store(true)
	g.stopCh = make(chan struct{})
	g.collector.Reset()

	// Duration이 설정된 경우 타이머 시작
	if g.config.Duration > 0 {
		go func() {
			time.Sleep(g.config.Duration)
			g.Stop()
		}()
	}

	// 워커 시작
	for i := 0; i < g.config.Workers; i++ {
		g.wg.Add(1)
		go g.worker()
	}

	return nil
}

func (g *Generator) Stop() {
	if !g.running.Load() {
		return
	}

	g.running.Store(false)
	close(g.stopCh)
	g.wg.Wait()
}

func (g *Generator) worker() {
	defer g.wg.Done()

	// TPS 제한을 위한 rate limiter
	var ticker *time.Ticker
	var tickerCh <-chan time.Time

	if g.config.TPS > 0 {
		// TPS를 워커 수로 나눔
		tpsPerWorker := g.config.TPS / g.config.Workers
		if tpsPerWorker < 1 {
			tpsPerWorker = 1
		}
		interval := time.Second / time.Duration(tpsPerWorker)
		ticker = time.NewTicker(interval)
		tickerCh = ticker.C
		defer ticker.Stop()
	}

	for {
		select {
		case <-g.stopCh:
			return
		default:
			// TPS 제한이 있으면 ticker 대기
			if tickerCh != nil {
				select {
				case <-tickerCh:
				case <-g.stopCh:
					return
				}
			}

			// 배치 INSERT 실행
			if err := g.insertBatch(); err != nil {
				g.collector.RecordFailure(g.config.BatchSize)
			}
		}
	}
}

func (g *Generator) insertBatch() error {
	tx, err := g.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// 격리 수준 설정
	if _, err := tx.Exec(fmt.Sprintf("SET TRANSACTION ISOLATION LEVEL %s", g.config.IsolationLevel)); err != nil {
		return err
	}

	start := time.Now()

	if g.config.BatchSize == 1 {
		// 단일 INSERT
		_, err = tx.Exec(
			"INSERT INTO logs (level, service, message, metadata) VALUES ($1, $2, $3, $4)",
			randomLevel(),
			randomService(),
			randomMessage(),
			randomMetadata(),
		)
	} else {
		// 배치 INSERT (VALUES를 여러 개 나열)
		query := "INSERT INTO logs (level, service, message, metadata) VALUES "
		args := make([]interface{}, 0, g.config.BatchSize*4)

		for i := 0; i < g.config.BatchSize; i++ {
			if i > 0 {
				query += ", "
			}
			offset := i * 4
			query += fmt.Sprintf("($%d, $%d, $%d, $%d)", offset+1, offset+2, offset+3, offset+4)

			args = append(args,
				randomLevel(),
				randomService(),
				randomMessage(),
				randomMetadata(),
			)
		}

		_, err = tx.Exec(query, args...)
	}

	if err != nil {
		return err
	}

	if err := tx.Commit(); err != nil {
		return err
	}

	latency := time.Since(start)
	g.collector.RecordSuccess(latency, g.config.BatchSize)

	return nil
}

// 랜덤 데이터 생성 함수들
func randomLevel() string {
	levels := []string{"INFO", "WARN", "ERROR", "DEBUG"}
	return levels[rand.Intn(len(levels))]
}

func randomService() string {
	services := []string{"auth", "api", "worker", "scheduler", "notification", "payment"}
	return services[rand.Intn(len(services))]
}

func randomMessage() string {
	messages := []string{
		"Request processed successfully",
		"Database connection established",
		"Cache invalidated",
		"Task completed",
		"User authentication verified",
		"Payment transaction initiated",
		"Email notification sent",
		"API rate limit checked",
	}
	return messages[rand.Intn(len(messages))]
}

func randomMetadata() string {
	requestID := rand.Intn(1000000)
	userID := rand.Intn(10000)
	duration := rand.Intn(1000)

	return fmt.Sprintf(`{"request_id": %d, "user_id": %d, "duration_ms": %d}`, requestID, userID, duration)
}

func (g *Generator) UpdateConfig(config *Config) error {
	if g.running.Load() {
		return fmt.Errorf("cannot update config while generator is running")
	}

	if err := config.Validate(); err != nil {
		return err
	}

	g.config = config
	return nil
}

func (g *Generator) GetConfig() *Config {
	return g.config
}

func (g *Generator) IsRunning() bool {
	return g.running.Load()
}
