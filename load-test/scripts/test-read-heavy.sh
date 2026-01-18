#!/bin/bash

# 읽기 집약 부하 테스트 스크립트

set -e

READ_SERVER="http://localhost:8081"
TEST_DURATION="5m"

echo "================================================"
echo "PostgreSQL 읽기 집약 부하 테스트"
echo "================================================"
echo ""

# 1. 부하 설정
echo "[1/4] 부하 설정 중..."
curl -s -X POST ${READ_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"qps\": 10000,
    \"workers\": 20,
    \"duration\": \"${TEST_DURATION}\",
    \"query_mix\": {
      \"simple\": 60,
      \"filter\": 30,
      \"aggregate\": 10
    },
    \"isolation_level\": \"READ COMMITTED\"
  }" | jq '.'

echo ""

# 2. 부하 시작
echo "[2/4] 부하 생성 시작..."
curl -s -X POST ${READ_SERVER}/load/start | jq '.'

echo ""
echo "부하 테스트 진행 중... (${TEST_DURATION})"
echo "------------------------------------------------"

# 3. 30초마다 메트릭 출력
INTERVAL=30
ITERATIONS=10

for i in $(seq 1 ${ITERATIONS}); do
  sleep ${INTERVAL}

  ELAPSED=$((i * INTERVAL))
  echo ""
  echo "=== ${ELAPSED}초 경과 ==="

  METRICS=$(curl -s ${READ_SERVER}/metrics)

  QPS=$(echo ${METRICS} | jq -r '.qps')
  AVG_LATENCY=$(echo ${METRICS} | jq -r '.avg_latency_ms')
  P95_LATENCY=$(echo ${METRICS} | jq -r '.p95_latency_ms')
  P99_LATENCY=$(echo ${METRICS} | jq -r '.p99_latency_ms')
  TOTAL=$(echo ${METRICS} | jq -r '.total_requests')
  SUCCESS=$(echo ${METRICS} | jq -r '.success_requests')
  FAILED=$(echo ${METRICS} | jq -r '.failed_requests')

  printf "  QPS: %.2f\n" ${QPS}
  printf "  평균 지연시간: %.2f ms\n" ${AVG_LATENCY}
  printf "  P95 지연시간: %.2f ms\n" ${P95_LATENCY}
  printf "  P99 지연시간: %.2f ms\n" ${P99_LATENCY}
  printf "  총 요청: %d (성공: %d, 실패: %d)\n" ${TOTAL} ${SUCCESS} ${FAILED}
  echo "------------------------------------------------"
done

# 4. 부하 중지
echo ""
echo "[3/4] 부하 생성 중지 확인..."

STATUS=$(curl -s ${READ_SERVER}/load/status | jq -r '.running')
if [ "$STATUS" = "true" ]; then
  curl -s -X POST ${READ_SERVER}/load/stop | jq '.'
fi

echo ""

# 5. 최종 메트릭
echo "[4/4] 최종 결과"
echo "================================================"
curl -s ${READ_SERVER}/metrics | jq '.'

echo ""
echo "테스트 완료!"
