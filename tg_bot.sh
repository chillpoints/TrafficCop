#!/bin/bash

# TG Bot - 交互式 Telegram 机器人 v1.0
# 功能：
#   1. 用户发送 /start 开始绑定端口
#   2. 发送端口号即完成绑定
#   3. 绑定后最多只能更换 3 次端口号
#   4. 可查询限速、流量用量、到期时间等
# 最后更新：2026-04-24

SCRIPT_VERSION="1.0"
LAST_UPDATE="2026-04-24"

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TZ='Asia/Shanghai'

WORK_DIR="/root/TrafficCop"
BOT_CONFIG_FILE="$WORK_DIR/tg_bot_config.txt"
BOT_USERS_FILE="$WORK_DIR/tg_bot_users.json"
BOT_OFFSET_FILE="$WORK_DIR/tg_bot_offset"
BOT_LOG_FILE="$WORK_DIR/tg_bot.log"
BOT_PID_FILE="$WORK_DIR/tg_bot.pid"
BOT_SCRIPT_PATH="$WORK_DIR/tg_bot.sh"

PORT_CONFIG_FILE="$WORK_DIR/ports_traffic_config.json"
SPEED_CONFIG_FILE="$WORK_DIR/port_speed_limits.json"
PORT_LIMIT_SCRIPT="$WORK_DIR/port_traffic_limit.sh"
SPEED_LIMIT_SCRIPT="$WORK_DIR/port_speed_limit.sh"

MAX_PORT_CHANGES=3

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$WORK_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$BOT_LOG_FILE"
}

check_deps() {
    local missing=()
    for tool in curl jq bc; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}缺少依赖: ${missing[*]}${NC}"
        return 1
    fi
    return 0
}

load_config() {
    if [ ! -f "$BOT_CONFIG_FILE" ]; then
        return 1
    fi
    # shellcheck disable=SC1090
    source "$BOT_CONFIG_FILE"
    [ -n "$BOT_TOKEN" ]
}

init_users_file() {
    [ -f "$BOT_USERS_FILE" ] || echo '{"users":[]}' > "$BOT_USERS_FILE"
}

# ---------- 用户状态管理 ----------

get_user() {
    local chat_id=$1
    jq -r --argjson c "$chat_id" '.users[] | select(.chat_id == $c)' "$BOT_USERS_FILE" 2>/dev/null
}

save_user() {
    local chat_id=$1 port=$2 changes=$3 state=$4
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp
    tmp=$(mktemp)
    jq --argjson c "$chat_id" 'del(.users[] | select(.chat_id == $c))' "$BOT_USERS_FILE" > "$tmp" && mv "$tmp" "$BOT_USERS_FILE"
    # port 可能是 null 字符串（未绑定）
    local port_json
    if [ -z "$port" ] || [ "$port" = "null" ]; then
        port_json="null"
    else
        port_json="$port"
    fi
    local entry
    entry=$(jq -n \
        --argjson c "$chat_id" \
        --argjson p "$port_json" \
        --argjson ch "$changes" \
        --arg s "$state" \
        --arg t "$now" \
        '{chat_id:$c, port:$p, changes_used:$ch, state:$s, updated_at:$t}')
    tmp=$(mktemp)
    jq ".users += [$entry]" "$BOT_USERS_FILE" > "$tmp" && mv "$tmp" "$BOT_USERS_FILE"
}

# ---------- 端口信息读取 ----------

# 检查端口是否在 trafficcop 端口列表中
port_is_configured() {
    [ -f "$PORT_CONFIG_FILE" ] || return 1
    local c
    c=$(jq -r --argjson p "$1" '.ports[] | select(.port == $p) | .port' "$PORT_CONFIG_FILE" 2>/dev/null | wc -l)
    [ "$c" -gt 0 ]
}

get_port_config_json() {
    jq -r --argjson p "$1" '.ports[] | select(.port == $p)' "$PORT_CONFIG_FILE" 2>/dev/null
}

get_speed_limit_json() {
    [ -f "$SPEED_CONFIG_FILE" ] || return
    jq -r --argjson p "$1" '.limits[] | select(.port == $p)' "$SPEED_CONFIG_FILE" 2>/dev/null
}

