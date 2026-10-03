#!/usr/bin/env bash
# ============================================================
# AstrBot + NapCat 升级与维护脚本 (Ubuntu 20+ / Debian 11+)
#
# 与 deploy.sh 配套使用：deploy.sh 负责「第一次装好」，
# 本脚本负责「装好之后怎么升级、怎么迁移配置」。
#
# 能做什么：
#   1) 升级 AstrBot 本体 (uv CLI 方式 / git 源码方式)
#   2) 升级 AstrBot WebUI 管理面板 (单独替换 data/dist)
#   3) 升级 NapCat (便携 AppImage / 官方脚本 rootless / 系统 /opt/QQ)
#   4) 更新 QQ：NapCat 是注入进 QQ 目录里的，所以必须先卸载旧 QQ 再装新版；
#      脚本会在卸载前备份 NapCat 配置，装好后自动迁移回来
#      (可以「顺便更新 NapCat」，也可以「保持 NapCat 版本不动」)
#   5) 备份 / 恢复 (AstrBot 数据 + NapCat 配置)
#
# 用法:
#   bash upgrade.sh                # 交互菜单(推荐)
#   bash upgrade.sh --status       # 只查看当前安装状态与版本
#   bash upgrade.sh --astrbot      # 升级 AstrBot
#   bash upgrade.sh --webui        # 只更新 WebUI 管理面板
#   bash upgrade.sh --protocol     # 升级 NapCat
#   bash upgrade.sh --qq           # 更新 QQ (卸载重装，并迁回 NapCat 配置)
#   bash upgrade.sh --backup       # 备份
#   bash upgrade.sh --restore      # 从备份恢复
#   bash upgrade.sh --all          # 依次升级 AstrBot + WebUI + NapCat
#   bash upgrade.sh --yes          # 免交互确认(配合上面任意动作使用)
#   bash upgrade.sh --qq-version 3.2.34_260924   # 指定 QQ 目标版本
#   bash upgrade.sh --help
# ============================================================

set -e

# ---------- 非交互模式 ----------
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# 以「函数库」方式加载 deploy.sh
# ------------------------------------------------------------
# deploy.sh 里已经有下载/校验/安装/探测/启动的全套实现，这里直接复用，
# 避免同一套逻辑维护两份、时间一长两边行为就不一致。
# 需要 deploy.sh 支持 ASTRBOT_DEPLOY_LIB 开关(否则它会直接开始部署)。
# ============================================================
if [ ! -f "$SCRIPT_DIR/deploy.sh" ]; then
    echo "错误: 未找到同目录下的 deploy.sh。upgrade.sh 需要与 deploy.sh 放在同一目录。"
    exit 1
fi
if ! grep -q 'ASTRBOT_DEPLOY_LIB' "$SCRIPT_DIR/deploy.sh" 2>/dev/null; then
    echo "错误: 同目录的 deploy.sh 版本过旧(不支持函数库模式)，请一并更新到配套版本。"
    exit 1
fi
ASTRBOT_DEPLOY_LIB=1
# shellcheck source=deploy.sh
. "$SCRIPT_DIR/deploy.sh"
unset ASTRBOT_DEPLOY_LIB

# ============================================================
# 升级脚本自己的配置
# ============================================================

# 备份根目录：每次备份会生成 $BACKUP_ROOT/<时间戳>/ 子目录
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/astrbot-backup}"

# 动作选择: ""(菜单) | status | astrbot | webui | protocol | qq | backup | restore | all
ACTION=""
ASSUME_YES=0            # --yes: 跳过所有确认
QQ_TARGET_VERSION=""    # --qq-version: 手动指定 QQ 目标版本
QQ_TARGET_URL=""        # --qq-url: 手动指定 QQ 安装包直链

# ---------- QQ 版本来源 ----------
# 注意：NapCat 是注入进 QQ 目录里的，QQ 版本与 NapCat 的兼容性强相关，
# 所以这里默认使用「NapCat 官方当前推荐的版本」，而不是盲目追新。
# 版本号钉在 deploy.sh 的 "QQ (LinuxQQ) 版本配置" 块里 —— 安装与升级共用同一份，
# 不要在这里重复定义，否则会「装的时候用 A 版本、升级时推荐 B 版本」。
QQ_NAPCAT_VERSION="${QQ_PIN_VERSION}"
QQ_NAPCAT_PATHS=("${QQ_DL_BASE}")
# 腾讯官方稳定渠道：优先走 deploy.sh 里的 qq_official_deb()(机器可读的 pcConfig.json)。
# 下面这个是下载页里内嵌 JS 变量的老接口，只作为兜底。
QQ_STABLE_JS_API="https://im.qq.com/rainbow/linuxQQDownload"

# ---------- 探测结果(全局) ----------
AST_MODE="none"          # cli | source | none
AST_DIR=""               # AstrBot 工作目录
AST_DATA_DIR=""          # 数据目录(内含 cmd_config.json / dist / logs)
AST_VERSION=""           # 已安装版本
AST_RUNNING=0

PROTO_KIND="none"        # napcat-appimage | napcat-rootless | napcat-system | none
PROTO_NAME="无"          # 展示用名字
NAPCAT_KIND="none"       # appimage | rootless | system | none
NAPCAT_VERSION=""        # 已安装 NapCat 版本
NAPCAT_RUN_DIR=""        # AppImage 所在目录(也是配置目录的父目录)
NAPCAT_APPIMAGE=""       # AppImage 文件名
NAPCAT_APP_LAUNCHER=""   # .../resources/app/app_launcher (NapCat 注入目录的父目录)
NAPCAT_BIN_DIR=""        # NapCat 程序目录(内含 napcat.mjs)
NAPCAT_CONFIG_DIR=""     # NapCat 配置目录(内含 webui.json / onebot11_*.json)
QQ_ROOT=""               # QQ 安装根目录(.../opt/QQ 或 /opt/QQ)
QQ_INSTALL_BASE=""       # rootless 布局的安装根($HOME/Napcat)
QQ_VERSION=""            # 已安装 QQ 版本

# ---------- 其它工具函数 ----------

# 统一的确认提示。$1=提示语 $2=默认值(y/n)
ask_yes() {
    local prompt="$1" def="${2:-n}" ans=""
    if [ "$ASSUME_YES" = "1" ]; then
        [ "$def" = "y" ] && return 0 || return 1
    fi
    if [ "$def" = "y" ]; then
        read -rp "$prompt [Y/n]: " ans || true
        [[ ! "${ans:-y}" =~ ^[Nn]$ ]]
    else
        read -rp "$prompt [y/N]: " ans || true
        [[ "${ans:-n}" =~ ^[Yy]$ ]]
    fi
}

# 对比版本号：$1 > $2 返回 0（用 sort -V，纯文本版本号也能比）
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# 写版本戳(下次即使拿不到程序内的版本号也能显示)
write_stamp() {
    local f="$HOME/.astrbot-deploy/$1" v="$2"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$v" > "$f"
}

read_stamp() {
    local f="$HOME/.astrbot-deploy/$1"
    [ -f "$f" ] && head -n 1 "$f" || true
}

# 确保 jq 可用(读 JSON 配置时更稳)
ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    info "安装 jq (解析配置文件需要)..."
    $SUDO apt-get install -y -qq jq >/dev/null 2>&1 || warn "jq 安装失败，将退化为文本解析"
}

# 从 JSON 文件里取一个顶层字符串字段：json_get <文件> <键>
json_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null && return 0
    fi
    # 没有 jq 时的文本兜底：必须锚定键名，否则贪婪匹配会取到最后一个字段
    grep -m1 "\"$key\"" "$file" 2>/dev/null \
        | sed -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

# ============================================================
# 探测：当前装了些什么
# ============================================================

# ---------- AstrBot ----------
detect_astrbot() {
    AST_MODE="none"; AST_DIR=""; AST_DATA_DIR=""; AST_VERSION=""; AST_RUNNING=0

    if [ -x "$HOME/.local/bin/astrbot" ] || command -v astrbot >/dev/null 2>&1; then
        AST_MODE="cli"
        AST_DIR="$HOME/astrbot-data"
    elif [ -d "$HOME/AstrBot/.git" ] || [ -f "$HOME/AstrBot/main.py" ]; then
        AST_MODE="source"
        AST_DIR="$HOME/AstrBot"
    else
        # 兜底：按数据目录判断(有些环境用别的方式装的)
        if [ -f "$HOME/astrbot-data/data/cmd_config.json" ]; then
            AST_MODE="cli"; AST_DIR="$HOME/astrbot-data"
        elif [ -f "$HOME/AstrBot/data/cmd_config.json" ]; then
            AST_MODE="source"; AST_DIR="$HOME/AstrBot"
        fi
    fi

    if [ -n "$AST_DIR" ]; then
        AST_DATA_DIR="$AST_DIR/data"
        [ -d "$AST_DATA_DIR" ] || AST_DATA_DIR=""
    fi

    # 版本：优先读 uv 安装的包元数据，其次读进程输出，最后读版本戳
    if [ "$AST_MODE" = "cli" ]; then
        local d
        d="$(ls -d "$HOME"/.local/share/uv/tools/astrbot/lib/python*/site-packages/astrbot-*.dist-info 2>/dev/null | head -n 1)"
        if [ -n "$d" ]; then
            AST_VERSION="$(basename "$d" | sed -E 's/^astrbot-//; s/\.dist-info$//')"
        fi
    elif [ "$AST_MODE" = "source" ]; then
        AST_VERSION="$(git -C "$AST_DIR" describe --tags --always 2>/dev/null || true)"
    fi
    [ -z "$AST_VERSION" ] && AST_VERSION="$(read_stamp astrbot.version)"

    if screen -ls 2>/dev/null | grep -q "\.astrbot"; then AST_RUNNING=1; fi
}

