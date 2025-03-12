# PostgreSQL レプリケーション検証環境

Kubernetes上でPostgreSQLのレプリケーション構成を検証するための環境です。

## 概要

このプロジェクトでは、Kubernetes上に2台のPostgreSQLサーバ（プライマリとレプリカ）を構築し、
手動でレプリケーションを設定して検証を行います。

## ファイル構成

- `postgres-primary.yaml`: プライマリPostgreSQLのDeployment、Service、PVCを定義
- `postgres-replica.yaml`: レプリカPostgreSQLのDeployment、Service、PVCを定義
- `replication-setup-guide.md`: レプリケーション設定の手順書
- `init-test-data.sql`: テスト用のデータベース、テーブル、初期データを作成するSQLスクリプト
- `verify-replication.sh`: レプリケーションの動作を自動で検証するスクリプト
- `check-replication.sql`: 簡易的なレプリケーション確認用SQLスクリプト

## 使い方

1. Kubernetesクラスターに接続された状態で、以下のコマンドを実行：

```bash
kubectl apply -f postgres-primary.yaml
kubectl apply -f postgres-replica.yaml
```

2. `replication-setup-guide.md` に従ってレプリケーションを手動で設定

3. レプリケーションが設定できたら、以下のコマンドでテストデータを作成し検証：

```bash
# テスト用データの作成とレプリケーション検証を自動で実行
./verify-replication.sh

# または手動で以下のように実行
# プライマリにテストデータを作成
kubectl exec $(kubectl get pod -l app=postgres-primary -o jsonpath="{.items[0].metadata.name}") -- psql -U postgres < init-test-data.sql

# レプリカでデータを確認
kubectl exec $(kubectl get pod -l app=postgres-replica -o jsonpath="{.items[0].metadata.name}") -- psql -U postgres -c "SELECT COUNT(*) FROM replication_test.users;"
```

## PostgreSQLバージョン

デフォルトでは PostgreSQL 15 を使用しています。