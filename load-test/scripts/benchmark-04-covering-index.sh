#!/bin/bash

# ============================================================
# 테스트 4: 커버링 인덱스(Covering Index) 효과 검증
# ============================================================
#
# 목적: 일반 인덱스 vs 커버링 인덱스의 성능 차이 측정
#
# 배경지식:
# PostgreSQL의 쿼리 실행 과정:
# 1. 인덱스로 조건에 맞는 행의 위치(TID) 찾기
# 2. TID로 실제 테이블(Heap)에 접근하여 필요한 컬럼 읽기 ← 이게 느림!
#
# 커버링 인덱스란?
# - 쿼리에서 필요한 모든 컬럼을 인덱스에 포함시키는 기법
# - PostgreSQL에서는 INCLUDE 절로 구현
# - 테이블 접근 없이 인덱스만으로 쿼리 완료 가능
#
# 예시:
# - 일반 인덱스:       CREATE INDEX idx ON logs(level);
# - 커버링 인덱스:     CREATE INDEX idx ON logs(level) INCLUDE (service, message);
#
# 차이점:
# 1. 일반 인덱스 (Index Scan + Heap Fetch)
#    - 인덱스로 level='ERROR' 찾기 (1000건)
#    - 테이블에서 1000건의 service, message 읽기 ← 랜덤 I/O
#    - 총 1000번의 heap 접근
#
# 2. 커버링 인덱스 (Index-Only Scan)
#    - 인덱스에 level, service, message 모두 있음
#    - 테이블 접근 불필요!
#    - Heap 접근 0번 (단, Visibility Map 체크는 필요)
#
# 효과가 큰 경우:
# - SELECT 절에 몇 개 컬럼만 필요한 경우
# - 자주 조회되는 컬럼 조합
# - 읽기가 압도적으로 많은 워크로드
#
# 주의사항:
# - 인덱스 크기가 증가 (컬럼 추가되므로)
# - INSERT/UPDATE 비용 증가 (인덱스 갱신 비용)
# - 너무 많은 컬럼을 INCLUDE하면 비효율
#
# 예상 결과:
# - 일반 인덱스:   평균 15ms (Index Scan + Heap Fetch)
# - 커버링 인덱스: 평균 5ms (Index-Only Scan, 3배 빠름)
#
# ============================================================

set -e

READ_SERVER="http://localhost:8081"
DB_CONTAINER="loadtest-postgres"
TEST_DURATION=30

echo "============================================================"
echo "테스트 4: 커버링 인덱스 효과 검증"
echo "============================================================"
echo ""
echo "📌 테스트 목적:"
echo "   Index Scan vs Index-Only Scan 성능 비교"
echo ""
echo "📌 일반 인덱스 (Index Scan + Heap Fetch)"
echo "   CREATE INDEX idx_logs_level ON logs(level);"
echo "   "
echo "   실행 과정:"
echo "   1. 인덱스에서 level='ERROR'인 행의 위치(TID) 찾기"
echo "   2. 각 TID에 대해 실제 테이블에 접근하여 컬럼 읽기"
echo "   3. 1000건 결과 → 1000번의 heap 접근 (랜덤 I/O)"
echo ""
echo "📌 커버링 인덱스 (Index-Only Scan)"
echo "   CREATE INDEX idx_logs_covering ON logs(level)"
echo "     INCLUDE (service, message);"
echo "   "
echo "   실행 과정:"
echo "   1. 인덱스에서 level='ERROR'이고 필요한 컬럼도 모두 읽기"
echo "   2. 테이블 접근 불필요! (Visibility Map만 체크)"
echo "   3. Heap 접근 0번 → 매우 빠름"
echo ""
echo "📌 왜 커버링 인덱스가 빠른가?"
echo "   • Heap 접근 제거 (랜덤 I/O 없음)"
echo "   • 순차적 인덱스 스캔만 수행"
echo "   • CPU 캐시 효율성 증가"
echo ""
echo "📌 단점:"
echo "   • 인덱스 크기 증가 (추가 컬럼 저장)"
echo "   • INSERT/UPDATE 비용 증가"
echo ""
echo "============================================================"
echo ""

