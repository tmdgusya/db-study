#!/bin/bash

# ============================================================
# 테스트 3: 인덱스 효과 검증 (읽기 성능)
# ============================================================
#
# 목적: 인덱스 유무에 따른 SELECT 쿼리 성능 차이 측정
#
# 이유:
# - 인덱스 없음: Full Table Scan
#   → WHERE level = 'ERROR' 조회 시 전체 테이블 스캔
#   → 10만 건 테이블에서 1000건 찾기: 10만 건 전부 읽음
#   → O(N) 시간 복잡도
#
# - 인덱스 있음: Index Scan
#   → B-tree 인덱스로 빠르게 탐색
#   → 10만 건 테이블에서 1000건 찾기: 약 log₂(100000) + 1000 = 약 1017번 읽음
#   → O(log N + M) 시간 복잡도 (M = 결과 개수)
#
# 인덱스가 효과적인 경우:
# - 선택도(Selectivity)가 높을 때 (< 5%)
#   예: WHERE user_id = 123 (전체의 0.001%)
# - 자주 조회되는 컬럼
# - 정렬(ORDER BY), 조인(JOIN)에 사용되는 컬럼
#
# 인덱스가 비효과적인 경우:
# - 선택도가 낮을 때 (> 20%)
#   예: WHERE gender = 'M' (전체의 50%)
# - 전체 테이블의 대부분을 읽어야 하는 경우
#
# 예상 결과:
# - 인덱스 없음: 평균 지연시간 ~500ms (Full Scan)
# - 인덱스 있음: 평균 지연시간 ~10ms (Index Scan, 50배 빠름)
#
# ============================================================

set -e

READ_SERVER="http://localhost:8081"
DB_CONTAINER="loadtest-postgres"
TEST_DURATION=30

echo "============================================================"
echo "테스트 3: 인덱스 효과 검증"
echo "============================================================"
echo ""
echo "📌 테스트 목적:"
echo "   WHERE level = 'ERROR' 필터 쿼리의 성능 측정"
echo ""
echo "📌 인덱스 없음 (Full Table Scan)"
echo "   • PostgreSQL이 전체 테이블을 순차적으로 읽음"
echo "   • 100만 건 중 10% (10만 건) 찾기 = 100만 건 전부 읽음"
echo "   • 디스크 I/O가 많아 매우 느림"
echo ""
echo "📌 인덱스 있음 (Index Scan)"
echo "   • B-tree 인덱스로 필요한 행만 빠르게 찾음"
echo "   • log₂(1000000) + 100000 = 약 100020번 읽음"
echo "   • 랜덤 I/O지만 적은 양이라 빠름"
echo ""
echo "📌 인덱스 효과가 큰 경우:"
echo "   • 선택도 < 5% (전체의 5% 미만 조회)"
echo "   • 자주 사용되는 WHERE, JOIN, ORDER BY 컬럼"
echo ""
echo "📌 인덱스 효과가 작은 경우:"
echo "   • 선택도 > 20% (전체의 20% 이상 조회)"
echo "   • Full Scan이 더 빠를 수 있음"
echo ""
echo "============================================================"
echo ""

# 현재 데이터 개수 확인
TOTAL_ROWS=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SELECT COUNT(*) FROM logs;" | xargs)
echo "현재 logs 테이블 행 개수: ${TOTAL_ROWS}"
echo ""

# 추가 데이터 삽입 (성능 차이를 명확히 하기 위해)
if [ ${TOTAL_ROWS} -lt 100000 ]; then
  echo "성능 차이를 명확히 하기 위해 데이터를 10만 건으로 증가시킵니다..."
  docker exec ${DB_CONTAINER} psql -U postgres -d loadtest > /dev/null 2>&1 <<EOF
INSERT INTO logs (level, service, message, metadata)
SELECT
    (ARRAY['INFO', 'WARN', 'ERROR', 'DEBUG'])[floor(random() * 4 + 1)],
    (ARRAY['auth', 'api', 'worker', 'scheduler'])[floor(random() * 4 + 1)],
    'Load test message ' || generate_series,
    jsonb_build_object('request_id', generate_series::text)
FROM generate_series(1, $((100000 - ${TOTAL_ROWS})));
ANALYZE logs;
EOF
  TOTAL_ROWS=100000
  echo "데이터 삽입 완료: ${TOTAL_ROWS} 행"
  echo ""
fi

# level 분포 확인
echo "level 컬럼 분포:"
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
SELECT level, COUNT(*) as count,
       ROUND(COUNT(*) * 100.0 / ${TOTAL_ROWS}, 2) as percentage
FROM logs
GROUP BY level
ORDER BY count DESC;
"
echo ""

