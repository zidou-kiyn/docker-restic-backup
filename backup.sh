#!/bin/bash
# =============================================================================
# backup.sh — Docker 项目 + 宿主机配置的 restic 备份（停机一致性）
#
# 模式：
#   backup.sh               正常：逐项目 停机→restic→启动，然后 host 组，forget，周日 prune/check
#   backup.sh --seed        不停任何容器/服务，只做 restic backup（首次播种用）
#   backup.sh --only <项目|host>   只处理指定项目（测试用；不做 forget/prune）
#   backup.sh --dry-run     只打印项目/容器发现结果，不做任何改动
#
# 设计要点：
#   - 项目 = $SERVICE_ROOT/<一级目录>；零配置自动发现（EXCLUDE_PROJECTS 除外）
#   - 相关容器：compose 容器按 working_dir 归属（含子目录）；非 compose 容器按 bind mount 归属
#   - 停止用 compose stop / docker stop（不 down/不重建）；启动用 compose start / docker start
#   - AutoRemove 容器（如面板托管的实例）停止后由其管理器重建，脚本只等待确认
#   - 无论备份成败都启动（trap 兜底）；启动失败立刻通知
#   - 项目钩子：hooks/<项目>.pre-stop 存在且可执行时，停容器前先运行；返回非 0 → 跳过该项目并告警
#
# 配置：默认值见下方「配置区」，机器相关的覆盖写在同目录 backup.conf（不入 git）
# 密钥：同目录 .env（RESTIC_REPOSITORY / RESTIC_PASSWORD_FILE / TG_* ...，不入 git）
# =============================================================================
set -o pipefail
umask 077
export LC_ALL=C.UTF-8

BACKUP_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# ---------------------------- 配置区（默认值；用 backup.conf 覆盖） ---------------
SERVICE_ROOT="$(dirname "$BACKUP_DIR")"            # 项目根目录，默认为本目录的上级
EXCLUDE_PROJECTS=("$(basename "$BACKUP_DIR")")      # 不当作项目处理的一级目录（本目录已由 host 组覆盖）
PRIORITY=()                          # 优先处理的项目（尽早恢复的服务放前面）
STOP_TIMEOUT=300                     # compose/docker stop 的宽限秒数
CONTAINER_LOG_DIR=/var/log/docker-backup/containers   # 停容器前导出的容器日志
CONTAINER_LOG_RETENTION_DAYS=30
LOCK_FILE=/run/docker-backup.lock
HOST_TAG="$(hostname -s)"            # restic --host，同一仓库多机共用时用于区分
MANAGED_WAIT_MAX=600                 # 等待管理器重建 AutoRemove 容器的最长秒数
HOST_PATHS=(/etc /root /usr/local/sbin /usr/local/bin /var/spool/cron)   # host 组备份路径
HOST_EXCLUDES=(/root/.cache /root/.npm)                                  # host 组排除（restic --exclude 语法）
HOST_SERVICES_TO_STOP=()             # host 组备份前停止的 systemd 服务（如面板），为空则不停
PVE_CONFIG_DB=/var/lib/pve-cluster/config.db          # 存在且有 sqlite3 时，快照到 PVE_CONFIG_DB_SNAPSHOT 并纳入 host 组
PVE_CONFIG_DB_SNAPSHOT=/var/backups/pve-config.db
KEEP_ARGS=(--keep-daily 7 --keep-weekly 4 --keep-monthly 3)
# ------------------------------------------------------------------------------
# shellcheck disable=SC1091
[ -r "$BACKUP_DIR/backup.conf" ] && . "$BACKUP_DIR/backup.conf"

NOTIFY="$BACKUP_DIR/notify.sh"
TS=$(date +%Y%m%d_%H%M%S)
SCRIPT_T0=$(date +%s)

log()  { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "WARN: $*"; }
err()  { log "ERROR: $*"; }
notify() { "$NOTIFY" "$@" >/dev/null 2>&1 || true; }
hsize() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }

