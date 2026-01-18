#!/bin/bash

# ============================================================
# 테스트 5: work_mem 효과 검증 (집계 쿼리 최적화)
# ============================================================
#
# 목적: work_mem 크기에 따른 GROUP BY/집계 쿼리 성능 차이 측정
#
# 배경지식:
# work_mem은 정렬(ORDER BY), 해시(GROUP BY), 조인(JOIN) 작업에 사용되는
# 메모리 크기입니다. 각 작업마다 최대 work_mem만큼 사용할 수 있습니다.
#
# work_mem이 작을 때:
# - 메모리에 데이터를 다 담을 수 없음
# - 디스크 임시 파일 사용 (disk sort, external merge)
# - 디스크 I/O 발생으로 매우 느림
#
# work_mem이 충분할 때:
# - 모든 작업을 메모리에서 수행
# - Quick Sort (정렬), Hash Aggregate (집계)
# - 디스크 I/O 없이 빠르게 처리
#
# 계산 예시:
# - GROUP BY로 1만 개 그룹 처리, 각 그룹당 100바이트
# - 필요 메모리 = 10000 * 100 = 1MB
# - work_mem = 1MB: 메모리 처리 (빠름)
# - work_mem = 100KB: 디스크 사용 (느림)
#
# 주의사항:
# - work_mem은 커넥션당 설정
# - max_connections=100, work_mem=1GB → 최대 100GB 사용 가능!
# - 너무 크게 설정하면 OOM 발생 위험
# - 적절한 값: 전체 메모리 / max_connections / 4
#
# 예상 결과:
# - work_mem = 4MB (작음):   평균 100ms (disk sort)
# - work_mem = 256MB (충분): 평균 20ms (memory sort, 5배 빠름)
#
# ============================================================

set -e

READ_SERVER="http://localhost:8081"
DB_CONTAINER="loadtest-postgres"
TEST_DURATION=30

echo "============================================================"
echo "테스트 5: work_mem 효과 검증"
echo "============================================================"
echo ""
echo "📌 테스트 목적:"
echo "   GROUP BY 집계 쿼리의 메모리 vs 디스크 성능 비교"
echo ""
echo "📌 work_mem이란?"
echo "   • 정렬, 해시, 조인 작업에 사용되는 메모리 크기"
echo "   • 각 operation마다 work_mem만큼 사용 가능"
echo "   • 복잡한 쿼리는 여러 operation → work_mem * N"
echo ""
echo "📌 work_mem이 작을 때 (4MB)"
echo "   • 메모리에 데이터를 다 담을 수 없음"
echo "   • 디스크 임시 파일 생성 (base/pgsql_tmp/)"
echo "   • Disk Sort, External Merge"
echo "   • 디스크 I/O로 인해 매우 느림"
echo ""
echo "📌 work_mem이 충분할 때 (256MB)"
echo "   • 모든 작업을 메모리에서 처리"
echo "   • Quick Sort, Hash Aggregate"
echo "   • 디스크 I/O 없이 빠름"
echo ""
echo "📌 적절한 work_mem 설정:"
echo "   work_mem = (Total RAM / max_connections) / 4"
echo "   예: 8GB RAM, 100 connections → 20MB"
echo ""
echo "⚠️  주의: work_mem은 커넥션당 설정!"
echo "   100개 연결 × 1GB = 최대 100GB 사용 가능 → OOM 위험"
echo ""
echo "============================================================"
echo ""

# 현재 설정 확인
CURRENT_WORK_MEM=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SHOW work_mem;" | xargs)
echo "현재 work_mem: ${CURRENT_WORK_MEM}"
echo ""

# 데이터 확인
TOTAL_ROWS=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SELECT COUNT(*) FROM logs;" | xargs)
echo "logs 테이블 행 개수: ${TOTAL_ROWS}"
echo ""

# 메트릭 초기화
curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null 2>&1 || true

# ============================================================
# BEFORE: work_mem = 4MB (작음, 디스크 사용)
# ============================================================

echo "[1/2] BEFORE: work_mem = 4MB (디스크 정렬)"
echo "------------------------------------------------------------"

# work_mem 설정
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "ALTER SYSTEM SET work_mem = '4MB';" > /dev/null
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "SELECT pg_reload_conf();" > /dev/null
sleep 2

CURRENT=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SHOW work_mem;" | xargs)
echo "설정 변경: work_mem = ${CURRENT}"
echo ""

# 쿼리 플랜 확인 (디스크 사용 여부 체크)
echo "쿼리 실행 계획 (work_mem=4MB):"
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    level,
    service,
    COUNT(*) as count,
    MIN(timestamp) as first_seen,
    MAX(timestamp) as last_seen,
    AVG(LENGTH(message)) as avg_msg_len
FROM logs
WHERE timestamp > NOW() - INTERVAL '1 hour'
GROUP BY level, service
ORDER BY count DESC;
" | grep -E "(Sort|Hash|Aggregate|Disk|Memory|Planning|Execution)" || true
echo ""

# 부하 설정 (Aggregate 쿼리 100%)
curl -s -X POST ${READ_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"qps\": 0,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"query_mix\": {
      \"simple\": 0,
      \"filter\": 0,
      \"aggregate\": 100
    },
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

echo "부하 설정: Aggregate 쿼리 100%, workers=10, duration=${TEST_DURATION}s"
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
echo "📊 BEFORE 결과 (work_mem=4MB):"
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

# 임시 파일 사용 확인
TEMP_FILES=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "
SELECT SUM(temp_files) as temp_files,
       pg_size_pretty(SUM(temp_bytes)) as temp_bytes
FROM pg_stat_database
WHERE datname = 'loadtest';
" | xargs)
echo "디스크 임시 파일 사용: ${TEMP_FILES}"

