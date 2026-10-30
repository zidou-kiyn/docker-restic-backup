#!/bin/bash
# restic-nfs-mirror.sh —— 把 restic 仓库（rclone 远端）每日镜像到 NFS，作为 Docker 备份的第二份副本。
# 源仓库从本仓库 .env 的 RESTIC_REPOSITORY 读取（必须是 rclone:<remote>:<path> 形式）。
# 镜像是普通 restic 本地仓库，可直接：restic -r <DST> snapshots（同一密码）。
# 由 restic-nfs-mirror.timer 触发（排在 backup.sh 之后）；backup.sh 还在跑就等它结束（最多 3 小时）。
# 成功只写 syslog（journalctl -t restic-nfs-mirror），失败才通知。
# 配置：/etc/restic-nfs-mirror.conf（可选，覆盖下面的默认值）
set -uo pipefail

# ---- 默认值；/etc/restic-nfs-mirror.conf 覆盖 ----
REPO_DIR="/docker/service/backup"          # 本仓库所在目录（读 .env、调用 notify.sh、检测 backup.sh）
NFS_MOUNT="/mnt/ovh-backup"                # NFS 挂载点
DST_SUBDIR="docker/restic"                 # 镜像放在 NFS 下的哪个子目录
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
WAIT_MAX_MIN=180
# shellcheck disable=SC1091
[ -r /etc/restic-nfs-mirror.conf ] && . /etc/restic-nfs-mirror.conf
export RCLONE_CONFIG

NOTIFY="$REPO_DIR/notify.sh"
DST="$NFS_MOUNT/$DST_SUBDIR"
notify() { [ -x "$NOTIFY" ] && "$NOTIFY" "$@" || true; }
log() { logger -t restic-nfs-mirror -- "$*"; echo "$*"; }

repo=$(sed -nE 's/^RESTIC_REPOSITORY=//p' "$REPO_DIR/.env" 2>/dev/null | head -1 | tr -d '"'"'")
case "$repo" in
  rclone:*) SRC="${repo#rclone:}" ;;
  *) notify "❌ restic 镜像未执行 · $(hostname -s)" "RESTIC_REPOSITORY 不是 rclone: 远端（$repo），本脚本只处理 rclone 仓库"; exit 1 ;;
esac

# 等 backup.sh 跑完，避免镜像到半截的仓库
for _ in $(seq 1 "$WAIT_MAX_MIN"); do pgrep -f "$REPO_DIR/backup.sh" >/dev/null || break; sleep 60; done
if pgrep -f "$REPO_DIR/backup.sh" >/dev/null; then
  notify "⚠️ restic 镜像跳过 · $(hostname -s)" "backup.sh ${WAIT_MAX_MIN} 分钟仍未结束，今天不镜像"; exit 0
fi

ls "$NFS_MOUNT" >/dev/null 2>&1 || true      # x-systemd.automount：先访问一次触发挂载
findmnt -t nfs,nfs4 "$NFS_MOUNT" >/dev/null 2>&1 || { notify "❌ restic 镜像失败 · $(hostname -s)" "NFS $NFS_MOUNT 未挂载"; exit 1; }
mkdir -p "$DST"

start=$(date +%s)
out=$(rclone sync "$SRC" "$DST" --transfers 4 --checkers 8 --retries 3 --low-level-retries 20 --stats 0 -v 2>&1)
rc=$?
took=$(( $(date +%s) - start ))
if [ $rc -ne 0 ]; then
  notify "❌ restic 镜像到 NFS 失败 · $(hostname -s)" "rclone exit $rc，用时 ${took}s
$(echo "$out" | grep -E 'ERROR|Failed' | tail -5)"
  exit 1
fi
log "ok: $(du -sh "$DST" 2>/dev/null | cut -f1) in ${took}s; $(echo "$out" | grep -cE 'Copied|Deleted') changes"
