# PostgreSQL 부하 테스트 프로젝트

## 개요

PostgreSQL의 쓰기/읽기 성능을 측정하고 최적화 효과를 검증하기 위한 부하 테스트 환경입니다.

### 주요 기능

- **쓰기 부하 생성**: 배치 INSERT, TPS 제어, 트랜잭션 격리 수준 변경
- **읽기 부하 생성**: 쿼리 믹스(단순/필터/집계), QPS 제어
- **성능 메트릭**: TPS/QPS, 지연시간(평균, P50, P95, P99), 성공/실패 카운트
- **리소스 제한**: Docker Compose를 통한 CPU(2 코어), 메모리(2GB) 제한

## 아키텍처

```
┌─────────────────┐     ┌─────────────────┐
│  Write Server   │     │   Read Server   │
│   (port 8080)   │     │   (port 8081)   │
│                 │     │                 │
│  - 로그 INSERT  │     │  - 로그 조회    │
│  - 배치 쓰기    │     │  - 필터 검색    │
│  - 부하 생성    │     │  - 집계 쿼리    │
│  - TPS 메트릭   │     │  - QPS 메트릭   │
└────────┬────────┘     └────────┬────────┘
         │                       │
         └───────────┬───────────┘
                     │
         ┌───────────▼────────────┐
         │   PostgreSQL 16        │
         │   CPU: 2 cores         │
         │   Memory: 2GB          │
         │   Port: 5432           │
         └────────────────────────┘
```

### 데이터 모델

```sql
CREATE TABLE logs (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    level VARCHAR(10) NOT NULL,
    service VARCHAR(50) NOT NULL,
    message TEXT NOT NULL,
    metadata JSONB
);

CREATE INDEX idx_logs_timestamp ON logs(timestamp);
CREATE INDEX idx_logs_level ON logs(level);
CREATE INDEX idx_logs_service ON logs(service);
```

## 빠른 시작

### 1. 환경 구성

```bash
# 모든 서비스 시작 (PostgreSQL + Write Server + Read Server)
cd load-test
docker-compose up -d

# 로그 확인
docker-compose logs -f
```

### 2. 헬스체크

```bash
# PostgreSQL 연결 확인
docker exec -it loadtest-postgres pg_isready -U postgres

# Write Server 확인
curl http://localhost:8080/health

# Read Server 확인
curl http://localhost:8081/health
```

### 3. 쓰기 부하 테스트

```bash
./scripts/test-write-heavy.sh
```

**예상 출력**:
```
=== 30초 경과 ===
  TPS: 5023.45
  평균 지연시간: 15.32 ms
  P95 지연시간: 35.21 ms
  P99 지연시간: 52.18 ms
  총 요청: 150703 (성공: 150703, 실패: 0)
```

### 4. 읽기 부하 테스트

```bash
./scripts/test-read-heavy.sh
```

### 5. 혼합 워크로드 테스트

```bash
./scripts/test-mixed.sh
```

## API 사용법

### Write Server (port 8080)

#### 부하 설정 변경

```bash
curl -X POST http://localhost:8080/load/config \
  -H "Content-Type: application/json" \
  -d '{
    "tps": 5000,
    "batch_size": 100,
    "workers": 10,
    "duration": "5m",
    "isolation_level": "READ COMMITTED"
  }'
```

**파라미터 설명**:
- `tps`: 목표 초당 트랜잭션 수 (0 = 무제한)
- `batch_size`: 배치 INSERT 크기 (1 = 단일 INSERT)
- `workers`: 동시 실행 워커 수
- `duration`: 테스트 지속 시간 (0 = 무제한, 예: "5m", "1h")
- `isolation_level`: `READ COMMITTED`, `REPEATABLE READ`, `SERIALIZABLE`

#### 부하 시작/중지

