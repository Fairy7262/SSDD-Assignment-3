#!/usr/bin/env bash
# monitor_and_push.sh
# Git Bash friendly. Polling-based checksum monitor.
# On change: git add/commit/push and append a markdown notification to NOTIFICATIONS.md,
# commit & push that notification as well.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load config (expects config.cfg in same directory)
if [[ ! -f config.cfg ]]; then
  echo "Missing config.cfg in $SCRIPT_DIR" >&2
  exit 1
fi
# shellcheck disable=SC1091
source config.cfg

# Resolve REPO_PATH to absolute
if [[ "${REPO_PATH:0:1}" == "/" || "${REPO_PATH:0:1}" == "~" ]]; then
  REPO_ABS="$(eval echo "$REPO_PATH")"
else
  REPO_ABS="$(cd "$REPO_PATH" 2>/dev/null && pwd) || true"
fi
if [[ -z "$REPO_ABS" ]]; then
  echo "Cannot resolve REPO_PATH ($REPO_PATH)." >&2
  exit 1
fi

LOG_FULL_PATH="$REPO_ABS/$LOG_FILE"
CHECKSUM_FULL_PATH="$REPO_ABS/$CHECKSUM_STORE"

# Basic tool checks
command -v git >/dev/null || { echo "git is required but not installed"; exit 1; }
command -v sha256sum >/dev/null || { echo "sha256sum is required but not installed"; exit 1; }
command -v curl >/dev/null || true  # curl might be used elsewhere; not required for notifications

# Logging helper
log() {
  local now
  now="$(date '+%F %T')"
  echo "[$now] $*" | tee -a "$LOG_FULL_PATH"
}

# Compute checksum for a directory or file
compute_checksum() {
  local target="$1"
  if [[ -d "$target" ]]; then
    # produce a stable checksum of all file contents under target
    (cd "$target" 2>/dev/null || return; find . -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null) | sha256sum | awk '{print $1}'
  elif [[ -f "$target" ]]; then
    sha256sum "$target" | awk '{print $1}'
  else
    echo ""
  fi
}

# Attempt git push with retries
attempt_git_push() {
  local tries=0
  while [[ $tries -lt $GIT_PUSH_RETRIES ]]; do
    if git push "$GIT_REMOTE" "$GIT_BRANCH"; then
      return 0
    fi
    tries=$((tries+1))
    log "git push failed (attempt ${tries}/${GIT_PUSH_RETRIES}); retrying in ${GIT_PUSH_RETRY_DELAY}s..."
    sleep "$GIT_PUSH_RETRY_DELAY"
  done
  return 1
}

# Stage, commit, push changes
perform_commit_and_push() {
  local msg="$1"
  git add -A || { log "git add failed"; return 1; }

  # If nothing staged, skip commit
  if git diff --cached --quiet; then
    log "No changes to commit."
    return 0
  fi

  if git commit -m "$msg" --no-verify; then
    log "Committed: $msg"
  else
    log "git commit failed"
    return 1
  fi

  log "Pushing to ${GIT_REMOTE}/${GIT_BRANCH}..."
  if attempt_git_push; then
    log "Push succeeded."
    return 0
  else
    log "Push failed after retries."
    return 1
  fi
}

# Write a human-readable notification entry to NOTIFICATIONS.md and stage it.
# Args: title, body
write_notification() {
  local title="$1"
  local body="$2"
  local notif_file="${REPO_ABS}/NOTIFICATIONS.md"
  local ts
  ts="$(date '+%F %T %z')"

  # Ensure file exists and has header
  if [[ ! -f "$notif_file" ]]; then
    echo "# Notifications" > "$notif_file"
    echo "" >> "$notif_file"
  fi

  {
    echo "## ${title}"
    echo ""
    echo "- **Time:** ${ts}"
    echo "- **Repository path:** ${REPO_ABS}"
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
      local chash
      chash="$(git rev-parse --short HEAD || true)"
      local cmsg
      cmsg="$(git log -1 --pretty=%B 2>/dev/null || true)"
      echo "- **Commit:** ${chash}"
      echo "- **Commit message:** ${cmsg}"
    fi
    echo ""
    echo "${body}"
    echo ""
    echo "---"
    echo ""
  } >> "$notif_file"

  # Stage the notification file so it gets committed
  (cd "$REPO_ABS" && git add "NOTIFICATIONS.md") || log "Warning: failed to stage NOTIFICATIONS.md"
}

# Initialize log & checksum file
mkdir -p "$(dirname "$LOG_FULL_PATH")"
touch "$LOG_FULL_PATH"
cd "$REPO_ABS" || { echo "Cannot cd to $REPO_ABS"; exit 1; }

if [[ ! -f "$CHECKSUM_FULL_PATH" ]]; then
  initial_checksum="$(compute_checksum "$TARGET")"
  echo "$initial_checksum" > "$CHECKSUM_FULL_PATH"
fi

log "Monitor started. Repo: $REPO_ABS Target: $TARGET"

# Main loop (polling mode)
while true; do
  new_checksum="$(compute_checksum "$TARGET")"
  if [[ -z "$new_checksum" ]]; then
    log "Target missing or empty: $TARGET. Sleeping ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    continue
  fi

  old_checksum="$(cat "$CHECKSUM_FULL_PATH" 2>/dev/null || true)"
  if [[ "$new_checksum" != "$old_checksum" ]]; then
    log "Change detected in $TARGET"
    echo "$new_checksum" > "$CHECKSUM_FULL_PATH"

    commit_msg="Auto-commit: Changes detected in ${TARGET}"
    if perform_commit_and_push "$commit_msg"; then
      log "Commit & push completed."

      # Add repository-based notification (no external email)
      notif_title="Auto-notify: Changes pushed to ${GIT_REMOTE}/${GIT_BRANCH}"
      notif_body="Changes detected in target: ${TARGET}\n\nAuto-commit message: ${commit_msg}\n\n(See commit on GitHub or pull to get latest code.)"
      write_notification "$notif_title" "$notif_body"

      # Commit the notification file if staged
      if git diff --cached --quiet; then
        log "No additional staged changes to commit (notification file unchanged)."
      else
        if git commit -m "Add notification entry: ${TARGET} changed" --no-verify; then
          log "Notification file committed."
          # push the notification commit too
          if attempt_git_push; then
            log "Notification commit pushed."
          else
            log "Failed to push notification commit after retries."
          fi
        else
          log "Failed to commit notification file."
        fi
      fi

    else
      log "Commit & push step failed; skipping notification."
    fi
  fi

  sleep "$POLL_INTERVAL"
done
