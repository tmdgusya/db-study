# PostgreSQL Lost Update 방지 데모

PostgreSQL에서 **Lost Update** 문제를 재현하고, **SELECT FOR UPDATE**로 해결하는 실습 프로젝트입니다.

## 📚 목차

1. [Lost Update란?](#lost-update란)
2. [프로젝트 구조](#프로젝트-구조)
3. [실행 방법](#실행-방법)
4. [예상 결과](#예상-결과)
5. [SELECT FOR UPDATE 작동 원리](#select-for-update-작동-원리)
6. [왜 REPEATABLE READ로는 부족한가?](#왜-repeatable-read로는-부족한가)
7. [성능 고려사항](#성능-고려사항)
8. [대안 방법들](#대안-방법들)

---

## Lost Update란?

**Lost Update**는 두 개 이상의 트랜잭션이 동일한 데이터를 동시에 읽고 수정할 때, 일부 변경사항이 손실되는 동시성 문제입니다.

### 발생 시나리오

```
초기 재고: 100개

시간 | TX1 (직원 A)                    | TX2 (직원 B)
-----|--------------------------------|--------------------------------
T1   | BEGIN;                         |
T2   | SELECT stock = 100             |
T3   |                                | BEGIN;
T4   |                                | SELECT stock = 100
T5   | UPDATE stock = 100 - 10 = 90   |
T6   | COMMIT;                        |
T7   |                                | UPDATE stock = 100 - 5 = 95
T8   |                                | COMMIT;

최종 재고: 95개 (올바른 값: 85개)
→ TX1의 변경사항(-10)이 손실됨!
```

### READ COMMITTED에서 왜 발생하는가?

PostgreSQL의 기본 격리 수준인 **READ COMMITTED**에서는:

1. **각 SQL 문장마다 새로운 스냅샷 생성**
2. SELECT 시점과 UPDATE 시점의 데이터가 다를 수 있음
3. SELECT로 읽은 값을 기준으로 계산 → UPDATE 시 다른 TX의 변경사항 무시

---

## 프로젝트 구조

```
lost-update-demo/
├── docker-compose.yml          # PostgreSQL 16 컨테이너
├── init.sql                    # 데이터베이스 초기화 스크립트
├── go.mod                      # Go 모듈 설정
├── main.go                     # 메인 프로그램
├── problem/
│   └── lost_update.go         # Lost Update 문제 재현
└── solution/
    └── select_for_update.go   # SELECT FOR UPDATE 해결책
```

---

## 실행 방법

### 1. PostgreSQL 시작

```bash
cd postgresql/examples/lost-update-demo
docker-compose up -d
```

### 2. 프로그램 실행

```bash
go run main.go
```

### 3. PostgreSQL 종료

```bash
docker-compose down
```

---

## 예상 결과

### PART 1: Lost Update 문제 재현

```
============================================================
❌ Lost Update 문제 재현 (READ COMMITTED)
============================================================

📦 초기 재고: 100개
🔄 10개의 고루틴이 각각 10개씩 차감 시도
📊 예상 최종 재고: 100 - (10 × 10) = 0개

  [고루틴  1] ✅ 10개 차감 완료
  [고루틴  2] ✅ 10개 차감 완료
  ...
  [고루틴 10] ✅ 10개 차감 완료

------------------------------------------------------------
⏱️  실행 시간: 125ms
📊 최종 재고: 30개

🚨 Lost Update 발생! 30개가 손실되었습니다!
💡 원인: SELECT와 UPDATE 사이에 다른 트랜잭션이 재고를 변경했지만,
   이미 읽은 stock 변수에는 반영되지 않았습니다.
============================================================
```

### PART 2: SELECT FOR UPDATE 해결책

```
============================================================
✅ SELECT FOR UPDATE 해결책
============================================================

📦 초기 재고: 100개
🔄 10개의 고루틴이 각각 10개씩 차감 시도
📊 예상 최종 재고: 100 - (10 × 10) = 0개
🔒 SELECT FOR UPDATE로 행 잠금 사용

  [고루틴  1] ✅ 10개 차감 완료
  [고루틴  2] ✅ 10개 차감 완료
  ...
  [고루틴 10] ✅ 10개 차감 완료

------------------------------------------------------------
⏱️  실행 시간: 142ms
📊 성공: 10건, 실패: 0건
📊 최종 재고: 0개

🎉 정확함! Lost Update가 방지되었습니다!
💡 SELECT FOR UPDATE가 행 잠금을 통해 동시성 문제를 해결했습니다.
============================================================
```

---

## SELECT FOR UPDATE 작동 원리

### 문법

```sql
SELECT column FROM table WHERE condition FOR UPDATE;
```

### 동작 방식

1. **행 잠금 획득**: SELECT 실행 시 해당 행에 대한 배타적 잠금(exclusive lock)을 획득
2. **다른 트랜잭션 대기**:
   - 다른 TX의 `UPDATE`, `DELETE`, `SELECT FOR UPDATE`는 대기
   - 일반 `SELECT`는 여전히 가능 (MVCC 덕분)
3. **잠금 해제**: COMMIT 또는 ROLLBACK 시 잠금 해제

### 코드 비교

#### ❌ 문제 (Lost Update 발생)

```go
tx.Begin()

// 1. 재고 조회
var stock int
tx.QueryRow("SELECT stock FROM products WHERE id = $1", id).Scan(&stock)

// 2. 재고 차감 계산
newStock := stock - quantity

// ⚠️ 다른 TX가 중간에 stock을 변경할 수 있음!

// 3. 업데이트
tx.Exec("UPDATE products SET stock = $1 WHERE id = $2", newStock, id)

tx.Commit()
```

#### ✅ 해결 (SELECT FOR UPDATE)

```go
tx.Begin()

// 1. 재고 조회 + 잠금 획득
var stock int
tx.QueryRow("SELECT stock FROM products WHERE id = $1 FOR UPDATE", id).Scan(&stock)

// 2. 재고 차감 계산
newStock := stock - quantity

// ✅ 다른 TX는 잠금이 해제될 때까지 대기 중

// 3. 업데이트
tx.Exec("UPDATE products SET stock = $1 WHERE id = $2", newStock, id)

tx.Commit()  // 잠금 해제
```

---

## 왜 REPEATABLE READ로는 부족한가?

많은 개발자들이 "격리 수준을 REPEATABLE READ로 올리면 되지 않나?"라고 생각하지만, **REPEATABLE READ로도 Lost Update는 발생할 수 있습니다**.

### REPEATABLE READ의 동작

```sql
-- TX1 (REPEATABLE READ)
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

SELECT stock FROM products WHERE id = 1;  -- 100 (스냅샷 생성)

-- TX2가 stock을 50으로 변경하고 커밋

SELECT stock FROM products WHERE id = 1;  -- 여전히 100 (스냅샷 사용)

UPDATE products SET stock = 100 - 10 WHERE id = 1;
-- ⚠️ UPDATE는 최신 커밋된 버전(50)을 기준으로 동작!
-- 결과: stock = 50 - 10 = 40
-- 하지만 우리는 100 - 10 = 90을 기대했음!

COMMIT;
```

### 핵심 차이

| 격리 수준 | SELECT | UPDATE/DELETE |
|----------|--------|---------------|
| **READ COMMITTED** | 각 문장마다 새 스냅샷 | 최신 커밋 버전 |
| **REPEATABLE READ** | 트랜잭션 시작 시 스냅샷 | **최신 커밋 버전** |

**중요**: REPEATABLE READ에서도 UPDATE/DELETE는 **최신 커밋된 버전**을 기준으로 동작합니다. 이는 PostgreSQL의 **Current Committed** 동작으로 Lost Update를 어느 정도 방지하지만, SELECT 후 계산하여 UPDATE하는 패턴에서는 여전히 문제가 발생합니다.

### 실제 테스트

`problem/lost_update.go`에서 격리 수준을 변경해보세요:

```go
// REPEATABLE READ로 변경
tx, _ := db.Begin()
tx.Exec("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")

// 여전히 Lost Update 발생!
```

---

## 성능 고려사항

### SELECT FOR UPDATE의 단점

1. **동시성 감소**
   - 행 잠금으로 인해 다른 트랜잭션이 대기
   - 처리량(throughput) 감소 가능

2. **데드락 가능성**
   ```sql
   -- TX1
   SELECT * FROM products WHERE id = 1 FOR UPDATE;  -- 행 1 잠금
   SELECT * FROM products WHERE id = 2 FOR UPDATE;  -- 행 2 대기...

   -- TX2
   SELECT * FROM products WHERE id = 2 FOR UPDATE;  -- 행 2 잠금
   SELECT * FROM products WHERE id = 1 FOR UPDATE;  -- 행 1 대기...

   -- ⚠️ 데드락 발생!
   ```

### 데드락 방지 방법

1. **항상 동일한 순서로 잠금**
   ```go
   // 항상 ID 오름차순으로 잠금
   ids := []int{5, 2, 8, 1}
   sort.Ints(ids)  // [1, 2, 5, 8]

   for _, id := range ids {
       tx.QueryRow("SELECT * FROM products WHERE id = $1 FOR UPDATE", id)
   }
   ```

2. **트랜잭션을 짧게 유지**
   - 잠금 시간 최소화
   - 네트워크 호출, 파일 I/O 등은 트랜잭션 밖에서 처리

3. **타임아웃 설정**
   ```sql
   SET lock_timeout = '5s';
   ```

---

## 대안 방법들

### 1. Serializable 격리 수준

```go
tx.Exec("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")

// PostgreSQL이 자동으로 직렬화 충돌 감지
// 충돌 발생 시 재시도 필요
for retries := 0; retries < 3; retries++ {
    err := executeTransaction(db)
    if err == nil {
        break
    }
    // Serialization failure - 재시도
}
```

**장점**: 완벽한 격리 보장
**단점**: 재시도 로직 필수, 성능 오버헤드

### 2. 낙관적 잠금 (Optimistic Locking)

```sql
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    stock INTEGER,
    version INTEGER DEFAULT 0  -- 버전 컬럼 추가
);
```

```go
// 1. 읽기
var stock, version int
tx.QueryRow("SELECT stock, version FROM products WHERE id = $1", id).Scan(&stock, &version)

// 2. 업데이트 (버전 확인)
result, _ := tx.Exec(
    "UPDATE products SET stock = $1, version = version + 1 WHERE id = $2 AND version = $3",
    newStock, id, version,
)

// 3. 충돌 확인
rowsAffected, _ := result.RowsAffected()
if rowsAffected == 0 {
    // 다른 TX가 먼저 수정함 - 재시도
}
```

**장점**: 높은 동시성, 읽기 전용 트랜잭션에 영향 없음
**단점**: 애플리케이션 복잡도 증가, 재시도 로직 필요

### 3. 애플리케이션 레벨 잠금

```go
// Redis 분산 락
redisLock := redis.AcquireLock("product:1")
defer redisLock.Release()

// 재고 차감 로직
```

**장점**: 데이터베이스 독립적, 여러 서버 간 동기화 가능
**단점**: 인프라 복잡도 증가, 추가 의존성

---

## 언제 어떤 방법을 사용해야 하는가?

| 방법 | 적합한 경우 | 부적합한 경우 |
|------|-----------|--------------|
| **SELECT FOR UPDATE** | • 단순한 재고 차감<br>• 읽기-수정-쓰기 패턴<br>• 데드락 가능성 낮음 | • 높은 동시성 필요<br>• 여러 행을 동시에 잠금<br>• 긴 트랜잭션 |
| **Serializable** | • 복잡한 비즈니스 로직<br>• Write Skew 방지 필요<br>• 완벽한 격리 필요 | • 높은 처리량 필요<br>• 재시도 불가능한 작업 |
| **낙관적 잠금** | • 충돌이 드문 경우<br>• 높은 읽기 비율<br>• 여러 서버 환경 | • 충돌이 빈번한 경우<br>• 재시도 비용이 높음 |
| **애플리케이션 락** | • 마이크로서비스 아키텍처<br>• 여러 DB 간 동기화<br>• 복잡한 분산 시스템 | • 단순한 단일 DB<br>• 네트워크 지연 민감 |

---

## 참고 자료

- [PostgreSQL 공식 문서 - SELECT FOR UPDATE](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)
- [PostgreSQL Transaction Isolation](https://www.postgresql.org/docs/current/transaction-iso.html)
- `../../트랜잭션_격리수준_스냅샷.md` - 트랜잭션 격리 수준 상세 가이드

---

## 라이선스

이 프로젝트는 교육 목적으로 제작되었습니다.
