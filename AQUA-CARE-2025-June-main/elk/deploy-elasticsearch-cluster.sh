#!/bin/bash

# ============================================
# TWCC 多節點 Elasticsearch 叢集部署腳本
# 基於您的 hosts.ini 配置的 2 Master + 1 Data 架構
# ============================================

set -e

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 主函數
main() {
    log_info "🚀 開始部署 TWCC 多節點 Elasticsearch 叢集..."
    
    # 檢查先決條件
    check_prerequisites
    
    # 標記節點
    label_nodes
    
    # 部署 Master 節點
    deploy_master_nodes
    
    # 等待 Master 節點就緒
    wait_for_master_nodes
    
    # 部署 Data 節點
    deploy_data_nodes
    
    # 驗證叢集
    verify_cluster
    
    log_success "🎉 多節點 Elasticsearch 叢集部署完成！"
    show_cluster_info
}

# 檢查先決條件
check_prerequisites() {
    log_info "🔍 檢查部署先決條件..."
    
    # 檢查 kubectl
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "❌ kubectl 未安裝"
        exit 1
    fi
    
    # 檢查 helm
    if ! command -v helm >/dev/null 2>&1; then
        log_error "❌ Helm 未安裝"
        exit 1
    fi
    
    # 檢查 K8s 連接
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "❌ 無法連接到 Kubernetes 叢集"
        exit 1
    fi
    
    # 檢查配置文件
    if [ ! -f "elasticsearch/values-master-nodes.yml" ]; then
        log_error "❌ 未找到 Master 節點配置文件"
        exit 1
    fi
    
    if [ ! -f "elasticsearch/values-data-nodes.yml" ]; then
        log_error "❌ 未找到 Data 節點配置文件"
        exit 1
    fi
    
    log_success "✅ 先決條件檢查通過"
}

# 從 Ansible inventory 讀取群組 IP
get_group_ips() {
    local group_name=$1
    local inventory_file="${2:-ansible/inventories/hosts.ini}"
    
    if [ ! -f "$inventory_file" ]; then
        log_error "❌ 未找到 inventory 文件: $inventory_file"
        return 1
    fi
    
    # 使用 awk 提取指定群組的 IP
    awk -v group="[$group_name]" '
    $0 == group { in_group = 1; next }
    /^\[/ && in_group { in_group = 0 }
    in_group && /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
        split($1, parts, " ")
        print parts[1]
    }
    ' "$inventory_file"
}

# 標記節點
label_nodes() {
    log_info "🏷️  為節點添加標籤..."
    
    # 從 inventory 文件讀取群組 IP
    local inventory_file="ansible/inventories/hosts.ini"
    
    if [ ! -f "$inventory_file" ]; then
        log_warning "⚠️  未找到 inventory 文件，使用預設 IP 配置"
        inventory_file=""
    fi
    
    # 獲取 elk_master 群組的 IP
    log_info "讀取 elk_master 群組 IP..."
    elk_master_ips=($(get_group_ips "elk_master" "$inventory_file"))
    
    # 獲取 elk_worker 群組的 IP  
    log_info "讀取 elk_worker 群組 IP..."
    elk_worker_ips=($(get_group_ips "elk_worker" "$inventory_file"))
    
    log_info "Master 節點 IP: ${elk_master_ips[*]}"
    log_info "Worker 節點 IP: ${elk_worker_ips[*]}"
    
    # 獲取 K8s 節點列表
    nodes=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
    
    for node_ip in $nodes; do
        # 獲取節點名稱
        node_name=$(kubectl get nodes -o jsonpath="{.items[?(@.status.addresses[0].address==\"$node_ip\")].metadata.name}")
        
        if [ -z "$node_name" ]; then
            continue
        fi
        
        # 檢查是否為 Master 節點
        if [[ " ${elk_master_ips[*]} " =~ " $node_ip " ]]; then
            log_info "標記 Master 節點: $node_name ($node_ip)"
            kubectl label nodes "$node_name" elk-role=master --overwrite
        # 檢查是否為 Worker 節點
        elif [[ " ${elk_worker_ips[*]} " =~ " $node_ip " ]]; then
            log_info "標記 Worker 節點: $node_name ($node_ip)"
            kubectl label nodes "$node_name" elk-role=worker --overwrite
        else
            log_warning "未分配角色的節點: $node_name ($node_ip)"
        fi
    done
    
    log_success "✅ 節點標籤設置完成"
}

