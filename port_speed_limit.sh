#!/bin/bash

# Port Speed Limit - 端口持续限速脚本 v1.0
# 功能：为选定端口设置常驻的 tc htb 带宽限速（与流量阈值限速独立）
# 最后更新：2026-04-24

SCRIPT_VERSION="1.0"
LAST_UPDATE="2026-04-24"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TZ='Asia/Shanghai'

WORK_DIR="/root/TrafficCop"
SPEED_CONFIG_FILE="$WORK_DIR/port_speed_limits.json"
SPEED_LOG_FILE="$WORK_DIR/port_speed_limit.log"
SPEED_SCRIPT_PATH="$WORK_DIR/port_speed_limit.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$WORK_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$SPEED_LOG_FILE"
}

check_deps() {
    local missing=()
    for tool in tc iptables jq bc; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}缺少依赖: ${missing[*]}${NC}"
        echo -e "${YELLOW}请先安装：apt-get install -y iproute2 iptables jq bc${NC}"
        return 1
    fi
    return 0
}

init_config() {
    [ -f "$SPEED_CONFIG_FILE" ] || echo '{"limits":[]}' > "$SPEED_CONFIG_FILE"
}

get_default_interface() {
    ip route | grep default | awk '{print $5}' | head -n1
}

# 校验端口号
valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# 限速 class id：1:<port_hex>，避免和现有 1:$port（decimal）冲突时的问题
# 这里直接用 port 作为 class minor id（与 port_traffic_limit.sh 保持一致，但 prio 使用 2 区分）
get_class_id() {
    echo "1:$1"
}

# 获取配置
get_limit_config() {
    jq -r ".limits[] | select(.port == $1)" "$SPEED_CONFIG_FILE" 2>/dev/null
}

limit_exists() {
    local count
    count=$(jq -r ".limits[] | select(.port == $1) | .port" "$SPEED_CONFIG_FILE" 2>/dev/null | wc -l)
    [ "$count" -gt 0 ]
}

save_limit() {
    local port=$1 speed=$2 interface=$3
    local created_at
    created_at=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp
    tmp=$(mktemp)
    jq "del(.limits[] | select(.port == $port))" "$SPEED_CONFIG_FILE" > "$tmp" && mv "$tmp" "$SPEED_CONFIG_FILE"
    local entry
    entry=$(jq -n --argjson p "$port" --argjson s "$speed" --arg i "$interface" --arg t "$created_at" \
        '{port:$p, speed_kbit:$s, interface:$i, created_at:$t}')
    tmp=$(mktemp)
    jq ".limits += [$entry]" "$SPEED_CONFIG_FILE" > "$tmp" && mv "$tmp" "$SPEED_CONFIG_FILE"
}

delete_limit_config() {
    local tmp
    tmp=$(mktemp)
    jq "del(.limits[] | select(.port == $1))" "$SPEED_CONFIG_FILE" > "$tmp" && mv "$tmp" "$SPEED_CONFIG_FILE"
}

# 确保根 qdisc 存在
ensure_root_qdisc() {
    local interface=$1
    if ! tc qdisc show dev "$interface" | grep -q "htb"; then
        tc qdisc add dev "$interface" root handle 1: htb default 30 2>/dev/null || true
    fi
}

# 清理接口上所有 prio 2 的限速规则（不影响 port_traffic_limit.sh 使用的 prio 1）
wipe_interface_rules() {
    local interface=$1
    tc filter del dev "$interface" parent 1:0 prio 2 2>/dev/null
    # 删除 config 中记录过的所有该接口上的 class
    if [ -f "$SPEED_CONFIG_FILE" ]; then
        local ports
        ports=$(jq -r --arg i "$interface" '.limits[] | select(.interface == $i) | .port' "$SPEED_CONFIG_FILE" 2>/dev/null)
        while read -r p; do
            [ -z "$p" ] && continue
            tc class del dev "$interface" classid "1:$p" 2>/dev/null
        done <<< "$ports"
    fi
}

# 为单个端口添加 class + filter（假设已清理旧规则）
add_port_rules() {
    local port=$1 speed=$2 interface=$3
    local class_id
    class_id=$(get_class_id "$port")
    tc class add dev "$interface" parent 1: classid "$class_id" htb rate "${speed}kbit" ceil "${speed}kbit" 2>>"$SPEED_LOG_FILE"
    tc filter add dev "$interface" protocol ip parent 1:0 prio 2 u32 \
        match ip sport "$port" 0xffff flowid "$class_id" 2>>"$SPEED_LOG_FILE"
    tc filter add dev "$interface" protocol ip parent 1:0 prio 2 u32 \
        match ip dport "$port" 0xffff flowid "$class_id" 2>>"$SPEED_LOG_FILE"
}

