#!/bin/bash

# 혼합 워크로드 부하 테스트 스크립트

set -e

WRITE_SERVER="http://localhost:8080"
READ_SERVER="http://localhost:8081"
TEST_DURATION="5m"

echo "================================================"
echo "PostgreSQL 혼합 워크로드 부하 테스트"
echo "================================================"
echo ""

# 1. 쓰기 부하 설정 (30%)
echo "[1/5] 쓰기 부하 설정 중..."
curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 3000,
    \"batch_size\": 50,
    \"workers\": 5,
    \"duration\": \"${TEST_DURATION}\",
    \"isolation_level\": \"REPEATABLE READ\"
  }" | jq '.'

echo ""

# 2. 읽기 부하 설정 (70%)
echo "[2/5] 읽기 부하 설정 중..."
curl -s -X POST ${READ_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"qps\": 7000,
    \"workers\": 15,
    \"duration\": \"${TEST_DURATION}\",
    \"query_mix\": {
      \"simple\": 70,
      \"filter\": 20,
      \"aggregate\": 10
    },
    \"isolation_level\": \"REPEATABLE READ\"
  }" | jq '.'

echo ""

# 3. 동시 부하 시작
echo "[3/5] 동시 부하 생성 시작..."
echo "  - 쓰기 부하 시작..."
curl -s -X POST ${WRITE_SERVER}/load/start | jq '.'

echo "  - 읽기 부하 시작..."
curl -s -X POST ${READ_SERVER}/load/start | jq '.'

echo ""
echo "부하 테스트 진행 중... (${TEST_DURATION})"
echo "================================================"

# 4. 30초마다 메트릭 출력
INTERVAL=30
ITERATIONS=10

for i in $(seq 1 ${ITERATIONS}); do
  sleep ${INTERVAL}

  ELAPSED=$((i * INTERVAL))
  echo ""
  echo "=== ${ELAPSED}초 경과 ==="
  echo ""

  # 쓰기 메트릭
  echo "--- 쓰기 메트릭 ---"
  WRITE_METRICS=$(curl -s ${WRITE_SERVER}/metrics)

  TPS=$(echo ${WRITE_METRICS} | jq -r '.tps')
  AVG_LATENCY=$(echo ${WRITE_METRICS} | jq -r '.avg_latency_ms')
  P95_LATENCY=$(echo ${WRITE_METRICS} | jq -r '.p95_latency_ms')
  TOTAL=$(echo ${WRITE_METRICS} | jq -r '.total_requests')
  SUCCESS=$(echo ${WRITE_METRICS} | jq -r '.success_requests')

  printf "  TPS: %.2f\n" ${TPS}
  printf "  평균 지연시간: %.2f ms\n" ${AVG_LATENCY}
  printf "  P95 지연시간: %.2f ms\n" ${P95_LATENCY}
  printf "  총 요청: %d (성공: %d)\n" ${TOTAL} ${SUCCESS}

  echo ""

  # 읽기 메트릭
  echo "--- 읽기 메트릭 ---"
  READ_METRICS=$(curl -s ${READ_SERVER}/metrics)

  QPS=$(echo ${READ_METRICS} | jq -r '.qps')
  AVG_LATENCY=$(echo ${READ_METRICS} | jq -r '.avg_latency_ms')
  P95_LATENCY=$(echo ${READ_METRICS} | jq -r '.p95_latency_ms')
  TOTAL=$(echo ${READ_METRICS} | jq -r '.total_requests')
  SUCCESS=$(echo ${READ_METRICS} | jq -r '.success_requests')

  printf "  QPS: %.2f\n" ${QPS}
  printf "  평균 지연시간: %.2f ms\n" ${AVG_LATENCY}
  printf "  P95 지연시간: %.2f ms\n" ${P95_LATENCY}
  printf "  총 요청: %d (성공: %d)\n" ${TOTAL} ${SUCCESS}

  echo "================================================"
done

# 5. 부하 중지
echo ""
echo "[4/5] 부하 중지 중..."

WRITE_STATUS=$(curl -s ${WRITE_SERVER}/load/status | jq -r '.running')
if [ "$WRITE_STATUS" = "true" ]; then
  curl -s -X POST ${WRITE_SERVER}/load/stop | jq -r '.status'
fi

READ_STATUS=$(curl -s ${READ_SERVER}/load/status | jq -r '.running')
if [ "$READ_STATUS" = "true" ]; then
  curl -s -X POST ${READ_SERVER}/load/stop | jq -r '.status'
fi

echo ""

# 6. 최종 메트릭
echo "[5/5] 최종 결과"
echo "================================================"

echo ""
echo "--- 쓰기 서버 최종 메트릭 ---"
curl -s ${WRITE_SERVER}/metrics | jq '.'

echo ""
echo "--- 읽기 서버 최종 메트릭 ---"
curl -s ${READ_SERVER}/metrics | jq '.'

echo ""
echo "테스트 완료!"