```bash
# 시작
curl -X POST http://localhost:8080/load/start

# 중지
curl -X POST http://localhost:8080/load/stop

# 상태 조회
curl http://localhost:8080/load/status
```

#### 메트릭 조회

```bash
curl http://localhost:8080/metrics | jq '.'
```

**응답 예시**:
```json
{
  "total_requests": 300000,
  "success_requests": 299850,
  "failed_requests": 150,
  "tps": 5000.23,
  "avg_latency_ms": 15.32,
  "p50_latency_ms": 12.45,
  "p95_latency_ms": 35.21,
  "p99_latency_ms": 52.18,
  "start_time": "2026-01-18T10:30:00Z",
  "elapsed_seconds": 60.0
}
```

#### 수동 로그 INSERT

```bash
# 단일 로그
curl -X POST http://localhost:8080/logs \
  -H "Content-Type: application/json" \
  -d '{
    "level": "INFO",
    "service": "api",
    "message": "Request processed",
    "metadata": "{\"request_id\": 123}"
  }'

# 배치 로그
curl -X POST http://localhost:8080/logs/batch \
  -H "Content-Type: application/json" \
  -d '{
    "logs": [
      {"level": "INFO", "service": "api", "message": "Log 1", "metadata": "{}"},
      {"level": "ERROR", "service": "worker", "message": "Log 2", "metadata": "{}"}
    ]
  }'
```

### Read Server (port 8081)

#### 부하 설정 변경

```bash
curl -X POST http://localhost:8081/load/config \
  -H "Content-Type: application/json" \
  -d '{
    "qps": 10000,
    "workers": 20,
    "duration": "5m",
    "query_mix": {
      "simple": 60,
      "filter": 30,
      "aggregate": 10
    },
    "isolation_level": "READ COMMITTED"
  }'
```

**파라미터 설명**:
- `qps`: 목표 초당 쿼리 수 (0 = 무제한)
- `workers`: 동시 실행 워커 수
- `query_mix`: 쿼리 타입 비율 (합이 100이어야 함)
  - `simple`: 단순 조회 (ORDER BY timestamp DESC LIMIT 100)
  - `filter`: 필터 조회 (WHERE level = ? AND service = ?)
  - `aggregate`: 집계 쿼리 (GROUP BY level, COUNT, MIN, MAX)

#### 수동 로그 조회

```bash
# 최근 로그 조회 (페이징)
curl 'http://localhost:8081/logs?limit=100'

# 필터 검색
curl 'http://localhost:8081/logs/search?level=ERROR&service=api&limit=50'

# 통계 조회
curl http://localhost:8081/logs/stats
```

## 성능 튜닝 가이드

### PostgreSQL 설정 변경

`postgresql/postgresql.conf` 파일 수정 후 재시작:

```bash
docker-compose restart postgres
```

**주요 설정**:

| 설정 | 기본값 | 설명 | 튜닝 시나리오 |
|------|--------|------|---------------|
| `shared_buffers` | 512MB | 공유 버퍼 크기 | 읽기 집약: 1GB로 증가 |
| `work_mem` | 64MB | 정렬/해시 작업 메모리 | 집계 쿼리 많음: 128MB로 증가 |
| `wal_buffers` | 16MB | WAL 버퍼 크기 | 쓰기 집약: 32MB로 증가 |
| `checkpoint_timeout` | 10min | 체크포인트 간격 | 쓰기 집약: 15min으로 증가 |
| `max_connections` | 100 | 최대 연결 수 | 높은 동시성: 200으로 증가 |

### CPU/메모리 제한 변경

`docker-compose.yml`의 `deploy.resources` 섹션 수정:

```yaml
deploy:
  resources:
    limits:
      cpus: '4.0'    # 2 → 4 코어
      memory: 4G     # 2GB → 4GB
```

### 부하 조절 전략

#### 최대 쓰기 성능 측정

```bash
# TPS 무제한, 큰 배치 크기
curl -X POST http://localhost:8080/load/config \
  -d '{"tps": 0, "batch_size": 1000, "workers": 20}'
```

