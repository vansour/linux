# Linux 系统配置助手 — 设计文档

## 概述

一个纯 Bash 交互式菜单脚本，用于在 Debian/Ubuntu 系统上快速完成常见系统配置。
单文件，零依赖，`curl | bash` 可用。

## 目标

提供 5 个功能 + 状态查看，以交互菜单驱动：

```
┌─────────────────────────────────────┐
│     Linux 系统配置助手              │
│     检测系统: Ubuntu 22.04          │
├─────────────────────────────────────┤
│  1. 开启 BBR + fq + ECN            │
│  2. 开启时间同步 (NTP)              │
│  3. 修改 SSH 端口                   │
│  4. 开启 root 密码登录              │
│  5. 删除 SSH 密钥，仅用密码登录     │
│  6. 查看当前状态                    │
│  0. 退出                            │
└─────────────────────────────────────┘
```

## 约束

- 语言：纯 Bash
- 目标发行版：Debian / Ubuntu（apt 生态）
- 要求 root 权限，脚本启动时检查 EUID
- 文件结构：单文件 `sysctl-helper.sh`
- 所有修改操作前自动备份（带时间戳）

---

## 功能详细设计

### 通用安全措施

- `set -euo pipefail`（但菜单循环捕获错误，不退出）
- 颜色标记：成功绿、警告黄、错误红、信息蓝
- 每次修改操作前打印"将要做什么"并请求确认 (y/N)

---

### 功能 1：开启 BBR + fq + ECN + bpftune

#### 阶段一：清空现有配置
- 扫描 `/etc/sysctl.conf` 及 `/etc/sysctl.d/*.conf`，注释掉与以下参数相关的行：
  - `net.core.default_qdisc`
  - `net.ipv4.tcp_congestion_control`
  - `net.ipv4.tcp_ecn`
- 卸载非 BBR 的拥塞控制模块（`tcp_cdg`、`tcp_westwood`、`tcp_htcp` 等），使当前 `congestion_control` 重置回系统默认
- 如果 `/etc/sysctl.d/99-bbr.conf` 已存在，直接重建

#### 阶段二：写入新配置
- 检查内核版本 ≥ 4.9（BBR 最低要求），不满足则退出并提示
- `modprobe tcp_bbr` 加载 BBR 内核模块
- 写入 `/etc/sysctl.d/99-bbr.conf`:
  ```
  net.core.default_qdisc = fq
  net.ipv4.tcp_congestion_control = bbr
  net.ipv4.tcp_ecn = 1
  ```
- `sysctl -p /etc/sysctl.d/99-bbr.conf` 即时生效

#### 阶段三：验证配置生效
- `sysctl net.ipv4.tcp_congestion_control` 确认输出为 `bbr`
- `sysctl net.core.default_qdisc` 确认输出为 `fq`
- `sysctl net.ipv4.tcp_ecn` 确认输出为 `1`
- `ss -ti` 抽样检查活跃连接中是否出现 `bbr` 拥塞算法
- 打印验证结果

#### 阶段四：安装 bpftune
- 检查 `bpftune` 是否已安装（`command -v bpftune` 和 `systemctl is-active bpftune`）
- 未安装时尝试：
  1. `apt update && apt install -y bpftune`
  2. 若 1 失败，从 GitHub releases 获取最新 `.deb` URL 并安装
  3. 若仍失败，提示用户手动安装并给出 URL
- 安装成功后：`systemctl enable --now bpftune`
- 验证：`systemctl is-active bpftune`

---

### 功能 2：开启时间同步 (NTP)

- 检测当前时间同步状态：`timedatectl show`
- 如果 `systemd-timesyncd` 可用（Ubuntu 16.04+ 默认内置）：
  - `timedatectl set-ntp true`
  - `systemctl restart systemd-timesyncd`
  - 确保 NTP 服务器配置为 `pool.ntp.org`（修改 `/etc/systemd/timesyncd.conf` 如需要）
- 如果 `systemd-timesyncd` 不存在：
  - 安装 `chrony`（`apt install -y chrony`）
  - `systemctl enable --now chrony`
- 验证：`timedatectl status` 确认 `Network time on: yes` 且 `NTP service: active`

---

### 功能 3：修改 SSH 端口

- 用户输入新端口号
  - 校验：1-65535 数字，排除常用保留端口 (0)
  - 警告 1024 以下端口需要 root 权限（SSH 本身已是 root，正常）
- 备份 `/etc/ssh/sshd_config` → `/etc/ssh/sshd_config.bak.YYYYMMDD-HHMMSS`
- 修改逻辑：
  - 若 `Port <N>` 已存在，替换
  - 若 `#Port 22` 被注释，取消注释并改为新端口
  - 若无 Port 行，追加
- 检查并处理防火墙：
  - 若 `ufw` 为 active：`ufw allow <new_port>/tcp`，提示是否需要删除旧端口规则
  - 若 `iptables` 有 INPUT 规则：提示用户手动放行
- 提示是否需要删除旧端口（保留为 fallback）
- 重启 sshd：`systemctl restart sshd`（或 `ssh`）
- 警告：**当前连接不会断开，但建议新开终端用新端口测试后再关闭当前会话**

