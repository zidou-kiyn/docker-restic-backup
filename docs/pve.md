# pve/ — Proxmox vzdump 备份配套

脚本在仓库 `pve/` 目录，两种方案任选：

| 方案 | 适用 | 脚本 |
|---|---|---|
| A. vzdump → rclone 挂载的云盘 | 只有云盘可用 | `vzdump-hook-check-rclone-mount.sh` + `vzdump-upload-verify.sh` |
| B. vzdump → NFS → rclone 直传云盘（推荐） | 有 NFS 等网络备份存储；想避免本地盘的额外写入 | `vzdump-hook-nfs-offsite.sh` + `vzdump-offsite-sync.sh` |

另有 `restic-nfs-mirror.sh`：把 Docker 备份的 restic 仓库（rclone 远端）每日镜像到 NFS，见文末 C 节。

方案 A 里 vzdump 写进 `--vfs-cache-mode writes` 挂载点，归档会先完整写进本地 VFS 缓存再上传——每份备份在本地 SSD 上多写一遍（几十 GB/次）。方案 B 先写 NFS，再由 rclone 从 NFS 直接读、直接传远端，不经挂载、不落本地缓存。

两个方案共用 `/etc/vzdump-hook.conf`（见 `vzdump-hook.conf.example`）和仓库的 `notify.sh`。

---

## A. vzdump 到 rclone 挂载云盘

场景：PVE 的备份存储是一个 `dir` 类型存储，path 在 `rclone mount --vfs-cache-mode writes` 的挂载点下。
vzdump 写完归档就"完成"了，但实际上文件还在本地 VFS 缓存里排队上传，几十 GB 可能要一小时。
这两个脚本补上"云端确实收到了"这一步：

| 脚本 | 作用 |
|---|---|
| `vzdump-hook-check-rclone-mount.sh` | vzdump hookscript：任务开始前检查挂载存在（不存在直接中止，避免写进本地目录塞满根盘）；每个归档写完记录大小；任务结束后台启动校验；中止时告警 |
| `vzdump-upload-verify.sh` | 等 rclone VFS 上传队列清空 → `rclone lsjson` 逐个比对云端大小 → Telegram 汇报 |

### 安装

```bash
cp vzdump-hook-check-rclone-mount.sh vzdump-upload-verify.sh /usr/local/sbin/ && chmod +x /usr/local/sbin/vzdump-*.sh
cp vzdump-hook.conf.example /etc/vzdump-hook.conf && vi /etc/vzdump-hook.conf
echo 'script: /usr/local/sbin/vzdump-hook-check-rclone-mount.sh' >> /etc/vzdump.conf
```

rclone mount 的 systemd 单元需要带 `--rc --rc-addr unix:///run/rclone-rc/rc.sock --rc-no-auth`（配合 `RuntimeDirectory=rclone-rc` + `RuntimeDirectoryMode=0700`；**不要用 TCP**：无认证的 127.0.0.1 端口能被 host 网络容器访问，等于交出 root 文件读写）（校验脚本用 `vfs/stats` 查队列），
PVE 存储定义建议加 `is_mountpoint <挂载点>`（双保险）。

### 测试

```bash
# 挂载检查
/usr/local/sbin/vzdump-hook-check-rclone-mount.sh job-start && echo ok
# 校验流程：拿云端已有的一个归档造清单
printf '%s\t%s\t%s\n' vzdump-qemu-100-xxx.vma.zst <本地字节数> 100 > /tmp/t.list
/usr/local/sbin/vzdump-upload-verify.sh /tmp/t.list     # 约 30s 后收到 TG
```

### 注意

- `--vfs-cache-max-size` 是软上限，正在上传的文件不会被驱逐，备份日缓存目录的峰值 ≈ 当天归档总量。

---

## B. vzdump 到 NFS，再直传云盘

场景：有一块 NFS（例如独服附带的备份空间），PVE 备份存储的 path 在 NFS 挂载点下；云盘作为异地副本。

