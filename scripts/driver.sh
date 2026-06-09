#!/bin/bash
# driver.sh — внешний state-machine для pipeline-template.
# Крутит цикл: plan → build → critic → next sprint.
# Переносим: state.json в репо, восстанавливается из любого состояния.
#
# Использование:
#   driver.sh init                   — создать state.json из templates/
#   driver.sh status                 — показать текущее состояние
#   driver.sh next                   — выполнить ОДИН шаг цикла
#   driver.sh loop [--max-iter N]    — крутить next, пока done/blocked
#   driver.sh set <key> <value>      — изменить поле state.json
#   driver.sh reset                  — обнулить state.json (init заново)
#
# Env:
#   OPENCODE_BIN     путь к opencode CLI (default: opencode)
#   DRY_RUN=1        не запускать opencode, печатать команды
#   AGENT_TIMEOUT    секунд на одного агента (default 900 = 15 min)
#   STATE_PATH       путь к state.json (default ./state.json)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../templates"
DEFAULT_STATE="$SCRIPT_DIR/../state.json"

STATE_PATH="${STATE_PATH:-$DEFAULT_STATE}"
TEMPLATE_DIR="${TEMPLATE_DIR:-$SCRIPT_DIR/../templates}"
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-900}"
DRY_RUN="${DRY_RUN:-0}"

# --- цвета (если терминал) ---
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'
  C_GRN=$'\033[0;32m'
  C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m'
  C_DIM=$'\033[2m'
  C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

log()  { echo "${C_DIM}[$(date -u +%H:%M:%S)]${C_RST} $*"; }
info() { echo "${C_BLU}▸${C_RST} $*"; }
ok()   { echo "${C_GRN}✓${C_RST} $*"; }
warn() { echo "${C_YEL}!${C_RST} $*" >&2; }
err()  { echo "${C_RED}✗${C_RST} $*" >&2; }

die() { err "$*"; exit 1; }

# --- проверки ---
require_state() {
  [ -f "$STATE_PATH" ] || die "state.json not found at $STATE_PATH. Run: driver.sh init"
  jq -e . "$STATE_PATH" >/dev/null 2>&1 || die "state.json is not valid JSON"
}

# --- jq helpers ---
# Чтение с default
jget() {
  local key="$1"
  jq -r "$key // empty" "$STATE_PATH"
}

# Запись с сохранением всего остального
jset() {
  local key="$1" val="$2"
  local tmp
  tmp="$(mktemp)"
  jq "$key = $val" "$STATE_PATH" > "$tmp" && mv "$tmp" "$STATE_PATH"
}

# Добавить событие в history
jlog() {
  local event="$1" result="${2:-}"
  local tmp
  tmp="$(mktemp)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg now "$now" --arg ev "$event" --arg res "$result" \
    '.last_update = $now | .history += [{"ts": $now, "event": $ev, "result": $res, "sprint": .sprint, "phase": .phase}]' \
    "$STATE_PATH" > "$tmp" && mv "$tmp" "$STATE_PATH"
}

# --- команды ---

cmd_init() {
  if [ -f "$STATE_PATH" ]; then
    warn "state.json already exists at $STATE_PATH"
    info "Use 'driver.sh reset' to overwrite or 'driver.sh status' to view"
    return 0
  fi
  if [ ! -f "$TEMPLATE_DIR/state.json" ]; then
    err "template not found: $TEMPLATE_DIR/state.json"
    err "set TEMPLATE_DIR env var"
    return 1
  fi
  cp "$TEMPLATE_DIR/state.json" "$STATE_PATH"
  ok "initialized $STATE_PATH"
  info "Next: edit goal.md, then run 'driver.sh next'"
}

cmd_status() {
  require_state
  echo "${C_BLU}=== state ===${C_RST}"
  jq . "$STATE_PATH"
  echo ""
  echo "${C_BLU}=== last 5 events ===${C_RST}"
  jq -r '.history[-5:] | .[] | "  [\(.ts)] \(.event) (sprint=\(.sprint) phase=\(.phase)) → \(.result)"' "$STATE_PATH" 2>/dev/null || echo "  (no events)"
}

cmd_reset() {
  if [ ! -f "$TEMPLATE_DIR/state.json" ]; then
    err "template not found: $TEMPLATE_DIR/state.json"
    err "set TEMPLATE_DIR env var, e.g.: TEMPLATE_DIR=./templates driver.sh reset"
    return 1
  fi
  cp "$TEMPLATE_DIR/state.json" "$STATE_PATH"
  ok "state reset to template"
  jlog "reset" "ok"
}

