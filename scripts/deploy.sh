#!/usr/bin/env bash
# ============================================================
# deploy.sh - 监控系统部署脚本
# ============================================================
# 用法：
#   ./deploy.sh manager   — 部署管理端 (Prometheus + Loki + Grafana)
#   ./deploy.sh agent     — 部署采集端 (Node Exporter + cAdvisor + Promtail)
#
# 前置条件：
#   - 管理端：已安装 Docker 和 docker-compose
#   - 采集端：已安装 systemd，需要 root 权限
#   - 管理端部署前请修改 prometheus.yml 中的 Tailscale IP
#   - 采集端部署前请修改 promtail-config.yaml 中的管理端 IP
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Agent 组件版本
NODE_EXPORTER_VERSION="1.8.1"
CADVISOR_VERSION="0.49.1"
PROMTAIL_VERSION="2.9.9"

usage() {
    echo "用法: $0 {manager|agent}"
    echo ""
    echo "  manager  — 部署管理端 (Prometheus + Loki + Grafana)"
    echo "  agent    — 部署采集端 (Node Exporter + cAdvisor + Promtail)"
    exit 1
}

check_docker_dependencies() {
    if ! command -v docker &> /dev/null; then
        echo "错误: 未找到 docker，请先安装 Docker"
        exit 1
    fi

    if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
        echo "错误: 未找到 docker compose 或 docker-compose，请先安装"
        exit 1
    fi
}

check_agent_dependencies() {
    if [[ $EUID -ne 0 ]]; then
        echo "错误: 采集端部署需要 root 权限，请使用 sudo 运行"
        exit 1
    fi

    if ! command -v systemctl &> /dev/null; then
        echo "错误: 未找到 systemctl，采集端需要 systemd 环境"
        exit 1
    fi

    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        echo "错误: 未找到 curl 或 wget，请先安装其中之一"
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

# 下载文件的辅助函数
download_file() {
    local url="$1"
    local dest="$2"

    echo "  下载: ${url}"
    if command -v curl &> /dev/null; then
        curl -fsSL -o "${dest}" "${url}"
    else
        wget -q -O "${dest}" "${url}"
    fi
}

# 检测系统架构
detect_arch() {
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l)        echo "armv7" ;;
        *)
            echo "错误: 不支持的架构 ${arch}" >&2
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------
# 安装 Node Exporter
# ----------------------------------------------------------
install_node_exporter() {
    local version="${NODE_EXPORTER_VERSION}"
    local arch
    arch=$(detect_arch)

    echo ""
    echo "--- 安装 Node Exporter v${version} ---"

    if [[ -f /usr/local/bin/node_exporter ]]; then
        local current_version
        current_version=$(/usr/local/bin/node_exporter --version 2>&1 | head -1 | grep -oP 'version \K[0-9.]+' || echo "unknown")
        if [[ "${current_version}" == "unknown" ]]; then
            echo "  警告: 无法识别已安装的 node_exporter 版本，将重新下载"
            download_and_install_node_exporter "${version}" "${arch}"
        elif [[ "${current_version}" == "${version}" ]]; then
            echo "  已安装版本 ${current_version}，版本一致，跳过下载"
        else
            echo "  已安装版本 ${current_version}，目标版本 ${version}，重新下载"
            download_and_install_node_exporter "${version}" "${arch}"
        fi
    else
        download_and_install_node_exporter "${version}" "${arch}"
    fi

    # 创建用户（如果不存在）
    if ! id -u node_exporter &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
        echo "  已创建用户 node_exporter"
    fi

    # 安装 systemd 服务文件
    cp "${PROJECT_ROOT}/agent/node-exporter.service" /etc/systemd/system/node-exporter.service

    systemctl daemon-reload
    systemctl enable node-exporter
    systemctl restart node-exporter

    echo "  Node Exporter 已启动 (端口 9100)"
}

download_and_install_node_exporter() {
    local version="$1"
    local arch="$2"
    local tarball="node_exporter-${version}.linux-${arch}.tar.gz"
    local url="https://github.com/prometheus/node_exporter/releases/download/v${version}/${tarball}"
    local tmpdir

    tmpdir=$(mktemp -d)
    download_file "${url}" "${tmpdir}/${tarball}"

    tar -xzf "${tmpdir}/${tarball}" -C "${tmpdir}"
    cp "${tmpdir}/node_exporter-${version}.linux-${arch}/node_exporter" /usr/local/bin/node_exporter
    chmod +x /usr/local/bin/node_exporter

    rm -rf "${tmpdir}"
    echo "  二进制文件已安装到 /usr/local/bin/node_exporter"
}

# ----------------------------------------------------------
# 安装 cAdvisor
# ----------------------------------------------------------
install_cadvisor() {
    local version="${CADVISOR_VERSION}"
    local arch
    arch=$(detect_arch)

    echo ""
    echo "--- 安装 cAdvisor v${version} ---"

    # cAdvisor 的 release 二进制文件命名规则
    local binary_name="cadvisor-v${version}-linux-${arch}"
    local url="https://github.com/google/cadvisor/releases/download/v${version}/${binary_name}"

    if [[ -f /usr/local/bin/cadvisor ]]; then
        echo "  已安装，重新下载覆盖"
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    download_file "${url}" "${tmpdir}/cadvisor"
    cp "${tmpdir}/cadvisor" /usr/local/bin/cadvisor
    chmod +x /usr/local/bin/cadvisor
    rm -rf "${tmpdir}"
    echo "  二进制文件已安装到 /usr/local/bin/cadvisor"

    # 安装 systemd 服务文件
    cp "${PROJECT_ROOT}/agent/cadvisor.service" /etc/systemd/system/cadvisor.service

    systemctl daemon-reload
    systemctl enable cadvisor
    systemctl restart cadvisor

    echo "  cAdvisor 已启动 (端口 8080)"
}