#### synchronous_commit 효과 측정

```sql
-- PostgreSQL에서 실행
ALTER SYSTEM SET synchronous_commit = off;
SELECT pg_reload_conf();
```

**예상 효과**: TPS 2.5배 향상 (5000 → 12500)

#### 인덱스 효과 측정

```bash
# 인덱스 제거 후 읽기 테스트
docker exec -it loadtest-postgres psql -U postgres -d loadtest

# PostgreSQL 쉘에서:
DROP INDEX idx_logs_level;

# 읽기 부하 테스트 실행
./scripts/test-read-heavy.sh

# 인덱스 재생성
CREATE INDEX idx_logs_level ON logs(level);
```

**예상 효과**: 필터 쿼리 지연시간 50배 개선 (500ms → 10ms)

#### 배치 크기 효과 측정

```bash
# batch_size=1 (단일 INSERT)
curl -X POST http://localhost:8080/load/config \
  -d '{"batch_size": 1, "workers": 10}'

# batch_size=100 (배치 INSERT)
curl -X POST http://localhost:8080/load/config \
  -d '{"batch_size": 100, "workers": 10}'
```

**예상 효과**: TPS 4배 향상 (2000 → 8000)

## 테스트 시나리오

### 시나리오 1: 최대 쓰기 성능

**목표**: `synchronous_commit=off`의 효과 측정

```bash
# Before
./scripts/test-write-heavy.sh

# PostgreSQL 설정 변경
docker exec -it loadtest-postgres psql -U postgres -c "ALTER SYSTEM SET synchronous_commit = off;"
docker exec -it loadtest-postgres psql -U postgres -c "SELECT pg_reload_conf();"

# After
./scripts/test-write-heavy.sh
```

### 시나리오 2: 격리 수준 비교

**목표**: `READ COMMITTED` vs `REPEATABLE READ` 성능 비교

```bash
# READ COMMITTED
curl -X POST http://localhost:8080/load/config \
  -d '{"isolation_level": "READ COMMITTED"}'
./scripts/test-write-heavy.sh

# REPEATABLE READ
curl -X POST http://localhost:8080/load/config \
  -d '{"isolation_level": "REPEATABLE READ"}'
./scripts/test-write-heavy.sh
```

### 시나리오 3: 혼합 워크로드 최적화

**목표**: Primary-Replica 아키텍처 검증

```bash
# 단일 인스턴스 (현재)
./scripts/test-mixed.sh

# Primary-Replica 구성 후 (쓰기는 Primary, 읽기는 Replica)
# docker-compose.yml에 replica 추가 필요
```

## 메트릭 설명

### TPS (Transactions Per Second)

초당 트랜잭션 수. 쓰기 성능 측정 지표.

- **좋음**: 5000+ (batch_size=100 기준)
- **보통**: 2000-5000
- **나쁨**: <2000

### QPS (Queries Per Second)

초당 쿼리 수. 읽기 성능 측정 지표.

- **좋음**: 10000+ (단순 쿼리 기준)
- **보통**: 5000-10000
- **나쁨**: <5000

### 지연시간 (Latency)

- **P50 (Median)**: 50% 요청의 응답 시간
- **P95**: 95% 요청의 응답 시간 (상위 5% 제외)
- **P99**: 99% 요청의 응답 시간 (상위 1% 제외)

**목표 값** (쓰기):
- P50: <20ms
- P95: <50ms
- P99: <100ms

**목표 값** (읽기):
- P50: <10ms
- P95: <30ms
- P99: <50ms

## 모니터링

### 실시간 메트릭 모니터링

```bash
# 1초마다 메트릭 출력
watch -n 1 'curl -s http://localhost:8080/metrics | jq .'
```

### PostgreSQL 통계 조회

