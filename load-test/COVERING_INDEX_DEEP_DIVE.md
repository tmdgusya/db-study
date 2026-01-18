# 커버링 인덱스 INCLUDE 절 Deep Dive

## PostgreSQL B-tree 인덱스 구조

### B-tree의 기본 구조

```
                [Internal Node]
                /      |      \
               /       |       \
    [Internal Node] [Internal] [Internal]
        /    \         |  \        /  \
       /      \        |   \      /    \
   [Leaf]  [Leaf]  [Leaf] [Leaf] [Leaf] [Leaf]
```

**중요한 사실**:
- Internal Node (내부 노드): 탐색을 위한 키만 저장
- Leaf Node (리프 노드): 실제 데이터 (또는 포인터) 저장

---

## 3가지 인덱스 비교

### 케이스 1: 일반 인덱스 (Heap Fetch 발생)

```sql
CREATE INDEX idx_normal ON logs(level, service);
```

**구조**:
```
Internal Node: [level, service]
Leaf Node:     [level, service, TID] → Heap으로 가서 message 읽기
```

**쿼리**: `SELECT level, service, message FROM logs WHERE level='ERROR'`

**실행 과정**:
1. B-tree에서 level='ERROR' 찾기
2. Leaf에서 TID(Tuple ID) 읽기
3. **Heap에 접근하여 message 읽기** ← 랜덤 I/O!

**문제점**: 1000건 결과 → 1000번 Heap 접근

---

### 케이스 2: 복합 인덱스 (모든 컬럼을 키로)

```sql
CREATE INDEX idx_composite ON logs(level, service, message);
```

**구조**:
```
Internal Node: [level, service, message]  ← 여기도 message!
Leaf Node:     [level, service, message, TID]
```

**쿼리**: `SELECT level, service, message FROM logs WHERE level='ERROR'`

**실행 과정**:
1. B-tree에서 level='ERROR' 찾기
2. Leaf에서 level, service, message 모두 읽기
3. **Heap 접근 불필요!** ✓

**문제점**:
- **모든 레벨에 message가 포함**
  - Internal Node가 비대해짐
  - B-tree 높이 증가 가능
  - 캐시 효율성 감소
- **message도 정렬됨**
  - INSERT/UPDATE 시 정렬 비용 증가
  - message로 정렬이 필요 없는데도 정렬함 (불필요한 작업)

---

### 케이스 3: INCLUDE 인덱스 (리프에만 추가 컬럼)

```sql
CREATE INDEX idx_include ON logs(level, service)
  INCLUDE (message);
```

**구조**:
```
Internal Node: [level, service]           ← message 없음!
Leaf Node:     [level, service, message, TID]  ← message는 여기만!
```

**쿼리**: `SELECT level, service, message FROM logs WHERE level='ERROR'`

**실행 과정**:
1. B-tree에서 level='ERROR' 찾기 (Internal Node는 작음)
2. Leaf에서 level, service, message 모두 읽기
3. **Heap 접근 불필요!** ✓

**장점**:
- **Internal Node가 작음**
  - 캐시 효율성 증가
  - B-tree 높이 감소
  - 탐색 속도 증가
- **message는 정렬 안 됨**
  - INSERT/UPDATE 시 정렬 비용 감소
  - 순서 상관없이 Leaf에 append
- **Heap 접근 제거**
  - Index-Only Scan 가능

---

## 왜 INCLUDE를 사용하는가?

### 핵심 이유 1: Internal Node 크기 최소화

```
복합 인덱스:
[Root]
  └─ Internal Node: [('ERROR','api','msg1'), ('ERROR','api','msg2'), ...]
       └─ 100바이트/엔트리 → 10개 = 1000바이트

INCLUDE 인덱스:
[Root]
  └─ Internal Node: [('ERROR','api'), ('ERROR','api'), ...]
       └─ 20바이트/엔트리 → 50개 = 1000바이트
```

**결과**: 동일한 메모리에 5배 더 많은 엔트리 캐싱 가능!

