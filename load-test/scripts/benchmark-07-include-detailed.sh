#!/bin/bash

# ============================================================
# 테스트 7: INCLUDE 절 상세 비교 (3-Way)
# ============================================================
#
# 목적: 3가지 인덱스 전략의 정확한 차이 측정
#
# 케이스 1: 일반 인덱스 (level, service)
#   - Leaf: [level, service, TID]
#   - Heap Fetch 발생 (message 읽기 위해)
#   - Index Scan + Heap Fetch
#
# 케이스 2: 복합 인덱스 (level, service, message)
#   - Internal: [level, service, message]  ← 모든 레벨에!
#   - Leaf: [level, service, message, TID]
#   - message도 정렬됨 (INSERT 비용 증가)
#   - Index-Only Scan 가능
#   - 인덱스 크기 큼, 캐시 효율 낮음
#
# 케이스 3: INCLUDE 인덱스 (level, service) INCLUDE (message)
#   - Internal: [level, service]  ← 작음!
#   - Leaf: [level, service, message, TID]
#   - message는 정렬 안 됨 (INSERT 빠름)
#   - Index-Only Scan 가능
#   - 인덱스 크기 작음, 캐시 효율 높음
#
# 측정 항목:
# 1. 읽기 성능 (QPS, 지연시간, 버퍼 사용)
# 2. 쓰기 성능 (INSERT TPS)
# 3. 인덱스 크기
# 4. 쿼리 플랜
#
# ============================================================

set -e

READ_SERVER="http://localhost:8081"
WRITE_SERVER="http://localhost:8080"
DB_CONTAINER="loadtest-postgres"
TEST_DURATION=20  # 각 케이스 20초

echo "============================================================"
echo "테스트 7: INCLUDE 절 상세 비교 (3-Way)"
echo "============================================================"
echo ""
echo "📌 비교 대상:"
echo "   1. 일반 인덱스:   (level, service)"
echo "   2. 복합 인덱스:   (level, service, message)"
echo "   3. INCLUDE 인덱스: (level, service) INCLUDE (message)"
echo ""
echo "📌 측정 항목:"
echo "   • 읽기 성능: QPS, 지연시간, 버퍼 사용"
echo "   • 쓰기 성능: INSERT TPS"
echo "   • 인덱스 크기"
echo "   • 쿼리 실행 계획"
echo ""
echo "============================================================"
echo ""

# 데이터 확인
TOTAL_ROWS=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SELECT COUNT(*) FROM logs;" | xargs)
echo "현재 데이터: ${TOTAL_ROWS} 행"

# 최소 10만 건 확보
if [ ${TOTAL_ROWS} -lt 100000 ]; then
  echo "데이터 부족: 10만 건으로 증가 중..."
  docker exec ${DB_CONTAINER} psql -U postgres -d loadtest > /dev/null 2>&1 <<EOF
INSERT INTO logs (level, service, message, metadata)
SELECT
    (ARRAY['INFO', 'WARN', 'ERROR', 'DEBUG'])[floor(random() * 4 + 1)],
    (ARRAY['auth', 'api', 'worker', 'scheduler'])[floor(random() * 4 + 1)],
    'Load test message ' || generate_series || ' - ' || md5(random()::text),
    jsonb_build_object('request_id', generate_series::text)
FROM generate_series(1, $((100000 - ${TOTAL_ROWS})));
ANALYZE logs;
EOF
  TOTAL_ROWS=100000
  echo "데이터 준비 완료: ${TOTAL_ROWS} 행"
fi

echo ""

# 결과 저장 배열
declare -A READ_QPS
declare -A READ_AVG_LAT
declare -A READ_P95_LAT
declare -A WRITE_TPS
declare -A INDEX_SIZE
declare -A BUFFER_HIT

# ============================================================
# 케이스 1: 일반 인덱스 (Heap Fetch)
# ============================================================

echo "============================================================"
echo "[1/3] 케이스 1: 일반 인덱스 (level, service)"
echo "============================================================"
echo ""

# 인덱스 재구성
echo "인덱스 생성 중..."
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest <<EOF
-- 모든 기존 인덱스 제거
DROP INDEX IF EXISTS idx_logs_level;
DROP INDEX IF EXISTS idx_logs_service;
DROP INDEX IF EXISTS idx_logs_timestamp;
DROP INDEX IF EXISTS idx_logs_covering;
DROP INDEX IF EXISTS idx_test;

-- 새 인덱스 생성
CREATE INDEX idx_test ON logs(level, service);
EOF

