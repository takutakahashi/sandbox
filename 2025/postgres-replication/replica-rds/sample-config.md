# ソースデータベース（PostgreSQL）の設定サンプル

以下のサンプル設定を参考にして、非同期論理レプリケーション用のソースデータベースを構成してください。

## postgresql.conf の設定例

```
# 基本設定
listen_addresses = '*'
port = 5432

# レプリケーション設定
wal_level = logical                  # 論理レプリケーションに必要
max_replication_slots = 10           # 必要に応じて調整
max_wal_senders = 10                 # 必要に応じて調整
max_logical_replication_workers = 4  # 必要に応じて調整
max_worker_processes = 10            # 必要に応じて調整

# パフォーマンス関連
shared_buffers = 1GB                 # サーバのメモリに合わせて調整
work_mem = 16MB                      # サーバのメモリに合わせて調整
maintenance_work_mem = 256MB         # サーバのメモリに合わせて調整

# ログ設定
log_destination = 'stderr'
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_truncate_on_rotation = on
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000    # 1秒以上かかったクエリをログに記録
log_checkpoints = on
log_connections = on
log_disconnections = on
log_line_prefix = '%m [%p] %q%u@%d '
log_statement = 'ddl'                # DDL文をログに記録
```

## pg_hba.conf の設定例

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# ローカル接続
local   all             postgres                                peer
local   all             all                                     peer

# IPv4ローカル接続
host    all             all             127.0.0.1/32            scram-sha-256

# IPv6ローカル接続
host    all             all             ::1/128                 scram-sha-256

# レプリケーション用設定（RDSのIP範囲に調整してください）
host    replication     replicator      <RDS-IP>/32             scram-sha-256
host    <DB-NAME>       replicator      <RDS-IP>/32             scram-sha-256

# 必要に応じて追加の接続許可
host    all             all             <許可するIP範囲>        scram-sha-256
```

## レプリケーションユーザーとパブリケーション作成のSQLサンプル

```sql
-- レプリケーションユーザーの作成
CREATE ROLE replicator WITH LOGIN PASSWORD 'secure_password' REPLICATION;

-- データベース権限の付与
GRANT CONNECT ON DATABASE my_database TO replicator;
GRANT USAGE ON SCHEMA public TO replicator;

-- テーブル単位の権限付与（レプリケーション対象テーブルごとに実行）
GRANT SELECT ON TABLE customers TO replicator;
GRANT SELECT ON TABLE orders TO replicator;
GRANT SELECT ON TABLE products TO replicator;

-- パブリケーションの作成（特定のテーブル用）
CREATE PUBLICATION my_publication FOR TABLE customers, orders, products;

-- または全テーブル用パブリケーションを作成
-- CREATE PUBLICATION my_publication FOR ALL TABLES;
```

## RDSインスタンスでのサブスクリプション作成のSQLサンプル

```sql
-- サブスクリプションの作成
CREATE SUBSCRIPTION my_subscription
CONNECTION 'host=<ソースDBのIPまたはホスト名> port=5432 dbname=my_database user=replicator password=secure_password'
PUBLICATION my_publication;

-- サブスクリプションの状態確認
SELECT * FROM pg_stat_subscription;
```

## レプリケーション状態の監視スクリプト例

以下のシェルスクリプトを使用して、レプリケーションの状態を定期的に監視することができます。

```bash
#!/bin/bash

# RDSへの接続情報
RDS_ENDPOINT="your-rds-endpoint.rds.amazonaws.com"
RDS_PORT="5432"
RDS_USER="postgres"
RDS_DB="my_database"

# レプリケーション状態の確認
echo "Checking replication status at $(date)"
PGPASSWORD=your_password psql -h $RDS_ENDPOINT -p $RDS_PORT -U $RDS_USER -d $RDS_DB -c "SELECT * FROM pg_stat_subscription;"

# レプリケーション遅延を確認
echo "Checking replication lag"
PGPASSWORD=your_password psql -h $RDS_ENDPOINT -p $RDS_PORT -U $RDS_USER -d $RDS_DB -c "
SELECT 
  now() - pg_last_committed_xact()::timestamptz AS replication_lag 
FROM pg_stat_subscription;"
```