# 计算到期日期（下一周期起始）
compute_expiry() {
    local period=$1 start_day=$2
    local today_y today_m today_d
    today_y=$(date '+%Y')
    today_m=$(date '+%m')
    today_d=$(date '+%d')
    today_m=${today_m#0}
    today_d=${today_d#0}
    [ -z "$start_day" ] || [ "$start_day" = "null" ] && start_day=1

    case "$period" in
        monthly)
            if [ "$today_d" -lt "$start_day" ]; then
                printf "%04d-%02d-%02d" "$today_y" "$today_m" "$start_day"
            else
                local next_m=$((today_m + 1))
                local next_y=$today_y
                if [ "$next_m" -gt 12 ]; then next_m=1; next_y=$((today_y + 1)); fi
                printf "%04d-%02d-%02d" "$next_y" "$next_m" "$start_day"
            fi
            ;;
        quarterly)
            local q_start_m=$(( ((today_m - 1) / 3) * 3 + 1 ))
            local next_q=$((q_start_m + 3))
            local next_y=$today_y
            if [ "$next_q" -gt 12 ]; then next_q=1; next_y=$((today_y + 1)); fi
            printf "%04d-%02d-%02d" "$next_y" "$next_q" "$start_day"
            ;;
        yearly)
            local next_y=$((today_y + 1))
            printf "%04d-01-%02d" "$next_y" "$start_day"
            ;;
        *)
            echo "未知"
            ;;
    esac
}

# 通过 port_traffic_limit.sh 内的函数计算当前流量使用（inline 复用逻辑）
get_port_usage_gb() {
    local port=$1
    local in_bytes=0
    in_bytes=$(iptables -L ufw-before-input -v -n -x 2>/dev/null | grep "dpt:$port" | awk '{sum+=$2} END {printf "%.0f", sum+0}')
    if [ -z "$in_bytes" ] || [ "$in_bytes" = "0" ]; then
        in_bytes=$(iptables -L INPUT -v -n -x 2>/dev/null | grep "dpt:$port" | awk '{sum+=$2} END {printf "%.0f", sum+0}')
    fi
    [ -z "$in_bytes" ] && in_bytes=0
    local in_gb
    in_gb=$(printf "%.2f" "$(echo "scale=4; $in_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")")
    local total_gb
    total_gb=$(printf "%.2f" "$(echo "scale=4; $in_gb * 2" | bc 2>/dev/null || echo "0")")
    echo "$in_gb $in_gb $total_gb"
}

# ---------- 消息构造 ----------

build_status_message() {
    local port=$1
    local cfg
    cfg=$(get_port_config_json "$port")
    if [ -z "$cfg" ]; then
        echo "❌ 端口 $port 未在 TrafficCop 中配置，无法查询。请联系管理员。"
        return
    fi

    local desc limit tolerance period start_day mode trigger_limit_mode trigger_speed
    desc=$(echo "$cfg" | jq -r '.description // "-"')
    limit=$(echo "$cfg" | jq -r '.traffic_limit // 0')
    tolerance=$(echo "$cfg" | jq -r '.traffic_tolerance // 0')
    period=$(echo "$cfg" | jq -r '.traffic_period // "monthly"')
    start_day=$(echo "$cfg" | jq -r '.period_start_day // 1')
    mode=$(echo "$cfg" | jq -r '.traffic_mode // "total"')
    trigger_limit_mode=$(echo "$cfg" | jq -r '.limit_mode // "tc"')
    trigger_speed=$(echo "$cfg" | jq -r '.limit_speed // 0')

    local usage in_gb out_gb total_gb
    usage=$(get_port_usage_gb "$port")
    in_gb=$(echo "$usage" | awk '{print $1}')
    out_gb=$(echo "$usage" | awk '{print $2}')
    total_gb=$(echo "$usage" | awk '{print $3}')

    local current
    case "$mode" in
        outbound) current=$out_gb ;;
        inbound)  current=$in_gb ;;
        total)    current=$total_gb ;;
        max)      current=$(echo "$in_gb $out_gb" | awk '{print ($1>$2)?$1:$2}') ;;
        *)        current=$total_gb ;;
    esac

    local pct="0"
    if [ "$(echo "$limit > 0" | bc 2>/dev/null)" = "1" ]; then
        pct=$(printf "%.1f" "$(echo "scale=2; $current / $limit * 100" | bc 2>/dev/null)")
    fi

    local expiry
    expiry=$(compute_expiry "$period" "$start_day")

    # 常驻限速
    local speed_info="未设置"
    local speed_cfg
    speed_cfg=$(get_speed_limit_json "$port")
    if [ -n "$speed_cfg" ]; then
        local s
        s=$(echo "$speed_cfg" | jq -r '.speed_kbit')
        if [ "$s" -ge 1000 ]; then
            speed_info="$(echo "scale=2; $s/1000" | bc) Mbit/s"
        else
            speed_info="${s} kbit/s"
        fi
    fi

    cat <<EOF