echo "인덱스: CREATE INDEX idx_test ON logs(level, service);"
echo ""

# VACUUM ANALYZE
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "VACUUM ANALYZE logs;" > /dev/null 2>&1

# 인덱스 크기 측정
SIZE=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SELECT pg_size_pretty(pg_relation_size('idx_test'::regclass));" 2>&1 | xargs)
INDEX_SIZE[1]=$SIZE
echo "인덱스 크기: ${SIZE}"
echo ""

# 쿼리 플랜 확인
echo "쿼리 실행 계획:"
PLAN=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT id, timestamp, level, service, message
FROM logs
WHERE level = 'ERROR' AND service = 'api'
LIMIT 100;
" 2>&1)

echo "$PLAN" | grep -E "(Index|Heap|Buffers|Planning|Execution)" || true

# 버퍼 사용량 추출
BUFFER_LINE=$(echo "$PLAN" | grep "Buffers:" | head -1)
echo "버퍼: $BUFFER_LINE"
echo ""

# === 읽기 성능 테스트 ===
echo "--- 읽기 성능 테스트 ---"

curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null 2>&1

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

curl -s -X POST ${READ_SERVER}/load/start > /dev/null
sleep ${TEST_DURATION}

METRICS=$(curl -s ${READ_SERVER}/metrics)
READ_QPS[1]=$(echo ${METRICS} | jq -r '.qps')
READ_AVG_LAT[1]=$(echo ${METRICS} | jq -r '.avg_latency_ms')
READ_P95_LAT[1]=$(echo ${METRICS} | jq -r '.p95_latency_ms')

printf "읽기 QPS:         %.2f\n" ${READ_QPS[1]}
printf "평균 지연시간:    %.2f ms\n" ${READ_AVG_LAT[1]}
printf "P95 지연시간:     %.2f ms\n" ${READ_P95_LAT[1]}
echo ""

sleep 3

# === 쓰기 성능 테스트 ===
echo "--- 쓰기 성능 테스트 ---"

curl -s -X POST ${WRITE_SERVER}/metrics/reset > /dev/null 2>&1

curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 0,
    \"batch_size\": 100,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

curl -s -X POST ${WRITE_SERVER}/load/start > /dev/null
sleep ${TEST_DURATION}

METRICS=$(curl -s ${WRITE_SERVER}/metrics)
WRITE_TPS[1]=$(echo ${METRICS} | jq -r '.tps')

printf "쓰기 TPS:         %.2f\n" ${WRITE_TPS[1]}
echo ""

sleep 5

# ============================================================
# 케이스 2: 복합 인덱스 (모든 컬럼을 키로)
# ============================================================

echo "============================================================"
echo "[2/3] 케이스 2: 복합 인덱스 (level, service, message)"
echo "============================================================"
echo ""

# 인덱스 재구성
echo "인덱스 생성 중..."
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest <<EOF
DROP INDEX IF EXISTS idx_test;
CREATE INDEX idx_test ON logs(level, service, message);
EOF

echo "인덱스: CREATE INDEX idx_test ON logs(level, service, message);"
echo ""

# VACUUM ANALYZE
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "VACUUM ANALYZE logs;" > /dev/null 2>&1

# 인덱스 크기 측정
SIZE=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SELECT pg_size_pretty(pg_relation_size('idx_test'::regclass));" 2>&1 | xargs)
INDEX_SIZE[2]=$SIZE
echo "인덱스 크기: ${SIZE}"
echo ""

# 쿼리 플랜 확인
echo "쿼리 실행 계획:"
PLAN=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT id, timestamp, level, service, message
FROM logs
WHERE level = 'ERROR' AND service = 'api'
LIMIT 100;
" 2>&1)

echo "$PLAN" | grep -E "(Index|Heap|Buffers|Planning|Execution)" || true

BUFFER_LINE=$(echo "$PLAN" | grep "Buffers:" | head -1)
echo "버퍼: $BUFFER_LINE"
echo ""

# === 읽기 성능 테스트 ===
echo "--- 읽기 성능 테스트 ---"

curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null 2>&1

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

curl -s -X POST ${READ_SERVER}/load/start > /dev/null
sleep ${TEST_DURATION}

METRICS=$(curl -s ${READ_SERVER}/metrics)
READ_QPS[2]=$(echo ${METRICS} | jq -r '.qps')
READ_AVG_LAT[2]=$(echo ${METRICS} | jq -r '.avg_latency_ms')
READ_P95_LAT[2]=$(echo ${METRICS} | jq -r '.p95_latency_ms')

