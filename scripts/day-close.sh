#!/bin/bash
# day-close.sh — Автоматические шаги Day Close (backup + reindex + linear sync)
#
# Вызывается Claude из протокола Day Close (protocol-close.md § День, шаг 4).
# Объединяет три механических операции в одну команду.
#
# Использование:
#   day-close.sh              # все три шага
#   day-close.sh --backup     # только backup
#   day-close.sh --reindex    # только reindex
#   day-close.sh --linear     # только linear sync
#
# Конфигурация: Пути заданы через переменные ниже — настроить при установке.

set -euo pipefail

# === КОНФИГУРАЦИЯ (настроить при установке) ===
RESOLVE_WORKSPACE_SH="$HOME/Github/FMT-exocortex-template/roles/synchronizer/scripts/resolve-workspace.sh"
if [ ! -f "$RESOLVE_WORKSPACE_SH" ]; then
  RESOLVE_WORKSPACE_SH="$(cd "$(dirname "$0")/../roles/synchronizer/scripts" && pwd)/resolve-workspace.sh"
fi
if [ -f "$RESOLVE_WORKSPACE_SH" ]; then
  eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"
fi
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/Github}"
DS_STRATEGY="$WORKSPACE_DIR/DS-strategy"
EXOCORTEX_DST="$DS_STRATEGY/exocortex"
PARAMS_YAML="$WORKSPACE_DIR/params.yaml"
LOG_FILE="$WORKSPACE_DIR/DS-agent-workspace/scheduler/day-close.log"
# === /КОНФИГУРАЦИЯ ===

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[day-close]${NC} $1"; }
warn() { echo -e "${YELLOW}[day-close]${NC} $1"; }
err() { echo -e "${RED}[day-close]${NC} $1" >&2; }