# AstrBot 最新版本：优先 GitHub Release 标签(与 PyPI 版本一致)，失败再用 PyPI JSON
astrbot_latest_version() {
    local api="https://api.github.com/repos/AstrBotDevs/AstrBot/releases/latest"
    local json="" ver=""
    json="$(curl -fsSL --connect-timeout 10 --max-time 60 "$api" 2>/dev/null || true)"
    if [ -z "$json" ]; then
        json="$(curl -fsSL --connect-timeout 10 --max-time 60 "${GH_PROXY}${api}" 2>/dev/null || true)"
    fi
    if [ -n "$json" ]; then
        ver="$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    fi
    ver="${ver#v}"
    if [ -z "$ver" ]; then
        json="$(curl -fsSL --connect-timeout 10 --max-time 60 "https://pypi.org/pypi/astrbot/json" 2>/dev/null || true)"
        if [ -n "$json" ]; then
            if command -v jq >/dev/null 2>&1; then
                ver="$(printf '%s' "$json" | jq -r '.info.version // empty' 2>/dev/null || true)"
            else
                ver="$(printf '%s' "$json" | grep -m1 '"version"' | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
            fi
        fi
    fi
    printf '%s' "$ver"
}

# ---------- NapCat ----------
# 从 napcat.mjs 里抠出版本号。打包产物里的形态是：
#   typeof Oj < "u" && "4.18.28" || "1.0.0-dev"
# 拿不到就返回空(由调用方决定是否提示未知)
napcat_version_from_bundle() {
    local dir="$1"
    local f="$dir/napcat.mjs"
    [ -f "$f" ] || return 0
    # 注意最后那个 head -n 1：匹配串里同时含 "4.18.28" 和兜底的 "1.0.0-dev"，
    # 不截断的话会返回两行，版本比较就会出错。
    grep -oE '&& "[0-9]+\.[0-9]+\.[0-9]+" \|\| "1\.0\.0-dev"' "$f" 2>/dev/null \
        | head -n 1 \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n 1 || true
}

# 读取 QQ 已安装版本(rootless 与系统布局通用)：qq_version_at <QQ 根目录>
qq_version_at() {
    local root="$1" pkg="$1/resources/app/package.json"
    [ -f "$pkg" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '.version // empty' "$pkg" 2>/dev/null && return 0
    fi
    grep -m1 '"version"' "$pkg" 2>/dev/null \
        | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

detect_napcat() {
    NAPCAT_KIND="none"; NAPCAT_VERSION=""; NAPCAT_RUN_DIR=""; NAPCAT_APPIMAGE=""
    NAPCAT_APP_LAUNCHER=""; NAPCAT_BIN_DIR=""; NAPCAT_CONFIG_DIR=""
    QQ_ROOT=""; QQ_INSTALL_BASE=""; QQ_VERSION=""

    # 1) 便携 AppImage：QQ 与 NapCat 打包在同一个文件里，没有独立 QQ
    local d img
    d="$(detect_napcat_run_dir 2>/dev/null || echo "")"
    if [ -n "$d" ]; then
        img=""
        [ -f "$d/NapCat.AppImage" ] && img="NapCat.AppImage"
        if [ -z "$img" ]; then
            img="$(cd "$d" 2>/dev/null && ls QQ-*.AppImage 2>/dev/null | head -n 1 || true)"
        fi
        if [ -n "$img" ]; then
            NAPCAT_KIND="appimage"
            NAPCAT_RUN_DIR="$d"
            NAPCAT_APPIMAGE="$img"
            NAPCAT_CONFIG_DIR="$d/napcat/config"
            # 版本号：优先用脚本记的版本戳(升级后会写)，再退回文件名里的版本
            NAPCAT_VERSION="$(read_stamp napcat.version)"
            if [ -z "$NAPCAT_VERSION" ]; then
                NAPCAT_VERSION="$(printf '%s' "$img" | grep -oE 'NapCat-v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | sed 's/^NapCat-v//')"
            fi
        fi
    fi

    # 2) 官方脚本 rootless 布局: $HOME/Napcat/opt/QQ/... (QQ 与 NapCat 分离)
    local rootless="$HOME/Napcat/opt/QQ/resources/app/app_launcher"
    if [ "$NAPCAT_KIND" = "none" ] && [ -d "$rootless/napcat" ]; then
        NAPCAT_KIND="rootless"
        NAPCAT_APP_LAUNCHER="$rootless"
        NAPCAT_BIN_DIR="$rootless/napcat"
        NAPCAT_CONFIG_DIR="$rootless/napcat/config"
        QQ_INSTALL_BASE="$HOME/Napcat"
        QQ_ROOT="$HOME/Napcat/opt/QQ"
    fi

    # 3) 旧版系统布局: /opt/QQ (apt 装的 linuxqq)
    local sysdir="/opt/QQ/resources/app/app_launcher"
    if [ "$NAPCAT_KIND" = "none" ] && [ -d "$sysdir/napcat" ]; then
        NAPCAT_KIND="system"
        NAPCAT_APP_LAUNCHER="$sysdir"
        NAPCAT_BIN_DIR="$sysdir/napcat"
        NAPCAT_CONFIG_DIR="$sysdir/napcat/config"
        QQ_ROOT="/opt/QQ"
    fi

    if [ "$NAPCAT_KIND" != "none" ] && [ "$NAPCAT_KIND" != "appimage" ]; then
        NAPCAT_VERSION="$(napcat_version_from_bundle "$NAPCAT_BIN_DIR")"
        [ -z "$NAPCAT_VERSION" ] && NAPCAT_VERSION="$(read_stamp napcat.version)"
        QQ_VERSION="$(qq_version_at "$QQ_ROOT")"
    fi
}

# NapCat 最新 Release 标签(不带 v)
napcat_latest_version() {
    local api="https://api.github.com/repos/NapNeko/NapCatQQ/releases/latest"
    local json="" ver=""
    json="$(curl -fsSL --connect-timeout 10 --max-time 60 "$api" 2>/dev/null || true)"
    if [ -z "$json" ]; then
        json="$(curl -fsSL --connect-timeout 10 --max-time 60 "${GH_PROXY}${api}" 2>/dev/null || true)"
    fi
    [ -n "$json" ] && ver="$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    printf '%s' "${ver#v}"
}

# NapCat AppImage 最新版本 + 资产名
# 输出: "<版本> <资产文件名>"
napcat_appimage_latest() {
    local api="https://api.github.com/repos/NapNeko/NapCatAppImageBuild/releases/latest"
    local arch re json="" ver="" asset=""
    arch="$(detect_arch_x64)"
    # NapCatAppImageBuild 的资产名在历史上用过 amd64/arm64 和 x64/aarch64 两套写法，
    # 这里两种都认，避免官方换命名后「查得到最新版却匹配不到资产」。
    case "$arch" in
        arm64) re='arm64|aarch64' ;;
        *)     re='amd64|x64' ;;
    esac
    json="$(curl -fsSL --connect-timeout 10 --max-time 60 "$api" 2>/dev/null || true)"
    if [ -z "$json" ]; then
        json="$(curl -fsSL --connect-timeout 10 --max-time 60 "${GH_PROXY}${api}" 2>/dev/null || true)"
    fi
    if [ -n "$json" ]; then
        ver="$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
        ver="${ver#v}"
        asset="$(printf '%s' "$json" \
            | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+\.AppImage"' \
            | sed -E 's/.*"([^"]+)"$/\1/' \
            | grep -E "$re" | head -n 1 || true)"
    fi
    if [ -z "$asset" ]; then
        warn "GitHub API 取不到 NapCat AppImage 资产名(可能被限流)。"
        echo "  请手动到 https://github.com/NapNeko/NapCatAppImageBuild/releases 下载新版 AppImage，" >&2
        echo "  替换掉 $NAPCAT_RUN_DIR/$NAPCAT_APPIMAGE 即可(配置目录不动)。" >&2
        printf '%s ' "$ver"
        return 0
    fi
    printf '%s %s' "$ver" "$(basename "$asset")"
}

# ---------- 总探测 ----------
detect_all() {
    detect_astrbot
    detect_napcat

    if [ "$NAPCAT_KIND" != "none" ]; then
        PROTO_KIND="napcat-$NAPCAT_KIND"; PROTO_NAME="NapCat"
    else
        PROTO_KIND="none"; PROTO_NAME="未检测到"
    fi
}

