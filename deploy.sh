#!/usr/bin/env bash
# ============================================================
# AstrBot + NapCat 一键搭建脚本 (Ubuntu 20+ / Debian 11+)
# 全部使用 Shell 方式安装，无需 Docker，针对国内网络优化
#
# 用法:
#   bash deploy.sh                     # 交互引导模式(推荐)
#   bash deploy.sh --source            # AstrBot 改用 git 源码方式(自动走 GitHub 加速)
#   bash deploy.sh --napcat-installer  # NapCat 改用官方一键脚本(安装到 /opt)
#   bash deploy.sh --astrbot-only      # 仅安装 AstrBot
#   bash deploy.sh --napcat-only       # 仅安装 NapCat
# ============================================================

set -e

# ---------- 非交互模式 ----------
# 避免 apt 安装时弹出 needrestart / debconf 等对话框阻塞自动化部署
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---------- 配置项 ----------
INSTALL_ASTRBOT=1
INSTALL_NAPCAT=1
USE_SOURCE=0
MENU_MODE=1
# NapCat 安装方式: 1=新式非入侵式启动器(默认,不污染系统) 0=官方一键脚本(安装到 /opt)
NAPCAT_LAUNCHER=1
# 详细输出日志目录（前台只显示一行进度条，完整日志见此处）
LOG_DIR="$PWD/logs"

# ---------- 作者与仓库(欢迎 Banner 显示, 部署前可自行修改) ----------
AUTHOR="须知Ntk"                                          # 脚本作者名
AUTHOR_GITHUB="https://github.com/10XuQ"               # 作者 GitHub 主页
REPO_URL="https://github.com/10XuQ/Fast_Deploy_Astrbot_Napcat"   # 本脚本仓库页

