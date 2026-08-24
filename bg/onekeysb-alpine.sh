#!/bin/bash
#
# onekeysb-alpine.sh
# sing-box 一键管理脚本 (Alpine Linux / OpenRC 版)
# 功能: 安装 / 配置更新 / 内核(binary)更新 / 自更新 / 服务管理 / 定时任务
#

set -o pipefail

# ============ 基础配置 ============
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BACKUP_DIR="${CONFIG_DIR}/backup"
SUB_URL_FILE="${CONFIG_DIR}/subscribe_url"
BIN_PATH="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/init.d/sing-box"
CRON_FILE="/etc/periodic/daily/sing-box-update"
SYSCTL_FILE="/etc/sysctl.d/99-sing-box-net.conf"

# 自更新地址：把这个脚本上传到你的仓库后，替换成对应 raw 地址

SELF_UPDATE_URL="https://raw.githubusercontent.com/bgg688/rule/main/bg/onekeysb-alpine.sh"
SCRIPT_PATH="$(readlink -f "$0")"

GITHUB_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

# ============ 颜色输出 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[信息]${NC} $1"; }
success() { echo -e "${GREEN}[成功]${NC} $1"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $1"; }
error()   { echo -e "${RED}[错误]${NC} $1"; }

# ============ 基础检查 ============
check_root() {
    if [ "$(id -u)" != "0" ]; then
        error "请使用 root 用户运行本脚本"
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *) error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

ensure_deps() {
    for pkg in curl wget tar jq; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            info "安装依赖: $pkg"
            apk add --no-cache "$pkg" >/dev/null 2>&1
        fi
    done
}

# ============ 获取最新版本号 ============
get_latest_version() {
    curl -s "$GITHUB_API" | jq -r '.tag_name' | sed 's/^v//'
}

# ============ 安装 / 更新 sing-box 内核 ============
install_kernel() {
    local version="$1"
    detect_arch
    ensure_deps

    if [ -z "$version" ]; then
        info "获取最新版本号..."
        version=$(get_latest_version)
        if [ -z "$version" ] || [ "$version" = "null" ]; then
            error "获取版本号失败，请检查网络"
            return 1
        fi
    fi

    info "准备安装 sing-box v${version} (${ARCH})"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${ARCH}.tar.gz"
    local tmpdir
    tmpdir=$(mktemp -d)

    if ! wget -q -O "${tmpdir}/sing-box.tar.gz" "$url"; then
        error "下载失败: $url"
        rm -rf "$tmpdir"
        return 1
    fi

    tar -xzf "${tmpdir}/sing-box.tar.gz" -C "$tmpdir"

    local bin_src
    bin_src=$(find "$tmpdir" -type f -name "sing-box" | head -n1)
    if [ -z "$bin_src" ]; then
        error "解压后未找到 sing-box 二进制文件"
        rm -rf "$tmpdir"
        return 1
    fi

    # 如果服务在运行，先停止再替换
    local was_running=0
    if rc-service sing-box status >/dev/null 2>&1; then
        was_running=1
        rc-service sing-box stop >/dev/null 2>&1
    fi

    install -m 755 "$bin_src" "$BIN_PATH"
    rm -rf "$tmpdir"

    if "$BIN_PATH" version >/dev/null 2>&1; then
        success "sing-box 已安装/更新到 v${version}"
        "$BIN_PATH" version
    else
        error "二进制安装后无法执行，请检查是否为 musl 兼容版本"
        return 1
    fi

    [ "$was_running" = "1" ] && rc-service sing-box start
}

# ============ tun 设备检测与持久化 ============
# 踩坑记录：如果 config.json 里用了 tun 入站，Alpine 精简安装默认没有
# tun 内核模块 / 设备节点，会导致 sing-box run 时报:
#   open tun: open /dev/net/tun: no such file or directory
# 这里在安装阶段就顺手检测并修好，同时写入 /etc/modules 保证重启后仍生效。
ensure_tun() {
    if ! lsmod | grep -q '^tun'; then
        info "检测到 tun 模块未加载，尝试加载..."
        if ! modprobe tun 2>/dev/null; then
            warn "modprobe tun 失败，尝试安装内核模块包 (linux-lts)..."
            apk add --no-cache linux-lts >/dev/null 2>&1
            modprobe tun 2>/dev/null
        fi
    fi

    if lsmod | grep -q '^tun'; then
        success "tun 模块已加载"
    else
        warn "tun 模块仍未加载，如果你的配置用到 tun 入站会启动失败，请手动检查内核类型 (uname -r) 对应哪个内核包"
    fi

    if [ ! -e /dev/net/tun ]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null
        chmod 600 /dev/net/tun 2>/dev/null
    fi

    # 持久化：开机自动加载 tun 模块（modules 服务在 boot 阶段读取 /etc/modules）
    if [ -f /etc/modules ] && ! grep -qx "tun" /etc/modules; then
        echo "tun" >> /etc/modules
        info "已将 tun 写入 /etc/modules，确保重启后自动加载"
    fi

    # 确保 modules 服务本身在 boot runlevel（正常 Alpine 默认就有，这里做个兜底）
    if ! rc-update show boot 2>/dev/null | grep -q modules; then
        rc-update add modules boot
        info "已将 modules 服务加入 boot 运行级"
    fi
}

# ============ 刷新 OpenRC 依赖缓存 ============
# 踩坑记录：新增/修改 /etc/init.d 下的服务脚本后，如果不刷新 deptree 缓存，
# 开机时 OpenRC 可能仍按旧缓存执行，导致新服务被“无声跳过”——
# 现象是 rc-update show default 里有这条服务、软链接也正常，
# 但 /var/log/rc.log 里开机阶段压根没出现这条服务的启动记录。
# 表现通常是 rc-service status 一直是 stopped 而不是 crashed。
refresh_deptree() {
    rm -f /lib/rc/cache/deptree 2>/dev/null
    rc-update -u >/dev/null 2>&1
    info "已刷新 OpenRC 依赖缓存 (deptree)"
}

# ============ 首次完整安装（内核 + 服务 + 目录） ============
full_install() {
    check_root
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"

    install_kernel "" || { error "内核安装失败，终止"; return 1; }
    ensure_tun

    if [ ! -f "$CONFIG_FILE" ]; then
        warn "未检测到配置文件，将写入一个空的最小配置，稍后请用菜单里的[更新配置]拉取订阅"
        cat > "$CONFIG_FILE" <<'EOF'
{
  "log": { "level": "info" },
  "inbounds": [],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
    fi

    write_openrc_service
    rc-update add sing-box default
    refresh_deptree
    success "安装完成。可用菜单中的 [服务管理] 启动，或先去 [更新配置] 拉取你的订阅"
    warn "建议现在执行一次 reboot，确认重启后 rc-status default 里能看到 sing-box [ started ]"
}

# ============ 写 OpenRC 服务文件 ============
write_openrc_service() {
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box service"
command="${BIN_PATH}"
command_args="run -c ${CONFIG_FILE}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
    need modules
    after firewall
}

start_pre() {
    ${BIN_PATH} check -c ${CONFIG_FILE} || {
        eerror "配置文件校验失败，拒绝启动，请检查 ${CONFIG_FILE}"
        return 1
    }
}
EOF
    chmod +x "$SERVICE_FILE"
    success "OpenRC 服务文件已写入 ${SERVICE_FILE}"
    # 踩坑记录：改动/重写服务脚本后必须刷新依赖缓存，否则开机时可能仍按旧缓存跳过该服务
    refresh_deptree
}

# ============ 更新配置（订阅拉取，含校验和回滚） ============
set_subscribe_url() {
    read -rp "请输入订阅/配置下载地址: " url
    if [ -z "$url" ]; then
        warn "未输入内容，取消"
        return
    fi
    echo "$url" > "$SUB_URL_FILE"
    success "订阅地址已保存"
}

update_config() {
    mkdir -p "$BACKUP_DIR"

    local url
    if [ -f "$SUB_URL_FILE" ]; then
        url=$(cat "$SUB_URL_FILE")
    fi

    if [ -z "$url" ]; then
        warn "尚未设置订阅地址"
        set_subscribe_url
        url=$(cat "$SUB_URL_FILE" 2>/dev/null)
        [ -z "$url" ] && return 1
    fi

    info "从订阅地址下载新配置..."
    local tmpfile
    tmpfile=$(mktemp)

    if ! curl -sSL -o "$tmpfile" "$url"; then
        error "下载失败"
        rm -f "$tmpfile"
        return 1
    fi

    info "校验新配置..."
    if ! "$BIN_PATH" check -c "$tmpfile" >/tmp/singbox_check.log 2>&1; then
        error "配置校验未通过，已放弃本次更新，日志如下:"
        cat /tmp/singbox_check.log
        rm -f "$tmpfile"
        return 1
    fi

    # 备份旧配置
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${BACKUP_DIR}/config.json.$(date +%Y%m%d%H%M%S)"
        # 只保留最近10份备份
        ls -t "${BACKUP_DIR}"/config.json.* 2>/dev/null | tail -n +11 | xargs -r rm -f
    fi

    mv "$tmpfile" "$CONFIG_FILE"
    success "配置已更新"

    if rc-service sing-box status >/dev/null 2>&1; then
        info "重启 sing-box 服务以应用新配置..."
        rc-service sing-box restart && success "服务已重启" || error "服务重启失败，请手动检查"
    else
        info "服务当前未运行，未自动启动（如需启动请到服务管理菜单）"
    fi
}

rollback_config() {
    mkdir -p "$BACKUP_DIR"
    local latest
    latest=$(ls -t "${BACKUP_DIR}"/config.json.* 2>/dev/null | head -n1)
    if [ -z "$latest" ]; then
        warn "没有可用的备份"
        return
    fi
    cp "$latest" "$CONFIG_FILE"
    success "已回滚到备份: $(basename "$latest")"
    rc-service sing-box restart 2>/dev/null
}

# ============ 服务管理 ============
service_menu() {
    echo "1) 启动    2) 停止    3) 重启    4) 状态    5) 开机自启    6) 取消自启"
    read -rp "选择: " s
    case "$s" in
        1) rc-service sing-box start ;;
        2) rc-service sing-box stop ;;
        3) rc-service sing-box restart ;;
        4) rc-service sing-box status ;;
        5) rc-update add sing-box default && success "已加入开机自启" ;;
        6) rc-update del sing-box default && success "已取消开机自启" ;;
        *) warn "无效选择" ;;
    esac
}