# ============================================================
# 展示当前状态
# ============================================================
show_status() {
    detect_all
    echo ""
    echo -e "${BOLD}${CYAN}┌─────────────────── 当前安装状态 ───────────────────┐${NC}"

    # AstrBot
    if [ "$AST_MODE" = "none" ]; then
        printf "  %-10s %s\n" "AstrBot" "未安装"
    else
        local mode_txt="uv CLI 方式"
        [ "$AST_MODE" = "source" ] && mode_txt="git 源码方式"
        local run_txt="已停止"
        [ "$AST_RUNNING" = "1" ] && run_txt="运行中(screen: astrbot)"
        printf "  %-10s %s  %s  [%s]\n" "AstrBot" "${AST_VERSION:-未知版本}" "$mode_txt" "$run_txt"
        printf "  %-10s %s\n" "  数据目录" "${AST_DIR:-未知}"
    fi

    # 协议端
    case "$NAPCAT_KIND" in
        appimage)
            printf "  %-10s NapCat v%s (便携 AppImage)\n" "协议端" "${NAPCAT_VERSION:-未知}"
            printf "  %-10s %s/%s\n" "  运行目录" "$NAPCAT_RUN_DIR" "$NAPCAT_APPIMAGE"
            printf "  %-10s %s\n" "  配置目录" "$NAPCAT_CONFIG_DIR"
            ;;
        rootless)
            printf "  %-10s NapCat v%s + QQ %s (官方脚本 rootless)\n" "协议端" "${NAPCAT_VERSION:-未知}" "${QQ_VERSION:-未知}"
            printf "  %-10s %s\n" "  QQ 根目录" "$QQ_ROOT"
            printf "  %-10s %s\n" "  配置目录" "$NAPCAT_CONFIG_DIR"
            ;;
        system)
            printf "  %-10s NapCat v%s + QQ %s (系统 /opt/QQ)\n" "协议端" "${NAPCAT_VERSION:-未知}" "${QQ_VERSION:-未知}"
            printf "  %-10s %s\n" "  配置目录" "$NAPCAT_CONFIG_DIR"
            ;;
    esac
    if [ "$NAPCAT_KIND" = "none" ]; then
        printf "  %-10s %s\n" "协议端" "未安装"
    fi

    # 守护服务
    if [ -f /etc/systemd/system/astrbot-guardian.service ]; then
        local gs
        gs="$(systemctl is-active astrbot-guardian 2>/dev/null || echo unknown)"
        printf "  %-10s %s\n" "守护服务" "astrbot-guardian: $gs"
    fi

    echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# ============================================================
# 守护服务与进程的暂停 / 恢复
# 升级期间必须先把 astrbot-guardian 停掉，否则它会在我们把服务停下来的
# 那几秒里把进程重新拉起来，导致「文件正在被替换」这种诡异问题。
# ============================================================
GUARDIAN_PAUSED=0

pause_guardian() {
    GUARDIAN_PAUSED=0
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet astrbot-guardian 2>/dev/null; then
        $SUDO systemctl stop astrbot-guardian >/dev/null 2>&1 || true
        GUARDIAN_PAUSED=1
        info "已暂停守护服务 astrbot-guardian (避免升级途中被自动拉起)"
    fi
    return 0
}

resume_guardian() {
    [ "$GUARDIAN_PAUSED" = "1" ] || return 0
    $SUDO systemctl start astrbot-guardian >/dev/null 2>&1 || true
    GUARDIAN_PAUSED=0
    info "守护服务 astrbot-guardian 已恢复"
    return 0
}

# ---------- AstrBot 停止 / 重启 ----------
stop_astrbot() {
    if screen -ls 2>/dev/null | grep -q "\.astrbot"; then
        screen -S astrbot -X quit >/dev/null 2>&1 || true
        info "已停止 AstrBot (screen: astrbot)"
    fi
    pkill -f "astrbot run" >/dev/null 2>&1 || true
    pkill -f "uv run --no-sync main.py" >/dev/null 2>&1 || true
    sleep 2
    # 被 pkill 打断的 screen 会话会以 (Dead) 状态残留，而 screen -ls 依然会把它列出来。
    # 不清掉的话，紧接着的 start_astrbot 会误判「已经在跑了」从而直接跳过启动 ——
    # 表现就是「升级完 AstrBot 起不来，日志也不再更新」。所以这里必须 wipe 一次。
    screen -wipe >/dev/null 2>&1 || true
    if screen -ls 2>/dev/null | grep -E '[0-9]+\.astrbot[[:space:]]' | grep -qv 'Dead'; then
        warn "AstrBot 的 screen 会话没能停干净，再清一次"
        screen -S astrbot -X quit >/dev/null 2>&1 || true
        sleep 1
        screen -wipe >/dev/null 2>&1 || true
    fi
    return 0
}

restart_astrbot() {
    export PATH="$HOME/.local/bin:$PATH"
    if [ "$AST_MODE" = "source" ]; then USE_SOURCE=1; else USE_SOURCE=0; fi
    stop_astrbot
    start_astrbot
    return 0
}

# ---------- 协议端停止 ----------
stop_napcat() {
    if screen -ls 2>/dev/null | grep -q "\.napcat"; then
        screen -S napcat -X quit >/dev/null 2>&1 || true
        info "已停止 NapCat (screen: napcat)"
    fi
    pkill -f "NapCat\.AppImage" >/dev/null 2>&1 || true
    pkill -f "QQ-.*\.AppImage" >/dev/null 2>&1 || true
    pkill -f "Napcat/opt/QQ/qq" >/dev/null 2>&1 || true
    # 系统布局：QQ 本体在 /opt/QQ/qq
    pkill -f "/opt/QQ/qq" >/dev/null 2>&1 || true
    sleep 2
    return 0
}

# ============================================================
# 备份
# ============================================================
new_backup_dir() {
    local tag="${1:-manual}"
    local ts d
    ts="$(date +%Y%m%d-%H%M%S)"
    d="$BACKUP_ROOT/${ts}-${tag}"
    mkdir -p "$d"
    printf '%s' "$d"
}

# 备份 NapCat 配置目录：backup_napcat_config <目标目录>
backup_napcat_config() {
    local dst="$1"
    [ -n "$NAPCAT_CONFIG_DIR" ] && [ -d "$NAPCAT_CONFIG_DIR" ] || return 0
    mkdir -p "$dst"
    tar -czf "$dst/napcat_config.tar.gz" -C "$(dirname "$NAPCAT_CONFIG_DIR")" "$(basename "$NAPCAT_CONFIG_DIR")" 2>/dev/null \
        && info "NapCat 配置已备份: $dst/napcat_config.tar.gz" \
        || warn "NapCat 配置备份失败(不影响继续)"
    return 0
}

backup_astrbot_data() {
    local dst="$1"
    [ -n "$AST_DATA_DIR" ] && [ -d "$AST_DATA_DIR" ] || return 0
    mkdir -p "$dst"
    tar -czf "$dst/astrbot_data.tar.gz" \
        --exclude="dist" --exclude="logs" --exclude="__pycache__" \
        -C "$(dirname "$AST_DATA_DIR")" "$(basename "$AST_DATA_DIR")" 2>/dev/null \
        && info "AstrBot 数据已备份: $dst/astrbot_data.tar.gz (不含 dist 面板与日志)" \
        || warn "AstrBot 数据备份失败(不影响继续)"
    return 0
}

# 一键备份所有组件
do_backup() {
    detect_all
    local dst
    dst="$(new_backup_dir backup)"
    step "备份到 $dst"
    backup_astrbot_data "$dst"
    backup_napcat_config "$dst"

    # 记一份清单，恢复时用来自动判断该恢复什么
    {
        echo "# AstrBot 部署备份清单"
        echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "astrbot_mode=$AST_MODE"
        echo "astrbot_dir=$AST_DIR"
        echo "astrbot_data_dir=$AST_DATA_DIR"
        echo "astrbot_version=$AST_VERSION"
        echo "napcat_kind=$NAPCAT_KIND"
        echo "napcat_version=$NAPCAT_VERSION"
        echo "napcat_config_dir=$NAPCAT_CONFIG_DIR"
        echo "qq_root=$QQ_ROOT"
        echo "qq_version=$QQ_VERSION"
    } > "$dst/manifest.txt"
    info "备份完成: $dst"
    echo ""
    ls -lh "$dst" | sed 's/^/    /'
    echo ""
    echo -e "${YELLOW}  提示: 备份只包含配置(不含 NapCat 程序与 QQ 数据)，足够重建对接关系。${NC}"
    echo ""
    return 0
}

