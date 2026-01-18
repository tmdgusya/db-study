package main

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"read-server/handler"
	"read-server/load"
	"read-server/metrics"
	"syscall"
	"time"

	"github.com/gorilla/mux"
	_ "github.com/lib/pq"
)

func main() {
	// 환경 변수 읽기
	dbHost := getEnv("DB_HOST", "localhost")
	dbPort := getEnv("DB_PORT", "5432")
	dbName := getEnv("DB_NAME", "loadtest")
	dbUser := getEnv("DB_USER", "postgres")
	dbPassword := getEnv("DB_PASSWORD", "postgres")
	serverPort := getEnv("SERVER_PORT", "8081")

	// PostgreSQL 연결
	connStr := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		dbHost, dbPort, dbUser, dbPassword, dbName,
	)

	log.Printf("Connecting to PostgreSQL at %s:%s/%s", dbHost, dbPort, dbName)

	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer db.Close()

	// 연결 풀 설정
	db.SetMaxOpenConns(50)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(time.Hour)

	// DB 연결 확인
	if err := db.Ping(); err != nil {
		log.Fatalf("Failed to ping database: %v", err)
	}

	log.Println("Successfully connected to PostgreSQL")

	// 메트릭 컬렉터 초기화
	collector := metrics.NewCollector()

	// 부하 생성기 초기화
	defaultConfig := load.DefaultConfig()
	generator := load.NewGenerator(db, defaultConfig, collector)

	// 핸들러 초기화
	readHandler := handler.NewReadHandler(db, collector)
	loadHandler := handler.NewLoadHandler(generator, collector)

	// 라우터 설정
	router := mux.NewRouter()

	// 로그 조회 API
	router.HandleFunc("/logs", readHandler.GetLogs).Methods("GET")
	router.HandleFunc("/logs/search", readHandler.SearchLogs).Methods("GET")
	router.HandleFunc("/logs/stats", readHandler.GetStats).Methods("GET")

	// 부하 제어 API
	router.HandleFunc("/load/start", loadHandler.Start).Methods("POST")
	router.HandleFunc("/load/stop", loadHandler.Stop).Methods("POST")
	router.HandleFunc("/load/config", loadHandler.GetConfig).Methods("GET")
	router.HandleFunc("/load/config", loadHandler.UpdateConfig).Methods("POST")
	router.HandleFunc("/load/status", loadHandler.GetStatus).Methods("GET")

	// 메트릭 API
	router.HandleFunc("/metrics", loadHandler.GetMetrics).Methods("GET")
	router.HandleFunc("/metrics/reset", loadHandler.ResetMetrics).Methods("POST")

	// 헬스체크
	router.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "OK")
	}).Methods("GET")

	// HTTP 서버 시작
	srv := &http.Server{
		Addr:         ":" + serverPort,
		Handler:      router,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Graceful shutdown 설정
	go func() {
		log.Printf("Read server listening on port %s", serverPort)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Failed to start server: %v", err)
		}
	}()

	// 종료 시그널 대기
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh

	log.Println("Shutting down server...")

	// 부하 생성기 중지
	if generator.IsRunning() {
		log.Println("Stopping load generator...")
		generator.Stop()
	}

	log.Println("Server stopped")
}

func getEnv(key, defaultValue string) string {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	return value
}
