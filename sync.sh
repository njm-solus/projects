#!/bin/bash
# =============================================================================
# sync.sh — Git sync script for Linux (Arch)
# Usage: ./sync.sh
#        ./sync.sh --no-pull        (skip pull, e.g. fully offline)
#        ./sync.sh --retry          (keep retrying push until internet is back)
#        ./sync.sh --message "msg"  (custom commit message)
# =============================================================================

# ── CONFIG ───────────────────────────────────────────────────────────────────
REPO_DIR="$HOME/projects"          # ← change this to your actual repo path
RETRY_INTERVAL=30                  # seconds between push retries
LOG_FILE="$REPO_DIR/.sync.log"     # log file location (hidden in repo root)
MAX_LOG_LINES=500                  # rotate log after this many lines
# ─────────────────────────────────────────────────────────────────────────────

# ── FLAGS ────────────────────────────────────────────────────────────────────
NO_PULL=false
RETRY=false
CUSTOM_MSG=""

for arg in "$@"; do
    case $arg in
        --no-pull)   NO_PULL=true ;;
        --retry)     RETRY=true ;;
        --message)   shift; CUSTOM_MSG="$1" ;;
        --message=*) CUSTOM_MSG="${arg#*=}" ;;
    esac
done
# ─────────────────────────────────────────────────────────────────────────────

# ── HELPERS ──────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"

    # Log rotation
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
        tail -n $((MAX_LOG_LINES / 2)) "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
        log "Log rotated (trimmed to $((MAX_LOG_LINES / 2)) lines)"
    fi
}

has_internet() {
    # Ping GitHub's DNS — fast and reliable check
    ping -c 1 -W 2 github.com &>/dev/null
}

check_repo() {
    if [ ! -d "$REPO_DIR/.git" ]; then
        echo "❌ ERROR: '$REPO_DIR' is not a git repository."
        echo "   Either clone your repo there or update REPO_DIR in this script."
        exit 1
    fi
}
# ─────────────────────────────────────────────────────────────────────────────

# ── MAIN ─────────────────────────────────────────────────────────────────────
check_repo
cd "$REPO_DIR" || exit 1

log "──────────────────────────────────────"
log "Sync started"

# 1) PULL
if [ "$NO_PULL" = false ]; then
    if has_internet; then
        log "Pulling from remote..."
        pull_output=$(git pull --rebase 2>&1)
        pull_exit=$?

        if [ $pull_exit -eq 0 ]; then
            log "Pull OK: $pull_output"
        else
            # Check for merge conflict
            if echo "$pull_output" | grep -q "CONFLICT"; then
                log "⚠ CONFLICT detected during pull. Resolve manually, then re-run sync."
                echo ""
                echo "⚠ Merge conflict! Steps to fix:"
                echo "   1. cd $REPO_DIR"
                echo "   2. git status          (see conflicting files)"
                echo "   3. Edit the files, resolve <<<<< markers"
                echo "   4. git add ."
                echo "   5. git rebase --continue"
                echo "   6. ./sync.sh --no-pull"
                exit 1
            else
                log "⚠ Pull failed (non-conflict): $pull_output"
                echo "⚠ Pull failed. Continuing with local commit anyway."
            fi
        fi
    else
        log "⚠ No internet — skipping pull"
        echo "⚠ Offline — skipping pull"
    fi
else
    log "Pull skipped (--no-pull flag)"
fi

# 2) STAGE
git add . 2>&1
stage_exit=$?
if [ $stage_exit -ne 0 ]; then
    log "❌ git add failed"
    exit 1
fi

# 3) COMMIT
if [ -z "$CUSTOM_MSG" ]; then
    COMMIT_MSG="sync: $(date '+%Y-%m-%d %H:%M')"
else
    COMMIT_MSG="$CUSTOM_MSG"
fi

commit_output=$(git commit -m "$COMMIT_MSG" 2>&1)
commit_exit=$?

if [ $commit_exit -eq 0 ]; then
    log "Committed: $COMMIT_MSG"
elif echo "$commit_output" | grep -q "nothing to commit"; then
    log "Nothing to commit — working tree clean"
    echo "✅ Nothing new to commit"
    exit 0
else
    log "❌ Commit failed: $commit_output"
    exit 1
fi

# 4) PUSH
do_push() {
    push_output=$(git push 2>&1)
    push_exit=$?

    if [ $push_exit -eq 0 ]; then
        log "✅ Pushed: $COMMIT_MSG"
        echo "✅ Synced successfully"
        return 0
    else
        log "⚠ Push failed: $push_output"
        return 1
    fi
}

if has_internet; then
    do_push
    push_result=$?

    if [ $push_result -ne 0 ] && [ "$RETRY" = true ]; then
        echo "⚠ Push failed despite internet — retrying every ${RETRY_INTERVAL}s (Ctrl+C to stop)"
        while ! do_push; do
            echo "   Waiting ${RETRY_INTERVAL}s..."
            sleep "$RETRY_INTERVAL"
        done
    fi
else
    log "⚠ Offline — commit saved locally, push pending"
    echo ""
    echo "⚠ No internet. Commit saved locally."
    echo "  Run './sync.sh --no-pull' when back online to push."

    if [ "$RETRY" = true ]; then
        echo "  Retrying push every ${RETRY_INTERVAL}s (Ctrl+C to stop)..."
        while ! has_internet; do
            sleep "$RETRY_INTERVAL"
        done
        log "Internet restored — attempting push"
        do_push
    fi
fi

log "Sync ended"
