#!/bin/bash

# PostgreSQL非同期レプリケーションのパフォーマンス測定スクリプト
# 同期モードと非同期モードの比較テストを行います

# 色の定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

NAMESPACE="postgres-async-replication"

echo -e "${YELLOW}PostgreSQL同期/非同期パフォーマンス比較ツール${NC}"
echo "============================================"

# Kubernetes環境でPodの名前を取得
PRIMARY_POD=$(kubectl get pod -l app=postgres-primary -n ${NAMESPACE} -o jsonpath="{.items[0].metadata.name}")
REPLICA_POD=$(kubectl get pod -l app=postgres-async-replica -n ${NAMESPACE} -o jsonpath="{.items[0].metadata.name}")

echo -e "プライマリPod: ${GREEN}$PRIMARY_POD${NC}"
echo -e "レプリカPod: ${GREEN}$REPLICA_POD${NC}"
echo ""

# 測定用データベースとテーブルの作成
echo -e "${YELLOW}1. テスト用データベースとテーブルの作成${NC}"
echo "----------------------------------------"

kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "DROP DATABASE IF EXISTS perf_test;"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "CREATE DATABASE perf_test;"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d perf_test -c "CREATE TABLE sync_test (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d perf_test -c "CREATE TABLE async_test (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);"

# 非同期モードのパフォーマンス測定
run_performance_test() {
    local mode=$1
    local table=$2
    local rows=$3
    
    echo -e "\n${YELLOW}2. ${mode}モードのパフォーマンス測定 (${rows}行)${NC}"
    echo "----------------------------------------"
    
    # レプリケーションモードの設定
    if [ "$mode" = "同期" ]; then
        kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "ALTER SYSTEM SET synchronous_commit = on;"
    else
        kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "ALTER SYSTEM SET synchronous_commit = off;"
    fi
    
    # 設定を反映するためにPostgreSQLを再読み込み
    kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "SELECT pg_reload_conf();"
    
    # 現在の設定を確認
    CURRENT_SETTING=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SHOW synchronous_commit;")
    echo -e "現在の同期モード設定: ${BLUE}$CURRENT_SETTING${NC}"
    
    # テストデータの挿入時間を測定
    echo "データを挿入しています..."
    START_TIME=$(date +%s.%N)
    
    # 最後のトランザクションに特別なマーカーを付ける
    MARKER="end-marker-$(date +%s)"
    
    # データ挿入のためのSQLスクリプトを作成
    TEMP_SQL_FILE="/tmp/insert_data_${mode}.sql"
    echo "BEGIN;" > $TEMP_SQL_FILE
    for ((i=1; i<=$rows; i++)); do
        if [ $i -eq $rows ]; then
            echo "INSERT INTO ${table} (data) VALUES ('$MARKER');" >> $TEMP_SQL_FILE
        else
            echo "INSERT INTO ${table} (data) VALUES ('test-$i');" >> $TEMP_SQL_FILE
        fi
    done
    echo "COMMIT;" >> $TEMP_SQL_FILE
    
    # SQLファイルをPodにコピーして実行
    kubectl cp $TEMP_SQL_FILE $PRIMARY_POD:/tmp/insert_data.sql -n ${NAMESPACE}
    kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d perf_test -f /tmp/insert_data.sql > /dev/null
    
    PRIMARY_END_TIME=$(date +%s.%N)
    PRIMARY_DURATION=$(echo "$PRIMARY_END_TIME - $START_TIME" | bc)
    echo -e "プライマリでの処理時間: ${GREEN}${PRIMARY_DURATION}秒${NC}"
    
    echo -e "\n${BLUE}レプリカにデータが完全にレプリケートされるのを待機しています...${NC}"
    
    # レプリケーション完了をポーリングで確認 (マーカーを探す)
    REPLICA_START_POLL=$(date +%s.%N)
    TIMEOUT=60  # タイムアウト時間(秒)
    MARKER_FOUND="false"
    POLLING_COUNT=0
    
    while [ "$MARKER_FOUND" = "false" ] && [ $(echo "$(date +%s.%N) - $REPLICA_START_POLL < $TIMEOUT" | bc) -eq 1 ]; do
        MARKER_COUNT=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -d perf_test -t -c "SELECT COUNT(*) FROM ${table} WHERE data = '$MARKER';")
        POLLING_COUNT=$((POLLING_COUNT + 1))
        if [ "$MARKER_COUNT" -gt 0 ]; then
            MARKER_FOUND="true"
        else
            sleep 0.2
        fi
    done
    
    REPLICA_END_TIME=$(date +%s.%N)
    
    if [ "$MARKER_FOUND" = "true" ]; then
        REPLICATION_DELAY=$(echo "$REPLICA_END_TIME - $PRIMARY_END_TIME" | bc)
        TOTAL_TIME=$(echo "$REPLICA_END_TIME - $START_TIME" | bc)
        
        echo -e "データ挿入からレプリケーション完了までの合計時間: ${GREEN}${TOTAL_TIME}秒${NC}"
        echo -e "プライマリでのコミット後のレプリケーション遅延: ${YELLOW}${REPLICATION_DELAY}秒${NC}"
        echo -e "ポーリング回数: ${BLUE}${POLLING_COUNT}${NC}"
        
        # データ件数の最終確認
        PRIMARY_FINAL_COUNT=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -d perf_test -t -c "SELECT COUNT(*) FROM ${table};")
        REPLICA_FINAL_COUNT=$(kubectl exec $REPLICA_POD -n ${NAMESPACE} -- psql -U postgres -d perf_test -t -c "SELECT COUNT(*) FROM ${table};")
        
        echo -e "プライマリのレコード数: ${GREEN}$PRIMARY_FINAL_COUNT${NC}"
        echo -e "レプリカのレコード数: ${GREEN}$REPLICA_FINAL_COUNT${NC}"
        
        if [ "$PRIMARY_FINAL_COUNT" = "$REPLICA_FINAL_COUNT" ]; then
            echo -e "${GREEN}✓ 全てのデータが正常にレプリケートされました${NC}"
        else
            echo -e "${RED}✗ 一部のデータがレプリケートされていません${NC}"
            echo -e "   欠損レコード数: ${RED}$((PRIMARY_FINAL_COUNT - REPLICA_FINAL_COUNT))${NC}"
        fi
        
        # 結果を返す
        echo "$PRIMARY_DURATION $REPLICATION_DELAY $TOTAL_TIME"
    else
        echo -e "${RED}✗ タイムアウト: $TIMEOUT秒以内にレプリケーションが完了しませんでした${NC}"
        echo "N/A N/A N/A"
    fi
}