# ============ 定时自动更新配置（类似 crontab CST-8） ============
setup_cron() {
    if ! command -v crond >/dev/null 2>&1; then
        info "安装 dcron..."
        apk add --no-cache dcron >/dev/null 2>&1
        rc-update add dcron default
        rc-service dcron start
    fi

    cat > "$CRON_FILE" <<EOF
#!/bin/sh
${SCRIPT_PATH} --auto-update-config
EOF
    chmod +x "$CRON_FILE"
    success "已加入每日定时任务 (${CRON_FILE})，由 dcron 的 daily 周期触发"
    warn "如需更精细的时间点（如每天固定几点），建议改用 /etc/crontabs/root 手动写 cron 表达式"
}

# ============ 自更新脚本本体 ============
self_update() {
    info "从远程拉取最新脚本..."
    local tmpfile
    tmpfile=$(mktemp)
    if ! curl -sSL -o "$tmpfile" "$SELF_UPDATE_URL"; then
        error "下载失败，请检查 SELF_UPDATE_URL 是否已改成你自己的仓库地址"
        rm -f "$tmpfile"
        return 1
    fi
    if [ ! -s "$tmpfile" ]; then
        error "下载内容为空"
        rm -f "$tmpfile"
        return 1
    fi
    chmod +x "$tmpfile"
    mv "$tmpfile" "$SCRIPT_PATH"
    success "脚本已更新，请重新运行: $SCRIPT_PATH"
    exit 0
}