echo ""
echo "============================================================"
echo ""

# 잠시 대기
sleep 5

# 통계 리셋
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "SELECT pg_stat_reset();" > /dev/null

# 메트릭 리셋
curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null

# ============================================================
# AFTER: work_mem = 256MB (충분, 메모리 정렬)
# ============================================================

echo "[2/2] AFTER: work_mem = 256MB (메모리 정렬)"
echo "------------------------------------------------------------"

# work_mem 증가
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "ALTER SYSTEM SET work_mem = '256MB';" > /dev/null
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "SELECT pg_reload_conf();" > /dev/null
sleep 2

CURRENT=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SHOW work_mem;" | xargs)
echo "설정 변경: work_mem = ${CURRENT}"
echo ""

# 쿼리 플랜 확인
echo "쿼리 실행 계획 (work_mem=256MB):"
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    level,
    service,
    COUNT(*) as count,
    MIN(timestamp) as first_seen,
    MAX(timestamp) as last_seen,
    AVG(LENGTH(message)) as avg_msg_len
FROM logs
WHERE timestamp > NOW() - INTERVAL '1 hour'
GROUP BY level, service
ORDER BY count DESC;
" | grep -E "(Sort|Hash|Aggregate|Disk|Memory|Planning|Execution)" || true
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
      \"filter\": 0,
      \"aggregate\": 100
    },
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

echo "부하 설정: Aggregate 쿼리 100%, workers=10, duration=${TEST_DURATION}s"
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
echo "📊 AFTER 결과 (work_mem=256MB):"
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

# 임시 파일 사용 확인
TEMP_FILES=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "
SELECT SUM(temp_files) as temp_files,
       pg_size_pretty(SUM(temp_bytes)) as temp_bytes
FROM pg_stat_database
WHERE datname = 'loadtest';
" | xargs)
echo "디스크 임시 파일 사용: ${TEMP_FILES}"

echo ""
echo "============================================================"
echo "📈 비교 분석"
echo "============================================================"
echo ""

# QPS 향상률
QPS_IMPROVEMENT=$(echo "scale=2; (${AFTER_QPS} / ${BEFORE_QPS} - 1) * 100" | bc)
printf "QPS 향상률:      %.2f%%\n" ${QPS_IMPROVEMENT}
printf "   4MB:          %.2f QPS\n" ${BEFORE_QPS}
printf "   256MB:        %.2f QPS\n" ${AFTER_QPS}
printf "   향상 배수:    %.2fx\n" $(echo "scale=2; ${AFTER_QPS} / ${BEFORE_QPS}" | bc)

echo ""

# 지연시간 개선
LAT_IMPROVEMENT=$(echo "scale=2; (${BEFORE_AVG_LAT} - ${AFTER_AVG_LAT}) * 100 / ${BEFORE_AVG_LAT}" | bc)
printf "지연시간 개선:   %.2f%%\n" ${LAT_IMPROVEMENT}
printf "   평균 - 4MB: %.2f ms → 256MB: %.2f ms (%.2fx 빠름)\n" \
  ${BEFORE_AVG_LAT} ${AFTER_AVG_LAT} \
  $(echo "scale=2; ${BEFORE_AVG_LAT} / ${AFTER_AVG_LAT}" | bc)
printf "   P95  - 4MB: %.2f ms → 256MB: %.2f ms\n" ${BEFORE_P95_LAT} ${AFTER_P95_LAT}
printf "   P99  - 4MB: %.2f ms → 256MB: %.2f ms\n" ${BEFORE_P99_LAT} ${AFTER_P99_LAT}

echo ""
echo "============================================================"
echo "💡 결론"
echo "============================================================"
echo ""
echo "충분한 work_mem 설정 시:"
printf "  ✓ QPS가 %.2fx 향상됩니다\n" $(echo "scale=2; ${AFTER_QPS} / ${BEFORE_QPS}" | bc)
printf "  ✓ 지연시간이 %.2fx 감소합니다\n" $(echo "scale=2; ${BEFORE_AVG_LAT} / ${AFTER_AVG_LAT}" | bc)
echo "  ✓ 디스크 I/O가 사라집니다 (메모리 정렬)"
echo "  ✓ CPU 효율성이 증가합니다"
echo ""
echo "✅ work_mem을 증가시켜야 하는 경우:"
echo "  • 복잡한 GROUP BY, ORDER BY, JOIN 쿼리"
echo "  • 대량 데이터 정렬/집계"
echo "  • 분석/리포팅 쿼리 (BI, 대시보드)"
echo "  • 배치 작업"
echo ""
echo "⚠️  주의사항:"
echo "  • work_mem은 커넥션당, operation당 설정!"
echo "  • 복잡한 쿼리 = 여러 operation = work_mem × N"
echo "  • max_connections × work_mem = 최대 메모리 사용량"
echo ""
echo "📐 적절한 work_mem 계산:"
echo "  work_mem = (Total RAM - shared_buffers) / max_connections / 4"
echo "  "
echo "  예시:"
echo "  • 8GB RAM, shared_buffers=2GB, max_connections=100"
echo "  • work_mem = (8GB - 2GB) / 100 / 4 = 15MB"
echo ""
echo "🔧 동적 설정 (세션별):"
echo "  SET work_mem = '512MB';  -- 특정 세션만 임시로 증가"
echo "  -- 배치 작업 실행"
echo "  RESET work_mem;          -- 원래대로 복원"
echo ""

# 설정 원복
echo "------------------------------------------------------------"
echo "설정 원복 중..."
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "ALTER SYSTEM SET work_mem = '64MB';" > /dev/null
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "SELECT pg_reload_conf();" > /dev/null
echo "work_mem을 64MB(기본값)로 복원했습니다."
echo ""
echo "테스트 완료!"
echo "============================================================"
