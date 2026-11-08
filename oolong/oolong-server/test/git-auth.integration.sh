#!/bin/sh
# Integration tests for Git pod credentials: configure_git_auth in
# helm-chart/oolong/scripts/git-publish.inc.sh and the credential helper
# helm-chart/oolong/scripts/git-credential-oolong.sh, against a local git http-backend
# behind HTTP Basic auth (test/git-http-auth-server.py). Fixtures are made-up values.
set -e

SCRIPTS="$(cd "$(dirname "$0")/../../../helm-chart/oolong/scripts" && pwd)"
SERVER_PY="$(cd "$(dirname "$0")" && pwd)/git-http-auth-server.py"
INC="$SCRIPTS/git-publish.inc.sh"
HELPER="$SCRIPTS/git-credential-oolong.sh"
for f in "$INC" "$HELPER" "$SERVER_PY"; do
  if [ ! -f "$f" ]; then
    echo "missing test input: $f"
    exit 1
  fi
done

for tool in git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for git auth tests"
    exit 1
  fi
done

TOKEN="not-a-real-token-0001"
USERNAME="tester"

ROOT="$(mktemp -d)"
PIDS=""
cleanup() {
  for _pid in $PIDS; do
    kill "$_pid" 2>/dev/null || true
  done
  rm -rf "$ROOT"
}
trap cleanup EXIT

# Isolated git configuration: nothing from the host leaks in.
HOME="$ROOT/home"
GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
GIT_CONFIG_NOSYSTEM=1
export HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
mkdir -p "$HOME"
: > "$GIT_CONFIG_GLOBAL"

if ! command -v flock >/dev/null 2>&1; then
  mkdir -p "$ROOT/bin"
  cat > "$ROOT/bin/flock" << 'PY'
#!/usr/bin/env python3
import fcntl
import sys

