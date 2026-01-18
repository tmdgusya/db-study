# PostgreSQL 성능 최적화 벤치마크 가이드

## 개요

이 벤치마크 suite는 PostgreSQL의 다양한 최적화 기법의 효과를 **Before/After 비교**를 통해 명확히 검증합니다.

각 테스트는:
- ✅ 설정을 선택한 **이유** 설명
- ✅ **Before** 상태에서 성능 측정
- ✅ **After** 상태에서 성능 측정
- ✅ 동일한 워크로드로 **공정한 비교**
- ✅ 결과 분석 및 **실무 활용 가이드**

## 테스트 목록

| # | 테스트 | Before | After | 예상 향상 | 소요 시간 |
|---|--------|--------|-------|-----------|----------|
| 1 | 배치 INSERT | batch_size=1 | batch_size=100 | 4배 | 3분 |
| 2 | synchronous_commit | on | off | 2.5배 | 3분 |
| 3 | 인덱스 효과 | 인덱스 없음 | 인덱스 있음 | 50배 | 3분 |
| 4 | 커버링 인덱스 | 일반 인덱스 | 커버링 인덱스 | 3배 | 3분 |
| 5 | work_mem | 4MB | 256MB | 5배 | 3분 |
| 6 | 격리 수준 | READ COMMITTED | REPEATABLE READ | 0.9배 | 3분 |

**총 소요 시간**: 약 18분

## 빠른 시작

### 전체 테스트 실행

```bash
cd /home/roach/db-study/load-test

# 서비스 시작 (아직 안 했다면)
docker compose up -d

# 모든 벤치마크 실행 (약 18분)
./scripts/run-all-benchmarks.sh
```

### 개별 테스트 실행

```bash
# 테스트 1: 배치 INSERT 효과
./scripts/benchmark-01-batch-insert.sh

# 테스트 2: synchronous_commit 효과
./scripts/benchmark-02-synchronous-commit.sh

# 테스트 3: 인덱스 효과
./scripts/benchmark-03-index-effect.sh

# 테스트 4: 커버링 인덱스 효과
./scripts/benchmark-04-covering-index.sh

# 테스트 5: work_mem 효과
./scripts/benchmark-05-work-mem.sh

# 테스트 6: 격리 수준 효과
./scripts/benchmark-06-isolation-level.sh
```

## 상세 테스트 설명

### 1. 배치 INSERT 효과 (benchmark-01-batch-insert.sh)

**목적**: 단일 INSERT vs 배치 INSERT의 TPS 차이 측정

**선택 이유**:
- 단일 INSERT: 각 레코드마다 네트워크 왕복 + WAL 쓰기
- 배치 INSERT: 여러 레코드를 하나의 트랜잭션으로 처리
  - 네트워크 왕복: N번 → 1번
  - WAL 쓰기: N번 → 1번 (commit 한 번만)
  - 잠금 오버헤드: N번 → 1번

**Before**: `batch_size=1` (단일 INSERT)
- 각 로그를 개별 트랜잭션으로 INSERT
- 예상 TPS: ~2,000

**After**: `batch_size=100` (배치 INSERT)
- 100개 로그를 하나의 트랜잭션으로 INSERT
- 예상 TPS: ~8,000 (4배 향상)

**결과 해석**:
- 4배 향상: 네트워크, WAL, 잠금 오버헤드 감소
- 실무 적용: 대량 데이터 적재 시 반드시 배치 사용
- 권장 batch_size: 100~1000

---

### 2. synchronous_commit 효과 (benchmark-02-synchronous-commit.sh)

**목적**: WAL fsync 대기 여부에 따른 TPS 차이 측정

**선택 이유**:
- `synchronous_commit=on` (기본값)
  - 매 commit마다 WAL을 디스크에 fsync()
  - 데이터 손실 위험 0% (서버 크래시에도 안전)
  - 디스크 I/O 대기로 느림

- `synchronous_commit=off`
  - WAL을 OS 캐시에만 쓰고 즉시 리턴
  - fsync는 백그라운드에서 비동기 처리
  - 서버 크래시 시 최대 3초치 데이터 손실 가능
  - 디스크 I/O 대기 없음 → 매우 빠름

**Before**: `synchronous_commit=on` (안전, 느림)
- 예상 TPS: ~5,000

