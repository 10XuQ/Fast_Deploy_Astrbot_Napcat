#!/usr/bin/env bash
# ============================================================
# AstrBot + NapCat 一键清理(清零)脚本
# 用于完全回滚 deploy.sh 的所有部署痕迹，方便重复测试
#
# 清除内容:
#   - AstrBot CLI (uv tool) / 数据目录 ~/astrbot-data / 源码目录 ~/AstrBot
#   - NapCat 安装脚本 / napcat、QQ 目录 / Linux QQ (dpkg)
#   - uv 运行时环境 (可选项)
#   - 后台 screen 会话
#
# 用法:
#   bash clean_all.sh          # 交互确认后全部清除
#   bash clean_all.sh --force  # 跳过确认直接清除
# ============================================================

set -e

# ---------- 非交互模式 ----------
# 避免 apt 卸载时弹出 needrestart / debconf 等对话框阻塞自动化
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

FORCE=0

# ---------- 颜色输出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[信息]${NC} $1"; }
warn()  { echo -e "${YELLOW}[提示]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; }
step()  { echo -e "${CYAN}──────────────────────────────────────${NC}"; echo -e "${BOLD}${CYAN}▶ $1${NC}"; }

# ---------- 已安装检测 ----------
check_astrbot_installed() {
    [ -x "$HOME/.local/bin/astrbot" ] || [ -f "$HOME/astrbot-data/data/cmd_config.json" ] || [ -d "$HOME/AstrBot/.git" ]
}
check_napcat_installed() {
    [ -f "$PWD/NapCat.AppImage" ] || [ -f "$PWD/napcat.sh" ] || [ -d "$PWD/napcat" ] || [ -d "$PWD/QQ" ] || [ -d "$PWD/NapCat-Installer" ] || [ -f "$PWD/libnapcat_launcher.so" ] || [ -f "$PWD/loadNapCat.cjs" ] || dpkg -l 2>/dev/null | grep -qi napcat || dpkg -l 2>/dev/null | grep -qw qq || dpkg -l 2>/dev/null | grep -qw linuxqq || [ -d /opt/QQ ]
}

# ---------- Banner ----------
show_banner() {
    clear
    echo -e "${RED}"
    cat << "EOF"
  ██████╗██╗     ███████╗ █████╗ ███╗   ██╗
 ██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║
 ██║     ██║     █████╗  ███████║██╔██╗ ██║
 ██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║
 ╚██████╗███████╗███████╗██║  ██║██║ ╚████║
  ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝
EOF
    echo -e "${NC}"
    echo -e "${BOLD}${RED}   AstrBot + NapCat 环境清零工具${NC}"
    echo -e "${RED}   ════════════════════════════════════${NC}"
    echo ""
}

# ---------- 清理 AstrBot ----------
clean_astrbot() {
    step "清理 AstrBot"

    # 1. 停止后台 screen 会话
    if screen -ls 2>/dev/null | grep -q "astrbot"; then
        screen -S astrbot -X quit 2>/dev/null || true
        info "已停止 AstrBot 后台会话 (screen)"
    fi

    # 2. 卸载 astrbot CLI (uv tool)
    if command -v uv >/dev/null 2>&1; then
        if uv tool list 2>/dev/null | grep -q astrbot; then
            uv tool uninstall astrbot
            info "已卸载 AstrBot CLI (uv tool)"
        else
            warn "uv 中未发现 astrbot 工具，跳过。"
        fi
    fi

    # 3. 删除数据/源码目录
    if [ -d "$HOME/astrbot-data" ]; then
        rm -rf "$HOME/astrbot-data"
        info "已删除数据目录: $HOME/astrbot-data"
    fi
    if [ -d "$HOME/AstrBot" ]; then
        rm -rf "$HOME/AstrBot"
        info "已删除源码目录: $HOME/AstrBot"
    fi
}

# ---------- 清理 NapCat ----------
clean_napcat() {
    step "清理 NapCat"

    local SUDO=""
    [ "$EUID" -ne 0 ] && SUDO="sudo"

    # 1. 停止 QQ/NapCat 进程
    if pgrep -f "qq --no-sandbox" >/dev/null 2>&1 || pgrep -f libnapcat >/dev/null 2>&1; then
        pkill -f "qq --no-sandbox" 2>/dev/null || true
        pkill -f libnapcat 2>/dev/null || true
        info "已停止 QQ/NapCat 进程"
    fi

    # 2. 卸载 Linux QQ (deb 包)
    local PKG_FOUND=0
    for pkg in qq linuxqq; do
        if dpkg -l 2>/dev/null | grep -qw "$pkg"; then
            PKG_FOUND=1
            $SUDO apt-get remove -y "$pkg" || warn "卸载 $pkg 失败，可手动执行: sudo dpkg -r $pkg"
            info "已卸载软件包: $pkg"
        fi
    done
    [ "$PKG_FOUND" = "0" ] && warn "未发现已安装的 QQ 软件包，跳过。"

    # 3. 删除 NapCat 相关目录/文件 (AppImage 便携版 / 官方脚本产物)
    for f in "$PWD/NapCat.AppImage" "$PWD/napcat.sh" "$PWD/napcat" "$PWD/QQ" "$PWD/NapCat-Installer" "$PWD/libnapcat_launcher.so" "$PWD/loadNapCat.cjs"; do
        if [ -e "$f" ]; then
            rm -rf "$f"
            info "已删除: $f"
        fi
    done
    if [ -d /opt/QQ ]; then
        $SUDO rm -rf /opt/QQ
        info "已删除: /opt/QQ"
    fi
}

# ---------- 清理 uv (可选) ----------
clean_uv() {
    step "清理 uv 运行时环境"
    local SUDO=""
    [ "$EUID" -ne 0 ] && SUDO="sudo"
    rm -rf "$HOME/.local/share/uv" "$HOME/.cache/uv" "$HOME/.local/state/uv"
    rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"
    info "已清除 uv 及其 Python 解释器、缓存 (路径: ~/.local/share/uv ~/.cache/uv 等)"
}

# ---------- 完成提示 ----------
print_done() {
    echo ""
    step "清零完成！"
    echo "  系统已恢复到初始状态，可以重新运行部署脚本进行测试:"
    echo "  bash deploy.sh"
    echo ""
}

# ---------- 主流程 ----------
main() {
    [ "$1" = "--force" ] && FORCE=1

    show_banner

    # 先展示检测结果
    local HAS_ASTRBOT=0 HAS_NAPCAT=0
    check_astrbot_installed && HAS_ASTRBOT=1
    check_napcat_installed && HAS_NAPCAT=1

    echo -e "${BOLD}检测到当前系统的部署状态：${NC}"
    if [ "$HAS_ASTRBOT" = "1" ]; then echo "  • AstrBot : ${RED}已部署${NC}"; else echo "  • AstrBot : ${GREEN}未部署${NC}"; fi
    if [ "$HAS_NAPCAT" = "1" ]; then echo "  • NapCat  : ${RED}已部署${NC}"; else echo "  • NapCat  : ${GREEN}未部署${NC}"; fi
    echo ""

    if [ "$HAS_ASTRBOT" = "0" ] && [ "$HAS_NAPCAT" = "0" ]; then
        warn "未检测到任何部署痕迹，无需清理。"
        exit 0
    fi

    # 展示将清除的内容
    echo -e "${BOLD}${RED}即将永久清除以下内容（不可恢复）：${NC}"
    [ "$HAS_ASTRBOT" = "1" ] && echo "  - AstrBot CLI / ~/astrbot-data 数据目录 / ~/AstrBot 源码目录"
    [ "$HAS_NAPCAT" = "1" ] && echo "  - NapCat 安装脚本与 napcat/QQ 目录 / Linux QQ 软件包 (/opt/QQ)"
    echo "  - 后台 screen 会话 (astrbot)"
    echo ""

    # 交互确认（--force 跳过）
    if [ "$FORCE" = "1" ]; then
        warn "已指定 --force，跳过确认直接清除。"
    else
        read -rp "确认全部清除? 请输入 yes 继续 (其他输入取消): " ans || true
        if [ "$ans" != "yes" ]; then
            echo -e "${YELLOW}已取消，未做任何更改。${NC}"
            exit 0
        fi
    fi
    echo ""

    [ "$HAS_ASTRBOT" = "1" ] && clean_astrbot
    [ "$HAS_NAPCAT" = "1" ] && clean_napcat

    # uv 环境清理（部署过 AstrBot 时一并清掉）
    if [ "$HAS_ASTRBOT" = "1" ] && command -v uv >/dev/null 2>&1; then
        clean_uv
    fi

    print_done
}

main "$@"