# ---------------------------- 参数 ----------------------------------------------
MODE=normal; ONLY=""
case "${1:-}" in
  "")        ;;
  --seed)    MODE=seed ;;
  --only)    MODE=only; ONLY="${2:-}"; [ -n "$ONLY" ] || { echo "usage: $0 --only <project|host>"; exit 2; } ;;
  --dry-run) MODE=dry ;;
  *) echo "usage: $0 [--seed | --only <project|host> | --dry-run]"; exit 2 ;;
esac

# ---------------------------- 锁 / 环境 -------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then err "another backup is running (lock $LOCK_FILE)"; exit 1; fi
[ -r "$BACKUP_DIR/.env" ] || { err "missing $BACKUP_DIR/.env (copy .env.example)"; exit 2; }
# shellcheck disable=SC1091
set -a; . "$BACKUP_DIR/.env"; set +a
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD_FILE:?}"
mkdir -p "$CONTAINER_LOG_DIR"
# 项目级排除清单（restic --exclude-file 语法），不存在则不排除
EXCLUDE_ARGS=(); [ -r "$BACKUP_DIR/excludes.txt" ] && EXCLUDE_ARGS=(--exclude-file "$BACKUP_DIR/excludes.txt")

# ---------------------------- 状态（trap 用） -------------------------------------
CUR_PROJECT=""                 # 正在处理（已停容器尚未启动）的项目
STOPPED_GROUPS=()              # "compose_project<TAB>working_dir<TAB>config_files"
STOPPED_PLAIN=()               # "container<TAB>autoremove(true|false)"
HOST_SERVICES_STOPPED=0
declare -A RESULT DOWNTIME ADDED    # 项目 -> 状态文本 / 停机秒 / restic 新增字节
FAILED=0
PROJECT_ORDER=()

# ---------------------------- restic 封装 -----------------------------------------
LAST_ADDED=0; LAST_SNAPSHOT=""; LAST_FILES=0; LAST_BYTES=0
restic_backup() {   # restic_backup <paths...> -- <extra args...>
  local out; out=$(mktemp)
  restic backup --json --quiet --host "$HOST_TAG" "$@" >"$out" 2>"$out.err"
  local rc=$?
  [ -s "$out.err" ] && sed 's/^/  restic: /' "$out.err"
  read -r LAST_SNAPSHOT LAST_ADDED LAST_FILES LAST_BYTES < <(python3 - "$out" <<'PY'
import json,sys
snap="-";added=0;files=0;byt=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line.startswith('{'): continue
    try: d=json.loads(line)
    except Exception: continue
    if d.get('message_type')=='summary':
        snap=d.get('snapshot_id','-')[:8]; added=d.get('data_added',0)
        files=d.get('total_files_processed',0); byt=d.get('total_bytes_processed',0)
print(snap,added,files,byt)
PY
)
  rm -f "$out" "$out.err"
  # rc 3 = 部分文件不可读（警告），视为成功
  if [ $rc -eq 0 ] || [ $rc -eq 3 ]; then
    [ $rc -eq 3 ] && warn "restic: some files could not be read (rc=3)"
    return 0
  fi
  return $rc
}

# ---------------------------- 容器发现 ---------------------------------------------
DISCOVER_PY=$(cat <<'PY'
import json,sys,os
root=sys.argv[1].rstrip('/')
projects=[d for d in sorted(os.listdir(root)) if os.path.isdir(os.path.join(root,d))]
def proj_of(path):
    if not path: return None
    p=os.path.abspath(path)+'/'
    for d in projects:
        if p.startswith(root+'/'+d+'/'): return d
    return None
for c in json.load(sys.stdin):
    name=c['Name'].lstrip('/')
    L=c['Config'].get('Labels') or {}
    cp=L.get('com.docker.compose.project','')
    wd=L.get('com.docker.compose.project.working_dir','')
    cf=L.get('com.docker.compose.project.config_files','')
    p=proj_of(wd) if cp else None
    if p:
        print('\t'.join(['compose',p,name,cp,wd,cf])); continue
    seen=set()
    for m in c.get('Mounts',[]):
        if m.get('Type')!='bind': continue
        q=proj_of(m.get('Source',''))
        if q and q not in seen:
            seen.add(q); print('\t'.join(['plain',q,name,'','','']))
PY
)
discover() {
  local ids; ids=$(docker ps -q)
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  docker inspect $ids | python3 -c "$DISCOVER_PY" "$SERVICE_ROOT"
}
mapfile -t DISC < <(discover)