| 脚本 | 作用 |
|---|---|
| `vzdump-hook-nfs-offsite.sh` | vzdump hookscript：任务开始前检查 NFS 已挂载（兼容 `x-systemd.automount`，未挂载则中止）；每个写进 NFS 的归档记录 文件名/大小/VMID；任务结束用 `systemd-run` 后台启动同步（`Nice=10`、`IOSchedulingClass=idle`，不阻塞 vzdump）；中止时告警 |
| `vzdump-offsite-sync.sh` | 逐个 `rclone copy` 归档 + `.log` + `.notes` 到远端（rclone 自带大小/哈希校验）→ 再 `lsjson` 比对大小（重试 6×10s，OneDrive 刚上传的文件可能晚几秒才列得出）→ 全部成功时远端按 VMID 只保留最近 `REMOTE_KEEP_LAST` 份（**只处理本次任务里出现的 VMID**，已删除 VM 的历史备份不动）→ 通知 |

NFS 上的保留由备份任务自己的 `prune-backups`（如 `keep-last=4`）负责。

### 安装

```bash
cp vzdump-hook-nfs-offsite.sh vzdump-offsite-sync.sh /usr/local/sbin/ && chmod +x /usr/local/sbin/vzdump-*.sh
cp vzdump-hook.conf.example /etc/vzdump-hook.conf && vi /etc/vzdump-hook.conf   # REMOTE / NFS_MOUNT / NFS_DUMPDIR / REMOTE_KEEP_LAST
sed -i -E 's#^script: .*#script: /usr/local/sbin/vzdump-hook-nfs-offsite.sh#' /etc/vzdump.conf   # 或追加一行
```

PVE 存储（`/etc/pve/storage.cfg`）建议 path 用 NFS 下的子目录，并把 `is_mountpoint` 指向挂载点本身，例如：

```
dir: nfs-backup
	path /mnt/nfs-backup/pve
	content backup,iso
	is_mountpoint /mnt/nfs-backup
```

备份任务的目标存储改成它即可（`pvesh set /cluster/backup/<job-id> --storage nfs-backup`）。

### 测试

```bash
/usr/local/sbin/vzdump-hook-nfs-offsite.sh job-start && echo ok                 # NFS 挂载检查
vzdump <一个小 VM 的 VMID> --storage nfs-backup --mode snapshot --compress zstd  # 完整走一遍，约 1 分钟后收到 TG
```

---

## C. restic 仓库每日镜像到 NFS

`restic-nfs-mirror.sh` + `restic-nfs-mirror.service` / `.timer`：把 `.env` 里的 `RESTIC_REPOSITORY`（必须是 `rclone:<remote>:<path>`）`rclone sync` 到 NFS 子目录，作为第二份副本。镜像就是普通的 restic 本地仓库，云盘不可用时直接 `restic -r <NFS>/docker/restic snapshots` / `restore`（同一密码）。

- 定时排在 backup.sh 之后（cron 04:00 → timer 05:00）；脚本仍会等 backup.sh 结束（最多 `WAIT_MAX_MIN` 分钟），避免镜像到半截的仓库。
- 成功只写 syslog（`journalctl -t restic-nfs-mirror`），失败 / 跳过才通知。
- 可选配置 `/etc/restic-nfs-mirror.conf`：`REPO_DIR` / `NFS_MOUNT` / `DST_SUBDIR` / `RCLONE_CONFIG` / `WAIT_MAX_MIN`。

```bash
cp restic-nfs-mirror.sh /usr/local/sbin/ && chmod +x /usr/local/sbin/restic-nfs-mirror.sh
cp restic-nfs-mirror.service restic-nfs-mirror.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now restic-nfs-mirror.timer
systemctl start restic-nfs-mirror.service && journalctl -t restic-nfs-mirror -n 1   # 首次全量，之后增量
```

---

## 通用注意

- PVE 通知模板默认带完整日志，Telegram 单条 4096 字符上限会导致 400；
  覆盖 `/etc/pve/notification-templates/default/vzdump-body.txt.hbs` 去掉 Logs 段。
