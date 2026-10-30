#!/bin/bash
# vzdump-offsite-sync.sh <清单文件>
# 清单格式：<归档文件名>\t<字节数>\t<VMID>（由 vzdump-hook-nfs-offsite.sh 的 backup-end 阶段写入）
# 流程：NFS → 云端 rclone copy（归档 + .log + .notes，rclone 自带哈希校验）→ 再比对一次大小
#       → 云端按 VMID 只保留最近 REMOTE_KEEP_LAST 份（只处理本次任务里出现的 VMID，其他 VMID 的旧备份不动）→ 通知
# rclone 直接访问远端，不经 rclone mount，本地盘零额外写入。
# 配置：/etc/vzdump-hook.conf（见 vzdump-hook.conf.example）
set -uo pipefail

# ---- 默认值；/etc/vzdump-hook.conf 覆盖 ----
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
NFS_DUMPDIR="/mnt/ovh-backup/pve/dump"
REMOTE="myremote:pve_backup/dump"
REMOTE_KEEP_LAST=4
NOTIFY="/docker/service/backup/notify.sh"
# shellcheck disable=SC1091
[ -r /etc/vzdump-hook.conf ] && . /etc/vzdump-hook.conf
export RCLONE_CONFIG

LIST="${1:-}"
notify() { [ -x "$NOTIFY" ] && "$NOTIFY" "$@" || true; }
hum() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }
is_archive() { [[ "$1" =~ \.(vma|tar)(\.(zst|gz|lzo))?$ ]]; }

[ -n "$LIST" ] && [ -s "$LIST" ] || { echo "no list"; exit 0; }
start=$(date +%s)
fail=0; total=0; report=""; vmids=()

while IFS=$'\t' read -r name size vmid; do
  [ -n "$name" ] || continue
  prefix="${name%%.vma*}"; prefix="${prefix%%.tar*}"      # vzdump-qemu-100-2026_10_29-06_00_01
  vmids+=("$vmid")
  if ! rclone copy "$NFS_DUMPDIR" "$REMOTE" --include "/${prefix}.*" \
        --transfers 1 --retries 5 --low-level-retries 20 --stats 0 -q; then
    fail=1; report+="❌ VM$vmid · rclone copy 失败"$'\n'; continue
  fi
  # rclone copy 本身已校验大小+哈希；这里再独立核对一次。OneDrive 刚上传的文件可能要几秒才列得出来 → 重试
  rsize=-1
  for _ in 1 2 3 4 5 6; do
    rsize=$(rclone lsjson --no-modtime --no-mimetype "$REMOTE/$name" 2>/dev/null \
            | python3 -c 'import json,sys; l=json.load(sys.stdin); print(l[0]["Size"] if l else -1)' 2>/dev/null || echo -1)
    [ "$rsize" = "$size" ] && break
    sleep 10
  done
  if [ "$rsize" = "$size" ]; then
    report+="✅ VM$vmid · $(hum "$size")"$'\n'; total=$((total + size))
  else
    fail=1
    report+="❌ VM$vmid · NFS $(hum "$size") / 云端 $( [ "$rsize" = -1 ] && echo 缺失 || hum "$rsize")"$'\n'
  fi
done < "$LIST"

# 云端保留：只在全部成功时清理，按 VMID 保留最近 N 份（文件名里的时间戳排序）
pruned=0
if [ "$fail" = 0 ] && [ "${REMOTE_KEEP_LAST:-0}" -gt 0 ]; then
  for vmid in $(printf '%s\n' "${vmids[@]}" | sort -u); do
    mapfile -t archives < <(rclone lsf "$REMOTE" --files-only --include "vzdump-*-${vmid}-*" 2>/dev/null | sort)
    keep=(); for f in "${archives[@]}"; do is_archive "$f" && keep+=("$f"); done
    n=${#keep[@]}
    [ "$n" -gt "$REMOTE_KEEP_LAST" ] || continue
    for f in "${keep[@]:0:$((n - REMOTE_KEEP_LAST))}"; do
      p="${f%%.vma*}"; p="${p%%.tar*}"
      rclone delete "$REMOTE" --include "/${p}.*" -q && pruned=$((pruned + 1))
    done
  done
fi

took=$(( $(date +%s) - start )); took_h=$(printf '%dm%02ds' $((took/60)) $((took%60)))
if [ "$fail" = 0 ]; then
  notify "☁️ PVE 备份已同步云端 · $(hostname -s)" "${report}— 共 $(hum "$total") · 用时 $took_h · 云端清理旧备份 ${pruned} 份（每台保留 ${REMOTE_KEEP_LAST}）"
else
  notify "❌ PVE 备份云端同步失败 · $(hostname -s)" "${report}— 用时 $took_h · NFS 上的备份不受影响；未做云端清理"
fi
rm -f "$LIST"
exit 0