# ============ 网络优化：BBR + sysctl 调优 ============
# 说明：
# - BBR 优化的是本机作为 TCP 发送方的拥塞控制，对 VLESS+Reality 这类走 TCP
#   的出站节点有直接帮助；Hysteria2 走 UDP/QUIC 自带拥塞控制，内核 BBR 对它不生效。
# - Alpine 的 linux-lts 内核自带 tcp_bbr 模块（以 .ko 形式提供，需要 modprobe 加载）。
enable_bbr() {
    info "检测 BBR 模块..."
    if ! lsmod | grep -q '^tcp_bbr'; then
        modprobe tcp_bbr 2>/dev/null
    fi

    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        warn "当前内核不支持 tcp_bbr（$(uname -r)），跳过 BBR 部分，仅应用其余 sysctl 调优"
        return 1
    fi

    success "tcp_bbr 模块可用"

    # 持久化模块加载
    if [ -f /etc/modules ] && ! grep -qx "tcp_bbr" /etc/modules; then
        echo "tcp_bbr" >> /etc/modules
        info "已将 tcp_bbr 写入 /etc/modules，确保重启后自动加载"
    fi
    return 0
}

network_optimize() {
    check_root
    local bbr_ok=0
    enable_bbr && bbr_ok=1

    info "写入 sysctl 调优配置到 ${SYSCTL_FILE} ..."

    {
        if [ "$bbr_ok" = "1" ]; then
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
        cat <<'EOF'
# 空闲后不重置慢启动，长连接更稳
net.ipv4.tcp_slow_start_after_idle = 0
# TCP Fast Open（客户端+服务端）
net.ipv4.tcp_fastopen = 3
# 加大读写缓冲区，高延迟链路（跨国节点）受益明显
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# 加大连接队列，避免高并发连接被丢
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
EOF
    } > "$SYSCTL_FILE"

    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
    success "sysctl 调优已应用（写入 ${SYSCTL_FILE}，重启后自动生效）"

    # 文件描述符限制
    info "配置文件描述符上限 (nofile)..."
    if ! grep -q "sing-box nofile 调优" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'
# --- sing-box nofile 调优 ---
root soft nofile 1000000
root hard nofile 1000000
EOF
        success "已写入 /etc/security/limits.conf"
    else
        info "limits.conf 中已存在相关配置，跳过"
    fi

    # 给 OpenRC 服务本身也加 ulimit，否则 root 全局 limits 对通过 openrc-run
    # 启动的后台进程不一定生效，需要在服务文件里显式声明
    if [ -f "$SERVICE_FILE" ] && ! grep -q "rc_ulimit" "$SERVICE_FILE"; then
        sed -i '/^command_background=true/a rc_ulimit="-n 1000000"' "$SERVICE_FILE"
        success "已在 ${SERVICE_FILE} 中加入 rc_ulimit，扩大 sing-box 进程自身的文件描述符上限"
        refresh_deptree
    fi

    echo ""
    info "当前生效状态："
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null
    sysctl net.core.default_qdisc 2>/dev/null
    warn "建议 reboot 一次，确认重启后 sysctl net.ipv4.tcp_congestion_control 仍显示 bbr"
}