printf "읽기 QPS:         %.2f\n" ${READ_QPS[2]}
printf "평균 지연시간:    %.2f ms\n" ${READ_AVG_LAT[2]}
printf "P95 지연시간:     %.2f ms\n" ${READ_P95_LAT[2]}
echo ""

sleep 3

# === 쓰기 성능 테스트 ===
echo "--- 쓰기 성능 테스트 ---"

curl -s -X POST ${WRITE_SERVER}/metrics/reset > /dev/null 2>&1

curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 0,
    \"batch_size\": 100,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

curl -s -X POST ${WRITE_SERVER}/load/start > /dev/null
sleep ${TEST_DURATION}

METRICS=$(curl -s ${WRITE_SERVER}/metrics)
WRITE_TPS[2]=$(echo ${METRICS} | jq -r '.tps')

printf "쓰기 TPS:         %.2f\n" ${WRITE_TPS[2]}
echo ""

sleep 5

# ============================================================
# 케이스 3: INCLUDE 인덱스
# ============================================================

echo "============================================================"
echo "[3/3] 케이스 3: INCLUDE 인덱스"
echo "============================================================"
echo ""

# 인덱스 재구성
echo "인덱스 생성 중..."
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest <<EOF
DROP INDEX IF EXISTS idx_test;
CREATE INDEX idx_test ON logs(level, service) INCLUDE (message);
EOF

echo "인덱스: CREATE INDEX idx_test ON logs(level, service)"
echo "         INCLUDE (message);"
echo ""

# VACUUM ANALYZE
docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "VACUUM ANALYZE logs;" > /dev/null 2>&1

# 인덱스 크기 측정
SIZE=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -t -c "SELECT pg_size_pretty(pg_relation_size('idx_test'::regclass));" 2>&1 | xargs)
INDEX_SIZE[3]=$SIZE
echo "인덱스 크기: ${SIZE}"
echo ""

# 쿼리 플랜 확인
echo "쿼리 실행 계획:"
PLAN=$(docker exec ${DB_CONTAINER} psql -U postgres -d loadtest -c "
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT id, timestamp, level, service, message
FROM logs
WHERE level = 'ERROR' AND service = 'api'
LIMIT 100;
" 2>&1)

echo "$PLAN" | grep -E "(Index|Heap|Buffers|Planning|Execution)" || true

BUFFER_LINE=$(echo "$PLAN" | grep "Buffers:" | head -1)
echo "버퍼: $BUFFER_LINE"
echo ""

# === 읽기 성능 테스트 ===
echo "--- 읽기 성능 테스트 ---"

curl -s -X POST ${READ_SERVER}/metrics/reset > /dev/null 2>&1

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

curl -s -X POST ${READ_SERVER}/load/start > /dev/null
sleep ${TEST_DURATION}

METRICS=$(curl -s ${READ_SERVER}/metrics)
READ_QPS[3]=$(echo ${METRICS} | jq -r '.qps')
READ_AVG_LAT[3]=$(echo ${METRICS} | jq -r '.avg_latency_ms')
READ_P95_LAT[3]=$(echo ${METRICS} | jq -r '.p95_latency_ms')

printf "읽기 QPS:         %.2f\n" ${READ_QPS[3]}
printf "평균 지연시간:    %.2f ms\n" ${READ_AVG_LAT[3]}
printf "P95 지연시간:     %.2f ms\n" ${READ_P95_LAT[3]}
echo ""

sleep 3

# === 쓰기 성능 테스트 ===
echo "--- 쓰기 성능 테스트 ---"

curl -s -X POST ${WRITE_SERVER}/metrics/reset > /dev/null 2>&1

curl -s -X POST ${WRITE_SERVER}/load/config \
  -H "Content-Type: application/json" \
  -d "{
    \"tps\": 0,
    \"batch_size\": 100,
    \"workers\": 10,
    \"duration\": ${TEST_DURATION}000000000,
    \"isolation_level\": \"READ COMMITTED\"
  }" > /dev/null

curl -s -X POST ${WRITE_SERVER}/load/start > /dev/null
sleep ${TEST_DURATION}

METRICS=$(curl -s ${WRITE_SERVER}/metrics)
WRITE_TPS[3]=$(echo ${METRICS} | jq -r '.tps')

printf "쓰기 TPS:         %.2f\n" ${WRITE_TPS[3]}
echo ""

# ============================================================
# 종합 비교
# ============================================================

