# 恢复

```bash
cd /docker/service/backup; set -a; . ./.env; set +a
restic snapshots --compact                      # 按 host / tag 找快照
restic snapshots --tag <项目> --host <HOST_TAG> --compact
```

## 整个项目

```bash
docker compose -f /docker/service/<项目>/docker-compose.yml down     # 若还在跑
restic restore <快照id> --target / --include "/docker/service/<项目>"
cat /docker/service/<项目>/.hotsnap/RESTORE.md                       # 热备快照：按说明导回数据库
```

恢复到临时目录再比对也可以：`--target /tmp/r`。

## 热备快照里的数据库

原始数据库文件不在快照里，用 `.hotsnap/` 下的一致副本导回（`RESTORE.md` 里有逐条命令）：

| 类型 | 导回 |
|---|---|
| SQLite | 把 `.hotsnap/sqlite/<相对路径>` 覆盖到同路径，并删掉旁边的 `-wal` `-shm` |
| PostgreSQL | 用空数据目录启动容器 → `gunzip -c pg-<容器>.sql.gz \| docker exec -i <容器> psql -U <user> -d postgres` |
| MySQL | 启动容器 → `gunzip -c mysql-<容器>.sql.gz \| docker exec -i -e MYSQL_PWD=<root密码> <容器> mysql -uroot` |
| Redis | 停容器 → `redis-<容器>.rdb` 放回数据目录改名 `dump.rdb`（启用 AOF 的先删 `appendonly*`）→ 启动 |
| MongoDB | `docker exec -i <容器> mongorestore --archive --gzip --drop < mongo-<容器>.archive.gz` |
| Minecraft | 存档目录直接恢复 |

导回后删除 `.hotsnap/` 目录（它只是备份产物）。

## 宿主机配置（host 组）

```bash
restic restore latest --tag host --host <HOST_TAG> --target /tmp/host
diff -r /tmp/host/etc /etc | less        # 先看差异再决定覆盖哪些
```

## 单个文件

```bash
restic restore <快照id> --target /tmp/r --include "/docker/service/npm/data/database.sqlite"
# 或挂载浏览
restic mount /mnt/restic
```

## 验证备份可用（建议每月）

```bash
restic restore latest --tag <项目> --target /tmp/rt --include "/docker/service/<项目>/.hotsnap"
python3 -c "import sqlite3; print(sqlite3.connect('/tmp/rt/docker/service/<项目>/.hotsnap/sqlite/<路径>').execute('pragma integrity_check').fetchone())"
gunzip -t /tmp/rt/docker/service/<项目>/.hotsnap/*.sql.gz
```

## 密钥

`RESTIC_PASSWORD_FILE` 指向的文件和 rclone 配置都在 host 组里，但**机器全丢时需要它们才能打开仓库**——
务必在密码管理器里另存：restic 密码、`rclone.conf`、`RESTIC_REPOSITORY`。
