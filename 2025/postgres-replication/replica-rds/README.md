# PostgreSQL 非同期論理レプリケーション セットアップ手順

このドキュメントでは、オンプレミスまたはEC2などで稼働するPostgreSQLをソースとし、Amazon RDS for PostgreSQLをレプリカとした論理レプリケーションの設定手順を説明します。

## 前提条件

- ソースサーバー: PostgreSQL 12以上がインストールされているサーバー
- レプリカ: Amazon RDS for PostgreSQL 12以上のインスタンス
- ソースとレプリカ間のネットワーク接続が確立されていること
- PostgreSQLの管理者権限を持つアカウント

## ステップ1: ソースデータベースの設定

### 1.1 PostgreSQL設定ファイルの変更

`postgresql.conf`ファイルを編集して、論理レプリケーションに必要なパラメータを設定します。

```bash
sudo vim /etc/postgresql/[version]/main/postgresql.conf
```

以下の設定を変更または追加します：

```
# レプリケーション設定
wal_level = logical
max_replication_slots = 10  # 必要に応じて調整
max_wal_senders = 10        # 必要に応じて調整
```

### 1.2 `pg_hba.conf`の設定

RDSからの接続を許可するために`pg_hba.conf`を編集します。

```bash
sudo vim /etc/postgresql/[version]/main/pg_hba.conf
```

以下の行を追加します（RDSのIPアドレス/CIDRに合わせて調整）：

```
# レプリケーション用のRDBアクセス許可
host    replication     replicator      <RDS-IP>/32            md5
# データベースへのアクセス許可
host    <DB-NAME>       replicator      <RDS-IP>/32            md5
```

### 1.3 PostgreSQLの再起動

設定を反映させるためにPostgreSQLを再起動します。

```bash
sudo systemctl restart postgresql
```

### 1.4 レプリケーション用ロールの作成

レプリケーション用のユーザーを作成します：

```sql
CREATE ROLE replicator WITH LOGIN PASSWORD 'secure_password' REPLICATION;
GRANT CONNECT ON DATABASE <DB-NAME> TO replicator;
GRANT USAGE ON SCHEMA public TO replicator;
-- レプリケーション対象のテーブルごとに権限を付与
GRANT SELECT ON <TABLE_NAME> TO replicator;
```

### 1.5 パブリケーションの作成

レプリケーションするテーブルのパブリケーションを作成します：

```sql
-- 特定のテーブルをレプリケーションする場合
CREATE PUBLICATION my_publication FOR TABLE <TABLE_NAME1>, <TABLE_NAME2>;

-- すべてのテーブルをレプリケーションする場合
-- CREATE PUBLICATION my_publication FOR ALL TABLES;
```

## ステップ2: RDS for PostgreSQLの設定

### 2.1 RDSパラメータグループの設定

1. AWS Management Consoleにログインし、RDSコンソールに移動します。
2. 左側のナビゲーションペインで「パラメータグループ」を選択します。
3. 「パラメータグループの作成」をクリックします。
4. 以下のパラメータを設定します：
   - ファミリー: postgres12（使用するPostgreSQLのバージョンに合わせて選択）
   - グループ名: logical-replication-pg
   - 説明: Parameter group for logical replication
5. 「作成」をクリックします。
6. 新しいパラメータグループを選択し、「パラメータの編集」をクリックします。
7. 以下のパラメータを検索して変更します：
   - `rds.logical_replication`: 1（有効化）
   - `max_logical_replication_workers`: 10（必要に応じて調整）
   - `max_worker_processes`: 20（必要に応じて調整）

### 2.2 RDSインスタンスへのパラメータグループの適用

1. RDSコンソールで「データベース」を選択します。
2. レプリカとなるRDSインスタンスを選択し、「変更」をクリックします。
3. 「追加設定」セクションで、先ほど作成したパラメータグループ「logical-replication-pg」を選択します。
4. 「続行」をクリックし、「すぐに適用」を選択して「インスタンスの変更」をクリックします。
5. インスタンスが修正され再起動されるのを待ちます。

### 2.3 データベースとスキーマの準備

RDSインスタンスに接続し、レプリケーション先のデータベースとスキーマを準備します：

```sql
-- ソースDBと同じ名前のデータベースを作成（必要な場合）
CREATE DATABASE <DB-NAME>;

-- データベースに接続
\c <DB-NAME>

-- レプリケーション対象のテーブルと同じスキーマを作成
CREATE TABLE <TABLE_NAME> (
  -- ソーステーブルと同じ列定義
);

-- 必要に応じて他のテーブルも同様に作成
```

## ステップ3: サブスクリプションの設定

### 3.1 RDSインスタンスでサブスクリプションを作成

RDSインスタンスに接続し、サブスクリプションを作成します：

```sql
CREATE SUBSCRIPTION my_subscription
CONNECTION 'host=<ソースDBのIPまたはホスト名> port=5432 dbname=<DB-NAME> user=replicator password=secure_password'
PUBLICATION my_publication;
```

### 3.2 レプリケーション状態の確認

サブスクリプションの状態を確認します：

```sql
SELECT * FROM pg_stat_subscription;
```

正常に動作している場合、`status`列が`streaming`になります。

## トラブルシューティング

### レプリケーションが開始されない場合

1. ソースデータベースのログを確認します：
```bash
sudo tail -f /var/log/postgresql/postgresql-[version]-main.log
```

2. RDSインスタンスのログを確認します：
   - RDSコンソールで、対象のインスタンスを選択
   - 「ログとイベント」タブをクリック
   - 「ログを表示」をクリック

3. ネットワーク接続を確認します：
   - ソースDBのセキュリティグループ/ファイアウォールでポート5432が開放されているか
   - RDSセキュリティグループがソースDBからの接続を許可しているか

### データの不一致が発生する場合

1. テーブル構造が完全に一致しているか確認します。
2. プライマリキーが存在しない場合、レプリケーションで問題が発生する可能性があります。
3. サブスクリプションの状態をリセットします：

```sql
-- RDS上で実行
ALTER SUBSCRIPTION my_subscription DISABLE;
ALTER SUBSCRIPTION my_subscription ENABLE;
```

## メンテナンス

### レプリケーションの一時停止

```sql
-- RDS上で実行
ALTER SUBSCRIPTION my_subscription DISABLE;
```

### レプリケーションの再開

```sql
-- RDS上で実行
ALTER SUBSCRIPTION my_subscription ENABLE;
```

### サブスクリプションの削除

```sql
-- RDS上で実行
DROP SUBSCRIPTION my_subscription;
```

### パブリケーションの削除

```sql
-- ソースDB上で実行
DROP PUBLICATION my_publication;
```

## セキュリティ上の注意

1. レプリケーションユーザーのパスワードは強力なものを使用し、定期的に変更してください。
2. 可能であればSSL接続を使用してください。その場合、`CONNECTION`文字列に`sslmode=require`を追加します。
3. ソースデータベースとRDSインスタンス間の通信は、VPNまたはAWS Direct Connectを介して行うことをお勧めします。

## 参考リンク

- [PostgreSQL論理レプリケーション公式ドキュメント](https://www.postgresql.org/docs/current/logical-replication.html)
- [Amazon RDS for PostgreSQLでの論理レプリケーション](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html#PostgreSQL.Concepts.LogicalReplication)