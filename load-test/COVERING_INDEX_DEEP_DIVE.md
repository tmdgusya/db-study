# 커버링 인덱스 INCLUDE 절 Deep Dive

> **⚠️ 중요 발견 (실제 벤치마크 결과)**
>
> INCLUDE 인덱스는 **데이터 중복도**에 따라 크기가 극단적으로 변합니다!
>
> **실제 측정 (31M 행, 10K 고유 조합, 중복도 3,049x)**:
> - 복합 인덱스: **217 MB** ✅
> - INCLUDE 인덱스: **1,822 MB** (8.4배 폭발!) ❌
>
> **원인**: PostgreSQL 공식 제한사항
> - **"INCLUDE indexes can NEVER use deduplication"**
> - 복합 인덱스는 posting list로 압축 (10K entries)
> - INCLUDE는 모든 행마다 별도 tuple (31M entries)
> → 같은 메시지를 3,049번 완전 복제 저장!
>
> **결론**: 중복도 > 1.5x면 복합 인덱스가 압도적으로 우수
>
> 자세한 내용은 [실제 벤치마크 섹션](#️-실제-벤치마크-include의-치명적-함정) 참조

---

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

**사용 시기 (모든 조건 만족 필요)**:
- ✅ **데이터 중복도 < 1.5x** ← 가장 중요!
- ✅ col3가 WHERE 절에 사용 안 됨
- ✅ col3는 SELECT 절에만 필요
- ✅ col3가 크거나 카디널리티가 높음
- ✅ INSERT/UPDATE가 많음 (정렬 비용 줄이기)

**⚠️ 필수 사전 검증**:
```sql
-- 먼저 중복도를 반드시 확인!
SELECT
    COUNT(*) / COUNT(DISTINCT (col1, col2, col3))::float as duplication_ratio
FROM table;

-- ratio < 1.5  → INCLUDE 사용 고려 ✅
-- ratio > 1.5  → 복합 인덱스 사용 (INCLUDE는 오히려 더 큼!)
```

**예시**:
```sql
-- 좋은 예: 고유한 세션 데이터
CREATE INDEX idx_sessions ON user_sessions(user_id, session_id)
  INCLUDE (session_data);  -- 중복도 1.02x ✅

-- 나쁜 예: 반복되는 로그 메시지
CREATE INDEX idx_logs ON logs(level, service) INCLUDE (message);
-- 중복도 3,049x → 인덱스가 8배 폭발! ❌
```

---

## 성능 트레이드오프

| 항목 | 복합 인덱스 | INCLUDE 인덱스 |
|------|------------|---------------|
| **인덱스 크기** | 중복도 낮을 때 큼 | **⚠️ 중복도에 크게 영향** |
|  | 중복도 높을 때 **매우 작음** | 중복도 높을 때 **폭발적으로 큼** |
| **중복 제거** | ✅ B-tree 키로 중복 제거 | ❌ INCLUDE는 중복 제거 불가 |
| **데이터 적합성** | 반복 데이터에 이상적 | 고유 데이터에만 유효 |
| **B-tree 높이** | 높다 (큰 키) | 낮다 (작은 키) |
| **캐시 효율** | 낮다 | 높다 (중복도 < 1.5x일 때) |
| **WHERE 절 사용** | 모든 컬럼 가능 | 키 컬럼만 |
| **INSERT 성능** | 느리다 (모든 컬럼 정렬) | 빠르다 (키만 정렬) |
| **SELECT 성능** | 빠르다 | 중복도 낮을 때 더 빠름 |
| **디스크 I/O** | 중복도 높을 때 매우 적음 | 중복도 낮을 때 적음 |

**⚠️ 중요**: INCLUDE 인덱스는 데이터 중복도가 1.5배 이상이면 복합 인덱스보다 훨씬 큼!

---

## PostgreSQL 버전 지원

- **PostgreSQL 11+**: INCLUDE 절 지원
- **PostgreSQL 10 이하**: 미지원 (복합 인덱스만 사용)

---

## ⚠️ 실제 벤치마크: INCLUDE의 치명적 함정

### 실험 환경

**데이터셋**:
```sql
-- logs 테이블
총 행 수:       31,076,650
고유 조합:          10,193
중복 반복률:    평균 3,049번/조합

-- 가장 많이 반복되는 데이터
('INFO', 'auth', 'Request processed successfully') → 162,856번
('ERROR', 'auth', 'Task completed')                → 162,807번
('WARN', 'auth', 'Request processed successfully') → 162,703번
```

**생성한 인덱스**:
```sql
CREATE INDEX idx_test ON logs(level, service);
CREATE INDEX idx_composite ON logs(level, service, message);
CREATE INDEX idx_include ON logs(level, service) INCLUDE (message);
```

### 충격적인 결과

| 인덱스 | 크기 | 배율 | 이론 예측 | 실제 결과 |
|--------|------|------|-----------|----------|
| `logs_pkey` | 666 MB | - | - | - |
| `idx_test` | 207 MB | 1.0x | - | - |
| `idx_composite` | 217 MB | 1.05x | 큼 | **작음** ✅ |
| `idx_include` | **1822 MB** | **8.8x** | 작음 | **폭발** ❌ |

**예상과 정반대!** INCLUDE 인덱스가 복합 인덱스보다 **8.4배 더 큼**

---

### 왜 INCLUDE가 폭발했는가?

#### 핵심 원인: 중복 제거 메커니즘의 차이

**복합 인덱스: B-tree 키 기반 중복 제거**

```
PostgreSQL 내부 동작:

INSERT INTO logs VALUES ('INFO', 'auth', 'Request processed', ...);
  → B-tree Key = ('INFO', 'auth', 'Request processed')
  → 기존 키가 있는가? YES
  → ✅ 새 TID만 추가 (중복 제거!)

INSERT INTO logs VALUES ('INFO', 'auth', 'Request processed', ...);
  → 동일한 키!
  → ✅ 또 TID만 추가

...162,856번 반복...

결과:
┌──────────────────────────────────────┬─────────────────────────┐
│ B-tree Key                           │ TID List                │
├──────────────────────────────────────┼─────────────────────────┤
│ (INFO, auth, Request processed)      │ [TID₁, TID₂, ..., T₁₆₂₈₅₆] │  ← 한 엔트리!
└──────────────────────────────────────┴─────────────────────────┘

저장량: 10,193 고유 조합
크기: 217 MB ✅
```

**INCLUDE 인덱스: 키에서 제외된 컬럼은 중복 제거 불가**

```
PostgreSQL 내부 동작:

INSERT INTO logs VALUES ('INFO', 'auth', 'Request processed', ...);
  → B-tree Key = ('INFO', 'auth')  ← message는 키가 아님!
  → INCLUDE Data = 'Request processed'
  → ❌ message는 키가 아니므로 중복 판단 불가
  → 새 Leaf 엔트리 생성 (TID + INCLUDE 데이터)

INSERT INTO logs VALUES ('INFO', 'auth', 'Request processed', ...);
  → B-tree Key = ('INFO', 'auth')  ← 키는 같지만
  → INCLUDE Data = 'Request processed'  ← 이건 페이로드일 뿐
  → ❌ 또 새 Leaf 엔트리 생성!

...162,856번 반복...

결과:
┌──────────────┬─────┬─────────────────────────┐
│ B-tree Key   │ TID │ INCLUDE(message)        │
├──────────────┼─────┼─────────────────────────┤
│ (INFO, auth) │ T₁  │ Request processed       │  ← 중복!
│ (INFO, auth) │ T₂  │ Request processed       │  ← 중복!
│ (INFO, auth) │ T₃  │ Request processed       │  ← 중복!
│     ...      │ ... │ ...                     │
│ (INFO, auth) │ T₁₆₂₈│ Request processed      │  ← 162,856번째 중복!
└──────────────┴─────┴─────────────────────────┘

저장량: 31,076,650 엔트리 (모든 행!)
크기: 1822 MB ❌ (8.4배 폭발!)
```

#### 시각적 비교

```
복합 인덱스 저장 구조:
┌──────────────────────────────────────────┐
│ ('INFO', 'auth', 'Request processed')    │ ← 1개 키
│   └─ TID: [1, 2, 3, ..., 162856]        │    162,856개 포인터
├──────────────────────────────────────────┤
│ ('ERROR', 'auth', 'Task completed')      │ ← 1개 키
│   └─ TID: [162857, 162858, ..., 325663] │    162,807개 포인터
└──────────────────────────────────────────┘

총 엔트리: 10,193개
디스크 사용: 217 MB


INCLUDE 인덱스 저장 구조:
┌─────────────┬─────┬──────────────────────┐
│ (INFO,auth) │ T₁  │ Request processed    │ ← 엔트리 1
│ (INFO,auth) │ T₂  │ Request processed    │ ← 엔트리 2 (중복!)
│ (INFO,auth) │ T₃  │ Request processed    │ ← 엔트리 3 (중복!)
│     ...     │ ... │ ...                  │
│ (INFO,auth) │ T₁₆₂₈│ Request processed   │ ← 엔트리 162,856 (중복!)
├─────────────┼─────┼──────────────────────┤
│ (ERROR,auth)│ T₁₆₂₈│ Task completed      │ ← 엔트리 162,857
│     ...     │ ... │ ...                  │
└─────────────┴─────┴──────────────────────┘

총 엔트리: 31,076,650개 (모든 행!)
디스크 사용: 1822 MB (8.4배!)
```

---

### PostgreSQL 소스 코드 레벨 설명

**복합 인덱스 삽입 시** (PostgreSQL 13+ Deduplication):

```c
// src/backend/access/nbtree/nbtinsert.c (의사 코드)

btree_insert(index, key=(level, service, message), tid) {
    // 1. B-tree에서 키 검색
    existing_entry = search_btree(key);

    if (existing_entry != NULL && key_equals(existing_entry.key, key)) {
        // 2. 키가 완전히 동일 → Posting List에 TID 추가!
        // ✅ PostgreSQL 13+ Deduplication (압축!)
        if (posting_list_has_space(existing_entry)) {
            append_to_posting_list(existing_entry, tid);
            // 추가 디스크: ~6바이트 (TID만, 압축됨)
        } else {
            // Posting list 꽉 참 → 새 엔트리
            create_new_entry_with_posting_list(key, tid);
        }
    } else {
        // 3. 새 키 → 새 엔트리 생성
        create_new_entry_with_posting_list(key, tid);
        // 디스크: key_size + 초기 posting list
    }
}

// allequalimage = true → aggressive deduplication!
// 결과: 10,193 unique keys, 페이지당 1,117 tuples (8.4배 압축!)
```

**INCLUDE 인덱스 삽입 시** (NO Deduplication):

```c
// src/backend/access/nbtree/nbtinsert.c (의사 코드)

btree_insert_with_include(index, key=(level, service), tid, include=message) {
    // ❌ CRITICAL: INCLUDE indexes can NEVER use deduplication
    // Source: https://www.postgresql.org/docs/current/btree.html
    // "INCLUDE indexes can never use deduplication"

    // ALWAYS create a new index tuple for EVERY row
    // No posting list, no compression, no deduplication
    create_new_index_tuple(key=(level, service), tid, include_data=message);

    // 디스크 사용량 (매 행마다):
    // - key_size (level + service)
    // - tid (6 bytes)
    // - include_size (message 전체)
    // - tuple overhead (~24 bytes)
}

// PostgreSQL 제한사항:
// allequalimage = false → deduplication 완전히 불가능!
//
// 이유: INCLUDE 컬럼은 leaf page에만 저장되며,
//       posting list 형식과 호환되지 않음
//
// 결과: 31,076,650 rows → 31,076,650 개의 별도 index tuples
//       페이지당 133 tuples (정상 밀도, 압축 없음)
```

**핵심 차이**:
- 복합 인덱스: `allequalimage=true` → 10,193개 unique keys → **강력한 deduplication (posting list)**
- INCLUDE 인덱스: `allequalimage=false` → **절대 deduplication 불가** → 31M개 별도 tuples

**실제 측정 데이터** (PostgreSQL 16, 31M 행):

```sql
-- Deduplication 효율 비교
SELECT
    indexrelname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size,
    pg_relation_size(indexrelid) / 8192 as total_pages,
    reltuples::bigint as estimated_tuples,
    reltuples / (pg_relation_size(indexrelid) / 8192) as tuples_per_page
FROM pg_stat_user_indexes
JOIN pg_class ON pg_class.oid = indexrelid
WHERE indexrelname IN ('idx_composite', 'idx_include');

-- 결과:
-- idx_composite:  217 MB,  27,817 pages, 1,117 tuples/page  ← 8.4배 압축!
-- idx_include:   1822 MB, 233,251 pages,   133 tuples/page  ← 정상 밀도

-- allequalimage 확인
SELECT indexrelname, allequalimage
FROM bt_metap('idx_composite'),
     (SELECT 'idx_composite' as indexrelname) t;
-- idx_composite: true  ← aggressive dedup 가능

SELECT indexrelname, allequalimage
FROM bt_metap('idx_include'),
     (SELECT 'idx_include' as indexrelname) t;
-- idx_include: false  ← dedup 제한적
```

**왜 deduplication 가능 여부가 다른가?**

PostgreSQL B-tree deduplication (posting list) - **공식 제한사항**:
- 복합 인덱스: `allequalimage=true` → **deduplication 가능** ✅
  - 같은 (level, service, message) → 하나의 posting list로 압축
  - 10,193 unique keys → 각 key당 평균 3,049 TIDs를 posting list에 압축
  - **1,117 tuples/page** (정상의 8.4배 압축!)
  - Source: PostgreSQL B-tree deduplication (PostgreSQL 13+)

- INCLUDE 인덱스: `allequalimage=false` → **deduplication 절대 불가** ❌
  - PostgreSQL 공식 제한: "INCLUDE indexes can never use deduplication"
  - 모든 행마다 별도 index tuple 생성 (posting list 사용 불가)
  - 31,076,650 rows → 31,076,650 개의 완전히 독립적인 tuples
  - **133 tuples/page** (정상 밀도, 압축 전혀 없음)
  - INCLUDE 데이터가 각 tuple에 완전 복제 → 엄청난 중복 저장

---

### 데이터 중복도에 따른 영향

| 중복 반복률 | 복합 인덱스 크기 | INCLUDE 크기 | 차이 |
|------------|-----------------|--------------|------|
| **1.0x** (모두 고유) | 1000 MB | 900 MB | INCLUDE 10% 작음 ✅ |
| **5x** | 250 MB | 1000 MB | INCLUDE 4배 큼 ❌ |
| **10x** | 150 MB | 1000 MB | INCLUDE 6.7배 큼 ❌ |
| **100x** | 50 MB | 1000 MB | INCLUDE 20배 큼 ❌❌ |
| **3049x** (실제) | 217 MB | 1822 MB | **INCLUDE 8.4배 큼** ❌❌❌ |

**임계점**: 중복도가 **1.5x**를 넘으면 INCLUDE가 불리!

---

### 실제 쿼리 성능 비교

```sql
-- 쿼리: SELECT level, service, message
--       FROM logs
--       WHERE level='ERROR' AND service='auth'
--       LIMIT 100;

-- idx_composite 사용
Index Only Scan using idx_composite
  Buffers: shared hit=5
  Execution Time: 0.072 ms  ✅

-- idx_include는 너무 커서 옵티마이저가 선택조차 안 함!
-- (PostgreSQL은 작은 인덱스를 선호)
```

**결과**:
- 복합 인덱스: 작고 빠름 ✅
- INCLUDE 인덱스: 너무 커서 사용조차 안 됨 ❌

---

### 결론: 언제 INCLUDE를 사용할 것인가?

#### ❌ 사용하면 안 되는 경우

```sql
-- 나쁜 예: 고도로 반복되는 데이터
CREATE TABLE logs (
    level TEXT,     -- 4가지 값 (INFO, WARN, ERROR, DEBUG)
    service TEXT,   -- 5가지 값 (api, auth, worker, ...)
    message TEXT    -- 500가지 고정 메시지
);
-- 고유 조합: 4 × 5 × 500 = 10,000개
-- 실제 행: 30,000,000개
-- 반복률: 3,000x ❌❌❌

CREATE INDEX bad_idx ON logs(level, service) INCLUDE (message);
-- 결과: 1.8GB (복합 인덱스의 8배!) ❌
```

**위험 신호**:
- ✗ 제한된 고유 조합 (< 100K)
- ✗ 높은 중복 반복률 (> 1.5x)
- ✗ INCLUDE 컬럼 값이 반복됨
- ✗ 로그, 이벤트 등 카테고리형 데이터

#### ✅ 사용해야 하는 경우 (매우 제한적!)

**핵심**: INCLUDE는 deduplication이 **절대 불가**하므로, 중복도가 거의 1.0에 수렴해야 유리!

```sql
-- 좋은 예: 거의 모든 행이 고유 (중복도 1.02x)
CREATE TABLE user_sessions (
    user_id BIGINT,       -- 1M 유저
    session_id UUID,      -- 고유 세션 (거의 중복 없음!)
    session_data JSONB    -- 평균 500바이트, 모두 다름
);
-- 고유 조합: 10M 행 중 9.8M 고유
-- 중복도: 1.02x ✅ (거의 1.0!)

CREATE INDEX good_idx ON user_sessions(user_id, session_id)
  INCLUDE (session_data);

-- 왜 INCLUDE가 유리한가?
-- 1. 중복도 1.02x → 복합 인덱스도 dedup 효과 거의 없음
-- 2. session_data가 큼 (500 bytes) → Internal Node 비대화
-- 3. INCLUDE는 Internal Node 작음 → B-tree 높이 감소
-- 결과: 1.0GB (복합 1.5GB보다 30% 작음!) ✅
```

**이상적 조건 (모두 만족 필요!)**:
- ✓ **중복도 < 1.2x** ← 가장 중요! (거의 1.0에 가까워야 함)
- ✓ **고유성 > 80%** (대부분의 행이 고유)
- ✓ **INCLUDE 컬럼이 큼** (> 100 bytes)
- ✓ **WHERE 절에 사용 안 함**

**왜 중복도가 1.0에 가까워야 하는가?**

| 중복도 | 복합 인덱스 효과 | INCLUDE 효과 | 승자 |
|--------|-----------------|-------------|------|
| **1.0x** | Dedup 효과 없음 | Internal node 작음 | **INCLUDE** ✅ |
| **1.2x** | 1.2배 압축 | 모든 행 복제 | **INCLUDE** (아슬아슬) |
| **1.5x** | 1.5배 압축 | 모든 행 복제 | **비슷** |
| **2.0x** | 2배 압축 | 모든 행 복제 | **복합** ✅ |
| **3049x** | 3049배 압축! | 모든 행 복제 | **복합** ✅✅✅ |

#### 중복도 계산 방법

```sql
-- 데이터 중복도 확인
SELECT
    COUNT(*) as total_rows,
    COUNT(DISTINCT (level, service, message)) as unique_combinations,
    ROUND(COUNT(*)::numeric /
          COUNT(DISTINCT (level, service, message)), 2) as duplication_ratio
FROM logs;

-- 결과:
-- total_rows: 31,076,650
-- unique_combinations: 10,193
-- duplication_ratio: 3049.00  ← 위험! (> 1.5)

-- 판단:
-- • ratio ≤ 1.2  → INCLUDE 사용 고려 (단, INCLUDE 컬럼이 크고 고유해야 함)
-- • ratio > 1.2  → 복합 인덱스 사용 권장 ✓
-- • ratio > 1.5  → 복합 인덱스 필수! ✓✓
-- • ratio > 10   → INCLUDE는 재앙! 절대 사용 금지! ✓✓✓
```

---

### 핵심 교훈

```
┌─────────────────────────────────────────────────────────┐
│  INCLUDE 인덱스의 치명적 함정                              │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  • PostgreSQL 공식 제한사항:                             │
│    "INCLUDE indexes can NEVER use deduplication"       │
│    (Source: postgresql.org/docs/current/btree.html)   │
│                                                         │
│  • 복합 인덱스: posting list로 압축 (dedup 가능)         │
│  • INCLUDE 인덱스: 모든 행마다 별도 tuple (dedup 불가)    │
│  • 반복되는 데이터는 수천 번 완전 복제 저장됨              │
│                                                         │
│  ⚠️ 데이터 중복도가 1.5x 이상이면                         │
│     복합 인덱스가 압도적으로 우수!                         │
│                                                         │
│  이론 ≠ 실전                                            │
│  반드시 실제 데이터로 검증할 것!                          │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## 빠른 의사결정 가이드

### 복합 인덱스 vs INCLUDE: 어떤 것을 선택할까?

```
시작: 추가 컬럼이 필요한가?
│
├─ YES → WHERE 절에 사용하는가?
│        │
│        ├─ YES → 복합 인덱스 필수!
│        │        CREATE INDEX idx ON t(a, b, c);
│        │
│        └─ NO → 데이터 중복도 확인
│                │
│                SELECT COUNT(*) / COUNT(DISTINCT (a, b, c))
│                FROM table;
│                │
│                ├─ ≤ 1.2x → INCLUDE 컬럼 크기 확인
│                │           │
│                │           ├─ > 100 bytes → INCLUDE 고려 ✅
│                │           │   CREATE INDEX idx ON t(a, b) INCLUDE (c);
│                │           │   (Internal node 작아서 10-30% 절감)
│                │           │
│                │           └─ < 100 bytes → 복합 인덱스 ✅
│                │               (절감 효과 미미, 복합이 더 나음)
│                │
│                └─ > 1.2x → 복합 인덱스 필수! ✅✅
│                            CREATE INDEX idx ON t(a, b, c);
│                            (INCLUDE는 dedup 불가로 폭발!)
│
└─ NO → 기본 인덱스 사용
         CREATE INDEX idx ON t(a, b);
```

### 체크리스트

**INCLUDE 사용 전 필수 확인 (모두 만족 필요!)**:
- [ ] **중복도 ≤ 1.2x** (거의 1.0에 가까움) ← 가장 중요!
- [ ] **고유성 > 80%** (대부분의 행이 고유)
- [ ] **INCLUDE 컬럼이 큼** (> 100 bytes)
- [ ] **INCLUDE 컬럼이 WHERE 절에 절대 없음**

**하나라도 해당되면 복합 인덱스 사용**:
- [ ] 중복도 > 1.2x
- [ ] INCLUDE 컬럼을 WHERE 절에서 사용
- [ ] 로그/이벤트/카테고리형 데이터
- [ ] 제한된 고유 조합
- [ ] INCLUDE 컬럼이 작음 (< 100 bytes)

---

## 실전 예제

### Case 1: 복합 인덱스 승리 (현재 logs 테이블)

```sql
-- 데이터 특성
총 행: 31M
고유 조합: 10K
중복도: 3,049x  ← 위험!

-- 잘못된 선택: INCLUDE
CREATE INDEX idx_include ON logs(level, service) INCLUDE (message);
-- 결과: 1,822 MB ❌

-- 올바른 선택: 복합 인덱스
CREATE INDEX idx_composite ON logs(level, service, message);
-- 결과: 217 MB ✅ (8.4배 작음!)

-- 교훈: 반복 데이터는 복합 인덱스!
```

### Case 2: INCLUDE 승리 (유저 세션 데이터)

```sql
-- 데이터 특성
총 행: 10M
고유 조합: 9.8M
중복도: 1.02x  ← 안전!

-- 잘못된 선택: 복합 인덱스
CREATE INDEX idx_composite ON sessions(user_id, session_id, data);
-- 결과: 1.5 GB (큰 JSONB가 모든 노드에 포함)

-- 올바른 선택: INCLUDE
CREATE INDEX idx_include ON sessions(user_id, session_id)
  INCLUDE (data);
-- 결과: 1.0 GB ✅ (30% 작음!)

-- 교훈: 고유 데이터는 INCLUDE!
```

### Case 3: WHERE 절 사용 시 복합 인덱스

```sql
-- 쿼리 패턴
WHERE level = 'ERROR'
  AND service = 'api'
  AND message LIKE 'Payment%';  ← message로 필터링!

-- INCLUDE는 불가능
CREATE INDEX idx_include ON logs(level, service) INCLUDE (message);
-- message는 정렬 안 됨 → LIKE 검색 비효율 ❌

-- 복합 인덱스 필수
CREATE INDEX idx_composite ON logs(level, service, message);
-- message로 정렬됨 → LIKE 검색 효율적 ✅

-- 교훈: WHERE 절 사용 컬럼은 반드시 키에 포함!
```

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
