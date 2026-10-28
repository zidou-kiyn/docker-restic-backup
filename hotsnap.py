#!/usr/bin/env python3
# hotsnap.py — 不停机备份前的「一致性快照」
#
# 用法：hotsnap.py <项目目录> <快照输出目录> [--ignore <glob>]...
#   扫描项目目录与项目的运行中容器，把所有「热拷贝不一致」的数据导出为一致副本（放到快照输出目录），
#   再由 backup.sh 用 restic 备份：项目目录（排除原始数据库文件） + 快照输出目录。
#
# 退出码：0 = 全部可热备；2 = 发现无法识别/无法导出的数据，调用方应退回停机备份；1 = 内部错误
# stdout：人类可读说明（进日志/TG）；stderr：调试
#
# 识别规则（按容器镜像名 + 文件头，不靠扩展名）：
#   postgres/postgis/timescale  → pg_dumpall（全库 + 角色）        → <out>/pg-<容器>.sql.gz
#   mysql/mariadb               → mysqldump --single-transaction   → <out>/mysql-<容器>.sql.gz
#   redis/valkey                → BGSAVE 等完成 → 拷 dump.rdb      → <out>/redis-<容器>.rdb
#   mongo                       → mongodump --archive --gzip       → <out>/mongo-<容器>.archive.gz
#   itzg/minecraft 或含 level.dat 的 MC 存档 → rcon save-off/save-all flush → 标记可拷 → save-on
#   文件头 "SQLite format 3"     → python sqlite3 backup API        → <out>/sqlite/<相对路径>
#   其余文件                     → 直接热拷（配置、上传、静态文件）
#   未知数据库（LevelDB/H2/influx/es/clickhouse/etcd…）→ 退出 2（除非 --ignore 命中）
#
# 恢复：见各导出文件旁的 RESTORE.md（本脚本生成）
import os, sys, json, subprocess, sqlite3, shutil, time, fnmatch, re, argparse, gzip

ap = argparse.ArgumentParser()
ap.add_argument("project_dir"); ap.add_argument("out_dir")
ap.add_argument("--ignore", action="append", default=[], help="glob（相对项目目录）：匹配的未知数据不算阻塞，直接热拷")
ap.add_argument("--mc-timeout", type=int, default=60)
a = ap.parse_args()
P = os.path.abspath(a.project_dir); OUT = os.path.abspath(a.out_dir)
notes, blockers, restore = [], [], []
exclude_originals = []   # 相对项目目录：已导出一致副本的原始文件/目录，restic 应排除