# ---------- 国内网络加速配置 ----------
# PyPI 清华镜像：uv/pip 安装 Python 依赖时使用
PYPI_MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"
# GitHub 加速前缀：解决 git clone 网络错误。
# 加速站可能失效，失效时换用其他前缀，如 https://ghfast.top/ 或 https://gh-proxy.com/，
# 也可留空(GH_PROXY="")改为直连。
GH_PROXY="https://gh-proxy.com/"
ASTRBOT_REPO="https://github.com/AstrBotDevs/AstrBot.git"

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;36m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[信息]${NC} $1"; }
warn()  { echo -e "${YELLOW}[提示]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; }
step()  { echo -e "${BLUE}──────────────────────────────────────${NC}"; echo -e "${BOLD}${CYAN}▶ $1${NC}"; }

# ---------- 网络请求封装: 详细日志 + 超时/重试控制 ----------
# 用法: http_get <URL> <保存文件> <描述>
# 成功返回 0；失败返回 curl 退出码并打印详细错误(便于排查连接超时)
http_get() {
    local url="$1" out="$2" desc="$3"
    local result rc host
    host=$(echo "$url" | awk -F/ '{print $3}')
    echo ""
    info "▶ 开始下载: ${desc}"
    info "  地址: ${url}"
    info "  保存: ${out}"
    info "  策略: 连接超时 10s | 总超时 300s | 失败重试 3 次(间隔 2s)"

    # 临时关闭 set -e，以便捕获 curl 的退出码与详细错误
    set +e
    result=$(curl -fsSL \
        --connect-timeout 10 \
        --max-time 300 \
        --retry 3 --retry-delay 2 --retry-connrefused \
        -o "$out" \
        -w "HTTP状态:%{http_code} | DNS解析:%{time_namelookup}s | TCP连接:%{time_connect}s | TLS握手:%{time_appconnect}s | 首字节:%{time_starttransfer}s | 总耗时:%{time_total}s | 下载:%{size_download}字节" \
        "$url" 2>&1)
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        info "  ✓ 下载成功 | $result"
        return 0
    fi
    error "  ✗ 下载失败 (curl 退出码 ${rc})"
    error "  常见退出码: 6=无法解析主机 | 7=连接被拒绝 | 28=连接/读取超时 | 35/60=TLS证书问题 | 22=HTTP 4xx/5xx"
    echo "$result" | sed 's/^/    /'
    if echo "$result" | grep -q 'HTTP状态:403'; then
        error "  HTTP 403: 可能是 GitHub API 触发限流, 请稍后重试或更换 GH_PROXY 前缀"
    fi
    error "  排查建议: 1) ping ${host} 检查连通性; 2) 检查服务器防火墙/安全组; 3) 更换镜像源或代理后重试"
    return "$rc"
}

# ---------- 进度条执行: 前台单行动画，详细输出写入日志 ----------
# 用法: run_progress <描述> <日志文件名> <命令...>
# 成功返回 0；失败打印日志尾部并返回命令退出码
run_progress() {
    local desc="$1" name="$2"
    shift 2
    local logfile="$LOG_DIR/$name.log" pid rc i
    mkdir -p "$LOG_DIR"
    echo ""
    echo -ne "${CYAN}▶ ${desc}${NC} "
    set +e
    "$@" >"$logfile" 2>&1 &
    pid=$!

    # ---- 趣味动画帧(随机挑一组) ----
    local anims=(
        '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        '◐◓◑◒'
        '▖▘▝▗'
        '▁▃▄▅▆▇█▇▆▅▄▃'
        '→↘↓↙←↖↑↗'
        '|/-\'
    )
    local anim="${anims[$((RANDOM % ${#anims[@]}))]}"
    local anim_len=${#anim}

    i=0
    while kill -0 "$pid" 2>/dev/null; do
        local ch="${anim:$((i % anim_len)):1}"
        local secs=$((i / 10))
        printf "\r${CYAN}▶ %s${NC} %s ${YELLOW}%ss${NC}   " "$desc" "$ch" "$secs"
        i=$((i + 1))
        sleep 0.1
    done
    wait "$pid"
    rc=$?
    set -e

    local praises=("完美!" "漂亮!" "搞定!" "轻松!" "一步到位!" "小菜一碟!")
    local p="${praises[$((RANDOM % ${#praises[@]}))]}"
    printf "\r${GREEN}▶ %s ✓ ${p}${NC}  (用时 %ss)${NC}                    \n" "$desc" "$((i / 10))"
    if [ "$rc" -ne 0 ]; then
        error "命令执行失败 (退出码 ${rc})，完整日志: ${logfile}"
        tail -n 30 "$logfile" | sed 's/^/    /'
        return "$rc"
    fi
    return 0
}

# ---------- 已安装检测 ----------
check_astrbot_installed() {
    [ -x "$HOME/.local/bin/astrbot" ] || [ -f "$HOME/astrbot-data/data/cmd_config.json" ] || [ -d "$HOME/AstrBot/.git" ]
}
check_napcat_installed() {
    [ -f "$PWD/NapCat.AppImage" ] || [ -f "$PWD/napcat.sh" ] || [ -d "$PWD/napcat" ] \
        || [ -d /opt/QQ ] || dpkg -l 2>/dev/null | grep -qi napcat
}

# ---------- 欢迎 Banner ----------
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
   █████╗ ███████╗████████╗██████╗ ██████╗  ██████╗ ████████╗
  ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝
  ███████║███████╗   ██║   ██████╔╝██████╔╝██║   ██║   ██║
  ██╔══██║╚════██║   ██║   ██╔══██╗██╔══██╗██║   ██║   ██║
  ██║  ██║███████║   ██║   ██║  ██║██████╔╝╚██████╔╝   ██║
  ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═════╝  ╚═════╝    ╚═╝
EOF
    echo -e "${NC}"
    echo -e "${BOLD}${CYAN}   QQ 机器人一键搭建 · AstrBot + NapCat${NC}"
    echo -e "${CYAN}   ═══════════════════════════════════════${NC}"
    echo -e "${CYAN}   作者: ${BOLD}${AUTHOR}${NC}${CYAN} · Powered by Deepseek V4 Flash 0731${NC}"
    echo -e "${CYAN}   主页: ${AUTHOR_GITHUB}${NC}"
    echo -e "${CYAN}   仓库: ${REPO_URL}${NC}"
    echo ""
}

# ---------- 系统概览 ----------
show_system_info() {
    local OS="未知系统" KERNEL ARCH CPU MEM DISK
    [ -f /etc/os-release ] && OS=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
    KERNEL=$(uname -r 2>/dev/null || echo "?")
    ARCH=$(uname -m 2>/dev/null || echo "?")
    CPU=$(nproc 2>/dev/null || echo "?")
    MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
    [ -z "$MEM" ] && MEM="?"
    DISK=$(df -h / 2>/dev/null | awk 'NR==2{print $4}')
    [ -z "$DISK" ] && DISK="?"

    local AS NC2
    if check_astrbot_installed; then AS="${GREEN}✓ 已安装${NC}"; else AS="${RED}✗ 未安装${NC}"; fi
    if check_napcat_installed; then NC2="${GREEN}✓ 已安装${NC}"; else NC2="${RED}✗ 未安装${NC}"; fi

    echo -e "${BOLD}${CYAN}  ┌────────────────── 系统概览 ──────────────────┐${NC}"
    printf "  │ %-8s %-28s │\n" "发行版:" "$OS"
    printf "  │ %-8s %-28s │\n" "内核/架构:" "$KERNEL  $ARCH"
    printf "  │ %-8s %-28s │\n" "CPU/内存:" "$CPU 核 / $MEM"
    printf "  │ %-8s %-28s │\n" "磁盘可用:" "$DISK (/ 分区)"
    printf "  │ %-8s %-28s │\n" "AstrBot:" "$AS"
    printf "  │ %-8s %-28s │\n" "NapCat:" "$NC2"
    echo -e "${BOLD}${CYAN}  └───────────────────────────────────────────────┘${NC}"
    echo ""
}

# ---------- 脚本作用说明 ----------
show_intro() {
    echo -e "${BOLD}本脚本能帮你做些什么？${NC}"
    echo "  • 自动安装 AstrBot —— 智能对话机器人框架，WebUI 可视化管理，可接入各大模型"
    echo "  • 自动安装 NapCat —— AppImage 便携版，自带 QQ+NapCat，零系统污染，扫码即用"
    echo "  • 全程无需 Docker，已针对国内网络加速 (PyPI 清华源 / GitHub 镜像)"
    echo "  • 自动检测重复部署，已安装的组件可放心跳过，不会破坏现有环境"
    echo ""
}

# ---------- 参数解析 ----------
parse_args() {
    if [ $# -eq 0 ]; then MENU_MODE=1; else MENU_MODE=0; fi
    while [ $# -gt 0 ]; do
        case "$1" in
            --source) USE_SOURCE=1; shift ;;
            --napcat-installer) NAPCAT_LAUNCHER=0; shift ;;
            --astrbot-only) INSTALL_NAPCAT=0; shift ;;
            --napcat-only)  INSTALL_ASTRBOT=0; shift ;;
            -h|--help)
                echo "用法: bash deploy.sh [--source] [--napcat-installer] [--astrbot-only|--napcat-only]"
                echo "不带参数运行将进入交互引导模式。"
                exit 0 ;;
            *) error "未知参数: $1"; exit 1 ;;
        esac
    done
}

# ---------- 交互引导 ----------
ask_install_mode() {
    echo -e "${BOLD}${CYAN}请选择要安装的内容：${NC}"
    echo "  1) 全部安装   (AstrBot + NapCat，推荐)"
    echo "  2) 仅安装 AstrBot"
    echo "  3) 仅安装 NapCat"
    echo "  4) 退出"
    read -rp "请输入数字 [1-4]，直接回车默认 1: " choice || true
    case "${choice:-1}" in
        1) INSTALL_ASTRBOT=1; INSTALL_NAPCAT=1 ;;
        2) INSTALL_ASTRBOT=1; INSTALL_NAPCAT=0 ;;
        3) INSTALL_ASTRBOT=0; INSTALL_NAPCAT=1 ;;
        4) echo -e "${YELLOW}已退出，期待下次再见～${NC}"; exit 0 ;;
        *) warn "输入无效，将默认安装全部。"; INSTALL_ASTRBOT=1; INSTALL_NAPCAT=1 ;;
    esac
    echo ""

    if [ "$INSTALL_ASTRBOT" = "1" ]; then
        echo -e "${BOLD}${CYAN}AstrBot 安装方式：${NC}"
        echo "  1) uv CLI 方式（推荐，无需 git clone，依赖走清华源）"
        echo "  2) git 源码方式（自动走 GitHub 加速镜像）"
        read -rp "请输入数字 [1-2]，直接回车默认 1: " src || true
        [ "${src:-1}" = "2" ] && USE_SOURCE=1
        echo ""
    fi

    if [ "$INSTALL_NAPCAT" = "1" ]; then
        echo -e "${BOLD}${CYAN}NapCat 安装方式：${NC}"
        echo "  1) AppImage 便携版（推荐，自带 QQ+NapCat，零系统污染）"
        echo "  2) 官方一键脚本（传统方式，QQ 安装到 /opt）"
        read -rp "请输入数字 [1-2]，直接回车默认 1: " nc || true
        [ "${nc:-1}" = "2" ] && NAPCAT_LAUNCHER=0
        echo ""
    fi
}