**After**: `synchronous_commit=off` (빠름, 약간 위험)
- 예상 TPS: ~12,000 (2.5배 향상)

**결과 해석**:
- 2.5배 향상: 디스크 fsync 대기 시간 제거
- 사용 케이스:
  - **OFF 권장**: 로그 수집, 분석 데이터, 세션 캐시
  - **ON 필수**: 금융 거래, 주문, 결제 데이터
- 주의: 서버 크래시 시 최대 3초치 손실 가능

---

### 3. 인덱스 효과 (benchmark-03-index-effect.sh)

**목적**: 인덱스 유무에 따른 SELECT 쿼리 성능 차이 측정

**선택 이유**:
- 인덱스 없음: Full Table Scan
  - WHERE level='ERROR' 조회 시 전체 테이블 스캔
  - 10만 건 테이블에서 2.5만 건 찾기: 10만 건 전부 읽음
  - O(N) 시간 복잡도

- 인덱스 있음: Index Scan
  - B-tree 인덱스로 빠르게 탐색
  - log₂(100000) + 25000 ≈ 25017번 읽음
  - O(log N + M) 시간 복잡도

**Before**: 인덱스 없음 (Full Table Scan)
- 예상 평균 지연시간: ~500ms
- 예상 QPS: ~20

**After**: 인덱스 있음 (Index Scan)
- 예상 평균 지연시간: ~10ms (50배 빠름)
- 예상 QPS: ~1,000 (50배 향상)

**결과 해석**:
- 50배 향상: 읽어야 하는 블록 수 획기적 감소
- 인덱스 생성 기준:
  - WHERE 절에 자주 사용되는 컬럼
  - 선택도가 높은 컬럼 (< 5%)
  - JOIN, ORDER BY에 사용되는 컬럼
- 단점: 디스크 공간, INSERT/UPDATE 느려짐

---

### 4. 커버링 인덱스 효과 (benchmark-04-covering-index.sh)

**목적**: 일반 인덱스 vs 커버링 인덱스의 성능 차이 측정

**선택 이유**:
- 일반 인덱스 (Index Scan + Heap Fetch)
  1. 인덱스에서 level='ERROR'인 행의 위치(TID) 찾기
  2. 각 TID에 대해 실제 테이블에 접근하여 컬럼 읽기
  3. 1000건 결과 → 1000번의 heap 접근 (랜덤 I/O)

- 커버링 인덱스 (Index-Only Scan)
  1. 인덱스에서 level='ERROR'이고 필요한 컬럼도 모두 읽기
  2. 테이블 접근 불필요! (Visibility Map만 체크)
  3. Heap 접근 0번 → 매우 빠름

**Before**: 일반 인덱스 `CREATE INDEX ON logs(level)`
- 예상 평균 지연시간: ~15ms
- 예상 QPS: ~700

**After**: 커버링 인덱스 `CREATE INDEX ON logs(level, service) INCLUDE (id, timestamp, message)`
- 예상 평균 지연시간: ~5ms (3배 빠름)
- 예상 QPS: ~2,100 (3배 향상)

**결과 해석**:
- 3배 향상: Heap 접근 제거 (랜덤 I/O 없음)
- 사용 케이스:
  - 자주 조회되는 컬럼 조합
  - 읽기가 압도적으로 많은 테이블
  - 리포팅, 대시보드 쿼리
- 단점: 인덱스 크기 증가, INSERT/UPDATE 비용 증가

---

### 5. work_mem 효과 (benchmark-05-work-mem.sh)

**목적**: work_mem 크기에 따른 GROUP BY/집계 쿼리 성능 차이 측정

**선택 이유**:
- work_mem이 작을 때 (4MB)
  - 메모리에 데이터를 다 담을 수 없음
  - 디스크 임시 파일 사용 (Disk Sort, External Merge)
  - 디스크 I/O 발생으로 매우 느림

- work_mem이 충분할 때 (256MB)
  - 모든 작업을 메모리에서 처리
  - Quick Sort, Hash Aggregate
  - 디스크 I/O 없이 빠름

**Before**: `work_mem=4MB` (디스크 정렬)
- 예상 평균 지연시간: ~100ms
- 예상 QPS: ~100