# 从备份恢复
do_restore() {
    if [ ! -d "$BACKUP_ROOT" ]; then
        error "备份目录不存在: $BACKUP_ROOT"
        return 1
    fi
    local dirs=()
    while IFS= read -r line; do
        [ -n "$line" ] && dirs+=("$line")
    done < <(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort -r)
    if [ "${#dirs[@]}" -eq 0 ]; then
        error "没有找到任何备份: $BACKUP_ROOT"
        return 1
    fi

    echo "可用备份:"
    local i=1 d
    for d in "${dirs[@]}"; do
        printf "  %2d) %s\n" "$i" "$(basename "${d%/}")"
        i=$((i + 1))
    done
    local pick=""
    read -rp "请选择要恢复的备份编号 [1]: " pick || true
    pick="${pick:-1}"
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#dirs[@]}" ]; then
        error "编号无效"
        return 1
    fi
    local src="${dirs[$((pick - 1))]%/}"

    detect_all
    step "从 $src 恢复"
    ask_yes "确认恢复?(同名配置会被覆盖)" y || { info "已取消"; return 0; }

    pause_guardian
    if [ -f "$src/astrbot_data.tar.gz" ] && [ -n "$AST_DATA_DIR" ]; then
        stop_astrbot
        tar -xzf "$src/astrbot_data.tar.gz" -C "$(dirname "$AST_DATA_DIR")" \
            && info "AstrBot 数据已恢复" || warn "AstrBot 数据恢复失败"
        restart_astrbot
    fi
    if [ -f "$src/napcat_config.tar.gz" ] && [ -n "$NAPCAT_CONFIG_DIR" ]; then
        stop_napcat
        mkdir -p "$NAPCAT_CONFIG_DIR"
        tar -xzf "$src/napcat_config.tar.gz" -C "$(dirname "$NAPCAT_CONFIG_DIR")" \
            && info "NapCat 配置已恢复" || warn "NapCat 配置恢复失败"
        if [ "$NAPCAT_KIND" = "appimage" ]; then start_napcat; fi
    fi
    resume_guardian
    info "恢复完成，请检查各服务的登录状态。"
    return 0
}

# ============================================================
# 1) 升级 AstrBot
# ============================================================
upgrade_astrbot() {
    detect_astrbot
    if [ "$AST_MODE" = "none" ]; then
        warn "未检测到 AstrBot，请先运行 bash deploy.sh 完成安装。"
        return 0
    fi
    ensure_jq

    local latest=""
    latest="$(astrbot_latest_version)"
    step "升级 AstrBot"
    echo "  安装方式: $([ "$AST_MODE" = source ] && echo 'git 源码' || echo 'uv CLI')"
    echo "  安装目录: $AST_DIR"
    echo "  当前版本: ${AST_VERSION:-未知}"
    echo "  最新版本: ${latest:-未能获取(不影响升级，uv 会装最新版)}"

    if [ -n "$latest" ] && [ -n "$AST_VERSION" ] && ! version_gt "$latest" "$AST_VERSION"; then
        info "当前已是最新版本。"
        ask_yes "仍要重新安装/更新一次吗?" n || return 0
    else
        ask_yes "确认升级 AstrBot?" y || { info "已取消"; return 0; }
    fi

    export PATH="$HOME/.local/bin:$PATH"
    export UV_DEFAULT_INDEX="$PYPI_MIRROR"
    mkdir -p "$LOG_DIR"

    # 升级本体期间必须先让守护服务停手。守护脚本每 30 秒轮询一次，只要发现 astrbot
    # 的 screen 会话不在了，就会拿当时(可能是半成品)的环境把它重新拉起来：
    #   1) 会和 uv 正在替换工具环境的过程抢，装出来的环境可能是坏的；
    #   2) 守护脚本把输出写到自己的 /var/log/astrbot/astrbot.log，
    #      而 deploy.sh 写的是 ~/astrbot-data/astrbot.log ——
    #      于是用户去看后一个文件时会发现「日志根本没更新」，误以为日志丢了。
    # 升级 WebUI 那条路径本来就这么做了，这里补齐，保持一致。
    pause_guardian

    if [ "$AST_MODE" = "source" ]; then
        step "拉取最新源码 (git pull)"
        if ! git -C "$AST_DIR" pull --ff-only; then
            error "git pull 失败(可能有本地改动或冲突)，请手动处理后重试。"
            error "  手动命令: cd $AST_DIR && git pull"
            resume_guardian
            return 1
        fi
        run_progress "同步依赖 (uv sync)" "upgrade_astrbot_sync" \
            bash -c "cd '$AST_DIR' && export PATH=\"\$HOME/.local/bin:\$PATH\"; export UV_DEFAULT_INDEX='$PYPI_MIRROR'; uv sync --index-url '$PYPI_MIRROR'" \
            || { error "uv sync 失败，详见 $LOG_DIR/upgrade_astrbot_sync.log"; resume_guardian; return 1; }
    else
        # 官方文档给出的更新命令
        if ! run_progress "升级 AstrBot (uv tool upgrade)" "upgrade_astrbot" \
            bash -c "export PATH=\"\$HOME/.local/bin:\$PATH\"; export UV_DEFAULT_INDEX='$PYPI_MIRROR'; uv tool upgrade astrbot --python 3.12"; then
            warn "uv tool upgrade 失败，改为强制重新安装..."
            run_progress "重新安装 AstrBot (uv tool install)" "upgrade_astrbot_reinstall" \
                bash -c "export PATH=\"\$HOME/.local/bin:\$PATH\"; export UV_DEFAULT_INDEX='$PYPI_MIRROR'; uv tool install astrbot --python 3.12 --force" \
                || { error "AstrBot 升级失败，详见 $LOG_DIR/upgrade_astrbot*.log"; resume_guardian; return 1; }
        fi
    fi

    detect_astrbot
    write_stamp astrbot.version "$AST_VERSION"
    info "AstrBot 已更新到 ${AST_VERSION:-未知版本}"
    restart_astrbot
    resume_guardian
    info "AstrBot 已重启。"
    return 0
}

# ============================================================
# 2) 升级 AstrBot WebUI 管理面板
# ------------------------------------------------------------
# 面板文件就是数据目录下的 dist/，AstrBot 官方 release 里提供了
# AstrBot-v<版本>-dashboard.zip (解压出来就是 dist/)，
# 所以这里可以直接替换，不必等面板自己提示更新。
# ============================================================
upgrade_webui() {
    detect_astrbot
    if [ -z "$AST_DATA_DIR" ]; then
        warn "未找到 AstrBot 数据目录，无法更新面板。"
        return 0
    fi
    local dist="$AST_DATA_DIR/dist"
    local latest=""
    latest="$(astrbot_latest_version)"
    if [ -z "$latest" ]; then
        error "无法获取 AstrBot 最新版本(网络不通)，请稍后重试。"
        return 1
    fi
    local url="https://github.com/AstrBotDevs/AstrBot/releases/download/v${latest}/AstrBot-v${latest}-dashboard.zip"

    step "更新 AstrBot WebUI 管理面板"
    echo "  面板目录: $dist"
    echo "  目标版本: v${latest}"
    echo ""
    echo -e "${YELLOW}  说明: 面板与 AstrBot 本体版本通常配套。${NC}"
    echo "        uv/PyPI 方式安装时，升级 AstrBot 本体一般也会把面板一起更新；"
    echo "        本项适合「源码方式部署」或「只想单独刷新面板」的情况。"
    echo "        另外也可以不进脚本，直接在 WebUI 里点 ⋮ → Update AstrBot 更新。"
    echo ""
    ask_yes "确认下载并替换面板文件?" y || { info "已取消"; return 0; }

    if ! command -v unzip >/dev/null 2>&1; then
        info "安装 unzip..."
        $SUDO apt-get install -y -qq unzip >/dev/null 2>&1 || { error "unzip 安装失败"; return 1; }
    fi

    local tmp="/tmp/astrbot_webui_$$"
    rm -rf "$tmp"; mkdir -p "$tmp"
    local ok=0
    if curl -fL --connect-timeout 15 --progress-bar -o "$tmp/dashboard.zip" "$url"; then
        ok=1
    else
        warn "直连下载失败，尝试 GitHub 镜像 ${GH_PROXY} 重试..."
        if curl -fL --connect-timeout 15 --progress-bar -o "$tmp/dashboard.zip" "${GH_PROXY}${url}"; then
            ok=1
        fi
    fi
    if [ "$ok" != "1" ]; then
        error "面板下载失败: $url"
        rm -rf "$tmp"
        return 1
    fi

    if ! unzip -q "$tmp/dashboard.zip" -d "$tmp" 2>/dev/null || [ ! -d "$tmp/dist" ]; then
        error "面板压缩包解压失败或结构异常(缺少 dist/)"
        rm -rf "$tmp"
        return 1
    fi

    local bdir=""
    if [ -d "$dist" ]; then
        bdir="$(new_backup_dir webui)"
        tar -czf "$bdir/webui_dist.tar.gz" -C "$AST_DATA_DIR" dist 2>/dev/null \
            && info "旧面板已备份: $bdir/webui_dist.tar.gz" \
            || warn "旧面板备份失败(继续替换)"
    fi

    pause_guardian
    stop_astrbot
    rm -rf "$AST_DATA_DIR/dist"
    mv "$tmp/dist" "$AST_DATA_DIR/dist"
    rm -rf "$tmp"
    resume_guardian
    info "面板已更新到 v${latest}"
    restart_astrbot
    echo -e "${YELLOW}  提示: 如果浏览器里还是旧界面，请按 Ctrl+F5 强制刷新清缓存。${NC}"
    return 0
}

# ============================================================
# 3) 升级 NapCat
# ============================================================

