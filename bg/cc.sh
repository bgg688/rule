#!/usr/bin/env bash

# =========================================================
# 常用命令工具箱 (cc.sh)
# 适用系统: Debian 12/13 & OpenWrt 25.12+ (apk)
# =========================================================

# 脚本远端更新地址与本地路径
SCRIPT_URL="https://raw.githubusercontent.com/bgg688/rule/refs/heads/main/bg/cc.sh"
SCRIPT_PATH="/usr/local/bin/cc.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 1. 检查包管理器与初始化环境
check_env() {
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
        PKG_ADD="apk add --no-cache"
        OS_TYPE="OpenWrt"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
        PKG_ADD="apt-get update -y && apt-get install -y"
        OS_TYPE="Debian/Ubuntu"
    else
        PKG_MGR="unknown"
        OS_TYPE="Unknown"
    fi
}

# 辅助按键继续
press_any_key() {
    echo ""
    read -rp "按回车键继续..." temp
}

# 2. 在线更新脚本函数
update_script() {
    echo -e "${YELLOW}正在从 GitHub 获取最新版本的 cc.sh...${PLAIN}"
    
    # 确保 curl 或 wget 存在
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        eval "$PKG_ADD curl wget" 2>/dev/null
    fi

    TMP_FILE="/tmp/cc_new.sh"

    if command -v curl >/dev/null 2>&1; then
        curl -sSL "$SCRIPT_URL" -o "$TMP_FILE"
    else
        wget -qO "$TMP_FILE" "$SCRIPT_URL"
    fi

    if [ -s "$TMP_FILE" ]; then
        if grep -q "main_menu" "$TMP_FILE"; then
            mv "$TMP_FILE" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            echo -e "${GREEN}脚本更新成功！正在重新启动最新版本...${PLAIN}"
            sleep 1
            exec "$SCRIPT_PATH"
        else
            echo -e "${RED}更新失败：下载的文件异常！${PLAIN}"
            rm -f "$TMP_FILE"
        fi
    else
        echo -e "${RED}更新失败：无法连接到 GitHub 或拉取文件为空！${PLAIN}"
        rm -f "$TMP_FILE"
    fi
    press_any_key
}

# =========================================================
# 菜单 1：系统维护与配置
# =========================================================
menu_system() {
    while true; do
        clear
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e "${GREEN}       1. 系统维护与配置            ${PLAIN}"
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e " 1. 查看系统信息、架构与端口占用"
        echo -e " 2. 修改系统时区 (Asia/Shanghai)"
        echo -e " 3. 一键开启 BBR 加速"
        echo -e " 4. 一键 DD 重装系统 (reinstall.sh)"
        echo -e "------------------------------------"
        echo -e " 0. 返回主菜单"
        echo -e "------------------------------------"
        read -rp "请输入选项 [0-4]: " choice

        case "$choice" in
            1)
                clear
                echo -e "${YELLOW}[系统概况]${PLAIN}"
                echo "操作系统: $OS_TYPE"
                echo "系统架构: $(uname -m)"
                echo "内核版本: $(uname -r)"
                echo "运行时间: $(uptime -p 2>/dev/null || uptime)"
                echo ""
                echo -e "${YELLOW}[内存使用]${PLAIN}"
                free -h 2>/dev/null || free
                echo ""
                echo -e "${YELLOW}[磁盘占用]${PLAIN}"
                df -h /
                echo ""
                echo -e "${YELLOW}[当前监听端口]${PLAIN}"
                if command -v ss >/dev/null 2>&1; then
                    ss -tulpn
                elif command -v netstat >/dev/null 2>&1; then
                    netstat -tulpn
                else
                    echo -e "${RED}未找到 ss 或 netstat 工具${PLAIN}"
                fi
                press_any_key
                ;;
            2)
                echo -e "${YELLOW}设置系统时区为 Asia/Shanghai...${PLAIN}"
                if command -v timedatectl >/dev/null 2>&1; then
                    timedatectl set-timezone Asia/Shanghai
                else
                    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
                fi
                echo -e "${GREEN}当前系统时间: $(date)${PLAIN}"
                press_any_key
                ;;
            3)
                echo -e "${YELLOW}开始检查并配置 BBR 加速...${PLAIN}"
                if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
                    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
                fi
                if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
                    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
                fi
                sysctl -p
                echo -e "${GREEN}当前 TCP 拥塞控制算法: $(sysctl net.ipv4.tcp_congestion_control)${PLAIN}"
                press_any_key
                ;;
            4)
                clear
                echo -e "${RED}===============================================${PLAIN}"
                echo -e "${RED}           警告：一键 DD 重装系统               ${PLAIN}"
                echo -e "${RED} 重装过程将清空当前系统磁盘所有数据，请谨慎操作！ ${PLAIN}"
                echo -e "${RED}===============================================${PLAIN}"
                read -rp "确定要继续吗？(y/N): " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    echo ""
                    echo "请选择要重装的系统:"
                    echo "1) Debian 12"
                    echo "2) Debian 11"
                    echo "3) Ubuntu 22.04"
                    echo "4) Ubuntu 20.04"
                    read -rp "选择系统 [1-4, 默认1]: " sys_choice
                    case "$sys_choice" in
                        2) OS_TARGET="debian 11" ;;
                        3) OS_TARGET="ubuntu 22.04" ;;
                        4) OS_TARGET="ubuntu 20.04" ;;
                        *) OS_TARGET="debian 12" ;;
                    esac

                    read -rp "请输入重装后的 Root 密码: " sys_pass
                    read -rp "请输入重装后的 SSH 端口 [默认 22]: " sys_port
                    sys_port=${sys_port:-22}

                    if [ -z "$sys_pass" ]; then
                        echo -e "${RED}密码不能为空！取消重装。${PLAIN}"
                    else
                        echo -e "${YELLOW}正在下载重装脚本...${PLAIN}"
                        curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O reinstall.sh https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
                        echo -e "${YELLOW}即将开始 DD 重装，系统将自动重启并进行安装...${PLAIN}"
                        sleep 3
                        bash reinstall.sh $OS_TARGET --password "$sys_pass" --ssh-port "$sys_port"
                    fi
                else
                    echo "已取消重装。"
                fi
                press_any_key
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

