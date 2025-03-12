-- レプリケーション動作確認用のシンプルなスクリプト
-- プライマリで実行し、データがレプリカにレプリケートされるか確認します

-- データベースの選択
\c replication_test

-- 現在のタイムスタンプを含むテーブルの作成
CREATE TABLE IF NOT EXISTS replication_status_check (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    message TEXT
);

-- 新しいレコードを挿入 (実行時間がレコードに記録される)
INSERT INTO replication_status_check (message) 
VALUES ('レプリケーション確認: ' || to_char(now(), 'YYYY-MM-DD HH24:MI:SS'));

-- 確認用クエリ
SELECT * FROM replication_status_check ORDER BY id DESC LIMIT 5;