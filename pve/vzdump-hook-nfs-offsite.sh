#!/bin/bash
# vzdump hookscript —— 备份写 NFS（OVH Backup Storage），任务结束后后台推一份到云端。
# 云端用 rclone 直传（不经 rclone mount / 本地 VFS 缓存），本地 SSD 零额外写入。
# 安装：cp 到 /usr/local/sbin/ 并 chmod +x；/etc/vzdump.conf：
#       script: /usr/local/sbin/vzdump-hook-nfs-offsite.sh
# 配置：/etc/vzdump-hook.conf（见 vzdump-hook.conf.example）
#
#  job-start   : 检查 NFS 已挂载（否则中止整个任务并告警），清空清单
#  backup-end  : 写进 NFS 的归档 → 记录 文件名/大小/VMID
#  backup-abort: 告警
#  job-abort   : 告警
#  job-end     : systemd-run 后台启动 vzdump-offsite-sync.sh（不阻塞 vzdump）
set -euo pipefail

# ---- 默认值；/etc/vzdump-hook.conf 覆盖 ----
NFS_MOUNT="/mnt/ovh-backup"
NOTIFY="/docker/service/backup/notify.sh"
SYNC="/usr/local/sbin/vzdump-offsite-sync.sh"
OFFSITE_LIST="/run/vzdump-offsite.list"
# shellcheck disable=SC1091
[ -r /etc/vzdump-hook.conf ] && . /etc/vzdump-hook.conf

PHASE="${1:-}"
notify() { [ -x "$NOTIFY" ] && "$NOTIFY" "$@" || true; }

case "$PHASE" in
  job-start)
    ls "$NFS_MOUNT" >/dev/null 2>&1 || true          # x-systemd.automount：先访问一次触发挂载
    if ! findmnt -t nfs,nfs4 "$NFS_MOUNT" >/dev/null 2>&1; then
      echo "ERROR: NFS not mounted at $NFS_MOUNT"
      notify "❌ vzdump 未启动" "NFS $NFS_MOUNT 未挂载，备份任务中止"
      exit 1
    fi
    : > "$OFFSITE_LIST"
    ;;
  backup-end)
    # 只记录写进 NFS 的归档（手动备份到 local 等其他存储不推云端）
    if [ -n "${TARGET:-}" ] && [ -f "$TARGET" ] && [[ "$TARGET" == "$NFS_MOUNT"/* ]]; then
      printf '%s\t%s\t%s\n' "$(basename "$TARGET")" "$(stat -c %s "$TARGET")" "${VMID:-?}" >> "$OFFSITE_LIST"
      echo "HOOK: recorded $(basename "$TARGET") for offsite copy"
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
    if [ -s "$OFFSITE_LIST" ]; then
      snap="/run/vzdump-offsite.$(date +%Y%m%d-%H%M%S).list"
      cp "$OFFSITE_LIST" "$snap"
      systemd-run --no-block --collect --quiet \
        --unit="vzdump-offsite-sync-$(date +%Y%m%d-%H%M%S)" \
        --description="Copy vzdump archives from NFS to cloud" \
        --property=Nice=10 --property=IOSchedulingClass=idle \
        "$SYNC" "$snap" && echo "HOOK: offsite copy started in background ($snap)" \
        || { echo "HOOK: WARNING failed to start offsite copy"; notify "⚠️ vzdump 云端同步未能启动" "systemd-run 失败，请手动执行 $SYNC $snap"; }
    else
      echo "HOOK: no archives recorded, skipping offsite copy"
    fi
    ;;
esac

exit 0