fd = int(sys.argv[-1])
try:
    fcntl.flock(fd, fcntl.LOCK_UN if "-u" in sys.argv else fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
PY
  chmod +x "$ROOT/bin/flock"
  PATH="$ROOT/bin:$PATH"
  export PATH
fi

# Every git call is bounded, so a regression to prompting fails instead of hanging.
GIT_BIN="$(command -v git)"
if command -v timeout >/dev/null 2>&1; then
  git() { timeout 30 "$GIT_BIN" "$@"; }
else
  git() {
    python3 -I -c '
import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
' "$GIT_BIN" "$@"
  }
fi

assert() {
  if ! "$@"; then
    echo "ASSERT FAILED: $*"
    exit 1
  fi
}

assert_contains() {
  if ! grep -qF -- "$2" "$1"; then
    echo "ASSERT FAILED: $1 does not contain: $2"
    exit 1
  fi
}

assert_not_contains() {
  if grep -qF -- "$2" "$1"; then
    echo "ASSERT FAILED: $1 contains: $2"
    exit 1
  fi
}

# --- Fixtures: a bare repository with a products/ tree ------------------------------------
REPO_ROOT="$ROOT/srv"
BARE="$REPO_ROOT/repo.git"
SRC="$ROOT/src"
mkdir -p "$REPO_ROOT"
git init -q --bare -b main "$BARE"
git init -q -b main "$SRC"

commit_products() {
  _label="$1"
  mkdir -p "$SRC/products/$_label"
  printf 'uuid: 11111111-1111-4111-8111-111111111111\nname: %s\nidentifiers: []\n' "$_label" \
    > "$SRC/products/$_label/product.yaml"
  git -C "$SRC" add .
  git -C "$SRC" -c user.name=Test -c user.email=test@example.invalid commit -q -m "$_label"
  git -C "$SRC" push -q "$BARE" main
}

commit_products alpha

# --- Servers ------------------------------------------------------------------------------
# start_server <name> <mode> [target]: sets <NAME>_PORT and <NAME>_LOG.
start_server() {
  _name="$1"
  _mode="$2"
  _target="$3"
  _log="$ROOT/$_name.log"
  _portfile="$ROOT/$_name.port"
  rm -f "$_portfile"
  if [ -n "$_target" ]; then
    python3 -I "$SERVER_PY" --mode "$_mode" --log "$_log" --port-file "$_portfile" \
      --target "$_target" &
  else
    python3 -I "$SERVER_PY" --mode "$_mode" --log "$_log" --port-file "$_portfile" \
      --repo-root "$REPO_ROOT" &
  fi
  PIDS="$PIDS $!"
  _tries=0
  while [ ! -s "$_portfile" ]; do
    _tries=$((_tries + 1))
    if [ "$_tries" -gt 100 ]; then
      echo "server $_name did not start"
      exit 1
    fi
    sleep 0.1
  done
  eval "${_name}_PORT=$(cat "$_portfile")"
  eval "${_name}_LOG=$_log"
}

start_server BACKEND backend
start_server REDIRECT redirect "http://127.0.0.1:$BACKEND_PORT"
start_server AUTHREDIR auth-redirect "http://127.0.0.1:$BACKEND_PORT"

# --- Per-case environment -----------------------------------------------------------------
AUTH_DIR="$ROOT/auth"
write_auth() {
  rm -rf "$AUTH_DIR"
  mkdir -p "$AUTH_DIR"
  printf '%s\n' "$USERNAME" > "$AUTH_DIR/username"
  printf '%s\n' "$1" > "$AUTH_DIR/token"
}

fresh_content() {
  cd "$ROOT"
  CONTENT_DIR="$ROOT/content"
  WORK_DIR="$CONTENT_DIR/_work"
  REVISIONS_DIR="$CONTENT_DIR/revisions"
  POINTER_FILE="$CONTENT_DIR/.oolong-current-revision"
  REVISION_RETENTION_COUNT=5
  GIT_BRANCH=main
  rm -rf "$CONTENT_DIR" "$HOME/.git-credentials"
  mkdir -p "$REVISIONS_DIR"
}

# Each case runs in a subshell, so exports and the working directory never leak.
# shellcheck disable=SC1090
. "$INC"

echo "test 1: auth type none against a protected server fails without prompting"
(
  fresh_content
  GIT_REPO_URL="http://localhost:$BACKEND_PORT/repo.git"
  OOLONG_GIT_AUTH_TYPE=none
  configure_git_auth "$HELPER" "$AUTH_DIR"
  if sync_worktree > "$ROOT/out1" 2>&1; then
    echo "ASSERT FAILED: anonymous clone of a protected repository succeeded"
    exit 1
  fi
  assert_contains "$ROOT/out1" "terminal prompts disabled"
)

echo "test 2: token auth clones, publishes and fetches a later commit"
(
  fresh_content
  write_auth "$TOKEN"
  GIT_REPO_URL="http://localhost:$BACKEND_PORT/repo.git"
  OOLONG_GIT_AUTH_TYPE=token
  configure_git_auth "$HELPER" "$AUTH_DIR"
  sync_worktree > "$ROOT/out2" 2>&1
  publish_revision >> "$ROOT/out2" 2>&1
  _first="$(git -C "$WORK_DIR" rev-parse HEAD)"
  assert test -f "$CONTENT_DIR/revisions/$_first/.oolong-publish-complete"
  commit_products beta
  sync_worktree >> "$ROOT/out2" 2>&1
  publish_revision >> "$ROOT/out2" 2>&1
  _second="$(git -C "$WORK_DIR" rev-parse HEAD)"
  assert test "$_first" != "$_second"
  assert test -f "$CONTENT_DIR/revisions/$_second/products/beta/product.yaml"

  echo "test 3: the token is nowhere on disk, in the remote URL or in the environment"
  assert test "$(git -C "$WORK_DIR" remote get-url origin)" = "$GIT_REPO_URL"
  if grep -rF "$TOKEN" "$WORK_DIR" "$CONTENT_DIR" "$HOME" > "$ROOT/grep3" 2>&1; then
    echo "ASSERT FAILED: the token is on disk"
    exit 1
  fi
  assert_not_contains "$ROOT/out2" "$TOKEN"
  env > "$ROOT/env3"
  assert_not_contains "$ROOT/env3" "$TOKEN"
  assert test "$GIT_TERMINAL_PROMPT" = 0
  assert test "$GIT_CONFIG_COUNT" = 2
  assert test -z "$GIT_CONFIG_VALUE_0"
  assert_not_contains "$ROOT/env3" "$TOKEN"
)

echo "test 4: an inherited store helper is reset and writes no credentials file"
(
  fresh_content
  write_auth "$TOKEN"
  git config --file "$GIT_CONFIG_GLOBAL" credential.helper store
  GIT_REPO_URL="http://localhost:$BACKEND_PORT/repo.git"
  OOLONG_GIT_AUTH_TYPE=token
  configure_git_auth "$HELPER" "$AUTH_DIR"
  sync_worktree > "$ROOT/out4" 2>&1
  assert test ! -e "$HOME/.git-credentials"
  # Control: without the reset entry the same store helper does persist the token.
  fresh_content
  GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0="credential.http://localhost:$BACKEND_PORT.helper"
  GIT_CONFIG_VALUE_0="/bin/sh $HELPER $AUTH_DIR"
  export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  sync_worktree > "$ROOT/out4b" 2>&1
  assert test -e "$HOME/.git-credentials"
)
: > "$GIT_CONFIG_GLOBAL"

echo "test 5: a wrong token fails with an authentication error"
(
  fresh_content
  write_auth "not-the-right-token"
  GIT_REPO_URL="http://localhost:$BACKEND_PORT/repo.git"
  OOLONG_GIT_AUTH_TYPE=token
  configure_git_auth "$HELPER" "$AUTH_DIR"
  if sync_worktree > "$ROOT/out5" 2>&1; then
    echo "ASSERT FAILED: a wrong token cloned the repository"
    exit 1
  fi
  assert_contains "$ROOT/out5" "Authentication failed"
)

# Cases 6 to 8: a log line from the clone must exist before "no Authorization header" counts.
assert_logged_without_auth() {
  assert test -s "$1"
  assert_not_contains "$1" "auth=yes"
}

echo "test 6: the token is not offered to another host name"
(
  fresh_content
  write_auth "$TOKEN"
  : > "$BACKEND_LOG"
  GIT_REPO_URL="http://127.0.0.1:$BACKEND_PORT/repo.git"
  OOLONG_GIT_AUTH_TYPE=token
  # Configure the helper for localhost, then clone through 127.0.0.1.
  configure_git_auth "$HELPER" "$AUTH_DIR"
  GIT_CONFIG_KEY_1="credential.http://localhost:$BACKEND_PORT.helper"
  export GIT_CONFIG_KEY_1
  if sync_worktree > "$ROOT/out6" 2>&1; then
    echo "ASSERT FAILED: clone through an unconfigured host name succeeded"
    exit 1
  fi
  assert_logged_without_auth "$BACKEND_LOG"
)

echo "test 7: an unauthenticated redirect to another host never carries the token"
(
  fresh_content
  write_auth "$TOKEN"
  : > "$BACKEND_LOG"
  : > "$REDIRECT_LOG"
  GIT_REPO_URL="http://localhost:$REDIRECT_PORT/repo.git"
  OOLONG_GIT_AUTH_TYPE=token
  configure_git_auth "$HELPER" "$AUTH_DIR"
  if sync_worktree > "$ROOT/out7" 2>&1; then
    echo "ASSERT FAILED: clone through a redirect to another host succeeded"
    exit 1
  fi
  assert test -s "$REDIRECT_LOG"
  assert_logged_without_auth "$BACKEND_LOG"
)

echo "test 8: a redirect after authentication never carries the token to the second host"
(
  fresh_content
  write_auth "$TOKEN"
  : > "$BACKEND_LOG"
  : > "$AUTHREDIR_LOG"
  GIT_REPO_URL="http://localhost:$AUTHREDIR_PORT/repo.git"
  OOLONG_GIT_AUTH_TYPE=token
  configure_git_auth "$HELPER" "$AUTH_DIR"
  if sync_worktree > "$ROOT/out8" 2>&1; then
    echo "ASSERT FAILED: clone through an authenticated redirect succeeded"
    exit 1
  fi
  assert_contains "$AUTHREDIR_LOG" "auth=yes"
  assert_logged_without_auth "$BACKEND_LOG"
  if grep -rF "$TOKEN" "$WORK_DIR" "$HOME" > "$ROOT/grep8" 2>&1; then
    echo "ASSERT FAILED: the token is on disk after the redirect"
    exit 1
  fi
)

echo "test 9: credential file validation names the file and never prints its content"
expect_refused() {
  _label="$1"
  _file="$2"
  _secret="$3"
  if (OOLONG_GIT_AUTH_TYPE=token GIT_REPO_URL="http://localhost:1/repo.git" \
      configure_git_auth "$HELPER" "$AUTH_DIR" > "$ROOT/out9" 2>&1); then
    echo "ASSERT FAILED: configure_git_auth accepted $_label"
    exit 1
  fi
  assert_contains "$ROOT/out9" "$AUTH_DIR/$_file"
  if [ -n "$_secret" ]; then
    assert_not_contains "$ROOT/out9" "$_secret"
  fi
}
rm -rf "$AUTH_DIR"
expect_refused "a missing auth directory" username ""
write_auth "$TOKEN"
: > "$AUTH_DIR/token"
expect_refused "an empty token" token ""
write_auth "$TOKEN"
printf 'first-line-secret-0002\nsecond-line-secret-0003\n' > "$AUTH_DIR/token"
expect_refused "a two-line token" token "first-line-secret-0002"
write_auth "$TOKEN"
printf 'crlf-secret-0004\r\n' > "$AUTH_DIR/token"
expect_refused "a token with a CRLF ending" token "crlf-secret-0004"
write_auth "$TOKEN"
: > "$AUTH_DIR/username"
expect_refused "an empty username" username ""
# A file without a trailing newline is accepted.
write_auth "$TOKEN"
printf '%s' "$TOKEN" > "$AUTH_DIR/token"
(OOLONG_GIT_AUTH_TYPE=token GIT_REPO_URL="http://localhost:1/repo.git" \
  configure_git_auth "$HELPER" "$AUTH_DIR")

echo "test 10: auth type validation"
for _type in "" ssh Token; do
  if (OOLONG_GIT_AUTH_TYPE="$_type" GIT_REPO_URL="http://localhost:1/repo.git" \
      configure_git_auth "$HELPER" "$AUTH_DIR" > "$ROOT/out10" 2>&1); then
    echo "ASSERT FAILED: configure_git_auth accepted auth type '$_type'"
    exit 1
  fi
  assert_contains "$ROOT/out10" "OOLONG_GIT_AUTH_TYPE must be none or token"
done

echo "test 11: path validation happens before any configuration is exported"
write_auth "$TOKEN"
(
  unset GIT_CONFIG_COUNT
  OOLONG_GIT_AUTH_TYPE=token
  GIT_REPO_URL="http://localhost:1/repo.git"
  if configure_git_auth "/tmp/a helper.sh" "$AUTH_DIR" > "$ROOT/out11" 2>&1; then
    echo "ASSERT FAILED: a helper path with a space was accepted"
    exit 1
  fi
  if configure_git_auth "$HELPER" "/tmp/auth;touch" > "$ROOT/out11" 2>&1; then
    echo "ASSERT FAILED: an auth directory with ; was accepted"
    exit 1
  fi
  assert test -z "${GIT_CONFIG_COUNT:-}"
)

echo "test 12: helper actions"
write_auth "$TOKEN"
for _action in store erase; do
  _out="$(printf 'protocol=http\nhost=localhost\n\n' | /bin/sh "$HELPER" "$AUTH_DIR" "$_action")"
  assert test -z "$_out"
done
printf 'a-secret-0005\nb-secret-0006\n' > "$AUTH_DIR/token"
if printf 'protocol=http\nhost=localhost\n\n' | /bin/sh "$HELPER" "$AUTH_DIR" get \
    > "$ROOT/out12" 2> "$ROOT/err12"; then
  echo "ASSERT FAILED: the helper accepted a two-line token"
  exit 1
fi
assert test ! -s "$ROOT/out12"
assert_not_contains "$ROOT/err12" "a-secret-0005"
write_auth "$TOKEN"
printf 'protocol=http\nhost=localhost\n\n' | /bin/sh "$HELPER" "$AUTH_DIR" get > "$ROOT/out12"
assert_contains "$ROOT/out12" "username=$USERNAME"
assert_contains "$ROOT/out12" "password=$TOKEN"

echo "all git auth integration tests passed"
