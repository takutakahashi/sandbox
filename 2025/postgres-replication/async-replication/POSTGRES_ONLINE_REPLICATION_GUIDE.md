# PostgreSQL非同期レプリケーションのオンライン設定手順書

この手順書では、既存の稼働中のPostgreSQLデータベースに対して、ダウンタイムを最小限に抑えながら非同期レプリケーションを設定する方法を説明します。既存のシステムをKubernetes環境で運用していることを前提としています。

## 1. 前提条件

- 稼働中のKubernetes環境
- 既存のPostgreSQLプライマリインスタンス
- kubectl CLIツールのインストール
- 必要なKubernetes RBAC権限

## 2. プライマリPostgreSQLをオンラインで設定変更

プライマリサーバーの設定を変更し、再起動せずに反映させます。

```bash
# プライマリPodの名前を取得
PRIMARY_POD=$(kubectl get pod -l app=postgres-primary -n postgres-async-replication -o jsonpath="{.items[0].metadata.name}")

# 現在の設定を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SHOW wal_level;"
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SHOW max_wal_senders;"
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SHOW max_replication_slots;"
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SHOW synchronous_commit;"
```

必要な設定値は以下の通りです：
- `wal_level = logical` (最低でも `replica` が必要)
- `max_wal_senders` >= 5 (レプリカの数に応じて増加)
- `max_replication_slots` >= 5 (レプリカの数に応じて増加)
- `synchronous_commit = off` (非同期レプリケーション用)

### 2.1. ConfigMapを使用して設定を更新

既存のConfigMapを更新するか、新しい設定用ConfigMapを作成します。

```bash
# 既存のConfigMapを確認
kubectl get configmap postgres-primary-config -n postgres-async-replication -o yaml

# 新しいConfigMapを適用（既存の設定に基づいて調整）
cat <<EOF | kubectl apply -n postgres-async-replication -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-primary-config
data:
  postgresql.conf: |
    listen_addresses = '*'
    wal_level = logical
    max_wal_senders = 10
    wal_keep_size = 1GB
    max_replication_slots = 10
    hot_standby = on
    synchronous_commit = off   # 非同期レプリケーションの設定
  pg_hba.conf: |
    # TYPE  DATABASE        USER            ADDRESS                 METHOD
    local   all             all                                     trust
    host    all             all             0.0.0.0/0               md5
    host    replication     all             0.0.0.0/0               md5
EOF
```

### 2.2. 設定ファイルをオンラインでマージ

新しい設定ファイルをプライマリのデータディレクトリにマージし、リロードします。

```bash
# プライマリPodに接続
kubectl exec -it $PRIMARY_POD -n postgres-async-replication -- bash

# 現在のPostgreSQLの設定ディレクトリを確認
ls -la /var/lib/postgresql/data/*.conf

# ConfigMapからの設定を現在の設定にマージ
if [ -f "/etc/postgresql/custom-config/postgresql.conf" ]; then
  cat /etc/postgresql/custom-config/postgresql.conf >> /var/lib/postgresql/data/postgresql.conf
fi

if [ -f "/etc/postgresql/custom-config/pg_hba.conf" ]; then
  cat /etc/postgresql/custom-config/pg_hba.conf >> /var/lib/postgresql/data/pg_hba.conf
fi

# 設定をリロード（再起動なし）
su - postgres -c "pg_ctl reload -D /var/lib/postgresql/data"
# または
psql -U postgres -c "SELECT pg_reload_conf();"

# 設定が反映されたことを確認
psql -U postgres -c "SHOW wal_level;"
psql -U postgres -c "SHOW max_wal_senders;"
psql -U postgres -c "SHOW max_replication_slots;"
psql -U postgres -c "SHOW synchronous_commit;"

exit
```

### 2.3. レプリケーションスロットを作成

プライマリサーバーでレプリケーションスロットを作成します。

```bash
# レプリケーションスロットを作成
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT pg_create_physical_replication_slot('replica_slot');"

# スロットが作成されたことを確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT * FROM pg_replication_slots;"
```

## 3. レプリカPostgreSQLの準備と設定

