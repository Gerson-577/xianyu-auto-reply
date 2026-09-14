#!/bin/bash
# ==========================================
# 闲鱼自动回复系统 - 本地一键启停脚本
#
# 用法:
#   bash start_local.sh            # 启动全部服务（默认）
#   bash start_local.sh start      # 同上
#   bash start_local.sh stop       # 停止全部服务
#   bash start_local.sh restart    # 重启全部服务
#   bash start_local.sh status     # 查看各服务状态
#   bash start_local.sh logs       # 实时查看全部日志
#
# 说明:
#   1. 依赖本机已运行的 MySQL(3306) / Redis(6379)
#   2. 自动探测各虚拟环境的 certifi 证书并设置 SSL_CERT_FILE，
#      解决 python.org 版 Python 缺少根证书导致的 SSL 验证失败
#   3. 日志输出到 logs/local/ 目录
# ==========================================

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$ROOT/logs/local"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 服务定义: 名称|目录|端口
SERVICES=(
    "backend-web|backend-web|8089"
    "websocket|websocket|8090"
    "scheduler|scheduler|8091"
)

mkdir -p "$LOG_DIR"

# 获取指定服务虚拟环境的 certifi 证书路径
cert_of() {
    "$ROOT/$1/.venv/bin/python" -c "import certifi; print(certifi.where())" 2>/dev/null
}

# 检查端口是否在监听
port_up() {
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

# 等待端口就绪（每 2 秒探测一次，默认最多等 120 秒）
# 用于开机自启场景：MySQL/Redis 由 brew services 托管，
# 与本脚本同为 LaunchAgent，启动顺序不保证，需要等待
wait_for_port() {
    local port=$1 tries=${2:-60}
    for _ in $(seq 1 "$tries"); do
        if port_up "$port"; then return 0; fi
        sleep 2
    done
    return 1
}

# 停止占用指定端口的进程
kill_port() {
    local pids
    pids=$(lsof -ti :"$1" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill 2>/dev/null || true
        return 0
    fi
    return 1
}

# 等待端口就绪
wait_port() {
    local port=$1 name=$2 tries=${3:-40}
    for _ in $(seq 1 "$tries"); do
        if port_up "$port"; then return 0; fi
        sleep 1
    done
    echo -e "${RED}✗ $name 启动超时（端口 $port 未监听），请查看 $LOG_DIR/$name.log${NC}"
    return 1
}

precheck() {
    echo -e "${CYAN}[检查] 基础服务...${NC}"
    if ! port_up 3306; then
        echo -e "${YELLOW}· MySQL(3306) 未就绪，等待中（最多 120 秒）...${NC}"
        if ! wait_for_port 3306; then
            echo -e "${RED}✗ MySQL(3306) 等待超时，请先启动: brew services start mysql${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}✓ MySQL(3306)${NC}"

    if ! port_up 6379; then
        echo -e "${YELLOW}· Redis(6379) 未就绪，等待中（最多 120 秒）...${NC}"
        if ! wait_for_port 6379; then
            echo -e "${RED}✗ Redis(6379) 等待超时，请先启动: brew services start redis${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}✓ Redis(6379)${NC}"
    echo ""
}

start_python_service() {
    local name=$1 dir=$2 port=$3
    if port_up "$port"; then
        echo -e "${YELLOW}· $name 已在运行($port)，跳过${NC}"
        return 0
    fi
    local cert
    cert=$(cert_of "$dir")
    if [ -z "$cert" ]; then
        echo -e "${RED}✗ $name 虚拟环境缺失，请先: cd $dir && python3 -m venv .venv && ./.venv/bin/pip install -e .${NC}"
        return 1
    fi
    echo -e "${CYAN}▶ 启动 $name ($port)...${NC}"
    ( cd "$ROOT/$dir" && SSL_CERT_FILE="$cert" nohup ./.venv/bin/python main.py >> "$LOG_DIR/$name.log" 2>&1 & )
    wait_port "$port" "$name"
    echo -e "${GREEN}✓ $name 已就绪${NC}"
}

start_frontend() {
    if port_up 9000; then
        echo -e "${YELLOW}· frontend 已在运行(9000)，跳过${NC}"
        return 0
    fi
    if [ ! -d "$ROOT/frontend/node_modules" ]; then
        echo -e "${RED}✗ frontend 依赖缺失，请先: cd frontend && npm install${NC}"
        return 1
    fi
    echo -e "${CYAN}▶ 启动 frontend (9000)...${NC}"
    ( cd "$ROOT/frontend" && nohup npm run dev >> "$LOG_DIR/frontend.log" 2>&1 & )
    wait_port 9000 "frontend"
    echo -e "${GREEN}✓ frontend 已就绪${NC}"
}

do_start() {
    precheck
    for svc in "${SERVICES[@]}"; do
        IFS='|' read -r name dir port <<< "$svc"
        start_python_service "$name" "$dir" "$port"
    done
    start_frontend
    echo ""
    echo -e "${GREEN}=========================================="
    echo "  全部服务已启动"
    echo "==========================================${NC}"
    echo "  前端:        http://localhost:9000"
    echo "  Backend-Web: http://localhost:8089"
    echo "  WebSocket:   http://localhost:8090"
    echo "  Scheduler:   http://localhost:8091"
    echo "  默认账号:    admin / admin123"
    echo "  日志目录:    $LOG_DIR"
    echo ""
}

do_stop() {
    echo -e "${CYAN}[停止] 全部服务...${NC}"
    for p in 9000 8089 8090 8091; do
        if kill_port "$p"; then
            echo -e "${GREEN}✓ 已停止端口 $p${NC}"
        else
            echo -e "· 端口 $p 无进程"
        fi
    done
    echo -e "${GREEN}✓ 已全部停止（MySQL / Redis 不受影响）${NC}"
}

do_status() {
    printf "%-14s %-8s %s\n" "服务" "端口" "状态"
    echo "-----------------------------------"
    for svc in "${SERVICES[@]}"; do
        IFS='|' read -r name dir port <<< "$svc"
        if port_up "$port"; then
            printf "%-14s %-8s ${GREEN}%s${NC}\n" "$name" "$port" "running"
        else
            printf "%-14s %-8s ${RED}%s${NC}\n" "$name" "$port" "stopped"
        fi
    done
    if port_up 9000; then
        printf "%-14s %-8s ${GREEN}%s${NC}\n" "frontend" "9000" "running"
    else
        printf "%-14s %-8s ${RED}%s${NC}\n" "frontend" "9000" "stopped"
    fi
    echo "-----------------------------------"
    if port_up 3306; then printf "%-14s %-8s ${GREEN}%s${NC}\n" "mysql" "3306" "running"; else printf "%-14s %-8s ${RED}%s${NC}\n" "mysql" "3306" "stopped"; fi
    if port_up 6379; then printf "%-14s %-8s ${GREEN}%s${NC}\n" "redis" "6379" "running"; else printf "%-14s %-8s ${RED}%s${NC}\n" "redis" "6379" "stopped"; fi
}

CMD="${1:-start}"
case "$CMD" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; sleep 2; do_start ;;
    status)  do_status ;;
    logs)    tail -f "$LOG_DIR"/*.log ;;
    *)
        echo "用法: bash $0 [start|stop|restart|status|logs]"
        exit 1
        ;;
esac
