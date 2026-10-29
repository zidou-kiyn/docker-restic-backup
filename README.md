# docker-restic-backup

单机 Docker 服务的 restic 备份：**不停机、自动识别数据库、按项目增量、Telegram / 企业微信汇报**。
零配置发现项目与容器；密钥和机器相关配置全部在 git 之外。

```
✅ 热备 33s +2.2MB   npm
✅ 热备 31s +18MB    mcsm          ← Minecraft：RCON flush，玩家不掉线
✅ 热备 34s +22MB    sub2api       ← PostgreSQL + Redis 一致导出
✅ 服务停 26s +97MB   host
— 总耗时 6m12s，restic 新增 140MB，forget✅
```

## 工作方式

| | |
|---|---|
| **项目** | `SERVICE_ROOT/<目录>` = 一个项目 = 一个 restic 快照（tag `docker,<项目>,hot`） |
| **容器归属** | compose 容器按 `working_dir`；非 compose 容器按 bind mount 来源 |
| **不停机** | 备份前 `hotsnap.py` 自动识别并导出一致副本：PostgreSQL / MySQL·MariaDB / MongoDB → dump，Redis → `BGSAVE`，SQLite → 在线备份 API，Minecraft → RCON `save-off`+`flush`；其余文件直接热拷 |
| **兜底** | 识别不了的数据库（LevelDB、H2、ES…）→ **该项目自动退回停机备份**并告警，不会产生"看着成功其实坏了"的快照 |
| **host 组** | `/etc /root /usr/local/{s,}bin /var/spool/cron` + 本目录 + 可选面板目录；PVE 的 `config.db` 自动做一致快照 |
| **保留** | `restic forget --group-by host,tags`（每个项目独立计数）；周日 `prune` + `check --read-data-subset=5%` |
| **通知** | `notify.sh` → Telegram（HTML）或企业微信群机器人（纯文本，按 .env 自动选）；失败只写 syslog，永远 exit 0 |

详细规则：[docs/hot-backup.md](docs/hot-backup.md) · 恢复：[docs/restore.md](docs/restore.md)

## 安装

```bash
apt install restic rclone python3
git clone <repo> /docker/service/backup          # 默认 SERVICE_ROOT = 上一级目录
cd /docker/service/backup
cp .env.example .env && chmod 600 .env           # RESTIC_REPOSITORY / TG_*
head -c 32 /dev/urandom | base64 > .restic-pass && chmod 600 .restic-pass   # 离线另存一份
cp backup.conf.example backup.conf               # 机器相关：HOST_PATHS、要停的面板服务……
cp excludes.txt.example excludes.txt
set -a; . ./.env; set +a; restic init
./backup.sh --dry-run                            # 核对项目/容器发现结果
./backup.sh --only <小项目>                       # 验证一次完整流程
crontab -e                                       # 见 cron.example
```

## 命令

| 命令 | 行为 |
|---|---|
| `backup.sh` | 全量：项目（按 `PRIORITY`）→ host → forget →（周日）prune/check → TG 汇总 |
| `backup.sh --only <项目\|host>` | 只处理一个项目；不做 forget/prune |
| `backup.sh --seed` | 不停任何容器、不做 hotsnap，只 restic。首次播种大目录用 |
| `backup.sh --dry-run` | 只打印发现结果 |

## 配置

| 文件 | 内容 | git |
|---|---|---|
| `backup.conf` | 机器相关覆盖：`SERVICE_ROOT` `HOST_PATHS` `HOST_SERVICES_TO_STOP` `HOT_IGNORE` `HOT_FORCE_STOP` `KEEP_ARGS`… | ✗ |
| `.env` | `RESTIC_REPOSITORY` `RESTIC_PASSWORD_FILE` `RCLONE_CONFIG` `TG_*` | ✗ |
| `excludes.txt` | 项目内排除（只放 cache/tmp 这类临时数据；**日志建议保留**——restic 里的副本是入侵者删不掉的取证材料） | ✗ |
| `hooks/<项目>.pre-stop` | 项目级断言，非 0 退出则跳过该项目（[hooks/README.md](hooks/README.md)） | ✗ |

所有可调项及默认值见 `backup.conf.example`。

## 附带

- `pve/` — Proxmox vzdump 到 rclone 云盘的配套：挂载检查 + 上传完成校验。见 [docs/pve.md](docs/pve.md)
- `cron.example` — 定时与日志轮转

## 多机共用仓库

`HOST_TAG`（默认 `hostname -s`）写入 restic `--host`，forget 按 host 分组：多台机器可指向同一仓库共享去重，保留策略互不影响。
