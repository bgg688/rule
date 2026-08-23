#!/usr/bin/env bash
#
# onekeysb.sh - sing-box 一键安装 / 更新 / 管理脚本
# 仓库: https://github.com/bgg688/rule/blob/main/bg/onekeysb.sh
#
# 首次安装 (raw.githubusercontent.com 不稳定，默认走反代镜像):
#   curl -fsSL https://jingxiang.gaminggod.top/https://raw.githubusercontent.com/bgg688/rule/refs/heads/main/bg/onekeysb.sh | bash
#
# 非交互安装（跳过 dialog，直接用环境变量传入远程配置地址）:
#   SB_REMOTE_URL="https://your-sub-url" curl -fsSL <RAW_URL> | bash -s -- install
#
# 已安装后 (脚本会自装到 /usr/local/bin/onekeysb.sh):
#   onekeysb.sh                # 交互菜单
#   onekeysb.sh update-config  # 仅拉取/校验/替换远程配置
#   onekeysb.sh update-kernel  # 仅尝试升级 sing-box 内核 (见下方说明)
#   onekeysb.sh self-update    # 仅更新本脚本
#   onekeysb.sh maintenance    # 定时任务专用: 自更新 -> 配置更新 -> 内核更新
#   onekeysb.sh fix-user       # 修复 unit 要求的运行用户缺失导致的 status=217/USER
#   onekeysb.sh status         # 查看状态
#   onekeysb.sh uninstall      # 卸载管理组件 (不卸载 sing-box 本体)
#
# sing-box 内核安装策略:
#   - 首次安装（系统里还没有 sing-box）：此时通常还没有代理可用，直接走
#     sing-box.app 大概率不通，所以改为从 GitHub Release 下载官方发布的
#     二进制包（通过镜像），手动解压部署 + 自建 systemd unit，先把服务跑起来。
#   - 之后每次触发更新内核：先检测系统里有没有 sing-box 进程正在运行。
#     * 有 —— 说明它已经在用 tun 模式接管全部出站流量，此时机器出网已经
#       走代理了，可以直接用官方脚本 curl -fsSL https://sing-box.app/install.sh | sh
#       来更新（如果官方安装接管了，会自动清理引导阶段的自定义 systemd unit）。
#     * 没有 —— 忽略本次内核更新，不做任何操作。
#
set -uo pipefail

# ============ 基本配置 ============
GITHUB_RAW_HOST="raw.githubusercontent.com"
REPO_RAW_PATH="bgg688/rule/refs/heads/main/bg/onekeysb.sh"
GITHUB_MIRROR_PREFIX="https://jingxiang.gaminggod.top/"   # 镜像格式: 前缀 + 完整原始URL(含https://)
USE_MIRROR_FIRST=true                                      # GitHub 相关域名访问不稳定，默认优先走镜像

SCRIPT_PATH="/usr/local/bin/onekeysb.sh"
CONF_DIR="/etc/onekeysb"
URL_FILE="$CONF_DIR/remote_url.conf"
SB_CONF="/etc/sing-box/config.json"
BACKUP_DIR="$CONF_DIR/backup"
LOG_FILE="/var/log/onekeysb.log"

BOOTSTRAP_BIN="/usr/local/bin/sing-box"       # 引导阶段手动安装的二进制位置
BOOTSTRAP_MARKER="$CONF_DIR/.bootstrap_service"  # 标记：当前 sing-box.service 是我们自建的
FALLBACK_SB_VERSION="1.13.19"                 # 自动获取最新版本失败时的兜底版本号

SERVICE_NAME="onekeysb-maintenance"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

MAINT_TIME="04:30:00"        # 每日维护时间
MAINT_RANDOM_DELAY="600"     # 随机延迟秒数，避免固定时间集中请求

# ============ 工具函数 ============
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行 (sudo onekeysb.sh ...)"
    exit 1
  fi
}