# 部署 Master 節點
deploy_master_nodes() {
    log_info "🎯 部署 Elasticsearch Master 節點..."
    
    # 添加 Elastic Helm 倉庫
    helm repo add elastic https://helm.elastic.co >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    
    # 部署 Master 節點
    helm upgrade --install elasticsearch-master elastic/elasticsearch \
        -f elasticsearch/values-master-nodes.yml \
        --namespace default \
        --wait --timeout=10m
    
    log_success "✅ Master 節點部署完成"
}

# 等待 Master 節點就緒
wait_for_master_nodes() {
    log_info "⏳ 等待 Master 節點就緒..."
    
    local retries=0
    local max_retries=30
    
    while [ $retries -lt $max_retries ]; do
        ready_pods=$(kubectl get pods -l app=elasticsearch-master,chart=elasticsearch -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | wc -w)
        total_pods=$(kubectl get pods -l app=elasticsearch-master,chart=elasticsearch -o jsonpath='{.items[*].metadata.name}' | wc -w)
        
        if [ "$ready_pods" -eq "$total_pods" ] && [ "$total_pods" -gt 0 ]; then
            log_success "✅ 所有 Master 節點已就緒 ($ready_pods/$total_pods)"
            break
        fi
        
        log_info "等待 Master 節點就緒... ($ready_pods/$total_pods)"
        sleep 30
        ((retries++))
    done
    
    if [ $retries -eq $max_retries ]; then
        log_error "❌ Master 節點啟動超時"
        exit 1
    fi
}

# 部署 Data 節點
deploy_data_nodes() {
    log_info "💾 部署 Elasticsearch Data 節點..."
    
    # 部署 Data 節點
    helm upgrade --install elasticsearch-data elastic/elasticsearch \
        -f elasticsearch/values-data-nodes.yml \
        --namespace default \
        --wait --timeout=10m
    
    log_success "✅ Data 節點部署完成"
}

# 驗證叢集
verify_cluster() {
    log_info "🔍 驗證 Elasticsearch 叢集..."
    
    # 等待所有節點加入叢集
    local retries=0
    local max_retries=20
    
    while [ $retries -lt $max_retries ]; do
        # 獲取叢集狀態
        cluster_status=$(kubectl exec -it elasticsearch-master-0 -- \
            curl -s -k -u "elastic:$(kubectl get secret elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d)" \
            "https://localhost:9200/_cluster/health" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "unknown")
        
        if [ "$cluster_status" = "green" ] || [ "$cluster_status" = "yellow" ]; then
            log_success "✅ 叢集狀態: $cluster_status"
            break
        fi
        
        log_info "等待叢集就緒... (狀態: $cluster_status)"
        sleep 15
        ((retries++))
    done
    
    # 顯示節點狀態
    log_info "顯示叢集節點狀態..."
    kubectl exec -it elasticsearch-master-0 -- \
        curl -s -k -u "elastic:$(kubectl get secret elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d)" \
        "https://localhost:9200/_cat/nodes?v" 2>/dev/null || log_warning "無法獲取節點狀態"
}