# ============ 故障诊断（汇总本次排查踩过的坑） ============
diagnose() {
    echo "---- 1. tun 模块 ----"
    lsmod | grep tun && success "tun 模块已加载" || warn "tun 模块未加载"
    ls -l /dev/net/tun 2>/dev/null || warn "/dev/net/tun 不存在"
    grep -qx "tun" /etc/modules 2>/dev/null && success "/etc/modules 已包含 tun" || warn "/etc/modules 未包含 tun，重启可能失效"

    echo "---- 2. 服务是否在 default 运行级 ----"
    rc-update show default | grep sing-box && success "已在 default" || warn "未加入 default，运行菜单6里的[开机自启]"

    echo "---- 3. runlevel 软链接 ----"
    ls -la /etc/runlevels/default/ 2>/dev/null | grep sing-box

    echo "---- 4. 当前服务状态 ----"
    rc-service sing-box status

    echo "---- 5. 配置文件语法校验 ----"
    if [ -f "$BIN_PATH" ] && [ -f "$CONFIG_FILE" ]; then
        "$BIN_PATH" check -c "$CONFIG_FILE" && success "配置校验通过" || error "配置校验失败"
    fi

    echo "---- 6. 最近日志 ----"
    [ -f /var/log/sing-box.log ] && tail -n 20 /var/log/sing-box.log
    [ -f /var/log/sing-box.err ] && tail -n 20 /var/log/sing-box.err

    echo ""
    warn "如果以上都正常但重启后仍不自启，大概率是 OpenRC 依赖缓存(deptree)过期"
    read -rp "是否现在执行 [清除运行状态缓存 + 刷新deptree + 尝试启动]？(y/n): " yn
    if [ "$yn" = "y" ]; then
        rc-service sing-box zap 2>/dev/null
        refresh_deptree
        rc-service sing-box start
        rc-service sing-box status
        warn "建议重启一次验证：reboot 后执行 rc-status default 确认能看到 sing-box [ started ]"
    fi
}

