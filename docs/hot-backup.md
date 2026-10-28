# 不停机备份（hotsnap）

`backup.sh` 在 `HOT_BACKUP=1`（默认）时，对每个项目先调用 `hotsnap.py <项目目录> <快照目录>`，再 restic。
容器全程不停。

## 识别与导出

| 数据 | 识别依据 | 导出方式 | 产物 |
|---|---|---|---|
| PostgreSQL（含 postgis/timescale/pgvector） | 容器镜像名 | `pg_dumpall --clean --if-exists`（用 `POSTGRES_USER`） | `pg-<容器>.sql.gz` |
| MySQL / MariaDB / Percona | 镜像名 | `mysqldump --single-transaction --all-databases --routines --triggers --events`（用 `MYSQL_ROOT_PASSWORD`） | `mysql-<容器>.sql.gz` |
| Redis / Valkey | 镜像名 | `BGSAVE` → 等 `LASTSAVE` 推进 → 拷 `dump.rdb`（支持 `REDIS_PASSWORD` / `REDISCLI_AUTH`） | `redis-<容器>.rdb` |
| MongoDB | 镜像名 | `mongodump --archive --gzip` | `mongo-<容器>.archive.gz` |
| Minecraft（itzg 镜像） | 镜像名 | `rcon-cli save-off` → `save-all flush`；restic 期间保持 save-off；备份完 `save-on`（trap 兜底） | 存档目录直接热拷 |
| SQLite | 文件头 `SQLite format 3`（**不看扩展名**） | python `sqlite3.Connection.backup()` | `sqlite/<相对路径>` |
| 其他文件 | — | restic 直接热拷 | — |

导出的一致副本以 bind mount 挂到 `<项目>/.hotsnap`，所以 restic 快照里的路径是
`/docker/service/<项目>/.hotsnap/…`，恢复时自然落位。被导出的**原始数据库文件/目录会从快照中排除**
（清单在 `.hotsnap/EXCLUDES.txt`），每个快照带一份 `.hotsnap/RESTORE.md` 写明导回命令。

## 退回停机

以下情况 hotsnap 退出码 2，`backup.sh` 对该项目改走旧的停机流程（停容器 → restic → 启动）并发 TG：

- 发现无法识别的数据库：LevelDB/RocksDB（`MANIFEST-*` + `.ldb/.sst`）、H2（`.mv.db`）、LMDB（`data.mdb`）、
  未被识别容器覆盖的 `PG_VERSION` / `ibdata*`
- dump 失败（密码缺失、容器不健康、超时）
- MC 的 `rcon-cli` 不可用

处理：
- 数据可丢（任务队列、缓存索引）→ `backup.conf`：`HOT_IGNORE=("<项目>:<glob>")`，如 `gitea:data/gitea/queues/*`
- 必须停机 → `HOT_FORCE_STOP=(<项目>)`
- 全部回到停机模式 → `HOT_BACKUP=0`

## 一致性说明

- 数据库：dump / 在线备份 API 给出的是**事务一致**副本。
- MC：`save-all flush` 后到 `save-on` 之前存档不会被写入，拷贝一致。
- 普通文件：热拷，和停机拷相比只差"正在写入的那一刻"；上传目录、配置文件等可接受。

## 开销

| 项目类型 | 典型耗时 | 说明 |
|---|---|---|
| 纯 SQLite / 文件 | 20–40s | 几乎全是 restic 扫描 |
| PostgreSQL + Redis（几百 MB） | 30–60s | dump 压缩后 restic 去重效果一般，每天会多上传 dump 的变化部分 |
| MySQL（GB 级） | 1–3min | 同上 |

快照目录默认 `/var/lib/docker-backup/hotsnap/<项目>`（`HOT_SNAP_DIR`），每次覆盖，只保留最近一次。
