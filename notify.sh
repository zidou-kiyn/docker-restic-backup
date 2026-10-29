#!/bin/bash
# notify.sh — 发送通知：Telegram（HTML 排版）或 企业微信群机器人（纯文本），按 .env 自动选择
# 用法: notify.sh "<标题>" "<正文>"
#       echo "<正文>" | notify.sh "<标题>"
# 环境变量（可选，按调用覆盖）:
#   NOTIFY_THREAD_ID=<n>   Telegram 话题（缺省 .env 的 TG_THREAD_ID）；企业微信忽略
#   NOTIFY_RAW_HTML=1      标题/正文已是合法 Telegram HTML，不再转义（默认会转义 & < > 并把标题加粗）；
#                          企业微信后端会把 HTML 去标签、还原实体后当纯文本发
# .env:
#   Telegram  : TG_BOT_TOKEN / TG_CHAT_ID / TG_THREAD_ID（默认话题）
#   企业微信  : WECOM_WEBHOOK_KEY=<群机器人 key>（只填 key，不是整条 URL；api.telegram.org 不通的机器用）
#               同时填了两者时优先 Telegram；要强制企业微信可 NOTIFY_BACKEND=wecom
#   公共      : HOST_TAG（缺省 hostname -s）
# 通知失败只写 syslog，永远 exit 0。
set -u
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ENV_FILE="$DIR/.env"
log_err() { logger -t notify -p user.err -- "$*" 2>/dev/null || true; echo "notify: $*" >&2; }
[ -r "$ENV_FILE" ] || { log_err "missing $ENV_FILE"; exit 0; }
envget() { sed -nE "s/^$1=//p" "$ENV_FILE" | head -1; }
TG_BOT_TOKEN=$(envget TG_BOT_TOKEN); TG_CHAT_ID=$(envget TG_CHAT_ID)
TG_THREAD_ID=${NOTIFY_THREAD_ID:-$(envget TG_THREAD_ID)}
WECOM_KEY=$(envget WECOM_WEBHOOK_KEY)
HOST_TAG=$(envget HOST_TAG); HOST_TAG="${HOST_TAG:-$(hostname -s)}"

title="${1:-notify}"
if [ $# -ge 2 ]; then body="$2"; elif [ ! -t 0 ]; then body="$(cat)"; else body=""; fi

backend=${NOTIFY_BACKEND:-}
if [ -z "$backend" ]; then
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then backend=telegram
  elif [ -n "$WECOM_KEY" ]; then backend=wecom
  else log_err "no backend configured (TG_BOT_TOKEN/TG_CHAT_ID or WECOM_WEBHOOK_KEY)"; exit 0; fi
fi

# ---------- 企业微信群机器人（text，上限 2048 字节） ----------
if [ "$backend" = wecom ]; then
  [ -n "$WECOM_KEY" ] || { log_err "WECOM_WEBHOOK_KEY not set"; exit 0; }
  unhtml() { sed -e 's/<[^>]*>//g' -e 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&amp;/\&/g'; }
  if [ "${NOTIFY_RAW_HTML:-0}" = 1 ]; then
    title="$(printf '%s' "$title" | unhtml)"; body="$(printf '%s' "$body" | unhtml)"
  fi
  text="【$title】 $HOST_TAG"
  [ -n "$body" ] && text="$text"$'\n'"$body"
  if [ "$(printf '%s' "$text" | wc -c)" -gt 1900 ]; then
    while [ "$(printf '%s' "$text" | wc -c)" -gt 1880 ]; do text="${text:0:$(( ${#text} - 40 ))}"; done
    text="$text"$'\n'"…(truncated)"
  fi
  json=$(printf '%s' "$text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' | sed -e ':a;N;$!ba;s/\n/\\n/g')
  payload="{\"msgtype\":\"text\",\"text\":{\"content\":\"$json\"}}"
  for attempt in 1 2 3; do
    resp=$(curl -sS --max-time 20 -H 'Content-Type: application/json' --data-binary "$payload" \
      "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=$WECOM_KEY" 2>&1) && [[ "$resp" == *'"errcode":0'* ]] && break
    [ $attempt -lt 3 ] && sleep $((attempt * 5))
  done
  [[ "${resp:-}" == *'"errcode":0'* ]] || log_err "wecom failed: ${resp:0:300}"
  exit 0
fi

# ---------- Telegram（HTML） ----------
[ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || { log_err "TG_BOT_TOKEN/TG_CHAT_ID not set"; exit 0; }
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