# ---------- 重复部署确认：返回 0=跳过安装, 1=继续安装 ----------
confirm_skip_or_reinstall() {
    local name="$1"
    echo ""
    warn "检测到 ${name} 已在当前系统部署过，为防止重复安装将默认跳过。"
    read -rp "是否跳过？[Y/n] (选择 n 将重新安装): " ans || true
    case "${ans:-y}" in
        y|Y|"") return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- 前置检查 ----------
pre_check() {
    [ "$EUID" -eq 0 ] && warn "检测到以 root 运行，将直接使用 apt 安装，无需 sudo。"
    if ! command -v apt-get >/dev/null 2>&1; then
        error "仅支持 Debian/Ubuntu 系系统 (apt)。CentOS 请使用官方脚本分别安装。"
        exit 1
    fi
}

# ---------- 安装基础依赖 ----------
install_deps() {
    step "安装基础依赖 (git/curl/screen/xvfb/python3/ffmpeg)"
    local SUDO=""
    [ "$EUID" -ne 0 ] && SUDO="sudo"
    run_progress "更新软件源 (apt update)" "apt_update" $SUDO apt-get update -y
    run_progress "安装依赖包 (apt install)" "apt_install" $SUDO apt-get install -y git curl wget screen xvfb python3 python3-venv ca-certificates ffmpeg file
    # AppImage 需要 FUSE (libfuse.so.2); Ubuntu 24.04 中 libfuse2 已改名为 libfuse2t64
    $SUDO apt-get install -y fuse libfuse2 >/dev/null 2>&1 || \
    $SUDO apt-get install -y fuse libfuse2t64 >/dev/null 2>&1 || \
        warn "FUSE 安装失败，NapCat AppImage 将使用 --appimage-extract-and-run 方式运行"
    info "基础依赖安装完成 (含 ffmpeg)。"
}

# ---------- 安装 uv ----------
install_uv() {
    # 固化 PATH: 新开的 SSH 会话 / screen 内 bash -c 都能直接找到 uv 和 astrbot
    export PATH="$HOME/.local/bin:$PATH"
    if ! grep -q '\.local/bin' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    if command -v uv >/dev/null 2>&1; then
        info "uv 已安装: $(uv --version)"
        return
    fi
    step "安装 uv (Python 包管理器)"
    # 下载 uv 安装脚本(带日志/超时/重试)，成功后再本地执行
    local uv_tmp
    uv_tmp=$(mktemp)
    if ! http_get "https://astral.sh/uv/install.sh" "$uv_tmp" "uv 安装脚本"; then
        rm -f "$uv_tmp"
        error "uv 安装脚本下载失败，请检查网络后重试"
        exit 1
    fi
    run_progress "执行 uv 安装脚本" "uv_install_script" bash "$uv_tmp"
    rm -f "$uv_tmp"
    # 国内加速：PyPI 依赖统一走清华镜像
    export UV_DEFAULT_INDEX="$PYPI_MIRROR"
    # 国内加速: uv 下载 Python 3.12 解释器走 GitHub 加速镜像 (直连常超时导致 uv tool install 失败)
    export UV_PYTHON_INSTALL_MIRROR="https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download"
    info "uv 安装完成: $(uv --version)"
}

# ---------- GitHub 加速 clone: 代理前缀失败自动回退直连 ----------
git_clone() {
    local repo="$1" dest="$2"
    if [ -d "$dest/.git" ]; then
        info "仓库已存在: $dest，跳过 clone。"
        return 0
    fi
    if [ -n "$GH_PROXY" ] && git clone --depth 1 "${GH_PROXY}${repo}" "$dest" 2>/dev/null; then
        info "已通过 GitHub 加速镜像 clone 成功: ${GH_PROXY}${repo}"
        return 0
    fi
    info "加速镜像失败，尝试直连 GitHub..."
    git clone --depth 1 "$repo" "$dest"
}

# ---------- 安装 AstrBot (uv/CLI 方式，默认) ----------
install_astrbot_cli() {
    step "安装 AstrBot CLI (uv 方式，从 PyPI 安装，无需 git clone)"
    export PATH="$HOME/.local/bin:$PATH"
    export UV_DEFAULT_INDEX="$PYPI_MIRROR"
    export UV_PYTHON_INSTALL_MIRROR="https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone/releases/download"
    # 先卸载旧安装再装, 保证重复部署不报 already installed; uv tool install 失败会在此被捕获
    run_progress "安装 astrbot CLI (uv tool install)" "astrbot_cli_install" \
        bash -c "uv tool uninstall astrbot 2>/dev/null || true; uv tool install astrbot --python 3.12"

    # 校验 astrbot 命令是否可用 (uv 安装到 ~/.local/bin)
    if ! command -v astrbot >/dev/null 2>&1; then
        error "astrbot 命令安装失败, 请检查 logs/astrbot_cli_install.log (常见原因: Python 3.12 下载超时)"
        return 1
    fi
    info "astrbot 命令可用: $(command -v astrbot)"

    ASTRBOT_DIR="$HOME/astrbot-data"
    if [ ! -f "$ASTRBOT_DIR/data/cmd_config.json" ]; then
        step "初始化 AstrBot 工作目录: $ASTRBOT_DIR"
        mkdir -p "$ASTRBOT_DIR"
        (cd "$ASTRBOT_DIR" && astrbot init) || {
            error "astrbot init 失败, 请手动执行: mkdir -p ~/astrbot-data && cd ~/astrbot-data && astrbot init"
            return 1
        }
    fi
}