all_projects() {
  local d n
  for d in "$SERVICE_ROOT"/*/; do
    n=$(basename "$d")
    [[ " ${EXCLUDE_PROJECTS[*]} " == *" $n "* ]] && continue
    echo "$n"
  done
}
ordered_projects() {
  local p all; all=$(all_projects)
  for p in "${PRIORITY[@]}"; do grep -qx "$p" <<<"$all" && echo "$p"; done
  for p in $all; do [[ " ${PRIORITY[*]} " == *" $p "* ]] || echo "$p"; done
}
groups_of() { printf '%s\n' "${DISC[@]}" | awk -F'\t' -v p="$1" '$1=="compose" && $2==p {print $4"\t"$5"\t"$6}' | sort -u; }
plains_of() { printf '%s\n' "${DISC[@]}" | awk -F'\t' -v p="$1" '$1=="plain"   && $2==p {print $3}' | sort -u; }

compose_cmd() {   # compose_cmd "<cp>\t<wd>\t<cf>" -> 打印 docker compose 参数数组（NUL 分隔）
  local cp wd cf f
  IFS=$'\t' read -r cp wd cf <<<"$1"
  printf '%s\0' docker compose -p "$cp" --project-directory "$wd"
  IFS=',' read -ra files <<<"$cf"
  for f in "${files[@]}"; do
    [ -n "$f" ] || continue
    [[ "$f" = /* ]] || f="$wd/$f"
    printf '%s\0' -f "$f"
  done
}
run_compose() {   # run_compose "<group>" <compose subcommand...>
  local g=$1; shift
  local -a cmd; mapfile -d '' -t cmd < <(compose_cmd "$g")
  "${cmd[@]}" "$@"
}

container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
wait_for_container() {   # wait_for_container <name> <max_s>
  local c=$1 max=$2 deadline
  deadline=$(( $(date +%s) + max ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    container_running "$c" && return 0
    sleep 5
  done
  return 1
}

# ---------------------------- 启动（正常路径与 trap 共用） --------------------------
start_current_project() {
  [ -n "$CUR_PROJECT" ] || return 0
  local proj=$CUR_PROJECT g c ar cp ok=1
  log "[$proj] starting containers"
  for g in "${STOPPED_GROUPS[@]}"; do
    cp=${g%%$'\t'*}
    if run_compose "$g" start; then log "[$proj] compose '$cp' started"
    else err "[$proj] compose '$cp' START FAILED"; ok=0; notify "❌ 备份后启动失败" "项目 $proj / compose $cp 无法启动，请立即检查"; fi
  done
  for c in "${STOPPED_PLAIN[@]}"; do
    IFS=$'\t' read -r c ar <<<"$c"
    if docker inspect "$c" >/dev/null 2>&1; then
      if docker start "$c" >/dev/null; then log "[$proj] container '$c' started"
      else err "[$proj] container '$c' START FAILED"; ok=0; notify "❌ 备份后启动失败" "项目 $proj / 容器 $c 无法启动"; fi
    elif [ "$ar" = true ]; then
      log "[$proj] '$c' was AutoRemove; waiting up to ${MANAGED_WAIT_MAX}s for its manager to recreate it"
      if wait_for_container "$c" "$MANAGED_WAIT_MAX"; then log "[$proj] '$c' is back (running)"
      else err "[$proj] '$c' did NOT come back within ${MANAGED_WAIT_MAX}s"; ok=0
           notify "❌ 备份后容器未回来" "项目 $proj：AutoRemove 容器 $c 在 ${MANAGED_WAIT_MAX}s 内未被管理器重建，请检查其管理器"; fi
    else
      err "[$proj] container '$c' disappeared and is not AutoRemove"; ok=0
      notify "❌ 备份后容器丢失" "项目 $proj：容器 $c 不存在且非 AutoRemove"
    fi
  done
  STOPPED_GROUPS=(); STOPPED_PLAIN=(); CUR_PROJECT=""
  [ $ok = 1 ]
}
start_host_services() {
  [ "$HOST_SERVICES_STOPPED" = 1 ] || return 0
  if systemctl start "${HOST_SERVICES_TO_STOP[@]}"; then log "[host] ${HOST_SERVICES_TO_STOP[*]} started"
  else err "[host] failed to start ${HOST_SERVICES_TO_STOP[*]}"; notify "❌ 备份后宿主服务启动失败" "systemctl start ${HOST_SERVICES_TO_STOP[*]} 失败"; fi
  HOST_SERVICES_STOPPED=0
}
on_exit() {
  local rc=$?
  if [ -n "$CUR_PROJECT" ]; then warn "trap: script exiting while project '$CUR_PROJECT' is stopped — starting it"; start_current_project || true; fi
  start_host_services || true
  exit $rc
}
trap on_exit EXIT
trap 'err "interrupted"; exit 130' INT TERM

# ---------------------------- 单个项目 -------------------------------------------
process_project() {
  local proj=$1 dir t0 tstop g c cp ar logf st="✅" note=""
  dir="$SERVICE_ROOT/$proj"          # 注意：不能与 proj 写在同一条 local 里（展开时 proj 尚未赋值）
  PROJECT_ORDER+=("$proj"); DOWNTIME[$proj]=0; ADDED[$proj]=0
  mapfile -t groups < <(groups_of "$proj")
  mapfile -t plains < <(plains_of "$proj")
  log "[$proj] compose groups: ${#groups[@]}, plain containers: ${#plains[@]}"

  if [ "$MODE" = dry ]; then
    for g in "${groups[@]}"; do log "[$proj]   compose: $(echo "$g" | cut -f1)  wd=$(echo "$g" | cut -f2)"; done
    for c in "${plains[@]}"; do log "[$proj]   plain:   $c (AutoRemove=$(docker inspect -f '{{.HostConfig.AutoRemove}}' "$c"))"; done
    RESULT[$proj]="dry"; return 0
  fi

  if [ "$MODE" = seed ]; then
    log "[$proj] seed mode: backing up without stopping"
    if restic_backup "$dir" --tag docker --tag "$proj" "${EXCLUDE_ARGS[@]}"; then
      ADDED[$proj]=$LAST_ADDED; RESULT[$proj]="✅ seed snap=$LAST_SNAPSHOT +$(hsize "$LAST_ADDED")"
      log "[$proj] restic ok snapshot=$LAST_SNAPSHOT added=$(hsize "$LAST_ADDED") files=$LAST_FILES"
    else RESULT[$proj]="❌ restic failed"; FAILED=1; err "[$proj] restic backup failed"; fi
    return 0
  fi

  # --- pre-stop 钩子：hooks/<项目>.pre-stop <项目名> <项目目录> <compose组数> <裸容器数>；非 0 退出 → 跳过 ---
  local hook="$BACKUP_DIR/hooks/$proj.pre-stop" hmsg
  if [ -x "$hook" ]; then
    if ! hmsg=$("$hook" "$proj" "$dir" "${#groups[@]}" "${#plains[@]}" 2>&1); then
      err "[$proj] pre-stop hook refused: ${hmsg:-no message}"
      RESULT[$proj]="❌ 跳过：pre-stop 钩子拒绝"; FAILED=1
      notify "❌ $proj 备份跳过" "pre-stop 钩子拒绝停机：${hmsg:-无说明}"
      return 0
    fi
    [ -n "$hmsg" ] && log "[$proj] pre-stop hook: $hmsg"
  fi

  # --- 停止 ---
  CUR_PROJECT=$proj; STOPPED_GROUPS=(); STOPPED_PLAIN=()
  t0=$(date +%s); mkdir -p "$CONTAINER_LOG_DIR/$proj"
  for g in "${groups[@]}"; do
    cp=${g%%$'\t'*}; logf="$CONTAINER_LOG_DIR/$proj/${cp}_$TS.log"
    run_compose "$g" logs --no-color --timestamps >"$logf" 2>&1 || warn "[$proj] compose '$cp' logs export failed"
    log "[$proj] compose stop '$cp' (timeout ${STOP_TIMEOUT}s)"
    if run_compose "$g" stop -t "$STOP_TIMEOUT" >/dev/null 2>&1; then STOPPED_GROUPS+=("$g")
    else err "[$proj] compose stop '$cp' failed"; STOPPED_GROUPS+=("$g"); st="⚠️"; note="stop失败 "; fi
  done
  for c in "${plains[@]}"; do
    ar=$(docker inspect -f '{{.HostConfig.AutoRemove}}' "$c" 2>/dev/null || echo false)
    docker logs --timestamps "$c" >"$CONTAINER_LOG_DIR/$proj/${c}_$TS.log" 2>&1 || warn "[$proj] docker logs '$c' failed"
    log "[$proj] docker stop '$c' (timeout ${STOP_TIMEOUT}s, AutoRemove=$ar)"
    if docker stop -t "$STOP_TIMEOUT" "$c" >/dev/null 2>&1; then STOPPED_PLAIN+=("$c"$'\t'"$ar")
    else err "[$proj] docker stop '$c' failed"; STOPPED_PLAIN+=("$c"$'\t'"$ar"); st="⚠️"; note="stop失败 "; fi
  done
  tstop=$(date +%s); log "[$proj] stopped in $((tstop - t0))s"

  # --- 备份 ---
  if restic_backup "$dir" --tag docker --tag "$proj" "${EXCLUDE_ARGS[@]}"; then
    ADDED[$proj]=$LAST_ADDED
    log "[$proj] restic ok snapshot=$LAST_SNAPSHOT added=$(hsize "$LAST_ADDED") files=$LAST_FILES"
  else
    err "[$proj] restic backup FAILED"; st="❌"; note="${note}restic失败 "; FAILED=1
  fi

  # --- 启动 ---
  if ! start_current_project; then st="❌"; note="${note}启动异常 "; FAILED=1; fi
  DOWNTIME[$proj]=$(( $(date +%s) - t0 ))
  RESULT[$proj]="$st ${note}停机 ${DOWNTIME[$proj]}s +$(hsize "${ADDED[$proj]}")"
  log "[$proj] done: ${RESULT[$proj]}"
}

# ---------------------------- host 组 ----------------------------------------------
process_host() {
  local t0 st="✅" note="" paths excl f
  PROJECT_ORDER+=(host); DOWNTIME[host]=0; ADDED[host]=0
  paths=("${HOST_PATHS[@]}" "$BACKUP_DIR")
  # SERVICE_ROOT 顶层散文件（不属于任何项目目录）
  while IFS= read -r f; do paths+=("$f"); done < <(find "$SERVICE_ROOT" -maxdepth 1 -type f)
  excl=(); for f in "${HOST_EXCLUDES[@]}"; do excl+=(--exclude "$f"); done
  if [ "$MODE" = dry ]; then log "[host] paths: ${paths[*]}"; RESULT[host]="dry"; return 0; fi
  t0=$(date +%s)
  if [ "$MODE" != seed ] && [ ${#HOST_SERVICES_TO_STOP[@]} -gt 0 ]; then
    log "[host] stopping ${HOST_SERVICES_TO_STOP[*]}"
    if systemctl stop "${HOST_SERVICES_TO_STOP[@]}"; then HOST_SERVICES_STOPPED=1
    else warn "[host] failed to stop host services (continuing)"; st="⚠️"; note="服务stop失败 "; fi
  fi
  # PVE：pmxcfs 的 sqlite 库用 .backup 做一致快照（直接拷文件可能拿到写一半的页）
  if [ -n "$PVE_CONFIG_DB" ] && [ -f "$PVE_CONFIG_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
    rm -f "$PVE_CONFIG_DB_SNAPSHOT"
    if sqlite3 "$PVE_CONFIG_DB" ".backup $PVE_CONFIG_DB_SNAPSHOT"; then log "[host] pve config.db snapshot ok"; paths+=("$PVE_CONFIG_DB_SNAPSHOT")
    else warn "[host] pve config.db snapshot failed"; st="⚠️"; note="${note}config.db失败 "; fi
  fi
  # 只备份存在的路径
  local -a exist=(); for f in "${paths[@]}"; do [ -e "$f" ] && exist+=("$f") || warn "[host] path missing: $f"; done
  if restic_backup "${exist[@]}" --tag host "${excl[@]}"; then
    ADDED[host]=$LAST_ADDED; log "[host] restic ok snapshot=$LAST_SNAPSHOT added=$(hsize "$LAST_ADDED") files=$LAST_FILES"
  else err "[host] restic backup FAILED"; st="❌"; note="${note}restic失败 "; FAILED=1; fi
  start_host_services
  DOWNTIME[host]=$(( $(date +%s) - t0 ))
  RESULT[host]="$st ${note}$([ "$MODE" != seed ] && [ ${#HOST_SERVICES_TO_STOP[@]} -gt 0 ] && echo "服务停 ${DOWNTIME[host]}s ")+$(hsize "${ADDED[host]}")"
  log "[host] done: ${RESULT[host]}"
}

# ---------------------------- 主流程 ------------------------------------------------
log "===== backup.sh start mode=$MODE${ONLY:+ only=$ONLY} ====="
if [ "$MODE" != dry ]; then
  if ! restic cat config >/dev/null 2>&1; then
    err "restic repository unreachable: $RESTIC_REPOSITORY"; notify "❌ Docker 备份未开始" "restic 仓库不可达：$RESTIC_REPOSITORY"; exit 1
  fi
  restic unlock >/dev/null 2>&1 || true
fi

case "$MODE" in
  only)
    if [ "$ONLY" = host ]; then process_host
    elif [ -d "$SERVICE_ROOT/$ONLY" ]; then process_project "$ONLY"
    else err "no such project: $ONLY"; exit 2; fi
    ;;
  *)
    for p in $(ordered_projects); do process_project "$p"; done
    process_host
    ;;
esac

# ---------------------------- 保留策略 / 维护 ----------------------------------------
MAINT=""
if [ "$MODE" = normal ]; then
  log "restic forget ${KEEP_ARGS[*]} (group-by host,tags)"
  if restic forget --host "$HOST_TAG" --group-by host,tags "${KEEP_ARGS[@]}" --quiet; then MAINT+="forget✅ "; else MAINT+="forget❌ "; FAILED=1; fi
  if [ "$(date +%u)" = 7 ]; then
    log "sunday: restic prune --max-unused 10%"
    if restic prune --max-unused 10% --quiet; then MAINT+="prune✅ "; else MAINT+="prune❌ "; FAILED=1; fi
    log "sunday: restic check --read-data-subset=5%"
    if restic check --read-data-subset=5% --quiet; then MAINT+="check✅ "; else MAINT+="check❌ "; FAILED=1; fi
  fi
  find "$CONTAINER_LOG_DIR" -type f -name '*.log' -mtime +"$CONTAINER_LOG_RETENTION_DAYS" -delete 2>/dev/null
fi

# ---------------------------- 汇总 ----------------------------------------------------
TOTAL=$(( $(date +%s) - SCRIPT_T0 )); TOTAL_ADDED=0; body=""
for p in "${PROJECT_ORDER[@]}"; do body+="${RESULT[$p]}  $p"$'\n'; TOTAL_ADDED=$((TOTAL_ADDED + ${ADDED[$p]:-0})); done
body+="— 总耗时 $((TOTAL/60))m$((TOTAL%60))s，restic 新增 $(hsize "$TOTAL_ADDED")${MAINT:+，$MAINT}"
log "summary:"; printf '%s\n' "$body" | sed 's/^/  /'
if [ "$MODE" != dry ]; then
  if [ "$FAILED" = 1 ]; then notify "❌ Docker 备份有失败 ($MODE)" "$body"; else notify "✅ Docker 备份完成 ($MODE)" "$body"; fi
fi
log "===== backup.sh end (failed=$FAILED) ====="
exit $FAILED
