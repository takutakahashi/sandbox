# PostgreSQL非同期レプリケーション設定手順

このガイドでは、Kubernetes上でPostgreSQLの非同期レプリケーションを設定する方法について説明します。非同期レプリケーションでは、プライマリでのトランザクション完了がレプリカでの書き込み完了を待たないため、パフォーマンスが向上しますが、その分レプリカでのデータ反映に遅延が発生する場合があります。

## 1. 前提条件

- Kubernetesクラスターへのアクセス
- kubectl CLIツールのインストール
- 必要なKubernetes RBAC権限

## 2. 環境のデプロイ

まず、プライマリとレプリカのPostgreSQLサーバーをKubernetesにデプロイします。

```bash
# 名前空間の作成
kubectl create namespace postgres-async-replication

# マニフェストのデプロイ
kubectl apply -k .

# または個別にファイルを適用
kubectl apply -f postgres-primary.yaml -n postgres-async-replication
kubectl apply -f postgres-async-replica.yaml -n postgres-async-replication

# デプロイが完了するまで待機
kubectl wait --for=condition=Ready pod -l app=postgres-primary -n postgres-async-replication
kubectl wait --for=condition=Ready pod -l app=postgres-async-replica -n postgres-async-replication
```

## 3. プライマリPostgreSQLの設定

プライマリには既にConfigMapで基本設定を投入していますが、レプリケーションスロットを作成する必要があります。

```bash
# プライマリPodの名前を取得
PRIMARY_POD=$(kubectl get pod -l app=postgres-primary -n postgres-async-replication -o jsonpath="{.items[0].metadata.name}")

# プライマリサーバーに接続
kubectl exec -it $PRIMARY_POD -n postgres-async-replication -- bash

# PostgreSQLの設定ディレクトリを探す
ls -la /var/lib/postgresql/data/*.conf

# カスタム設定ファイルが適用されているか確認
# 既存の設定ファイルに ConfigMap の内容をマージする
if [ -f "/etc/postgresql/custom-config/postgresql.conf" ]; then
  cat /etc/postgresql/custom-config/postgresql.conf >> /var/lib/postgresql/data/postgresql.conf
fi

if [ -f "/etc/postgresql/custom-config/pg_hba.conf" ]; then
  cat /etc/postgresql/custom-config/pg_hba.conf >> /var/lib/postgresql/data/pg_hba.conf
fi

# PostgreSQLを再起動して設定を反映
pg_ctl -D /var/lib/postgresql/data restart

# PostgreSQLに接続してレプリケーションスロットを作成
su - postgres

psql -c "SELECT pg_create_physical_replication_slot('replica_slot');"

# 設定の確認
psql -c "SHOW wal_level;"
psql -c "SHOW max_wal_senders;"
psql -c "SHOW max_replication_slots;"
psql -c "SHOW synchronous_commit;"

# レプリケーションスロットの確認
psql -c "SELECT * FROM pg_replication_slots;"

# 終了
exit
exit
```

## 4. レプリカPostgreSQLの設定

レプリカサーバーを設定して、プライマリからの非同期レプリケーションを開始します。

```bash
# レプリカPodの名前を取得
REPLICA_POD=$(kubectl get pod -l app=postgres-async-replica -n postgres-async-replication -o jsonpath="{.items[0].metadata.name}")

# レプリカサーバーに接続
kubectl exec -it $REPLICA_POD -n postgres-async-replication -- bash

# PostgreSQLの停止
pg_ctl -D /var/lib/postgresql/data stop -m fast

# データディレクトリの初期化
rm -rf /var/lib/postgresql/data/*
chown postgres:postgres /var/lib/postgresql/data

# プライマリからベースバックアップを取得
su - postgres -c "pg_basebackup -h postgres-primary -U postgres -W -D /var/lib/postgresql/data -Fp -Xs -P -R -S replica_slot"

# レプリカの設定の追加
cat > /var/lib/postgresql/data/standby.signal << EOF
# standby mode
EOF

cat >> /var/lib/postgresql/data/postgresql.conf << EOF
# Replication configuration
primary_conninfo = 'host=postgres-primary port=5432 user=postgres password=postgres application_name=async_replica'
primary_slot_name = 'replica_slot'
hot_standby = on
EOF

# カスタム設定ファイルをマージ
if [ -f "/etc/postgresql/custom-config/postgresql.conf" ]; then
  cat /etc/postgresql/custom-config/postgresql.conf >> /var/lib/postgresql/data/postgresql.conf
fi

if [ -f "/etc/postgresql/custom-config/pg_hba.conf" ]; then
  cat /etc/postgresql/custom-config/pg_hba.conf >> /var/lib/postgresql/data/pg_hba.conf
fi

# PostgreSQLの起動
pg_ctl -D /var/lib/postgresql/data start

# 設定の確認
su - postgres

psql -c "SHOW hot_standby;"
psql -c "SHOW synchronous_commit;"

# レプリケーション状態の確認
psql -c "SELECT pg_is_in_recovery();"

exit
exit
```