# 通用 GitHub 相关下载：direct_url 为完整原始 URL（github.com / raw.githubusercontent.com / api.github.com 均可）
# 按 USE_MIRROR_FIRST 决定顺序，一个失败自动尝试另一个
fetch_via_mirror() {
  local direct_url="$1"
  local dest="$2"
  local mirror_url="${GITHUB_MIRROR_PREFIX}${direct_url}"

  local order=("$direct_url" "$mirror_url")
  if [[ "$USE_MIRROR_FIRST" == "true" ]]; then
    order=("$mirror_url" "$direct_url")
  fi

  for url in "${order[@]}"; do
    if curl -fsSL --max-time 30 "$url" -o "$dest" 2>/dev/null && [[ -s "$dest" ]]; then
      return 0
    fi
  done
  return 1
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv6l) echo "armv7" ;;
    i386|i686) echo "386" ;;
    *) echo "" ;;
  esac
}

get_latest_singbox_version() {
  local tmp_json version
  tmp_json=$(mktemp)
  if fetch_via_mirror "https://api.github.com/repos/SagerNet/sing-box/releases/latest" "$tmp_json"; then
    version=$(jq -r '.tag_name // empty' "$tmp_json" 2>/dev/null | sed 's/^v//')
  fi
  rm -f "$tmp_json"
  if [[ -z "${version:-}" ]]; then
    log "无法获取最新版本号，使用兜底版本 $FALLBACK_SB_VERSION"
    echo "$FALLBACK_SB_VERSION"
  else
    echo "$version"
  fi
}

# ============ 安装相关 ============
install_base() {
  log "更新系统 (apt update && upgrade)"
  apt update && apt upgrade -y
  log "安装常用工具"
  apt install -y wget curl unzip tar jq dialog cron gnupg ca-certificates lsb-release
}

