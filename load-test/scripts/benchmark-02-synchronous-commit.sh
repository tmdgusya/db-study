#!/bin/bash

# ============================================================
# 테스트 2: synchronous_commit 효과 검증
# ============================================================
#
# 목적: synchronous_commit on vs off의 쓰기 성능 차이 측정
#
# 이유:
# - synchronous_commit = on (기본값)
#   → 트랜잭션 commit 시 WAL을 디스크에 fsync()로 강제 flush
#   → 데이터 내구성 보장 (서버 크래시 시에도 데이터 손실 없음)
#   → 하지만 매 commit마다 디스크 I/O 대기 → 느림
#
# - synchronous_commit = off
#   → WAL을 OS 버퍼 캐시에만 쓰고 즉시 리턴
#   → fsync()는 백그라운드에서 비동기 처리
#   → 서버 크래시 시 최대 3초치 데이터 손실 가능
#   → 하지만 디스크 I/O 대기 없음 → 매우 빠름
#
# 언제 사용?
# - synchronous_commit = off
#   → 로그 수집, 분석 데이터, 캐시 등 (손실 허용 가능한 데이터)
#   → 대량 배치 작업 (나중에 CHECKPOINT로 일괄 flush)
#
# - synchronous_commit = on
#   → 금융 거래, 주문, 결제 등 (절대 손실 불가능한 데이터)
#
# 예상 결과:
# - synchronous_commit = on:  ~5,000 TPS
# - synchronous_commit = off: ~12,000 TPS (약 2.5배 향상)
#
# ============================================================

set -e

WRITE_SERVER="http://localhost:8080"
DB_CONTAINER="loadtest-postgres"
TEST_DURATION=30

echo "============================================================"
echo "테스트 2: synchronous_commit 효과 검증"
echo "============================================================"
echo ""
echo "📌 테스트 목적:"
echo "   WAL fsync 대기 여부에 따른 TPS 차이 측정"
echo ""
echo "📌 synchronous_commit = on (기본값)"
echo "   • 매 commit마다 WAL을 디스크에 fsync()"
echo "   • 데이터 손실 위험 0% (서버 크래시에도 안전)"
echo "   • 하지만 디스크 I/O 대기로 인해 느림"
echo ""
echo "📌 synchronous_commit = off"
echo "   • WAL을 OS 캐시에만 쓰고 즉시 리턴"
echo "   • fsync는 백그라운드에서 비동기 처리"
echo "   • 서버 크래시 시 최대 3초치 데이터 손실 가능"
echo "   • 디스크 I/O 대기 없음 → 매우 빠름"
echo ""
echo "📌 사용 시나리오:"
echo "   • OFF: 로그 수집, 분석 데이터, 세션 캐시"
echo "   • ON:  금융 거래, 주문, 결제 데이터"
echo ""
echo "============================================================"
echo ""

# 메트릭 초기화
curl -s -X POST ${WRITE_SERVER}/metrics/reset > /dev/null 2>&1 || true

# ============================================================
# BEFORE: synchronous_commit = on (기본값)
# ============================================================

echo "[1/2] BEFORE: synchronous_commit = on (안전, 느림)"
echo "------------------------------------------------------------"

# PostgreSQL 설정 확인
CURRENT_SETTING=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SHOW synchronous_commit;" | xargs)
echo "현재 설정: synchronous_commit = ${CURRENT_SETTING}"

# on으로 설정 (기본값이지만 명시적으로)
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "ALTER SYSTEM SET synchronous_commit = on;" > /dev/null
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "SELECT pg_reload_conf();" > /dev/null
sleep 2

echo "설정 변경: synchronous_commit = on"
echo ""

# 부하 설정 (배치 100 사용 - 배치 효과는 이미 검증했으므로)
curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 0,
    \"batch_size\": 100,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

echo "부하 설정: batch_size=100, workers=10, duration=${TEST_DURATION}s"
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
echo "📊 BEFORE 결과 (synchronous_commit = on):"
BEFORE_METRICS=$(curl -s ${WRITE_SERVER}/metrics)

BEFORE_TPS=$(echo ${BEFORE_METRICS} | jq -r '.tps')
BEFORE_TOTAL=$(echo ${BEFORE_METRICS} | jq -r '.total_requests')
BEFORE_SUCCESS=$(echo ${BEFORE_METRICS} | jq -r '.success_requests')
BEFORE_AVG_LAT=$(echo ${BEFORE_METRICS} | jq -r '.avg_latency_ms')
BEFORE_P95_LAT=$(echo ${BEFORE_METRICS} | jq -r '.p95_latency_ms')
BEFORE_P99_LAT=$(echo ${BEFORE_METRICS} | jq -r '.p99_latency_ms')

