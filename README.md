# Galaxy Monitor

服务器与容器监控系统 — 基于 Prometheus + Loki + Grafana + cAdvisor + Node Exporter + Promtail。

## 架构概览

```
┌─────────────────────────────────────────────────┐
│                 Manager (管理端)                  │
│  ┌───────────┐  ┌──────┐  ┌─────────┐          │
│  │ Prometheus │  │ Loki │  │ Grafana │          │
│  │   :9090    │  │:3100 │  │  :3000  │          │
│  └─────┬─────┘  └──┬───┘  └────┬────┘          │
│        │           │           │                │
└────────┼───────────┼───────────┼────────────────┘
         │           │           │
    Tailscale 组网 (抓取指标 / 接收日志)
         │           │
┌────────┼───────────┼────────────────────────────┐
│        │    Agent (每台被控机 - 宿主机直接部署)     │
│  ┌─────┴───────┐  ┌┴────────┐  ┌──────────┐    │
│  │node-exporter│  │Promtail │  │ cAdvisor │    │
│  │   :9100     │  │  (push) │  │  :8080   │    │
│  └─────────────┘  └─────────┘  └──────────┘    │
│         (systemd 服务，宿主机直接运行)             │
└─────────────────────────────────────────────────┘
```

## 目录结构

```
galaxy_monitor/
├── manager/                          # 管理端配置（Docker 部署）
│   ├── docker-compose.yml            # Prometheus + Loki + Grafana
│   ├── prometheus.yml                # Prometheus 抓取配置 (含 10 个 IP 占位符)
│   ├── loki-config.yaml              # Loki 日志存储配置 (保留 720h)
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           │   └── datasources.yaml  # 预配置 Prometheus + Loki 数据源
│           └── dashboards/
│               └── dashboards.yaml   # 仪表盘自动加载配置
├── agent/                            # 采集端配置（宿主机直接部署）
│   ├── node-exporter.service         # Node Exporter systemd 服务文件
│   ├── cadvisor.service              # cAdvisor systemd 服务文件
│   ├── promtail.service              # Promtail systemd 服务文件
│   └── promtail-config.yaml          # Promtail 日志推送配置
├── scripts/
│   └── deploy.sh                     # 一键部署脚本
└── README.md
```

## 快速开始

### 前置条件

- **管理端**：已安装 Docker 和 docker-compose
- **采集端**：Linux 系统，已安装 systemd、curl（或 wget）、unzip，需要 root 权限
- 所有服务器已通过 Tailscale 组网

### 1. 部署管理端

1. 编辑 `manager/prometheus.yml`，将 `<TAILSCALE_IP_X>` 占位符替换为各被控机的实际 Tailscale IP 地址。

2. 运行部署脚本：
   ```bash
   ./scripts/deploy.sh manager
   ```

3. 访问 Grafana：`http://<MANAGER_IP>:3000`（默认账号：admin / admin）

### 2. 部署采集端

在每台被控机上：

1. 编辑 `agent/promtail-config.yaml`，将 `<MANAGER_TAILSCALE_IP>` 替换为管理端的 Tailscale IP 地址。

2. 以 root 权限运行部署脚本：
   ```bash
   sudo ./scripts/deploy.sh agent
   ```

   部署脚本会自动完成以下操作：
   - 下载 Node Exporter、cAdvisor、Promtail 二进制文件
   - 创建对应的系统用户
   - 安装 systemd 服务文件并启动服务

3. 查看服务状态：
   ```bash
   systemctl status node-exporter
   systemctl status cadvisor
   systemctl status promtail
   ```

## 监控能力

| 类别 | 指标 | 来源 |
|------|------|------|
| 系统指标 | CPU 使用率、内存使用率、磁盘 I/O、网络流量 | Node Exporter |
| 容器指标 | 镜像名称、容器名称、运行时长、CPU/内存使用 | cAdvisor |
| 系统日志 | systemd journal 日志、/var/log 下的日志文件 | Promtail → Loki |
| 容器日志 | Docker 容器的标准输出日志 | Promtail → Loki |

## 数据保留

- **Prometheus（指标数据）**：30 天（通过 `--storage.tsdb.retention.time=30d` 配置）
- **Loki（日志数据）**：30 天（通过 `retention_period: 720h` 配置）

## 端口说明

| 服务 | 端口 | 部署位置 |
|------|------|----------|
| Grafana | 3000 | Manager |
| Prometheus | 9090 | Manager |
| Loki | 3100 | Manager |
| Node Exporter | 9100 | Agent |
| cAdvisor | 8080 | Agent |

## 注意事项

- 确保 Tailscale 网络中的防火墙规则允许上述端口通信。
- Grafana 首次登录后请立即修改默认密码。
- 采集端部署需要 root 权限以安装 systemd 服务。
- 如果被控机上运行了 Docker，Promtail 会自动采集容器日志（需要 Docker socket 访问权限）。
- cAdvisor 以 root 权限运行以获取完整的容器指标。