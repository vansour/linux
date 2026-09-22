# Linux 一键配置脚本

纯 Bash 交互式 Linux 初始化 / 配置工具。零依赖，任何 Linux 发行版都能跑。

> 当前为 **v0.0.1 框架版**，只搭好了骨架和菜单系统，功能待逐项添加。

## 特性

- **零依赖**：只用 bash + coreutils，不依赖 whiptail/dialog/python
- **中英文混排对齐**：自实现 CJK 宽字符计算，中文菜单不会错位
- **自适应布局**：终端宽 ≥ 66 列双列菜单，窄屏自动降级单列
- **发行版自动识别**：debian / rhel / arch / alpine / suse 五大分支，包管理命令自动适配
- **模块化**：新增功能 = 新增一个 `modules/*.sh` 文件，不用改主程序
- **单文件分发**：开发用多文件，分发用一个自包含 `install.sh`

## 运行

### 方式一：源码目录（开发用）

```bash
sudo bash main.sh
```

### 方式二：单文件一键运行（给用户用）

源码是模块化的，但 `build.sh` 会把它打包成一个**完全自包含**的 `install.sh` —— 不依赖 lib/、modules/，也不需要额外下载任何文件：

```bash
bash build.sh          # 打包，产出 install.sh
sudo bash install.sh   # 单文件运行
```

分发时只需托管这一个文件，用户侧支持两种写法：

```bash
# 推荐：stdin 留给自己，交互最稳
bash <(curl -sL https://raw.githubusercontent.com/vansour/linux/main/install.sh)

# 也支持：脚本改用 /dev/tty 读键盘，交互同样正常
curl -sL https://raw.githubusercontent.com/vansour/linux/main/install.sh | sudo bash
```

> `curl | bash` 能工作是因为所有交互读取都走了 `ui_read`，它在 stdin 被 bash 占用读脚本时
> 自动改从 `/dev/tty` 读键盘（rustup / docker 安装脚本同款做法）。

**改完源码记得重新 `bash build.sh`**，否则 `install.sh` 还是旧的。

### 命令行选项

| 选项 | 说明 |
| --- | --- |
| `-h, --help` | 帮助 |
| `-V, --version` | 版本号 |
| `-l, --list` | 列出已注册模块后退出（不需要终端，可用于 CI 检查） |
| `-d, --debug` | 输出调试日志 |
| `--no-color` | 禁用彩色（也支持 `NO_COLOR=1` 环境变量） |
| `--log FILE` | 指定日志文件，默认 `/var/log/linux-toolkit.log` |

所有操作写入日志文件，方便出问题后回溯。

## 目录结构

```
linux/
├── main.sh              # 入口：参数解析 → 载入库 → 探测系统 → 载入模块 → 主菜单
├── build.sh             # 打包：把上面所有文件合成单个 install.sh
├── install.sh           # 【自动生成，勿手改】单文件分发版
├── lib/
│   ├── core.sh          # 颜色 / 日志 / 系统探测 / 包管理抽象 / 交互函数
│   ├── ui.sh            # 界面渲染：宽字符计算、边框、菜单、标题
│   ├── module.sh        # 模块开发辅助：module_begin/end、run_submenu
│   └── registry.sh      # 模块注册表 + 主菜单循环
├── modules/
│   ├── 01-system.sh     # 系统信息
│   ├── 02-update.sh     # 系统更新
│   ├── 03-tools.sh      # 常用工具
│   ├── 04-network.sh    # 网络设置
│   ├── 05-user.sh       # 用户管理
│   └── 06-service.sh    # 服务管理
└── .shellcheckrc        # shellcheck 配置（多文件 source 架构的误报屏蔽）
```

`main.sh` 通过 `SINGLE_FILE` 变量区分两种形态：置 1 时跳过 `lib/` `modules/` 的磁盘加载
（内容已内联），也不校验这两个目录是否存在。两种形态共用同一份源码。

