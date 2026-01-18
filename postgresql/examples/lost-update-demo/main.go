package main

import (
	"database/sql"
	"fmt"
	"log"
	"time"

	_ "github.com/lib/pq"

	"lost-update-demo/problem"
	"lost-update-demo/solution"
)

const (
	host     = "localhost"
	port     = 5433
	user     = "postgres"
	password = "postgres"
	dbname   = "inventory"
)

func main() {
	fmt.Println("\n" + repeat("=", 70))
	fmt.Println("🚀 PostgreSQL Lost Update 데모")
	fmt.Println(repeat("=", 70))

	// PostgreSQL 연결
	db := connectDB()
	defer db.Close()

	// 연결 확인
	if err := db.Ping(); err != nil {
		log.Fatalf("❌ 데이터베이스 연결 실패: %v\n", err)
	}
	fmt.Println("✅ PostgreSQL 연결 성공")

	// 1. Lost Update 문제 재현
	fmt.Println("\n" + repeat("*", 70))
	fmt.Println("PART 1: Lost Update 문제 재현")
	fmt.Println(repeat("*", 70))
	problem.RunProblemDemo(db)

	// 사용자가 결과를 확인할 수 있도록 잠시 대기
	fmt.Println("\n⏳ 3초 후 해결책 데모를 시작합니다...")
	time.Sleep(3 * time.Second)

	// 2. SELECT FOR UPDATE 해결책
	fmt.Println("\n" + repeat("*", 70))
	fmt.Println("PART 2: SELECT FOR UPDATE 해결책")
	fmt.Println(repeat("*", 70))
	solution.RunSolutionDemo(db)

	// 최종 요약
	fmt.Println("\n" + repeat("=", 70))
	fmt.Println("📚 핵심 요약")
	fmt.Println(repeat("=", 70))
	fmt.Println(`
1️⃣  Lost Update 문제란?
   - 두 개 이상의 트랜잭션이 동일한 데이터를 동시에 읽고 수정할 때 발생
   - READ COMMITTED에서는 SELECT와 UPDATE 사이에 다른 TX가 데이터를 변경 가능
   - 결과: 일부 변경사항이 손실됨

2️⃣  REPEATABLE READ로는 왜 부족한가?
   - SELECT는 트랜잭션 시작 시점의 스냅샷을 사용
   - 하지만 UPDATE는 최신 커밋된 버전을 기준으로 동작
   - 여전히 Lost Update 발생 가능!

3️⃣  SELECT FOR UPDATE의 작동 원리
   - 행(row) 단위 비관적 잠금 (Pessimistic Lock)
   - 다른 트랜잭션은 해당 행의 UPDATE/DELETE/SELECT FOR UPDATE를 대기
   - 일반 SELECT는 여전히 가능 (MVCC 덕분)

4️⃣  주의사항
   ✅ 장점: 간단하고 확실한 Lost Update 방지
   ⚠️  단점: 동시성 감소, 데드락 가능성
   💡 팁: 항상 동일한 순서로 잠금, 트랜잭션을 짧게 유지

5️⃣  대안들
   - Serializable 격리 수준 + 재시도 로직
   - 낙관적 잠금 (version 컬럼 사용)
   - 애플리케이션 레벨 큐/락 (Redis 등)
`)
	fmt.Println(repeat("=", 70))
	fmt.Println("✨ 데모 종료")
	fmt.Println(repeat("=", 70) + "\n")
}

// connectDB는 PostgreSQL 데이터베이스에 연결합니다.
func connectDB() *sql.DB {
	psqlInfo := fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=disable",
		host, port, user, password, dbname)

	db, err := sql.Open("postgres", psqlInfo)
	if err != nil {
		log.Fatalf("❌ 데이터베이스 연결 실패: %v\n", err)
	}

	// 연결 풀 설정
	db.SetMaxOpenConns(25)                 // 최대 연결 수
	db.SetMaxIdleConns(10)                 // 유휴 연결 수
	db.SetConnMaxLifetime(5 * time.Minute) // 연결 최대 수명

	return db
}

// repeat는 문자열을 n번 반복합니다.
func repeat(s string, n int) string {
	result := ""
	for i := 0; i < n; i++ {
		result += s
	}
	return result
}