# =========================================================
# 菜单 2：网络诊断与测试
# =========================================================
menu_network() {
    while true; do
        clear
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e "${GREEN}       2. 网络诊断与流媒体测试      ${PLAIN}"
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e " 1. 运行流媒体解锁测试 (RegionRestrictionCheck)"
        echo -e " 2. 测试 VPS 大陆回程路由 (BestTrace)"
        echo -e " 3. 实时网络流量监控 (vnstat / iftop)"
        echo -e " 4. 基础网络诊断 (curl / ping / traceroute)"
        echo -e "------------------------------------"
        echo -e " 0. 返回主菜单"
        echo -e "------------------------------------"
        read -rp "请输入选项 [0-4]: " choice

        case "$choice" in
            1)
                echo -e "${YELLOW}正在运行流媒体解锁测试...${PLAIN}"
                bash <(curl -L -s check.unlock.media)
                press_any_key
                ;;
            2)
                echo -e "${YELLOW}正在测试大陆回程路由...${PLAIN}"
                wget -qO- git.io/besttrace | bash
                press_any_key
                ;;
            3)
                if command -v iftop >/dev/null 2>&1; then
                    iftop
                elif command -v vnstat >/dev/null 2>&1; then
                    vnstat -l
                else
                    echo -e "${YELLOW}未检测到流量统计工具，正在为您安装...${PLAIN}"
                    eval "$PKG_ADD iftop"
                    iftop
                fi
                press_any_key
                ;;
            4)
                read -rp "请输入要测试的目标 IP 或 域名: " target_host
                if [ -n "$target_host" ]; then
                    echo -e "${YELLOW}--- Ping 测试 ---${PLAIN}"
                    ping -c 4 "$target_host"
                    echo -e "${YELLOW}--- 路由追踪 ---${PLAIN}"
                    if command -v traceroute >/dev/null 2>&1; then
                        traceroute "$target_host"
                    else
                        tracepath "$target_host" 2>/dev/null || echo "请先安装 traceroute"
                    fi
                fi
                press_any_key
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

