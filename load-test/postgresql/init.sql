-- PostgreSQL 부하 테스트를 위한 초기화 스크립트

-- logs 테이블 생성
CREATE TABLE logs (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    level VARCHAR(10) NOT NULL,
    service VARCHAR(50) NOT NULL,
    message TEXT NOT NULL,
    metadata JSONB
);

-- 인덱스 생성 (읽기 최적화)
CREATE INDEX idx_logs_timestamp ON logs(timestamp);
CREATE INDEX idx_logs_level ON logs(level);
CREATE INDEX idx_logs_service ON logs(service);

-- pg_stat_statements 확장 활성화 (쿼리 성능 모니터링)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 초기 데이터 삽입 (테스트용)
INSERT INTO logs (level, service, message, metadata)
SELECT
    (ARRAY['INFO', 'WARN', 'ERROR', 'DEBUG'])[floor(random() * 4 + 1)],
    (ARRAY['auth', 'api', 'worker', 'scheduler'])[floor(random() * 4 + 1)],
    'Initial test log message ' || generate_series,
    jsonb_build_object('request_id', generate_series::text)
FROM generate_series(1, 10000);

-- 통계 업데이트
ANALYZE logs;