📊 端口 $port 状态（$desc）

📈 流量用量
  入站: ${in_gb} GB
  出站(估算): ${out_gb} GB
  当前(${mode}): ${current} GB / ${limit} GB (${pct}%)
  容错: ${tolerance} GB

🚦 常驻限速: ${speed_info}
⚠️ 超限动作: ${trigger_limit_mode} (超限后限速 ${trigger_speed}kbit/s)

📅 周期: ${period}（每周期 ${start_day} 日起算）
⏳ 下次重置: ${expiry}
EOF
}

build_welcome() {
    cat <<EOF
👋 欢迎使用 TrafficCop 端口监控机器人！

请直接发送你要绑定的端口号（1-65535）完成绑定。

⚠️ 绑定后最多只能更换 ${MAX_PORT_CHANGES} 次端口，请谨慎选择。

可用命令：
/start  - 开始 / 重新绑定
/status - 查看绑定端口的流量与限速
/change - 更换绑定端口（计入更换次数）
/info   - 查看绑定信息
/help   - 帮助
EOF
}

build_help() {
    cat <<EOF
📖 命令帮助

/start  - 发送后再发端口号即可绑定
/status - 查看当前绑定端口的流量用量、限速和到期时间
/change - 请求更换端口（消耗 1 次更换机会，最多 ${MAX_PORT_CHANGES} 次）
/info   - 查看当前绑定的端口与剩余更换次数
/help   - 显示此帮助
EOF
}

# ---------- Telegram API ----------

tg_send() {
    local chat_id=$1 text=$2
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" >/dev/null
}

tg_get_updates() {
    local offset=$1
    curl -s --max-time 35 \
        "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=30&offset=${offset}"
}

# ---------- 主逻辑 ----------

handle_message() {
    local chat_id=$1 text=$2

    init_users_file
    local user
    user=$(get_user "$chat_id")
    local port_bound changes_used state
    if [ -z "$user" ]; then
        port_bound="null"
        changes_used=0
        state="new"
    else
        port_bound=$(echo "$user" | jq -r '.port')
        changes_used=$(echo "$user" | jq -r '.changes_used')
        state=$(echo "$user" | jq -r '.state')
    fi

    case "$text" in
        /start|"/start@"*)
            save_user "$chat_id" "$port_bound" "$changes_used" "awaiting_port_initial"
            tg_send "$chat_id" "$(build_welcome)"
            ;;

        /help|"/help@"*)
            tg_send "$chat_id" "$(build_help)"
            ;;

        /info|"/info@"*)
            if [ "$port_bound" = "null" ] || [ -z "$port_bound" ]; then
                tg_send "$chat_id" "您尚未绑定端口，请发送 /start 开始绑定。"
            else
                local remain=$((MAX_PORT_CHANGES - changes_used))
                tg_send "$chat_id" "🔗 已绑定端口：${port_bound}
🔁 剩余更换次数：${remain} / ${MAX_PORT_CHANGES}"
            fi
            ;;

        /status|"/status@"*)
            if [ "$port_bound" = "null" ] || [ -z "$port_bound" ]; then
                tg_send "$chat_id" "您尚未绑定端口，请发送 /start 开始绑定。"
            else
                tg_send "$chat_id" "$(build_status_message "$port_bound")"
            fi
            ;;

        /change|"/change@"*)
            if [ "$port_bound" = "null" ] || [ -z "$port_bound" ]; then
                tg_send "$chat_id" "您尚未绑定端口，请发送 /start 进行首次绑定（不计入更换次数）。"
            elif [ "$changes_used" -ge "$MAX_PORT_CHANGES" ]; then
                tg_send "$chat_id" "❌ 您已达到更换上限（${MAX_PORT_CHANGES} 次），无法再次更换端口。"
            else
                local remain=$((MAX_PORT_CHANGES - changes_used))
                save_user "$chat_id" "$port_bound" "$changes_used" "awaiting_port_change"
                tg_send "$chat_id" "请发送新的端口号（1-65535）。
