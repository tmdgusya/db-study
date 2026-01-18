#!/bin/bash

# 쓰기 집약 부하 테스트 스크립트

set -e

WRITE_SERVER="http://localhost:8080"
TEST_DURATION="5m"

echo "================================================"
echo "PostgreSQL 쓰기 집약 부하 테스트"
echo "================================================"
echo ""

# 1. 부하 설정
echo "[1/4] 부하 설정 중..."
curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 5000,
    \"batch_size\": 100,
    \"workers\": 10,
    \"duration\": \"${TEST_DURATION}\",
    \"isolation_level\": \"READ COMMITTED\"
  }" | jq '.'

echo ""

# 2. 부하 시작
echo "[2/4] 부하 생성 시작..."
curl -s -X POST ${WRITE_SERVER}/load/start | jq '.'

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

  METRICS=$(curl -s ${WRITE_SERVER}/metrics)

  TPS=$(echo ${METRICS} | jq -r '.tps')
  AVG_LATENCY=$(echo ${METRICS} | jq -r '.avg_latency_ms')
  P95_LATENCY=$(echo ${METRICS} | jq -r '.p95_latency_ms')
  P99_LATENCY=$(echo ${METRICS} | jq -r '.p99_latency_ms')
  TOTAL=$(echo ${METRICS} | jq -r '.total_requests')
  SUCCESS=$(echo ${METRICS} | jq -r '.success_requests')
  FAILED=$(echo ${METRICS} | jq -r '.failed_requests')

  printf "  TPS: %.2f\n" ${TPS}
  printf "  평균 지연시간: %.2f ms\n" ${AVG_LATENCY}
  printf "  P95 지연시간: %.2f ms\n" ${P95_LATENCY}
  printf "  P99 지연시간: %.2f ms\n" ${P99_LATENCY}
  printf "  총 요청: %d (성공: %d, 실패: %d)\n" ${TOTAL} ${SUCCESS} ${FAILED}
  echo "------------------------------------------------"
done

# 4. 부하 중지 (이미 duration으로 자동 중지됨)
echo ""
echo "[3/4] 부하 생성 중지 확인..."

# 부하가 아직 실행중이면 중지
STATUS=$(curl -s ${WRITE_SERVER}/load/status | jq -r '.running')
if [ "$STATUS" = "true" ]; then
  curl -s -X POST ${WRITE_SERVER}/load/stop | jq '.'
fi

echo ""

# 5. 최종 메트릭
echo "[4/4] 최종 결과"
echo "================================================"
curl -s ${WRITE_SERVER}/metrics | jq '.'

echo ""
echo "테스트 완료!"