# 메트릭 초기화
curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null 2>&1 || true

# ============================================================
# BEFORE: 인덱스 제거 (Full Table Scan)
# ============================================================

echo "[1/2] BEFORE: 인덱스 없음 (Full Table Scan)"
echo "------------------------------------------------------------"

# 기존 인덱스 제거
echo "idx_logs_level 인덱스 제거 중..."
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "DROP INDEX IF EXISTS idx_logs_level;" > /dev/null
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "DROP INDEX IF EXISTS idx_logs_service;" > /dev/null
echo "인덱스 제거 완료"
echo ""

# 쿼리 플랜 확인
echo "쿼리 실행 계획 (인덱스 없음):"
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
EXPLAIN ANALYZE
SELECT id, timestamp, level, service, message
FROM logs
WHERE level = 'ERROR'
LIMIT 100;
" | grep -E "(Seq Scan|Index|Planning|Execution)" || true
echo ""

# 부하 설정 (Filter 쿼리 100%)
curl -s -X POST ${READ_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"qps\": 0,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"query_mix\": {
      \"simple\": 0,
      \"filter\": 100,
      \"aggregate\": 0
    },
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

echo "부하 설정: Filter 쿼리 100%, workers=10, duration=${TEST_DURATION}s"
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
  AVG_LAT=$(echo ${METRICS} | jq -r '.avg_latency_ms')
  printf "  %2ds 경과: QPS=%.2f, 총 요청=%d, 평균 지연시간=%.2fms\n" ${i} ${QPS} ${TOTAL} ${AVG_LAT}
done

# 최종 결과
echo ""
echo "📊 BEFORE 결과 (인덱스 없음):"
BEFORE_METRICS=$(curl -s ${READ_SERVER}/metrics)

BEFORE_QPS=$(echo ${BEFORE_METRICS} | jq -r '.qps')
BEFORE_TOTAL=$(echo ${BEFORE_METRICS} | jq -r '.total_requests')
BEFORE_SUCCESS=$(echo ${BEFORE_METRICS} | jq -r '.success_requests')
BEFORE_AVG_LAT=$(echo ${BEFORE_METRICS} | jq -r '.avg_latency_ms')
BEFORE_P50_LAT=$(echo ${BEFORE_METRICS} | jq -r '.p50_latency_ms')
BEFORE_P95_LAT=$(echo ${BEFORE_METRICS} | jq -r '.p95_latency_ms')
BEFORE_P99_LAT=$(echo ${BEFORE_METRICS} | jq -r '.p99_latency_ms')