# ---------- 安装 AstrBot (git 源码方式，--source) ----------
install_astrbot_source() {
    step "以源码方式安装 AstrBot (git clone 自动走 GitHub 加速镜像)"
    git_clone "$ASTRBOT_REPO" "$HOME/AstrBot" || {
        error "git clone 失败：网络不通或加速站失效。"
        error "解决办法: 1) 更换脚本头部 GH_PROXY 前缀; 2) 或使用默认 CLI 方式"
        return 1
    }
    run_progress "同步 AstrBot 源码依赖 (uv sync)" "astrbot_sync" bash -c "cd '$HOME/AstrBot' && uv sync --index-url '$PYPI_MIRROR'"
    info "AstrBot 源码安装完成。"
}

install_astrbot() {
    export PATH="$HOME/.local/bin:$PATH"
    if [ "$USE_SOURCE" = "1" ]; then
        install_astrbot_source || { error "AstrBot 源码安装失败, 已中止部署"; return 1; }
    else
        install_astrbot_cli || { error "AstrBot CLI 安装失败, 已中止部署"; return 1; }
    fi
    info "AstrBot 安装完成。"
}

# ---------- 启动 AstrBot (screen 后台) ----------
start_astrbot() {
    export PATH="$HOME/.local/bin:$PATH"
    if screen -ls 2>/dev/null | grep -q "astrbot"; then
        return
    fi
    # 显式注入 ~/.local/bin 到 PATH: screen 内 bash -c 非登录 shell 不会加载 .bashrc
    # 输出重定向到 astrbot.log: 首次启动的初始密码只会打印在启动输出里, 必须落盘才能自动提取
    if [ "$USE_SOURCE" = "1" ]; then
        screen -dmS astrbot bash -c "export PATH=\"$HOME/.local/bin:\$PATH\"; cd '$HOME/AstrBot' && uv run --no-sync main.py >> '$HOME/AstrBot/astrbot.log' 2>&1"
    else
        screen -dmS astrbot bash -c "export PATH=\"$HOME/.local/bin:\$PATH\"; cd '$HOME/astrbot-data' && astrbot run >> '$HOME/astrbot-data/astrbot.log' 2>&1"
    fi
    sleep 3
    if ! screen -ls 2>/dev/null | grep -q "astrbot"; then
        error "AstrBot 启动失败，请手动运行: cd ~/astrbot-data && astrbot run"
    fi
}

# ---------- 启动 NapCat (screen 后台, 与 AstrBot 一致) ----------
start_napcat() {
    local run_dir="" cmd=""
    # 仅支持 AppImage 便携版 (脚本唯一的 NapCat 安装形态)
    if [ -f "$PWD/NapCat.AppImage" ]; then
        run_dir="$PWD"
        # root 下运行 Electron(QQ) 必须 --no-sandbox + 禁用沙箱环境变量
        if ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then
            # 有 FUSE: 直接挂载运行
            cmd="xvfb-run -a bash -c 'ELECTRON_DISABLE_SANDBOX=1 ./NapCat.AppImage --no-sandbox'"
        else
            # 无 FUSE: 用解压运行方式绕过
            cmd="xvfb-run -a bash -c 'ELECTRON_DISABLE_SANDBOX=1 ./NapCat.AppImage --no-sandbox --appimage-extract-and-run'"
        fi
    fi
    if [ -z "$run_dir" ]; then
        warn "未找到 NapCat 安装文件，跳过自动启动，请手动启动。"
        return
    fi
    if screen -ls 2>/dev/null | grep -q "napcat"; then
        return
    fi
    mkdir -p "$LOG_DIR"
    screen -dmS napcat bash -c "cd '$run_dir' && $cmd > '$LOG_DIR/napcat_start.log' 2>&1"
    sleep 4
    if ! screen -ls 2>/dev/null | grep -q "napcat"; then
        error "NapCat 启动失败，完整日志: $LOG_DIR/napcat_start.log"
        tail -n 30 "$LOG_DIR/napcat_start.log" 2>/dev/null | sed 's/^/    /'
        error "手动启动命令: cd '$run_dir' && $cmd"
    fi
}

# ---------- 安装 Electron/QQ 运行依赖 (AppImage 内 QQ 需要系统 GUI 库) ----------
install_qq_deps() {
    step "安装 QQ/Electron 运行依赖 (GTK/ATK/NSS 等系统库)"
    local SUDO=""
    [ "$EUID" -ne 0 ] && SUDO="sudo"
    # 第一套: Ubuntu 22.04 及更早
    $SUDO apt-get install -y \
        libatk1.0-0 libatk-bridge2.0-0 libgtk-3-0 libnss3 libgbm1 \
        libasound2 libxss1 libxtst6 libxrandr2 libxcomposite1 libxdamage1 \
        libxfixes3 libxkbcommon0 libcups2 libpango-1.0-0 libcairo2 \
        >/dev/null 2>&1 || \
    # 第二套: Ubuntu 24.04 (多个包改名 t64)
    $SUDO apt-get install -y \
        libatk1.0-0t64 libatk-bridge2.0-0t64 libgtk-3-0t64 libnss3 libgbm1 \
        libasound2t64 libxss1 libxtst6 libxrandr2 libxcomposite1 libxdamage1 \
        libxfixes3 libxkbcommon0 libcups2t64 libpango-1.0-0t64 libcairo2 \
        >/dev/null 2>&1 || \
        warn "部分 Electron 依赖安装失败，若 NapCat 启动仍报缺库请手动安装"
    info "QQ/Electron 运行依赖安装完成。"
}