# 依据 config 重建某个接口上的所有限速规则
rebuild_interface() {
    local interface=$1
    ensure_root_qdisc "$interface"
    wipe_interface_rules "$interface"
    if [ -f "$SPEED_CONFIG_FILE" ]; then
        local rows
        rows=$(jq -r --arg i "$interface" '.limits[] | select(.interface == $i) | "\(.port) \(.speed_kbit)"' "$SPEED_CONFIG_FILE" 2>/dev/null)
        while read -r p s; do
            [ -z "$p" ] && continue
            add_port_rules "$p" "$s" "$interface"
        done <<< "$rows"
    fi
}

# 应用 tc 限速：保存配置后全量重建
apply_speed_limit() {
    local port=$1 speed=$2 interface=$3
    rebuild_interface "$interface"
    log "已应用端口 $port 常驻限速 ${speed}kbit/s (接口 $interface)"
}

remove_speed_limit_tc() {
    local port=$1 interface=$2
    # 先显式删除该端口的 class（因为它已从 config 中移除，wipe 不会处理）
    tc class del dev "$interface" classid "1:$port" 2>/dev/null
    rebuild_interface "$interface"
    log "已移除端口 $port 的限速"
}

# 开机/重启后一次性重建所有限速
apply_all() {
    init_config
    local total
    total=$(jq -r '.limits | length' "$SPEED_CONFIG_FILE")
    [ "$total" -eq 0 ] && { log "无配置的端口限速"; return 0; }

    log "开始应用 $total 条端口限速规则"
    local i=0
    while [ "$i" -lt "$total" ]; do
        local port speed interface
        port=$(jq -r ".limits[$i].port" "$SPEED_CONFIG_FILE")
        speed=$(jq -r ".limits[$i].speed_kbit" "$SPEED_CONFIG_FILE")
        interface=$(jq -r ".limits[$i].interface" "$SPEED_CONFIG_FILE")
        apply_speed_limit "$port" "$speed" "$interface"
        i=$((i+1))
    done
}

list_limits() {
    init_config
    echo -e "${CYAN}==================== 已配置的端口限速 ====================${NC}"
    local total
    total=$(jq -r '.limits | length' "$SPEED_CONFIG_FILE")
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}暂无配置${NC}"
        return 1
    fi
    local i=0 idx=1
    while [ "$i" -lt "$total" ]; do
        local port speed interface created
        port=$(jq -r ".limits[$i].port" "$SPEED_CONFIG_FILE")
        speed=$(jq -r ".limits[$i].speed_kbit" "$SPEED_CONFIG_FILE")
        interface=$(jq -r ".limits[$i].interface" "$SPEED_CONFIG_FILE")
        created=$(jq -r ".limits[$i].created_at" "$SPEED_CONFIG_FILE")
        echo -e "  ${GREEN}[$idx]${NC} 端口 $port  速率 ${speed}kbit/s  接口 $interface  创建于 $created"
        i=$((i+1)); idx=$((idx+1))
    done
    echo -e "${CYAN}==========================================================${NC}"
}

wizard_add() {
    clear
    echo -e "${CYAN}==================== 设置端口限速 ====================${NC}"
    local port speed unit interface

    while true; do
        read -p "请输入端口号 (1-65535): " port
        if valid_port "$port"; then break; fi
        echo -e "${RED}无效端口${NC}"
    done

    echo ""
    echo -e "${CYAN}限速单位：${NC}"
    echo "1) kbit/s  (默认)"
    echo "2) mbit/s"
    read -p "选择 [回车=1]: " unit_choice
    [ -z "$unit_choice" ] && unit_choice="1"

    while true; do
        read -p "限速值: " speed_input
        if [[ "$speed_input" =~ ^[0-9]+$ ]] && [ "$speed_input" -gt 0 ]; then
            break
        fi
        echo -e "${RED}请输入正整数${NC}"
    done

    if [ "$unit_choice" = "2" ]; then
        speed=$((speed_input * 1000))
    else
        speed="$speed_input"
    fi

    local default_if
    default_if=$(get_default_interface)
    read -p "网络接口 [回车=$default_if]: " interface
    [ -z "$interface" ] && interface="$default_if"

    save_limit "$port" "$speed" "$interface"
    apply_speed_limit "$port" "$speed" "$interface"

    echo ""
    echo -e "${GREEN}✓ 端口 $port 已设置常驻限速 ${speed}kbit/s${NC}"
    echo ""
    read -p "按回车键继续..." _
}

