#!/bin/bash
#
# 配置加载顺序 (前面的优先):
#   1. 环境变量 BACKUP_CONFIG=/path/to/backup.env
#   2. 脚本同目录的 backup.env   (推荐: 和脚本一起放在 /backup/)
#   3. /etc/backup.env

set -euo pipefail

# ================= 配置加载 =================
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

if [ -n "${BACKUP_CONFIG:-}" ]; then
    CONFIG_FILE="$BACKUP_CONFIG"
elif [ -f "${SCRIPT_DIR}/backup.env" ]; then
    CONFIG_FILE="${SCRIPT_DIR}/backup.env"
else
    CONFIG_FILE="/etc/backup.env"
fi

# 显式声明数组，避免 set -u 在 source 前误报
SOURCE_DIRS=()
EXCLUDES=()
SOURCE_DIR=""

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "❌ 配置文件不存在: $CONFIG_FILE"
    exit 1
fi

# ================= 必填校验 =================
: "${TOKEN:?TOKEN 未配置 (请检查 ${CONFIG_FILE})}"
: "${CHAT_ID:?CHAT_ID 未配置}"

# 兼容旧版单目录配置
if [ "${#SOURCE_DIRS[@]}" -eq 0 ]; then
    if [ -n "$SOURCE_DIR" ]; then
        SOURCE_DIRS=("$SOURCE_DIR")
    else
        echo "❌ 必须设置 SOURCE_DIRS=(/path1 /path2 ...) 或 SOURCE_DIR=/single"
        exit 1
    fi
fi

# 默认值
THREAD_ID="${THREAD_ID:-}"
HOST_STAGING_DIR="${HOST_STAGING_DIR:-/backup}"
DOCKER_READ_PATH="${DOCKER_READ_PATH:-${HOST_STAGING_DIR}}"
SPLIT_SIZE="${SPLIT_SIZE:-1900M}"
TG_API="${TG_API:-http://127.0.0.1:55522}"
MAX_RETRY="${MAX_RETRY:-3}"
BACKUP_NAME="${BACKUP_NAME:-system}"
PG_DUMP_ENABLED="${PG_DUMP_ENABLED:-false}"

# 自动把暂存目录加入 EXCLUDES，防止套娃
EXCLUDES+=("$HOST_STAGING_DIR")

# ================= 运行时变量 =================
DATE=$(date +%Y%m%d_%H%M%S)
BASENAME="backup_${BACKUP_NAME}_${DATE}.tar.gz"
WORK_DIR="${HOST_STAGING_DIR}/temp_${DATE}"
DOCKER_WORK_DIR="${DOCKER_READ_PATH}/temp_${DATE}"
FAILED_DIR="${HOST_STAGING_DIR}/failed_${DATE}"