# ---------- NapCat：便携 AppImage ----------
upgrade_napcat_appimage() {
    local latest="" asset="" line=""
    line="$(napcat_appimage_latest)"
    latest="$(printf '%s' "$line" | awk '{print $1}')"
    asset="$(printf '%s' "$line" | awk '{print $2}')"
    if [ -z "$latest" ] || [ -z "$asset" ]; then
        error "无法获取 NapCat AppImage 最新版本(网络不通或 GitHub API 限流)"
        return 1
    fi
    local arch url target
    arch="$(detect_arch_x64)"
    url="https://github.com/NapNeko/NapCatAppImageBuild/releases/download/v${latest}/${asset}"
    target="$NAPCAT_RUN_DIR/$NAPCAT_APPIMAGE"

    step "升级 NapCat 便携版 (AppImage)"
    echo "  当前版本: ${NAPCAT_VERSION:-未知}"
    echo "  最新版本: v${latest}"
    echo "  安装位置: $target"
    echo ""
    echo -e "${YELLOW}  说明: 便携版把 QQ 与 NapCat 打包在同一个 AppImage 里，${NC}"
    echo "        所以「更新 QQ」在这里等于「换一个更新的 AppImage」。"
    echo "        NapCat 配置在 $NAPCAT_CONFIG_DIR，替换 AppImage 不会动它。"
    echo ""
    ask_yes "确认下载并替换 AppImage?" y || { info "已取消"; return 0; }

    local tmp="/tmp/napcat_appimage_$$"
    rm -rf "$tmp"; mkdir -p "$tmp"
    if ! curl -fL --connect-timeout 15 --progress-bar -o "$tmp/$asset" "$url"; then
        warn "直连下载失败，尝试 GitHub 镜像..."
        curl -fL --connect-timeout 15 --progress-bar -o "$tmp/$asset" "${GH_PROXY}${url}" \
            || { error "AppImage 下载失败: $url"; rm -rf "$tmp"; return 1; }
    fi

    # 校验：必须是可执行镜像，且大小合理(正常 190MB 上下)
    local ftype fsize
    ftype="$(file -b "$tmp/$asset" 2>/dev/null || echo unknown)"
    fsize="$(stat -c %s "$tmp/$asset" 2>/dev/null || echo 0)"
    if [ "$fsize" -lt 100000000 ]; then
        error "下载的文件只有 $((fsize / 1024 / 1024))MB，明显不完整，已中止。"
        rm -rf "$tmp"
        return 1
    fi
    if ! printf '%s' "$ftype" | grep -qiE 'appimage|ELF'; then
        warn "文件类型看起来不太对($ftype)，但体积正常，继续。"
    fi

    chmod +x "$tmp/$asset"
    local bdir=""
    bdir="$(new_backup_dir napcat)"
    [ -f "$target" ] && cp -a "$target" "$bdir/$(basename "$target").old" 2>/dev/null || true

    pause_guardian
    stop_napcat
    mkdir -p "$NAPCAT_RUN_DIR"
    # 文件名带版本号的那种(QQ-*.AppImage)换成新资产名，避免文件名里的版本号
    # 与新版本对不上；用固定别名 NapCat.AppImage 的保持原名不变。
    local old_target="$target"
    case "$NAPCAT_APPIMAGE" in
        QQ-*) target="$NAPCAT_RUN_DIR/$asset" ;;
    esac
    mv -f "$tmp/$asset" "$target" || { error "替换 AppImage 失败"; rm -rf "$tmp"; resume_guardian; return 1; }
    chmod +x "$target"
    if [ "$old_target" != "$target" ] && [ -f "$old_target" ]; then
        rm -f "$old_target"
    fi
    rm -rf "$tmp"
    write_stamp napcat.version "$latest"
    info "NapCat 便携版已更新到 v${latest}"
    resume_guardian
    start_napcat
    return 0
}

# ---------- NapCat：注入到 QQ 里的部署(rootless / 系统) ----------
# 重新把 NapCat 程序文件铺一遍，但配置目录原样保留：
# 注意 NapCat.Shell.zip 里自带一个 config/napcat.json，直接覆盖会改掉用户设置，
# 所以这里先把配置目录挪走，铺完再挪回来。
upgrade_napcat_injected() {
    local latest=""
    latest="$(napcat_latest_version)"
    local url=""
    if [ -n "$latest" ]; then
        url="https://github.com/NapNeko/NapCatQQ/releases/download/v${latest}/NapCat.Shell.zip"
    else
        url="https://github.com/NapNeko/NapCatQQ/releases/latest/download/NapCat.Shell.zip"
    fi

    step "升级 NapCat (注入式部署)"
    echo "  安装布局: $NAPCAT_KIND"
    echo "  程序目录: $NAPCAT_BIN_DIR"
    echo "  配置目录: $NAPCAT_CONFIG_DIR"
    echo "  当前版本: ${NAPCAT_VERSION:-未知}"
    echo "  最新版本: ${latest:-最新版(未取到具体版本号)}"
    echo ""
    ask_yes "确认升级 NapCat?(会保留现有配置与登录状态)" y || { info "已取消"; return 0; }

    if ! command -v unzip >/dev/null 2>&1; then
        info "安装 unzip..."
        $SUDO apt-get install -y -qq unzip >/dev/null 2>&1 || { error "unzip 安装失败"; return 1; }
    fi

    local stage="/tmp/napcat_upgrade_$$"
    rm -rf "$stage"; mkdir -p "$stage"
    if ! curl -fL --connect-timeout 15 --progress-bar -o "$stage/NapCat.Shell.zip" "$url"; then
        warn "直连下载失败，尝试 GitHub 镜像..."
        curl -fL --connect-timeout 15 --progress-bar -o "$stage/NapCat.Shell.zip" "${GH_PROXY}${url}" \
            || { error "NapCat 下载失败: $url"; rm -rf "$stage"; return 1; }
    fi
    if ! unzip -q "$stage/NapCat.Shell.zip" -d "$stage/extract" 2>/dev/null || [ ! -f "$stage/extract/napcat.mjs" ]; then
        error "NapCat 压缩包解压失败或结构异常(缺少 napcat.mjs)"
        rm -rf "$stage"
        return 1
    fi

    # 备份配置 + 记下旧版本，出问题可回退
    local bdir=""
    bdir="$(new_backup_dir napcat)"
    backup_napcat_config "$bdir"
    [ -n "$NAPCAT_VERSION" ] && printf '%s\n' "$NAPCAT_VERSION" > "$bdir/napcat.version.old"

    pause_guardian
    stop_napcat

    # 把现有配置挪出来(同时保住 napcat.json 里的自定义项)
    if [ -d "$NAPCAT_BIN_DIR/config" ]; then
        mv "$NAPCAT_BIN_DIR/config" "$stage/config_old"
    fi
    rm -rf "$NAPCAT_BIN_DIR"
    mkdir -p "$NAPCAT_BIN_DIR"
    cp -a "$stage/extract/." "$NAPCAT_BIN_DIR/"
    chmod -R +x "$NAPCAT_BIN_DIR" 2>/dev/null || true
    rm -rf "$NAPCAT_BIN_DIR/config"
    if [ -d "$stage/config_old" ]; then
        cp -a "$stage/config_old" "$NAPCAT_BIN_DIR/config"
        info "已保留原配置目录(webui.json / onebot11_*.json / napcat.json)"
    fi
    rm -rf "$stage"

    inject_napcat_loader
    [ -n "$latest" ] && write_stamp napcat.version "$latest"
    info "NapCat 已更新到 ${latest:-最新版}"
    resume_guardian
    start_napcat
    return 0
}

# 重新写 loadNapCat.js，并让 QQ 的 package.json 指向它
# (QQ 被重装/更新后这两个注入点会丢，必须重新打一遍)
inject_napcat_loader() {
    [ -n "$NAPCAT_APP_LAUNCHER" ] || return 0
    local app_dir pkg
    app_dir="$(dirname "$NAPCAT_APP_LAUNCHER")"
    pkg="$app_dir/package.json"

    mkdir -p "$NAPCAT_APP_LAUNCHER/napcat"
    printf "(async () => {await import('file://%s/napcat/napcat.mjs');})();\n" "$NAPCAT_APP_LAUNCHER" \
        > "$app_dir/loadNapCat.js"

    if [ ! -f "$pkg" ]; then
        warn "未找到 $pkg，无法设置 QQ 启动入口(loadNapCat.js)，请检查 QQ 是否完整。"
        return 0
    fi
    ensure_jq
    if command -v jq >/dev/null 2>&1; then
        if jq '.main = "./loadNapCat.js"' "$pkg" > "$pkg.tmp.$$" 2>/dev/null; then
            mv "$pkg.tmp.$$" "$pkg"
            info "已设置 QQ 启动入口: $pkg -> ./loadNapCat.js"
        else
            rm -f "$pkg.tmp.$$"
            warn "写入 $pkg 失败，请手动把 \"main\" 改为 \"./loadNapCat.js\""
        fi
    else
        warn "缺少 jq，请手动把 $pkg 里的 \"main\" 改为 \"./loadNapCat.js\""
    fi
    return 0
}

