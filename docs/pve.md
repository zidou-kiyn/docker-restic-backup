# pve/ — vzdump 到 rclone 挂载云盘的配套

脚本在仓库 `pve/` 目录。

场景：PVE 的备份存储是一个 `dir` 类型存储，path 在 `rclone mount --vfs-cache-mode writes` 的挂载点下。
vzdump 写完归档就"完成"了，但实际上文件还在本地 VFS 缓存里排队上传，几十 GB 可能要一小时。
这两个脚本补上"云端确实收到了"这一步：

| 脚本 | 作用 |
|---|---|
| `vzdump-hook-check-rclone-mount.sh` | vzdump hookscript：任务开始前检查挂载存在（不存在直接中止，避免写进本地目录塞满根盘）；每个归档写完记录大小；任务结束后台启动校验；中止时告警 |
| `vzdump-upload-verify.sh` | 等 rclone VFS 上传队列清空 → `rclone lsjson` 逐个比对云端大小 → Telegram 汇报 |

## 安装

```bash
cp vzdump-hook-check-rclone-mount.sh vzdump-upload-verify.sh /usr/local/sbin/ && chmod +x /usr/local/sbin/vzdump-*.sh
cp vzdump-hook.conf.example /etc/vzdump-hook.conf && vi /etc/vzdump-hook.conf
echo 'script: /usr/local/sbin/vzdump-hook-check-rclone-mount.sh' >> /etc/vzdump.conf
```

rclone mount 的 systemd 单元需要带 `--rc --rc-addr unix:///run/rclone-rc/rc.sock --rc-no-auth`（配合 `RuntimeDirectory=rclone-rc` + `RuntimeDirectoryMode=0700`；**不要用 TCP**：无认证的 127.0.0.1 端口能被 host 网络容器访问，等于交出 root 文件读写）（校验脚本用 `vfs/stats` 查队列），
PVE 存储定义建议加 `is_mountpoint <挂载点>`（双保险）。

## 测试

```bash
# 挂载检查
/usr/local/sbin/vzdump-hook-check-rclone-mount.sh job-start && echo ok
# 校验流程：拿云端已有的一个归档造清单
printf '%s\t%s\t%s\n' vzdump-qemu-100-xxx.vma.zst <本地字节数> 100 > /tmp/t.list
/usr/local/sbin/vzdump-upload-verify.sh /tmp/t.list     # 约 30s 后收到 TG
```

## 注意

- PVE 通知模板默认带完整日志，Telegram 单条 4096 字符上限会导致 400；
  覆盖 `/etc/pve/notification-templates/default/vzdump-body.txt.hbs` 去掉 Logs 段。
- `--vfs-cache-max-size` 是软上限，正在上传的文件不会被驱逐，备份日缓存目录的峰值 ≈ 当天归档总量。
