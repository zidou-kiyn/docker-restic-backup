#!/bin/bash
# notify.sh — 发送 Telegram 通知
# 用法: notify.sh "<标题>" "<正文>"
#       echo "<正文>" | notify.sh "<标题>"
# 说明: 读取同目录 .env 中的 TG_BOT_TOKEN / TG_CHAT_ID（可选 HOST_TAG，缺省 hostname）；
#       通知失败只写 syslog，永远 exit 0，因此可安全地被任何脚本/hook 调用。
set -u
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ENV_FILE="$DIR/.env"

log_err() { logger -t notify -p user.err -- "$*" 2>/dev/null || true; echo "notify: $*" >&2; }

if [ ! -r "$ENV_FILE" ]; then log_err "missing $ENV_FILE"; exit 0; fi
# 只取需要的变量，避免执行 .env 中的其他内容
TG_BOT_TOKEN=$(sed -nE 's/^TG_BOT_TOKEN=//p' "$ENV_FILE" | head -1)
TG_CHAT_ID=$(sed -nE 's/^TG_CHAT_ID=//p' "$ENV_FILE" | head -1)
HOST_TAG=$(sed -nE 's/^HOST_TAG=//p' "$ENV_FILE" | head -1); HOST_TAG="${HOST_TAG:-$(hostname -s)}"
if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then log_err "TG_BOT_TOKEN/TG_CHAT_ID not set in $ENV_FILE"; exit 0; fi

title="${1:-notify}"
if [ $# -ge 2 ]; then
  body="$2"
elif [ ! -t 0 ]; then
  body="$(cat)"
else
  body=""
fi

text="[$HOST_TAG] $title"
[ -n "$body" ] && text="$text"$'\n'"$body"
# Telegram 单条上限 4096，留余量
if [ ${#text} -gt 3900 ]; then text="${text:0:3900}"$'\n'"…(truncated)"; fi

# 最多 3 次（开机早期 DNS/网络可能未就绪）
for attempt in 1 2 3; do
  resp=$(curl -sS --max-time 20 \
    --data-urlencode "chat_id=$TG_CHAT_ID" \
    --data-urlencode "text=$text" \
    --data-urlencode "disable_web_page_preview=true" \
    "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" 2>&1) && break
  [ $attempt -lt 3 ] && sleep $((attempt * 5))
done
if [ -z "${resp:-}" ] || ! [[ "$resp" == *'"ok"'* ]]; then
  case "${resp:-}" in *'"ok":true'*) ;; *) log_err "curl failed after $attempt attempts: ${resp:0:200}"; exit 0 ;; esac
fi

case "$resp" in
  *'"ok":true'*) ;;
  *) log_err "telegram API error: ${resp:0:300}" ;;
esac
exit 0
