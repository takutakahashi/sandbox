#!/bin/bash

# PostgreSQL非同期レプリケーション検証スクリプト
# 非同期レプリケーションのテストと遅延測定を行います

# 色の定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NAMESPACE="postgres-async-replication"

echo -e "${YELLOW}PostgreSQL非同期レプリケーション検証ツール${NC}"
echo "============================================"

# Kubernetes環境でPodの名前を取得
PRIMARY_POD=$(kubectl get pod -l app=postgres-primary -n ${NAMESPACE} -o jsonpath="{.items[0].metadata.name}")
REPLICA_POD=$(kubectl get pod -l app=postgres-async-replica -n ${NAMESPACE} -o jsonpath="{.items[0].metadata.name}")

echo -e "プライマリPod: ${GREEN}$PRIMARY_POD${NC}"
echo -e "レプリカPod: ${GREEN}$REPLICA_POD${NC}"
echo ""

# テスト用データベースとテーブルの作成
echo -e "${YELLOW}1. テスト用データベースとテーブルの作成${NC}"
echo "----------------------------------------"

kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "DROP DATABASE IF EXISTS async_test;"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "CREATE DATABASE async_test;"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -c "CREATE TABLE test_transactions (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);"

# 非同期レプリケーション状態の確認
echo -e "\n${YELLOW}2. レプリケーション状態の確認${NC}"
echo "----------------------------------------"
REPLICATION_STATUS=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;")
echo -e "${BLUE}$REPLICATION_STATUS${NC}"

# プライマリが非同期モードになっていることを確認
SYNC_MODE=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SHOW synchronous_commit;")
echo -e "同期モード設定: ${BLUE}$SYNC_MODE${NC}"
if [[ $SYNC_MODE == *"off"* ]]; then
    echo -e "${GREEN}✓ 非同期レプリケーションモードが正しく設定されています${NC}"
else 
    echo -e "${RED}✗ 同期モードが off になっていません。非同期レプリケーションの設定を確認してください${NC}"
fi

# シンプルな単一トランザクションのレプリケーション確認
echo -e "\n${YELLOW}3. 単一トランザクションのレプリケーション確認${NC}"
echo "----------------------------------------"
echo "プライマリに1件のデータを挿入しています..."
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -c "INSERT INTO test_transactions (data) VALUES ('single-test');"

echo "レプリケーションを待機しています (3秒)..."
sleep 3

PRIMARY_COUNT=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -t -c "SELECT COUNT(*) FROM test_transactions WHERE data = 'single-test';")
REPLICA_COUNT=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -t -c "SELECT COUNT(*) FROM test_transactions WHERE data = 'single-test';")

echo -e "プライマリ結果: ${GREEN}$PRIMARY_COUNT${NC}"
echo -e "レプリカ結果: ${GREEN}$REPLICA_COUNT${NC}"

if [ "$PRIMARY_COUNT" = "$REPLICA_COUNT" ]; then
    echo -e "${GREEN}✓ 単一トランザクションが正常にレプリケートされました${NC}"
else
    echo -e "${RED}✗ レプリケーションに問題があります${NC}"
fi

# 大量トランザクションでの遅延測定
echo -e "\n${YELLOW}4. 大量トランザクションにおけるレプリケーション遅延の測定${NC}"
echo "----------------------------------------"
echo "プライマリに多数のトランザクションを生成しています..."

START_TIME=$(date +%s)
# トランザクション数
TRANSACTION_COUNT=500

# 最後のトランザクションに特別なマーカーを付ける
MARKER="end-marker-$(date +%s)"

# 複数のトランザクションをバッチ処理で一気に実行
for ((i=1; i<=$TRANSACTION_COUNT; i++)); do
    if [ $i -eq $TRANSACTION_COUNT ]; then
        # 最後のトランザクションに特別なマーカーを付ける
        kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -c "INSERT INTO test_transactions (data) VALUES ('$MARKER');"
    else
        kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -c "INSERT INTO test_transactions (data) VALUES ('batch-test-$i');"
    fi
done

