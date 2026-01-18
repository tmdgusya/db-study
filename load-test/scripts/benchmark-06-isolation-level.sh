#!/bin/bash

# ============================================================
# 테스트 6: 트랜잭션 격리 수준 효과 검증
# ============================================================
#
# 목적: READ COMMITTED vs REPEATABLE READ의 성능 차이 측정
#
# 배경지식:
# PostgreSQL의 트랜잭션 격리 수준:
# 1. READ UNCOMMITTED (미지원, READ COMMITTED로 동작)
# 2. READ COMMITTED (기본값)
# 3. REPEATABLE READ
# 4. SERIALIZABLE
#
# READ COMMITTED:
# - 각 쿼리마다 새로운 스냅샷 생성
# - 커밋된 최신 데이터 읽음
# - 오버헤드: 작음 (스냅샷 생성 빠름)
# - 동시성: 높음 (잠금 경합 적음)
# - 일관성: 낮음 (Phantom Read 발생 가능)
#
# REPEATABLE READ:
# - 트랜잭션 시작 시 스냅샷 생성, 이후 계속 사용
# - 트랜잭션 시작 시점의 일관된 데이터 읽음
# - 오버헤드: 중간 (스냅샷 유지 비용)
# - 동시성: 중간 (Serialization Failure 가능)
# - 일관성: 높음 (Phantom Read 방지)
#
# 성능 차이가 나는 이유:
# 1. 스냅샷 관리 비용
#    - READ COMMITTED: 쿼리마다 새 스냅샷 (빠름)
#    - REPEATABLE READ: 트랜잭션 전체에서 하나의 스냅샷 (오버헤드)
#
# 2. 잠금 경합
#    - READ COMMITTED: 행 단위 잠금, 빨리 해제
#    - REPEATABLE READ: 트랜잭션 종료까지 유지, Serialization Failure
#
# 3. Tuple Visibility 체크
#    - REPEATABLE READ가 더 복잡한 visibility 로직
#
# 언제 REPEATABLE READ를 사용할까?
# - 금융 거래 (잔액 조회 → 출금, 일관성 필요)
# - 보고서 생성 (전체 데이터가 일관된 시점이어야 함)
# - 배치 작업 (여러 단계가 동일한 데이터 기준)
#
# 언제 READ COMMITTED를 사용할까?
# - 단순 CRUD 작업
# - 최신 데이터가 중요한 경우
# - 높은 동시성이 필요한 경우
#
# 예상 결과:
# - READ COMMITTED:  ~8,000 TPS (빠름, 동시성 높음)
# - REPEATABLE READ: ~7,000 TPS (약간 느림, 일관성 높음)
#
# ============================================================

set -e

WRITE_SERVER="http://localhost:8080"
READ_SERVER="http://localhost:8081"
TEST_DURATION=30

echo "============================================================"
echo "테스트 6: 트랜잭션 격리 수준 효과 검증"
echo "============================================================"
echo ""
echo "📌 테스트 목적:"
echo "   READ COMMITTED vs REPEATABLE READ 성능 비교"
echo ""
echo "📌 READ COMMITTED (기본값)"
echo "   • 각 쿼리마다 새 스냅샷 생성"
echo "   • 커밋된 최신 데이터 읽음"
echo "   • Non-Repeatable Read, Phantom Read 발생 가능"
echo "   • 높은 동시성, 낮은 오버헤드"
echo ""
echo "📌 REPEATABLE READ"
echo "   • 트랜잭션 시작 시 스냅샷 생성"
echo "   • 트랜잭션 전체에서 동일 데이터 보장"
echo "   • Phantom Read 방지"
echo "   • Serialization Failure 발생 가능"
echo "   • 약간 낮은 동시성, 중간 오버헤드"
echo ""
echo "📌 성능 차이 원인:"
echo "   1. 스냅샷 관리 비용"
echo "   2. Tuple Visibility 체크 복잡도"
echo "   3. 잠금 경합 및 Serialization Failure"
echo ""
echo "============================================================"
echo ""

# ============================================================
# 쓰기 워크로드 테스트
# ============================================================

echo "============================================================"
echo "Part 1: 쓰기 워크로드 (INSERT)"
echo "============================================================"
echo ""

# 메트릭 초기화
curl -s -X POST ${WRITE_SERVER}/metrics/reset > /dev/null 2>&1 || true

echo "[1/2] READ COMMITTED (쓰기)"
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

echo "설정: READ COMMITTED, batch_size=100, workers=10"
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
echo "📊 READ COMMITTED 쓰기 결과:"
RC_WRITE_METRICS=$(curl -s ${WRITE_SERVER}/metrics)

RC_WRITE_TPS=$(echo ${RC_WRITE_METRICS} | jq -r '.tps')
RC_WRITE_TOTAL=$(echo ${RC_WRITE_METRICS} | jq -r '.total_requests')
RC_WRITE_AVG_LAT=$(echo ${RC_WRITE_METRICS} | jq -r '.avg_latency_ms')
RC_WRITE_P95=$(echo ${RC_WRITE_METRICS} | jq -r '.p95_latency_ms')