## 5. レプリケーション動作の確認

プライマリとレプリカ間の非同期レプリケーションが正しく動作しているか確認します。

```bash
# プライマリでの確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# タイムスタンプを含むテストテーブルを作成
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "CREATE DATABASE replication_test;"
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d replication_test -c "CREATE TABLE test_async (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"

# データを挿入
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d replication_test -c "INSERT INTO test_async (data) VALUES ('test1');"
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d replication_test -c "INSERT INTO test_async (data) VALUES ('test2');"

# プライマリでデータを確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d replication_test -c "SELECT * FROM test_async;"

# 少し待機してからレプリカでデータを確認
sleep 2
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d replication_test -c "SELECT * FROM test_async;"
```

## 6. 非同期レプリケーションの遅延確認

非同期レプリケーションでは、遅延が発生する可能性があるため、その状態を確認します。

```bash
# プライマリで多数のトランザクションを発生させる
kubectl exec $PRIMARY_POD -n postgres-async-replication -- bash -c "for i in {1..1000}; do psql -U postgres -d replication_test -c \"INSERT INTO test_async (data) VALUES ('bulk-test-$i');\"; done"

# レプリケーションの遅延を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT application_name, client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"

# プライマリとレプリカで行数を比較
PRIMARY_COUNT=$(kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d replication_test -t -c "SELECT COUNT(*) FROM test_async;")
REPLICA_COUNT=$(kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d replication_test -t -c "SELECT COUNT(*) FROM test_async;")

echo "プライマリの行数: $PRIMARY_COUNT"
echo "レプリカの行数: $REPLICA_COUNT"
```

## 7. レプリケーションスロットの管理

レプリケーションスロットは WAL ファイルの保持に使用されます。適切な管理が重要です。

```bash
# プライマリでスロットの状態を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots;"

# レプリカが長期間停止している場合、プライマリのディスクが満杯になるリスクがあるため、不要なスロットを削除する方法を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "-- 必要に応じて: SELECT pg_drop_replication_slot('replica_slot');"
```

## 8. トラブルシューティング

レプリケーションに問題がある場合は、以下のコマンドでログを確認します。

```bash
# プライマリのログ確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- tail -f /var/lib/postgresql/data/log/*.log

# レプリカのログ確認
kubectl exec $REPLICA_POD -n postgres-async-replication -- tail -f /var/lib/postgresql/data/log/*.log

# レプリケーション接続状態の確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT * FROM pg_stat_activity WHERE application_name = 'async_replica';"
```

## 9. 非同期レプリケーション特有の注意点

1. **データの一貫性**: 非同期レプリケーションでは、プライマリで完了したトランザクションがレプリカにすぐに反映されない可能性があります。クリティカルな読み取り操作が必要な場合は、プライマリを使用するか同期レプリケーションを検討してください。

2. **災害復旧**: プライマリに障害が発生した場合、最新のトランザクションがレプリカにレプリケートされていない可能性があります。

3. **レプリカ昇格**: 障害時にレプリカをプライマリに昇格させる場合：

```bash
# レプリカをプライマリモードに切り替え
kubectl exec $REPLICA_POD -n postgres-async-replication -- bash -c "pg_ctl -D /var/lib/postgresql/data promote"

# 昇格後、以前のプライマリを新しいレプリカとして再構成する必要があります
```

## 10. パフォーマンスモニタリング

レプリケーションのパフォーマンスを定期的に監視することが重要です。

```bash
# レプリケーションの状態と遅延を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT pid, application_name, client_addr, backend_start, state, sync_state, replay_lag FROM pg_stat_replication;"

# プライマリでのWAL生成レート
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT pg_current_wal_lsn(), pg_walfile_name(pg_current_wal_lsn());"

# レプリカでのWAL受信状態
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();"
```

非同期レプリケーションはパフォーマンスが高く、多くのシステムに適していますが、データの一貫性よりもパフォーマンスが優先される場合に最適です。