echo "プライマリでの挿入完了時間: $(date)"
PRIMARY_END_TIME=$(date +%s)
PRIMARY_DURATION=$((PRIMARY_END_TIME - START_TIME))
echo -e "プライマリでの処理時間: ${GREEN}${PRIMARY_DURATION}秒${NC}"

echo -e "\n${BLUE}レプリカにデータが完全にレプリケートされるのを待機しています...${NC}"

# レプリケーション完了をポーリングで確認 (マーカーを探す)
REPLICA_START_POLL=$(date +%s)
TIMEOUT=60  # タイムアウト時間(秒)
MARKER_FOUND="false"

while [ "$MARKER_FOUND" = "false" ] && [ $(($(date +%s) - REPLICA_START_POLL)) -lt $TIMEOUT ]; do
    MARKER_COUNT=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -t -c "SELECT COUNT(*) FROM test_transactions WHERE data = '$MARKER';")
    if [ "$MARKER_COUNT" -gt 0 ]; then
        MARKER_FOUND="true"
    else
        sleep 1
    fi
done

REPLICA_END_TIME=$(date +%s)

if [ "$MARKER_FOUND" = "true" ]; then
    REPLICATION_DELAY=$((REPLICA_END_TIME - PRIMARY_END_TIME))
    TOTAL_TIME=$((REPLICA_END_TIME - START_TIME))
    
    echo "レプリカでのレプリケーション完了時間: $(date)"
    echo -e "非同期レプリケーション遅延: ${YELLOW}${REPLICATION_DELAY}秒${NC}"
    echo -e "トータル処理時間: ${GREEN}${TOTAL_TIME}秒${NC}"
    
    # データ件数の最終確認
    PRIMARY_FINAL_COUNT=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -t -c "SELECT COUNT(*) FROM test_transactions;")
    REPLICA_FINAL_COUNT=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -t -c "SELECT COUNT(*) FROM test_transactions;")
    
    echo -e "\n${YELLOW}5. 最終結果確認${NC}"
    echo "----------------------------------------"
    echo -e "プライマリのレコード数: ${GREEN}$PRIMARY_FINAL_COUNT${NC}"
    echo -e "レプリカのレコード数: ${GREEN}$REPLICA_FINAL_COUNT${NC}"
    
    if [ "$PRIMARY_FINAL_COUNT" = "$REPLICA_FINAL_COUNT" ]; then
        echo -e "${GREEN}✓ 全てのデータが正常にレプリケートされました${NC}"
    else
        echo -e "${RED}✗ 一部のデータがレプリケートされていません${NC}"
        echo -e "   欠損レコード数: ${RED}$((PRIMARY_FINAL_COUNT - REPLICA_FINAL_COUNT))${NC}"
    fi
else
    echo -e "${RED}✗ タイムアウト: $TIMEOUT秒以内にレプリケーションが完了しませんでした${NC}"
    
    PRIMARY_FINAL_COUNT=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -t -c "SELECT COUNT(*) FROM test_transactions;")
    REPLICA_FINAL_COUNT=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -d async_test -t -c "SELECT COUNT(*) FROM test_transactions;")
    
    echo -e "プライマリのレコード数: ${GREEN}$PRIMARY_FINAL_COUNT${NC}"
    echo -e "レプリカのレコード数: ${GREEN}$REPLICA_FINAL_COUNT${NC}"
    echo -e "レプリケーション遅延レコード数: ${RED}$((PRIMARY_FINAL_COUNT - REPLICA_FINAL_COUNT))${NC}"
fi

# レプリケーション統計情報の表示
echo -e "\n${YELLOW}6. 詳細なレプリケーション統計情報${NC}"
echo "----------------------------------------"
REPLICATION_STATS=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SELECT application_name, client_addr, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes FROM pg_stat_replication;")
echo -e "${BLUE}$REPLICATION_STATS${NC}"

# WALの位置情報
PRIMARY_WAL=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SELECT pg_current_wal_lsn(), pg_walfile_name(pg_current_wal_lsn());")
REPLICA_WAL=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();")

echo -e "プライマリWAL位置: ${BLUE}$PRIMARY_WAL${NC}"
echo -e "レプリカWAL位置: ${BLUE}$REPLICA_WAL${NC}"

echo -e "\n${GREEN}非同期レプリケーション検証が完了しました${NC}"