# ---------- 升级 NapCat 总入口 ----------
upgrade_protocol() {
    detect_all

    if [ "$NAPCAT_KIND" = "none" ]; then
        warn "未检测到已安装的 NapCat。"
        echo "  如果你还没装过，请先运行: bash deploy.sh"
        return 0
    fi

    case "$NAPCAT_KIND" in
        appimage)        upgrade_napcat_appimage ;;
        rootless|system) upgrade_napcat_injected ;;
    esac
    return 0
}

# ============================================================
# 4) 更新 QQ
# ------------------------------------------------------------
# 用户需求：更新 QQ 要先卸载一遍 QQ；NapCat 可选是否一并更新；
# 而且配置必须迁移回来。
#
# 三种布局的语义不同：
#   appimage → QQ 打包在 AppImage 里，没有独立 QQ，「更新 QQ」= 换 AppImage
#   rootless → QQ 解包在 $HOME/Napcat/opt/QQ，NapCat 注入在 app_launcher/napcat
#   system   → QQ 由 apt 装在 /opt/QQ
# ============================================================

# 把 uname -m 归一化成 deb 包名里的架构段
qq_arch() { detect_arch; }

# 探测一个直链是否真的可下载。
# 坑：腾讯 QQ 的 CDN 对 HEAD 请求返回 403(直链本身是好的)，所以必须先用 Range GET
# 拉 1 个字节来判活，HEAD 只能作为退而求其次的补充手段。
qq_url_alive() {
    local u="$1"
    [ -n "$u" ] || return 1
    if curl -fsSL --connect-timeout 10 --max-time 30 -r 0-0 -o /dev/null "$u" >/dev/null 2>&1; then
        return 0
    fi
    curl -fsIL --connect-timeout 10 --max-time 30 "$u" >/dev/null 2>&1
}

# 尝试各种已知渠道，拼出候选直链
qq_url_candidates() {
    local ver="$1" arch="$2" official="" o_ver="" o_url=""
    # 1) 直接问官方接口 —— 构建号变了也能跟上，最可靠。
    #    但接口只给「当前稳定版」的直链，版本对不上就不能用它，否则会下错版本。
    official="$(qq_official_deb "$arch" 2>/dev/null || true)"
    if [ -n "$official" ]; then
        o_ver="${official%% *}"
        o_url="${official#* }"
        # 接口只给主干版本(3.2.34)，而请求的可能是 3.2.34 或 3.2.34_260924，
        # 所以比主干；主干一致才允许用，否则会下错版本。
        if [ "$(qq_base_version "$ver")" = "$(qq_base_version "$o_ver")" ]; then
            echo "$o_url"
        fi
    fi
    # 2) deploy.sh 里钉住的 NapCat 官方渠道(新版命名 QQ_<ver>_<arch>_01.deb)
    qq_deb_url "$arch" "$ver" "$QQ_DL_BASE"
    # 3) 腾讯 v6 直链
    echo "https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_${ver}_${arch}_01.deb"
    # 4) 第三方镜像
    echo "${QQ_MIRROR}/QQ_${ver}_${arch}_01.deb"
}

# 逐个试探候选直链，返回第一个能下到的
qq_pick_url() {
    local ver="$1" arch="$2" u
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        if qq_url_alive "$u"; then
            printf '%s' "$u"
            return 0
        fi
    done < <(qq_url_candidates "$ver" "$arch")
    return 1
}

# 解析腾讯官方稳定渠道，输出 "<版本> <deb直链>"
qq_stable_release() {
    local arch="$1" out="" json="" blk="" ver="" url=""
    # 首选：官方机器可读配置(pcConfig.json)
    out="$(qq_official_deb "$arch" 2>/dev/null || true)"
    if [ -n "$out" ]; then
        local o_ver="${out%% *}"
        case "$o_ver" in
            "") ;;
            *) printf '%s' "$out"; return 0 ;;
        esac
    fi
    # 兜底：下载页里内嵌的 JS 变量
    json="$(curl -fsSL --connect-timeout 10 --max-time 30 "$QQ_STABLE_JS_API" 2>/dev/null || true)"
    [ -n "$json" ] || return 1
    json="$(printf '%s' "$json" | sed -n 's/.*var params=//p')"
    json="${json%;*}"
    ver="$(printf '%s' "$json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ "$arch" = "arm64" ]; then
        blk="$(printf '%s' "$json" | sed -n 's/.*"armDownloadUrl"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p')"
    else
        blk="$(printf '%s' "$json" | sed -n 's/.*"x64DownloadUrl"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p')"
    fi
    url="$(printf '%s' "$blk" | sed -n 's/.*"deb"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$url" ] || return 1
    printf '%s %s' "$ver" "$url"
}

# 选择 QQ 目标版本：设置 QQ_TARGET_VERSION / QQ_TARGET_URL
choose_qq_target() {
    local arch rec_ver rec_base rec_name pick="" ver="" url=""
    arch="$(qq_arch)"
    if [ -z "$arch" ]; then
        error "不支持的 CPU 架构: $(uname -m)"
        return 1
    fi

    rec_ver="$QQ_NAPCAT_VERSION"; rec_base="$QQ_DL_BASE"; rec_name="NapCat"

    # 命令行直接指定优先
    if [ -n "$QQ_TARGET_URL" ]; then
        echo "  使用命令行指定的安装包: $QQ_TARGET_URL"
        QQ_TARGET_VERSION="${QQ_TARGET_VERSION:-手动指定}"
        return 0
    fi
    if [ -n "$QQ_TARGET_VERSION" ]; then
        echo "  使用命令行指定的版本: $QQ_TARGET_VERSION"
        if [ "$QQ_TARGET_VERSION" = "$rec_ver" ]; then
            QQ_TARGET_URL="$(qq_deb_url "$arch" "$rec_ver" "$rec_base")"
        fi
        return 0
    fi

    echo "  当前 QQ 版本: ${QQ_VERSION:-未知}"
    echo ""
    echo "  1) ${rec_name} 官方推荐版本: ${rec_ver}  (最稳妥, 默认)"
    echo "  2) 查询腾讯官方稳定渠道版本"
    echo "  3) 手动输入版本号"
    echo "  4) 手动输入 deb 安装包直链"
    echo ""
    read -rp "  请选择 [1]: " pick || true
    pick="${pick:-1}"
    case "$pick" in
        2)
            local line=""
            line="$(qq_stable_release "$arch" || true)"
            ver="$(printf '%s' "$line" | awk '{print $1}')"
            url="$(printf '%s' "$line" | awk '{print $2}')"
            if [ -z "$url" ]; then
                warn "没能从腾讯官方渠道解析出版本与直链，回退到推荐版本。"
                QQ_TARGET_VERSION="$rec_ver"; QQ_TARGET_URL=""
                qq_resolve_target_url "$arch" "$rec_ver" "$rec_base" || return 1
                return 0
            fi
            echo "  官方稳定渠道: ${ver}"
            echo "  下载地址:     ${url}"
            if [ -n "$QQ_VERSION" ] && ! version_gt "$ver" "$QQ_VERSION"; then
                warn "注意: 官方稳定渠道的版本(${ver})并不比当前版本(${QQ_VERSION})新。"
                warn "      NapCat 一般用的是更新更快的渠道，若只是想升级，建议选 1。"
                ask_yes "仍然使用这个版本吗?" n || return 1
            fi
            QQ_TARGET_VERSION="$ver"
            QQ_TARGET_URL="$url"
            ;;
        3)
            read -rp "  请输入 QQ 版本号(形如 3.2.30-50828 或 3.2.32_260812): " ver || true
            ver="$(printf '%s' "$ver" | tr -d '[:space:]')"
            if [ -z "$ver" ]; then error "版本号不能为空"; return 1; fi
            echo "  正在为版本 ${ver} 查找可用的下载地址..."
            if ! qq_resolve_target_url "$arch" "$ver" "$rec_base"; then
                error "没找到版本 ${ver} 的可用安装包，请确认版本号，或改用选项 4 直接给直链。"
                return 1
            fi
            QQ_TARGET_VERSION="$ver"
            ;;
        4)
            read -rp "  请粘贴 deb 安装包直链: " url || true
            url="$(printf '%s' "$url" | tr -d '[:space:]')"
            if [ -z "$url" ]; then error "直链不能为空"; return 1; fi
            QQ_TARGET_VERSION="手动指定"
            QQ_TARGET_URL="$url"
            ;;
        *)
            QQ_TARGET_VERSION="$rec_ver"
            if ! qq_resolve_target_url "$arch" "$rec_ver" "$rec_base"; then
                error "没能找到推荐版本 ${rec_ver} 的安装包，请稍后重试或手动指定。"
                return 1
            fi
            ;;
    esac
    return 0
}

# 给定版本号找直链
qq_resolve_target_url() {
    local arch="$1" ver="$2" base="$3" url="" cand=""
    # 先按命名规则拼出直链并探活(官方 CDN 对 HEAD 返回 403，qq_url_alive 用 Range GET)
    for cand in "$(qq_deb_url "$arch" "$ver" "$base")" \
                "$(qq_deb_url "$arch" "$ver" "$QQ_MIRROR")"; do
        [ -n "$cand" ] || continue
        if qq_url_alive "$cand"; then
            QQ_TARGET_URL="$cand"
            QQ_TARGET_VERSION="$ver"
            return 0
        fi
    done
    # 拼不出来就逐个渠道试
    url="$(qq_pick_url "$ver" "$arch" || true)"
    if [ -n "$url" ]; then
        QQ_TARGET_URL="$url"
        QQ_TARGET_VERSION="$ver"
        return 0
    fi
    return 1
}

