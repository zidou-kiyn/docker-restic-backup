#!/bin/bash
# vzdump hookscript —— 目标存储是 rclone 挂载的云盘时用。
# 安装：cp 到 /usr/local/sbin/ 并 chmod +x；/etc/vzdump.conf 加一行
#       hookscript: /usr/local/sbin/vzdump-hook-check-rclone-mount.sh
# 配置：/etc/vzdump-hook.conf（见 vzdump-hook.conf.example）
#
#  job-start   : 检查挂载点存在（不存在则中止整个任务并告警），清空上传清单
#  backup-end  : 写入挂载点的归档 → 记录 文件名/大小/VMID 到清单
#  backup-abort: 告警
#  job-abort   : 告警
#  job-end     : 用 systemd-run 后台启动 vzdump-upload-verify.sh 核对云端（不阻塞 vzdump）
set -euo pipefail

# ---- 默认值；/etc/vzdump-hook.conf 覆盖 ----
MOUNTPOINT="/mnt/cloud"                                   # rclone mount 挂载点（PVE 存储的 path 在其下）
NOTIFY="/opt/docker-restic-backup/notify.sh"              # 通知脚本（本仓库的 notify.sh，读同目录 .env）
VERIFY="/usr/local/sbin/vzdump-upload-verify.sh"
LIST="/run/vzdump-uploads.list"
# shellcheck disable=SC1091
[ -r /etc/vzdump-hook.conf ] && . /etc/vzdump-hook.conf

PHASE="${1:-}"
notify() { [ -x "$NOTIFY" ] && "$NOTIFY" "$@" || true; }

case "$PHASE" in
  job-start)
    if ! findmnt -T "$MOUNTPOINT" >/dev/null 2>&1; then
      echo "ERROR: rclone mount not present at $MOUNTPOINT"
      notify "❌ vzdump 未启动" "挂载 $MOUNTPOINT 不存在，备份任务中止"
      exit 1
    fi
    : > "$LIST"
    ;;
  backup-end)
    # 只记录写入挂载点的归档（手动备份到 local 等其他存储不做上传校验）
    if [ -n "${TARGET:-}" ] && [ -f "$TARGET" ] && [[ "$TARGET" == "$MOUNTPOINT"/* ]]; then
      printf '%s\t%s\t%s\n' "$(basename "$TARGET")" "$(stat -c %s "$TARGET")" "${VMID:-?}" >> "$LIST"
      echo "HOOK: recorded $(basename "$TARGET") for upload verification"
    fi
    ;;
  backup-abort)
    notify "❌ vzdump VM ${VMID:-?} 备份中止" "TARGET=${TARGET:-n/a}
LOGFILE=${LOGFILE:-n/a}"
    ;;
  job-abort)
    notify "❌ vzdump 任务中止" "storage=${STOREID:-n/a} dumpdir=${DUMPDIR:-n/a}"
    ;;
  job-end)
    if [ -s "$LIST" ]; then
      snap="/run/vzdump-uploads.$(date +%Y%m%d-%H%M%S).list"
      cp "$LIST" "$snap"
      systemd-run --no-block --collect --quiet \
        --unit="vzdump-upload-verify-$(date +%Y%m%d-%H%M%S)" \
        --description="Verify vzdump archives uploaded to cloud" \
        --property=Nice=10 \
        "$VERIFY" "$snap" && echo "HOOK: upload verification started in background ($snap)" \
        || { echo "HOOK: WARNING failed to start upload verification"; notify "⚠️ vzdump 上传校验未能启动" "systemd-run 失败，请手动检查 $snap"; }
    else
      echo "HOOK: no archives recorded, skipping upload verification"
    fi
    ;;
esac

exit 0