# ---------- 安装 NapCat (AppImage 便携版, 默认) ----------
# 自带 QQ + NapCat，全部在当前目录运行，零系统污染、依赖隔离
install_napcat_launcher() {
    step "安装 NapCat (AppImage 便携版，自带 QQ+NapCat，零系统污染)"
    # 先补装 QQ/Electron 运行依赖 (libatk/gtk/nss 等), 否则 AppImage 内 QQ 无法启动
    install_qq_deps
    local arch
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) error "不支持的架构: $(uname -m) (仅支持 amd64/arm64)"; return 1 ;;
    esac
    info "当前架构: ${arch}"

    # 1. 查询最新 release 下载地址 (GitHub API, 走加速镜像)
    local dl_url="" api_tmp api_url
    api_tmp=$(mktemp)
    for api_url in \
        "${GH_PROXY}https://api.github.com/repos/NapNeko/NapCatAppImageBuild/releases/latest" \
        "https://api.github.com/repos/NapNeko/NapCatAppImageBuild/releases/latest"; do
        if http_get "$api_url" "$api_tmp" "查询 NapCat AppImage 最新版本"; then
            dl_url=$(grep -oP '"browser_download_url":\s*"\K[^"]*\.AppImage' "$api_tmp" | grep "$arch" | head -n 1)
            [ -n "$dl_url" ] && break
        fi
    done
    rm -f "$api_tmp"
    if [ -z "$dl_url" ]; then
        warn "获取最新版本失败，回退到已知版本 v4.18.13 直链。"
        dl_url="https://github.com/NapNeko/NapCatAppImageBuild/releases/download/v4.18.13/QQ-50969_NapCat-v4.18.13-${arch}.AppImage"
    fi

    # 2. 下载 AppImage (先走加速镜像, 失败再直连)
    local ok=0 u
    for u in "${GH_PROXY}${dl_url}" "$dl_url"; do
        if http_get "$u" "$PWD/NapCat.AppImage" "NapCat AppImage (体积较大, 请耐心等待)"; then
            ok=1
            break
        fi
        warn "该镜像源不可用，自动尝试下一个..."
    done
    if [ "$ok" = "0" ]; then
        error "NapCat AppImage 下载失败，请检查网络后重试"
        return 1
    fi

    # 3. 基本完整性校验 (文件类型/大小, 防止代理返回错误页面)
    if [ ! -s "$PWD/NapCat.AppImage" ]; then
        error "NapCat.AppImage 为空文件, 下载可能失败"
        return 1
    fi
    if command -v file >/dev/null 2>&1; then
        local ftype
        ftype=$(file -b "$PWD/NapCat.AppImage")
        if ! echo "$ftype" | grep -qi 'appimage\|ELF'; then
            error "NapCat.AppImage 文件类型异常: $ftype (可能是加速站返回的错误页面)"
            return 1
        fi
        info "AppImage 文件类型校验通过: $ftype"
    else
        local fsize
        fsize=$(stat -c%s "$PWD/NapCat.AppImage" 2>/dev/null || echo 0)
        if [ "$fsize" -lt 100000000 ]; then
            warn "NapCat.AppImage 仅 ${fsize} 字节, 可能下载不完整, 仍尝试使用"
        fi
    fi

    # 4. 赋予执行权限
    chmod +x "$PWD/NapCat.AppImage"
    info "NapCat AppImage 安装完成: $PWD/NapCat.AppImage"
}

# ---------- 安装 NapCat (官方一键脚本, --napcat-installer) ----------
# 传统 shell 方式，git clone 官方仓库后执行，QQ 安装到 /opt
install_napcat_installer() {
    step "安装 NapCat (官方一键脚本，git clone NapCat-Installer 仓库)"
    local SUDO=""
    [ "$EUID" -ne 0 ] && SUDO="sudo"

    git_clone "https://github.com/NapNeko/NapCat-Installer.git" "$PWD/NapCat-Installer" || {
        error "git clone NapCat-Installer 失败，请检查网络或更换 GH_PROXY 加速前缀"
        return 1
    }

    run_progress "执行 NapCat 安装 (官方一键脚本)" "napcat_install" $SUDO bash "$PWD/NapCat-Installer/script/install.sh" --docker n --cli n --proxy 0
    info "NapCat 安装完成。"
}

install_napcat() {
    if [ "$NAPCAT_LAUNCHER" = "1" ]; then
        install_napcat_launcher
    else
        install_napcat_installer
    fi
}

# ---------- 探测 NapCat 配置目录 ----------
detect_napcat_config_dir() {
    local candidates=(
        "/opt/QQ/resources/app/app_launcher/napcat/config"
        "/opt/QQ/resources/app/napcat/config"
        "$PWD/QQ/resources/app/app_launcher/napcat/config"
        "$PWD/napcat/config"
        "$PWD/config"
        "$HOME/.config/QQ/NapCat/config"
    )
    local d
    for d in "${candidates[@]}"; do
        if [ -d "$d" ]; then
            NAPCAT_CONFIG_DIR="$d"
            return
        fi
    done
    NAPCAT_CONFIG_DIR="/opt/QQ/resources/app/app_launcher/napcat/config"
}

# ---------- 显示访问地址与端口放行提示 (不获取/不显示真实 IP, 以纯文本 IP 代替) ----------
print_public_urls() {
    step "访问地址与端口放行"
    echo "  • AstrBot 管理面板: IP:6185"
    [ "$INSTALL_NAPCAT" = "1" ] && echo "  • NapCat WebUI:      IP:6099"
    echo ""
    warn "已取消自动放行，若为云服务器请手动放行端口 6185、6099 (控制台/安全组)"
}

# ---------- 返回 AstrBot 登录信息(从日志/screen 缓冲提取初始账号密码) ----------
print_astrbot_login() {
    step "AstrBot 登录信息"
    local user="astrbot" pass="" logf dump i alive=0
    # 初始密码只会打印在首次启动日志中, 轮询等待 WebUI 启动输出 (最长 30s)
    for i in $(seq 1 6); do
        screen -ls 2>/dev/null | grep -q "astrbot" && alive=1
        # 1) 从启动日志 / 守护日志提取 (兼容中英文冒号)
        for logf in "$HOME/astrbot-data/astrbot.log" "$HOME/AstrBot/astrbot.log" \
                    "$HOME/astrbot-data/data/logs/"*.log "$HOME/AstrBot/data/logs/"*.log \
                    /var/log/astrbot/astrbot.log; do
            [ -f "$logf" ] || continue
            pass=$(grep -oP '(?:Initial password|初始密码)[:：]\s*\K\S+' "$logf" 2>/dev/null | tail -n 1)
            [ -n "$pass" ] && break
        done
        # 2) 从 screen 缓冲提取 (hardcopy -h 包含滚动历史, 不只看当前屏幕)
        if [ -z "$pass" ] && [ "$alive" = "1" ]; then
            dump="/tmp/astrbot_screen_$$.txt"
            screen -S astrbot -X hardcopy -h "$dump" 2>/dev/null || true
            [ -f "$dump" ] && pass=$(grep -oP '(?:Initial password|初始密码)[:：]\s*\K\S+' "$dump" 2>/dev/null | tail -n 1)
            rm -f "$dump"
        fi
        [ -n "$pass" ] && break
        [ "$alive" = "0" ] && break
        sleep 5
    done
    info "AstrBot 管理面板: IP:6185"
    if [ -n "$pass" ]; then
        info "初始用户名: ${GREEN}${BOLD}${user}${NC}  初始密码: ${GREEN}${BOLD}${pass}${NC}"
        warn "登录后请立即修改密码"
    else
        warn "未能自动提取初始密码, 可执行: cd ~/astrbot-data && astrbot run --reset-password 重新生成并打印到日志"
        warn "或: screen -r astrbot 后在 screen 内按 ↑ 向上翻找启动日志中的密码"
    fi
    echo "  若使用服务器 IP 无法访问面板，请在 data/cmd_config.json 设置 dashboard.host 后重启"
    echo ""
}