# テスト実行
ROWS="5000"  # 挿入する行数

# 非同期モードのテスト実行
ASYNC_RESULTS=$(run_performance_test "非同期" "async_test" $ROWS)
ASYNC_PRIMARY=$(echo $ASYNC_RESULTS | cut -d' ' -f1)
ASYNC_REPLICATION=$(echo $ASYNC_RESULTS | cut -d' ' -f2)
ASYNC_TOTAL=$(echo $ASYNC_RESULTS | cut -d' ' -f3)

sleep 5  # テスト間の待機時間

# 同期モードのテスト実行
SYNC_RESULTS=$(run_performance_test "同期" "sync_test" $ROWS)
SYNC_PRIMARY=$(echo $SYNC_RESULTS | cut -d' ' -f1)
SYNC_REPLICATION=$(echo $SYNC_RESULTS | cut -d' ' -f2)
SYNC_TOTAL=$(echo $SYNC_RESULTS | cut -d' ' -f3)

# 元の設定に戻す（非同期モード）
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "ALTER SYSTEM SET synchronous_commit = off;"
kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -c "SELECT pg_reload_conf();"

# 結果の比較
echo -e "\n${YELLOW}3. 同期モードと非同期モードのパフォーマンス比較${NC}"
echo "----------------------------------------"

if [ "$ASYNC_PRIMARY" != "N/A" ] && [ "$SYNC_PRIMARY" != "N/A" ]; then
    PRIMARY_DIFF=$(echo "$SYNC_PRIMARY - $ASYNC_PRIMARY" | bc)
    PRIMARY_PERC=$(echo "($PRIMARY_DIFF / $ASYNC_PRIMARY) * 100" | bc)
    
    TOTAL_DIFF=$(echo "$SYNC_TOTAL - $ASYNC_TOTAL" | bc)
    TOTAL_PERC=$(echo "($TOTAL_DIFF / $ASYNC_TOTAL) * 100" | bc)
    
    echo -e "プライマリでのデータ挿入時間:"
    echo -e "  非同期: ${GREEN}${ASYNC_PRIMARY}秒${NC}"
    echo -e "  同期: ${YELLOW}${SYNC_PRIMARY}秒${NC}"
    echo -e "  差分: ${BLUE}+${PRIMARY_DIFF}秒 (約${PRIMARY_PERC}%増)${NC}"
    
    echo -e "\nレプリケーション遅延時間:"
    echo -e "  非同期: ${GREEN}${ASYNC_REPLICATION}秒${NC}"
    echo -e "  同期: ${YELLOW}${SYNC_REPLICATION}秒${NC}"
    
    echo -e "\n合計処理時間:"
    echo -e "  非同期: ${GREEN}${ASYNC_TOTAL}秒${NC}"
    echo -e "  同期: ${YELLOW}${SYNC_TOTAL}秒${NC}"
    echo -e "  差分: ${BLUE}+${TOTAL_DIFF}秒 (約${TOTAL_PERC}%増)${NC}"
    
    echo -e "\n${GREEN}結論:${NC}"
    if (( $(echo "$SYNC_TOTAL > $ASYNC_TOTAL" | bc -l) )); then
        echo -e "${BLUE}非同期レプリケーションは同期レプリケーションよりも約${TOTAL_PERC}%高速ですが、"
        echo -e "データ一貫性の保証は弱くなります。アプリケーションの要件に合わせて選択してください。${NC}"
    else
        echo -e "${BLUE}このテストケースでは同期レプリケーションが非同期レプリケーションよりも高速でした。"
        echo -e "ネットワーク遅延や負荷状況によって結果が異なる場合があります。${NC}"
    fi
else
    echo -e "${RED}テストの一部がタイムアウトしたため、完全な比較ができません${NC}"
fi

# レプリケーション統計情報の表示
echo -e "\n${YELLOW}4. 詳細なレプリケーション統計情報${NC}"
echo "----------------------------------------"
REPLICATION_STATS=$(kubectl exec $PRIMARY_POD -n ${NAMESPACE} -- psql -U postgres -t -c "SELECT application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;")
echo -e "${BLUE}$REPLICATION_STATS${NC}"

echo -e "\n${GREEN}パフォーマンス比較テストが完了しました${NC}"