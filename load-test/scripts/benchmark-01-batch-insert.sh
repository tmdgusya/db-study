#!/bin/bash

# ============================================================
# 테스트 1: 배치 INSERT 효과 검증
# ============================================================
#
# 목적: 단일 INSERT vs 배치 INSERT의 성능 차이 측정
#
# 이유:
# - 단일 INSERT: 각 레코드마다 네트워크 roundtrip + WAL 쓰기 발생
# - 배치 INSERT: 여러 레코드를 하나의 트랜잭션으로 처리
#   → 네트워크 왕복 감소 (N번 → 1번)
#   → WAL 쓰기 횟수 감소 (commit이 한 번만 발생)
#   → 잠금 오버헤드 감소 (transaction begin/commit 1회)
#
# 예상 결과:
# - batch_size=1:   ~2,000 TPS
# - batch_size=100: ~8,000 TPS (약 4배 향상)
#
# ============================================================

set -e

WRITE_SERVER="http://localhost:8080"
TEST_DURATION=30  # 30초 테스트

echo "============================================================"
echo "테스트 1: 배치 INSERT 효과 검증"
echo "============================================================"
echo ""
echo "📌 테스트 목적:"
echo "   단일 INSERT vs 배치 INSERT의 TPS 차이 측정"
echo ""
echo "📌 왜 배치가 빠른가?"
echo "   1. 네트워크 왕복: 100번 → 1번"
echo "   2. WAL 쓰기: 100번 commit → 1번 commit"
echo "   3. 잠금 획득/해제: 100번 → 1번"
echo ""
echo "============================================================"
echo ""

# 메트릭 초기화
curl -s -X POST ${WRITE_SERVER}/metrics/reset > /dev/null 2>&1 || true

# ============================================================
# BEFORE: batch_size = 1 (단일 INSERT)
# ============================================================

echo "[1/2] BEFORE: batch_size = 1 (단일 INSERT)"
echo "------------------------------------------------------------"

# 설정
curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 0,
    \"batch_size\": 1,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

echo "설정: batch_size=1, workers=10, duration=${TEST_DURATION}s, TPS=무제한"
echo ""

# 테스트 시작
curl -s -X POST ${WRITE_SERVER}/load/start > /dev/null
echo "부하 생성 시작..."

# 중간 체크 (10초마다)
for i in 10 20 30; do
  sleep 10
  METRICS=$(curl -s ${WRITE_SERVER}/metrics)
  TPS=$(echo ${METRICS} | jq -r '.tps')
  TOTAL=$(echo ${METRICS} | jq -r '.total_requests')
  printf "  %2ds 경과: TPS=%.2f, 총 요청=%d\n" ${i} ${TPS} ${TOTAL}
done

# 최종 결과
echo ""
echo "📊 BEFORE 결과 (batch_size=1):"
BEFORE_METRICS=$(curl -s ${WRITE_SERVER}/metrics)

BEFORE_TPS=$(echo ${BEFORE_METRICS} | jq -r '.tps')
BEFORE_TOTAL=$(echo ${BEFORE_METRICS} | jq -r '.total_requests')
BEFORE_SUCCESS=$(echo ${BEFORE_METRICS} | jq -r '.success_requests')
BEFORE_FAILED=$(echo ${BEFORE_METRICS} | jq -r '.failed_requests')
BEFORE_AVG_LAT=$(echo ${BEFORE_METRICS} | jq -r '.avg_latency_ms')
BEFORE_P95_LAT=$(echo ${BEFORE_METRICS} | jq -r '.p95_latency_ms')
BEFORE_P99_LAT=$(echo ${BEFORE_METRICS} | jq -r '.p99_latency_ms')

