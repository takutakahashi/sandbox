-- テスト用データベース作成
CREATE DATABASE replication_test;

-- 作成したデータベースに接続
\c replication_test;

-- ユーザー情報テーブル
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 商品テーブル
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    stock INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 注文テーブル
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    order_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    total_amount DECIMAL(12, 2) NOT NULL,
    status VARCHAR(50) DEFAULT 'pending'
);

-- 注文詳細テーブル
CREATE TABLE order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES orders(id),
    product_id INTEGER REFERENCES products(id),
    quantity INTEGER NOT NULL,
    price DECIMAL(10, 2) NOT NULL
);

-- サンプルデータ挿入: ユーザー
INSERT INTO users (username, email) VALUES
    ('user1', 'user1@example.com'),
    ('user2', 'user2@example.com'),
    ('user3', 'user3@example.com'),
    ('user4', 'user4@example.com'),
    ('user5', 'user5@example.com');

-- サンプルデータ挿入: 商品
INSERT INTO products (name, price, stock) VALUES
    ('ノートパソコン', 89000.00, 10),
    ('スマートフォン', 78000.00, 15),
    ('ヘッドフォン', 25000.00, 20),
    ('ワイヤレスマウス', 5800.00, 30),
    ('モニター', 35000.00, 5),
    ('キーボード', 12000.00, 12),
    ('外付けHDD', 9800.00, 8),
    ('Webカメラ', 7500.00, 25);

-- サンプルデータ挿入: 注文と注文詳細
-- 注文1
INSERT INTO orders (user_id, total_amount, status) VALUES
    (1, 94800.00, 'completed');
INSERT INTO order_items (order_id, product_id, quantity, price) VALUES
    (1, 1, 1, 89000.00),
    (1, 4, 1, 5800.00);

-- 注文2
INSERT INTO orders (user_id, total_amount, status) VALUES
    (2, 103000.00, 'processing');
INSERT INTO order_items (order_id, product_id, quantity, price) VALUES
    (2, 2, 1, 78000.00),
    (2, 3, 1, 25000.00);

-- 注文3
INSERT INTO orders (user_id, total_amount, status) VALUES
    (3, 47000.00, 'completed');
INSERT INTO order_items (order_id, product_id, quantity, price) VALUES
    (3, 5, 1, 35000.00),
    (3, 6, 1, 12000.00);

-- 注文4
INSERT INTO orders (user_id, total_amount, status) VALUES
    (4, 25000.00, 'pending');
INSERT INTO order_items (order_id, product_id, quantity, price) VALUES
    (4, 3, 1, 25000.00);

-- 注文5
INSERT INTO orders (user_id, total_amount, status) VALUES
    (5, 85600.00, 'completed');
INSERT INTO order_items (order_id, product_id, quantity, price) VALUES
    (5, 7, 1, 9800.00),
    (5, 8, 1, 7500.00),
    (5, 2, 1, 78000.00);