**After**: `work_mem=256MB` (메모리 정렬)
- 예상 평균 지연시간: ~20ms (5배 빠름)
- 예상 QPS: ~500 (5배 향상)

**결과 해석**:
- 5배 향상: 디스크 I/O 제거
- 적절한 work_mem: (Total RAM - shared_buffers) / max_connections / 4
- 주의: work_mem은 커넥션당 설정!
  - 100 connections × 1GB = 최대 100GB → OOM 위험

---

### 6. 격리 수준 효과 (benchmark-06-isolation-level.sh)

**목적**: READ COMMITTED vs REPEATABLE READ의 성능 차이 측정

**선택 이유**:
- READ COMMITTED (기본값)
  - 각 쿼리마다 새 스냅샷 생성
  - 커밋된 최신 데이터 읽음
  - 높은 동시성, 낮은 오버헤드
  - Non-Repeatable Read, Phantom Read 발생 가능

- REPEATABLE READ
  - 트랜잭션 시작 시 스냅샷 생성, 이후 계속 사용
  - 트랜잭션 전체에서 일관된 데이터 보장
  - Serialization Failure 발생 가능
  - 약간 낮은 동시성, 중간 오버헤드

**Before**: READ COMMITTED
- 쓰기 예상 TPS: ~8,000
- 읽기 예상 QPS: ~10,000

**After**: REPEATABLE READ
- 쓰기 예상 TPS: ~7,000 (약간 감소, Serialization Failure)
- 읽기 예상 QPS: ~10,000 (큰 차이 없음)

**결과 해석**:
- 성능 차이 약간 (쓰기는 10% 감소)
- 사용 기준:
  - **READ COMMITTED**: 단순 CRUD, 높은 동시성, API 서버
  - **REPEATABLE READ**: 복잡한 비즈니스 로직, 금융 거래, 보고서 생성
- 주의: REPEATABLE READ는 Serialization Failure 재시도 필요

## 결과 해석 및 실무 적용

### 성능 지표 이해

#### TPS (Transactions Per Second)
- 의미: 초당 처리 가능한 트랜잭션 수
- 쓰기 성능 지표
- 높을수록 좋음

#### QPS (Queries Per Second)
- 의미: 초당 처리 가능한 쿼리 수
- 읽기 성능 지표
- 높을수록 좋음

#### 지연시간 (Latency)
- P50 (Median): 50% 요청의 응답 시간
- P95: 95% 요청의 응답 시간
- P99: 99% 요청의 응답 시간
- 낮을수록 좋음, P95/P99가 중요 (사용자 경험)

### 실무 적용 순서

1. **테스트 결과 분석**
   - 각 최적화의 향상률 확인
   - 비용(디스크, 메모리, 복잡도) vs 효과 비교

2. **우선순위 결정**
   - 즉시 적용 가능: 배치 INSERT, 인덱스 추가
   - 신중히 검토: synchronous_commit, work_mem 증가
   - 상황에 따라: 커버링 인덱스, 격리 수준 변경

3. **점진적 적용**
   - 개발 환경 → 스테이징 → 프로덕션
   - 모니터링 필수 (pg_stat_statements, slow query log)
   - 롤백 계획 수립

4. **지속적 모니터링**
   - 성능 지표 추적
   - 인덱스 사용률 확인 (pg_stat_user_indexes)
   - 정기적인 VACUUM, ANALYZE

## 트러블슈팅

### 테스트 실패 시

```bash
# 서비스 재시작
docker compose restart

# 로그 확인
docker compose logs postgres
docker compose logs write-server
docker compose logs read-server

# 데이터베이스 연결 확인
docker exec loadtest-postgres psql -U postgres -d loadtest -c "SELECT 1"
```

### 성능이 예상과 다를 때

- 동시 실행 중인 프로세스 확인
- 디스크 I/O 상태 확인 (`iostat`, `iotop`)
- CPU 사용률 확인 (`top`, `htop`)
- PostgreSQL 설정 확인 (`SHOW ALL`)

## 참고 자료

- [PostgreSQL 공식 문서](https://www.postgresql.org/docs/16/)
- [트랜잭션 격리 수준](../postgresql/트랜잭션_격리수준_스냅샷.md)
- [성능 최적화 가이드](../postgresql/트랜잭션_성능_최적화.md)
- [README.md](./README.md)

## 라이선스

MIT License