printf "   TPS:           %.2f\n" ${BEFORE_TPS}
printf "   총 요청:       %d\n" ${BEFORE_TOTAL}
printf "   성공:          %d\n" ${BEFORE_SUCCESS}
printf "   실패:          %d\n" ${BEFORE_FAILED}
printf "   평균 지연시간: %.2f ms\n" ${BEFORE_AVG_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${BEFORE_P95_LAT}
printf "   P99 지연시간:  %.2f ms\n" ${BEFORE_P99_LAT}

echo ""
echo "============================================================"
echo ""

# 잠시 대기 (시스템 안정화)
sleep 5

# 메트릭 리셋
curl -s -X POST ${WRITE_SERVER}/metrics/reset > /dev/null

# ============================================================
# AFTER: batch_size = 100 (배치 INSERT)
# ============================================================

echo "[2/2] AFTER: batch_size = 100 (배치 INSERT)"
echo "------------------------------------------------------------"

# 설정
curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 0,
    \"batch_size\": 100,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

echo "설정: batch_size=100, workers=10, duration=${TEST_DURATION}s, TPS=무제한"
echo ""

# 테스트 시작
curl -s -X POST ${WRITE_SERVER}/load/start > /dev/null
echo "부하 생성 시작..."

# 중간 체크
for i in 10 20 30; do
  sleep 10
  METRICS=$(curl -s ${WRITE_SERVER}/metrics)
  TPS=$(echo ${METRICS} | jq -r '.tps')
  TOTAL=$(echo ${METRICS} | jq -r '.total_requests')
  printf "  %2ds 경과: TPS=%.2f, 총 요청=%d\n" ${i} ${TPS} ${TOTAL}
done

# 최종 결과
echo ""
echo "📊 AFTER 결과 (batch_size=100):"
AFTER_METRICS=$(curl -s ${WRITE_SERVER}/metrics)

AFTER_TPS=$(echo ${AFTER_METRICS} | jq -r '.tps')
AFTER_TOTAL=$(echo ${AFTER_METRICS} | jq -r '.total_requests')
AFTER_SUCCESS=$(echo ${AFTER_METRICS} | jq -r '.success_requests')
AFTER_FAILED=$(echo ${AFTER_METRICS} | jq -r '.failed_requests')
AFTER_AVG_LAT=$(echo ${AFTER_METRICS} | jq -r '.avg_latency_ms')
AFTER_P95_LAT=$(echo ${AFTER_METRICS} | jq -r '.p95_latency_ms')
AFTER_P99_LAT=$(echo ${AFTER_METRICS} | jq -r '.p99_latency_ms')

printf "   TPS:           %.2f\n" ${AFTER_TPS}
printf "   총 요청:       %d\n" ${AFTER_TOTAL}
printf "   성공:          %d\n" ${AFTER_SUCCESS}
printf "   실패:          %d\n" ${AFTER_FAILED}
printf "   평균 지연시간: %.2f ms\n" ${AFTER_AVG_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${AFTER_P95_LAT}
printf "   P99 지연시간:  %.2f ms\n" ${AFTER_P99_LAT}

echo ""
echo "============================================================"
echo "📈 비교 분석"
echo "============================================================"
echo ""

# TPS 향상률 계산
TPS_IMPROVEMENT=$(echo "scale=2; (${AFTER_TPS} / ${BEFORE_TPS} - 1) * 100" | bc)
printf "TPS 향상률:      %.2f%%\n" ${TPS_IMPROVEMENT}
printf "   BEFORE:       %.2f TPS\n" ${BEFORE_TPS}
printf "   AFTER:        %.2f TPS\n" ${AFTER_TPS}
printf "   향상 배수:    %.2fx\n" $(echo "scale=2; ${AFTER_TPS} / ${BEFORE_TPS}" | bc)

echo ""

# 처리량 비교
printf "총 처리량 비교:\n"
printf "   BEFORE:       %d requests\n" ${BEFORE_TOTAL}
printf "   AFTER:        %d requests\n" ${AFTER_TOTAL}
printf "   차이:         %d requests (+%.1f%%)\n" \
  $((${AFTER_TOTAL} - ${BEFORE_TOTAL})) \
  $(echo "scale=1; (${AFTER_TOTAL} - ${BEFORE_TOTAL}) * 100 / ${BEFORE_TOTAL}" | bc)

echo ""

# 지연시간 비교
printf "지연시간 비교:\n"
printf "   평균 - BEFORE: %.2f ms, AFTER: %.2f ms\n" ${BEFORE_AVG_LAT} ${AFTER_AVG_LAT}
printf "   P95  - BEFORE: %.2f ms, AFTER: %.2f ms\n" ${BEFORE_P95_LAT} ${AFTER_P95_LAT}
printf "   P99  - BEFORE: %.2f ms, AFTER: %.2f ms\n" ${BEFORE_P99_LAT} ${AFTER_P99_LAT}

echo ""
echo "============================================================"
echo "💡 결론"
echo "============================================================"
echo ""
echo "배치 INSERT를 사용하면:"
printf "  ✓ TPS가 %.2fx 향상됩니다\n" $(echo "scale=2; ${AFTER_TPS} / ${BEFORE_TPS}" | bc)
echo "  ✓ 네트워크 왕복 횟수가 1/100로 감소합니다"
echo "  ✓ WAL 쓰기 오버헤드가 1/100로 감소합니다"
echo "  ✓ 트랜잭션 begin/commit 비용이 1/100로 감소합니다"
echo ""
echo "권장 사항:"
echo "  • 대량 데이터 INSERT 시 반드시 배치 처리 사용"
echo "  • 적절한 batch_size: 100~1000 (메모리와 트레이드오프)"
echo "  • COPY 명령은 배치 INSERT보다 더 빠름 (고려해볼 것)"
echo ""
echo "테스트 완료!"
echo "============================================================"
