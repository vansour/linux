# Linux 系统配置助手 (sysctl-helper)

纯 Bash 交互式菜单脚本，在 Debian/Ubuntu 上快速完成常见系统配置。零依赖，一键运行。

## 一键下载运行

```bash
curl -sSL https://raw.githubusercontent.com/vansour/linux/main/sysctl-helper.sh | sudo bash
```

## 功能菜单

```
┌─────────────────────────────────────┐
│     Linux 系统配置助手              │
│     检测系统: Ubuntu 22.04          │
├─────────────────────────────────────┤
│  1. 开启 BBR + fq + ECN + bpftune  │
│  2. 开启时间同步 (NTP)              │
│  3. 修改 SSH 端口                   │
│  4. 开启 root 密码登录              │
│  5. 删除 SSH 密钥，仅用密码登录     │
│  6. 开启/禁用 IPv6                  │
│  7. 配置 Swap                       │
│  0. 退出                            │
└─────────────────────────────────────┘
```

| # | 功能 | 说明 |
|---|------|------|
| 1 | BBR + fq + ECN + bpftune | 展示当前状态 → 清空现有拥塞控制配置 → 写入 BBR/fq/ECN → 验证生效 → 安装 bpftune |
| 2 | NTP 时间同步 | 展示当前同步状态 → 选择时区和 NTP 服务器 → 配置 systemd-timesyncd 或 chrony |
| 3 | 修改 SSH 端口 | 展示当前端口 → 输入新端口 → 备份配置 → 修改主配置+drop-in → 处理 ufw → 重启 sshd |
| 4 | 开启 root 密码登录 | 展示当前 PermitRootLogin/PasswordAuth/root 密码状态 → 修改配置（含厂商 drop-in 目录） |
| 5 | 仅用密码登录 | 展示当前状态 → 强制前置 root 密码检查 → 扫描全部阻止因素 → 清理密钥 |
| 6 | 开启/禁用 IPv6 | 展示当前 IPv6 状态 → 即时切换 + 持久化 sysctl 配置 + 可选 GRUB 内核参数 |
| 7 | 配置 Swap | 展示当前 Swap 状态和内存 → 添加/删除/调整 swap 文件（默认 /swapfile），建议容量不超过内存 |

## 依赖要求

| 项目 | 要求 |
|------|------|
| 系统 | Debian / Ubuntu（apt 生态） |
| 权限 | root（sudo） |
| Bash | 4.0+ |

## 手动下载

```bash
# 下载脚本
curl -sSL -o sysctl-helper.sh https://raw.githubusercontent.com/vansour/linux/main/sysctl-helper.sh

# 赋予执行权限
chmod +x sysctl-helper.sh

# 以 root 运行
sudo bash sysctl-helper.sh
```

## 安全提示

- SSH 相关操作（功能 3/4/5）会**自动备份**原配置文件（时间戳格式 `.bak.YYYYMMDD-HHMMSS`）
- 修改 SSH 端口后请**另开终端测试**新端口，确认可用后再关闭当前会话
- 功能 5 执行前**强制要求 root 密码已设置**，防止锁死自己