### 3.1. レプリカ用のConfigMapを作成

レプリカ用のConfigMapを作成または更新します。

```bash
cat <<EOF | kubectl apply -n postgres-async-replication -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-async-replica-config
data:
  postgresql.conf: |
    listen_addresses = '*'
    hot_standby = on
    wal_level = logical
    max_wal_senders = 10
    synchronous_commit = off   # 非同期レプリケーション設定
  pg_hba.conf: |
    # TYPE  DATABASE        USER            ADDRESS                 METHOD
    local   all             all                                     trust
    host    all             all             0.0.0.0/0               md5
EOF
```

### 3.2. レプリカ用のPVCとDeploymentを作成（または既存のものを利用）

Kubernetesマニフェストを適用してレプリカを作成します。

```bash
# レプリカのマニフェストを適用
kubectl apply -f postgres-async-replica.yaml -n postgres-async-replication

# レプリカPodが起動するまで待機
kubectl wait --for=condition=Ready pod -l app=postgres-async-replica -n postgres-async-replication
```

### 3.3. ベースバックアップの取得と初期化

レプリカPodでプライマリからベースバックアップを取得します。

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
# パスワードプロンプトが表示されたら「postgres」と入力

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

## 4. レプリケーション動作の確認

プライマリとレプリカ間の非同期レプリケーションが正しく動作しているか確認します。

```bash
# プライマリでの確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# プライマリで詳細なレプリケーション状態の確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT client_addr, application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) AS sent_lag, pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn) AS write_lag, pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn) AS flush_lag, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag FROM pg_stat_replication;"

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

## 5. 非同期レプリケーションの遅延確認

非同期レプリケーションでは、遅延が発生する可能性があるため、その状態を確認します。

```bash
# プライマリで多数のトランザクションを発生させる
kubectl exec $PRIMARY_POD -n postgres-async-replication -- bash -c "for i in {1..1000}; do psql -U postgres -d replication_test -c \"INSERT INTO test_async (data) VALUES ('bulk-test-$i');\"; done"

# レプリケーションの遅延を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT application_name, client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"

# プライマリとレプリカで行数を比較
PRIMARY_COUNT=$(kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d replication_test -t -c "SELECT COUNT(*) FROM test_async;")
sleep 5  # レプリケーションの遅延を考慮
REPLICA_COUNT=$(kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d replication_test -t -c "SELECT COUNT(*) FROM test_async;")

echo "プライマリの行数: $PRIMARY_COUNT"
echo "レプリカの行数: $REPLICA_COUNT"
```

## 6. 運用中の設定変更

既存のレプリケーション設定を運用中に変更することも可能です。その手順を説明します。

### 6.1. プライマリの設定を変更

例えば、WALの保持サイズを変更する場合：

```bash
# プライマリPodに接続
kubectl exec -it $PRIMARY_POD -n postgres-async-replication -- bash

# 現在の設定を確認
psql -U postgres -c "SHOW wal_keep_size;"

# 設定ファイルを編集
cat >> /var/lib/postgresql/data/postgresql.conf << EOF
# WAL保持サイズの変更
wal_keep_size = 2GB
EOF

# 設定をリロード（再起動不要）
su - postgres -c "pg_ctl reload -D /var/lib/postgresql/data"

# 設定が反映されたことを確認
psql -U postgres -c "SHOW wal_keep_size;"

exit
```

### 6.2. レプリカの設定を変更

レプリカの設定も同様にオンラインで変更できます：

```bash
# レプリカPodに接続
kubectl exec -it $REPLICA_POD -n postgres-async-replication -- bash

# 設定ファイルを編集
cat >> /var/lib/postgresql/data/postgresql.conf << EOF
# 読み取り設定の調整
hot_standby_feedback = on
EOF

# 設定をリロード
su - postgres -c "pg_ctl reload -D /var/lib/postgresql/data"

# 設定が反映されたことを確認
psql -U postgres -c "SHOW hot_standby_feedback;"

exit
```

## 7. レプリケーションスロットの管理

レプリケーションスロットはWALファイルの保持に使用され、適切な管理が重要です。

```bash
# プライマリでスロットの状態を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn FROM pg_replication_slots;"