# ============ 卸载 ============
uninstall_all() {
    read -rp "确认卸载 sing-box 及配置？(y/n): " yn
    [ "$yn" != "y" ] && return
    rc-service sing-box stop 2>/dev/null
    rc-update del sing-box default 2>/dev/null
    rm -f "$BIN_PATH" "$SERVICE_FILE" "$CRON_FILE"
    read -rp "是否同时删除配置目录 ${CONFIG_DIR}？(y/n): " yn2
    [ "$yn2" = "y" ] && rm -rf "$CONFIG_DIR"
    success "卸载完成"
}

# ============ 支持 cron 静默调用 ============
if [ "$1" = "--auto-update-config" ]; then
    update_config >> /var/log/sing-box-update.log 2>&1
    exit 0
fi

# ============ 主菜单 ============
check_root
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"

while true; do
    echo ""
    echo "===== sing-box 管理脚本 (Alpine/OpenRC) ====="
    echo " 1) 全新安装 (内核 + 服务)"
    echo " 2) 更新内核 (sing-box binary)"
    echo " 3) 设置订阅地址"
    echo " 4) 更新配置 (拉取订阅并校验)"
    echo " 5) 回滚配置到上一次备份"
    echo " 6) 服务管理 (启停/状态/自启)"
    echo " 7) 设置定时自动更新配置"
    echo " 8) 自更新本脚本"
    echo " 9) 卸载"
    echo "10) 故障诊断 (tun/自启/依赖缓存等常见问题一键排查)"
    echo "11) 网络优化 (启用BBR + sysctl调优 + 文件描述符上限)"
    echo " 0) 退出"
    echo "=============================================="
    read -rp "请选择: " choice
    case "$choice" in
        1) full_install ;;
        2) install_kernel "" ;;
        3) set_subscribe_url ;;
        4) update_config ;;
        5) rollback_config ;;
        6) service_menu ;;
        7) setup_cron ;;
        8) self_update ;;
        9) uninstall_all ;;
        10) diagnose ;;
        11) network_optimize ;;
        0) exit 0 ;;
        *) warn "无效选择" ;;
    esac
done
