#!/bin/bash
# runtime-arbiter.sh — единый арбитр provider/runtime режима экосистемы
#
# Отвечает на два ортогональных вопроса:
# 1. Какой provider primary сейчас использовать локальным агентам?
# 2. Каков truthful runtime mode: local-primary / cloud-primary / degraded?
#
# Источник политики:
#   ~/Github/DS-strategy/current/RUNTIME-POLICY.env
#
# Выходы:
#   --env   → shell assignments для source/process substitution
#   default → обновляет current/RUNTIME-MODE.md и state env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE_WORKSPACE_SH="$SCRIPT_DIR/resolve-workspace.sh"
eval "$(bash "$RESOLVE_WORKSPACE_SH" --env)"
STRATEGY_DIR="$WORKSPACE_DIR/DS-strategy"
CURRENT_DIR="$STRATEGY_DIR/current"
STATE_DIR="$HOME/.local/state/exocortex"
POLICY_FILE="$CURRENT_DIR/RUNTIME-POLICY.env"
MODE_FILE="$CURRENT_DIR/RUNTIME-MODE.md"
STATE_FILE="$STATE_DIR/runtime-arbiter.env"

mkdir -p "$CURRENT_DIR" "$STATE_DIR"

if [ -f "$POLICY_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$POLICY_FILE"
    set +a
fi

AI_PROVIDER_POLICY="${AI_PROVIDER_POLICY:-auto}"
AI_PROVIDER_PREFERENCE="${AI_PROVIDER_PREFERENCE:-codex}"
AI_RUNTIME_POLICY="${AI_RUNTIME_POLICY:-split}"
CLOUD_TAKEOVER_SCOPE="${CLOUD_TAKEOVER_SCOPE:-product-only}"
CLOUD_RAG_HEALTH_URL="${CLOUD_RAG_HEALTH_URL:-}"
CLOUD_BOT_RUNTIME_DECLARED="${CLOUD_BOT_RUNTIME_DECLARED:-declared}"

codex_available=0
codex_status="missing"
codex_reason="codex_cli_not_found"

claude_available=0
claude_status="missing"
claude_reason="claude_cli_not_found"

local_control_plane="degraded"
local_control_reason="scheduler_not_loaded"

cloud_rag_status="unknown"
cloud_rag_reason="health_url_not_configured"

provider_primary="unavailable"
provider_reason="no_provider_available"

resolve_codex_path() {
    local candidate

    if [ -n "${CODEX_PATH:-}" ] && [ -x "${CODEX_PATH:-}" ]; then
        printf '%s\n' "$CODEX_PATH"
        return 0
    fi

    candidate=$(command -v codex 2>/dev/null || true)
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    for candidate in \
        "/Applications/Codex.app/Contents/Resources/codex" \
        "/usr/local/bin/codex" \
        "/opt/homebrew/bin/codex" \
        "$HOME/.local/bin/codex"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

check_codex() {
    local codex_path
    codex_path=$(resolve_codex_path 2>/dev/null || true)
    if [ -z "$codex_path" ] || [ ! -x "$codex_path" ]; then
        return
    fi

    if "$codex_path" login status >/tmp/runtime-arbiter-codex.log 2>&1; then
        if grep -Eiq "logged in|authenticated" /tmp/runtime-arbiter-codex.log 2>/dev/null; then
            codex_available=1
            codex_status="available"
            codex_reason="login_ok"
            return
        fi
        codex_status="degraded"
        codex_reason="login_status_unknown"
        return
    fi

    codex_status="degraded"
    codex_reason="login_status_failed"
}

check_claude() {
    local claude_path helper
    claude_path="${CLAUDE_PATH:-$(command -v claude 2>/dev/null || true)}"
    if [ -z "$claude_path" ] || [ ! -x "$claude_path" ]; then
        return
    fi

    helper="$HOME/.config/aist/anthropic_auth_helper.sh"
    if [ -x "$helper" ]; then
        if "$helper" >/tmp/runtime-arbiter-claude.log 2>&1; then
            claude_available=1
            claude_status="available"
            claude_reason="auth_helper_ok"
            return
        fi
        claude_status="degraded"
        claude_reason="auth_helper_failed"
        return
    fi

    if "$claude_path" --version >/tmp/runtime-arbiter-claude.log 2>&1; then
        claude_available=1
        claude_status="available"
        claude_reason="cli_present_no_helper"
        return
    fi

    claude_status="degraded"
    claude_reason="cli_version_failed"
}

check_local_control_plane() {
    if command -v launchctl >/dev/null 2>&1 && launchctl list | grep -q 'com.exocortex.scheduler'; then
        local_control_plane="available"
        local_control_reason="launchctl_scheduler_loaded"
        return
    fi

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet com.exocortex.scheduler.timer; then
        local_control_plane="available"
        local_control_reason="systemd_scheduler_active"
        return
    fi

    if [ -d "$STATE_DIR/status" ]; then
        local_control_plane="degraded"
        local_control_reason="status_dir_present_scheduler_missing"
        return
    fi
}

check_cloud_rag() {
    if [ -z "$CLOUD_RAG_HEALTH_URL" ]; then
        return
    fi

    if curl -fsS --max-time 3 "$CLOUD_RAG_HEALTH_URL" >/tmp/runtime-arbiter-cloud.log 2>&1; then
        cloud_rag_status="available"
        cloud_rag_reason="healthcheck_ok"
        return
    fi

    cloud_rag_status="degraded"
    cloud_rag_reason="healthcheck_failed"
}

resolve_provider_primary() {
    case "$AI_PROVIDER_POLICY" in
        codex)
            if [ "$codex_available" -eq 1 ]; then
                provider_primary="codex"
                provider_reason="policy_codex"
            elif [ "$claude_available" -eq 1 ]; then
                provider_primary="claude"
                provider_reason="codex_unavailable_fallback_claude"
            fi
            ;;
        claude)
            if [ "$claude_available" -eq 1 ]; then
                provider_primary="claude"
                provider_reason="policy_claude"
            elif [ "$codex_available" -eq 1 ]; then
                provider_primary="codex"
                provider_reason="claude_unavailable_fallback_codex"
            fi
            ;;
        auto|*)
            if [ "$codex_available" -eq 1 ] && [ "$claude_available" -eq 1 ]; then
                case "$AI_PROVIDER_PREFERENCE" in
                    claude)
                        provider_primary="claude"
                        provider_reason="both_available_preference_claude"
                        ;;
                    codex|*)
                        provider_primary="codex"
                        provider_reason="both_available_preference_codex"
                        ;;
                esac
            elif [ "$codex_available" -eq 1 ]; then
                provider_primary="codex"
                provider_reason="only_codex_available"
            elif [ "$claude_available" -eq 1 ]; then
                provider_primary="claude"
                provider_reason="only_claude_available"
            fi
            ;;
    esac
}