# レプリカが長期間停止している場合、プライマリのディスクが満杯になるリスクがあるため、
# 必要に応じて不要なスロットを削除
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "-- 必要な場合のみ: SELECT pg_drop_replication_slot('replica_slot');"
```

## 8. トラブルシューティング

レプリケーションに問題がある場合は、以下のコマンドでログを確認します。

```bash
# プライマリのログ確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- tail -f /var/lib/postgresql/data/log/postgresql-*.log

# レプリカのログ確認
kubectl exec $REPLICA_POD -n postgres-async-replication -- tail -f /var/lib/postgresql/data/log/postgresql-*.log

# レプリケーション接続状態の確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT * FROM pg_stat_activity WHERE application_name = 'async_replica';"
```

### 8.1. 一般的な問題と解決策

1. **接続エラー**: `pg_hba.conf`の設定と認証情報を確認します。
2. **スロット使用エラー**: スロットが既に使用されている場合は別の名前で作成します。
3. **WALセグメントの欠落**: `wal_keep_size`または`max_slot_wal_keep_size`設定を増加します。

## 9. フェイルオーバー手順

プライマリに障害が発生した場合、レプリカを昇格させる手順：

```bash
# レプリカPodに接続
kubectl exec -it $REPLICA_POD -n postgres-async-replication -- bash

# レプリカをプライマリモードに昇格
su - postgres -c "pg_ctl promote -D /var/lib/postgresql/data"

# 昇格の確認
psql -U postgres -c "SELECT pg_is_in_recovery();"

exit
```

フェイルオーバー後のアプリケーション接続先の変更は、Kubernetesサービスの設定変更で対応できます。

## 10. パフォーマンスモニタリングと最適化

レプリケーションのパフォーマンスを定期的に監視することが重要です。

```bash
# レプリケーションの状態と遅延を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT pid, application_name, client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"

# プライマリでのWAL生成レート
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SELECT pg_current_wal_lsn(), pg_walfile_name(pg_current_wal_lsn());"

# レプリカでのWAL受信状態
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();"

# レプリカでの遅延を秒単位で確認
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -c "SELECT extract(epoch from now() - pg_last_xact_replay_timestamp()) AS replay_lag_seconds;"
```

### 10.1. パフォーマンス最適化のポイント

1. **ネットワーク最適化**: プライマリとレプリカ間のネットワーク帯域幅と遅延を確認します。
2. **リソース配分**: レプリカに十分なCPU、メモリ、ディスクI/Oリソースがあることを確認します。
3. **WALセグメントサイズ**: 必要に応じて`wal_segment_size`を調整します（PostgreSQLの再初期化が必要）。
4. **チェックポイント設定**: `checkpoint_timeout`と`max_wal_size`を調整して書き込みバーストを管理します。

## 11. 運用上のベストプラクティス

1. **定期的なモニタリング**: レプリケーションの遅延と状態を定期的に監視
2. **アラート設定**: レプリケーション遅延やエラーに対するアラートを設定
3. **バックアップの継続**: レプリケーションはバックアップの代替にならないため、定期的にバックアップを実行
4. **テスト環境での練習**: フェイルオーバー手順を定期的にテスト環境で練習
5. **ドキュメント化**: 設定変更やフェイルオーバー手順をドキュメント化し、チーム内で共有

## 12. 複数データベースを持つPostgreSQLの論理レプリケーション設定

複数のデータベースを持つPostgreSQLをレプリケーションする場合、論理レプリケーション（logical replication）を使用するのが適切です。論理レプリケーションでは、データベースごと、さらにはテーブルごとに選択的にレプリケーションを設定できます。

### 12.1. 論理レプリケーションの前提条件

論理レプリケーションには、以下の前提条件があります：

1. PostgreSQL 10以上のバージョンが必要（推奨は12以上）
2. プライマリとレプリカの両方で`wal_level = logical`の設定が必要
3. 各データベースごとに個別に発行（publication）と購読（subscription）の設定が必要

### 12.2. プライマリサーバーの論理レプリケーション設定

まず、プライマリサーバーの設定を変更します：

```bash
# プライマリPodの名前を取得
PRIMARY_POD=$(kubectl get pod -l app=postgres-primary -n postgres-async-replication -o jsonpath="{.items[0].metadata.name}")