---

### 功能 4：开启 root 密码登录

- 备份 `/etc/ssh/sshd_config` 和 `/etc/ssh/sshd_config.d/` 整个目录
- 设置 `PermitRootLogin yes`：
  - 主配置 `/etc/ssh/sshd_config` 中注释/替换
  - 遍历 `/etc/ssh/sshd_config.d/*.conf`，注释掉其中的 `PermitRootLogin` 行（厂商覆盖）
- 设置 `PasswordAuthentication yes`（同理，含 drop-in 目录）
- 检查 root 密码状态：
  - `passwd -S root` 判断状态
  - 若为 `L`（locked）或 `NP`（无密码），强制用户先运行 `passwd root` 设置密码
- 重启 sshd
- 提示：测试 `ssh root@<ip>` 密码登录

---

### 功能 5：删除 SSH 密钥，仅用密码登录

#### 前置检查（强制）
- 执行 `passwd -S root` 检查 root 密码状态
- 若状态非 `P`（usable password），**强制中断**并提示用户先运行功能 4 或手动 `passwd root`

#### 扫描阶段
遍历以下所有位置，生成"阻止密码登录的因素"清单：

| 检查点 | 路径 | 检查内容 |
|--------|------|---------|
| root 公钥 | `/root/.ssh/authorized_keys` | 是否存在且非空 |
| 其他用户公钥 | `/home/*/.ssh/authorized_keys` | 是否存在（仅报告，不操作） |
| sshd 主配置 | `/etc/ssh/sshd_config` | `PasswordAuthentication no`、`AuthenticationMethods` 含 `publickey`、`PermitRootLogin` 限制 |
| drop-in 配置 | `/etc/ssh/sshd_config.d/*.conf` | 同上三项，**逐文件检查**（DMIT 等厂商用此阻止密码登录） |
| Match 块 | `/etc/ssh/sshd_config` 及 drop-in | `Match User root` 或 `Match All` 内覆盖认证方式 |
| PAM | `/etc/pam.d/sshd` | 是否有 `pam_listfile` 或额外限制 |
| 账户锁定 | `passwd -S root` | 是否为 L/NP |

#### 展示清单
- 将扫描结果汇总为清单，标注每个因素的具体文件和行号
- 展示给用户，等待确认 (y/N)

#### 清理阶段
- 备份 `/etc/ssh/sshd_config` 和 `/etc/ssh/sshd_config.d/`
- **主配置文件**：
  - `PasswordAuthentication yes`
  - 注释 `AuthenticationMethods`
  - `PermitRootLogin yes`
- **drop-in 目录**：
  - 注释所有 `PermitRootLogin` 行
  - 注释所有 `PasswordAuthentication no`
  - 注释所有 `AuthenticationMethods` 限制
- **authorized_keys**：
  - 清空 `/root/.ssh/authorized_keys`
- **Match 块**：注释块内 `PasswordAuthentication no` 和 `AuthenticationMethods`
- 重启 sshd

#### 验证
- 提示用户立即新开终端窗口测试密码登录：
  ```
  ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@<ip>
  ```
- 警告：若密码错误/未设，将无法登录

---

### 功能 6：查看当前状态

以表格形式展示所有相关配置的当前状态：

| 项目 | 检测内容 | 来源 |
|------|---------|------|
| 拥塞控制算法 | `sysctl net.ipv4.tcp_congestion_control` | 内核 |
| 默认 qdisc | `sysctl net.core.default_qdisc` | 内核 |
| ECN | `sysctl net.ipv4.tcp_ecn` | 内核 |
| BBR 模块 | `lsmod \| grep tcp_bbr` | 内核模块 |
| bpftune | `systemctl is-active bpftune` | systemd |
| NTP 同步 | `timedatectl status` | systemd |
| SSH 端口 | `sshd -T \| grep -E '^port'` | sshd |
| PermitRootLogin | `sshd -T \| grep permitrootlogin` | sshd |
| PasswordAuth | `sshd -T \| grep passwordauthentication` | sshd |
| root 密码状态 | `passwd -S root` | passwd |
| authorized_keys | 文件大小/存在性 | 文件系统 |
| sshd_config.d | 列出所有 .conf 及其覆盖项 | 文件系统 |

---

## 实现结构

```
sysctl-helper.sh           # 单文件
├── 常量（颜色、路径）
├── 工具函数（msg_info, msg_ok, msg_warn, msg_err, confirm, backup_file）
├── check_root()           # root 权限检查
├── check_os()             # Debian/Ubuntu 检测
├── menu_main()            # 主菜单循环
├── func_enable_bbr()      # 功能 1
├── func_enable_ntp()      # 功能 2
├── func_change_ssh_port() # 功能 3
├── func_enable_root_login()# 功能 4
├── func_remove_keys()     # 功能 5
├── func_show_status()     # 功能 6
└── main()                 # 入口
```

## 非功能需求

- 所有备份文件带 `YYYYMMDD-HHMMSS` 时间戳
- 错误处理：`set -euo pipefail` 但菜单循环中捕获错误，不让脚本崩溃退出
- 颜色输出：检查 stdout 是否为 tty，管道/重定向时自动关闭颜色