# 데이터 확인
TOTAL_ROWS=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SELECT COUNT(*) FROM logs;" | xargs)
echo "현재 logs 테이블 행 개수: ${TOTAL_ROWS}"
echo ""

# 메트릭 초기화
curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null 2>&1 || true

# ============================================================
# BEFORE: 일반 인덱스 (Index Scan + Heap Fetch)
# ============================================================

echo "[1/2] BEFORE: 일반 인덱스 (Index Scan + Heap Fetch)"
echo "------------------------------------------------------------"

# 기존 인덱스 정리 및 일반 인덱스만 생성
echo "인덱스 재구성 중..."
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest > /dev/null <<EOF
DROP INDEX IF EXISTS idx_logs_level;
DROP INDEX IF EXISTS idx_logs_service;
DROP INDEX IF EXISTS idx_logs_covering;

-- 일반 인덱스 (level만)
CREATE INDEX idx_logs_level ON logs(level);

ANALYZE logs;
EOF
echo "일반 인덱스 생성: idx_logs_level ON logs(level)"
echo ""

# 쿼리 플랜 확인
echo "쿼리 실행 계획 (일반 인덱스):"
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, timestamp, level, service, message
FROM logs
WHERE level = 'ERROR'
  AND service = 'api'
LIMIT 100;
" | grep -E "(Index|Heap|Buffers|Planning|Execution)" || true
echo ""

# 부하 설정 (Filter 쿼리)
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
echo "📊 BEFORE 결과 (일반 인덱스):"
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

# 인덱스 크기 확인
BEFORE_INDEX_SIZE=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "
SELECT pg_size_pretty(pg_relation_size('idx_logs_level'));
" | xargs)
echo "인덱스 크기: ${BEFORE_INDEX_SIZE}"

echo ""
echo "============================================================"
echo ""

# 잠시 대기
sleep 5

# 메트릭 리셋
curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null

# ============================================================
# AFTER: 커버링 인덱스 (Index-Only Scan)
# ============================================================

echo "[2/2] AFTER: 커버링 인덱스 (Index-Only Scan)"
echo "------------------------------------------------------------"

# 커버링 인덱스 생성
echo "커버링 인덱스 생성 중..."
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest > /dev/null <<EOF
DROP INDEX IF EXISTS idx_logs_level;

-- 커버링 인덱스 (level + service를 키로, message를 INCLUDE)
-- SELECT에 필요한 id, timestamp, level, service, message를 모두 커버
CREATE INDEX idx_logs_covering ON logs(level, service)
  INCLUDE (id, timestamp, message);

-- VACUUM으로 Visibility Map 갱신 (Index-Only Scan 활성화)
VACUUM ANALYZE logs;
EOF
echo "커버링 인덱스 생성: idx_logs_covering ON logs(level, service)"
echo "                     INCLUDE (id, timestamp, message)"
echo ""

# 쿼리 플랜 확인
echo "쿼리 실행 계획 (커버링 인덱스):"
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, timestamp, level, service, message
FROM logs
WHERE level = 'ERROR'
  AND service = 'api'
LIMIT 100;
" | grep -E "(Index|Heap|Buffers|Planning|Execution)" || true
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
echo "📊 AFTER 결과 (커버링 인덱스):"
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

# 인덱스 크기 비교
AFTER_INDEX_SIZE=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "
SELECT pg_size_pretty(pg_relation_size('idx_logs_covering'));
" | xargs)
echo "인덱스 크기: ${AFTER_INDEX_SIZE} (BEFORE: ${BEFORE_INDEX_SIZE})"