printf "   TPS:           %.2f\n" ${RC_WRITE_TPS}
printf "   총 요청:       %d\n" ${RC_WRITE_TOTAL}
printf "   평균 지연시간: %.2f ms\n" ${RC_WRITE_AVG_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${RC_WRITE_P95}

echo ""
sleep 5

# 메트릭 리셋
curl -s -X POST ${WRITE_SERVER}/metrics/reset > /dev/null

echo "[2/2] REPEATABLE READ (쓰기)"
echo "------------------------------------------------------------"

# 설정
curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 0,
    \"batch_size\": 100,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"isolation_level\": \"REPEATABLE READ\"
  }" > /dev/null

echo "설정: REPEATABLE READ, batch_size=100, workers=10"
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
  FAILED=$(echo ${METRICS} | jq -r '.failed_requests')
  printf "  %2ds 경과: TPS=%.2f, 총 요청=%d, 실패=%d\n" ${i} ${TPS} ${TOTAL} ${FAILED}
done

# 최종 결과
echo ""
echo "📊 REPEATABLE READ 쓰기 결과:"
RR_WRITE_METRICS=$(curl -s ${WRITE_SERVER}/metrics)

RR_WRITE_TPS=$(echo ${RR_WRITE_METRICS} | jq -r '.tps')
RR_WRITE_TOTAL=$(echo ${RR_WRITE_METRICS} | jq -r '.total_requests')
RR_WRITE_FAILED=$(echo ${RR_WRITE_METRICS} | jq -r '.failed_requests')
RR_WRITE_AVG_LAT=$(echo ${RR_WRITE_METRICS} | jq -r '.avg_latency_ms')
RR_WRITE_P95=$(echo ${RR_WRITE_METRICS} | jq -r '.p95_latency_ms')