# =========================================================
# 菜单 3：代理协议服务 (sing-box / Hysteria 2)
# =========================================================
menu_proxy() {
    while true; do
        clear
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e "${GREEN}     3. sing-box / Hysteria 2 管理   ${PLAIN}"
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e " 1. 查看 sing-box 运行状态"
        echo -e " 2. 重启 sing-box 服务"
        echo -e " 3. 查看 sing-box 实时日志"
        echo -e " 4. 查看 Hysteria 2 运行状态"
        echo -e " 5. 重启 Hysteria 2 服务"
        echo -e " 6. 查看 Hysteria 2 实时日志"
        echo -e " 7. 运行常用开源代理一键脚本 (安装/更新)"
        echo -e "------------------------------------"
        echo -e " 0. 返回主菜单"
        echo -e "------------------------------------"
        read -rp "请输入选项 [0-7]: " choice

        case "$choice" in
            1)
                if [ "$OS_TYPE" = "OpenWrt" ]; then
                    service sing-box status 2>/dev/null || ps | grep sing-box
                else
                    systemctl status sing-box --no-pager
                fi
                press_any_key
                ;;
            2)
                if [ "$OS_TYPE" = "OpenWrt" ]; then
                    service sing-box restart
                else
                    systemctl restart sing-box
                fi
                echo -e "${GREEN}sing-box 已发起重启。${PLAIN}"
                press_any_key
                ;;
            3)
                echo -e "${YELLOW}正在读取 sing-box 实时日志 (按 Ctrl+C 退出)...${PLAIN}"
                if [ "$OS_TYPE" = "OpenWrt" ]; then
                    logread -e sing-box -f
                else
                    journalctl -u sing-box -n 50 -f
                fi
                press_any_key
                ;;
            4)
                if [ "$OS_TYPE" = "OpenWrt" ]; then
                    service hysteria2 status 2>/dev/null || ps | grep hysteria
                else
                    systemctl status hysteria2 --no-pager
                fi
                press_any_key
                ;;
            5)
                if [ "$OS_TYPE" = "OpenWrt" ]; then
                    service hysteria2 restart
                else
                    systemctl restart hysteria2
                fi
                echo -e "${GREEN}Hysteria 2 已发起重启。${PLAIN}"
                press_any_key
                ;;
            6)
                echo -e "${YELLOW}正在读取 Hysteria 2 实时日志 (按 Ctrl+C 退出)...${PLAIN}"
                if [ "$OS_TYPE" = "OpenWrt" ]; then
                    logread -e hysteria -f
                else
                    journalctl -u hysteria2 -n 50 -f
                fi
                press_any_key
                ;;
            7)
                echo -e "${YELLOW}选择要调用的安装脚本:${PLAIN}"
                echo "1) Hysteria 2 官方一键脚本"
                echo "2) sing-box 官方安装脚本"
                read -rp "选择 [1-2]: " script_choice
                case "$script_choice" in
                    1) bash <(curl -fsSL https://get.hy2.sh/) ;;
                    2) bash <(curl -fsSL https://sing-box.app/deb-install.sh) ;;
                    *) echo "已取消" ;;
                esac
                press_any_key
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

# =========================================================
# 菜单 4：Docker 与容器工具
# =========================================================
menu_docker() {
    while true; do
        clear
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e "${GREEN}       4. Docker 常用管理           ${PLAIN}"
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e " 1. 一键安装 Docker 环境"
        echo -e " 2. 一键部署 SmokePing 网络监控容器"
        echo -e " 3. 查看运行中的容器 (docker ps)"
        echo -e " 4. 查看全部容器 (docker ps -a)"
        echo -e " 5. 查看容器资源占用 (docker stats)"
        echo -e " 6. 清理无用 Docker 镜像与缓存"
        echo -e "------------------------------------"
        echo -e " 0. 返回主菜单"
        echo -e "------------------------------------"
        read -rp "请输入选项 [0-6]: " choice

        case "$choice" in
            1)
                echo -e "${YELLOW}正在准备安装 Docker...${PLAIN}"
                curl -fsSL https://get.docker.com | sh
                systemctl enable --now docker 2>/dev/null
                echo -e "${GREEN}Docker 安装完成！${PLAIN}"
                press_any_key
                ;;
            2)
                echo -e "${YELLOW}开始拉取并部署 SmokePing 容器...${PLAIN}"
                mkdir -p /home/config/smokeping /home/data/smokeping
                docker pull linuxserver/smokeping
                docker run -d \
                  --name=smokeping \
                  -e PUID=1000 \
                  -e PGID=1000 \
                  -e TZ=Asia/Shanghai \
                  -p 9080:80 \
                  -v /home/config/smokeping:/config \
                  -v /home/data/smokeping:/data \
                  --restart unless-stopped \
                  linuxserver/smokeping
                echo -e "${GREEN}SmokePing 已成功部署！Web 访问地址: http://你的IP:9080${PLAIN}"
                press_any_key
                ;;
            3) docker ps; press_any_key ;;
            4) docker ps -a; press_any_key ;;
            5) docker stats --no-stream; press_any_key ;;
            6)
                echo -e "${YELLOW}正在清理系统未使用的容器和镜像...${PLAIN}"
                docker system prune -a --volumes -f
                echo -e "${GREEN}清理完成！${PLAIN}"
                press_any_key
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