SUCCESS=0
cleanup() {
    if [ "$SUCCESS" -eq 1 ]; then
        rm -rf "$WORK_DIR"
        return
    fi
    if [ -d "$WORK_DIR" ] && [ -n "$(ls -A "$WORK_DIR" 2>/dev/null || true)" ]; then
        mkdir -p "$FAILED_DIR"
        mv "$WORK_DIR"/* "$FAILED_DIR"/ 2>/dev/null || true
        echo "ℹ️  残留文件已保留至: $FAILED_DIR"
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"

# ================= 依赖检查 =================
for cmd in pv tar split curl du numfmt awk; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "❌ 缺少依赖: $cmd"; exit 1; }
done

if [ "$PG_DUMP_ENABLED" = "true" ]; then
    command -v docker >/dev/null 2>&1 || { echo "❌ PG_DUMP_ENABLED=true 需要 docker 命令"; exit 1; }
fi

if command -v pigz >/dev/null 2>&1; then
    COMPRESS=pigz
    COMPRESS_LABEL="pigz (多线程)"
else
    COMPRESS=gzip
    COMPRESS_LABEL="gzip (单线程, 建议安装 pigz)"
fi

echo "-----------------------------------------------------"
echo "📋 备份任务: ${BACKUP_NAME}"
echo "📁 源目录: ${SOURCE_DIRS[*]}"
echo "🚫 排除项: ${EXCLUDES[*]}"
echo "📄 配置文件: ${CONFIG_FILE}"

# ================= [1/5] 数据库 Dump =================
if [ "$PG_DUMP_ENABLED" = "true" ]; then
    echo "[1/5] PostgreSQL Dump..."
    : "${PG_CONTAINER:?PG_DUMP_ENABLED=true 时必须设置 PG_CONTAINER}"
    PG_USER="${PG_USER:-postgres}"
    PG_DUMP_PATH="${PG_DUMP_PATH:-/opt/db_dump}"
    PG_DUMP_KEEP_DAYS="${PG_DUMP_KEEP_DAYS:-7}"

    mkdir -p "$PG_DUMP_PATH"
    PG_DUMP_FILE="${PG_DUMP_PATH}/pg_${PG_CONTAINER}_${DATE}.sql.gz"

    if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        echo "❌ PostgreSQL 容器 '${PG_CONTAINER}' 未运行"
        echo "    可用容器: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
        exit 1
    fi

    echo -n "   -> dump → ${PG_DUMP_FILE} ... "
    set +e
    docker exec "$PG_CONTAINER" pg_dumpall -U "$PG_USER" 2>/dev/null | gzip > "$PG_DUMP_FILE"
    PG_PIPE_STATUS=("${PIPESTATUS[@]}")
    set -e

    if [ "${PG_PIPE_STATUS[0]}" -ne 0 ] || [ "${PG_PIPE_STATUS[1]}" -ne 0 ]; then
        echo "❌"
        rm -f "$PG_DUMP_FILE"
        echo "❌ pg_dumpall 失败 (状态: ${PG_PIPE_STATUS[*]})"
        exit 1
    fi

    DUMP_SIZE=$(du -h "$PG_DUMP_FILE" | awk '{print $1}')
    echo "✅ ${DUMP_SIZE}"

    # 清理超过 N 天的旧 dump
    find "$PG_DUMP_PATH" -name "pg_${PG_CONTAINER}_*.sql.gz" -mtime "+${PG_DUMP_KEEP_DAYS}" -delete 2>/dev/null || true
else
    echo "[1/5] 数据库 Dump: 跳过 (PG_DUMP_ENABLED=false)"
fi

# ================= [2/5] 计算大小 =================
echo "[2/5] 计算源目录大小..."
EXCLUDE_ARGS=()
for ex in "${EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$ex")
done

TOTAL_SIZE=$(du -sb "${EXCLUDE_ARGS[@]}" "${SOURCE_DIRS[@]}" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
HUMAN_SIZE=$(numfmt --to=iec-i --suffix=B "$TOTAL_SIZE")
echo "📊 源目录总大小: ${HUMAN_SIZE}"
echo "🗜  压缩工具: ${COMPRESS_LABEL}"

# ================= [3/5] 压缩 + 分卷 =================
echo "[3/5] 开始压缩并分卷..."

# -P 保留绝对路径，恢复时 tar -xpPf 可一键还原到原位置
set +e
tar -cpPf - "${EXCLUDE_ARGS[@]}" "${SOURCE_DIRS[@]}" 2>/dev/null \
  | pv -s "${TOTAL_SIZE}" -N "🚀 压缩进度" \
  | "$COMPRESS" \
  | split -b "${SPLIT_SIZE}" -d - "${WORK_DIR}/${BASENAME}.part_"
PIPE_STATUSES=("${PIPESTATUS[@]}")
set -e

for s in "${PIPE_STATUSES[@]}"; do
    if [ "$s" -ne 0 ]; then
        echo "❌ 压缩管道失败 (状态: ${PIPE_STATUSES[*]})"
        exit 1
    fi
done
echo ""
echo "✅ 压缩完成"

# 收集分卷
mapfile -t PART_FILES < <(cd "$WORK_DIR" && ls -1 "${BASENAME}.part_"* 2>/dev/null | sort)
COUNT=${#PART_FILES[@]}

if [ "$COUNT" -eq 0 ]; then
    echo "❌ 未生成任何分卷文件"
    exit 1
fi

if [ "$COUNT" -eq 1 ]; then
    mv "${WORK_DIR}/${PART_FILES[0]}" "${WORK_DIR}/${BASENAME}"
    PART_FILES=("${BASENAME}")
    echo "ℹ️  单文件模式: 已移除 .part_00 后缀"
else
    echo "ℹ️  多文件模式: 共 ${COUNT} 个分卷"
fi

# ================= [4/5] 上传 =================
echo "[4/5] 开始上传到 Telegram (共 ${COUNT} 个文件)..."

upload_one() {
    local docker_path="$1" caption="$2"
    local resp http body
    resp=$(curl -sS --max-time 1800 -w $'\n%{http_code}' \
        "${TG_API}/bot${TOKEN}/sendDocument" \
        -F "chat_id=${CHAT_ID}" \
        ${THREAD_ID:+-F "message_thread_id=${THREAD_ID}"} \
        -F "document=file://${docker_path}" \
        -F "caption=${caption}" 2>&1) || return 1
    http=$(printf '%s\n' "$resp" | tail -n1)
    body=$(printf '%s\n' "$resp" | sed '$d')
    [[ "$http" == "200" && "$body" == *'"ok":true'* ]]
}

FAILED_COUNT=0
CURRENT_INDEX=1
for FILE in "${PART_FILES[@]}"; do
    FULL_LOCAL_PATH="${WORK_DIR}/${FILE}"
    FULL_DOCKER_PATH="${DOCKER_WORK_DIR}/${FILE}"
    FILE_SIZE=$(du -h "$FULL_LOCAL_PATH" | awk '{print $1}')

    CAPTION_TEXT="📦 ${BACKUP_NAME} | (${CURRENT_INDEX}/${COUNT})
文件: ${FILE} | 大小: ${FILE_SIZE}"

    echo -n "   -> [${CURRENT_INDEX}/${COUNT}] ${FILE} (${FILE_SIZE})... "

    OK=0
    for ((try=1; try<=MAX_RETRY; try++)); do
        if upload_one "$FULL_DOCKER_PATH" "$CAPTION_TEXT"; then
            OK=1
            break
        fi
        if [ "$try" -lt "$MAX_RETRY" ]; then
            echo -n "重试 $((try+1))/${MAX_RETRY}... "
            sleep $((try * 5))
        fi
    done

    if [ "$OK" -eq 1 ]; then
        echo "✅"
        rm -f "$FULL_LOCAL_PATH"
    else
        echo "❌ (已重试 ${MAX_RETRY} 次)"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi

    CURRENT_INDEX=$((CURRENT_INDEX + 1))
done

# ================= [5/5] 收尾 =================
echo "[5/5] 收尾..."
if [ "$FAILED_COUNT" -eq 0 ]; then
    SUCCESS=1
    echo "🎉 全部完成 (${COUNT}/${COUNT})"
    echo "-----------------------------------------------------"
    exit 0
else
    echo "⚠️  完成但有失败: 成功 $((COUNT - FAILED_COUNT))/${COUNT}, 失败 ${FAILED_COUNT}"
    echo "   未上传成功的分卷会被 trap 转移到: ${FAILED_DIR}"
    echo "-----------------------------------------------------"
    exit 2
fi