echo ""
echo "============================================================"
echo "📈 비교 분석"
echo "============================================================"
echo ""

# QPS 향상률
QPS_IMPROVEMENT=$(echo "scale=2; (${AFTER_QPS} / ${BEFORE_QPS} - 1) * 100" | bc)
printf "QPS 향상률:      %.2f%%\n" ${QPS_IMPROVEMENT}
printf "   일반 인덱스:  %.2f QPS\n" ${BEFORE_QPS}
printf "   커버링 인덱스: %.2f QPS\n" ${AFTER_QPS}
printf "   향상 배수:    %.2fx\n" $(echo "scale=2; ${AFTER_QPS} / ${BEFORE_QPS}" | bc)

echo ""

# 지연시간 개선
LAT_IMPROVEMENT=$(echo "scale=2; (${BEFORE_AVG_LAT} - ${AFTER_AVG_LAT}) * 100 / ${BEFORE_AVG_LAT}" | bc)
printf "지연시간 개선:   %.2f%%\n" ${LAT_IMPROVEMENT}
printf "   평균 - 일반: %.2f ms → 커버링: %.2f ms (%.2fx 빠름)\n" \
  ${BEFORE_AVG_LAT} ${AFTER_AVG_LAT} \
  $(echo "scale=2; ${BEFORE_AVG_LAT} / ${AFTER_AVG_LAT}" | bc)
printf "   P95  - 일반: %.2f ms → 커버링: %.2f ms\n" ${BEFORE_P95_LAT} ${AFTER_P95_LAT}
printf "   P99  - 일반: %.2f ms → 커버링: %.2f ms\n" ${BEFORE_P99_LAT} ${AFTER_P99_LAT}

echo ""

# 인덱스 크기 비교
echo "저장 공간 비용:"
echo "   일반 인덱스:   ${BEFORE_INDEX_SIZE}"
echo "   커버링 인덱스: ${AFTER_INDEX_SIZE}"

echo ""
echo "============================================================"
echo "💡 결론"
echo "============================================================"
echo ""
echo "커버링 인덱스 사용 시:"
printf "  ✓ QPS가 %.2fx 향상됩니다\n" $(echo "scale=2; ${AFTER_QPS} / ${BEFORE_QPS}" | bc)
printf "  ✓ 지연시간이 %.2fx 감소합니다\n" $(echo "scale=2; ${BEFORE_AVG_LAT} / ${AFTER_AVG_LAT}" | bc)
echo "  ✓ Heap 접근 제거 (랜덤 I/O 없음)"
echo "  ✓ Index-Only Scan 활성화"
echo ""
echo "✅ 커버링 인덱스를 사용해야 하는 경우:"
echo "  • 자주 조회되는 컬럼 조합 (SELECT 절이 거의 같음)"
echo "  • 읽기가 압도적으로 많은 테이블"
echo "  • JOIN이나 서브쿼리에서 사용되는 컬럼"
echo "  • 리포팅, 대시보드 쿼리"
echo ""
echo "⚠️  주의사항:"
echo "  • 인덱스 크기 증가 (디스크 공간 필요)"
echo "  • INSERT/UPDATE 비용 증가 (인덱스 갱신)"
echo "  • 너무 많은 컬럼을 INCLUDE하면 비효율"
echo "  • VACUUM 필요 (Visibility Map 갱신)"
echo ""
echo "📝 PostgreSQL 전용 문법:"
echo "  CREATE INDEX idx ON table(col1, col2)"
echo "    INCLUDE (col3, col4, col5);"
echo ""
echo "🔥 실무 팁:"
echo "  • WHERE 절 컬럼은 인덱스 키로"
echo "  • SELECT 절 컬럼은 INCLUDE로"
echo "  • 쓰기가 많으면 신중히 사용"
echo "  • pg_stat_user_indexes로 사용률 모니터링"
echo ""
echo "테스트 완료!"
echo "============================================================"
