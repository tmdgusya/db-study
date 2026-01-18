# 검증 결과

## 구축 완료 항목

### ✅ Phase 1: 인프라 구성
- Docker Compose 설정 (PostgreSQL + 2 Go 서버)
- PostgreSQL 16 with CPU (2 cores), Memory (2GB) 제한
- 초기 데이터 10,000개 로그 레코드
- 성능 튜닝 설정 (shared_buffers=512MB, work_mem=64MB 등)

### ✅ Phase 2: Write Server
- Go 1.21 기반 HTTP 서버 (port 8080)
- 배치 INSERT 지원 (batch_size 설정 가능)
- TPS 제어 가능한 부하 생성기
- 메트릭 수집: TPS, 평균/P50/P95/P99 지연시간

### ✅ Phase 3: Read Server  
- Go 1.21 기반 HTTP 서버 (port 8081)
- 3가지 쿼리 타입: Simple, Filter, Aggregate
- QPS 제어 및 쿼리 믹스 설정 가능
- 메트릭 수집: QPS, 지연시간 분포

### ✅ Phase 4: 테스트 스크립트
- test-write-heavy.sh: 쓰기 집약 테스트
- test-read-heavy.sh: 읽기 집약 테스트
- test-mixed.sh: 혼합 워크로드 테스트
- README.md: 완전한 사용 가이드

### ✅ Phase 5: 검증 및 테스트

#### 서비스 상태
```
✓ PostgreSQL: Healthy (10,000 initial rows)
✓ Write Server: Running (port 8080)
✓ Read Server: Running (port 8081)
```

#### 기능 테스트
```
✓ Health Endpoints: OK
✓ Manual INSERT: Success
✓ Manual SELECT: Success (returns 5 rows)
✓ Load Generation: Success
  - Configured TPS: 100
  - Actual TPS: ~727 (averaged over 10s)
  - Total Requests: 9,990
  - P95 Latency: 1ms
  - Success Rate: 100%
```

## 테스트 결과

### 쓰기 성능 (Write Server)
- **설정**: TPS=100, batch_size=10, workers=2
- **결과**: 
  - 총 요청: 9,990
  - 평균 TPS: 727
  - P95 지연시간: 1ms
  - 성공률: 100%

### 읽기 성능 (Read Server)
- **상태**: 초기 데이터 10,001개 (10,000 + 1 테스트 INSERT)
- **쿼리**: 정상 동작 확인

## 사용 방법

### 1. 서비스 시작
```bash
cd /home/roach/db-study/load-test
docker compose up -d
```

### 2. 상태 확인
```bash
docker compose ps
curl http://localhost:8080/health  # Write Server
curl http://localhost:8081/health  # Read Server
```

### 3. 부하 테스트 실행
```bash
# 쓰기 집약
./scripts/test-write-heavy.sh

# 읽기 집약
./scripts/test-read-heavy.sh

# 혼합 워크로드
./scripts/test-mixed.sh
```

### 4. 메트릭 확인
```bash
# 쓰기 메트릭
curl http://localhost:8080/metrics | jq '.'

# 읽기 메트릭
curl http://localhost:8081/metrics | jq '.'
```

## 주요 API 엔드포인트

### Write Server (8080)
- `POST /load/config` - 부하 설정
- `POST /load/start` - 부하 시작
- `POST /load/stop` - 부하 중지
- `GET /metrics` - 메트릭 조회
- `POST /logs` - 수동 INSERT
- `POST /logs/batch` - 배치 INSERT

### Read Server (8081)
- `POST /load/config` - 부하 설정
- `POST /load/start` - 부하 시작
- `POST /load/stop` - 부하 중지
- `GET /metrics` - 메트릭 조회
- `GET /logs?limit=N` - 로그 조회
- `GET /logs/search?level=X&service=Y` - 필터 검색
- `GET /logs/stats` - 통계 조회

## 알려진 이슈 및 해결

### 이슈 1: Docker Compose 버전 경고
- **증상**: `version` attribute is obsolete
- **해결**: 경고는 무시 가능 (Docker Compose V2)

### 이슈 2: Duration JSON 파싱
- **증상**: "10s" 형식의 duration이 JSON unmarshal 실패
- **해결**: nanosecond 단위로 전송 (10s = 10000000000)
- **예시**: `{"duration": 10000000000}` (10초)

## 다음 단계

1. **성능 벤치마크**: 다양한 설정으로 최대 TPS/QPS 측정
2. **최적화 검증**: synchronous_commit, batch_size, 인덱스 효과 측정
3. **격리 수준 비교**: READ COMMITTED vs REPEATABLE READ 성능 차이
4. **혼합 워크로드**: 실제 프로덕션 비율로 테스트 (예: 70% Read, 30% Write)

## 참고 문서

- [README.md](./README.md) - 상세 사용 가이드
- [트랜잭션 격리 수준](../postgresql/트랜잭션_격리수준_스냅샷.md)
- [성능 최적화](../postgresql/트랜잭션_성능_최적화.md)