# ---------- 读取并返回 NapCat WebUI 登录密钥(token) ----------
print_napcat_token() {
    local webui="$NAPCAT_CONFIG_DIR/webui.json"
    step "NapCat WebUI 登录信息"
    # 若 webui.json 尚未生成且 NapCat 未在运行, 先启动 NapCat 生成配置
    if [ ! -f "$webui" ] && ! screen -ls 2>/dev/null | grep -q "napcat"; then
        warn "NapCat 尚未启动，webui.json 还未生成，先尝试自动启动..."
        start_napcat
    fi
    # 循环等待 webui.json 生成 (最长 60s, 低配服务器首次启动较慢)
    local wait_i
    for wait_i in $(seq 1 12); do
        [ -f "$webui" ] && break
        sleep 5
    done
    if [ -f "$webui" ]; then
        local token
        token=$(grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' "$webui" | head -n 1 | sed 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
        if [ -n "$token" ]; then
            info "NapCat WebUI 地址: IP:6099"
            info "NapCat WebUI 登录密钥(token): ${GREEN}${BOLD}${token}${NC}"
            warn "请妥善保管该 token，不要截图/分享终端"
            echo ""
        else
            warn "未在 $webui 中找到 token，请手动打开该文件查看。"
        fi
    else
        warn "等待 60s 后仍未生成配置文件 $webui"
        warn "NapCat 启动后会自动生成 webui.json，可稍后重试或手动查找"
    fi
}

# ---------- 引导输入机器人 QQ 号并创建 onebot11 配置 ----------
setup_onebot11_config() {
    step "配置 OneBot 11 (NapCat ↔ AstrBot 连接)"
    local SUDO=""
    [ "$EUID" -ne 0 ] && SUDO="sudo"
    echo ""
    echo -e "${BOLD}请输入机器人 QQ 号:${NC}"
    read -rp "> " qq || true
    qq=$(echo "$qq" | tr -d '[:space:]')
    if [ -z "$qq" ]; then
        warn "未输入 QQ 号，跳过 onebot11 配置文件创建。"
        return
    fi
    # 确保配置目录存在
    if [ ! -d "$NAPCAT_CONFIG_DIR" ]; then
        mkdir -p "$NAPCAT_CONFIG_DIR" 2>/dev/null || $SUDO mkdir -p "$NAPCAT_CONFIG_DIR"
    fi
    local conf="$NAPCAT_CONFIG_DIR/onebot11_${qq}.json"
    # 生成 16 位随机 token (反向 WS 鉴权, NapCat 与 AstrBot 两侧必须一致)
    local token
    token=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)
    if [ -f "$conf" ]; then
        info "配置文件已存在: $conf，跳过创建。"
        # 从已有配置中读回 token, 方便用户填写 AstrBot 端
        token=$(grep -oP '"token"[[:space:]]*:[[:space:]]*"\K[^"]+' "$conf" 2>/dev/null | head -n 1)
    else
        if [ -w "$NAPCAT_CONFIG_DIR" ]; then
            cat > "$conf" << EOF
{
  "network": {
    "httpServers": [],
    "httpClients": [],
    "websocketServers": [],
    "websocketClients": [
      {
        "name": "astrbot",
        "enable": true,
        "url": "ws://0.0.0.0:6199/ws",
        "messagePostFormat": "array",
        "reportSelfMessage": false,
        "token": "${token}",
        "debug": false
      }
    ]
  },
  "musicSignUrl": "",
  "enableLocalFile2Url": false,
  "parseMultMsg": false
}
EOF
        else
            $SUDO tee "$conf" >/dev/null << EOF
{
  "network": {
    "httpServers": [],
    "httpClients": [],
    "websocketServers": [],
    "websocketClients": [
      {
        "name": "astrbot",
        "enable": true,
        "url": "ws://0.0.0.0:6199/ws",
        "messagePostFormat": "array",
        "reportSelfMessage": false,
        "token": "${token}",
        "debug": false
      }
    ]
  },
  "musicSignUrl": "",
  "enableLocalFile2Url": false,
  "parseMultMsg": false
}
EOF
        fi
        info "已创建配置文件: $conf"
    fi
    echo ""
    if [ -n "$token" ]; then
        info "反向 WS 连接: ws://0.0.0.0:6199/ws (token 已写入 onebot11_${qq}.json)"
        info "请在 AstrBot [机器人 → OneBot v11] 中填写 反向 WebSocket Token: ${GREEN}${BOLD}${token}${NC}"
        warn "token 仅提示一次, 请妥善保存"
    fi
    info "NapCat WebUI: IP:6099 (登录 token 见上方)"
    info "onebot11_${qq}.json 已就绪，可直接在 WebUI 的 [网络配置] 中查看/修改连接"
    echo ""
}