# 顯示叢集信息
show_cluster_info() {
    # 動態獲取群組 IP 信息
    local inventory_file="ansible/inventories/hosts.ini"
    local elk_master_ips=($(get_group_ips "elk_master" "$inventory_file" 2>/dev/null))
    local elk_worker_ips=($(get_group_ips "elk_worker" "$inventory_file" 2>/dev/null))
    
    echo ""
    log_success "🎉 TWCC Elasticsearch 多節點叢集部署完成！"
    echo ""
    echo "📋 叢集配置："
    echo "  叢集名稱: twcc-cluster"
    echo "  Master 節點: ${#elk_master_ips[@]} 個 (${elk_master_ips[*]})"
    echo "  Data 節點: ${#elk_worker_ips[@]} 個 (${elk_worker_ips[*]})"
    echo ""
    echo "🔑 認證信息："
    echo "  用戶名: elastic"
    echo "  密碼: $(kubectl get secret elasticsearch-master-credentials -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo '請手動獲取')"
    echo ""
    echo "🌐 訪問信息："
    echo "  Master 服務: elasticsearch-master:9200"
    echo "  Data 服務: elasticsearch-data:9200"
    echo ""
    echo "🔧 常用命令："
    echo "  檢查叢集狀態: kubectl exec elasticsearch-master-0 -- curl -k -u elastic:密碼 https://localhost:9200/_cluster/health"
    echo "  查看節點: kubectl exec elasticsearch-master-0 -- curl -k -u elastic:密碼 https://localhost:9200/_cat/nodes?v"
    echo "  查看索引: kubectl exec elasticsearch-master-0 -- curl -k -u elastic:密碼 https://localhost:9200/_cat/indices?v"
    echo ""
    echo "🚀 下一步："
    echo "  1. 部署 Kibana: helm install kibana elastic/kibana -f kibana/values.yml"
    echo "  2. 部署 Logstash: helm install logstash elastic/logstash -f logstash/values.yml"
    echo "  3. 部署 Filebeat: helm install filebeat elastic/filebeat -f filebeat/values.yml"
    echo ""
}

# 錯誤處理
error_handler() {
    log_error "❌ 部署過程中發生錯誤 (行號: $1)"
    echo ""
    echo "🛠️  故障排除："
    echo "  1. 檢查節點狀態: kubectl get nodes -o wide"
    echo "  2. 檢查 Pod 狀態: kubectl get pods -l app=elasticsearch"
    echo "  3. 查看日誌: kubectl logs elasticsearch-master-0"
    echo ""
    exit 1
}

# 設置錯誤處理
trap 'error_handler $LINENO' ERR

# 檢查參數
case "${1:-deploy}" in
    deploy)
        main
        ;;
    verify)
        verify_cluster
        ;;
    info)
        show_cluster_info
        ;;
    clean)
        log_warning "🧹 清理 Elasticsearch 叢集..."
        helm uninstall elasticsearch-data || true
        helm uninstall elasticsearch-master || true
        log_success "✅ 清理完成"
        ;;
    test-inventory)
        log_info "🧪 測試 Inventory 解析..."
        inventory_file="ansible/inventories/hosts.ini"
        
        echo "📋 ELK Master 群組 IP:"
        elk_master_ips=($(get_group_ips "elk_master" "$inventory_file"))
        for ip in "${elk_master_ips[@]}"; do
            echo "  - $ip"
        done
        
        echo ""
        echo "📋 ELK Worker 群組 IP:"
        elk_worker_ips=($(get_group_ips "elk_worker" "$inventory_file"))
        for ip in "${elk_worker_ips[@]}"; do
            echo "  - $ip"
        done
        
        echo ""
        echo "📊 統計："
        echo "  Master 節點數: ${#elk_master_ips[@]}"
        echo "  Worker 節點數: ${#elk_worker_ips[@]}"
        echo "  總節點數: $((${#elk_master_ips[@]} + ${#elk_worker_ips[@]}))"
        ;;
    *)
        echo "用法: $0 [deploy|verify|info|clean|test-inventory]"
        echo "  deploy         - 部署多節點叢集 (預設)"
        echo "  verify         - 驗證叢集狀態"
        echo "  info           - 顯示叢集信息"
        echo "  clean          - 清理叢集"
        echo "  test-inventory - 測試 inventory 解析"
        exit 1
        ;;
esac