## 添加一个新功能

### 1. 叶子功能（干完就回菜单）

在对应模块文件里加一个函数，结尾调 `module_end`：

```bash
sys_overview() {
    ui_section "主机名"
    ui_kv "主机名" "$HOSTNAME_SHORT"
    ui_kv "内核"   "$KERNEL"
    module_end                # 必须：暂停等按键，否则输出一闪而过
}
```

把函数名加进模块的 `fns` 数组即可出现在菜单里。

### 2. 新增一个顶级模块

新建 `modules/07-xxx.sh`：

```bash
#!/usr/bin/env bash
# 模块: 防火墙

fw_status() {
    ui_section "防火墙状态"
    # ...
    module_end
}

fw_rules() {
    # ...
    module_end
}

menu_firewall() {
    local items=(
        "状态查看|当前规则 / 开关状态"
        "规则管理|放行 / 封禁端口"
    )
    local fns=(fw_status fw_rules)
    run_submenu "防火墙" items fns
}

# 只在 debian/rhel 上显示；省略第 5 个参数 = 所有发行版都显示
register_module "firewall" "防火墙" "menu_firewall" "ufw / firewalld" "debian rhel"
```

主菜单会自动多出这一项，**不需要改任何其它文件**。

## API 速查

### 界面

| 函数 | 用途 |
| --- | --- |
| `ui_screen` | 清屏 + 画顶部横幅 |
| `ui_title "标题"` | 分节标题（带横线） |
| `ui_section "小标题"` | 内容区小节标题（带竖条） |
| `ui_kv 键 值` | 对齐的键值行 |
| `ui_menu 标题 数组名 [返回文案]` | 渲染菜单，结果存 `UI_CHOICE`（0 起下标，-1 = 返回/退出） |
| `_str_width "字符串"` | 计算显示宽度（中文算 2 列） |

### 交互

| 函数 | 用途 |
| --- | --- |
| `ui_read 变量名` | **统一读取入口**：stdin 是终端就读 stdin，否则读 `/dev/tty`。自己写交互时用这个，别直接用 `read` |
| `confirm "提示" [y\|n]` | y/N 确认，返回 0/1 |
| `ask "提示" [默认值]` | 读取输入，结果存 `REPLY` |
| `pause [提示语]` | 等待按键 |

### 日志

`log_debug` / `log_info` / `log_ok` / `log_warn` / `log_err` / `die`

### 系统 & 包管理

| 函数 | 用途 |
| --- | --- |
| `detect_system` | 填充 `DISTRO_ID` `DISTRO_NAME` `DISTRO_VERSION` `DISTRO_FAMILY` `ARCH` `KERNEL` |
| `is_root` / `require_root` | 权限判断 |
| `have_cmd 命令` | 命令是否存在 |
| `pkg_refresh` | 刷新软件源缓存 |
| `pkg_install 包...` | 安装（自动适配 apt/dnf/pacman/apk/zypper） |
| `ensure_pkg 命令 包名` | 命令不存在才安装 |

### 已有全局变量

`APP_NAME` `APP_VERSION` `SINGLE_FILE` `DISTRO_*` `ARCH` `KERNEL` `HOSTNAME_SHORT` `SCRIPT_DIR` `LIB_DIR` `MODULES_DIR`

## 开发注意

- 模块文件按**文件名排序**载入，序数前缀（`01-`）控制主菜单顺序
- `register_module` 的 id 必须唯一，重复会被拒绝并告警
- 模块文件在**当前 shell**中被 source，不是子进程 —— 注意别污染全局变量，局部变量加 `local`
- 需要 root 的操作，函数开头调 `require_root`
- **交互一律用 `ui_read`，不要直接 `read`** —— 否则 `curl | bash` 场景下会去读脚本管道而不是键盘
- 改完跑静态检查 + 重新打包：

```bash
shellcheck main.sh lib/*.sh modules/*.sh build.sh
bash build.sh
```
