#!/bin/bash

# ================= 配置区域 =================
TOKEN="8205616130:AAHjN8x10FTvE2UR1t8LwCA7IUjp5Fw5XFM"
CHAT_ID="-1003566077984"
THREAD_ID="2"

SOURCE_DIR="/opt"
HOST_STAGING_DIR="/backup"
DOCKER_READ_PATH="/backup"

DATE=$(date +%Y%m%d_%H%M%S)
BASENAME="backup_opt_${DATE}.tar.gz"

# 分卷大小
SPLIT_SIZE="1900M"

WORK_DIR="${HOST_STAGING_DIR}/temp_${DATE}"
mkdir -p "$WORK_DIR"
DOCKER_WORK_DIR="${DOCKER_READ_PATH}/temp_${DATE}"
# ===========================================

if ! command -v pv &> /dev/null; then
    echo "❌ 错误: pv 未安装"
    exit 1
fi

echo "-----------------------------------------------------"
echo "[1/4] 计算源目录大小..."
TOTAL_SIZE=$(du -sb "${SOURCE_DIR}" --exclude="${HOST_STAGING_DIR}" 2>/dev/null | awk '{print $1}')
HUMAN_SIZE=$(numfmt --to=iec-i --suffix=B "$TOTAL_SIZE")
echo "📊 源目录总大小: ${HUMAN_SIZE}"

echo "[2/4] 开始压缩 (Gzip) 并分卷..."
tar -cf - "${SOURCE_DIR}" --exclude="${HOST_STAGING_DIR}" 2> /dev/null \
  | pv -s ${TOTAL_SIZE} -N "🚀 压缩进度" \
  | gzip \
  | split -b ${SPLIT_SIZE} -d - "${WORK_DIR}/${BASENAME}.part_"

echo "" 
echo "✅ 压缩处理完成！"

# 获取文件列表
PART_FILES=$(ls "${WORK_DIR}" | grep "${BASENAME}.part_")
if [ -z "$PART_FILES" ]; then
    echo "❌ 错误: 未生成文件"
    rm -rf "$WORK_DIR"
    exit 1
fi

# ================= 智能重命名 =================
COUNT=$(echo "$PART_FILES" | wc -l)
PART_FILES=$(echo "$PART_FILES" | sort)

if [ "$COUNT" -eq 1 ]; then
    SINGLE_FILE=$(echo "$PART_FILES" | tr -d '[:space:]')
    mv "${WORK_DIR}/${SINGLE_FILE}" "${WORK_DIR}/${BASENAME}"
    PART_FILES="${BASENAME}"
    echo "ℹ️  单文件模式: 已移除 .part_00 后缀"
else
    echo "ℹ️  多文件模式: 共 ${COUNT} 个分卷"
fi
# ============================================

echo "[3/4] 开始上传到 Telegram (共 ${COUNT} 个文件)..."

CURRENT_INDEX=1

for FILE in $PART_FILES; do
    FULL_LOCAL_PATH="${WORK_DIR}/${FILE}"
    FULL_DOCKER_PATH="${DOCKER_WORK_DIR}/${FILE}"
    FILE_SIZE=$(ls -lh "$FULL_LOCAL_PATH" | awk '{print $5}')
    
    # 构造进度 (例如: (1/3))
    PROGRESS_STR="(${CURRENT_INDEX}/${COUNT})"
    
    # 构造换行的消息内容
    # 注意：下面的双引号之间真的有一个换行，不要删掉它
    CAPTION_TEXT="📦 标准备份 | ${PROGRESS_STR}
文件: ${FILE} | 大小: ${FILE_SIZE}"
    
    echo -n "   -> [${CURRENT_INDEX}/${COUNT}] 上传: ${FILE} (${FILE_SIZE})... "
    
    RESPONSE=$(curl -s "http://127.0.0.1:55522/bot${TOKEN}/sendDocument" \
        -F "chat_id=${CHAT_ID}" \
        -F "message_thread_id=${THREAD_ID}" \
        -F "document=file://${FULL_DOCKER_PATH}" \
        -F "caption=${CAPTION_TEXT}")

    if [[ "$RESPONSE" == *'"ok":true'* ]]; then
        echo "✅ 成功"
        rm -f "$FULL_LOCAL_PATH"
    else
        echo "❌ 失败"
        echo "      $RESPONSE"
    fi
    
    ((CURRENT_INDEX++))
done

echo "[4/4] 清理环境..."
rm -rf "$WORK_DIR"
echo "🎉 全部完成！"
echo "-----------------------------------------------------"