printf "   QPS:           %.2f\n" ${BEFORE_QPS}
printf "   총 요청:       %d\n" ${BEFORE_TOTAL}
printf "   성공:          %d\n" ${BEFORE_SUCCESS}
printf "   평균 지연시간: %.2f ms\n" ${BEFORE_AVG_LAT}
printf "   P50 지연시간:  %.2f ms\n" ${BEFORE_P50_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${BEFORE_P95_LAT}
printf "   P99 지연시간:  %.2f ms\n" ${BEFORE_P99_LAT}

echo ""
echo "============================================================"
echo ""

# 잠시 대기
sleep 5

# 메트릭 리셋
curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null

# ============================================================
# AFTER: 인덱스 생성 (Index Scan)
# ============================================================

echo "[2/2] AFTER: 인덱스 생성 (Index Scan)"
echo "------------------------------------------------------------"

# 인덱스 생성
echo "idx_logs_level, idx_logs_service 인덱스 생성 중..."
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest > /dev/null <<EOF
CREATE INDEX idx_logs_level ON logs(level);
CREATE INDEX idx_logs_service ON logs(service);
ANALYZE logs;
EOF
echo "인덱스 생성 완료"
echo ""

# 쿼리 플랜 확인
echo "쿼리 실행 계획 (인덱스 있음):"
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
EXPLAIN ANALYZE
SELECT id, timestamp, level, service, message
FROM logs
WHERE level = 'ERROR'
LIMIT 100;
" | grep -E "(Seq Scan|Index|Bitmap|Planning|Execution)" || true
echo ""

# 부하 설정 (동일 조건)
curl -s -X POST ${READ_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"qps\": 0,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"query_mix\": {
      \"simple\": 0,
      \"filter\": 100,
      \"aggregate\": 0
    },
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

echo "부하 설정: Filter 쿼리 100%, workers=10, duration=${TEST_DURATION}s"
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
  AVG_LAT=$(echo ${METRICS} | jq -r '.avg_latency_ms')
  printf "  %2ds 경과: QPS=%.2f, 총 요청=%d, 평균 지연시간=%.2fms\n" ${i} ${QPS} ${TOTAL} ${AVG_LAT}
done

# 최종 결과
echo ""
echo "📊 AFTER 결과 (인덱스 있음):"
AFTER_METRICS=$(curl -s ${READ_SERVER}/metrics)

AFTER_QPS=$(echo ${AFTER_METRICS} | jq -r '.qps')
AFTER_TOTAL=$(echo ${AFTER_METRICS} | jq -r '.total_requests')
AFTER_SUCCESS=$(echo ${AFTER_METRICS} | jq -r '.success_requests')
AFTER_AVG_LAT=$(echo ${AFTER_METRICS} | jq -r '.avg_latency_ms')
AFTER_P50_LAT=$(echo ${AFTER_METRICS} | jq -r '.p50_latency_ms')
AFTER_P95_LAT=$(echo ${AFTER_METRICS} | jq -r '.p95_latency_ms')
AFTER_P99_LAT=$(echo ${AFTER_METRICS} | jq -r '.p99_latency_ms')

printf "   QPS:           %.2f\n" ${AFTER_QPS}
printf "   총 요청:       %d\n" ${AFTER_TOTAL}
printf "   성공:          %d\n" ${AFTER_SUCCESS}
printf "   평균 지연시간: %.2f ms\n" ${AFTER_AVG_LAT}
printf "   P50 지연시간:  %.2f ms\n" ${AFTER_P50_LAT}
printf "   P95 지연시간:  %.2f ms\n" ${AFTER_P95_LAT}
printf "   P99 지연시간:  %.2f ms\n" ${AFTER_P99_LAT}

echo ""
echo "============================================================"
echo "📈 비교 분석"
echo "============================================================"
echo ""

# QPS 향상률
QPS_IMPROVEMENT=$(echo "scale=2; (${AFTER_QPS} / ${BEFORE_QPS} - 1) * 100" | bc)
printf "QPS 향상률:      %.2f%%\n" ${QPS_IMPROVEMENT}
printf "   BEFORE:       %.2f QPS\n" ${BEFORE_QPS}
printf "   AFTER:        %.2f QPS\n" ${AFTER_QPS}
printf "   향상 배수:    %.2fx\n" $(echo "scale=2; ${AFTER_QPS} / ${BEFORE_QPS}" | bc)

echo ""

# 지연시간 개선
LAT_IMPROVEMENT=$(echo "scale=2; (${BEFORE_AVG_LAT} - ${AFTER_AVG_LAT}) * 100 / ${BEFORE_AVG_LAT}" | bc)
printf "지연시간 개선:   %.2f%%\n" ${LAT_IMPROVEMENT}
printf "   평균 - BEFORE: %.2f ms → AFTER: %.2f ms (%.2fx 빠름)\n" \
  ${BEFORE_AVG_LAT} ${AFTER_AVG_LAT} \
  $(echo "scale=2; ${BEFORE_AVG_LAT} / ${AFTER_AVG_LAT}" | bc)
printf "   P95  - BEFORE: %.2f ms → AFTER: %.2f ms\n" ${BEFORE_P95_LAT} ${AFTER_P95_LAT}
printf "   P99  - BEFORE: %.2f ms → AFTER: %.2f ms\n" ${BEFORE_P99_LAT} ${AFTER_P99_LAT}

echo ""
echo "============================================================"
echo "💡 결론"
echo "============================================================"
echo ""
echo "인덱스 생성 시:"
printf "  ✓ QPS가 %.2fx 향상됩니다\n" $(echo "scale=2; ${AFTER_QPS} / ${BEFORE_QPS}" | bc)
printf "  ✓ 지연시간이 %.2fx 감소합니다\n" $(echo "scale=2; ${BEFORE_AVG_LAT} / ${AFTER_AVG_LAT}" | bc)
echo "  ✓ Full Table Scan → Index Scan으로 변경"
echo "  ✓ 읽어야 하는 블록 수가 획기적으로 감소"
echo ""
echo "✅ 인덱스를 만들어야 하는 경우:"
echo "  • WHERE 절에 자주 사용되는 컬럼"
echo "  • 선택도가 높은 컬럼 (< 5%)"
echo "  • JOIN, ORDER BY에 사용되는 컬럼"
echo "  • 외래 키 컬럼"
echo ""
echo "⚠️  인덱스 단점:"
echo "  • 디스크 공간 사용 (테이블 크기의 ~30%)"
echo "  • INSERT/UPDATE/DELETE 시 인덱스도 갱신 필요 (쓰기 느려짐)"
echo "  • 너무 많은 인덱스는 오히려 성능 저하"
echo ""
echo "테스트 완료!"
echo "============================================================"