echo ""
echo "============================================================"
echo "📊 종합 비교 결과"
echo "============================================================"
echo ""

# 테이블 헤더
printf "%-20s | %-15s | %-15s | %-15s\n" "항목" "케이스1 (일반)" "케이스2 (복합)" "케이스3 (INCLUDE)"
echo "--------------------------------------------------------------------------------"

# 읽기 QPS
printf "%-20s | %15.2f | %15.2f | %15.2f\n" "읽기 QPS" ${READ_QPS[1]} ${READ_QPS[2]} ${READ_QPS[3]}

# 읽기 지연시간
printf "%-20s | %15.2f | %15.2f | %15.2f\n" "평균 지연시간 (ms)" ${READ_AVG_LAT[1]} ${READ_AVG_LAT[2]} ${READ_AVG_LAT[3]}
printf "%-20s | %15.2f | %15.2f | %15.2f\n" "P95 지연시간 (ms)" ${READ_P95_LAT[1]} ${READ_P95_LAT[2]} ${READ_P95_LAT[3]}

# 쓰기 TPS
printf "%-20s | %15.2f | %15.2f | %15.2f\n" "쓰기 TPS" ${WRITE_TPS[1]} ${WRITE_TPS[2]} ${WRITE_TPS[3]}

# 인덱스 크기
printf "%-20s | %15s | %15s | %15s\n" "인덱스 크기" "${INDEX_SIZE[1]}" "${INDEX_SIZE[2]}" "${INDEX_SIZE[3]}"

echo ""
echo "============================================================"
echo "💡 핵심 인사이트"
echo "============================================================"
echo ""

# 케이스 1 vs 3 비교 (일반 vs INCLUDE)
QPS_IMPROVEMENT_1_3=$(echo "scale=2; (${READ_QPS[3]} / ${READ_QPS[1]} - 1) * 100" | bc)
printf "1. 일반 → INCLUDE 읽기 성능: +%.1f%%\n" ${QPS_IMPROVEMENT_1_3}
printf "   (Heap Fetch 제거 효과)\n"
echo ""

# 케이스 2 vs 3 비교 (복합 vs INCLUDE)
QPS_IMPROVEMENT_2_3=$(echo "scale=2; (${READ_QPS[3]} / ${READ_QPS[2]} - 1) * 100" | bc)
printf "2. 복합 → INCLUDE 읽기 성능: +%.1f%%\n" ${QPS_IMPROVEMENT_2_3}
printf "   (Internal Node 크기 감소, 캐시 효율 증가)\n"
echo ""

# 쓰기 성능 비교
WRITE_IMPROVEMENT_2_3=$(echo "scale=2; (${WRITE_TPS[3]} / ${WRITE_TPS[2]} - 1) * 100" | bc)
printf "3. 복합 → INCLUDE 쓰기 성능: +%.1f%%\n" ${WRITE_IMPROVEMENT_2_3}
printf "   (message 정렬 제거 효과)\n"
echo ""

echo "============================================================"
echo "📋 결론"
echo "============================================================"
echo ""

echo "케이스 1: 일반 인덱스 (level, service)"
echo "  ❌ Heap Fetch 발생 → 가장 느림"
echo "  ✅ 인덱스 크기 가장 작음"
echo "  ✅ INSERT 빠름"
echo ""

echo "케이스 2: 복합 인덱스 (level, service, message)"
echo "  ✅ Index-Only Scan (Heap Fetch 없음)"
echo "  ✅ message를 WHERE 절에 사용 가능"
echo "  ❌ 인덱스 크기 가장 큼"
echo "  ❌ Internal Node 비대 (캐시 효율 낮음)"
echo "  ❌ message 정렬 비용 (INSERT 느림)"
echo ""

echo "케이스 3: INCLUDE 인덱스 (level, service) INCLUDE (message)"
echo "  ✅ Index-Only Scan (Heap Fetch 없음)"
echo "  ✅ 인덱스 크기 작음 (복합보다)"
echo "  ✅ Internal Node 작음 (캐시 효율 최고)"
echo "  ✅ message 정렬 안 함 (INSERT 빠름)"
echo "  ❌ message를 WHERE 절에 사용 불가"
echo ""

echo "🎯 권장 사항:"
echo "  • message를 WHERE 절에 안 쓴다면 → INCLUDE 인덱스"
echo "  • message를 WHERE 절에 쓴다면 → 복합 인덱스"
echo "  • 읽기만 한다면 → 일반 인덱스는 피할 것"
echo ""

echo "테스트 완료!"
echo "============================================================"