⚠️ 本次更换将计入次数，当前剩余 ${remain} 次。"
            fi
            ;;

        *)
            # 非命令：可能是端口号输入
            if [ "$state" = "awaiting_port_initial" ] || [ "$state" = "awaiting_port_change" ]; then
                if [[ "$text" =~ ^[0-9]+$ ]] && [ "$text" -ge 1 ] && [ "$text" -le 65535 ]; then
                    if ! port_is_configured "$text"; then
                        tg_send "$chat_id" "❌ 端口 $text 未在 TrafficCop 中配置，无法绑定。请联系管理员或换一个端口。"
                        return
                    fi

                    local new_changes=$changes_used
                    if [ "$state" = "awaiting_port_change" ]; then
                        new_changes=$((changes_used + 1))
                    fi

                    save_user "$chat_id" "$text" "$new_changes" "idle"
                    log "chat=$chat_id 绑定端口=$text changes_used=$new_changes"

                    local remain=$((MAX_PORT_CHANGES - new_changes))
                    local hint=""
                    if [ "$state" = "awaiting_port_change" ]; then
                        hint="（已使用 ${new_changes} / ${MAX_PORT_CHANGES} 次更换，剩余 ${remain} 次）"
                    else
                        hint="（首次绑定不计入更换次数，后续最多可更换 ${MAX_PORT_CHANGES} 次）"
                    fi

                    tg_send "$chat_id" "✅ 已绑定端口 $text ${hint}

发送 /status 查看流量状态。"
                else
                    tg_send "$chat_id" "请输入有效的端口号（1-65535）。"
                fi
            else
                tg_send "$chat_id" "未识别的指令。发送 /help 查看命令列表。"
            fi
            ;;
    esac
}

poll_loop() {
    if ! load_config; then
        log "未找到配置 $BOT_CONFIG_FILE，退出"
        exit 1
    fi
    init_users_file

    local offset=0
    [ -f "$BOT_OFFSET_FILE" ] && offset=$(cat "$BOT_OFFSET_FILE")

    log "Bot 启动，offset=$offset"

    while true; do
        local resp
        resp=$(tg_get_updates "$offset")
        if [ -z "$resp" ]; then
            sleep 2
            continue
        fi
        local ok
        ok=$(echo "$resp" | jq -r '.ok // false')
        if [ "$ok" != "true" ]; then
            log "getUpdates 失败: $(echo "$resp" | head -c 200)"
            sleep 5
            continue
        fi

        local count
        count=$(echo "$resp" | jq -r '.result | length')
        if [ "$count" -eq 0 ]; then
            continue
        fi

        local i=0
        while [ "$i" -lt "$count" ]; do
            local update_id chat_id text
            update_id=$(echo "$resp" | jq -r ".result[$i].update_id")
            chat_id=$(echo "$resp" | jq -r ".result[$i].message.chat.id // empty")
            text=$(echo "$resp" | jq -r ".result[$i].message.text // empty")

            if [ -n "$chat_id" ] && [ -n "$text" ]; then
                handle_message "$chat_id" "$text" || log "处理失败 chat=$chat_id text=$text"
            fi

            offset=$((update_id + 1))
            echo "$offset" > "$BOT_OFFSET_FILE"
            i=$((i+1))
        done
    done
}