# データベース一覧を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "\l"

# 設定ファイルにwal_level = logicalが含まれていることを確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- grep "wal_level" /var/lib/postgresql/data/postgresql.conf

# wal_level = logicalに設定されていない場合は設定を追加
kubectl exec -it $PRIMARY_POD -n postgres-async-replication -- bash -c "echo 'wal_level = logical' >> /var/lib/postgresql/data/postgresql.conf"

# 設定をリロードまたはサーバーを再起動
kubectl exec $PRIMARY_POD -n postgres-async-replication -- su - postgres -c "pg_ctl reload -D /var/lib/postgresql/data"
# または、必要に応じて再起動（wal_levelの変更は再起動が必要）
# kubectl exec $PRIMARY_POD -n postgres-async-replication -- su - postgres -c "pg_ctl restart -D /var/lib/postgresql/data"

# wal_levelの設定を確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "SHOW wal_level;"
```

### 12.3. レプリカサーバーの論理レプリケーション設定

レプリカサーバーも論理レプリケーションに対応するよう設定します：

```bash
# レプリカPodの名前を取得
REPLICA_POD=$(kubectl get pod -l app=postgres-async-replica -n postgres-async-replication -o jsonpath="{.items[0].metadata.name}")

# レプリカでも同様にwal_level = logicalを設定
kubectl exec -it $REPLICA_POD -n postgres-async-replication -- bash -c "echo 'wal_level = logical' >> /var/lib/postgresql/data/postgresql.conf"

# 設定をリロードまたはサーバーを再起動
kubectl exec $REPLICA_POD -n postgres-async-replication -- su - postgres -c "pg_ctl reload -D /var/lib/postgresql/data"
# または、必要に応じて再起動
# kubectl exec $REPLICA_POD -n postgres-async-replication -- su - postgres -c "pg_ctl restart -D /var/lib/postgresql/data"

# wal_levelの設定を確認
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -c "SHOW wal_level;"
```

### 12.4. 複数データベースの論理レプリケーション設定

各データベースに対して個別に論理レプリケーションを設定します：

```bash
# レプリケーションするデータベースのリスト
DATABASES=("db1" "db2" "db3")  # 実際のデータベース名に置き換えてください

# 各データベースでスキーマとテーブルを作成（レプリカ側）
for DB in "${DATABASES[@]}"; do
  # プライマリ側にデータベースが存在するか確認
  DB_EXISTS=$(kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -t -c "SELECT 1 FROM pg_database WHERE datname='$DB';")
  
  if [ -z "$DB_EXISTS" ]; then
    # データベースが存在しない場合は作成
    echo "プライマリにデータベース $DB を作成します"
    kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "CREATE DATABASE $DB;"
  fi
  
  # レプリカ側にも同名のデータベースを作成
  REPLICA_DB_EXISTS=$(kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -t -c "SELECT 1 FROM pg_database WHERE datname='$DB';")
  
  if [ -z "$REPLICA_DB_EXISTS" ]; then
    echo "レプリカにデータベース $DB を作成します"
    kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -c "CREATE DATABASE $DB;"
  fi
  
  # プライマリ側のテーブル一覧を取得
  TABLES=$(kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DB -t -c "SELECT tablename FROM pg_tables WHERE schemaname='public';")
  
  # テーブルがない場合はスキップ
  if [ -z "$TABLES" ]; then
    echo "データベース $DB にテーブルが見つかりません"
    continue
  fi
  
  # レプリカ側に同じスキーマを作成
  for TABLE in $TABLES; do
    # テーブル名の前後の空白を削除
    TABLE=$(echo $TABLE | xargs)
    
    # テーブル定義を取得
    TABLE_DEF=$(kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DB -t -c "\d+ $TABLE")
    
    # テーブル作成DDLを取得（pg_dump使用）
    TABLE_DDL=$(kubectl exec $PRIMARY_POD -n postgres-async-replication -- pg_dump -U postgres -d $DB -t $TABLE --schema-only)
    
    # レプリカ側でテーブルを作成
    echo "$TABLE_DDL" | kubectl exec -i $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB
  done
  
  # プライマリ側でpublication作成
  kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "DROP PUBLICATION IF EXISTS pub_$DB;"
  kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "CREATE PUBLICATION pub_$DB FOR ALL TABLES;"
  
  # レプリカ側でsubscription作成
  kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "DROP SUBSCRIPTION IF EXISTS sub_$DB;"
  kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "CREATE SUBSCRIPTION sub_$DB CONNECTION 'host=postgres-primary port=5432 dbname=$DB user=postgres password=postgres' PUBLICATION pub_$DB;"
  
  echo "データベース $DB の論理レプリケーションを設定しました"
