#!/bin/bash

# このスクリプトはPostgreSQLレプリケーションを検証するためのものです
# プライマリとレプリカで同じクエリを実行し、結果を比較します

# 色の定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}PostgreSQLレプリケーション検証ツール${NC}"
echo "---------------------------------------"

# Kubernetes環境でPodの名前を取得
PRIMARY_POD=$(kubectl get pod -l app=postgres-primary -o jsonpath="{.items[0].metadata.name}")
REPLICA_POD=$(kubectl get pod -l app=postgres-replica -o jsonpath="{.items[0].metadata.name}")

echo -e "プライマリPod: ${GREEN}$PRIMARY_POD${NC}"
echo -e "レプリカPod: ${GREEN}$REPLICA_POD${NC}"
echo ""

# プライマリでデータベースを初期化
echo "1. プライマリにテストデータを作成しています..."
kubectl cp init-test-data.sql $PRIMARY_POD:/tmp/init-test-data.sql
kubectl exec $PRIMARY_POD -- bash -c "psql -U postgres < /tmp/init-test-data.sql"

# 少し待機してレプリケーションが完了するのを待つ
echo "レプリケーションを待機しています (5秒)..."
sleep 5

# 検証クエリ
QUERIES=(
    "SELECT COUNT(*) FROM replication_test.users;"
    "SELECT COUNT(*) FROM replication_test.products;"
    "SELECT COUNT(*) FROM replication_test.orders;"
    "SELECT COUNT(*) FROM replication_test.order_items;"
    "SELECT SUM(total_amount) FROM replication_test.orders;"
)

# 各クエリを両方のデータベースで実行して結果を比較
for QUERY in "${QUERIES[@]}"; do
    echo -e "\n${YELLOW}クエリ: $QUERY${NC}"
    
    PRIMARY_RESULT=$(kubectl exec $PRIMARY_POD -- psql -U postgres -t -c "$QUERY")
    REPLICA_RESULT=$(kubectl exec $REPLICA_POD -- psql -U postgres -t -c "$QUERY")
    
    echo -e "プライマリ結果: ${GREEN}$PRIMARY_RESULT${NC}"
    echo -e "レプリカ結果: ${GREEN}$REPLICA_RESULT${NC}"
    
    if [ "$PRIMARY_RESULT" = "$REPLICA_RESULT" ]; then
        echo -e "${GREEN}✓ 一致${NC}"
    else
        echo -e "${RED}✗ 不一致${NC}"
    fi
done

# 新しいデータをプライマリに追加して、レプリケーションを再検証
echo -e "\n\n${YELLOW}レプリケーション動作確認: プライマリに新しいデータを追加${NC}"
echo "---------------------------------------"

NEW_DATA_QUERY="INSERT INTO replication_test.users (username, email) VALUES ('new_user', 'new_user@example.com');"
echo -e "実行クエリ: ${GREEN}$NEW_DATA_QUERY${NC}"

kubectl exec $PRIMARY_POD -- psql -U postgres -c "$NEW_DATA_QUERY"
echo "新しいユーザーをプライマリに追加しました"

# 少し待機してレプリケーションが完了するのを待つ
echo "レプリケーションを待機しています (5秒)..."
sleep 5

# 両方のデータベースでクエリを実行
CHECK_QUERY="SELECT * FROM replication_test.users WHERE username = 'new_user';"
echo -e "\n${YELLOW}確認クエリ: $CHECK_QUERY${NC}"

PRIMARY_RESULT=$(kubectl exec $PRIMARY_POD -- psql -U postgres -t -c "$CHECK_QUERY")
REPLICA_RESULT=$(kubectl exec $REPLICA_POD -- psql -U postgres -t -c "$CHECK_QUERY")

echo -e "プライマリ結果: ${GREEN}$PRIMARY_RESULT${NC}"
echo -e "レプリカ結果: ${GREEN}$REPLICA_RESULT${NC}"

if [ "$PRIMARY_RESULT" = "$REPLICA_RESULT" ]; then
    echo -e "\n${GREEN}✓ レプリケーションが正常に動作しています${NC}"
else
    echo -e "\n${RED}✗ レプリケーションに問題があります${NC}"
fi