```bash
# pg_stat_statements 활용
docker exec -it loadtest-postgres psql -U postgres -d loadtest

# 느린 쿼리 TOP 10
SELECT
  query,
  calls,
  mean_exec_time,
  total_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;

# 테이블 통계
SELECT
  schemaname,
  tablename,
  n_tup_ins AS inserts,
  n_tup_upd AS updates,
  n_tup_del AS deletes,
  n_live_tup AS live_tuples,
  n_dead_tup AS dead_tuples
FROM pg_stat_user_tables
WHERE tablename = 'logs';
```

### 연결 상태 확인

```bash
# 활성 연결 수
docker exec -it loadtest-postgres psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"

# 연결 상세 정보
docker exec -it loadtest-postgres psql -U postgres -c "SELECT pid, usename, application_name, client_addr, state FROM pg_stat_activity WHERE datname = 'loadtest';"
```

## 트러블슈팅

### 연결 실패 (connection refused)

```bash
# PostgreSQL이 실행 중인지 확인
docker-compose ps

# 로그 확인
docker-compose logs postgres

# 재시작
docker-compose restart postgres
```

### 너무 많은 연결 (too many connections)

**증상**: `FATAL: sorry, too many clients already`

**해결**:

```sql
-- max_connections 증가
ALTER SYSTEM SET max_connections = 200;
SELECT pg_reload_conf();
```

또는 워커 수 감소:

```bash
curl -X POST http://localhost:8080/load/config -d '{"workers": 5}'
```

### 디스크 공간 부족

```bash
# 볼륨 정리
docker-compose down -v

# 다시 시작
docker-compose up -d
```

### 메트릭이 0으로 표시됨

**원인**: 부하 생성기가 실행 중이 아님

**해결**:

```bash
# 부하 시작
curl -X POST http://localhost:8080/load/start
```

## 프로젝트 구조

```
load-test/
├── README.md                       # 이 문서
├── docker-compose.yml              # Docker Compose 설정
├── .env                            # 환경 변수
│
├── write-server/                   # 쓰기 부하 서버
│   ├── main.go                     # 서버 엔트리포인트
│   ├── handler/
│   │   ├── write.go                # 로그 INSERT 핸들러
│   │   └── load.go                 # 부하 제어/메트릭 핸들러
│   ├── load/
│   │   ├── generator.go            # 부하 생성 로직
│   │   └── config.go               # 설정 관리
│   ├── metrics/
│   │   └── collector.go            # 메트릭 수집
│   ├── Dockerfile
│   └── go.mod
│
├── read-server/                    # 읽기 부하 서버
│   ├── main.go
│   ├── handler/
│   │   ├── read.go                 # 로그 조회 핸들러
│   │   └── load.go                 # 부하 제어/메트릭 핸들러
│   ├── load/
│   │   ├── generator.go            # 부하 생성 로직
│   │   └── config.go               # 설정 관리
│   ├── metrics/
│   │   └── collector.go            # 메트릭 수집
│   ├── Dockerfile
│   └── go.mod
│
├── postgresql/                     # PostgreSQL 설정
│   ├── init.sql                    # 초기화 스크립트
│   └── postgresql.conf             # 성능 튜닝 설정
│
└── scripts/                        # 테스트 스크립트
    ├── test-write-heavy.sh         # 쓰기 집약 테스트
    ├── test-read-heavy.sh          # 읽기 집약 테스트
    └── test-mixed.sh               # 혼합 워크로드 테스트
```

## 참고 자료

- [PostgreSQL 공식 문서](https://www.postgresql.org/docs/16/)
- [PostgreSQL 성능 튜닝](https://wiki.postgresql.org/wiki/Performance_Optimization)
- [트랜잭션 격리 수준](../postgresql/트랜잭션_격리수준_스냅샷.md)
- [성능 최적화 가이드](../postgresql/트랜잭션_성능_최적화.md)

## 라이선스

MIT License