done
```

### 12.5. 論理レプリケーションの確認

各データベースごとにレプリケーションが正しく機能しているか確認します：

```bash
# 各データベースでレプリケーションをテスト
for DB in "${DATABASES[@]}"; do
  echo "データベース $DB のレプリケーションをテストします："
  
  # テスト用テーブルの作成（まだ存在しない場合）
  kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "CREATE TABLE IF NOT EXISTS repl_test (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
  
  # データ挿入
  kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "INSERT INTO repl_test (data) VALUES ('test-$DB-$(date +%s)');"
  
  # プライマリでデータ確認
  echo "プライマリでのデータ:"
  kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "SELECT * FROM repl_test ORDER BY id DESC LIMIT 5;"
  
  # レプリケーションの反映を待機
  sleep 5
  
  # レプリカでデータ確認
  echo "レプリカでのデータ:"
  kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "SELECT * FROM repl_test ORDER BY id DESC LIMIT 5;"
done
```

### 12.6. 論理レプリケーションのステータス確認

レプリケーションの状態を定期的に確認します：

```bash
# プライマリ側のPublicationの状態
for DB in "${DATABASES[@]}"; do
  echo "データベース $DB のPublication状態:"
  kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "SELECT * FROM pg_publication;"
  kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "SELECT * FROM pg_publication_tables;"
done

# レプリカ側のSubscriptionの状態
for DB in "${DATABASES[@]}"; do
  echo "データベース $DB のSubscription状態:"
  kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "SELECT subname, subenabled, subconninfo, subslotname, subsynccommit FROM pg_subscription;"
done

# レプリケーション進行状況の確認
for DB in "${DATABASES[@]}"; do
  echo "データベース $DB のレプリケーション進行状況:"
  kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "SELECT * FROM pg_stat_subscription;"
done
```

### 12.7. 新規テーブルの追加

運用中に新しいテーブルを追加する場合の手順：

```bash
# 例: db1データベースに新しいテーブルを追加
DATABASE="db1"

# プライマリ側で新しいテーブルを作成
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DATABASE -c "CREATE TABLE new_table (id SERIAL PRIMARY KEY, name TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"

# publicationが「FOR ALL TABLES」の場合、追加のアクションは不要
# 特定のテーブルを指定したpublicationの場合、テーブルを追加
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DATABASE -c "ALTER PUBLICATION pub_$DATABASE ADD TABLE new_table;"

# レプリカ側でテーブル構造を作成（必要な場合）
# テーブルDDLを取得
TABLE_DDL=$(kubectl exec $PRIMARY_POD -n postgres-async-replication -- pg_dump -U postgres -d $DATABASE -t new_table --schema-only)

# レプリカ側でテーブルを作成
echo "$TABLE_DDL" | kubectl exec -i $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DATABASE

# レプリケーションが機能しているか確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $DATABASE -c "INSERT INTO new_table (name) VALUES ('test-new-table');"
sleep 5
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DATABASE -c "SELECT * FROM new_table;"
```

### 12.8. 新規データベースの追加

運用中に新しいデータベースを追加する場合の手順：

```bash
# 新しいデータベース名
NEW_DB="new_database"

# プライマリ側にデータベースを作成
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -c "CREATE DATABASE $NEW_DB;"

# レプリカ側にも同じデータベースを作成
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -c "CREATE DATABASE $NEW_DB;"

