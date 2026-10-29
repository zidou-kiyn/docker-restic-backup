#!/bin/bash
# notify.sh — 发送 Telegram 通知（HTML 排版）
# 用法: notify.sh "<标题>" "<正文>"
#       echo "<正文>" | notify.sh "<标题>"
# 环境变量（可选，按调用覆盖）:
#   NOTIFY_THREAD_ID=<n>   发到指定话题（缺省 .env 的 TG_THREAD_ID）
#   NOTIFY_RAW_HTML=1      标题/正文已是合法 Telegram HTML，不再转义（默认会转义 & < > 并把标题加粗）
# .env: TG_BOT_TOKEN / TG_CHAT_ID / TG_THREAD_ID（默认话题）/ HOST_TAG（缺省 hostname -s）
# 通知失败只写 syslog，永远 exit 0。
set -u
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ENV_FILE="$DIR/.env"
log_err() { logger -t notify -p user.err -- "$*" 2>/dev/null || true; echo "notify: $*" >&2; }
[ -r "$ENV_FILE" ] || { log_err "missing $ENV_FILE"; exit 0; }
TG_BOT_TOKEN=$(sed -nE 's/^TG_BOT_TOKEN=//p' "$ENV_FILE" | head -1)
TG_CHAT_ID=$(sed -nE 's/^TG_CHAT_ID=//p' "$ENV_FILE" | head -1)
TG_THREAD_ID=${NOTIFY_THREAD_ID:-$(sed -nE 's/^TG_THREAD_ID=//p' "$ENV_FILE" | head -1)}
HOST_TAG=$(sed -nE 's/^HOST_TAG=//p' "$ENV_FILE" | head -1); HOST_TAG="${HOST_TAG:-$(hostname -s)}"
[ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || { log_err "TG_BOT_TOKEN/TG_CHAT_ID not set"; exit 0; }

title="${1:-notify}"
if [ $# -ge 2 ]; then body="$2"; elif [ ! -t 0 ]; then body="$(cat)"; else body=""; fi

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
if [ "${NOTIFY_RAW_HTML:-0}" = 1 ]; then
  text="$title"
else
  text="<b>$(printf '%s' "$title" | esc)</b>  <i>$HOST_TAG</i>"
  body="$(printf '%s' "$body" | esc)"
fi
[ -n "$body" ] && text="$text"$'\n'"$body"
[ ${#text} -gt 3900 ] && text="${text:0:3900}"$'\n'"…(truncated)"

thread_args=(); [ -n "$TG_THREAD_ID" ] && thread_args=(--data-urlencode "message_thread_id=$TG_THREAD_ID")
for attempt in 1 2 3; do
  resp=$(curl -sS --max-time 20 --data-urlencode "chat_id=$TG_CHAT_ID" "${thread_args[@]}" \
    --data-urlencode "text=$text" --data-urlencode "parse_mode=HTML" --data-urlencode "disable_web_page_preview=true" \
    "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" 2>&1) && [[ "$resp" == *'"ok":true'* ]] && break
  # HTML 解析失败（内容含非法标签）时退回纯文本再发一次
  if [[ "$resp" == *"can't parse entities"* ]]; then
    resp=$(curl -sS --max-time 20 --data-urlencode "chat_id=$TG_CHAT_ID" "${thread_args[@]}" \
      --data-urlencode "text=$(printf '%s' "$text" | sed -e 's/<[^>]*>//g' -e 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g')" \
      --data-urlencode "disable_web_page_preview=true" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" 2>&1) && break
  fi
  [ $attempt -lt 3 ] && sleep $((attempt * 5))
done
[[ "${resp:-}" == *'"ok":true'* ]] || log_err "telegram failed: ${resp:0:300}"
exit 0