printf "   TPS:           %.2f\n" ${RR_WRITE_TPS}
printf "   총 요청:       %d\n" ${RR_WRITE_TOTAL}
printf "   실패:          %d (Serialization Failure)\n" ${RR_WRITE_FAILED}
printf "   평균 지연시간: %.2f ms\n" ${RR_WRITE_AVG_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${RR_WRITE_P95}

echo ""
echo "------------------------------------------------------------"
echo "쓰기 워크로드 비교:"
printf "   TPS - RC: %.2f, RR: %.2f (%.1f%% 차이)\n" \
  ${RC_WRITE_TPS} ${RR_WRITE_TPS} \
  $(echo "scale=1; (${RC_WRITE_TPS} - ${RR_WRITE_TPS}) * 100 / ${RC_WRITE_TPS}" | bc)

if [ ${RR_WRITE_FAILED} -gt 0 ]; then
  printf "   ⚠️  REPEATABLE READ에서 %d건의 Serialization Failure 발생!\n" ${RR_WRITE_FAILED}
fi

echo ""
echo "============================================================"
echo ""

sleep 5

# ============================================================
# 읽기 워크로드 테스트
# ============================================================

echo "============================================================"
echo "Part 2: 읽기 워크로드 (SELECT)"
echo "============================================================"
echo ""

# 메트릭 초기화
curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null 2>&1 || true

echo "[1/2] READ COMMITTED (읽기)"
echo "------------------------------------------------------------"

# 설정
curl -s -X POST ${READ_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"qps\": 0,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"query_mix\": {
      \"simple\": 40,
      \"filter\": 40,
      \"aggregate\": 20
    },
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

echo "설정: READ COMMITTED, workers=10, 혼합 쿼리"
echo ""

# 테스트 시작
curl -s -X POST ${READ_SERVER}/load/start > /dev/null
echo "부하 생성 시작..."

# 중간 체크
for i in 10 20 30; do
  sleep 10
  METRICS=$(curl -s ${READ_SERVER}/metrics)
  QPS=$(echo ${METRICS} | jq -r '.qps')
  TOTAL=$(echo ${METRICS} | jq -r '.total_requests')
  printf "  %2ds 경과: QPS=%.2f, 총 요청=%d\n" ${i} ${QPS} ${TOTAL}
done

# 최종 결과
echo ""
echo "📊 READ COMMITTED 읽기 결과:"
RC_READ_METRICS=$(curl -s ${READ_SERVER}/metrics)

RC_READ_QPS=$(echo ${RC_READ_METRICS} | jq -r '.qps')
RC_READ_TOTAL=$(echo ${RC_READ_METRICS} | jq -r '.total_requests')
RC_READ_AVG_LAT=$(echo ${RC_READ_METRICS} | jq -r '.avg_latency_ms')
RC_READ_P95=$(echo ${RC_READ_METRICS} | jq -r '.p95_latency_ms')

printf "   QPS:           %.2f\n" ${RC_READ_QPS}
printf "   총 요청:       %d\n" ${RC_READ_TOTAL}
printf "   평균 지연시간: %.2f ms\n" ${RC_READ_AVG_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${RC_READ_P95}

echo ""
sleep 5

# 메트릭 리셋
curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null

echo "[2/2] REPEATABLE READ (읽기)"
echo "------------------------------------------------------------"

# 설정
curl -s -X POST ${READ_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"qps\": 0,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"query_mix\": {
      \"simple\": 40,
      \"filter\": 40,
      \"aggregate\": 20
    },
    \"isolation_level\": \"REPEATABLE READ\"
  }" > /dev/null

echo "설정: REPEATABLE READ, workers=10, 혼합 쿼리"
echo ""

# 테스트 시작
curl -s -X POST ${READ_SERVER}/load/start > /dev/null
echo "부하 생성 시작..."

# 중간 체크
for i in 10 20 30; do
  sleep 10
  METRICS=$(curl -s ${READ_SERVER}/metrics)
  QPS=$(echo ${METRICS} | jq -r '.qps')
  TOTAL=$(echo ${METRICS} | jq -r '.total_requests')
  printf "  %2ds 경과: QPS=%.2f, 총 요청=%d\n" ${i} ${QPS} ${TOTAL}
done

# 최종 결과
echo ""
echo "📊 REPEATABLE READ 읽기 결과:"
RR_READ_METRICS=$(curl -s ${READ_SERVER}/metrics)

RR_READ_QPS=$(echo ${RR_READ_METRICS} | jq -r '.qps')
RR_READ_TOTAL=$(echo ${RR_READ_METRICS} | jq -r '.total_requests')
RR_READ_AVG_LAT=$(echo ${RR_READ_METRICS} | jq -r '.avg_latency_ms')
RR_READ_P95=$(echo ${RR_READ_METRICS} | jq -r '.p95_latency_ms')

printf "   QPS:           %.2f\n" ${RR_READ_QPS}
printf "   총 요청:       %d\n" ${RR_READ_TOTAL}
printf "   평균 지연시간: %.2f ms\n" ${RR_READ_AVG_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${RR_READ_P95}

echo ""
echo "------------------------------------------------------------"
echo "읽기 워크로드 비교:"
printf "   QPS - RC: %.2f, RR: %.2f (%.1f%% 차이)\n" \
  ${RC_READ_QPS} ${RR_READ_QPS} \
  $(echo "scale=1; (${RC_READ_QPS} - ${RR_READ_QPS}) * 100 / ${RC_READ_QPS}" | bc)

echo ""
echo "============================================================"
echo "📈 종합 비교 분석"
echo "============================================================"
echo ""

echo "쓰기 성능:"
printf "   READ COMMITTED:  %.2f TPS\n" ${RC_WRITE_TPS}
printf "   REPEATABLE READ: %.2f TPS (%.1f%%)\n" \
  ${RR_WRITE_TPS} \
  $(echo "scale=1; ${RR_WRITE_TPS} * 100 / ${RC_WRITE_TPS}" | bc)

echo ""

echo "읽기 성능:"
printf "   READ COMMITTED:  %.2f QPS\n" ${RC_READ_QPS}
printf "   REPEATABLE READ: %.2f QPS (%.1f%%)\n" \
  ${RR_READ_QPS} \
  $(echo "scale=1; ${RR_READ_QPS} * 100 / ${RC_READ_QPS}" | bc)

echo ""
echo "============================================================"
echo "💡 결론"
echo "============================================================"
echo ""

echo "성능 차이:"
echo "  • 쓰기: READ COMMITTED가 약간 빠름"
echo "  • 읽기: 큰 차이 없음 (워크로드에 따라 다름)"
echo "  • REPEATABLE READ는 Serialization Failure 발생 가능"
echo ""

echo "✅ READ COMMITTED 사용 권장:"
echo "  • 단순 CRUD 작업"
echo "  • 높은 동시성이 필요한 경우"
echo "  • 최신 데이터가 중요한 경우"
echo "  • API 서버, 웹 애플리케이션"
echo ""

echo "✅ REPEATABLE READ 사용 권장:"
echo "  • 복잡한 비즈니스 로직 (여러 단계 조회)"
echo "  • 일관된 데이터 스냅샷 필요"
echo "  • 금융 거래 (잔액 조회 → 출금)"
echo "  • 보고서 생성, 배치 작업"
echo ""

echo "⚠️  REPEATABLE READ 주의사항:"
echo "  • Serialization Failure 처리 필요 (재시도 로직)"
echo "  • 장시간 트랜잭션은 피할 것"
echo "  • 동시 쓰기가 많으면 경합 증가"
echo ""

echo "🔥 실무 팁:"
echo "  • 기본은 READ COMMITTED 사용"
echo "  • 필요한 경우에만 REPEATABLE READ"
echo "  • 트랜잭션은 최대한 짧게 유지"
echo "  • Serialization Failure는 애플리케이션에서 재시도"
echo ""

echo "테스트 완료!"
echo "============================================================"