wizard_remove() {
    clear
    list_limits || { read -p "按回车键继续..." _; return; }
    echo ""
    read -p "输入要解除的端口号 (或 all): " input
    if [ "$input" = "all" ]; then
        local total
        total=$(jq -r '.limits | length' "$SPEED_CONFIG_FILE")
        local i=0
        while [ "$i" -lt "$total" ]; do
            local port interface
            port=$(jq -r ".limits[0].port" "$SPEED_CONFIG_FILE")
            interface=$(jq -r ".limits[0].interface" "$SPEED_CONFIG_FILE")
            delete_limit_config "$port"
            remove_speed_limit_tc "$port" "$interface"
            total=$((total-1))
        done
        echo -e "${GREEN}已解除所有端口限速${NC}"
    elif valid_port "$input"; then
        if ! limit_exists "$input"; then
            echo -e "${RED}端口 $input 无限速配置${NC}"
        else
            local interface
            interface=$(get_limit_config "$input" | jq -r '.interface')
            delete_limit_config "$input"
            remove_speed_limit_tc "$input" "$interface"
            echo -e "${GREEN}端口 $input 限速已解除${NC}"
        fi
    else
        echo -e "${RED}无效输入${NC}"
    fi
    echo ""
    read -p "按回车键继续..." _
}

setup_boot_cron() {
    local entry="@reboot $SPEED_SCRIPT_PATH --apply-all >> $SPEED_LOG_FILE 2>&1"
    local cur
    cur=$(crontab -l 2>/dev/null)
    if echo "$cur" | grep -Fq "$SPEED_SCRIPT_PATH --apply-all"; then
        echo -e "${GREEN}开机自启已配置${NC}"
    else
        (echo "$cur"; echo "$entry") | crontab -
        echo -e "${GREEN}已添加开机自启任务${NC}"
    fi
}

interactive_menu() {
    while true; do
        clear
        echo -e "${CYAN}========== 端口常驻限速管理 v${SCRIPT_VERSION} ==========${NC}"
        echo "1) 设置端口限速"
        echo "2) 解除端口限速"
        echo "3) 查看所有限速"
        echo "4) 启用开机自动恢复"
        echo "5) 立即重建所有限速规则"
        echo "0) 退出"
        echo -e "${CYAN}==================================================${NC}"
        read -p "请选择 [0-5]: " choice
        case $choice in
            1) wizard_add ;;
            2) wizard_remove ;;
            3) clear; list_limits; echo ""; read -p "按回车键继续..." _ ;;
            4) setup_boot_cron; read -p "按回车键继续..." _ ;;
            5) apply_all; read -p "按回车键继续..." _ ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

main() {
    check_deps || exit 1
    init_config

    case "$1" in
        --apply-all)
            apply_all
            ;;
        --set)
            # --set PORT SPEED_KBIT [INTERFACE]
            local port=$2 speed=$3 interface=${4:-$(get_default_interface)}
            if ! valid_port "$port" || ! [[ "$speed" =~ ^[0-9]+$ ]]; then
                echo "用法: $0 --set PORT SPEED_KBIT [INTERFACE]" >&2
                exit 1
            fi
            save_limit "$port" "$speed" "$interface"
            apply_speed_limit "$port" "$speed" "$interface"
            ;;
        --remove)
            local port=$2
            if ! valid_port "$port"; then
                echo "用法: $0 --remove PORT" >&2
                exit 1
            fi
            if limit_exists "$port"; then
                local interface
                interface=$(get_limit_config "$port" | jq -r '.interface')
                delete_limit_config "$port"
                remove_speed_limit_tc "$port" "$interface"
                echo "端口 $port 限速已解除"
            else
                echo "端口 $port 无配置"
            fi
            ;;
        --list)
            list_limits
            ;;
        --get)
            # 给 tg_bot 使用：输出 JSON
            local port=$2
            get_limit_config "$port"
            ;;
        "")
            interactive_menu
            ;;
        *)
            echo "用法: $0 [--set PORT SPEED | --remove PORT | --list | --apply-all | --get PORT]"
            exit 1
            ;;
    esac
}

main "$@"