cmd_set() {
  local key="$1" val="$2"
  require_state
  # Определяем тип значения
  if [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" =~ ^(true|false|null)$ ]]; then
    jset "$key" "$val"
  else
    jset "$key" "\"$val\""
  fi
  ok "set $key = $val"
}

# --- пауза для человека ---
# Использование: pause_for_human "<сообщение>"
# Печатает что произошло и ждёт Enter. В DRY_RUN или non-tty — пропускается.
pause_for_human() {
  local reason="$1"
  # В cron / pipeline / non-tty — не блокируемся
  if [ "$DRY_RUN" = "1" ] || [ ! -t 0 ]; then
    info "[pause] $reason (auto-skip: non-interactive)"
    return 0
  fi
  echo ""
  echo "${C_YEL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RST}"
  echo "${C_YEL}⏸  $reason${C_RST}"
  echo "${C_YEL}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RST}"
  echo "  state.json: $(jq -c '{phase, sprint, attempts, last_verdict, last_error}' "$STATE_PATH")"
  echo ""
  echo "  Press Enter to continue, Ctrl-C to abort..."
  read -r _
}

# --- запуск агента ---
# Использование: run_agent <agent_name> <message>
# Возвращает 0 если агент успешно завершил работу (файл-маркер появился/обновился).
run_agent() {
  local agent="$1" message="$2"
  
  if [ "$DRY_RUN" = "1" ]; then
    info "[DRY] would run: $OPENCODE_BIN run --agent $agent --message \"$message\""
    return 0
  fi
  
  if ! command -v "$OPENCODE_BIN" >/dev/null 2>&1 && [ ! -x "$OPENCODE_BIN" ]; then
    warn "opencode binary not found: $OPENCODE_BIN"
    info "Manual step required:"
    echo "  $OPENCODE_BIN run --agent $agent --message \"$message\""
    info "После завершения нажми Enter..."
    read -r _
    return 0
  fi
  
  log "running agent: $agent"
  log "message: $message"
  
  # Запускаем с таймаутом
  if timeout "$AGENT_TIMEOUT" "$OPENCODE_BIN" run --agent "$agent" --message "$message"; then
    ok "agent $agent completed"
    return 0
  else
    local code=$?
    err "agent $agent failed (exit $code) or timed out (${AGENT_TIMEOUT}s)"
    return 1
  fi
}

# --- phase handlers ---

# phase=plan → spawn planner
phase_plan() {
  info "[plan] spawning planner"
  if [ -f "plans/current.md" ]; then
    info "[plan] plans/current.md already exists, skipping planner"
    jset '.phase' '"build"'
    jset '.sprint' '1'
    jset '.contract_path' '"contracts/sprint-1.md"'
    jset '.report_path' '"reports/sprint-1.md"'
    jset '.critique_path' '"critique/sprint-1.md"'
    jlog "plan-skip" "build"
    return 0
  fi
  
  local msg
  msg="Phase: plan. Read goal.md and state.json. Write plans/current.md with all sprints. Confirm with user if needed (use questions.md). After plan is approved, exit."
  
  if run_agent planner "$msg"; then
    if [ -f "plans/current.md" ]; then
      ok "[plan] plans/current.md created"
      # Если planner задавал вопросы — пауза для человека
      if [ -f "questions.md" ]; then
        pause_for_human "planner has questions (questions.md) and plan is ready. Review plans/current.md."
      fi
      jset '.phase' '"build"'
      jset '.sprint' '1'
      jset '.contract_path' '"contracts/sprint-1.md"'
      jset '.report_path' '"reports/sprint-1.md"'
      jset '.critique_path' '"critique/sprint-1.md"'
      jlog "plan" "ok"
    else
      err "[plan] planner finished but plans/current.md not found"
      if [ -f "questions.md" ]; then
        pause_for_human "planner has questions (questions.md) and no plan. Answer them and run 'driver.sh next' to retry."
        # Не блокируем, даём возможность попробовать снова после ответа
        return 0
      fi
      jset '.phase' '"blocked"'
      jset '.last_error' '"planner did not produce plans/current.md"'
      jlog "plan" "fail"
      return 1
    fi
  else
    err "[plan] planner failed"
    jset '.phase' '"blocked"'
    jset '.last_error' '"planner agent failed"'
    jlog "plan" "fail"
    return 1
  fi
}

# phase=build → spawn build, run verify.sh
phase_build() {
  local sprint report_path contract_path
  sprint=$(jget '.sprint')
  report_path=$(jget '.report_path')
  contract_path=$(jget '.contract_path')
  
  info "[build] sprint=$sprint contract=$contract_path"
  
  # Проверяем что контракт есть
  if [ ! -f "$contract_path" ]; then
    err "[build] contract not found: $contract_path"
    info "Build должен создать контракт ДО реализации (если его нет)."
    
    local attempts
    attempts=$(jget '.attempts')
    if [ "$attempts" -lt 2 ]; then
      # Первые попытки — пусть build сам напишет контракт
      local msg
      msg="Phase: build. Sprint=$sprint. Contract $contract_path is missing. Read plans/current.md and goal.md. If contract is missing, write it FIRST (use templates/contract.md), then implement. Run scripts/verify.sh — must exit 0. Write $report_path. Exit."
      if run_agent build "$msg" && [ -f "$contract_path" ]; then
        ok "[build] contract created by build"
      else
        err "[build] build failed to create contract"
        jset '.phase' '"blocked"'
        jset '.last_error' '"contract missing and build did not create it"'
        jlog "build" "no-contract"
        return 1
      fi
    else
      err "[build] contract still missing after retries"
      jset '.phase' '"blocked"'
      jset '.last_error' '"contract missing"'
      jlog "build" "no-contract"
      return 1
    fi
  fi
  
  # Запускаем build (или retry, если уже есть отчёт)
  local msg
  msg="Phase: build. Sprint=$sprint. Read $contract_path. Implement code. Run scripts/verify.sh — must exit 0. Write $report_path. Exit."
  
  if ! run_agent build "$msg"; then
    err "[build] agent failed"
    jset '.phase' '"blocked"'
    jset '.last_error' '"build agent failed"'
    jlog "build" "fail"
    return 1
  fi
  
  if [ ! -f "$report_path" ]; then
    err "[build] report not found: $report_path"
    jset '.phase' '"blocked"'
    jset '.last_error' '"build did not write report"'
    jlog "build" "no-report"
    return 1
  fi
  
  # Запускаем verify.sh
  info "[build] running verify.sh"
  if [ -f "scripts/verify.sh" ]; then
    if bash scripts/verify.sh > /tmp/driver-verify.log 2>&1; then
      ok "[build] verify.sh passed"
      jset '.phase' '"critic"'
      jlog "build" "verify-pass"
    else
      err "[build] verify.sh failed (see /tmp/driver-verify.log)"
      # Первая попытка — не пауза, даём агенту самому исправить
      local attempts
      attempts=$(jget '.attempts')
      if [ "$attempts" -ge 1 ]; then
        # Со второй попытки — пауза, дать человеку посмотреть
        pause_for_human "verify.sh failed (attempt $((attempts+1))/$max_attempts). See /tmp/driver-verify.log and reports/sprint-$sprint.md. Press Enter to let build retry, or Ctrl-C to stop."
      fi
      jset '.phase' '"build"'
      jset '.attempts' "$(( $(jget '.attempts') + 1 ))"
      jset '.last_error' '"verify.sh failed"'
      jlog "build" "verify-fail"
      return 0  # не блокируем, даём пересобрать
    fi
  else
    warn "[build] no scripts/verify.sh, skipping (build agent must create one)"
    jset '.phase' '"critic"'
    jlog "build" "no-verify"
  fi
}

# phase=critic → spawn critic, parse verdict
phase_critic() {
  local sprint critique_path attempts max_attempts
  sprint=$(jget '.sprint')
  critique_path=$(jget '.critique_path')
  attempts=$(jget '.attempts')
  max_attempts=$(jget '.max_attempts')
  
  info "[critic] sprint=$sprint"
  
  local msg
  msg="Phase: critic. Sprint=$sprint. Read contracts/sprint-$sprint.md, reports/sprint-$sprint.md. Run scripts/verify.sh. Write $critique_path with VERDICT: PASS or VERDICT: FAIL on the last line. Exit."
  
  if ! run_agent critic "$msg"; then
    err "[critic] agent failed"
    jset '.phase' '"blocked"'
    jset '.last_error' '"critic agent failed"'
    jlog "critic" "fail"
    return 1
  fi
  
  if [ ! -f "$critique_path" ]; then
    err "[critic] critique not found: $critique_path"
    jset '.phase' '"blocked"'
    jset '.last_error' '"critic did not write critique"'
    jlog "critic" "no-critique"
    return 1
  fi
  
  # Парсим вердикт (последняя строка)
  local verdict
  verdict=$(grep -E '^VERDICT:' "$critique_path" | tail -1 | awk '{print $2}' | tr -d '[:space:]')
  
  if [ "$verdict" = "PASS" ]; then
    ok "[critic] VERDICT: PASS"
    jset '.last_verdict' '"PASS"'
    jset '.attempts' '0'
    jlog "critic" "pass"
    
    # Следующий спринт? Есть контракт ИЛИ упомянут в плане.
    local next_sprint=$((sprint + 1))
    if [ -f "contracts/sprint-$next_sprint.md" ] || { [ -f "plans/current.md" ] && grep -q "Sprint $next_sprint" "plans/current.md"; }; then
      info "[critic] moving to sprint $next_sprint"
      jset '.sprint' "$next_sprint"
      jset '.contract_path' "\"contracts/sprint-$next_sprint.md\""
      jset '.report_path' "\"reports/sprint-$next_sprint.md\""
      jset '.critique_path' "\"critique/sprint-$next_sprint.md\""
      jset '.phase' '"build"'
    else
      ok "[critic] all sprints done"
      jset '.phase' '"done"'
      jlog "done" "all-sprints"
    fi
  elif [ "$verdict" = "FAIL" ]; then
    err "[critic] VERDICT: FAIL"
    jset '.last_verdict' '"FAIL"'
    
    if [ "$attempts" -lt "$max_attempts" ]; then
      # Пауза перед retry — дать человеку посмотреть на critique
      pause_for_human "critic returned FAIL (attempt $((attempts+1))/$max_attempts). See $critique_path. Press Enter to let build retry, or Ctrl-C to stop and fix manually."
      info "[critic] retrying build (attempt $((attempts + 1))/$max_attempts)"
      jset '.phase' '"build"'
      jset '.attempts' "$((attempts + 1))"
      jlog "critic" "fail-retry"
    else
      err "[critic] max attempts reached, blocking"
      pause_for_human "critic FAIL but max attempts reached. Project is BLOCKED. Review and either fix contract/code or run: driver.sh set .attempts 0 && driver.sh set .phase build && driver.sh next"
      jset '.phase' '"blocked"'
      jset '.last_error' "\"max attempts ($max_attempts) reached\""
      jlog "critic" "blocked"
    fi
  else
    err "[critic] could not parse verdict (got: '$verdict')"
    jset '.phase' '"blocked"'
    jset '.last_error' "\"unparseable verdict: $verdict\""
    jlog "critic" "parse-error"
    return 1
  fi
}

# --- main dispatcher ---

cmd_next() {
  require_state
  local phase
  phase=$(jget '.phase')
  
  case "$phase" in
    plan)    phase_plan ;;
    build)   phase_build ;;
    critic)  phase_critic ;;
    done)    ok "project complete (phase=done)"; return 0 ;;
    blocked) err "project blocked: $(jget '.last_error')"; return 1 ;;
    *)       err "unknown phase: $phase"; return 1 ;;
  esac
  
  # Печатаем обновлённый статус
  echo ""
  cmd_status
}

cmd_loop() {
  local max_iter=100
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-iter) max_iter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  
  local iter=0
  while [ $iter -lt "$max_iter" ]; do
    iter=$((iter + 1))
    echo ""
    info "=== iteration $iter / $max_iter ==="
    
    local phase
    phase=$(jget '.phase' 2>/dev/null || echo "missing")
    if [ "$phase" = "done" ]; then
      ok "project complete"
      return 0
    fi
    if [ "$phase" = "blocked" ]; then
      err "project blocked: $(jget '.last_error')"
      return 1
    fi
    
    if ! cmd_next; then
      err "step failed, stopping"
      return 1
    fi
  done
  
  warn "max iterations ($max_iter) reached"
  return 1
}

# --- entrypoint ---
case "${1:-}" in
  init)    shift; cmd_init "$@" ;;
  status)  shift; cmd_status "$@" ;;
  reset)   shift; cmd_reset "$@" ;;
  set)     shift; cmd_set "$@" ;;
  next)    shift; cmd_next "$@" ;;
  loop)    shift; cmd_loop "$@" ;;
  help|--help|-h|"") 
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown command: $1. Run 'driver.sh help'" ;;
esac