printf "   TPS:           %.2f\n" ${BEFORE_TPS}
printf "   총 요청:       %d\n" ${BEFORE_TOTAL}
printf "   성공:          %d\n" ${BEFORE_SUCCESS}
printf "   평균 지연시간: %.2f ms\n" ${BEFORE_AVG_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${BEFORE_P95_LAT}
printf "   P99 지연시간:  %.2f ms\n" ${BEFORE_P99_LAT}

echo ""
echo "============================================================"
echo ""

# 잠시 대기
sleep 5

# 메트릭 리셋
curl -s -X POST ${WRITE_SERVER}/metrics/reset > /dev/null

# ============================================================
# AFTER: synchronous_commit = off
# ============================================================

echo "[2/2] AFTER: synchronous_commit = off (빠름, 약간 위험)"
echo "------------------------------------------------------------"

# off로 설정
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "ALTER SYSTEM SET synchronous_commit = off;" > /dev/null
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "SELECT pg_reload_conf();" > /dev/null
sleep 2

CURRENT_SETTING=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SHOW synchronous_commit;" | xargs)
echo "설정 변경: synchronous_commit = ${CURRENT_SETTING}"
echo ""

# 부하 설정 (동일한 조건)
curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 0,
    \"batch_size\": 100,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

echo "부하 설정: batch_size=100, workers=10, duration=${TEST_DURATION}s"
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
echo "📊 AFTER 결과 (synchronous_commit = off):"
AFTER_METRICS=$(curl -s ${WRITE_SERVER}/metrics)

AFTER_TPS=$(echo ${AFTER_METRICS} | jq -r '.tps')
AFTER_TOTAL=$(echo ${AFTER_METRICS} | jq -r '.total_requests')
AFTER_SUCCESS=$(echo ${AFTER_METRICS} | jq -r '.success_requests')
AFTER_AVG_LAT=$(echo ${AFTER_METRICS} | jq -r '.avg_latency_ms')
AFTER_P95_LAT=$(echo ${AFTER_METRICS} | jq -r '.p95_latency_ms')
AFTER_P99_LAT=$(echo ${AFTER_METRICS} | jq -r '.p99_latency_ms')

printf "   TPS:           %.2f\n" ${AFTER_TPS}
printf "   총 요청:       %d\n" ${AFTER_TOTAL}
printf "   성공:          %d\n" ${AFTER_SUCCESS}
printf "   평균 지연시간: %.2f ms\n" ${AFTER_AVG_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${AFTER_P95_LAT}
printf "   P99 지연시간:  %.2f ms\n" ${AFTER_P99_LAT}

echo ""
echo "============================================================"
echo "📈 비교 분석"
echo "============================================================"
echo ""

# TPS 향상률
TPS_IMPROVEMENT=$(echo "scale=2; (${AFTER_TPS} / ${BEFORE_TPS} - 1) * 100" | bc)
printf "TPS 향상률:      %.2f%%\n" ${TPS_IMPROVEMENT}
printf "   ON (안전):    %.2f TPS\n" ${BEFORE_TPS}
printf "   OFF (빠름):   %.2f TPS\n" ${AFTER_TPS}
printf "   향상 배수:    %.2fx\n" $(echo "scale=2; ${AFTER_TPS} / ${BEFORE_TPS}" | bc)

echo ""

# 처리량 비교
printf "총 처리량 비교:\n"
printf "   ON:           %d requests\n" ${BEFORE_TOTAL}
printf "   OFF:          %d requests\n" ${AFTER_TOTAL}
printf "   차이:         %d requests (+%.1f%%)\n" \
  $((${AFTER_TOTAL} - ${BEFORE_TOTAL})) \
  $(echo "scale=1; (${AFTER_TOTAL} - ${BEFORE_TOTAL}) * 100 / ${BEFORE_TOTAL}" | bc)

echo ""

# 지연시간 비교
printf "지연시간 비교:\n"
printf "   평균 - ON: %.2f ms, OFF: %.2f ms (%.1f%% 감소)\n" \
  ${BEFORE_AVG_LAT} ${AFTER_AVG_LAT} \
  $(echo "scale=1; (${BEFORE_AVG_LAT} - ${AFTER_AVG_LAT}) * 100 / ${BEFORE_AVG_LAT}" | bc)
printf "   P95  - ON: %.2f ms, OFF: %.2f ms\n" ${BEFORE_P95_LAT} ${AFTER_P95_LAT}
printf "   P99  - ON: %.2f ms, OFF: %.2f ms\n" ${BEFORE_P99_LAT} ${AFTER_P99_LAT}

echo ""
echo "============================================================"
echo "💡 결론"
echo "============================================================"
echo ""
echo "synchronous_commit = off 사용 시:"
printf "  ✓ TPS가 %.2fx 향상됩니다\n" $(echo "scale=2; ${AFTER_TPS} / ${BEFORE_TPS}" | bc)
echo "  ✓ 디스크 fsync() 대기 시간이 사라집니다"
echo "  ✓ 지연시간이 크게 감소합니다"
echo ""
echo "⚠️  주의사항:"
echo "  • 서버 크래시 시 최대 3초치 데이터 손실 가능"
echo "  • OS 크래시나 전원 차단 시에는 손실 위험"
echo "  • 복제본(replica)에는 영향 없음 (wal_sender는 별도)"
echo ""
echo "✅ 권장 사용 케이스:"
echo "  • 로그 수집 시스템 (ELK, Splunk 등)"
echo "  • 분석용 데이터 적재"
echo "  • 세션 스토어, 캐시"
echo "  • 임시 작업 테이블"
echo ""
echo "❌ 사용 금지 케이스:"
echo "  • 금융 거래 (결제, 송금, 주문)"
echo "  • 사용자 데이터 (회원 정보, 비밀번호)"
echo "  • 법적 요구사항이 있는 데이터 (감사 로그 등)"
echo ""

# 설정 원복
echo "------------------------------------------------------------"
echo "설정 원복 중..."
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "ALTER SYSTEM SET synchronous_commit = on;" > /dev/null
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "SELECT pg_reload_conf();" > /dev/null
echo "synchronous_commit을 on으로 복원했습니다."
echo ""
echo "테스트 완료!"
echo "============================================================"