# テスト用テーブルをプライマリ側に作成
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $NEW_DB -c "CREATE TABLE test_table (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"

# レプリカ側にも同じテーブル構造を作成
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $NEW_DB -c "CREATE TABLE test_table (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"

# プライマリ側でpublicationを作成
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $NEW_DB -c "CREATE PUBLICATION pub_$NEW_DB FOR ALL TABLES;"

# レプリカ側でsubscriptionを作成
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $NEW_DB -c "CREATE SUBSCRIPTION sub_$NEW_DB CONNECTION 'host=postgres-primary port=5432 dbname=$NEW_DB user=postgres password=postgres' PUBLICATION pub_$NEW_DB;"

# レプリケーションの動作確認
kubectl exec $PRIMARY_POD -n postgres-async-replication -- psql -U postgres -d $NEW_DB -c "INSERT INTO test_table (data) VALUES ('test-data-$NEW_DB');"
sleep 5
kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $NEW_DB -c "SELECT * FROM test_table;"
```

### 12.9. 論理レプリケーションのトラブルシューティング

論理レプリケーションで起こりがちな問題と対処法：

1. **テーブルスキーマの不一致**：プライマリとレプリカで同一のテーブル構造が必要です。
   ```bash
   # スキーマを比較
   kubectl exec $PRIMARY_POD -n postgres-async-replication -- pg_dump -U postgres -d $DB --schema-only > primary_schema.sql
   kubectl exec $REPLICA_POD -n postgres-async-replication -- pg_dump -U postgres -d $DB --schema-only > replica_schema.sql
   diff primary_schema.sql replica_schema.sql
   ```

2. **Subscriptionが同期されない**：
   ```bash
   # Subscriptionのステータスを確認
   kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "SELECT * FROM pg_stat_subscription;"
   
   # 必要に応じてSubscriptionを無効化して再度有効化
   kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "ALTER SUBSCRIPTION sub_$DB DISABLE;"
   kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "ALTER SUBSCRIPTION sub_$DB ENABLE;"
   ```

3. **接続エラー**：
   ```bash
   # レプリカのログを確認
   kubectl exec $REPLICA_POD -n postgres-async-replication -- tail -f /var/lib/postgresql/data/log/postgresql-*.log
   ```

### 12.10. 論理レプリケーションでのフェイルオーバー考慮点

論理レプリケーションでのフェイルオーバーは物理レプリケーションと異なります：

1. 各データベースが独立してレプリケーションされているため、個別に確認が必要
2. フェイルオーバー時にはSubscriptionを削除し、新しいプライマリで新たにPublicationを作成する必要がある場合も

```bash
# フェイルオーバー時の各データベースの処理例
for DB in "${DATABASES[@]}"; do
  echo "データベース $DB のフェイルオーバー処理："
  
  # レプリカをプライマリとして使用する場合、Subscriptionを削除
  kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "DROP SUBSCRIPTION IF EXISTS sub_$DB;"
  
  # 以前のレプリカ（新プライマリ）でPublicationを作成
  kubectl exec $REPLICA_POD -n postgres-async-replication -- psql -U postgres -d $DB -c "CREATE PUBLICATION pub_$DB FOR ALL TABLES;"
  
  # 新しいレプリカを設定する場合は、そちらでSubscriptionを作成
  # ...
done
```

## まとめ

この手順書を使用することで、既存のPostgreSQLサーバーを運用しながらオンラインでレプリケーションを設定できます。ダウンタイムを最小限に抑えながら高可用性環境を構築することが可能です。複数のデータベースを持つ環境では、論理レプリケーションを使用することで、データベースごとに選択的なレプリケーションが可能になります。

非同期レプリケーションはパフォーマンスに優れていますが、レプリカへのデータ反映に遅延が生じる場合があることを念頭に置いてください。高可用性が必要な場合は、フェイルオーバー手順を十分にテストし、必要に応じて自動化することをお勧めします。また、論理レプリケーションはテーブル構造の一致が必要など、物理レプリケーションとは異なる制約がありますので、その特性を理解した上で活用してください。