def sh(cmd, inp=None, timeout=600):
    r = subprocess.run(cmd, input=inp, capture_output=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr.decode(errors="replace")
def dexec(c, cmd, timeout=600, user=None):
    base = ["docker", "exec", "-i"] + (["-u", user] if user else []) + [c]
    return sh(base + cmd, timeout=timeout)
def env_of(c):
    rc, o, _ = sh(["docker", "inspect", "-f", "{{json .Config.Env}}", c])
    d = {}
    for kv in (json.loads(o) if rc == 0 else []):
        k, _, v = kv.partition("="); d[k] = v
    return d
def rel(p): return os.path.relpath(p, P)
def ignored(relpath): return any(fnmatch.fnmatch(relpath, g) or fnmatch.fnmatch(relpath, g.rstrip("/") + "/*") for g in a.ignore)
def gz_write(path, data_iter):
    tmp = path + ".tmp"
    with gzip.open(tmp, "wb", compresslevel=6) as f:
        for chunk in data_iter: f.write(chunk)
    os.chmod(tmp, 0o600); os.replace(tmp, path)
def stream_cmd_to_gz(cmd, path, timeout=1800):
    tmp = path + ".tmp"
    with gzip.open(tmp, "wb", compresslevel=6) as f:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for chunk in iter(lambda: p.stdout.read(1 << 20), b""): f.write(chunk)
        err = p.stderr.read().decode(errors="replace"); p.wait(timeout=timeout)
    if p.returncode != 0 or os.path.getsize(tmp) < 32:
        os.unlink(tmp); return False, err
    os.chmod(tmp, 0o600); os.replace(tmp, path); return True, ""

os.makedirs(OUT, mode=0o700, exist_ok=True)
for f in os.listdir(OUT):
    fp = os.path.join(OUT, f); shutil.rmtree(fp) if os.path.isdir(fp) else os.unlink(fp)

# ---------- 项目的运行中容器 ----------
rc, o, _ = sh(["docker", "ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Label \"com.docker.compose.project.working_dir\"}}\t{{.ID}}"])
containers = []
for line in o.decode().splitlines():
    name, image, wd, cid = line.split("\t")
    if wd and (wd == P or wd.startswith(P + "/")):
        containers.append((name, image.lower())); continue
    rc2, m, _ = sh(["docker", "inspect", "-f", "{{range .Mounts}}{{if eq .Type \"bind\"}}{{.Source}}\n{{end}}{{end}}", cid])
    if any(s == P or s.startswith(P + "/") for s in m.decode().split()):
        containers.append((name, image.lower()))

mc_containers = []
for name, image in containers:
    e = env_of(name)
    try:
        if re.search(r"postgres|postgis|timescale|pgvector", image):
            user = e.get("POSTGRES_USER", "postgres")
            ok, err = stream_cmd_to_gz(["docker", "exec", name, "pg_dumpall", "-U", user, "--clean", "--if-exists"], f"{OUT}/pg-{name}.sql.gz")
            if not ok: blockers.append(f"{name}: pg_dumpall 失败: {err.strip()[:200]}"); continue
            notes.append(f"pg_dumpall {name} → pg-{name}.sql.gz")
            restore.append(f"- **{name}** (PostgreSQL)：`gunzip -c pg-{name}.sql.gz | docker exec -i {name} psql -U {user} -d postgres`（容器需先以空数据目录启动）")
            for d in ("PGDATA",):
                pass
            # 原始数据目录：从 mount 找 bind 到 /var/lib/postgresql 下的
            rc3, m, _ = sh(["docker", "inspect", "-f", "{{range .Mounts}}{{.Source}}\t{{.Destination}}\n{{end}}", name])
            for ln in m.decode().splitlines():
                src, _, dst = ln.partition("\t")
                if dst.startswith("/var/lib/postgresql") and src.startswith(P + "/"): exclude_originals.append(rel(src))
        elif re.search(r"mysql|mariadb|percona", image):
            pw = e.get("MYSQL_ROOT_PASSWORD") or e.get("MARIADB_ROOT_PASSWORD")
            if not pw: blockers.append(f"{name}: 找不到 MYSQL_ROOT_PASSWORD 环境变量，无法 mysqldump"); continue
            tool = "mariadb-dump" if "mariadb" in image else "mysqldump"
            ok, err = stream_cmd_to_gz(["docker", "exec", "-e", f"MYSQL_PWD={pw}", name, tool, "-uroot", "--single-transaction", "--quick", "--routines", "--triggers", "--events", "--all-databases"], f"{OUT}/mysql-{name}.sql.gz")
            if not ok: blockers.append(f"{name}: {tool} 失败: {err.strip()[:200]}"); continue
            notes.append(f"{tool} {name} → mysql-{name}.sql.gz")
            restore.append(f"- **{name}** (MySQL)：`gunzip -c mysql-{name}.sql.gz | docker exec -i -e MYSQL_PWD=<root密码> {name} mysql -uroot`")
            rc3, m, _ = sh(["docker", "inspect", "-f", "{{range .Mounts}}{{.Source}}\t{{.Destination}}\n{{end}}", name])
            for ln in m.decode().splitlines():
                src, _, dst = ln.partition("\t")
                if dst == "/var/lib/mysql" and src.startswith(P + "/"): exclude_originals.append(rel(src))
        elif re.search(r"redis|valkey", image):
            cli = "valkey-cli" if "valkey" in image else "redis-cli"
            pw = e.get("REDIS_PASSWORD") or e.get("REDISCLI_AUTH") or ""
            base = [cli] + (["-a", pw, "--no-auth-warning"] if pw else [])
            rc1, o1, _ = dexec(name, base + ["ping"])
            if b"PONG" not in o1 and pw:   # 可能 REDISCLI_AUTH 设了但未启用密码
                base = [cli]; rc1, o1, _ = dexec(name, ["env", "-u", "REDISCLI_AUTH", cli, "ping"])
                base = ["env", "-u", "REDISCLI_AUTH", cli]
            if b"PONG" not in o1: blockers.append(f"{name}: redis ping 失败（密码？）"); continue
            rc1, o1, _ = dexec(name, base + ["LASTSAVE"]); last = int(o1.strip() or 0)
            dexec(name, base + ["BGSAVE"])
            for _ in range(120):
                time.sleep(1); rc1, o1, _ = dexec(name, base + ["LASTSAVE"])
                if int(o1.strip() or 0) > last: break
            else: blockers.append(f"{name}: BGSAVE 120s 未完成"); continue
            rc1, o1, _ = dexec(name, base + ["CONFIG", "GET", "dir"]); d = o1.decode().split()[-1] if o1 else "/data"
            rc1, o1, _ = dexec(name, base + ["CONFIG", "GET", "dbfilename"]); fn = o1.decode().split()[-1] if o1 else "dump.rdb"
            rc1, rdb, err = dexec(name, ["cat", f"{d}/{fn}"])
            if rc1 != 0 or len(rdb) < 16: blockers.append(f"{name}: 读取 {d}/{fn} 失败"); continue
            with open(f"{OUT}/redis-{name}.rdb", "wb") as f: f.write(rdb)
            os.chmod(f"{OUT}/redis-{name}.rdb", 0o600)
            notes.append(f"redis BGSAVE {name} → redis-{name}.rdb")
            restore.append(f"- **{name}** (Redis)：停容器，把 redis-{name}.rdb 放回数据目录改名为 {fn}（若启用 AOF，先删 appendonly* 再启动）")
            rc3, m, _ = sh(["docker", "inspect", "-f", "{{range .Mounts}}{{.Source}}\t{{.Destination}}\n{{end}}", name])
            for ln in m.decode().splitlines():
                src, _, dst = ln.partition("\t")
                if dst == d and src.startswith(P + "/"): exclude_originals.append(rel(src))
        elif re.search(r"mongo", image):
            user, pw = e.get("MONGO_INITDB_ROOT_USERNAME"), e.get("MONGO_INITDB_ROOT_PASSWORD")
            auth = ["-u", user, "-p", pw, "--authenticationDatabase", "admin"] if user else []
            ok, err = stream_cmd_to_gz(["docker", "exec", name, "mongodump", "--archive", "--gzip"] + auth, f"{OUT}/mongo-{name}.archive.gz")
            if not ok: blockers.append(f"{name}: mongodump 失败: {err.strip()[:200]}"); continue
            notes.append(f"mongodump {name} → mongo-{name}.archive.gz")
            restore.append(f"- **{name}** (MongoDB)：`docker exec -i {name} mongorestore --archive --gzip --drop < mongo-{name}.archive.gz`")
            rc3, m, _ = sh(["docker", "inspect", "-f", "{{range .Mounts}}{{.Source}}\t{{.Destination}}\n{{end}}", name])
            for ln in m.decode().splitlines():
                src, _, dst = ln.partition("\t")
                if dst == "/data/db" and src.startswith(P + "/"): exclude_originals.append(rel(src))
        elif re.search(r"minecraft", image):
            mc_containers.append(name)
    except subprocess.TimeoutExpired:
        blockers.append(f"{name}: 导出超时")
    except Exception as ex:
        blockers.append(f"{name}: {type(ex).__name__}: {ex}")

# ---------- Minecraft：存档一致性（rcon save-off / save-all flush） ----------
# 存档在 save-off 期间不会被写入；backup.sh 在 restic 期间保持 save-off，备份完 save-on（见 mc_resume）
mc_state = []
for name in mc_containers:
    rc1, o1, err = dexec(name, ["rcon-cli", "list"], timeout=30)
    if rc1 != 0:
        blockers.append(f"{name}: rcon-cli 不可用（{err.strip()[:100]}），MC 存档无法保证一致"); continue
    dexec(name, ["rcon-cli", "save-off"], timeout=30)
    rc1, o1, err = dexec(name, ["rcon-cli", "save-all", "flush"], timeout=a.mc_timeout)
    if rc1 != 0: dexec(name, ["rcon-cli", "save-on"], timeout=30); blockers.append(f"{name}: save-all flush 失败"); continue
    mc_state.append(name); notes.append(f"MC {name}: save-off + save-all flush 完成（备份后 save-on）")
    restore.append(f"- **{name}** (Minecraft)：存档目录直接恢复即可（备份时已 flush 且 save-off）")
with open(f"{OUT}/.mc-save-off", "w") as f: f.write("\n".join(mc_state))

# ---------- 文件扫描：SQLite 在线备份；未知数据库报警 ----------
UNKNOWN_MARKERS = {
    "LevelDB": lambda p: os.path.basename(p).startswith(("MANIFEST-", "CURRENT")) and any(x.endswith((".ldb", ".sst")) for x in os.listdir(os.path.dirname(p))),
}
sqlite_n = 0
for root, dirs, files in os.walk(P):
    dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "__pycache__")]
    r = rel(root)
    if any(r == x or r.startswith(x + "/") for x in exclude_originals): dirs[:] = []; continue
    for fn in files:
        fp = os.path.join(root, fn); rp = rel(fp)
        try:
            if os.path.islink(fp) or os.path.getsize(fp) == 0: continue
            with open(fp, "rb") as f: head = f.read(16)
        except OSError: continue
        if head.startswith(b"SQLite format 3\x00"):
            if ignored(rp): continue
            dst = os.path.join(OUT, "sqlite", rp); os.makedirs(os.path.dirname(dst), mode=0o700, exist_ok=True)
            try:
                src = sqlite3.connect(f"file:{fp}?mode=ro", uri=True, timeout=30); dstc = sqlite3.connect(dst + ".tmp")
                src.backup(dstc); dstc.close(); src.close(); os.chmod(dst + ".tmp", 0o600); os.replace(dst + ".tmp", dst)
                sqlite_n += 1; exclude_originals.append(rp)
                for suf in ("-wal", "-shm", "-journal"):
                    if os.path.exists(fp + suf): exclude_originals.append(rp + suf)
            except Exception as ex:
                blockers.append(f"sqlite {rp}: {ex}")
        elif fn.startswith("MANIFEST-") and not ignored(rp):
            try:
                if any(x.endswith((".ldb", ".sst", ".log")) for x in os.listdir(root)):
                    blockers.append(f"未知数据库（LevelDB/RocksDB）: {os.path.dirname(rp)}/")
            except OSError: pass
        elif (fn.endswith((".mv.db", ".h2.db")) or fn == "data.mdb" or fn.startswith("ibdata") or fn == "PG_VERSION") and not ignored(rp):
            if fn == "PG_VERSION" and any(rp.startswith(x) for x in exclude_originals): continue
            if fn.startswith("ibdata") and any(rp.startswith(x) for x in exclude_originals): continue
            blockers.append(f"未知/未导出的数据库文件: {rp}")
if sqlite_n: notes.append(f"sqlite 在线备份 {sqlite_n} 个库 → sqlite/")
if sqlite_n: restore.append("- **SQLite**：`sqlite/<相对路径>` 是一致副本，恢复时覆盖项目目录中同路径文件（并删除旁边的 -wal/-shm）")

with open(f"{OUT}/EXCLUDES.txt", "w") as f: f.write("\n".join(sorted(set(exclude_originals))) + ("\n" if exclude_originals else ""))
with open(f"{OUT}/RESTORE.md", "w") as f:
    f.write(f"# {os.path.basename(P)} 不停机备份快照 {time.strftime('%F %T')}\n\n项目目录中以下原始数据文件已被排除（用本目录的一致副本代替）：\n```\n" + "\n".join(sorted(set(exclude_originals))) + "\n```\n\n## 恢复\n" + "\n".join(restore) + "\n")
blockers = list(dict.fromkeys(blockers))
print("; ".join(notes) if notes else "无数据库，纯文件热拷")
if blockers:
    # 回滚已做的 MC save-off
    for name in mc_state: dexec(name, ["rcon-cli", "save-on"], timeout=30)
    print("阻塞: " + " | ".join(blockers)); sys.exit(2)
sys.exit(0)
