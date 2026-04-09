#!/usr/bin/env bash
# deploy-vps-exocortex-runtime.sh — sync canonical workspace to VPS and install exocortex scheduler runtime

set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-root@72.56.4.61}"
LOCAL_WORKSPACE="${LOCAL_WORKSPACE:-$HOME/Github}"
REMOTE_WORKSPACE="${REMOTE_WORKSPACE:-/root/Github}"
INTERVAL_MINUTES="${INTERVAL_MINUTES:-15}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            REMOTE_HOST="$2"
            shift 2
            ;;
        --local-workspace)
            LOCAL_WORKSPACE="$2"
            shift 2
            ;;
        --remote-workspace)
            REMOTE_WORKSPACE="$2"
            shift 2
            ;;
        --interval-minutes)
            INTERVAL_MINUTES="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--host root@ip] [--local-workspace /path] [--remote-workspace /path] [--interval-minutes 15]" >&2
            exit 1
            ;;
    esac
done

if [ ! -d "$LOCAL_WORKSPACE/FMT-exocortex-template" ] || [ ! -d "$LOCAL_WORKSPACE/DS-strategy" ]; then
    echo "Local workspace does not contain FMT-exocortex-template and DS-strategy: $LOCAL_WORKSPACE" >&2
    exit 1
fi

if ! [[ "$INTERVAL_MINUTES" =~ ^[0-9]+$ ]] || [ "$INTERVAL_MINUTES" -lt 5 ]; then
    echo "--interval-minutes must be an integer >= 5" >&2
    exit 1
fi

echo "[1/4] Checking SSH connectivity to $REMOTE_HOST..."
ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE_HOST" 'echo ok' >/dev/null

echo "[2/4] Preparing remote workspace $REMOTE_WORKSPACE..."
ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_WORKSPACE'"

echo "[3/4] Syncing FMT-exocortex-template..."
rsync -az --delete \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.venv' \
    --exclude='venv' \
    --exclude='__pycache__' \
    "$LOCAL_WORKSPACE/FMT-exocortex-template/" \
    "$REMOTE_HOST:$REMOTE_WORKSPACE/FMT-exocortex-template/"

echo "[3/4] Syncing DS-strategy..."
rsync -az --delete \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.venv' \
    --exclude='venv' \
    --exclude='__pycache__' \
    --exclude='current/UNPROCESSED-NOTES-REPORT.md' \
    "$LOCAL_WORKSPACE/DS-strategy/" \
    "$REMOTE_HOST:$REMOTE_WORKSPACE/DS-strategy/"

echo "[4/4] Writing VPS runtime overrides..."
ssh "$REMOTE_HOST" "cat > '$REMOTE_WORKSPACE/DS-strategy/current/SCHEDULER-RUNTIME.env' <<'EOF'
EXOCORTEX_RUNTIME_TARGET=vps
EXOCORTEX_DISABLE_LOCAL_DISPATCH=0
EOF"

echo "[4/4] Installing systemd runtime..."
ssh "$REMOTE_HOST" "bash '$REMOTE_WORKSPACE/FMT-exocortex-template/setup/optional/setup-vps-agent-runtime.sh' --workspace '$REMOTE_WORKSPACE' --interval-minutes '$INTERVAL_MINUTES'"

echo
echo "Deployment complete."
echo "Remote workspace: $REMOTE_WORKSPACE"
echo "Host: $REMOTE_HOST"
