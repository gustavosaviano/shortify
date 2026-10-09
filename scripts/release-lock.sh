# shellcheck shell=bash  # sourced, never executed, so it has no shebang
# One host-wide lock for everything that changes what the ALB serves: a release
# (scripts/release.sh) and the session's in-place deploy (scripts/floci-session.sh).
# The deploy workflow's concurrency group only orders pipeline runs; it can't see a manual
# shortify_session on the same laptop, and two of them at once can leave two instances
# behind the ALB or deploy into an instance that is being retired.
# How: the caller re-runs itself as a child of flock(1).
#   - The kernel drops the lock when the flock process exits, even after a crash or kill -9:
#     no stale lock to clean up, so the file's content is only a hint of who holds it.
#   - -o: the child runs without the lock's file descriptor, so a process the deploy leaves
#     behind (an SSH ControlPersist master, say) can't keep the lock after the script ends.
#   - Exit 75 (EX_TEMPFAIL) means the lock was still busy after the wait; nothing changed.
#   - A nested caller (the session's cold path runs release.sh) sees SHORTIFY_RELEASE_LOCK_HELD
#     and doesn't lock again: a second flock on the same file would wait for its own parent.
# SHORTIFY_RELEASE_LOCK and SHORTIFY_RELEASE_LOCK_WAIT exist for the tests.
release_lock_file="${SHORTIFY_RELEASE_LOCK:-/tmp/shortify-release.lock}"

# release_lock <who> <absolute script path> [args...]
# Returns only in the locked child; the unlocked caller exits with the child's exit code.
release_lock() {
  local who=$1 script=$2 wait="${SHORTIFY_RELEASE_LOCK_WAIT:-900}" rc
  shift 2
  if [ "${SHORTIFY_RELEASE_LOCK_HELD:-}" = "$release_lock_file" ]; then
    printf '%s pid %s since %s\n' "$who" "$$" "$(date -u +%FT%TZ)" > "$release_lock_file"
    return 0
  fi
  if ! flock -n "$release_lock_file" true 2> /dev/null; then
    echo "$who: the release lock is busy (held by: $(cat "$release_lock_file" 2> /dev/null || echo unknown)); waiting up to $wait s"
  fi
  SHORTIFY_RELEASE_LOCK_HELD="$release_lock_file" flock -o -E 75 -w "$wait" "$release_lock_file" bash "$script" "$@"
  rc=$?
  if [ "$rc" -eq 75 ]; then
    echo "$who: the release lock was still busy after $wait s; nothing changed" >&2
  fi
  exit "$rc"
}
