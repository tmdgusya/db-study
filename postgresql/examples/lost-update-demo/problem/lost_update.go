package problem

import (
	"database/sql"
	"fmt"
	"sync"
	"time"
)

// DeductStockWithProblem은 Lost Update 문제가 발생하는 재고 차감 함수입니다.
// READ COMMITTED 격리 수준(PostgreSQL 기본값)에서 실행됩니다.
//
// 문제점:
// 1. SELECT로 재고를 읽음 (스냅샷 1 생성)
// 2. 다른 트랜잭션이 재고를 변경하고 커밋
// 3. UPDATE를 실행할 때 새로운 스냅샷 2 생성 (다른 TX의 변경사항 반영됨)
// 4. 하지만 이미 읽은 stock 변수는 이전 값 (Lost Update!)
func DeductStockWithProblem(db *sql.DB, productID int, quantity int) error {
	// READ COMMITTED 격리 수준 (명시적으로 설정하지 않아도 기본값)
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("트랜잭션 시작 실패: %w", err)
	}
	defer tx.Rollback() // COMMIT 성공 시 무시됨

	// 1단계: 현재 재고 조회 (스냅샷 1)
	var stock int
	err = tx.QueryRow("SELECT stock FROM products WHERE id = $1", productID).Scan(&stock)
	if err != nil {
		return fmt.Errorf("재고 조회 실패: %w", err)
	}

	// 2단계: 재고 충분한지 확인
	if stock < quantity {
		return fmt.Errorf("재고 부족: 현재 %d개, 요청 %d개", stock, quantity)
	}

	// 3단계: 경합 상황 시뮬레이션 (다른 트랜잭션이 동시에 실행될 시간을 줌)
	time.Sleep(10 * time.Millisecond)

	// 4단계: 재고 차감 (Lost Update 발생!)
	// ⚠️ 문제: stock 변수는 이전에 읽은 값이므로, 다른 TX가 중간에 변경한 내용이 반영되지 않음
	newStock := stock - quantity
	_, err = tx.Exec("UPDATE products SET stock = $1 WHERE id = $2", newStock, productID)
	if err != nil {
		return fmt.Errorf("재고 업데이트 실패: %w", err)
	}

	// 5단계: 커밋
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("커밋 실패: %w", err)
	}

	return nil
}

// RunProblemDemo는 Lost Update 문제를 재현하는 데모를 실행합니다.
func RunProblemDemo(db *sql.DB) {
	fmt.Println("\n" + repeat("=", 60))
	fmt.Println("❌ Lost Update 문제 재현 (READ COMMITTED)")
	fmt.Println(repeat("=", 60))

	// 초기 재고 설정
	_, err := db.Exec("UPDATE products SET stock = 100 WHERE id = 1")
	if err != nil {
		fmt.Printf("초기 재고 설정 실패: %v\n", err)
		return
	}

	var initialStock int
	db.QueryRow("SELECT stock FROM products WHERE id = 1").Scan(&initialStock)
	fmt.Printf("\n📦 초기 재고: %d개\n", initialStock)
	fmt.Printf("🔄 10개의 고루틴이 각각 10개씩 차감 시도\n")
	fmt.Printf("📊 예상 최종 재고: %d - (10 × 10) = 0개\n\n", initialStock)

	// 동시성 테스트
	var wg sync.WaitGroup
	startTime := time.Now()

	// 10개의 goroutine이 동시에 재고 10개씩 차감
	for i := 1; i <= 10; i++ {
		wg.Add(1)
		go func(num int) {
			defer wg.Done()
			err := DeductStockWithProblem(db, 1, 10)
			if err != nil {
				fmt.Printf("  [고루틴 %2d] ❌ 실패: %v\n", num, err)
			} else {
				fmt.Printf("  [고루틴 %2d] ✅ 10개 차감 완료\n", num)
			}
		}(i)
	}

	wg.Wait()
	elapsed := time.Since(startTime)

	// 최종 재고 확인
	var finalStock int
	db.QueryRow("SELECT stock FROM products WHERE id = 1").Scan(&finalStock)

	fmt.Printf("\n" + repeat("-", 60) + "\n")
	fmt.Printf("⏱️  실행 시간: %v\n", elapsed)
	fmt.Printf("📊 최종 재고: %d개\n", finalStock)

	if finalStock != 0 {
		fmt.Printf("\n🚨 Lost Update 발생! %d개가 손실되었습니다!\n", finalStock)
		fmt.Printf("💡 원인: SELECT와 UPDATE 사이에 다른 트랜잭션이 재고를 변경했지만,\n")
		fmt.Printf("   이미 읽은 stock 변수에는 반영되지 않았습니다.\n")
	} else {
		fmt.Printf("\n⚠️  이번에는 Lost Update가 발생하지 않았습니다.\n")
		fmt.Printf("   (타이밍에 따라 발생하지 않을 수도 있습니다. 다시 실행해보세요)\n")
	}
	fmt.Println(repeat("=", 60))
}

// repeat는 문자열을 n번 반복합니다 (헬퍼 함수)
func repeat(s string, n int) string {
	result := ""
	for i := 0; i < n; i++ {
		result += s
	}
	return result
}