# ----------------------------------------------------------
# 安装 Promtail
# ----------------------------------------------------------
install_promtail() {
    local version="${PROMTAIL_VERSION}"
    local arch
    arch=$(detect_arch)

    echo ""
    echo "--- 安装 Promtail v${version} ---"

    if [[ -f /usr/local/bin/promtail ]]; then
        local current_version
        current_version=$(/usr/local/bin/promtail --version 2>&1 | head -1 | grep -oP 'version \K[0-9.]+' || echo "unknown")
        if [[ "${current_version}" == "unknown" ]]; then
            echo "  警告: 无法识别已安装的 promtail 版本，将重新下载"
            download_and_install_promtail "${version}" "${arch}"
        elif [[ "${current_version}" == "${version}" ]]; then
            echo "  已安装版本 ${current_version}，版本一致，跳过下载"
        else
            echo "  已安装版本 ${current_version}，目标版本 ${version}，重新下载"
            download_and_install_promtail "${version}" "${arch}"
        fi
    else
        download_and_install_promtail "${version}" "${arch}"
    fi

    # 创建用户（如果不存在）
    if ! id -u promtail &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin promtail
        echo "  已创建用户 promtail"
    fi

    # 创建配置目录和数据目录
    mkdir -p /etc/promtail
    mkdir -p /var/lib/promtail
    chown promtail:promtail /var/lib/promtail

    # 复制配置文件
    cp "${PROJECT_ROOT}/agent/promtail-config.yaml" /etc/promtail/config.yml
    chown promtail:promtail /etc/promtail/config.yml

    # 确保 promtail 用户可以读取日志文件
    if usermod -aG systemd-journal promtail 2>/dev/null; then
        echo "  已将 promtail 加入 systemd-journal 组"
    else
        echo "  警告: 无法将 promtail 加入 systemd-journal 组，journal 日志采集可能不可用"
    fi
    if usermod -aG adm promtail 2>/dev/null; then
        echo "  已将 promtail 加入 adm 组"
    else
        echo "  警告: 无法将 promtail 加入 adm 组，/var/log 日志采集可能受限"
    fi
    # 如果有 Docker，允许 promtail 读取 Docker socket
    if getent group docker &>/dev/null; then
        if usermod -aG docker promtail 2>/dev/null; then
            echo "  已将 promtail 加入 docker 组"
        else
            echo "  警告: 无法将 promtail 加入 docker 组，Docker 容器日志采集可能不可用"
        fi
    fi

    # 安装 systemd 服务文件
    cp "${PROJECT_ROOT}/agent/promtail.service" /etc/systemd/system/promtail.service

    systemctl daemon-reload
    systemctl enable promtail
    systemctl restart promtail

    echo "  Promtail 已启动"
}

download_and_install_promtail() {
    local version="$1"
    local arch="$2"
    local zipfile="promtail-linux-${arch}.zip"
    local url="https://github.com/grafana/loki/releases/download/v${version}/${zipfile}"
    local tmpdir

    tmpdir=$(mktemp -d)
    download_file "${url}" "${tmpdir}/${zipfile}"

    # promtail 发行包为 zip 格式
    if ! command -v unzip &> /dev/null; then
        echo "错误: 未找到 unzip，请先安装 unzip"
        rm -rf "${tmpdir}"
        exit 1
    fi

    unzip -o -q "${tmpdir}/${zipfile}" -d "${tmpdir}"
    cp "${tmpdir}/promtail-linux-${arch}" /usr/local/bin/promtail
    chmod +x /usr/local/bin/promtail

    rm -rf "${tmpdir}"
    echo "  二进制文件已安装到 /usr/local/bin/promtail"
}

deploy_manager() {
    echo "=============================="
    echo "  部署管理端 (Manager)"
    echo "=============================="

    check_docker_dependencies

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

    check_agent_dependencies

    local agent_dir="${PROJECT_ROOT}/agent"

    # 检查是否已修改 Loki 地址
    if grep -q '<MANAGER_TAILSCALE_IP>' "${agent_dir}/promtail-config.yaml"; then
        echo ""
        echo "警告: promtail-config.yaml 中仍包含管理端 IP 占位符 (<MANAGER_TAILSCALE_IP>)"
        echo "请先编辑 ${agent_dir}/promtail-config.yaml，将占位符替换为管理端的实际 Tailscale IP 地址"
        echo ""
        read -r -p "是否继续部署？(y/N): " confirm
        if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
            echo "部署已取消"
            exit 0
        fi
    fi

    echo "正在安装采集端组件（宿主机直接部署）..."

    install_node_exporter
    install_cadvisor
    install_promtail

    echo ""
    echo "=============================="
    echo "  采集端部署完成！"
    echo "=============================="
    echo "  - Node Exporter: http://localhost:9100/metrics"
    echo "  - cAdvisor:      http://localhost:8080"
    echo ""
    echo "查看服务状态："
    echo "  systemctl status node-exporter"
    echo "  systemctl status cadvisor"
    echo "  systemctl status promtail"
    echo ""
}

# ============================================================
# 主入口
# ============================================================
if [[ $# -lt 1 ]]; then
    usage
fi

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