resolve_memory_src() {
  local user_slug
  user_slug="$(whoami)"
  for candidate in \
    "$HOME/.claude/projects/-Users-${user_slug}-Github/memory" \
    "$HOME/.claude/projects/-Users-${user_slug}-Github-DS-strategy/memory" \
    "$HOME/.claude/projects/-Users-${user_slug}-IWE/memory" \
    "$WORKSPACE_DIR/memory"
  do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

MEMORY_SRC="${MEMORY_SRC:-$(resolve_memory_src || true)}"

resolve_selective_reindex() {
  local candidate
  for candidate in \
    "$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/selective-reindex.sh" \
    "$WORKSPACE_DIR/knowledge-mcp/scripts/selective-reindex.sh" \
    "$WORKSPACE_DIR/DS-IT-systems/DS-MCP/knowledge-mcp/scripts/selective-reindex.sh"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_linear_sync() {
  local raw candidate
  if [ -f "$PARAMS_YAML" ] && command -v python3 >/dev/null 2>&1; then
    raw=$(python3 -c 'import sys; import yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; print(d.get("linear_sync_path",""))' "$PARAMS_YAML" 2>/dev/null || true)
    if [ -n "$raw" ]; then
      candidate="${raw/#\~/$HOME}"
      if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  for candidate in \
    "$WORKSPACE_DIR/DS-IT-systems/DS-ai-systems/synchronizer/scripts/linear-sync.sh" \
    "$WORKSPACE_DIR/FMT-exocortex-template/roles/synchronizer/scripts/linear-sync.sh"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

SELECTIVE_REINDEX="${SELECTIVE_REINDEX:-$(resolve_selective_reindex || true)}"
LINEAR_SYNC="${LINEAR_SYNC:-$(resolve_linear_sync || true)}"

# --- Шаг 1: Backup memory/ + CLAUDE.md → exocortex/ ---
do_backup() {
  log "Шаг 1/3: Backup memory/ → exocortex/"

  if [ -z "${MEMORY_SRC:-}" ] || [ ! -d "$MEMORY_SRC" ]; then
    err "Memory source not found: $MEMORY_SRC"
    return 1
  fi

  mkdir -p "$EXOCORTEX_DST"

  local count=0
  for f in "$MEMORY_SRC"/*.md "$MEMORY_SRC"/*.yaml "$MEMORY_SRC"/*.yml; do
    [ -f "$f" ] || continue
    cp "$f" "$EXOCORTEX_DST/"
    count=$((count + 1))
  done

  if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
    cp "$WORKSPACE_DIR/CLAUDE.md" "$EXOCORTEX_DST/CLAUDE.md"
    count=$((count + 1))
  fi

  log "  Скопировано: $count файлов → $EXOCORTEX_DST/"
}

# --- Шаг 2: Knowledge-MCP reindex ---
do_reindex() {
  log "Шаг 2/3: Knowledge-MCP reindex"

  if [ -z "${SELECTIVE_REINDEX:-}" ] || [ ! -x "$SELECTIVE_REINDEX" ]; then
    warn "  selective-reindex.sh не найден: ${SELECTIVE_REINDEX:-not_configured_or_missing} — пропуск"
    return 0
  fi

  local changed_sources=""
  for repo in "$WORKSPACE_DIR"/PACK-* "$WORKSPACE_DIR"/DS-*; do
    [ -d "$repo/.git" ] || continue
    local repo_name
    repo_name=$(basename "$repo")
    local today_commits
    today_commits=$(git -C "$repo" log --since="today 00:00" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
    if [ "$today_commits" -gt 0 ]; then
      changed_sources="$changed_sources $repo_name"
    fi
  done

  if [ -z "$changed_sources" ]; then
    log "  Нет изменений в Pack/DS сегодня — пропуск reindex"
    return 0
  fi

  log "  Изменённые источники:$changed_sources"
  # shellcheck disable=SC2086
  "$SELECTIVE_REINDEX" $changed_sources
}

# --- Шаг 3: Linear sync ---
do_linear() {
  log "Шаг 3/3: Linear sync"

  if [ -z "${LINEAR_SYNC:-}" ] || [ ! -x "$LINEAR_SYNC" ]; then
    warn "  linear-sync.sh не найден: ${LINEAR_SYNC:-not_configured_or_missing} — пропуск"
    return 0
  fi

  "$LINEAR_SYNC"
}

# --- Лог ---
write_log() {
  local date_str
  date_str=$(date "+%Y-%m-%d %H:%M")
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$date_str | day-close | backup=$1 reindex=$2 linear=$3" >> "$LOG_FILE"
}

# --- Main ---
main() {
  local do_all=true
  local run_backup=false
  local run_reindex=false
  local run_linear=false

  for arg in "$@"; do
    case "$arg" in
      --backup)  run_backup=true; do_all=false ;;
      --reindex) run_reindex=true; do_all=false ;;
      --linear)  run_linear=true; do_all=false ;;
      --help|-h)
        echo "Использование: day-close.sh [--backup] [--reindex] [--linear]"
        echo "  Без аргументов — все три шага"
        exit 0
        ;;
      *)
        err "Неизвестный аргумент: $arg"
        exit 1
        ;;
    esac
  done

  if $do_all; then
    run_backup=true
    run_reindex=true
    run_linear=true
  fi

  log "=== Day Close (автоматические шаги) ==="

  local backup_status="skip" reindex_status="skip" linear_status="skip"

  if $run_backup; then
    if do_backup; then backup_status="ok"; else backup_status="fail"; fi
  fi

  if $run_reindex; then
    if do_reindex; then reindex_status="ok"; else reindex_status="fail"; fi
  fi

  if $run_linear; then
    if do_linear; then linear_status="ok"; else linear_status="fail"; fi
  fi

  write_log "$backup_status" "$reindex_status" "$linear_status"

  log "=== Готово ==="
  log "  backup=$backup_status  reindex=$reindex_status  linear=$linear_status"

  if [ "$backup_status" = "fail" ]; then
    err "Day Close failed: backup step is mandatory"
    exit 1
  fi
}

main "$@"