### 핵심 이유 2: 불필요한 정렬 제거

message는 WHERE 조건에 사용되지 않으므로 정렬할 필요 없음.

**복합 인덱스**: (level, service, message) 순으로 정렬
- INSERT 시 3단계 정렬 비용

**INCLUDE 인덱스**: (level, service)만 정렬
- INSERT 시 2단계 정렬 비용
- message는 순서 상관없이 저장

### 핵심 이유 3: WHERE 절 제약

```sql
-- INCLUDE 인덱스
CREATE INDEX idx ON logs(level, service) INCLUDE (message);

-- 사용 가능
WHERE level = 'ERROR' AND service = 'api'  ✓

-- 사용 불가 (message는 정렬되지 않음)
WHERE message LIKE 'payment%'  ✗ (Full Scan)
```

**설계 의도**:
- WHERE 절에 사용할 컬럼: 인덱스 키로
- SELECT 절에만 필요한 컬럼: INCLUDE로

---

## 실제 차이를 보여주는 예시

### 데이터 예시 (100만 건)

```
level   service   message
-----   -------   -------
ERROR   api       Payment failed: card declined (80자)
ERROR   api       Connection timeout after 30s (80자)
ERROR   worker    Task execution failed (80자)
...
```

### 인덱스 크기 비교

**일반 인덱스**: `(level, service)`
- Entry: level(10) + service(10) + TID(6) = 26바이트
- 100만 건 = 26MB (+ overhead) ≈ **30MB**

**복합 인덱스**: `(level, service, message)`
- Entry: level(10) + service(10) + message(80) + TID(6) = 106바이트
- 100만 건 = 106MB (+ overhead) ≈ **120MB**

**INCLUDE 인덱스**: `(level, service) INCLUDE (message)`
- Internal Node: level(10) + service(10) = 20바이트
- Leaf Node: level(10) + service(10) + message(80) + TID(6) = 106바이트
- Internal: 10% (작음), Leaf: 90%
- 총 크기: ≈ **100MB** (복합보다 작음)

### B-tree 높이 비교 (100만 건 기준)

**복합 인덱스**:
- Entry per page: 8KB / 106바이트 ≈ 75개
- 높이: log₇₅(1,000,000) ≈ 4 levels

**INCLUDE 인덱스**:
- Internal: 8KB / 20바이트 ≈ 400개
- 높이: log₄₀₀(1,000,000) ≈ 3 levels

**결과**: INCLUDE가 1 level 낮음 → 탐색 1번 덜!

---

## PostgreSQL 내부 동작

### EXPLAIN ANALYZE로 확인

```sql
-- 복합 인덱스
CREATE INDEX idx_composite ON logs(level, service, message);

EXPLAIN (ANALYZE, BUFFERS)
SELECT level, service, message
FROM logs
WHERE level = 'ERROR' AND service = 'api';

-- 결과:
Index Only Scan using idx_composite
  Heap Fetches: 0  ← Visibility Map 체크만
  Buffers: shared hit=150  ← 버퍼 읽기 많음 (큰 인덱스)
```

```sql
-- INCLUDE 인덱스
CREATE INDEX idx_include ON logs(level, service) INCLUDE (message);

EXPLAIN (ANALYZE, BUFFERS)
SELECT level, service, message
FROM logs
WHERE level = 'ERROR' AND service = 'api';

-- 결과:
Index Only Scan using idx_include
  Heap Fetches: 0
  Buffers: shared hit=80  ← 버퍼 읽기 적음 (작은 인덱스)
```

**차이**: INCLUDE가 Buffer 읽기 47% 감소!

---

## WHERE 절 동작 차이

### 테스트 1: message를 WHERE에 사용

```sql
-- 복합 인덱스
CREATE INDEX idx_composite ON logs(level, service, message);

SELECT * FROM logs
WHERE level = 'ERROR'
  AND service = 'api'
  AND message LIKE 'Payment%';

-- Index Scan 가능 (message가 정렬되어 있음)
-- Execution time: 10ms
```

