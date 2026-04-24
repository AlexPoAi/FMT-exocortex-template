#!/bin/bash
# close-task.sh — обязательный финиш каждой задачи
# Использование:
#   ./close-task.sh "описание что сделано"
#   ./close-task.sh --scope-file /tmp/close-task-scope.tsv "описание что сделано"
#
# Scope file format (tab separated):
#   repo-basename<TAB>relative/path/from/repo/root
# Example:
#   VK-offee<TAB>PACK-park-development/PROJECT-STATUS.md
#   DS-strategy<TAB>inbox/WP-73-example.md

set -u

SCOPE_FILE=""
SCOPED_CLOSE=0

if [ "${1:-}" = "--scope-file" ]; then
    SCOPE_FILE="${2:-}"
    shift 2 || true
    SCOPED_CLOSE=1
    if [ -z "$SCOPE_FILE" ] || [ ! -f "$SCOPE_FILE" ]; then
        echo "❌ scope-file не найден: ${SCOPE_FILE:-<empty>}" >&2
        exit 1
    fi
fi

DESCRIPTION="${1:-без описания}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
TODAY=$(date '+%Y-%m-%d')
CURRENT_WEEK_NUM=$(date +%V)
CURRENT_WEEK_LABEL="W${CURRENT_WEEK_NUM#0}"
WEEK_START=$(date -v-monday '+%Y-%m-%d' 2>/dev/null || date -d 'monday this week' '+%Y-%m-%d' 2>/dev/null || echo "$TODAY")
WEEK_END=$(date -v+sunday '+%Y-%m-%d' 2>/dev/null || date -d 'sunday this week' '+%Y-%m-%d' 2>/dev/null || echo "$TODAY")
SESSION_AGENT_LABEL="${SESSION_AGENT_LABEL:-${AI_SESSION_AGENT:-Codex (GPT-5)}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../roles/synchronizer/scripts/resolve-workspace.sh" ]; then
    RESOLVE_WORKSPACE_SH="$SCRIPT_DIR/../roles/synchronizer/scripts/resolve-workspace.sh"
elif [ -f "$SCRIPT_DIR/FMT-exocortex-template/roles/synchronizer/scripts/resolve-workspace.sh" ]; then
    RESOLVE_WORKSPACE_SH="$SCRIPT_DIR/FMT-exocortex-template/roles/synchronizer/scripts/resolve-workspace.sh"
else
    echo "❌ resolve-workspace.sh не найден. Невозможно определить workspace." >&2
    exit 1
fi
eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"

SESSION_CONTEXT="$DS_STRATEGY_DIR/current/SESSION-CONTEXT.md"
LOG="$HOME/Library/Logs/close-task.log"
CLAUDE_PROJECT_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"
BRAIN_DIR="$HOME/.claude/projects/$CLAUDE_PROJECT_SLUG/memory"
BRAIN="$BRAIN_DIR/project-brain.md"
EXOCORTEX_BACKUP="$DS_STRATEGY_DIR/exocortex"
UPDATE_ECOSYSTEM="$FMT_EXOCORTEX_DIR/roles/extractor/scripts/update-ecosystem.sh"
DAY_CLOSE_NOTIFY_SCRIPT="$FMT_EXOCORTEX_DIR/roles/synchronizer/scripts/notify.sh"

REPOS=(
    "$WORKSPACE_DIR/VK-offee"
    "$WORKSPACE_DIR/creativ-convector"
    "$DS_STRATEGY_DIR"
    "$FMT_EXOCORTEX_DIR"
)

PUSHED=()
CHANGED_REPOS=()
ERRORS=()
WARNINGS=()

log() {
    echo "[$TIMESTAMP] $1" >> "$LOG"
}

scope_paths_for_repo() {
    local repo_name="$1"
    [ "$SCOPED_CLOSE" -eq 1 ] || return 0
    awk -F '\t' -v repo="$repo_name" '$1 == repo { print $2 }' "$SCOPE_FILE"
}

