#!/bin/bash
# code-scan.sh — ночное сканирование Downstream-репо (статистика активности)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE_WORKSPACE_SH="$SCRIPT_DIR/resolve-workspace.sh"
eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"
WORKSPACE="$WORKSPACE_DIR"
LOG_DIR="$HOME/logs/synchronizer"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/code-scan-$DATE.log"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [code-scan] $1" | tee -a "$LOG_FILE"
}

discover_repos() {
    local repos=()
    local exclude=("DS-strategy")

    for dir in "$WORKSPACE"/DS-*/; do
        [ -d "$dir/.git" ] || continue
        local name
        name=$(basename "$dir")
        local skip=false
        for ex in "${exclude[@]}"; do
            [ "$name" = "$ex" ] && skip=true && break
        done
        [ "$skip" = true ] && continue
        repos+=("$dir")
    done

    if [ "${#repos[@]}" -eq 0 ]; then
        return 0
    fi

    printf '%s\n' "${repos[@]}"
}

scan_repos() {
    local total_repos=0
    local total_commits=0

    while IFS= read -r repo_dir; do
        repo_dir="${repo_dir%/}"
        local repo_name
        repo_name=$(basename "$repo_dir")

        local commits
        commits=$(git -C "$repo_dir" log --since="24 hours ago" --oneline --no-merges 2>/dev/null || true)

        if [ -z "$commits" ]; then
            log "SKIP: $repo_name — нет коммитов за 24ч"
            continue
        fi

        local count
        count=$(echo "$commits" | wc -l | tr -d ' ')
        log "FOUND: $repo_name — $count коммитов"

        total_repos=$((total_repos + 1))
        total_commits=$((total_commits + count))
    done < <(discover_repos)

    log "Итого: $total_repos репо, $total_commits коммитов"

    if [ "$DRY_RUN" = false ] && [ "$total_repos" -gt 0 ]; then
        "$SCRIPT_DIR/notify.sh" synchronizer code-scan 2>/dev/null || true
    fi
}

log "=== Code Scan Started ==="
scan_repos
log "=== Code Scan Completed ==="