configure_bot() {
    echo -e "${CYAN}==================== TG Bot 配置 ====================${NC}"
    local existing_token=""
    if [ -f "$BOT_CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$BOT_CONFIG_FILE"
        existing_token="$BOT_TOKEN"
    fi

    if [ -n "$existing_token" ]; then
        local t="${existing_token:0:10}...${existing_token: -4}"
        read -p "Bot Token [回车保留 $t]: " new_token
        [ -z "$new_token" ] && new_token="$existing_token"
    else
        read -p "请输入 Bot Token: " new_token
    fi

    if [ -z "$new_token" ]; then
        echo -e "${RED}Token 不能为空${NC}"
        return 1
    fi

    cat > "$BOT_CONFIG_FILE" <<EOF
# TG Bot 配置 - 由 tg_bot.sh 管理
BOT_TOKEN="$new_token"
EOF
    chmod 600 "$BOT_CONFIG_FILE"
    echo -e "${GREEN}✓ 配置已保存到 $BOT_CONFIG_FILE${NC}"
}

start_bot() {
    if [ -f "$BOT_PID_FILE" ] && kill -0 "$(cat "$BOT_PID_FILE")" 2>/dev/null; then
        echo -e "${YELLOW}Bot 已在运行 (PID=$(cat "$BOT_PID_FILE"))${NC}"
        return
    fi
    if ! load_config; then
        echo -e "${RED}未配置 Bot Token，请先选择"配置 Bot"${NC}"
        return
    fi
    nohup bash "$BOT_SCRIPT_PATH" --poll >> "$BOT_LOG_FILE" 2>&1 &
    echo $! > "$BOT_PID_FILE"
    sleep 1
    if kill -0 "$(cat "$BOT_PID_FILE")" 2>/dev/null; then
        echo -e "${GREEN}✓ Bot 已启动 (PID=$(cat "$BOT_PID_FILE"))${NC}"
    else
        echo -e "${RED}启动失败，请查看 $BOT_LOG_FILE${NC}"
    fi
}

stop_bot() {
    if [ -f "$BOT_PID_FILE" ]; then
        local pid
        pid=$(cat "$BOT_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            sleep 1
            kill -9 "$pid" 2>/dev/null
            echo -e "${GREEN}✓ Bot 已停止 (PID=$pid)${NC}"
        fi
        rm -f "$BOT_PID_FILE"
    else
        echo -e "${YELLOW}Bot 未在运行${NC}"
    fi
    # 同时清理可能的残留
    pkill -f "tg_bot.sh --poll" 2>/dev/null || true
}

bot_status() {
    if [ -f "$BOT_PID_FILE" ] && kill -0 "$(cat "$BOT_PID_FILE")" 2>/dev/null; then
        echo -e "${GREEN}运行中 (PID=$(cat "$BOT_PID_FILE"))${NC}"
    else
        echo -e "${YELLOW}未运行${NC}"
    fi
    echo ""
    echo "配置文件: $BOT_CONFIG_FILE"
    echo "日志文件: $BOT_LOG_FILE"
    echo "用户数据: $BOT_USERS_FILE"
    if [ -f "$BOT_USERS_FILE" ]; then
        local n
        n=$(jq -r '.users | length' "$BOT_USERS_FILE" 2>/dev/null || echo 0)
        echo "已绑定用户: $n"
    fi
}

setup_autostart() {
    local entry="@reboot $BOT_SCRIPT_PATH --poll >> $BOT_LOG_FILE 2>&1"
    local cur
    cur=$(crontab -l 2>/dev/null)
    if echo "$cur" | grep -Fq "$BOT_SCRIPT_PATH --poll"; then
        echo -e "${GREEN}开机自启已配置${NC}"
    else
        (echo "$cur"; echo "$entry") | crontab -
        echo -e "${GREEN}已添加开机自启任务${NC}"
    fi
}

interactive_menu() {
    while true; do
        clear
        echo -e "${CYAN}========== TrafficCop TG Bot 管理 v${SCRIPT_VERSION} ==========${NC}"
        echo "1) 配置 Bot Token"
        echo "2) 启动 Bot"
        echo "3) 停止 Bot"
        echo "4) 查看 Bot 状态"
        echo "5) 查看日志（最近 30 行）"
        echo "6) 启用开机自启"
        echo "7) 重置所有用户绑定"
        echo "0) 退出"
        echo -e "${CYAN}======================================================${NC}"
        read -p "请选择 [0-7]: " choice
        case $choice in
            1) configure_bot; read -p "按回车键继续..." _ ;;
            2) start_bot; read -p "按回车键继续..." _ ;;
            3) stop_bot; read -p "按回车键继续..." _ ;;
            4) bot_status; read -p "按回车键继续..." _ ;;
            5) tail -n 30 "$BOT_LOG_FILE" 2>/dev/null || echo "无日志"; read -p "按回车键继续..." _ ;;
            6) setup_autostart; read -p "按回车键继续..." _ ;;
            7)
                read -p "确认重置所有用户绑定？[y/N]: " c
                if [[ "$c" =~ ^[yY]$ ]]; then
                    echo '{"users":[]}' > "$BOT_USERS_FILE"
                    echo -e "${GREEN}已重置${NC}"
                fi
                read -p "按回车键继续..." _
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

main() {
    check_deps || exit 1

    case "$1" in
        --poll)
            poll_loop
            ;;
        --start)
            start_bot
            ;;
        --stop)
            stop_bot
            ;;
        --status)
            bot_status
            ;;
        "")
            interactive_menu
            ;;
        *)
            echo "用法: $0 [--poll | --start | --stop | --status]"
            exit 1
            ;;
    esac
}

main "$@"