# ---------- 守护体系: 崩溃自愈 + 每周一 10:00 定时重启 + systemd 自启 + 状态面板 ----------
setup_guardian() {
    step "守护体系部署 (崩溃自愈 / 每周一 10:00 重启 / bot 状态面板)"
    echo ""
    read -rp "是否部署守护体系? [Y/n] (直接回车默认 Y): " g || true
    case "${g:-y}" in
        y|Y|"") ;;
        *) warn "已跳过守护体系部署。"; echo ""; return ;;
    esac
    echo ""
    read -rp "是否创建 4G swap 交换空间? [Y/n] (低内存服务器推荐, 直接回车默认 Y): " sw || true
    local DO_SWAP=1
    case "${sw:-y}" in
        y|Y|"") DO_SWAP=1 ;;
        *) DO_SWAP=0 ;;
    esac
    local SUDO=""
    [ "$EUID" -ne 0 ] && SUDO="sudo"

    # 1. 4G swap (可选)
    if [ "$DO_SWAP" = "1" ]; then
        if [ ! -f /swapfile ]; then
            $SUDO fallocate -l 4G /swapfile 2>/dev/null || $SUDO dd if=/dev/zero of=/swapfile bs=1M count=4096
            $SUDO chmod 600 /swapfile
            $SUDO mkswap /swapfile >/dev/null 2>&1
            $SUDO swapon /swapfile 2>/dev/null || true
            grep -q '^/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null
            info "已创建 4G swap"
        fi
    else
        info "已跳过 swap 创建。"
    fi

    # 2. 内核参数优化
    local sctl="/etc/sysctl.conf" kv
    for kv in "vm.swappiness=10" "vm.vfs_cache_pressure=50" "net.ipv4.tcp_tw_reuse=1" "net.ipv4.tcp_fin_timeout=30" "net.ipv4.ip_local_port_range=1024 65000" "net.core.somaxconn=1024"; do
        grep -q "^${kv%%=*}" "$sctl" 2>/dev/null || echo "$kv" | $SUDO tee -a "$sctl" >/dev/null
    done
    $SUDO sysctl -p >/dev/null 2>&1 || true

    # 3. 守护脚本 (screen 管理 + 崩溃自愈 + 每周一 10:00 重启)
    cat > /root/astrbot-guardian.sh <<'GUARDIAN'
#!/bin/bash
# AstrBot + NapCat 守护脚本 (崩溃自愈 + 每周一 10:00 定时重启)
set -e
LOG_DIR="/var/log/astrbot"
HOME_DIR="/root"
MAX_LOG_SIZE_MB=50
CHECK_INTERVAL=30
RESTART_WEEKDAY=1
RESTART_HOUR=10

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_DIR/guardian.log"; }

get_astrbot_cmd() {
    if [ -f "$HOME_DIR/astrbot-data/data/cmd_config.json" ]; then
        echo "export PATH=\"$HOME_DIR/.local/bin:\$PATH\"; cd '$HOME_DIR/astrbot-data' && astrbot run"
    elif [ -d "$HOME_DIR/AstrBot" ]; then
        echo "export PATH=\"$HOME_DIR/.local/bin:\$PATH\"; cd '$HOME_DIR/AstrBot' && uv run --no-sync main.py"
    fi
}
get_napcat_cmd() {
    if [ -f "$HOME_DIR/NapCat.AppImage" ]; then
        if ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then
            echo "cd '$HOME_DIR' && ELECTRON_DISABLE_SANDBOX=1 xvfb-run -a ./NapCat.AppImage --no-sandbox"
        else
            echo "cd '$HOME_DIR' && ELECTRON_DISABLE_SANDBOX=1 xvfb-run -a ./NapCat.AppImage --no-sandbox --appimage-extract-and-run"
        fi
    fi
}

