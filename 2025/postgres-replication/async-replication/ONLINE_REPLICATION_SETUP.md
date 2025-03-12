# PostgreSQL非同期レプリケーションのオンライン設定手順

このドキュメントでは、PostgreSQLの非同期レプリケーションを既存の稼働中のデータベースに対してダウンタイムを最小限に抑えて設定する方法を説明します。この方法では、プライマリサーバーの再起動を避け、オンラインでレプリケーションを構成します。

## 1. 前提条件

- 稼働中のプライマリPostgreSQLサーバー
- レプリケーション用の新規PostgreSQLインスタンス
- プライマリとレプリカサーバー間のネットワーク接続
- レプリケーション用のユーザー権限
- PostgreSQL 10以上のバージョン（推奨は12以上）

## 2. プライマリサーバーでの準備（再起動なし）

### 2.1. レプリケーション設定の確認と修正

以下の設定パラメータが適切な値になっているか確認します。これらの設定は、ほとんどの場合`postgresql.conf`の変更とリロードだけで対応可能です。

```sql
-- プライマリサーバーに接続
psql -U postgres

-- 現在の設定を確認
SHOW wal_level;
SHOW max_wal_senders;
SHOW max_replication_slots;
SHOW synchronous_commit;
```

必要な設定値:
- `wal_level = logical` (最低でも `replica` が必要)
- `max_wal_senders` >= 5 (レプリカの数に応じて増加)
- `max_replication_slots` >= 5 (レプリカの数に応じて増加)
- `synchronous_commit = off` (非同期レプリケーション用)

設定を変更する場合は、`postgresql.conf`を編集して、リロードします:

```bash
# postgresql.confを編集（PostgreSQLデータディレクトリにあります）
nano /var/lib/postgresql/data/postgresql.conf

# 設定を以下のように変更
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
synchronous_commit = off
```

### 2.2. クライアント認証設定の更新

レプリケーション用の接続を許可するために`pg_hba.conf`を編集します:

```bash
# pg_hba.confを編集
nano /var/lib/postgresql/data/pg_hba.conf

# 以下の行を追加
host    replication     postgres        <レプリカのIPアドレス>/32         md5
host    replication     replicator      <レプリカのIPアドレス>/32         md5
```

### 2.3. 設定のリロード（再起動なし）

設定変更を反映するために、PostgreSQLの設定をリロードします:

```sql
-- SQLから設定をリロードする場合
SELECT pg_reload_conf();
```

または、システムコマンドからリロードする場合:

```bash
# システムコマンドからリロードする場合
pg_ctl reload -D /var/lib/postgresql/data
```

### 2.4. レプリケーション用スロットの作成

レプリケーションスロットを作成してWALファイルを確保します:

```sql
-- レプリケーションスロットの作成
SELECT pg_create_physical_replication_slot('replica_slot_1');

-- スロットの確認
SELECT * FROM pg_replication_slots;
```

### 2.5. レプリケーション用ユーザーの作成（必要に応じて）

専用のレプリケーションユーザーを作成する場合:

```sql
-- レプリケーション権限を持つユーザーの作成
CREATE USER replicator WITH REPLICATION PASSWORD 'strong_password';
```

## 3. レプリカサーバーの初期化

### 3.1. PostgreSQLのインストールと初期設定

新しいサーバーにPostgreSQLをインストールし、初期化します。バージョンはプライマリと同じかそれ以降を使用します。

### 3.2. ベースバックアップの取得

プライマリサーバーからベースバックアップを取得します。この操作はプライマリサーバーの稼働中に行えます:

```bash
# レプリカサーバー上で実行
# 既存のPostgreSQLデータディレクトリを空にする
rm -rf /var/lib/postgresql/data/*

# ベースバックアップの取得
pg_basebackup -h <プライマリのIPアドレス> -p 5432 -U replicator -D /var/lib/postgresql/data -Fp -Xs -P -R -S replica_slot_1
```

パラメータの説明:
- `-h`: プライマリサーバーのホスト名またはIPアドレス
- `-U`: レプリケーション権限を持つユーザー
- `-D`: バックアップの保存先（レプリカのデータディレクトリ）
- `-Fp`: プレーンフォーマットでバックアップ
- `-Xs`: WALストリーミングモード
- `-P`: 進捗情報の表示
- `-R`: レプリケーション設定を自動的に作成
- `-S`: 使用するレプリケーションスロット名

### 3.3. レプリカの設定

ベースバックアップに`-R`オプションを使用した場合、必要な設定ファイルは自動的に生成されます。不足している場合は手動で設定します:

