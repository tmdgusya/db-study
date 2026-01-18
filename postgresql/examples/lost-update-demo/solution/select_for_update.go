package solution

import (
	"database/sql"
	"fmt"
	"sync"
	"time"
)

// DeductStockWithLock은 SELECT FOR UPDATE를 사용하여 Lost Update를 방지하는 재고 차감 함수입니다.
//
// 작동 원리:
// 1. SELECT ... FOR UPDATE로 행 잠금을 획득
// 2. 다른 트랜잭션은 이 행에 대한 UPDATE/DELETE/SELECT FOR UPDATE를 대기
// 3. 현재 트랜잭션이 커밋/롤백될 때까지 다른 TX는 블로킹됨
// 4. Lost Update 완벽히 방지!
//
// 장점:
// - 간단하고 직관적
// - Lost Update 확실히 방지
//
// 단점:
// - 동시성 감소 (행 잠금으로 인한 대기)
// - 데드락 가능성 (여러 행을 잠글 때)
func DeductStockWithLock(db *sql.DB, productID int, quantity int) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("트랜잭션 시작 실패: %w", err)
	}
	defer tx.Rollback()

	// 1단계: SELECT FOR UPDATE로 행 잠금 획득
	// 🔒 중요: 이 순간 해당 행(id=1)에 대한 배타적 잠금을 획득합니다
	var stock int
	err = tx.QueryRow(
		"SELECT stock FROM products WHERE id = $1 FOR UPDATE",
		productID,
	).Scan(&stock)
	if err != nil {
		return fmt.Errorf("재고 조회 및 잠금 실패: %w", err)
	}

	// 2단계: 재고 충분한지 확인
	if stock < quantity {
		return fmt.Errorf("재고 부족: 현재 %d개, 요청 %d개", stock, quantity)
	}

	// 3단계: 경합 상황 시뮬레이션
	// 다른 트랜잭션들은 이 행에 대한 잠금을 기다리는 중...
	time.Sleep(10 * time.Millisecond)

	// 4단계: 재고 차감 (안전하게!)
	// ✅ 다른 트랜잭션이 중간에 stock을 변경할 수 없으므로 안전
	newStock := stock - quantity
	_, err = tx.Exec("UPDATE products SET stock = $1 WHERE id = $2", newStock, productID)
	if err != nil {
		return fmt.Errorf("재고 업데이트 실패: %w", err)
	}

	// 5단계: 커밋 (잠금 해제)
	// 🔓 커밋 시 잠금이 해제되고, 대기 중인 다른 트랜잭션 중 하나가 잠금을 획득
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("커밋 실패: %w", err)
	}

	return nil
}

// RunSolutionDemo는 SELECT FOR UPDATE를 사용한 해결책을 데모합니다.
func RunSolutionDemo(db *sql.DB) {
	fmt.Println("\n" + repeat("=", 60))
	fmt.Println("✅ SELECT FOR UPDATE 해결책")
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
	fmt.Printf("📊 예상 최종 재고: %d - (10 × 10) = 0개\n", initialStock)
	fmt.Printf("🔒 SELECT FOR UPDATE로 행 잠금 사용\n\n")

	// 동시성 테스트
	var wg sync.WaitGroup
	var successCount, failCount int
	var mu sync.Mutex
	startTime := time.Now()

	// 10개의 goroutine이 동시에 재고 10개씩 차감
	for i := 1; i <= 10; i++ {
		wg.Add(1)
		go func(num int) {
			defer wg.Done()
			err := DeductStockWithLock(db, 1, 10)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				failCount++
				fmt.Printf("  [고루틴 %2d] ❌ 실패: %v\n", num, err)
			} else {
				successCount++
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
	fmt.Printf("📊 성공: %d건, 실패: %d건\n", successCount, failCount)
	fmt.Printf("📊 최종 재고: %d개\n", finalStock)

	if finalStock == 0 {
		fmt.Printf("\n🎉 정확함! Lost Update가 방지되었습니다!\n")
		fmt.Printf("💡 SELECT FOR UPDATE가 행 잠금을 통해 동시성 문제를 해결했습니다.\n")
	} else {
		fmt.Printf("\n⚠️  예상과 다른 결과입니다. (예상: 0, 실제: %d)\n", finalStock)
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