# 下载并校验 QQ 安装包
qq_download_deb() {
    local url="$1" dst="$2" arch="" u="" ok=0
    arch="$(qq_arch)"
    step "下载 QQ 安装包"
    echo "  $url"
    if curl -fL --connect-timeout 15 --progress-bar -o "$dst" "$url"; then
        ok=1
    fi
    # 腾讯的下载站不能用 GitHub 镜像救，改为依次试其它已知渠道
    if [ "$ok" != "1" ]; then
        warn "下载失败，依次尝试其它已知渠道..."
        while IFS= read -r u; do
            [ -n "$u" ] || continue
            [ "$u" = "$url" ] && continue
            echo "  尝试: $u"
            if curl -fL --connect-timeout 15 --progress-bar -o "$dst" "$u"; then
                ok=1
                break
            fi
        done < <(qq_url_candidates "${QQ_TARGET_VERSION:-}" "$arch")
    fi
    if [ "$ok" != "1" ]; then
        error "下载失败: $url"
        return 1
    fi
    local ftype fsize
    fsize="$(stat -c %s "$dst" 2>/dev/null || echo 0)"
    ftype="$(file -b "$dst" 2>/dev/null || echo unknown)"
    if [ "$fsize" -lt 50000000 ]; then
        error "安装包只有 $((fsize / 1024 / 1024))MB，明显不完整，已中止。"
        return 1
    fi
    if ! printf '%s' "$ftype" | grep -qiE 'debian|archive'; then
        warn "文件类型是 $ftype，可能不是 deb 包，继续尝试解包。"
    fi
    if ! dpkg-deb --info "$dst" >/dev/null 2>&1; then
        error "这不是一个有效的 deb 安装包，已中止。"
        return 1
    fi
    info "安装包校验通过 ($((fsize / 1024 / 1024))MB)"
    return 0
}

# 更新 QQ 之后的登录状态记录(QQ 自己用它判断版本)
update_qq_version_record() {
    local ver="$1" build_id f
    f="$HOME/.config/QQ/versions/config.json"
    [ -f "$f" ] || return 0
    build_id="${ver##*-}"
    ensure_jq
    if command -v jq >/dev/null 2>&1; then
        cp -a "$f" "$f.bak.astrbot" 2>/dev/null || true
        if jq --arg v "$ver" --arg b "$build_id" \
            '.baseVersion = $v | .curVersion = $v | .buildId = $b' "$f" > "$f.tmp.$$" 2>/dev/null; then
            mv "$f.tmp.$$" "$f"
            info "已同步 QQ 版本记录 ($ver)"
        else
            rm -f "$f.tmp.$$"
        fi
    fi
    return 0
}

# ---------- 便携版：QQ 打包在 AppImage 里 ----------
qq_update_appimage() {
    echo ""
    echo -e "${YELLOW}  便携版(AppImage)把 QQ 与 NapCat 打包在一起，${NC}"
    echo "  机器上没有独立安装的 QQ，所以「更新 QQ」实际就是换一个更新的 AppImage。"
    echo ""
    upgrade_napcat_appimage
}

# ---------- rootless / 系统布局：真正意义上的卸载重装 ----------
qq_update_injected() {
    local arch="" deb="" stage="" bdir="" also_napcat=0
    if [ "$NAPCAT_KIND" = "rootless" ]; then
        echo ""
        echo "  当前布局: QQ 解包在 $QQ_INSTALL_BASE/opt/QQ (NapCat 由官方脚本注入)"
    else
        echo ""
        echo "  当前布局: QQ 由系统包装在 /opt/QQ (NapCat 注入在 app_launcher/napcat)"
    fi

    choose_qq_target || return 1
    arch="$(qq_arch)"
    if [ -z "$QQ_TARGET_URL" ]; then
        if ! qq_resolve_target_url "$arch" "$QQ_TARGET_VERSION" "$QQ_DL_BASE"; then
            error "没能解析出 $QQ_TARGET_VERSION 的下载地址"
            return 1
        fi
    fi

    echo ""
    echo -e "${BOLD}  升级计划${NC}"
    echo "    QQ 版本:   ${QQ_VERSION:-未知}  →  ${QQ_TARGET_VERSION}"
    echo "    QQ 布局:   $NAPCAT_KIND"
    echo "    NapCat 配置目录: $NAPCAT_CONFIG_DIR (会被完整备份并迁回)"
    echo ""
    echo -e "${YELLOW}  流程: 备份配置 → 停止服务 → 卸载旧 QQ → 安装新 QQ → 迁回配置 → 重启${NC}"
    echo ""
    ask_yes "确认开始更新 QQ?" y || { info "已取消"; return 0; }

    # ---- 是否顺便升级 NapCat ----
    if [ "$NAPCAT_KIND" != "none" ]; then
        echo ""
        echo "  更新 QQ 时 NapCat 一定会被重新铺一遍(它就装在 QQ 目录里)。"
        echo "  所以这里可以顺便把它换成最新版："
        echo "    - 选 y: 顺便把 NapCat 也升级到最新版(推荐，配置照旧保留)"
        echo "    - 选 n: 保持当前 NapCat 版本不变(${NAPCAT_VERSION:-未知})"
        if ask_yes "  是否顺便升级 NapCat?" y; then
            also_napcat=1
        fi
    fi

    stage="/tmp/qq_upgrade_$$"
    rm -rf "$stage"; mkdir -p "$stage"

    # ---- 下载新 QQ ----
    deb="$stage/linuxqq_new.deb"
    qq_download_deb "$QQ_TARGET_URL" "$deb" || { rm -rf "$stage"; return 1; }

    # ---- 备份 ----
    bdir="$(new_backup_dir qq)"
    backup_napcat_config "$bdir"
    if [ -n "$NAPCAT_BIN_DIR" ] && [ -d "$NAPCAT_BIN_DIR" ]; then
        cp -a "$NAPCAT_BIN_DIR" "$stage/napcat_old" 2>/dev/null \
            && info "NapCat 程序目录已暂存(含配置)" \
            || warn "NapCat 程序目录暂存失败"
    fi
    [ -n "$QQ_VERSION" ] && printf '%s\n' "$QQ_VERSION" > "$bdir/qq.version.old"

    if [ "$also_napcat" = "1" ]; then
        local nurl="$stage/NapCat.Shell.zip"
        step "下载最新版 NapCat"
        if ! curl -fL --connect-timeout 15 --progress-bar -o "$nurl" \
            "https://github.com/NapNeko/NapCatQQ/releases/latest/download/NapCat.Shell.zip"; then
            warn "直连下载 NapCat 失败，尝试镜像..."
            curl -fL --connect-timeout 15 --progress-bar -o "$nurl" \
                "${GH_PROXY}https://github.com/NapNeko/NapCatQQ/releases/latest/download/NapCat.Shell.zip" \
                || { error "NapCat 下载失败，已中止(未做任何破坏性操作)"; rm -rf "$stage"; return 1; }
        fi
        if ! unzip -q "$nurl" -d "$stage/napcat_new" 2>/dev/null || [ ! -f "$stage/napcat_new/napcat.mjs" ]; then
            error "NapCat 压缩包异常，已中止(未做任何破坏性操作)"
            rm -rf "$stage"
            return 1
        fi
    fi

    # ---- 停止服务 ----
    pause_guardian
    stop_napcat

    # ---- 卸载旧 QQ ----
    step "卸载旧 QQ"
    if [ "$NAPCAT_KIND" = "rootless" ]; then
        # rootless 布局：整个 $HOME/Napcat 就是这份 QQ，直接删掉
        rm -rf "$QQ_INSTALL_BASE"
        info "已删除 $QQ_INSTALL_BASE"
    else
        # 系统布局：交给包管理器卸载，再清残留
        if dpkg -l 2>/dev/null | grep -qi '^ii[[:space:]]*linuxqq'; then
            $SUDO apt-get remove -y -qq linuxqq >/dev/null 2>&1 || warn "apt 卸载 linuxqq 失败，继续清理目录"
        fi
        rm -rf /opt/QQ
        info "已卸载系统 QQ 并清理 /opt/QQ"
    fi

    # ---- 安装新 QQ ----
    step "安装 QQ ${QQ_TARGET_VERSION}"
    if [ "$NAPCAT_KIND" = "rootless" ]; then
        # 与官方脚本一致：只解包，不注册到系统(dpkg -x 不执行 maintainer script)
        mkdir -p "$QQ_INSTALL_BASE"
        if ! dpkg -x "$deb" "$QQ_INSTALL_BASE"; then
            error "解包新 QQ 失败，正在回滚..."
            if [ -d "$stage/napcat_old" ] && [ -d "$NAPCAT_APP_LAUNCHER" ]; then
                rm -rf "$NAPCAT_BIN_DIR"
                cp -a "$stage/napcat_old" "$NAPCAT_BIN_DIR" 2>/dev/null || true
            fi
            rm -rf "$stage"
            return 1
        fi
        if [ ! -x "$QQ_INSTALL_BASE/opt/QQ/qq" ]; then
            warn "没找到 $QQ_INSTALL_BASE/opt/QQ/qq，请检查安装包内容。"
        else
            info "QQ 已解包到 $QQ_INSTALL_BASE/opt/QQ"
        fi
    else
        if ! $SUDO apt-get install -y -qq "$deb"; then
            error "安装新 QQ 失败，请手动执行: sudo apt install -y '$QQ_TARGET_URL' 对应的 deb"
            rm -rf "$stage"
            return 1
        fi
        info "QQ 已安装到 /opt/QQ"
    fi
    update_qq_version_record "$QQ_TARGET_VERSION"

    # ---- 恢复 / 更新 NapCat ----
    step "恢复 NapCat"
    mkdir -p "$NAPCAT_APP_LAUNCHER"
    if [ "$also_napcat" = "1" ]; then
        rm -rf "$NAPCAT_BIN_DIR"
        mkdir -p "$NAPCAT_BIN_DIR"
        cp -a "$stage/napcat_new/." "$NAPCAT_BIN_DIR/"
        chmod -R +x "$NAPCAT_BIN_DIR" 2>/dev/null || true
        rm -rf "$NAPCAT_BIN_DIR/config"
        if [ -d "$stage/napcat_old/config" ]; then
            cp -a "$stage/napcat_old/config" "$NAPCAT_BIN_DIR/config"
            info "已把原 NapCat 配置迁移到新版 (含 webui.json / onebot11_*.json)"
        fi
        local bin_ver
        bin_ver="$(napcat_version_from_bundle "$NAPCAT_BIN_DIR")"
        # 抽不到就保留旧版本戳，别用空值覆盖掉已有记录
        if [ -n "$bin_ver" ]; then
            write_stamp napcat.version "$bin_ver"
        else
            write_stamp napcat.version "${NAPCAT_VERSION:-未知}"
        fi
    else
        rm -rf "$NAPCAT_BIN_DIR"
        if [ -d "$stage/napcat_old" ]; then
            cp -a "$stage/napcat_old" "$NAPCAT_BIN_DIR"
            info "已恢复原 NapCat 程序与配置 (版本保持 ${NAPCAT_VERSION:-未知})"
        else
            warn "没有暂存到原 NapCat 目录，请重新运行 bash deploy.sh 安装协议端。"
        fi
    fi
    inject_napcat_loader
    rm -rf "$stage"

    resume_guardian
    start_napcat
    info "QQ 更新完成。"
    echo ""
    echo -e "${YELLOW}  提示: QQ 登录态保存在 $HOME/.config/QQ，正常情况下不需要重新扫码；${NC}"
    echo "        如果提示要重新登录，请用 VNC 或直接看 NapCat WebUI 处理。"
    echo ""
    return 0
}

