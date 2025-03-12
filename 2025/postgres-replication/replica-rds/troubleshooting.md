# PostgreSQL論理レプリケーションのトラブルシューティング

このドキュメントでは、PostgreSQLの論理レプリケーション（特にRDSをレプリカとして使用する場合）でよく発生する問題とその解決方法について説明します。

## 一般的な問題と解決策

### 1. レプリケーションが開始されない

#### 症状
- サブスクリプション作成後もデータがレプリカに複製されない
- `pg_stat_subscription`のステータスが`initializing`のままになっている

#### 確認ポイント
1. **ネットワーク接続**
   ```bash
   # ソースDBサーバーからRDSへの接続確認
   telnet <RDS-ENDPOINT> 5432
   
   # または
   nc -zv <RDS-ENDPOINT> 5432
   ```

2. **ファイアウォール設定**
   - ソースDBのセキュリティグループまたはファイアウォールで5432ポートが開放されているか
   - RDSセキュリティグループでソースDBからの接続が許可されているか

3. **pg_hba.conf設定**
   ```bash
   # ログで拒否されたアクセスを確認
   grep "connection rejected" /var/log/postgresql/postgresql-*.log
   ```

4. **レプリケーションユーザー権限**
   ```sql
   -- ソースDBで確認
   SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';
   ```

#### 解決策
1. **接続文字列の確認と修正**
   ```sql
   -- RDSで実行
   ALTER SUBSCRIPTION my_subscription CONNECTION 'host=<正確なホスト> port=5432 dbname=<DB名> user=replicator password=<パスワード>';
   ALTER SUBSCRIPTION my_subscription REFRESH PUBLICATION;
   ```

2. **サブスクリプションのリセット**
   ```sql
   -- RDSで実行
   ALTER SUBSCRIPTION my_subscription DISABLE;
   ALTER SUBSCRIPTION my_subscription ENABLE;
   ```

3. **手動でのスロット作成確認**
   ```sql
   -- ソースDBで実行
   SELECT * FROM pg_replication_slots;
   
   -- スロットがない場合は手動作成も検討
   SELECT pg_create_logical_replication_slot('my_subscription', 'pgoutput');
   ```

### 2. レプリケーションが途中で停止する

#### 症状
- 初期同期後にデータの複製が停止
- `pg_stat_subscription`の`last_msg_receipt_time`が更新されない

#### 確認ポイント
1. **WALの生成状況**
   ```sql
   -- ソースDBで実行
   SELECT pg_current_wal_lsn();
   ```

2. **レプリケーションスロットの状態**
   ```sql
   -- ソースDBで実行
   SELECT slot_name, active, restart_lsn FROM pg_replication_slots;
   ```

3. **エラーログの確認**
   ```bash
   # ソースDBのログ確認
   grep -i "replication" /var/log/postgresql/postgresql-*.log
   grep -i "error" /var/log/postgresql/postgresql-*.log
   
   # RDSのログはRDSコンソールから確認
   ```

#### 解決策
1. **サブスクリプションの再起動**
   ```sql
   -- RDSで実行
   ALTER SUBSCRIPTION my_subscription DISABLE;
   ALTER SUBSCRIPTION my_subscription ENABLE;
   ```

2. **問題のあるトランザクションをスキップ**
   深刻な問題が特定のトランザクションにある場合:
   ```sql
   -- ソースDBでスロットの位置を進める（慎重に！）
   SELECT pg_replication_slot_advance('my_subscription', pg_current_wal_lsn());
   ```

3. **接続の安定性改善**
   ```sql
   -- RDSで実行
   ALTER SUBSCRIPTION my_subscription SET (connect_timeout = '30s');
   ```

### 3. データの不一致

#### 症状
- レプリカのデータがソースと一致しない
- 特定のテーブルのみ複製されていない

#### 確認ポイント
1. **パブリケーション設定**
   ```sql
   -- ソースDBで実行
   SELECT pubname, pubtables FROM pg_publication;
   ```

2. **テーブル構造の一致**
   ```sql
   -- 両方のDBで実行して比較
   \d <テーブル名>
   ```

3. **プライマリキーの存在確認**
   ```sql
   -- 両方のDBで実行
   SELECT c.relname, c.relreplident
   FROM pg_class c, pg_namespace n
   WHERE c.relnamespace = n.oid AND n.nspname = 'public' AND c.relkind = 'r';
   ```

#### 解決策
1. **テーブル構造の修正**
   不一致があるテーブルの構造を修正:
   ```sql
   -- RDSで実行（必要に応じて）
   ALTER TABLE <テーブル名> ADD COLUMN <カラム名> <タイプ>;
   -- または
   ALTER TABLE <テーブル名> ALTER COLUMN <カラム名> TYPE <タイプ>;
   ```

2. **パブリケーションの更新**
   ```sql
   -- ソースDBで実行
   ALTER PUBLICATION my_publication ADD TABLE <テーブル名>;
   ```

