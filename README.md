# server-backup

将 Linux 服务器关键目录（含 PostgreSQL）每日全量备份到 Telegram 频道/群组的脚本。一份 bash 脚本 + 一份 env 配置即可工作。

## 特性

- **多目录备份** —— 一次打包 `/etc /root /opt /var/lib/docker/volumes` 等任意路径
- **PostgreSQL 自动 dump** —— 跑前先 `docker exec pg_dumpall`，避免直接 tar 物理文件导致的损坏
- **多线程压缩** —— 自动检测 `pigz`，回落 `gzip`
- **自动分卷 + 重试上传** —— 单卷 1900M（可配），失败按 5/10s 退避最多重试 3 次
- **失败保留现场** —— 未成功上传的分卷会被挪到 `failed_${DATE}/` 而非删除
- **绝对路径还原** —— 用 `tar -cpPf` 打包，恢复时一行命令直接还原到原位置
- **配置外置** —— 敏感的 TOKEN / CHAT_ID 走 `backup.env`，不进 Git

## 依赖

```bash
sudo apt install -y pv pigz curl coreutils
```

| 命令 | 用途 |
|------|------|
| `pv tar split curl du numfmt awk gzip` | 必需，主流发行版默认装 |
| `pigz` | 可选但强烈推荐，多线程压缩 |
| `docker` | 仅 `PG_DUMP_ENABLED=true` 时需要 |
| 自部署 [telegram-bot-api](https://github.com/aiogram/telegram-bot-api) | 用于绕过 Telegram 官方 50MB 文件上限 |

## 自部署 telegram-bot-api

Telegram 官方 Bot API 限制单文件上传 50MB，自部署后可上传到 2GB。`API_ID` / `API_HASH` 在 [my.telegram.org](https://my.telegram.org) 申请。

```yaml
services:
  telegram-bot-api:
    image: aiogram/telegram-bot-api:latest
    container_name: telegram-bot-api
    restart: always
    environment:
      TELEGRAM_LOCAL: true
      TELEGRAM_API_ID: "xxx"
      TELEGRAM_API_HASH: "yyy"
    volumes:
      - ./telegram-bot-api:/var/lib/telegram-bot-api
    ports:
      - 127.0.0.1:55522:8081
```

启动后将 `backup.env` 里的 `TG_API` 指向 `http://127.0.0.1:55522`，并用 `curl ${TG_API}/bot${TOKEN}/logOut` 让 Bot 从官方 API 登出，再切到本地实例即可。

## 快速开始

```bash
# 1. 克隆到目标位置
sudo git clone https://github.com/<你的用户名>/server-backup.git /server-backup
cd /server-backup

# 2. 创建并填写真实配置
sudo cp backup.env.example backup.env
sudo chmod 600 backup.env
sudo nano backup.env

# 3. 试跑
sudo /server-backup/server-backup.sh
```

## 配置项

详见 [`backup.env.example`](backup.env.example)。关键字段：

| 字段 | 必填 | 说明 |
|------|:---:|------|
| `TOKEN` | ✅ | Telegram Bot Token（[@BotFather](https://t.me/BotFather) 获取） |
| `CHAT_ID` | ✅ | 目标群组/频道 ID（负数为群组） |
| `THREAD_ID` | | 话题群的 thread id，普通群留空 |
| `TG_API` | | 本地 Bot API 反代地址，默认 `http://127.0.0.1:55522` |
| `BACKUP_NAME` | | 用于文件名，例如 `my-server` |
| `SOURCE_DIRS` | ✅ | bash 数组，列出要备份的目录 |
| `EXCLUDES` | | bash 数组，要排除的子路径 |
| `HOST_STAGING_DIR` | | 暂存目录，默认 `/backup` |
| `SPLIT_SIZE` | | 分卷大小，默认 `1900M` |
| `PG_DUMP_ENABLED` | | `true`/`false`，是否启用 PG dump |
| `PG_CONTAINER` | | PG 容器名（`docker ps` 查看） |
| `PG_USER` | | 留空则自动用容器内 `$POSTGRES_USER` |
| `PG_DUMP_PATH` | | dump 输出路径，需在 `SOURCE_DIRS` 子目录内 |

## 定时任务

```bash
sudo crontab -e
```

加入：

```cron
0 4 * * * /server-backup/server-backup.sh >> /server-backup/log/server-backup.log 2>&1
```

## 日志轮转

```bash
sudo mkdir -p /server-backup/log
sudo tee /etc/logrotate.d/server-backup > /dev/null <<'EOF'
/server-backup/log/server-backup.log {
    monthly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
```

## 恢复方法

脚本用 `tar -cpPf` 打包并保留绝对路径，恢复时直接还原到原位置。

### 文件恢复

```bash
# 多分卷
cat backup_<NAME>_<DATE>.tar.gz.part_* | gunzip | tar -xpPf -

# 单文件
gunzip -c backup_<NAME>_<DATE>.tar.gz | tar -xpPf -
```

### PostgreSQL 恢复

```bash
gunzip -c /opt/db_dump/pg_<container>_<DATE>.sql.gz \
  | docker exec -i <pg_container> psql -U postgres
```

## 目录结构

```
/server-backup/
├── server-backup.sh        # 主脚本
├── backup.env.example      # 配置模板（仓库内）
├── backup.env              # 真实配置（chmod 600，已 .gitignore）
├── log/                    # 运行日志
├── temp_<DATE>/            # 运行时暂存（成功后自动清理）
└── failed_<DATE>/          # 失败时保留的分卷
```

## 退出码

| 码 | 含义 |
|---|------|
| 0 | 全部成功 |
| 1 | 压缩 / PG dump 失败 |
| 2 | 部分分卷上传失败（残留在 `failed_<DATE>/`） |

## 故障排查

| 现象 | 原因 / 处理 |
|------|------------|
| `command not found` | Windows 编辑导致 CRLF 行尾。`sudo sed -i 's/\r$//' server-backup.sh backup.env` |
| `pg_dumpall: role "xxx" does not exist` | 真实超级用户与 `PG_USER` 不一致；留空 `PG_USER` 让脚本自动读容器内 `$POSTGRES_USER` |
| `pg_dumpall: connection failed` | 容器没设 `POSTGRES_PASSWORD`；脚本默认用 `$POSTGRES_PASSWORD`，未设置时改用 trust auth 或在 PG 中配置 .pgpass |
| 上传一直失败 | 检查 `TG_API` 反代是否可达，`curl ${TG_API}/bot${TOKEN}/getMe` 验证 |
| 压缩耗时过长 | 装 `pigz` 后会自动启用多线程 |

## License

MIT