rotate_log() {
    local f="$1"
    if [ -f "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -gt $((MAX_LOG_SIZE_MB * 1024 * 1024)) ]; then
        mv "$f" "${f}.$(date +%Y%m%d%H%M%S).bak"
        log "日志轮转: $f"
    fi
}

start_window() {
    local name="$1" cmd="$2" lf="$LOG_DIR/$name.log"
    if screen -list | grep -q "$name"; then
        return
    fi
    rotate_log "$lf"
    screen -dmS "$name" bash -l -c "source ~/.bashrc 2>/dev/null; $cmd >> '$lf' 2>&1"
    log "已启动: $name"
}

check_and_restart() {
    local name="$1" pattern="$2" cmd="$3" tf="/tmp/.last_check_$name" now last
    now=$(date +%s)
    last=$(cat "$tf" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt 10 ]; then return; fi
    echo "$now" > "$tf"
    if pgrep -f "$pattern" >/dev/null 2>&1; then return; fi
    log "检测到 $name 崩溃, 正在重启..."
    pkill -f "$pattern" 2>/dev/null || true
    screen -S "$name" -X quit 2>/dev/null || true
    sleep 2
    start_window "$name" "$cmd"
}

restart_all() {
    log "定时重启: AstrBot + NapCat (每周一 10:00)"
    pkill -f "astrbot run|uv run --no-sync main.py" 2>/dev/null || true
    pkill -f "NapCat.AppImage|qq --no-sandbox" 2>/dev/null || true
    screen -S astrbot -X quit 2>/dev/null || true
    screen -S napcat -X quit 2>/dev/null || true
    sleep 3
    start_window "astrbot" "$ASTRBOT_CMD"
    start_window "napcat" "$NAPCAT_CMD"
    log "定时重启完成"
}

main() {
    mkdir -p "$LOG_DIR"
    ASTRBOT_CMD=$(get_astrbot_cmd)
    NAPCAT_CMD=$(get_napcat_cmd)
    log "=========================================="
    log "守护脚本启动 (崩溃自愈 + 每周一 10:00 定时重启)"
    [ -n "$ASTRBOT_CMD" ] && start_window "astrbot" "$ASTRBOT_CMD" || log "未检测到 AstrBot 安装"
    [ -n "$NAPCAT_CMD" ] && start_window "napcat" "$NAPCAT_CMD" || log "未检测到 NapCat 安装"
    while true; do
        # 每周一 10:00-10:30 定时重启 (北京时间)
        if [ "$(TZ=Asia/Shanghai date +%u)" = "$RESTART_WEEKDAY" ] && [ "$(TZ=Asia/Shanghai date +%H)" = "$RESTART_HOUR" ] && [ "$(TZ=Asia/Shanghai date +%M)" -lt 30 ]; then
            week=$(TZ=Asia/Shanghai date +%G-W%V)
            if [ "$(cat /tmp/.last_restart_week 2>/dev/null)" != "$week" ]; then
                restart_all
                echo "$week" > /tmp/.last_restart_week
            fi
        fi
        [ -n "$ASTRBOT_CMD" ] && check_and_restart "astrbot" "astrbot run|uv run --no-sync main.py" "$ASTRBOT_CMD"
        [ -n "$NAPCAT_CMD" ] && check_and_restart "napcat" "NapCat.AppImage|qq --no-sandbox" "$NAPCAT_CMD"
        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
GUARDIAN
    chmod +x /root/astrbot-guardian.sh

    # 4. systemd 服务 (开机自启 + 崩溃拉起)
    cat > /etc/systemd/system/astrbot-guardian.service <<'SVC'
[Unit]
Description=AstrBot Guardian Service
After=network.target

[Service]
Type=simple
ExecStart=/root/astrbot-guardian.sh
Restart=always
RestartSec=10
User=root
WorkingDirectory=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=TZ=Asia/Shanghai

[Install]
WantedBy=multi-user.target
SVC
    $SUDO systemctl daemon-reload >/dev/null 2>&1
    $SUDO systemctl enable astrbot-guardian.service >/dev/null 2>&1 || warn "守护服务注册失败"
    $SUDO systemctl restart astrbot-guardian.service >/dev/null 2>&1 || warn "守护服务启动失败, 请执行: systemctl status astrbot-guardian"

    # 5. 状态面板
    cat > /root/bot-status.sh <<'PANEL'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
clear
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  AstrBot + NapCat 状态面板${NC}"
echo -e "${BLUE}========================================${NC}"
echo "时间: $(date)"
echo "北京时间: $(TZ='Asia/Shanghai' date)"
echo ""
echo -e "${BLUE}内存与 Swap:${NC}"
free -h
echo ""
echo -e "${BLUE}服务状态:${NC}"
pgrep -af "astrbot run|uv run --no-sync main.py" >/dev/null && echo -e "  ${GREEN}[运行中]${NC} AstrBot" || echo -e "  ${RED}[已停止]${NC} AstrBot"
pgrep -af "NapCat.AppImage|qq --no-sandbox" >/dev/null && echo -e "  ${GREEN}[运行中]${NC} NapCat" || echo -e "  ${RED}[已停止]${NC} NapCat"
echo ""
echo -e "${BLUE}Screen 会话:${NC}"
screen -list | sed 's/^/  /'
echo ""
echo -e "${BLUE}守护进程:${NC}"
systemctl is-active astrbot-guardian.service 2>/dev/null | grep -q active && echo -e "  ${GREEN}[运行中]${NC}" || echo -e "  ${RED}[已停止]${NC}"
echo ""
echo -e "${BLUE}下次定时重启:${NC}"
echo "  每周一 10:00 (北京时间)"
echo ""
echo -e "${BLUE}常用命令:${NC}"
echo "  botlog     -> 实时查看日志"
echo "  botscreen  -> 进入 screen 会话"
echo "  botrestart -> 重启守护服务"
PANEL
    chmod +x /root/bot-status.sh

    # 6. 命令别名
    grep -q "alias bot=" /root/.bashrc 2>/dev/null || cat >> /root/.bashrc <<'ALIAS'

# AstrBot/NapCat 管理命令
alias bot='/root/bot-status.sh'
alias botlog='tail -f /var/log/astrbot/guardian.log'
alias botscreen='screen -r astrbot || screen -r napcat'
alias botrestart='systemctl restart astrbot-guardian.service && echo "服务已重启"'
ALIAS

    info "守护体系部署完成: bot / botlog / botscreen / botrestart (日志: /var/log/astrbot/)"
    echo ""
}

# ---------- 主流程 ----------
main() {
    parse_args "$@"
    pre_check

    show_banner
    show_system_info
    show_intro

    # 交互引导：未传参数时让用户选择
    if [ "$MENU_MODE" = "1" ]; then
        ask_install_mode
    fi

    # 最终确认
    local will_install=""
    [ "$INSTALL_ASTRBOT" = "1" ] && will_install="${will_install} AstrBot"
    [ "$INSTALL_NAPCAT" = "1" ] && will_install="${will_install} NapCat"
    if [ -z "$will_install" ]; then
        error "没有选择任何组件，退出。"
        exit 0
    fi
    echo -e "${BOLD}即将安装:${NC}${GREEN}${will_install}${NC}"
    read -rp "确认开始安装吗？[Y/n] (直接回车默认 Y): " go || true
    case "${go:-y}" in
        y|Y|"") ;;
        *) echo -e "${YELLOW}已取消安装。${NC}"; exit 0 ;;
    esac
    echo ""

    # 防止重复部署：已安装的组件默认跳过
    local DO_ASTRBOT=0 DO_NAPCAT=0
    if [ "$INSTALL_ASTRBOT" = "1" ]; then
        if check_astrbot_installed && confirm_skip_or_reinstall "AstrBot"; then
            warn "已跳过 AstrBot 安装（检测到已部署）。"
        else
            DO_ASTRBOT=1
        fi
    fi
    if [ "$INSTALL_NAPCAT" = "1" ]; then
        if check_napcat_installed && confirm_skip_or_reinstall "NapCat"; then
            warn "已跳过 NapCat 安装（检测到已部署）。"
        else
            DO_NAPCAT=1
        fi
    fi
    if [ "$DO_ASTRBOT" = "0" ] && [ "$DO_NAPCAT" = "0" ]; then
        echo ""
        warn "所有组件均已跳过，无需执行任何操作，再见～"
        exit 0
    fi

    # 开始安装
    if [ "$DO_ASTRBOT" = "1" ] || [ "$DO_NAPCAT" = "1" ]; then
        install_deps
    fi

    if [ "$DO_ASTRBOT" = "1" ]; then
        install_uv || exit 1
        install_astrbot || exit 1
        start_astrbot
    fi

    if [ "$DO_NAPCAT" = "1" ]; then
        install_napcat
        start_napcat
    fi

    # ---------- 收尾: 访问地址 / 登录信息 / NapCat 配置 ----------
    if [ "$INSTALL_ASTRBOT" = "1" ] || [ "$INSTALL_NAPCAT" = "1" ]; then
        detect_napcat_config_dir
        print_public_urls
        if [ "$INSTALL_ASTRBOT" = "1" ]; then
            print_astrbot_login
        fi
        if [ "$INSTALL_NAPCAT" = "1" ]; then
            print_napcat_token
            setup_onebot11_config
        fi
    fi

    # 部署守护体系 (崩溃自愈 / 每周一 10:00 重启 / systemd 自启 / 状态面板)
    setup_guardian
}

main "$@"