# 首次引导安装：从 GitHub Release 下载官方二进制包（走镜像），手动部署 + 自建 systemd unit
install_singbox_bootstrap() {
  local arch version tmp_dir tmp_tar url bin_path

  arch=$(detect_arch)
  if [[ -z "$arch" ]]; then
    log "错误: 无法识别的 CPU 架构 ($(uname -m))，无法完成引导安装"
    return 1
  fi

  version=$(get_latest_singbox_version)
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
  log "引导安装 sing-box v${version} (${arch})，通过镜像下载: $url"

  tmp_dir=$(mktemp -d)
  tmp_tar="$tmp_dir/sing-box.tar.gz"

  if ! fetch_via_mirror "$url" "$tmp_tar"; then
    log "错误: 下载 sing-box release 包失败"
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! tar -xzf "$tmp_tar" -C "$tmp_dir"; then
    log "错误: 解压 sing-box release 包失败"
    rm -rf "$tmp_dir"
    return 1
  fi

  bin_path=$(find "$tmp_dir" -type f -name "sing-box" | head -n1)
  if [[ -z "$bin_path" ]]; then
    log "错误: 解压后未找到 sing-box 可执行文件"
    rm -rf "$tmp_dir"
    return 1
  fi

  install -m 0755 "$bin_path" "$BOOTSTRAP_BIN"
  rm -rf "$tmp_dir"
  mkdir -p "$(dirname "$SB_CONF")" "$CONF_DIR"

  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service (onekeysb bootstrap install)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${BOOTSTRAP_BIN} run -c ${SB_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

  touch "$BOOTSTRAP_MARKER"
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
  log "sing-box 引导安装完成 (v${version})，二进制位于 $BOOTSTRAP_BIN，服务已 enable（等配置写入后启动）"
}

# 检查 sing-box.service 实际生效的 unit 里要求哪个运行用户，如果这个用户在系统里不存在就自动创建，
# 并把配置目录的所有权改给它。官方安装（尤其是非标准 apt 流程时）有时只写 unit 不建用户，
# 会导致 systemd 报 "Failed to determine credentials for user ... status=217/USER"
ensure_singbox_service_user() {
  local unit_user
  unit_user=$(systemctl cat sing-box 2>/dev/null | grep -m1 '^User=' | cut -d'=' -f2 | tr -d ' ')

  [[ -z "$unit_user" || "$unit_user" == "root" ]] && return 0

  if ! id "$unit_user" >/dev/null 2>&1; then
    log "sing-box.service 需要运行用户 '$unit_user'，但系统里不存在，自动创建"
    if useradd --system --no-create-home --shell /usr/sbin/nologin "$unit_user" 2>/dev/null; then
      log "已创建系统用户 $unit_user"
    else
      log "警告: 创建用户 $unit_user 失败，请手动执行: useradd --system --no-create-home --shell /usr/sbin/nologin $unit_user"
      return 1
    fi
  fi

  mkdir -p "$(dirname "$SB_CONF")"
  chown -R "$unit_user":"$unit_user" "$(dirname "$SB_CONF")" 2>/dev/null || true
}

# 官方安装接管后，清理引导阶段自建的 systemd unit，避免覆盖官方管理的服务
cleanup_bootstrap_if_superseded() {
  if command -v dpkg >/dev/null 2>&1 && dpkg -s sing-box >/dev/null 2>&1; then
    log "检测到官方 apt 包已接管 sing-box，移除引导阶段自建的 systemd unit"
    rm -f /etc/systemd/system/sing-box.service
    rm -f "$BOOTSTRAP_MARKER"
    systemctl daemon-reload
    ensure_singbox_service_user
    if systemctl restart sing-box; then
      log "已切换为官方安装的 sing-box 并重启完成"
    else
      log "警告: 切换后重启 sing-box 失败，请检查 systemctl status sing-box"
    fi
  fi
}

# 输入远程配置地址：优先用 SB_REMOTE_URL 环境变量，其次弹 dialog（走 /dev/tty，兼容 curl|bash）
ask_remote_url() {
  mkdir -p "$CONF_DIR"
  local url="${SB_REMOTE_URL:-}"

  if [[ -z "$url" && -e /dev/tty ]]; then
    local default_url=""
    [[ -f "$URL_FILE" ]] && default_url=$(cat "$URL_FILE")
    if command -v dialog >/dev/null 2>&1; then
      url=$(dialog --stdout --title "sing-box 远程配置" \
        --inputbox "请输入远程配置文件 URL:" 10 70 "$default_url" < /dev/tty 2>/dev/tty) || true
      clear
    else
      read -rp "请输入远程配置文件 URL: " url < /dev/tty
    fi
  fi

  if [[ -z "$url" ]]; then
    log "未获取到远程配置 URL（无 tty 且未传入 SB_REMOTE_URL），跳过，之后可在菜单里设置"
    return 1
  fi

  echo "$url" > "$URL_FILE"
  log "已保存远程配置地址: $url"
}

deploy_self() {
  mkdir -p "$(dirname "$SCRIPT_PATH")"
  if fetch_via_mirror "https://${GITHUB_RAW_HOST}/${REPO_RAW_PATH}" "$SCRIPT_PATH"; then
    chmod +x "$SCRIPT_PATH"
    log "已部署管理脚本到 $SCRIPT_PATH"
  else
    log "警告: 无法从仓库拉取脚本自身，尝试回退为复制当前运行副本"
    if [[ -f "$0" ]]; then
      cp "$0" "$SCRIPT_PATH" 2>/dev/null && chmod +x "$SCRIPT_PATH"
    fi
  fi
}

setup_systemd() {
  log "配置 systemd 定时维护任务"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=onekeysb sing-box maintenance (self-update + config update + kernel update)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} maintenance
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Daily onekeysb maintenance timer

[Timer]
OnCalendar=*-*-* ${MAINT_TIME}
RandomizedDelaySec=${MAINT_RANDOM_DELAY}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.timer"
  log "定时任务已启用；Persistent=true 表示如果预定时间点机器未开机，开机后会自动补跑一次"
}

do_install() {
  need_root
  install_base

  if command -v sing-box >/dev/null 2>&1; then
    log "检测到系统已安装 sing-box，跳过引导安装"
  else
    install_singbox_bootstrap || log "引导安装失败，请检查网络/镜像配置后手动重试: onekeysb.sh update-kernel 不适用于此场景，请重新运行 onekeysb.sh install"
  fi

  ask_remote_url || true
  deploy_self
  setup_systemd

  log "执行首次维护（拉取配置、检测内核更新等）"
  "$SCRIPT_PATH" maintenance || log "首次维护未完全成功，请查看日志: $LOG_FILE"

  print_summary
}