```sql
-- INCLUDE 인덱스
CREATE INDEX idx_include ON logs(level, service) INCLUDE (message);

SELECT * FROM logs
WHERE level = 'ERROR'
  AND service = 'api'
  AND message LIKE 'Payment%';

-- Index Scan 후 Filter 필요 (message가 정렬 안 됨)
-- Execution time: 15ms (약간 느림)
```

**결론**: WHERE 절에 message를 사용한다면 복합 인덱스가 유리!

### 테스트 2: message를 SELECT만 사용

```sql
-- 복합 인덱스
CREATE INDEX idx_composite ON logs(level, service, message);

SELECT level, service, message
FROM logs
WHERE level = 'ERROR' AND service = 'api';

-- Buffers: 150
```

```sql
-- INCLUDE 인덱스
CREATE INDEX idx_include ON logs(level, service) INCLUDE (message);

SELECT level, service, message
FROM logs
WHERE level = 'ERROR' AND service = 'api';

-- Buffers: 80 (47% 감소!)
```

**결론**: SELECT만 사용한다면 INCLUDE가 유리!

---

## 언제 무엇을 사용할까?

### 복합 인덱스 사용 (모든 컬럼을 키로)

```sql
CREATE INDEX idx ON table(col1, col2, col3);
```

**사용 시기**:
- ✅ col3가 WHERE 절에 자주 사용됨
- ✅ col3로 정렬이 필요함 (ORDER BY col3)
- ✅ col3의 선택도가 높음 (< 5%)

**예시**:
```sql
-- user_id로 필터링이 중요
CREATE INDEX idx_user_events ON events(event_type, user_id, timestamp);

SELECT * FROM events
WHERE event_type = 'click'
  AND user_id = 12345;  -- user_id로 필터링!
```

---

### INCLUDE 인덱스 사용 (리프에만 추가)

```sql
CREATE INDEX idx ON table(col1, col2) INCLUDE (col3);
```

**사용 시기**:
- ✅ col3가 WHERE 절에 사용 안 됨
- ✅ col3는 SELECT 절에만 필요
- ✅ col3가 크거나 카디널리티가 높음
- ✅ INSERT/UPDATE가 많음 (정렬 비용 줄이기)

**예시**:
```sql
-- message는 조회만 하고 필터링 안 함
CREATE INDEX idx_logs ON logs(level, service) INCLUDE (message, metadata);

SELECT level, service, message, metadata
FROM logs
WHERE level = 'ERROR' AND service = 'api';  -- message 필터링 없음!
```

---

## 성능 트레이드오프

| 항목 | 복합 인덱스 | INCLUDE 인덱스 |
|------|------------|---------------|
| **인덱스 크기** | 크다 (모든 레벨에 컬럼) | 작다 (리프에만) |
| **B-tree 높이** | 높다 | 낮다 |
| **캐시 효율** | 낮다 | 높다 |
| **WHERE 절 사용** | 모든 컬럼 가능 | 키 컬럼만 |
| **INSERT 성능** | 느리다 (모든 컬럼 정렬) | 빠르다 (키만 정렬) |
| **SELECT 성능** | 빠르다 | 더 빠르다 (작은 인덱스) |
| **디스크 I/O** | 많다 | 적다 |

---

## PostgreSQL 버전 지원

- **PostgreSQL 11+**: INCLUDE 절 지원
- **PostgreSQL 10 이하**: 미지원 (복합 인덱스만 사용)

---

## 다음 단계

실제 부하 테스트로 3가지 케이스를 비교하겠습니다:
1. 일반 인덱스 (Heap Fetch)
2. 복합 인덱스 (모든 컬럼 키)
3. INCLUDE 인덱스 (리프에만)

각 케이스의:
- QPS
- 지연시간 (P50, P95, P99)
- 버퍼 사용량
- 인덱스 크기
- INSERT 성능 영향

을 측정하여 정확한 차이를 확인하겠습니다.
