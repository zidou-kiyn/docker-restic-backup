# docker-restic-backup

单机 Docker 服务的 restic 备份脚本：**逐项目停机 → restic 增量备份 → 立即拉起**，再备份宿主机配置，
按策略保留，Telegram 汇报。零配置发现项目和容器，密钥与机器相关配置全部在 git 之外。

```
✅ 停机 104s +61MB  game-panel
✅ 停机 24s +1.1MB  git
✅ 停机 40s +409MB  monitoring
…
✅ 服务停 23s +39MB  host
— 总耗时 18m43s，restic 新增 543MB，forget✅
```

## 设计

| 概念 | 规则 |
|---|---|
| 项目 | `SERVICE_ROOT/<一级目录>`，每个目录一个 restic 快照（tag `docker,<项目名>`） |
| 项目的容器 | compose 容器按 `working_dir` 归属（含子目录）；非 compose 容器按 bind mount 来源归属 |
| 停机 | `compose stop` / `docker stop`（不 down、不重建，网络和匿名卷都保留）；备份完 `start` |
| AutoRemove 容器 | 面板托管的实例（`--rm`）停止后由其管理器重建，脚本只等待它回来（`MANAGED_WAIT_MAX`） |
| 兜底 | `trap EXIT`：脚本无论怎么退出，已停的容器/服务都会被拉起 |
| host 组 | `HOST_PATHS`（`/etc /root …`）+ 本脚本目录 + `SERVICE_ROOT` 顶层散文件，tag `host`；可先停面板等服务 |
| PVE | 检测到 `/var/lib/pve-cluster/config.db` 时用 sqlite `.backup` 做一致快照并纳入 host 组 |
| 保留 | `restic forget --group-by host,tags`（每个项目独立计数）；周日 `prune` + `check --read-data-subset=5%` |
| 钩子 | `hooks/<项目>.pre-stop` 可拒绝停机（见 `hooks/README.md`） |
| 通知 | `notify.sh`：Telegram，失败只写 syslog、永远 exit 0 |

## 不停机备份（HOT_BACKUP=1，默认）

备份前 `hotsnap.py` 自动识别项目里「热拷不一致」的数据并导出一致副本，容器**不停**：

| 数据 | 识别 | 导出 |
|---|---|---|
| PostgreSQL / MySQL·MariaDB / MongoDB | 容器镜像名 | `pg_dumpall` / `mysqldump --single-transaction` / `mongodump` |
| Redis / Valkey | 镜像名 | `BGSAVE` 完成后拷 `dump.rdb` |
| Minecraft（itzg 镜像） | 镜像名 | RCON `save-off` + `save-all flush`，restic 期间保持 save-off，备份完 `save-on`（玩家不掉线） |
| SQLite | 文件头 `SQLite format 3`（不看扩展名） | python sqlite3 在线备份 API |
| 其他文件 | — | 直接热拷（配置、上传、日志） |
| **无法识别的数据库**（LevelDB/H2/influx/es…） | 文件特征 | **该项目自动退回停机备份**并发 TG；可丢的加 `HOT_IGNORE`，必须停机的加 `HOT_FORCE_STOP` |

一致副本以 bind mount 挂到 `<项目>/.hotsnap`，restic 快照里的路径是 `/docker/service/<项目>/.hotsnap/…`（原始数据库文件被排除），
旁边有 `RESTORE.md` 写明每个库怎么导回。快照 tag 多一个 `hot`。
`HOT_BACKUP=0` 回到旧的停机流程。

日志建议**全部备份**（不要排除 `logs/`）：增量很小，而且 restic 里的副本是入侵者删不掉的取证材料；`excludes.txt` 只放 cache/tmp 这类真正的临时数据。

## 安装

```bash
apt install restic rclone python3 sqlite3        # sqlite3 仅 PVE 需要
git clone <repo> /opt/docker-restic-backup       # 放哪都行；默认 SERVICE_ROOT = 上一级目录
cd /opt/docker-restic-backup
cp .env.example .env && chmod 600 .env           # 填 RESTIC_REPOSITORY / TG_*
head -c 32 /dev/urandom | base64 > .restic-pass && chmod 600 .restic-pass   # 离线另存一份！
cp backup.conf.example backup.conf               # SERVICE_ROOT、HOST_PATHS、要停的服务……
cp excludes.txt.example excludes.txt
set -a; . ./.env; set +a; restic init            # 新仓库；复用现有仓库则跳过
./backup.sh --dry-run                            # 看项目/容器发现是否符合预期
./backup.sh --seed                               # 首次播种：不停任何容器，先把大头传上去
./backup.sh --only <某个小项目>                    # 验证一次完整的 停→备→启
crontab -e                                       # 见 cron.example
```

## 模式

| 命令 | 行为 |
|---|---|
| `backup.sh` | 全量流程：项目（按 `PRIORITY` 先后）→ host → forget →（周日）prune/check → TG 汇总 |
| `backup.sh --seed` | 不停任何容器/服务，只做 restic backup。首次或大改后用 |
| `backup.sh --only <项目\|host>` | 只处理一个项目，不做 forget/prune。测试用 |
| `backup.sh --dry-run` | 只打印发现结果，不做任何改动 |

## 恢复

```bash
set -a; . /opt/docker-restic-backup/.env; set +a
restic snapshots --compact                         # 找快照
restic restore <id> --target /tmp/r --include /docker/service/<项目>   # 恢复到临时目录再挪
restic mount /mnt/restic                           # 或直接挂载浏览
```

## 多机共用一个仓库

`HOST_TAG`（默认 `hostname -s`）会写入 restic `--host`，forget 也按 host 分组，因此多台机器可以指向同一个仓库、
共享去重，互不影响保留策略。

## pve/（可选）

Proxmox VE 的 vzdump 配套：目标存储是 rclone 挂载的云盘时，检查挂载、记录归档、在 VFS 写回完成后核对远端大小并 TG 汇报。
见 `pve/README.md`。

## 文件

```
backup.sh            主脚本（默认值在「配置区」，勿直接改；用 backup.conf 覆盖）
notify.sh            Telegram 通知
backup.conf.example  机器相关配置模板 → backup.conf（不入 git）
.env.example         密钥模板 → .env（不入 git）
excludes.txt.example 项目内排除模板 → excludes.txt（不入 git）
hooks/               项目 pre-stop 钩子
pve/                 vzdump hook（可选）
cron.example
```