scope_has_repo() {
    local repo_name="$1"
    [ "$SCOPED_CLOSE" -eq 1 ] || return 0
    awk -F '\t' -v repo="$repo_name" '$1 == repo { found=1 } END { exit found ? 0 : 1 }' "$SCOPE_FILE"
}

record_error() {
    ERRORS+=("$1")
    log "ERROR: $1"
}

record_warning() {
    WARNINGS+=("$1")
    log "WARN: $1"
}

repo_has_blocking_git_state() {
    local repo="$1"
    local git_dir
    git_dir=$(git -C "$repo" rev-parse --git-dir 2>/dev/null) || return 1
    case "$git_dir" in
        /*) ;;
        *) git_dir="$repo/$git_dir" ;;
    esac

    [ -d "$git_dir/rebase-merge" ] && return 0
    [ -d "$git_dir/rebase-apply" ] && return 0
    [ -f "$git_dir/MERGE_HEAD" ] && return 0
    [ -f "$git_dir/CHERRY_PICK_HEAD" ] && return 0
    [ -f "$git_dir/REVERT_HEAD" ] && return 0
    [ -f "$git_dir/BISECT_LOG" ] && return 0
    [ -f "$git_dir/index.lock" ] && return 0
    return 1
}

update_session_context_file() {
    local file="$1"
    local timestamp="$2"
    local description="$3"
    local close_marker="$4"
    local entry="$5"
    local current_week_label="$6"
    local week_start="$7"
    local week_end="$8"
    local session_agent_label="$9"
    local tmp
    tmp=$(mktemp)

    if ! python3 - "$file" "$timestamp" "$description" "$close_marker" "$entry" "$current_week_label" "$week_start" "$week_end" "$session_agent_label" > "$tmp" <<'PY'
from pathlib import Path
import re
import sys

file_path, timestamp, description, close_marker, entry, current_week_label, week_start, week_end, session_agent_label = sys.argv[1:]
text = Path(file_path).read_text()

text = re.sub(
    r'(^> Последнее обновление: ).*$',
    fr'\g<1>{timestamp[:10]}',
    text,
    flags=re.M,
)

section_pattern = re.compile(r'^## .*$', re.M)
headers = list(section_pattern.finditer(text))
preamble = text[:headers[0].start()] if headers else text
sections = {}
order = []
for i, match in enumerate(headers):
    header = match.group(0)
    start = match.start()
    end = headers[i + 1].start() if i + 1 < len(headers) else len(text)
    body = text[match.end():end]
    body = re.sub(r'\n?---\n\s*$', '', body, flags=re.S)
    sections[header] = body.strip("\n")
    order.append(header)


def set_section(header: str, body: str):
    if header not in order:
        order.append(header)
    sections[header] = body.rstrip()


def update_done_today(header: str, new_entry: str):
    existing = sections.get(header)
    if existing is None:
        order.append(header)
        sections[header] = new_entry
        return

    lines = [line for line in existing.splitlines() if line.strip()]
    if new_entry not in lines:
        lines = [new_entry, *lines]
    sections[header] = "\n".join(lines)


set_section(
    "## Где мы находимся",
    f"**Последнее обновление:** {timestamp}\n"
    f"**Сессия:** {current_week_label}, активная неделя {week_start} → {week_end}\n"
    f"**Агент:** {session_agent_label}\n"
    "**Рабочий терминал:** ~/Github/",
)

set_section(
    "## Что делаем прямо сейчас",
    f"**Статус:** задача закрыта — {description}\n"
    f"**Активный РП:** {current_week_label} / текущий рабочий цикл экзокортекса\n"
    "**Следующий шаг:** Открыть следующий рабочий цикл из обновлённого SESSION-CONTEXT без потери уже сохранённых артефактов.",
)

update_done_today(f"## Что сделано сегодня ({timestamp[:10]})", entry)

set_section(
    "## Следующий шаг",
    f"{close_marker}\n"
    "1. Проверить, что SESSION-CONTEXT и рабочие продукты сохранены в одном контуре закрытия.\n"
    "2. Открыть следующий рабочий цикл от текущего truthful состояния.\n"
    "3. Если остались незакрытые хвосты, зафиксировать их отдельной задачей в INBOX.",
)

clean_preamble = preamble.rstrip()
if clean_preamble.endswith("\n---"):
    clean_preamble = clean_preamble[:-4].rstrip()

parts = [clean_preamble] if clean_preamble else []
for header in order:
    body = sections[header].rstrip()
    block = f"{header}\n{body}" if body else header
    parts.append(block.rstrip())

sys.stdout.write("\n\n---\n\n".join(part for part in parts if part) + "\n")
PY
    then
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$file"
}

run_git_close_for_repo() {
    local repo="$1"
    local repo_name
    repo_name=$(basename "$repo")

    [ -d "$repo/.git" ] || return 0

    if [ "$SCOPED_CLOSE" -eq 1 ] && ! scope_has_repo "$repo_name"; then
        return 0
    fi

    if [ -z "$(git -C "$repo" status --porcelain)" ]; then
        # Репо чистый — всё равно тянем remote чтобы не накапливать дрейф
        git -C "$repo" pull --rebase --autostash origin main >> "$LOG" 2>&1 || true
        return 0
    fi

    if repo_has_blocking_git_state "$repo"; then
        record_warning "$repo_name: repo skipped due to active git operation state"
        return 0
    fi

    CHANGED_REPOS+=("$repo_name")

    if ! git -C "$repo" pull --rebase --autostash origin main >> "$LOG" 2>&1; then
        record_error "$repo_name: git pull --rebase --autostash origin main failed"
        return 1
    fi

    if [ "$SCOPED_CLOSE" -eq 1 ]; then
        while IFS= read -r scoped_path; do
            [ -n "$scoped_path" ] || continue
            if ! git -C "$repo" add -- "$scoped_path" >> "$LOG" 2>&1; then
                record_error "$repo_name: git add failed for scoped path: $scoped_path"
                return 1
            fi
        done <<EOF
$(scope_paths_for_repo "$repo_name")
EOF
    else
        if ! git -C "$repo" add -A >> "$LOG" 2>&1; then
            record_error "$repo_name: git add failed"
            return 1
        fi
    fi

    if ! git -C "$repo" diff --cached --quiet >> "$LOG" 2>&1; then
        if ! git -C "$repo" commit -m "close: $DESCRIPTION [$TIMESTAMP]" >> "$LOG" 2>&1; then
            record_error "$repo_name: git commit failed"
            return 1
        fi
    fi

    if ! git -C "$repo" push origin main >> "$LOG" 2>&1; then
        record_error "$repo_name: git push origin main failed"
        return 1
    fi

    if [ ${#PUSHED[@]} -eq 0 ] || [[ ! " ${PUSHED[*]} " =~ " ${repo_name} " ]]; then
        PUSHED+=("$repo_name")
    fi
    log "Запушено: $repo"
    return 0
}

run_git_close_pass() {
    for REPO in "${REPOS[@]}"; do
        run_git_close_for_repo "$REPO"
    done
}

verify_repos_clean() {
    local repo repo_name
    if [ "$SCOPED_CLOSE" -eq 1 ]; then
        log "Scoped close: skipping whole-worktree clean verification"
        return 0
    fi
    for repo in "${REPOS[@]}"; do
        [ -d "$repo/.git" ] || continue
        repo_name=$(basename "$repo")
        if [ -n "$(git -C "$repo" status --porcelain)" ]; then
            record_error "$repo_name: working tree still dirty after close-flow"
        fi
    done
}

verify_expected_artifacts() {
    # WeekPlan existence gate: success запрещён без физического файла текущей недели
    # Используем find вместо compgen -G: compgen не надёжен с пробелами в паттерне
    local current_week
    current_week=$(date +%V | sed 's/^0//')
    local weekplan_dir="$DS_STRATEGY_DIR/current"
    if ! find "$weekplan_dir" -maxdepth 1 -name "WeekPlan W${current_week} *.md" | grep -q .; then
        record_error "WeekPlan W${current_week} не существует физически — success запрещён (создай файл или проверь номер недели)"
    fi

    # SESSION-CONTEXT existence gate: файл должен существовать и не быть пустым
    if [ ! -s "$SESSION_CONTEXT" ]; then
        record_error "SESSION-CONTEXT.md отсутствует или пустой — success запрещён"
    fi

    if ! grep -Fq "**Последнее обновление:** $TIMESTAMP" "$SESSION_CONTEXT" 2>/dev/null; then
        record_error "SESSION-CONTEXT.md не обновлён текущим timestamp — success запрещён"
    fi

    if ! grep -Fq "$TODAY" "$SESSION_CONTEXT" 2>/dev/null; then
        record_error "SESSION-CONTEXT.md не содержит сегодняшнюю дату $TODAY — success запрещён"
    fi
}

update_session_context() {
    local entry="- ✅ [$TIMESTAMP] $DESCRIPTION"
    local close_marker="- 🔒 [$(date '+%H:%M')] Сессия закрыта"

    if [ ! -f "$SESSION_CONTEXT" ]; then
        record_error "SESSION-CONTEXT.md not found: $SESSION_CONTEXT"
        return 1
    fi

    if ! update_session_context_file "$SESSION_CONTEXT" "$TIMESTAMP" "$DESCRIPTION" "$close_marker" "$entry" "$CURRENT_WEEK_LABEL" "$WEEK_START" "$WEEK_END" "$SESSION_AGENT_LABEL"; then
        record_error "Не удалось обновить SESSION-CONTEXT.md"
        return 1
    fi

    return 0
}

backup_exocortex() {
    if [ ! -d "$BRAIN_DIR" ]; then
        record_error "Memory directory not found: $BRAIN_DIR"
        return 1
    fi

    if ! mkdir -p "$EXOCORTEX_BACKUP"; then
        record_error "Не удалось создать директорию backup: $EXOCORTEX_BACKUP"
        return 1
    fi

    if ! compgen -G "$BRAIN_DIR/*.md" > /dev/null; then
        record_error "В memory нет .md файлов для backup"
        return 1
    fi

    if ! cp "$BRAIN_DIR"/*.md "$EXOCORTEX_BACKUP/"; then
        record_error "Не удалось скопировать memory/*.md в exocortex backup"
        return 1
    fi

    if ! cp "$WORKSPACE_DIR/CLAUDE.md" "$EXOCORTEX_BACKUP/CLAUDE.md"; then
        record_error "Не удалось скопировать корневой CLAUDE.md в exocortex backup"
        return 1
    fi

    return 0
}

update_project_brain() {
    [ -f "$BRAIN" ] || return 0

    local brain_entry="- **$TIMESTAMP** — $DESCRIPTION"
    local tmp
    tmp=$(mktemp)

    if ! awk -v entry="$brain_entry" '
        /^## История ключевых изменений/ { print; print entry; next }
        { print }
    ' "$BRAIN" > "$tmp"; then
        rm -f "$tmp"
        record_warning "Не удалось обновить project-brain.md"
        return 1
    fi

    if ! mv "$tmp" "$BRAIN"; then
        rm -f "$tmp"
        record_warning "Не удалось сохранить project-brain.md"
        return 1
    fi

    return 0
}

update_ecosystem() {
    [ -f "$UPDATE_ECOSYSTEM" ] || return 0

    if ! bash "$UPDATE_ECOSYSTEM" >> "$LOG" 2>&1; then
        record_error "update-ecosystem.sh завершился с ошибкой"
        return 1
    fi

    return 0
}

send_day_close_notification() {
    if [ ! -x "$DAY_CLOSE_NOTIFY_SCRIPT" ]; then
        record_warning "day-close notification skipped: notify.sh not executable"
        return 0
    fi

    if ! "$DAY_CLOSE_NOTIFY_SCRIPT" synchronizer day-close >> "$LOG" 2>&1; then
        record_warning "day-close notification failed: synchronizer/day-close"
        return 1
    fi

    log "Day-close Telegram summary sent"
    return 0
}

sync_generated_changes() {
    log "Синхронизация generated changes после backup/update-ecosystem"
    run_git_close_pass
}

log "Закрытие задачи: $DESCRIPTION"
[ "$SCOPED_CLOSE" -eq 1 ] && log "Scoped close enabled: $SCOPE_FILE"

run_git_close_pass

if update_session_context; then
    if ! git -C "$DS_STRATEGY_DIR" pull --rebase --autostash origin main >> "$LOG" 2>&1; then
        record_error "DS-strategy: git pull --rebase --autostash origin main failed before SESSION-CONTEXT commit"
    elif ! git -C "$DS_STRATEGY_DIR" add current/SESSION-CONTEXT.md >> "$LOG" 2>&1; then
        record_error "DS-strategy: git add current/SESSION-CONTEXT.md failed"
    elif ! git -C "$DS_STRATEGY_DIR" diff --cached --quiet >> "$LOG" 2>&1 && ! git -C "$DS_STRATEGY_DIR" commit -m "context: $DESCRIPTION [$TIMESTAMP]" >> "$LOG" 2>&1; then
        record_error "DS-strategy: git commit for SESSION-CONTEXT failed"
    elif ! git -C "$DS_STRATEGY_DIR" push origin main >> "$LOG" 2>&1; then
        record_error "DS-strategy: git push origin main failed after SESSION-CONTEXT update"
    else
        if [ ${#PUSHED[@]} -eq 0 ] || [[ ! " ${PUSHED[*]} " =~ " DS-strategy " ]]; then
            PUSHED+=("DS-strategy")
        fi
    fi
fi

if [ "$SCOPED_CLOSE" -eq 1 ]; then
    log "Scoped close: skipping project-brain backup/update-ecosystem/sync-generated to avoid unrelated dirty changes"
else
    update_project_brain
    backup_exocortex
    update_ecosystem
    sync_generated_changes
fi
verify_repos_clean
verify_expected_artifacts

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "❌ ЗАДАЧА НЕ ЗАКРЫТА"
    echo "📝 Что сделано: $DESCRIPTION"
    echo "🚫 Что не выполнено:"
    for error in "${ERRORS[@]}"; do
        echo "- $error"
    done
    if [ ${#PUSHED[@]} -gt 0 ]; then
        echo "💾 Что реально запушено: ${PUSHED[*]}"
    else
        echo "💾 Что реально запушено: ничего"
    fi
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo "⚠️ Предупреждения:"
        for warning in "${WARNINGS[@]}"; do
            echo "- $warning"
        done
    fi
    echo "🔜 Следующий шаг: устранить ошибки и повторно запустить close-task.sh"
    echo ""
    exit 1
fi

send_day_close_notification || true

echo ""
echo "✅ ЗАДАЧА ЗАКРЫТА"
echo "📝 Что сделано: $DESCRIPTION"
if [ ${#PUSHED[@]} -gt 0 ]; then
    echo "💾 Запушено: ${PUSHED[*]}"
else
    echo "💾 Запушено: изменений не было"
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo "⚠️ Предупреждения:"
    for warning in "${WARNINGS[@]}"; do
        echo "- $warning"
    done
fi
echo "🔜 Следующий шаг: проверь DS-strategy/current/SESSION-CONTEXT.md"
echo ""
# Token monitoring and token-report removed from the canonical day-close route.
