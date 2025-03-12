#!/bin/bash

# PostgreSQL非同期レプリケーションのフェイルオーバーテスト
# プライマリの障害時にレプリカを新しいプライマリに昇格させる手順

# 色の定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NAMESPACE="postgres-async-replication"

echo -e "${YELLOW}PostgreSQL非同期レプリケーション フェイルオーバーテスト${NC}"
echo "============================================"

# Kubernetes環境でPodの名前を取得
PRIMARY_POD=$(kubectl get pod -l app=postgres-primary -n ${NAMESPACE} -o jsonpath="{.items[0].metadata.name}")
REPLICA_POD=$(kubectl get pod -l app=postgres-async-replica -n ${NAMESPACE} -o jsonpath="{.items[0].metadata.name}")

echo -e "現在のプライマリPod: ${GREEN}$PRIMARY_POD${NC}"
echo -e "現在のレプリカPod: ${GREEN}$REPLICA_POD${NC}"
echo ""

# 確認フェーズ - レプリケーションが正常に動作しているか
echo -e "${YELLOW}1. 現在のレプリケーション状態の確認${NC}"
echo "----------------------------------------"
REPLICATION_STATUS=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;")
echo -e "${BLUE}$REPLICATION_STATUS${NC}"

if [[ -z "$REPLICATION_STATUS" ]]; then
    echo -e "${RED}✗ レプリケーションが動作していません。手順を中止します。${NC}"
    exit 1
fi

echo -e "${GREEN}✓ レプリケーションは正常に動作しています${NC}"

# テスト用データベースの作成
echo -e "\n${YELLOW}2. フェイルオーバーテスト用データの準備${NC}"
echo "----------------------------------------"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "DROP DATABASE IF EXISTS failover_test;"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "CREATE DATABASE failover_test;"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d failover_test -c "CREATE TABLE important_data (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);"

# 初期データの挿入
echo "初期データを挿入しています..."
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d failover_test -c "INSERT INTO important_data (data) VALUES ('init-data-1'), ('init-data-2'), ('init-data-3');"

# レプリケーションの確認
echo "レプリケーションを待機しています (3秒)..."
sleep 3

PRIMARY_COUNT=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d failover_test -t -c "SELECT COUNT(*) FROM important_data;")
REPLICA_COUNT=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -d failover_test -t -c "SELECT COUNT(*) FROM important_data;")

echo -e "プライマリのレコード数: ${GREEN}$PRIMARY_COUNT${NC}"
echo -e "レプリカのレコード数: ${GREEN}$REPLICA_COUNT${NC}"

if [ "$PRIMARY_COUNT" = "$REPLICA_COUNT" ]; then
    echo -e "${GREEN}✓ 初期データが正常にレプリケートされています${NC}"
else
    echo -e "${RED}✗ レプリケーションに問題があります。手順を中止します。${NC}"
    exit 1
fi

# プライマリの障害シミュレーション
echo -e "\n${YELLOW}3. プライマリの障害シミュレーション${NC}"
echo "----------------------------------------"
echo -e "${RED}プライマリPostgreSQLを停止しています...${NC}"

# PostgreSQLプロセスを強制終了してク障害をシミュレート
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- bash -c "pg_ctl -D /var/lib/postgresql/data stop -m immediate"

echo -e "${RED}プライマリがダウンしました${NC}"
sleep 2

# レプリカの状態確認
echo -e "\n${YELLOW}4. レプリカの状態確認${NC}"
echo "----------------------------------------"

# レプリカがリカバリモードかどうか確認
IS_IN_RECOVERY=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SELECT pg_is_in_recovery();")
echo -e "レプリカがリカバリモード: ${BLUE}$IS_IN_RECOVERY${NC}"

if [[ "$IS_IN_RECOVERY" == *"t"* ]]; then
    echo -e "${GREEN}✓ レプリカは現在リカバリ(スタンバイ)モードです${NC}"
else
    echo -e "${RED}✗ レプリカがリカバリモードではありません。手動で確認してください。${NC}"
    exit 1
fi

# レプリカを新しいプライマリに昇格
echo -e "\n${YELLOW}5. レプリカを新しいプライマリに昇格${NC}"
echo "----------------------------------------"

echo -e "${BLUE}レプリカをプライマリに昇格しています...${NC}"
kubectl exec $REPLICA_POD -n ${NAMESPACE} -- bash -c "pg_ctl -D /var/lib/postgresql/data promote"
sleep 3

# 昇格が成功したか確認
IS_IN_RECOVERY_AFTER=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SELECT pg_is_in_recovery();")
echo -e "レプリカがリカバリモード (昇格後): ${BLUE}$IS_IN_RECOVERY_AFTER${NC}"

if [[ "$IS_IN_RECOVERY_AFTER" == *"f"* ]]; then
    echo -e "${GREEN}✓ レプリカが正常に新しいプライマリに昇格しました${NC}"
else
    echo -e "${RED}✗ レプリカの昇格に失敗しました${NC}"
    exit 1
fi

# 新しいプライマリで書き込みテスト
echo -e "\n${YELLOW}6. 新しいプライマリでの書き込みテスト${NC}"
echo "----------------------------------------"

echo "新しいプライマリに追加データを書き込みます..."
kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -d failover_test -c "INSERT INTO important_data (data) VALUES ('new-primary-data-1'), ('new-primary-data-2');"

NEW_PRIMARY_COUNT=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -d failover_test -t -c "SELECT COUNT(*) FROM important_data;")
echo -e "新プライマリのレコード数: ${GREEN}$NEW_PRIMARY_COUNT${NC}"

if [ "$NEW_PRIMARY_COUNT" -gt "$PRIMARY_COUNT" ]; then
    echo -e "${GREEN}✓ 新しいプライマリで正常にデータを書き込めました${NC}"
else
    echo -e "${RED}✗ 新しいプライマリでのデータ書き込みに問題があります${NC}"
fi

# 元のプライマリの復旧シミュレーション (オプション)
echo -e "\n${YELLOW}7. 元のプライマリの復旧 (新しいレプリカとして)${NC}"
echo "----------------------------------------"

echo -e "${BLUE}元のプライマリを再起動しています...${NC}"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- bash -c "pg_ctl -D /var/lib/postgresql/data start"
sleep 2

echo -e "\n${YELLOW}注意:${NC} 元のプライマリを新しいレプリカとして再構成するには、"
echo "データディレクトリをクリアし、新しいプライマリからベースバックアップを取得する必要があります。"
echo "実際の運用環境では、以下のような手順が必要です："

cat << EOF
# 元のプライマリで実行する手順
1. PostgreSQLを停止
2. データディレクトリの内容をクリア
3. 新しいプライマリからベースバックアップを取得
   pg_basebackup -h postgres-async-replica -U postgres -D /var/lib/postgresql/data -P -Xs -R
4. standby.signalファイルを作成
   touch /var/lib/postgresql/data/standby.signal
5. postgresql.confに接続情報を設定
   primary_conninfo = 'host=postgres-async-replica port=5432 user=postgres password=postgres'
6. PostgreSQLを起動
EOF

echo -e "\n${GREEN}フェイルオーバーテスト完了${NC}"
echo -e "${BLUE}新しいプライマリ: $REPLICA_POD${NC}"
echo -e "${BLUE}元のプライマリ (現在はスタンドアロン): $PRIMARY_POD${NC}"
echo "============================================"