# ============ 各子功能 ============
update_config() {
  if [[ ! -f "$URL_FILE" ]]; then
    log "错误: 未配置远程地址 ($URL_FILE 不存在)，请先在菜单里设置"
    return 1
  fi
  local url tmp_file
  url=$(cat "$URL_FILE")
  tmp_file=$(mktemp)
  mkdir -p "$BACKUP_DIR"

  log "拉取远程配置: $url"
  if ! curl -fsSL --max-time 30 "$url" -o "$tmp_file"; then
    log "下载失败，保留现有配置"
    rm -f "$tmp_file"; return 1
  fi
  if [[ ! -s "$tmp_file" ]]; then
    log "下载文件为空，放弃更新"
    rm -f "$tmp_file"; return 1
  fi

  log "校验新配置文件 (sing-box check)"
  if ! sing-box check -c "$tmp_file"; then
    log "配置校验失败，放弃更新，保留旧配置"
    rm -f "$tmp_file"; return 1
  fi

  if [[ -f "$SB_CONF" ]]; then
    cp "$SB_CONF" "$BACKUP_DIR/config.json.$(date '+%Y%m%d%H%M%S').bak"
  fi
  mkdir -p "$(dirname "$SB_CONF")"
  cp "$tmp_file" "$SB_CONF"
  rm -f "$tmp_file"

  ensure_singbox_service_user

  if systemctl restart sing-box; then
    log "配置更新完成，sing-box 已重启"
  else
    log "警告: sing-box 重启失败，请查看: journalctl -u sing-box -n 50"
    return 1
  fi

  ls -t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | tail -n +11 | xargs -r rm -f
}

# 内核更新：仅在检测到 sing-box 进程正在运行时才通过官方脚本更新，否则忽略本次更新
update_kernel() {
  if pgrep -x sing-box >/dev/null 2>&1; then
    log "检测到 sing-box 正在运行，执行官方安装脚本更新内核"
    if curl -fsSL https://sing-box.app/install.sh | sh; then
      log "官方安装脚本执行完成"
      cleanup_bootstrap_if_superseded
      ensure_singbox_service_user
    else
      log "错误: 官方安装脚本执行失败"
      return 1
    fi
  else
    log "未检测到 sing-box 进程在运行，跳过本次内核更新"
  fi
}

self_update() {
  local tmp_file
  tmp_file=$(mktemp)
  if ! fetch_via_mirror "https://${GITHUB_RAW_HOST}/${REPO_RAW_PATH}" "$tmp_file"; then
    log "self-update: 拉取远程脚本失败，跳过"
    rm -f "$tmp_file"; return 1
  fi
  if [[ ! -s "$tmp_file" ]] || ! head -1 "$tmp_file" | grep -q "^#!"; then
    log "self-update: 拉取到的内容异常，跳过替换"
    rm -f "$tmp_file"; return 1
  fi

  if [[ -f "$SCRIPT_PATH" ]] && cmp -s "$tmp_file" "$SCRIPT_PATH"; then
    log "self-update: 已是最新版本"
    rm -f "$tmp_file"; return 0
  fi

  mkdir -p "$BACKUP_DIR"
  [[ -f "$SCRIPT_PATH" ]] && cp "$SCRIPT_PATH" "$BACKUP_DIR/onekeysb.sh.$(date '+%Y%m%d%H%M%S').bak"
  mv "$tmp_file" "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  log "self-update: 脚本已更新到最新版本 ($SCRIPT_PATH)"
}

# 顺序: 先自更新脚本 -> 再更新配置（确保服务尽快跑起来）-> 再判断是否更新内核
do_maintenance() {
  log "===== 开始例行维护 ====="
  self_update
  update_config
  update_kernel
  log "===== 例行维护结束 ====="
}

show_status() {
  echo "---- sing-box 服务状态 ----"
  systemctl is-active sing-box 2>/dev/null || echo "未运行"
  sing-box version 2>/dev/null || echo "无法获取版本"
  if [[ -f "$BOOTSTRAP_MARKER" ]]; then
    echo "(当前为引导阶段自建服务，尚未被官方安装接管)"
  fi
  echo ""
  echo "---- 定时维护任务 ----"
  systemctl list-timers "${SERVICE_NAME}.timer" --no-pager 2>/dev/null
  echo ""
  echo "---- 远程配置地址 ----"
  [[ -f "$URL_FILE" ]] && cat "$URL_FILE" || echo "未设置"
  echo ""
  echo "---- 最近日志 (末尾20行) ----"
  [[ -f "$LOG_FILE" ]] && tail -n 20 "$LOG_FILE" || echo "暂无日志"
}

