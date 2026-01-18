# PostgreSQL Autovacuum 튜닝 가이드

## 목차
1. [왜 쓰기 워크로드에서 더 많은 Autovacuum Workers가 필요한가?](#1-왜-쓰기-워크로드에서-더-많은-autovacuum-workers가-필요한가)
2. [Autovacuum Workers 증설 판단 기준](#2-autovacuum-workers-증설-판단-기준)
3. [블로트가 성능에 미치는 영향 측정](#3-블로트가-성능에-미치는-영향-측정)
4. [진단 및 조치 가이드](#4-진단-및-조치-가이드)

---

## 1. 왜 쓰기 워크로드에서 더 많은 Autovacuum Workers가 필요한가?

### PostgreSQL MVCC 특성

PostgreSQL의 MVCC는 UPDATE/DELETE 시 기존 행을 바로 삭제하지 않고 새 버전을 만듭니다. 이전 버전은 **dead tuple**로 남으며, VACUUM이 이를 정리해야 합니다.

| 워크로드 | Dead Tuple 생성량 | VACUUM 필요성 |
|---------|------------------|--------------|
| **OLTP (높은 쓰기)** | 많음 (UPDATE/DELETE 빈번) | 높음 |
| **OLAP (주로 읽기)** | 적음 (SELECT 위주) | 낮음 |

### 시각적 비교

```
OLTP (쓰기 많음):
┌─────────────────────────────────────┐
│  테이블에 dead tuples 빠르게 쌓임    │
│  ████████████████ (쓰기 속도)       │
│  ████████ (VACUUM 3 workers)        │  ← 따라잡지 못함!
│  ████████████████ (VACUUM 6 workers)│  ← 균형 맞춤
└─────────────────────────────────────┘

OLAP (읽기 위주):
┌─────────────────────────────────────┐
│  dead tuples 느리게 쌓임             │
│  ████ (쓰기 속도)                    │
│  ████████ (VACUUM 3 workers)        │  ← 충분함
└─────────────────────────────────────┘
```

### 워커가 부족하면 발생하는 문제

1. **테이블 블로트**: dead tuples가 쌓여 테이블 크기 증가
2. **쿼리 성능 저하**: 불필요한 행을 스캔해야 함
3. **Transaction ID Wraparound 위험**: 심각한 경우 DB가 멈출 수 있음

### 권장 설정

| 설정 | OLTP (높은 쓰기) | OLAP (주로 읽기) |
|------|------------------|------------------|
| `autovacuum_max_workers` | 5-10 | 3 |
| `autovacuum_vacuum_threshold` | 1000-5000 | 50 |
| `autovacuum_vacuum_scale_factor` | 0.01-0.05 | 0.1 |

---

## 2. Autovacuum Workers 증설 판단 기준

### 2.1 현재 Autovacuum 워커 활동 상태 확인

```sql
SELECT
    v.pid,
    v.datname,
    v.relid::regclass AS table_name,
    v.phase,
    v.heap_blks_scanned,
    v.heap_blks_vacuumed,
    NOW() - a.xact_start AS duration
FROM pg_stat_progress_vacuum v
JOIN pg_stat_activity a ON v.pid = a.pid;
```

**워커가 부족한 신호:**
- 대부분의 시간 동안 모든 워커가 사용 중
- VACUUM이 완료되기를 대기하는 테이블이 계속 쌓임

### 2.2 Dead Tuple 비율 추적

```sql
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    last_autovacuum,
    NOW() - last_autovacuum AS since_last_vacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY dead_pct DESC
LIMIT 20;
```

| dead_pct | 상태 | 조치 |
|----------|------|------|
| < 5% | 정상 | 유지 |
| 5-20% | 주의 | 모니터링 강화 |
| > 20% | 위험 | 워커 증설 검토 |

### 2.3 Autovacuum 대기열 확인

```sql
-- VACUUM이 필요하지만 아직 실행되지 않은 테이블
SELECT
    schemaname,
    relname,
    n_dead_tup,
    n_live_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup, 0), 2) AS dead_pct,
    last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > (
    current_setting('autovacuum_vacuum_threshold')::int +
    current_setting('autovacuum_vacuum_scale_factor')::float * n_live_tup
)
ORDER BY n_dead_tup DESC;
```

**결과 해석:**
- 여러 테이블이 지속적으로 나타나면 → 워커 부족
- 가끔 1-2개만 나타나면 → 정상

### 2.4 워커 포화도 확인

```sql
SELECT 
    COUNT(*) AS running_workers,
    current_setting('autovacuum_max_workers') AS max_workers
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%';
```

**판단 기준:**

| 포화도 (running/max) | 상태 | 조치 |
|---------------------|------|------|
| < 50% | 여유 있음 | 현재 설정 유지 |
| 50-80% | 적정 | 모니터링 유지 |
| > 80% | 포화 상태 | 워커 증설 검토 |
| = 100% | 병목 발생 | 즉시 증설 필요 |

### 2.5 종합 진단 쿼리

```sql
WITH vacuum_stats AS (
    SELECT
        (SELECT COUNT(*) FROM pg_stat_activity 
         WHERE query LIKE 'autovacuum:%') AS running_workers,
        current_setting('autovacuum_max_workers')::int AS max_workers,
        (SELECT COUNT(*) FROM pg_stat_user_tables
         WHERE n_dead_tup > 10000 
         AND n_dead_tup > n_live_tup * 0.1) AS tables_need_vacuum,
        (SELECT ROUND(AVG(100.0 * n_dead_tup / NULLIF(n_live_tup, 0)), 2)
         FROM pg_stat_user_tables
         WHERE n_live_tup > 1000) AS avg_dead_pct
)
SELECT
    running_workers,
    max_workers,
    ROUND(100.0 * running_workers / max_workers, 0) AS worker_saturation_pct,
    tables_need_vacuum,
    avg_dead_pct,
    CASE
        WHEN running_workers >= max_workers AND tables_need_vacuum > 3 
            THEN '🔴 워커 증설 필요'
        WHEN running_workers >= max_workers * 0.8 
            THEN '🟡 모니터링 필요'
        ELSE '🟢 정상'
    END AS recommendation
FROM vacuum_stats;
```

**핵심 판단 공식:**
1. 워커 포화도 > 80% **AND**
2. VACUUM 대기 테이블 > 3개 **AND**
3. 평균 dead tuple 비율 > 10%

→ 이 세 조건이 **지속적으로** 만족되면 워커 증설을 고려

### 2.6 워커 증설 가이드

| 현재 워커 | 권장 증설 | 주의사항 |
|----------|----------|---------|
| 3 (기본값) | 5-6 | 대부분의 OLTP에 적합 |
| 6 | 8-10 | 고부하 환경 |
| 10+ | 신중히 | CPU/IO 경합 주의 |

**증설 시 고려사항:**
- 각 워커는 CPU와 I/O를 소비
- `autovacuum_vacuum_cost_limit`도 함께 조정 필요
- 너무 많으면 일반 쿼리 성능에 영향

---

## 3. 블로트가 성능에 미치는 영향 측정

### 3.1 테이블 블로트 크기 확인

```sql
-- pgstattuple 확장 필요
CREATE EXTENSION IF NOT EXISTS pgstattuple;

-- 실제 블로트 비율 측정 (대형 테이블은 느릴 수 있음)
SELECT
    table_len,
    tuple_len,
    dead_tuple_len,
    free_space,
    ROUND(100.0 * dead_tuple_len / NULLIF(table_len, 0), 2) AS dead_space_pct,
    ROUND(100.0 * free_space / NULLIF(table_len, 0), 2) AS free_space_pct,
    pg_size_pretty(table_len) AS total_size,
    pg_size_pretty(dead_tuple_len) AS wasted_space
FROM pgstattuple('테이블명');
```

결과 해석:
- `wasted_space`: 실제로 낭비되는 디스크 공간
- `dead_space_pct`: 10% 이상이면 쿼리 성능에 영향

### 3.2 쿼리 성능에 미치는 영향 측정

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM 테이블명
WHERE created_at > NOW() - INTERVAL '7 days';
```

주목할 지표:
- `Buffers: shared hit=X read=Y` → read가 높으면 블로트 영향
- `Seq Scan` 시 `rows removed by filter` → dead tuples 때문에 불필요한 스캔

### 3.3 실제 I/O 비용 측정

```sql
SELECT
    schemaname,
    relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_live_tup,
    n_dead_tup,
    -- Sequential scan 당 읽는 튜플 수
    ROUND(seq_tup_read::numeric / NULLIF(seq_scan, 0), 0) AS tuples_per_seq_scan,
    -- 이론상 필요한 튜플 vs 실제 읽은 튜플
    ROUND(seq_tup_read::numeric / NULLIF(seq_scan * n_live_tup, 0), 2) AS scan_efficiency
FROM pg_stat_user_tables
WHERE seq_scan > 0 AND n_live_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 10;
```

`scan_efficiency`가 1.0보다 훨씬 크면 dead tuples 때문에 불필요한 I/O가 발생

### 3.4 VACUUM 전후 비교 실험

```sql
-- Step 1: 현재 상태 기록
SELECT
    pg_relation_size('테이블명') AS size_before,
    (SELECT dead_tuple_len FROM pgstattuple('테이블명')) AS dead_before;

-- Step 2: 자주 사용하는 쿼리 실행 시간 측정
\timing on
SELECT COUNT(*) FROM 테이블명 WHERE created_at > NOW() - INTERVAL '7 days';
-- 실행 시간 기록

-- Step 3: VACUUM 실행
VACUUM ANALYZE 테이블명;

-- Step 4: 동일 쿼리 다시 측정
SELECT COUNT(*) FROM 테이블명 WHERE created_at > NOW() - INTERVAL '7 days';
-- 실행 시간 기록

-- Step 5: 크기 변화 확인
SELECT
    pg_relation_size('테이블명') AS size_after,
    (SELECT dead_tuple_len FROM pgstattuple('테이블명')) AS dead_after;
```

### 3.5 조치 필요 판단 기준

| 지표 | 정상 | 주의 | 조치 필요 |
|------|------|------|----------|
| Dead tuple % | < 5% | 5-15% | > 15% |
| 테이블 블로트 | < 20% | 20-40% | > 40% |
| 쿼리 성능 저하 | 없음 | 10-30% | > 30% |
| 마지막 VACUUM | < 1일 | 1-7일 | > 7일 (활성 테이블) |

---

## 4. 진단 및 조치 가이드

### 4.1 현재 설정 확인

```sql
SELECT name, setting
FROM pg_settings
WHERE name IN (
    'autovacuum',
    'autovacuum_max_workers',
    'autovacuum_naptime',
    'autovacuum_vacuum_threshold',
    'autovacuum_vacuum_scale_factor'
);
```

### 4.2 VACUUM 트리거 조건 이해

```
트리거 조건 = threshold + scale_factor × n_live_tup
```

예시 (기본 설정: threshold=50, scale_factor=0.2):
- 1,000행 테이블: 50 + 0.2 × 1,000 = **250** dead tuples에서 VACUUM 시작
- 1,000,000행 테이블: 50 + 0.2 × 1,000,000 = **200,050** dead tuples에서 VACUUM 시작

**문제점:** 대형 테이블에서 scale_factor=0.2는 너무 관대함

### 4.3 각 테이블의 VACUUM 트리거 상태 확인

```sql
SELECT
    relname,
    n_live_tup,
    n_dead_tup,
    (50 + 0.2 * n_live_tup)::int AS vacuum_trigger_threshold,
    CASE 
        WHEN n_dead_tup > (50 + 0.2 * n_live_tup) 
        THEN '🔴 VACUUM 필요'
        ELSE '🟢 OK'
    END AS status
FROM pg_stat_user_tables
WHERE n_dead_tup > 100
ORDER BY n_dead_tup DESC
LIMIT 10;
```

### 4.4 즉시 조치: 수동 VACUUM 실행

```sql
-- 문제 테이블들에 대해 수동 VACUUM
VACUUM ANALYZE 테이블명1;
VACUUM ANALYZE 테이블명2;
```

### 4.5 대형 테이블에 테이블별 설정 적용

```sql
-- 쓰기가 많은 대형 테이블
ALTER TABLE 대형_테이블 SET (
    autovacuum_vacuum_threshold = 10000,
    autovacuum_vacuum_scale_factor = 0.01  -- 0.2 → 0.01 (1%)
);

-- 중간 크기 활성 테이블
ALTER TABLE 중간_테이블 SET (
    autovacuum_vacuum_threshold = 1000,
    autovacuum_vacuum_scale_factor = 0.05
);

-- 작은 활성 테이블
ALTER TABLE 작은_테이블 SET (
    autovacuum_vacuum_threshold = 500,
    autovacuum_vacuum_scale_factor = 0.05
);
```

### 4.6 글로벌 설정 변경 (선택)

```sql
-- postgresql.conf 또는 ALTER SYSTEM
ALTER SYSTEM SET autovacuum_vacuum_scale_factor = 0.05;  -- 0.2 → 0.05
ALTER SYSTEM SET autovacuum_vacuum_threshold = 1000;     -- 50 → 1000
SELECT pg_reload_conf();  -- 설정 리로드
```

### 4.7 워커 수 증설

```sql
-- 워커 포화가 확인된 경우
ALTER SYSTEM SET autovacuum_max_workers = 6;  -- 3 → 6
SELECT pg_reload_conf();
```

---

## 요약

### 핵심 모니터링 포인트

1. **Dead tuple 비율**: 15% 이상이면 조치 필요
2. **워커 포화도**: 80% 이상이면 증설 검토
3. **마지막 VACUUM 시간**: 활성 테이블이 7일 이상이면 문제

### 튜닝 우선순위

1. **scale_factor 조정** (가장 흔한 문제)
   - 기본값 0.2는 대형 테이블에 너무 관대
   - 0.01~0.05로 낮추기

2. **테이블별 설정** (대형/활성 테이블)
   - 글로벌 설정과 별도로 관리

3. **워커 수 증설** (포화 시에만)
   - 포화도 확인 후 필요시에만 증설

### 변경 전 확인 사항

- pgstattuple로 실제 블로트 측정
- VACUUM 전후 쿼리 성능 비교
- 워커 포화도 확인
- 데이터 기반으로 판단 후 변경
