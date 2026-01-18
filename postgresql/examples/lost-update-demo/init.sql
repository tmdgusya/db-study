-- Lost Update Demo Database 초기화 스크립트

-- products 테이블 생성
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    stock INTEGER NOT NULL CHECK (stock >= 0),
    version INTEGER DEFAULT 0,  -- 낙관적 잠금용 (향후 확장)
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 초기 데이터 삽입
INSERT INTO products (name, stock) VALUES
    ('iPhone 15', 100),
    ('Galaxy S24', 100),
    ('MacBook Pro', 50);

-- 인덱스 생성 (성능 최적화)
CREATE INDEX idx_products_stock ON products(stock);

-- 테이블 정보 출력 (디버깅용)
SELECT 'Products table initialized successfully' AS status;
SELECT * FROM products;
