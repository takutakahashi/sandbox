# PostgreSQLレプリケーション設定手順

Kubernetes上で2台のPostgreSQL間のレプリケーションを手動で設定するための手順です。

## 1. マニフェストのデプロイ

```bash
# プライマリPostgreSQLのデプロイ
kubectl apply -f postgres-primary.yaml

# レプリカPostgreSQLのデプロイ
kubectl apply -f postgres-replica.yaml

# デプロイが完了するまで待機
kubectl wait --for=condition=Ready pod -l app=postgres-primary
kubectl wait --for=condition=Ready pod -l app=postgres-replica
```

## 2. プライマリPostgreSQLの設定

プライマリPostgreSQLの`postgresql.conf`と`pg_hba.conf`を編集して、レプリケーションを許可します。

```bash
# プライマリPodに接続
PRIMARY_POD=$(kubectl get pod -l app=postgres-primary -o jsonpath="{.items[0].metadata.name}")
kubectl exec -it $PRIMARY_POD -- bash

# postgresql.confの編集
cat >> /var/lib/postgresql/data/postgresql.conf << EOF
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
wal_keep_segments = 64
hot_standby = on
EOF

# pg_hba.confの編集
cat >> /var/lib/postgresql/data/pg_hba.conf << EOF
host    replication     postgres        0.0.0.0/0               md5
EOF

# PostgreSQLの再起動
exit
kubectl exec $PRIMARY_POD -- pg_ctl -D /var/lib/postgresql/data reload
```

## 3. レプリカPostgreSQLの設定

レプリカのデータディレクトリを初期化して、pg_basebackupでプライマリからデータを複製します。

```bash
# レプリカPodに接続
REPLICA_POD=$(kubectl get pod -l app=postgres-replica -o jsonpath="{.items[0].metadata.name}")
kubectl exec -it $REPLICA_POD -- bash

# PostgreSQLの停止
pg_ctl -D /var/lib/postgresql/data stop -m fast

# データディレクトリの初期化
rm -rf /var/lib/postgresql/data/*
chown postgres:postgres /var/lib/postgresql/data

# プライマリからベースバックアップを取得
su - postgres -c "pg_basebackup -h postgres-primary -p 5432 -U postgres -D /var/lib/postgresql/data -P -Xs -R"

# recovery.confの設定（PostgreSQL 12以降は不要、standby.signalファイルを作成）
touch /var/lib/postgresql/data/standby.signal

# PostgreSQL 15では以下の設定をpostgresql.confに追加
cat >> /var/lib/postgresql/data/postgresql.conf << EOF
primary_conninfo = 'host=postgres-primary port=5432 user=postgres password=postgres'
EOF

# PostgreSQLの起動
pg_ctl -D /var/lib/postgresql/data start

exit
```

## 4. レプリケーションの確認

プライマリとレプリカ間のレプリケーションが正しく動作しているか確認します。

```bash
# プライマリでの確認
kubectl exec $PRIMARY_POD -- psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# シンプルなテスト
kubectl exec $PRIMARY_POD -- psql -U postgres -c "CREATE TABLE test (id SERIAL PRIMARY KEY, name TEXT);"
kubectl exec $PRIMARY_POD -- psql -U postgres -c "INSERT INTO test (name) VALUES ('test1'), ('test2');"

# レプリカで確認
kubectl exec $REPLICA_POD -- psql -U postgres -c "SELECT * FROM test;"
```

## 5. 詳細なテストデータの作成と検証

より詳細なテストを行うには、用意されたSQLスクリプトを使用します。

```bash
# テストデータの作成（提供されたSQLスクリプトを使用）
kubectl cp init-test-data.sql $PRIMARY_POD:/tmp/
kubectl exec $PRIMARY_POD -- bash -c "psql -U postgres < /tmp/init-test-data.sql"

# レプリカにデータが反映されているか確認
kubectl exec $REPLICA_POD -- psql -U postgres -c "SELECT COUNT(*) FROM replication_test.users;"
kubectl exec $REPLICA_POD -- psql -U postgres -c "SELECT COUNT(*) FROM replication_test.products;"

# 自動検証スクリプトを使用する場合
./verify-replication.sh
```

## 6. 継続的な検証

継続的にレプリケーションを検証するには、定期的にプライマリに新しいデータを挿入し、レプリカに反映されるか確認します。

```bash
# チェック用スクリプトの実行
kubectl cp check-replication.sql $PRIMARY_POD:/tmp/
kubectl exec $PRIMARY_POD -- bash -c "psql -U postgres < /tmp/check-replication.sql"

# レプリカで結果を確認
kubectl exec $REPLICA_POD -- psql -U postgres -c "SELECT * FROM replication_test.replication_status_check ORDER BY id DESC LIMIT 1;"
```

## 7. トラブルシューティング

レプリケーションに問題がある場合は、以下のコマンドでログを確認します。

```bash
# プライマリのログ確認
kubectl exec $PRIMARY_POD -- tail -f /var/lib/postgresql/data/log/*.log

# レプリカのログ確認
kubectl exec $REPLICA_POD -- tail -f /var/lib/postgresql/data/log/*.log
```