3. **サブスクリプションのリフレッシュ**
   ```sql
   -- RDSで実行
   ALTER SUBSCRIPTION my_subscription REFRESH PUBLICATION;
   ```

4. **完全再同期（最終手段）**
   ```sql
   -- RDSで実行
   DROP SUBSCRIPTION my_subscription;
   CREATE SUBSCRIPTION my_subscription
   CONNECTION 'host=<ソースDBのIP> port=5432 dbname=<DB名> user=replicator password=<パスワード>'
   PUBLICATION my_publication;
   ```

### 4. パフォーマンス問題

#### 症状
- レプリケーション遅延が大きい
- ソースDBのCPU/ディスクI/Oが高い

#### 確認ポイント
1. **レプリケーション遅延の測定**
   ```sql
   -- RDSで実行
   SELECT now() - pg_last_committed_xact()::timestamptz AS replication_lag;
   ```

2. **ワーカープロセスの確認**
   ```sql
   -- ソースDBで実行
   SELECT * FROM pg_stat_replication;
   
   -- RDSで実行
   SELECT * FROM pg_stat_subscription;
   ```

3. **リソース使用状況の確認**
   ```bash
   # ソースDBサーバー
   top
   iostat -x 1
   ```

#### 解決策
1. **ワーカー数の調整**
   ```sql
   -- ソースDBのpostgresql.confを編集
   max_logical_replication_workers = 8  # 増やす
   max_worker_processes = 20            # 関連して増やす
   
   -- RDSパラメータグループで同様のパラメータを調整
   ```

2. **パブリケーションの分割**
   大量データを扱う場合、複数のパブリケーション/サブスクリプションに分割:
   ```sql
   -- ソースDBで実行
   CREATE PUBLICATION pub_table1 FOR TABLE table1;
   CREATE PUBLICATION pub_table2 FOR TABLE table2;
   
   -- RDSで実行
   CREATE SUBSCRIPTION sub_table1
   CONNECTION 'host=<ソースDB> port=5432 dbname=<DB名> user=replicator password=<パスワード>'
   PUBLICATION pub_table1;
   
   CREATE SUBSCRIPTION sub_table2
   CONNECTION 'host=<ソースDB> port=5432 dbname=<DB名> user=replicator password=<パスワード>'
   PUBLICATION pub_table2;
   ```

3. **インデックス最適化**
   レプリカ側でクエリパフォーマンスを向上させるためのインデックス追加:
   ```sql
   -- RDSで実行（読み取りパフォーマンス向上のため）
   CREATE INDEX idx_<column> ON <table> (<column>);
   ```

### 5. RDS固有の問題

#### 症状
- `rds.logical_replication`が有効にもかかわらずレプリケーションが機能しない
- RDSの再起動後にレプリケーションが停止する

#### 確認ポイント
1. **パラメータグループの適用確認**
   - RDSコンソールでインスタンスの詳細を確認
   - パラメータグループのステータスが「同期中」または「保留中の再起動」になっていないか

2. **RDSバージョンの互換性**
   - ソースPostgreSQLとRDSのメジャーバージョンが一致しているか

3. **RDSストレージ容量**
   - ストレージの使用率が高くないか

#### 解決策
1. **RDSインスタンスの再起動**
   - パラメータグループ変更を適用するために必要な場合

2. **RDSストレージの拡張**
   ```
   # RDSコンソールでストレージサイズを増やす
   ```

3. **RDSログの詳細確認**
   - RDSコンソールでログを有効化し、詳細レベルを上げる
   - CloudWatch Logsでログを分析

## 予防策と定期メンテナンス

### 日常的なモニタリング

1. **レプリケーション状態の確認**
   ```sql
   -- RDSで実行
   SELECT * FROM pg_stat_subscription;
   ```

2. **レプリケーション遅延の監視**
   ```sql
   -- RDSで実行
   SELECT now() - pg_last_committed_xact()::timestamptz AS replication_lag;
   ```

3. **スロットサイズの監視**
   ```sql
   -- ソースDBで実行
   SELECT slot_name,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal_size
   FROM pg_replication_slots;
   ```

### 定期メンテナンス作業

1. **未使用スロットのクリーンアップ**
   ```sql
   -- ソースDBで実行（不要なスロットを削除）
   SELECT pg_drop_replication_slot('<不要なスロット名>');
   ```

2. **定期的な統計情報更新**
   ```sql
   -- 両方のDBで実行
   VACUUM ANALYZE;
   ```

3. **テーブル構造変更時の注意**
   - スキーマ変更前にサブスクリプションを一時停止
   - 両方のDBで同一の変更を適用
   - サブスクリプションを再開

## まとめ

論理レプリケーションは強力なツールですが、適切な設定とモニタリングが重要です。問題が発生した場合は:

1. ログを詳細に確認する
2. 接続とネットワーク構成を検証する
3. レプリケーション設定を確認する
4. 必要に応じてサブスクリプションをリセットする

深刻な問題が発生した場合は、サブスクリプションを再作成する方法も検討してください。