# ---------- 更新 QQ 总入口 ----------
# NapCat 装在 QQ 目录内部，跟随 QQ 走。「更新 QQ」= 卸旧装新 + 迁回配置，
# 可以顺便把 NapCat 也升到最新版。
update_qq() {
    detect_all

    case "$NAPCAT_KIND" in
        appimage) qq_update_appimage; return $? ;;
        rootless|system) qq_update_injected; return $? ;;
    esac

    # 没有 NapCat，但系统里装了独立 QQ —— 无法判断该按哪套布局处理，
    # 直接引导用户走协议端安装。
    if [ -x /opt/QQ/qq ]; then
        warn "检测到系统 QQ，但没有检测到 NapCat。"
        echo "  请先运行 bash deploy.sh 安装 NapCat(会按 NapCat 自动对齐 QQ 版本)。"
        return 0
    fi

    error "未检测到 QQ / NapCat，无法更新。"
    return 0
}

# ============================================================
# 5) 重启服务
# ============================================================
restart_services() {
    detect_all
    pause_guardian
    if [ "$AST_MODE" != "none" ]; then
        restart_astrbot
        info "AstrBot 已重启"
    fi
    case "$NAPCAT_KIND" in
        appimage|rootless|system)
            stop_napcat
            start_napcat
            info "NapCat 已重启"
            ;;
    esac
    resume_guardian
    return 0
}

# ============================================================
# 菜单与入口
# ============================================================
show_upgrade_header() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}   AstrBot 部署维护工具 · 升级 / 备份 / 维护${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "   deploy.sh: 首次安装      upgrade.sh: 日常维护(本脚本)"
    echo ""
}

# 菜单里显示一行摘要
menu_summary() {
    local a="" p=""
    if [ "$AST_MODE" = "none" ]; then
        a="AstrBot 未安装"
    else
        a="AstrBot ${AST_VERSION:-未知}"
        [ "$AST_RUNNING" = "1" ] && a="$a (运行中)"
    fi
    case "$NAPCAT_KIND" in
        none) p="NapCat 未安装" ;;
        appimage) p="NapCat v${NAPCAT_VERSION:-未知} (便携版)" ;;
        rootless) p="NapCat v${NAPCAT_VERSION:-未知} + QQ ${QQ_VERSION:-未知}" ;;
        system) p="NapCat v${NAPCAT_VERSION:-未知} + QQ ${QQ_VERSION:-未知} (系统)" ;;
    esac
    printf '   当前: %s | %s\n' "$a" "$p"
}

interactive_menu() {
    while true; do
        detect_all
        show_upgrade_header
        menu_summary
        echo "  ----------------------------------------------------------"
        echo "   1) 升级 AstrBot            更新本体 (uv CLI / git 源码)"
        echo "   2) 更新 WebUI 管理面板     单独刷新 data/dist 面板文件"
        echo "   3) 升级 NapCat             便携 AppImage / rootless / 系统"
        echo "   4) 更新 QQ                 卸载重装 QQ，并自动迁回 NapCat 配置"
        echo "   5) 备份配置"
        echo "   6) 从备份恢复"
        echo "   7) 查看当前状态"
        echo "   8) 重启服务                AstrBot / NapCat"
        echo "   0) 退出"
        echo ""
        local pick=""
        read -rp "  请选择 [0-8]: " pick || true
        echo ""
        case "${pick:-}" in
            1) upgrade_astrbot ;;
            2) upgrade_webui ;;
            3) upgrade_protocol ;;
            4) update_qq ;;
            5) do_backup ;;
            6) do_restore ;;
            7) show_status ;;
            8) restart_services ;;
            0|"") info "已退出"; return 0 ;;
            *) warn "无效选项: $pick" ;;
        esac
        echo ""
        read -rp "  按回车继续..." _ || true
    done
}

show_usage() {
    sed -n '3,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

parse_upgrade_args() {
    MENU_MODE=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --status)          ACTION=status ;;
            --astrbot)         ACTION=astrbot ;;
            --webui)           ACTION=webui ;;
            --protocol)        ACTION=protocol ;;
            --qq|--update-qq)  ACTION=qq ;;
            --backup)          ACTION=backup ;;
            --restore)         ACTION=restore ;;
            --restart)         ACTION=restart ;;
            --all)             ACTION=all ;;
            --yes|-y)          ASSUME_YES=1 ;;
            --qq-version)      shift; QQ_TARGET_VERSION="${1:-}" ;;
            --qq-url)          shift; QQ_TARGET_URL="${1:-}" ;;
            -h|--help)         show_usage; exit 0 ;;
            *)
                error "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
    if [ -z "$ACTION" ]; then
        MENU_MODE=1
    fi
    return 0
}

main() {
    parse_upgrade_args "$@"
    mkdir -p "$LOG_DIR"

    if [ "$ACTION" = "status" ]; then
        show_upgrade_header
        show_status
        return 0
    fi

    if [ "$MENU_MODE" = "1" ]; then
        # 抬头由 interactive_menu 每轮自己刷新，这里不要再打一次
        interactive_menu
        return 0
    fi

    show_upgrade_header
    # 需要 root 的操作(安装系统 QQ、写 /opt) —— 提前把风险讲清楚
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            info "当前非 root，需要时会通过 sudo 提权(可能会要求输入密码)。"
        else
            warn "当前不是 root 且系统里没有 sudo，安装系统 QQ 等操作会失败。"
        fi
    fi

    case "$ACTION" in
        astrbot)  upgrade_astrbot ;;
        webui)    upgrade_webui ;;
        protocol) upgrade_protocol ;;
        qq)       update_qq ;;
        backup)   do_backup ;;
        restore)  do_restore ;;
        restart)  restart_services ;;
        all)
            upgrade_astrbot
            upgrade_webui
            upgrade_protocol
            ;;
        *)
            error "未知动作: $ACTION"
            show_usage
            exit 1
            ;;
    esac
    echo ""
    info "全部完成。"
    return 0
}

# 允许被其它脚本 source 复用(设 ASTRBOT_UPGRADE_LIB=1 时只加载函数)
if [ "${ASTRBOT_UPGRADE_LIB:-0}" != "1" ]; then
    main "$@"
fi