emit_env() {
    cat <<EOF
AI_CLI_PROVIDER_PRIMARY_RESOLVED="$provider_primary"
AI_CLI_PROVIDER_PRIMARY_REASON="$provider_reason"
AI_CLI_CODEX_STATUS="$codex_status"
AI_CLI_CODEX_REASON="$codex_reason"
AI_CLI_CLAUDE_STATUS="$claude_status"
AI_CLI_CLAUDE_REASON="$claude_reason"
AI_RUNTIME_LOCAL_CONTROL="$local_control_plane"
AI_RUNTIME_LOCAL_REASON="$local_control_reason"
AI_RUNTIME_CLOUD_RAG_STATUS="$cloud_rag_status"
AI_RUNTIME_CLOUD_RAG_REASON="$cloud_rag_reason"
AI_RUNTIME_POLICY_RESOLVED="$AI_RUNTIME_POLICY"
AI_RUNTIME_CLOUD_TAKEOVER_SCOPE="$CLOUD_TAKEOVER_SCOPE"
AI_RUNTIME_CLOUD_BOT_DECLARED="$CLOUD_BOT_RUNTIME_DECLARED"
EOF
}

write_mode_file() {
    local truthful_local_line
    local truthful_product_line
    local truthful_provider_line

    if [ "$AI_RUNTIME_POLICY" = "cloud-primary" ] || [ "$CLOUD_TAKEOVER_SCOPE" = "all-agents" ]; then
        truthful_local_line="- Local agents (\`strategist\`, \`extractor\`, \`scheduler\`) переведены в \`cloud-primary\`; локальный dispatch должен быть standby-only."
        truthful_product_line="- Product services (\`VK-offee-rag\`, \`VK-offee/telegram-bot\`) остаются \`cloud-primary\` контуром."
    else
        truthful_local_line="- Local agents (\`strategist\`, \`extractor\`, \`scheduler\`) остаются \`local-primary\` до отдельного runtime redesign."
        truthful_product_line="- Product services (\`VK-offee-rag\`, \`VK-offee/telegram-bot\`) считаются \`cloud-primary\` контуром."
    fi

    truthful_provider_line="- Provider selection для активного runtime должен брать \`$provider_primary\`, пока он доступен."

    cat > "$MODE_FILE" <<EOF
---
type: runtime-mode
updated: $(date '+%Y-%m-%d %H:%M:%S')
provider_policy: $AI_PROVIDER_POLICY
provider_preference: $AI_PROVIDER_PREFERENCE
runtime_policy: $AI_RUNTIME_POLICY
cloud_takeover_scope: $CLOUD_TAKEOVER_SCOPE
---

# Runtime Mode

## Provider Plane

- Primary provider: \`$provider_primary\`
- Why: \`$provider_reason\`
- Codex: \`$codex_status\` (\`$codex_reason\`)
- Claude: \`$claude_status\` (\`$claude_reason\`)

## Runtime Plane

- Local control plane: \`$local_control_plane\` (\`$local_control_reason\`)
- Cloud RAG status: \`$cloud_rag_status\` (\`$cloud_rag_reason\`)
- Cloud bot runtime: \`$CLOUD_BOT_RUNTIME_DECLARED\`
- Runtime policy: \`$AI_RUNTIME_POLICY\`
- Cloud takeover scope: \`$CLOUD_TAKEOVER_SCOPE\`

## Truthful Verdict

$truthful_local_line
$truthful_product_line
$truthful_provider_line
- Если primary provider станет недоступен, runner должен переключаться на доступный fallback-provider без ручного переписывания скриптов.
EOF

    emit_env > "$STATE_FILE"
}

check_codex
check_claude
check_local_control_plane
check_cloud_rag
resolve_provider_primary

case "${1:-}" in
    --env)
        emit_env
        ;;
    *)
        write_mode_file
        printf '%s\n' "$MODE_FILE"
        ;;
esac
