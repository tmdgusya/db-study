package load

import (
	"database/sql"
	"fmt"
	"math/rand"
	"read-server/metrics"
	"sync"
	"sync/atomic"
	"time"
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

	if g.config.Duration > 0 {
		go func() {
			time.Sleep(g.config.Duration)
			g.Stop()
		}()
	}

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

	var ticker *time.Ticker
	var tickerCh <-chan time.Time

	if g.config.QPS > 0 {
		qpsPerWorker := g.config.QPS / g.config.Workers
		if qpsPerWorker < 1 {
			qpsPerWorker = 1
		}
		interval := time.Second / time.Duration(qpsPerWorker)
		ticker = time.NewTicker(interval)
		tickerCh = ticker.C
		defer ticker.Stop()
	}

	for {
		select {
		case <-g.stopCh:
			return
		default:
			if tickerCh != nil {
				select {
				case <-tickerCh:
				case <-g.stopCh:
					return
				}
			}

			// 쿼리 타입 선택
			queryType := g.selectQueryType()
			if err := g.executeQuery(queryType); err != nil {
				g.collector.RecordFailure()
			}
		}
	}
}

func (g *Generator) selectQueryType() string {
	r := rand.Intn(100)

	if r < g.config.QueryMix.Simple {
		return "simple"
	} else if r < g.config.QueryMix.Simple+g.config.QueryMix.Filter {
		return "filter"
	} else {
		return "aggregate"
	}
}

func (g *Generator) executeQuery(queryType string) error {
	switch queryType {
	case "simple":
		return g.simpleQuery()
	case "filter":
		return g.filterQuery()
	case "aggregate":
		return g.aggregateQuery()
	default:
		return fmt.Errorf("unknown query type: %s", queryType)
	}
}

func (g *Generator) simpleQuery() error {
	tx, err := g.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(fmt.Sprintf("SET TRANSACTION ISOLATION LEVEL %s", g.config.IsolationLevel)); err != nil {
		return err
	}

	query := `
		SELECT id, timestamp, level, service, message
		FROM logs
		ORDER BY timestamp DESC
		LIMIT 100
	`

	start := time.Now()
	rows, err := tx.Query(query)
	if err != nil {
		return err
	}
	defer rows.Close()

	// 결과 읽기 (실제 데이터 fetch)
	for rows.Next() {
		var id int64
		var timestamp time.Time
		var level, service, message string
		if err := rows.Scan(&id, &timestamp, &level, &service, &message); err != nil {
			return err
		}
	}

	if err := rows.Err(); err != nil {
		return err
	}

	if err := tx.Commit(); err != nil {
		return err
	}

	latency := time.Since(start)
	g.collector.RecordSuccess(latency)

	return nil
}

func (g *Generator) filterQuery() error {
	tx, err := g.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(fmt.Sprintf("SET TRANSACTION ISOLATION LEVEL %s", g.config.IsolationLevel)); err != nil {
		return err
	}

	level := randomLevel()
	service := randomService()

	query := `
		SELECT id, timestamp, level, service, message
		FROM logs
		WHERE level = $1
		  AND service = $2
		  AND timestamp > NOW() - INTERVAL '1 hour'
		ORDER BY timestamp DESC
		LIMIT 100
	`

	start := time.Now()
	rows, err := tx.Query(query, level, service)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var id int64
		var timestamp time.Time
		var level, service, message string
		if err := rows.Scan(&id, &timestamp, &level, &service, &message); err != nil {
			return err
		}
	}

	if err := rows.Err(); err != nil {
		return err
	}

	if err := tx.Commit(); err != nil {
		return err
	}

	latency := time.Since(start)
	g.collector.RecordSuccess(latency)

	return nil
}

func (g *Generator) aggregateQuery() error {
	tx, err := g.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(fmt.Sprintf("SET TRANSACTION ISOLATION LEVEL %s", g.config.IsolationLevel)); err != nil {
		return err
	}

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
	rows, err := tx.Query(query)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var level string
		var count int64
		var firstSeen, lastSeen time.Time
		if err := rows.Scan(&level, &count, &firstSeen, &lastSeen); err != nil {
			return err
		}
	}

	if err := rows.Err(); err != nil {
		return err
	}

	if err := tx.Commit(); err != nil {
		return err
	}

	latency := time.Since(start)
	g.collector.RecordSuccess(latency)

	return nil
}

func randomLevel() string {
	levels := []string{"INFO", "WARN", "ERROR", "DEBUG"}
	return levels[rand.Intn(len(levels))]
}

func randomService() string {
	services := []string{"auth", "api", "worker", "scheduler", "notification", "payment"}
	return services[rand.Intn(len(services))]
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