do_uninstall() {
  need_root
  read -rp "确认卸载 onekeysb 管理脚本及定时任务？(不会卸载 sing-box 本体) [y/N]: " confirm < /dev/tty
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "已取消"; return; }

  systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$TIMER_FILE"
  systemctl daemon-reload
  rm -f "$SCRIPT_PATH"
  log "onekeysb 管理组件已卸载（sing-box 本体及配置未删除，如需卸载请手动处理）"
}

print_summary() {
  cat <<EOF

===================== 安装完成 =====================
sing-box 配置文件:        $SB_CONF
远程配置地址记录:          $URL_FILE
配置/脚本备份目录:          $BACKUP_DIR
运行日志:                 $LOG_FILE

常用命令 (已装到 $SCRIPT_PATH，可直接敲 onekeysb.sh):
  onekeysb.sh                 进入交互菜单
  onekeysb.sh status           查看 sing-box 状态 + 定时任务 + 最近日志
  onekeysb.sh update-config    立即拉取并替换远程配置
  onekeysb.sh update-kernel    立即尝试升级内核（仅当 sing-box 正在运行时才会实际更新）
  onekeysb.sh self-update      立即更新本管理脚本
  onekeysb.sh maintenance      立即执行完整维护(以上三项)
  onekeysb.sh uninstall        卸载管理脚本及定时任务

sing-box 原生命令:
  systemctl status sing-box            查看服务状态
  systemctl restart sing-box           重启服务
  journalctl -u sing-box -n 50 -f      查看实时日志
  sing-box check -c $SB_CONF   手动校验配置

内核更新说明:
  首次安装时系统里没有 sing-box，走的是从 GitHub Release 镜像下载官方二进制包
  手动部署的「引导安装」。之后每次维护/手动 update-kernel，会先检测 sing-box
  进程是否在运行：在运行则说明出网已经走代理了，直接用官方脚本更新；不在运行
  则跳过，不做任何改动。一旦官方脚本成功接管，会自动清理引导阶段的自建 unit。

定时任务:
  systemctl list-timers onekeysb-maintenance.timer   查看下次维护时间
  每天 ${MAINT_TIME} 左右自动执行「脚本自更新 + 配置更新 + 内核更新判断」
  Persistent=true：如果到点时机器没开机，开机后会自动补跑一次
=====================================================
EOF
}

show_menu() {
  while true; do
    echo ""
    echo "==== onekeysb 管理菜单 ===="
    echo "1) 立即执行完整维护 (自更新+配置+内核)"
    echo "2) 仅更新远程配置"
    echo "3) 仅尝试升级 sing-box 内核"
    echo "4) 仅更新本管理脚本"
    echo "5) 修改远程配置地址"
    echo "6) 查看运行状态"
    echo "7) 修复运行用户缺失问题 (status=217/USER)"
    echo "8) 卸载"
    echo "0) 退出"
    read -rp "请选择: " choice < /dev/tty
    case "$choice" in
      1) do_maintenance ;;
      2) update_config ;;
      3) update_kernel ;;
      4) self_update ;;
      5) rm -f "$URL_FILE"; ask_remote_url ;;
      6) show_status ;;
      7) ensure_singbox_service_user && systemctl restart sing-box ;;
      8) do_uninstall; break ;;
      0) break ;;
      *) echo "无效选项" ;;
    esac
  done
}

usage() {
  cat <<EOF
用法: onekeysb.sh [install|menu|update-config|update-kernel|self-update|maintenance|fix-user|status|uninstall]
不带参数运行等同于 menu（若未安装则自动 install）
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    install) do_install ;;
    update-config) need_root; update_config ;;
    update-kernel) need_root; update_kernel ;;
    self-update) need_root; self_update ;;
    maintenance) need_root; do_maintenance ;;
    fix-user) need_root; ensure_singbox_service_user && systemctl restart sing-box ;;
    status) show_status ;;
    uninstall) do_uninstall ;;
    menu) need_root; show_menu ;;
    "")
      if command -v sing-box >/dev/null 2>&1 && [[ -f "$URL_FILE" ]]; then
        need_root
        show_menu
      else
        do_install
      fi
      ;;
    *) usage ;;
  esac
}

main "$@"
