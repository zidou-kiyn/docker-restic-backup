#!/bin/bash
# vzdump-upload-verify.sh <清单文件>
# 清单格式：<文件名>\t<本地字节数>\t<VMID>（由 vzdump hook 的 backup-end 阶段写入）
# 流程：等待 rclone VFS 写回队列清空（最长 MAX_WAIT）→ 逐个比对云端大小 → 通知 → 删除清单
# 前提：rclone mount 以 --rc --rc-addr unix://$RC_SOCK 启动（用 vfs/stats 查队列）；--vfs-cache-mode writes 或 full
#       rc 不要开在 TCP 上：--rc-no-auth 的 TCP 端口能被 host 网络容器访问，等于把 root 文件读写权限交出去
# 配置：/etc/vzdump-hook.conf（见 vzdump-hook.conf.example）
set -uo pipefail

# ---- 默认值；/etc/vzdump-hook.conf 覆盖 ----
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
RC_SOCK="/run/rclone-rc/rc.sock"                  # rclone rc 的 unix socket（目录 0700 root）
RC_URL=""                                        # 旧写法兼容：RC_SOCK 为空时才用 TCP
REMOTE="myremote:pve_backup/dump"                 # 归档在云端的目录（rclone 路径）
NOTIFY="/opt/docker-restic-backup/notify.sh"
MAX_WAIT=$((6*3600))
INTERVAL=60
# shellcheck disable=SC1091
[ -r /etc/vzdump-hook.conf ] && . /etc/vzdump-hook.conf
export RCLONE_CONFIG

LIST="${1:-}"
notify() { [ -x "$NOTIFY" ] && "$NOTIFY" "$@" || true; }

[ -n "$LIST" ] && [ -s "$LIST" ] || { echo "no list"; exit 0; }
start=$(date +%s)
sleep 30   # 给 VFS write-back 延迟（默认 5s）留余量，避免队列尚未入队就判定为空

rc() { if [ -n "${RC_SOCK:-}" ]; then rclone rc --unix-socket "$RC_SOCK" "$@"; else rclone rc --url "$RC_URL" "$@"; fi; }

pending() {
  rc vfs/stats 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["diskCache"]; print(int(d["uploadsInProgress"])+int(d["uploadsQueued"]))' 2>/dev/null \
    || echo "?"
}

timed_out=0
while :; do
  p=$(pending)
  if [ "$p" = "0" ]; then break; fi
  if [ $(( $(date +%s) - start )) -ge "$MAX_WAIT" ]; then timed_out=1; break; fi
  sleep "$INTERVAL"
done
wait_s=$(( $(date +%s) - start ))

fail=0; total=0; report=""
while IFS=$'\t' read -r name size vmid; do
  [ -n "$name" ] || continue
  rsize=$(rclone lsjson --no-modtime --no-mimetype "$REMOTE/$name" 2>/dev/null \
          | python3 -c 'import json,sys; l=json.load(sys.stdin); print(l[0]["Size"] if l else -1)' 2>/dev/null || echo -1)
  human=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size}B")
  if [ "$rsize" = "$size" ]; then
    report+="✅ VM$vmid $name ($human)"$'\n'
    total=$((total + size))
  else
    fail=1
    report+="❌ VM$vmid $name 本地=$size 云端=$rsize"$'\n'
  fi
done < "$LIST"

hdr="等待写回 ${wait_s}s"; [ "$timed_out" = 1 ] && hdr="⏰ 等待写回超时(${wait_s}s)，队列仍有 $(pending) 项"
if [ "$fail" = 0 ] && [ "$timed_out" = 0 ]; then
  notify "✅ vzdump 上传校验通过" "$hdr，共 $(numfmt --to=iec --suffix=B "$total")
$report"
else
  notify "❌ vzdump 上传校验失败" "$hdr
$report"
fi
rm -f "$LIST"
exit 0