# =========================================================
# 菜单 5：域名 SSL 证书管理 (ACME)
# =========================================================
menu_acme() {
    while true; do
        clear
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e "${GREEN}       5. ACME 域名 SSL 证书申请    ${PLAIN}"
        echo -e "${GREEN}====================================${PLAIN}"
        echo -e " 1. 申请域名证书 (80 端口模式 -> /root/acme)"
        echo -e " 2. 查看当前已申请的 ACME 证书列表"
        echo -e " 3. 手动强制续期所有证书"
        echo -e "------------------------------------"
        echo -e " 0. 返回主菜单"
        echo -e "------------------------------------"
        read -rp "请输入选项 [0-3]: " choice

        case "$choice" in
            1)
                clear
                echo -e "${YELLOW}正在安装必要的依赖项与 acme.sh...${PLAIN}"
                eval "$PKG_ADD socat curl wget cron" 2>/dev/null
                curl https://get.acme.sh | sh -s email="admin@$(date +%s).com"
                
                ACME_BIN="$HOME/.acme.sh/acme.sh"
                $ACME_BIN --set-default-ca --server letsencrypt

                read -rp "请输入你要申请证书的完整域名 (例: node.example.com): " domain_name
                if [ -n "$domain_name" ]; then
                    echo -e "${YELLOW}正在通过 80 端口验证申请证书，请确保 80 端口未被占用且域名解析已生效！${PLAIN}"
                    $ACME_BIN --issue -d "$domain_name" --standalone -k ec-256

                    if [ $? -eq 0 ]; then
                        mkdir -p /root/acme/"$domain_name"
                        $ACME_BIN --install-cert -d "$domain_name" --ecc \
                          --fullchain-file /root/acme/"$domain_name"/fullchain.pem \
                          --key-file /root/acme/"$domain_name"/privkey.pem

                        echo -e "${GREEN}==================================================${PLAIN}"
                        echo -e "${GREEN} 证书申请并安装成功！${PLAIN}"
                        echo -e " 公钥路径: ${CYAN}/root/acme/$domain_name/fullchain.pem${PLAIN}"
                        echo -e " 私钥路径: ${CYAN}/root/acme/$domain_name/privkey.pem${PLAIN}"
                        echo -e "${GREEN}==================================================${PLAIN}"
                    else
                        echo -e "${RED}证书申请失败，请检查 80 端口占用或防火墙设置。${PLAIN}"
                    fi
                fi
                press_any_key
                ;;
            2)
                if [ -f "$HOME/.acme.sh/acme.sh" ]; then
                    $HOME/.acme.sh/acme.sh --list
                else
                    echo -e "${RED}尚未安装 acme.sh${PLAIN}"
                fi
                press_any_key
                ;;
            3)
                if [ -f "$HOME/.acme.sh/acme.sh" ]; then
                    $HOME/.acme.sh/acme.sh --cron --force
                else
                    echo -e "${RED}尚未安装 acme.sh${PLAIN}"
                fi
                press_any_key
                ;;
            0) break ;;
            *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

# =========================================================
# 主菜单
# =========================================================
main_menu() {
    check_env
    while true; do
        clear
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e "${BLUE}          常用运维与快捷命令工具箱 (cc.sh)         ${PLAIN}"
        echo -e "${BLUE}          当前系统环境: ${CYAN}${OS_TYPE}${BLUE}                    ${PLAIN}"
        echo -e "${BLUE}==================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 系统维护与配置 (时区/BBR/一键DD/信息查阅)"
        echo -e " ${GREEN}2.${PLAIN} 网络诊断与测试 (解锁检测/回程路由/流量统计)"
        echo -e " ${GREEN}3.${PLAIN} 代理协议服务   (sing-box / Hysteria 2 日志与管理)"
        echo -e " ${GREEN}4.${PLAIN} Docker 容器管理 (Docker安装 / SmokePing 部署)"
        echo -e " ${GREEN}5.${PLAIN} ACME 域名 SSL 证书一键申请"
        echo -e " ${CYAN}6. 在线更新 cc.sh 脚本${PLAIN}"
        echo -e "--------------------------------------------------"
        echo -e " ${GREEN}0.${PLAIN} 退出脚本"
        echo -e "--------------------------------------------------"
        read -rp "请输入选项 [0-6]: " choice

        case "$choice" in
            1) menu_system ;;
            2) menu_network ;;
            3) menu_proxy ;;
            4) menu_docker ;;
            5) menu_acme ;;
            6) update_script ;;
            0)
                echo -e "${GREEN}感谢使用，已退出脚本。${PLAIN}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新输入！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# 启动主流程
main_menu
