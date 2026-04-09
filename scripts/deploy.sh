#!/usr/bin/env bash
# ============================================================
# deploy.sh - 监控系统部署脚本
# ============================================================
# 用法：
#   ./deploy.sh manager   — 部署管理端 (Prometheus + Loki + Grafana)
#   ./deploy.sh agent     — 部署采集端 (Node Exporter + cAdvisor + Promtail)
#
# 前置条件：
#   - 已安装 Docker 和 docker-compose
#   - 管理端部署前请修改 prometheus.yml 中的 Tailscale IP
#   - 采集端部署前请修改 promtail-config.yaml 中的管理端 IP
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    echo "用法: $0 {manager|agent}"
    echo ""
    echo "  manager  — 部署管理端 (Prometheus + Loki + Grafana)"
    echo "  agent    — 部署采集端 (Node Exporter + cAdvisor + Promtail)"
    exit 1
}

check_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo "错误: 未找到 docker，请先安装 Docker"
        exit 1
    fi

    if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
        echo "错误: 未找到 docker compose 或 docker-compose，请先安装"
        exit 1
    fi
}

# 检测使用 docker compose (v2) 还是 docker-compose (v1)
get_compose_cmd() {
    if docker compose version &> /dev/null; then
        echo "docker compose"
    else
        echo "docker-compose"
    fi
}

deploy_manager() {
    echo "=============================="
    echo "  部署管理端 (Manager)"
    echo "=============================="

    local compose_dir="${PROJECT_ROOT}/manager"
    local compose_cmd
    compose_cmd=$(get_compose_cmd)

    # 检查是否已修改 IP 占位符
    if grep -q '<TAILSCALE_IP_' "${compose_dir}/prometheus.yml"; then
        echo ""
        echo "警告: prometheus.yml 中仍包含 IP 占位符 (<TAILSCALE_IP_X>)"
        echo "请先编辑 ${compose_dir}/prometheus.yml，将占位符替换为实际的 Tailscale IP 地址"
        echo ""
        read -r -p "是否继续部署？(y/N): " confirm
        if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
            echo "部署已取消"
            exit 0
        fi
    fi

    echo "正在启动管理端服务..."
    cd "${compose_dir}"
    ${compose_cmd} up -d

    echo ""
    echo "管理端部署完成！"
    echo "  - Prometheus: http://localhost:9090"
    echo "  - Loki:       http://localhost:3100"
    echo "  - Grafana:    http://localhost:3000 (admin/admin)"
    echo ""
}

deploy_agent() {
    echo "=============================="
    echo "  部署采集端 (Agent)"
    echo "=============================="

    local compose_dir="${PROJECT_ROOT}/agent"
    local compose_cmd
    compose_cmd=$(get_compose_cmd)

    # 检查是否已修改 Loki 地址
    if grep -q '<MANAGER_TAILSCALE_IP>' "${compose_dir}/promtail-config.yaml"; then
        echo ""
        echo "警告: promtail-config.yaml 中仍包含管理端 IP 占位符 (<MANAGER_TAILSCALE_IP>)"
        echo "请先编辑 ${compose_dir}/promtail-config.yaml，将占位符替换为管理端的实际 Tailscale IP 地址"
        echo ""
        read -r -p "是否继续部署？(y/N): " confirm
        if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
            echo "部署已取消"
            exit 0
        fi
    fi

    echo "正在启动采集端服务..."
    cd "${compose_dir}"
    ${compose_cmd} up -d

    echo ""
    echo "采集端部署完成！"
    echo "  - Node Exporter: http://localhost:9100/metrics"
    echo "  - cAdvisor:      http://localhost:8080"
    echo ""
}

# ============================================================
# 主入口
# ============================================================
if [[ $# -lt 1 ]]; then
    usage
fi

check_dependencies

case "$1" in
    manager)
        deploy_manager
        ;;
    agent)
        deploy_agent
        ;;
    *)
        echo "错误: 未知参数 '$1'"
        usage
        ;;
esac