```bash
# standby.signalファイルを作成
touch /var/lib/postgresql/data/standby.signal

# postgresql.confを編集してプライマリ接続情報を追加
cat >> /var/lib/postgresql/data/postgresql.conf << EOF
# レプリケーション設定
primary_conninfo = 'host=<プライマリのIPアドレス> port=5432 user=replicator password=strong_password application_name=replica_1'
primary_slot_name = 'replica_slot_1'
hot_standby = on
EOF
```

## 4. レプリカサーバーの起動

設定が完了したら、レプリカサーバーを起動します:

```bash
# PostgreSQLサービスを起動
systemctl start postgresql
# または
pg_ctl -D /var/lib/postgresql/data start
```

## 5. レプリケーションの確認とモニタリング

### 5.1. レプリケーション状態の確認

プライマリサーバーでレプリケーションの状態を確認します:

```sql
-- レプリケーション接続とステータス確認
SELECT client_addr, usename, application_name, state, sync_state, 
       pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) AS sent_lag,
       pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn) AS write_lag,
       pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn) AS flush_lag,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag
FROM pg_stat_replication;
```

プライマリとレプリカ間のレプリケーション遅延をモニタリングします:

```sql
-- プライマリで実行
SELECT pg_current_wal_lsn(), pg_walfile_name(pg_current_wal_lsn());

-- レプリカで実行
SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
       pg_last_xact_replay_timestamp(),
       extract(epoch from now() - pg_last_xact_replay_timestamp()) AS replay_lag_seconds;
```

### 5.2. レプリケーションの検証

テストデータを使用してレプリケーションが正常に機能していることを検証します:

```sql
-- プライマリで実行
CREATE DATABASE replication_test;
\c replication_test
CREATE TABLE test (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
INSERT INTO test (data) VALUES ('test data 1');
INSERT INTO test (data) VALUES ('test data 2');

-- レプリカで確認（少し待機が必要な場合があります）
\c replication_test
SELECT * FROM test;
```

## 6. レプリケーションスロットの管理

レプリケーションスロットはWALの保持に使用されるため、適切な管理が必要です:

```sql
-- スロットの状態確認
SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn 
FROM pg_replication_slots;

-- 不要になったスロットの削除（使用しなくなったレプリカがある場合）
SELECT pg_drop_replication_slot('replica_slot_1');
```

## 7. トラブルシューティング

### 7.1. レプリケーションの遅延issues

遅延が大きい場合、以下を確認します:
- ネットワーク帯域幅と遅延
- プライマリのワークロード（書き込み量）
- レプリカのリソース（CPU/メモリ/ディスクI/O）

### 7.2. エラーの確認

両方のサーバーでログを確認します:

```bash
# ログファイルの確認
tail -f /var/log/postgresql/postgresql-<バージョン>-main.log
# または
tail -f /var/lib/postgresql/data/log/postgresql-*.log
```

### 7.3. 一般的な問題と解決策

1. **接続エラー**: `pg_hba.conf`の設定と認証情報を確認
2. **スロット使用エラー**: スロットが既に使用されている場合は別の名前で作成
3. **WALセグメントの欠落**: `wal_keep_size`または`max_slot_wal_keep_size`設定を増加

## 8. フェイルオーバー手順

プライマリに障害が発生した場合のレプリカ昇格手順:

```bash
# レプリカサーバーでの操作
pg_ctl promote -D /var/lib/postgresql/data

# 昇格後の確認
psql -U postgres -c "SELECT pg_is_in_recovery();"
```

## 9. オンラインでの再同期

長時間切断されたレプリカを再同期する場合、完全な再構築が必要になる可能性があります。WALセグメントが保持されている場合は、以下の手順で再接続できます:

1. レプリカの`postgresql.conf`の`primary_conninfo`を確認
2. レプリカの`postgresql.conf`の`restore_command`が正しく設定されていることを確認
3. レプリカを再起動

```bash
pg_ctl restart -D /var/lib/postgresql/data
```

## 10. 運用上のベストプラクティス

1. **定期的なモニタリング**: レプリケーションの遅延と状態を定期的に監視
2. **アラート設定**: レプリケーション遅延やエラーに対するアラートを設定
3. **バックアップの継続**: レプリケーションはバックアップの代替にならないため、定期的にバックアップを実行
4. **テスト環境での練習**: フェイルオーバー手順を定期的にテスト環境で練習

## まとめ

この手順を使用することで、既存のPostgreSQLサーバーのダウンタイムを最小限に抑えながら非同期レプリケーションを設定できます。非同期レプリケーションはパフォーマンスに優れていますが、レプリカへのデータ反映に遅延が生じる場合があることを念頭に置いてください。高可用性が必要な場合は、フェイルオーバー手順を十分にテストし、必要に応じて自動化することをお勧めします。