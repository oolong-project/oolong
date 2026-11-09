#!/bin/sh
# Integration tests for Git pod SSH deploy keys: configure_git_auth, install_ssh_files and
# validate_git_repo_url in helm-chart/oolong/scripts/git-publish.inc.sh, against an unprivileged
# sshd on 127.0.0.1 serving a bare repository. All keys are generated per run; no key is committed.
set -e

SCRIPTS="$(cd "$(dirname "$0")/../../../helm-chart/oolong/scripts" && pwd)"
INC="$SCRIPTS/git-publish.inc.sh"
HELPER="$SCRIPTS/git-credential-oolong.sh"
for f in "$INC" "$HELPER"; do
  if [ ! -f "$f" ]; then
    echo "missing test input: $f"
    exit 1
  fi
done

SSHD="$(command -v sshd 2>/dev/null || true)"
if [ -z "$SSHD" ] && [ -x /usr/sbin/sshd ]; then
  SSHD=/usr/sbin/sshd
fi
if [ -z "$SSHD" ]; then
  echo "sshd is required for the ssh auth tests"
  exit 1
fi
for tool in git ssh ssh-keygen ssh-agent ssh-add python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for the ssh auth tests"
    exit 1
  fi
done

ROOT="$(mktemp -d)"
PIDS=""
cleanup() {
  for _pid in $PIDS; do
    kill "$_pid" 2>/dev/null || true
  done
  if [ -n "${SSH_AGENT_PID:-}" ]; then
    kill "$SSH_AGENT_PID" 2>/dev/null || true
  fi
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

# Writing the allowance once: the Git pod's git-sync.sh does the same for type ssh.
git config --global protocol.ssh.allow always

# --- Keys ----------------------------------------------------------------------------------
KEYS="$ROOT/keys"
mkdir -p "$KEYS"
for _k in hostkey impostor good good2 wrong; do
  ssh-keygen -q -t ed25519 -N '' -C "oolong-test-$_k" -f "$KEYS/$_k"
done
ssh-keygen -q -t ed25519 -N 'test-passphrase-0001' -C oolong-test-enc -f "$KEYS/enc"

fingerprint() {
  ssh-keygen -lf "$KEYS/$1.pub" | awk '{ print $2 }'
}
FP_GOOD="$(fingerprint good)"
FP_GOOD2="$(fingerprint good2)"
FP_WRONG="$(fingerprint wrong)"

# --- sshd ----------------------------------------------------------------------------------
SSH_USER="$(id -un)"
SSHD_PORT="$(python3 -I -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"
AUTHORIZED="$ROOT/authorized_keys"
SSHD_LOG="$ROOT/sshd.log"
set_authorized() {
  printf 'restrict %s\n' "$(cat "$KEYS/$1.pub")" > "$AUTHORIZED"
}
set_authorized good
cat > "$ROOT/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $SSHD_PORT
HostKey $KEYS/hostkey
AuthorizedKeysFile $AUTHORIZED
PidFile $ROOT/sshd.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
LogLevel VERBOSE
EOF
: > "$SSHD_LOG"
"$SSHD" -D -e -f "$ROOT/sshd_config" -E "$SSHD_LOG" &
PIDS="$PIDS $!"
_tries=0
until python3 -I -c "
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(('127.0.0.1', $SSHD_PORT))
except OSError:
    sys.exit(1)
" 2>/dev/null; do
  _tries=$((_tries + 1))
  if [ "$_tries" -gt 50 ]; then
    echo "sshd did not start"
    cat "$SSHD_LOG"
    exit 1
  fi
  sleep 0.2
done

log_count() {
  wc -l < "$SSHD_LOG" | tr -d ' '
}

# new_log <count-before> <file>: the sshd log lines written after the count, once the attempt's
# connection line is there (sshd logs a little after the client exits).
new_log() {
  _tries=0
  while :; do
    tail -n +"$(($1 + 1))" "$SSHD_LOG" > "$2"
    if grep -q 'Connection from 127.0.0.1' "$2"; then
      sleep 0.3
      tail -n +"$(($1 + 1))" "$SSHD_LOG" > "$2"
      return 0
    fi
    _tries=$((_tries + 1))
    if [ "$_tries" -gt 30 ]; then
      return 1
    fi
    sleep 0.1
  done
}

# --- Repository ----------------------------------------------------------------------------
BARE="$ROOT/srv/repo.git"
SRC="$ROOT/src"
mkdir -p "$ROOT/srv"
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

REPO_URL="ssh://$SSH_USER@127.0.0.1:$SSHD_PORT$BARE"
KNOWN_HOST="[127.0.0.1]:$SSHD_PORT"
AUTH_DIR="$ROOT/auth"
SSH_DIR="$ROOT/sshdir"

host_pub() {
  cut -d' ' -f1,2 "$KEYS/$1.pub"
}

# write_auth <client key> <host key>: the auth directory as the Secret mount presents it.
write_auth() {
  rm -rf "$AUTH_DIR"
  mkdir -p "$AUTH_DIR"
  cp "$KEYS/$1" "$AUTH_DIR/identity"
  printf '%s %s\n' "$KNOWN_HOST" "$(host_pub "$2")" > "$AUTH_DIR/known_hosts"
  chmod 440 "$AUTH_DIR/identity" "$AUTH_DIR/known_hosts"
}

# put_known_hosts <text>: replace known_hosts in the auth directory (mode 0440 as mounted).
put_known_hosts() {
  chmod 640 "$AUTH_DIR/known_hosts"
  printf '%s\n' "$1" > "$AUTH_DIR/known_hosts"
  chmod 440 "$AUTH_DIR/known_hosts"
}

fresh_content() {
  cd "$ROOT"
  CONTENT_DIR="$ROOT/content"
  WORK_DIR="$CONTENT_DIR/_work"
  REVISIONS_DIR="$CONTENT_DIR/revisions"
  POINTER_FILE="$CONTENT_DIR/.oolong-current-revision"
  REVISION_RETENTION_COUNT=5
  GIT_BRANCH=main
  GIT_REPO_URL="$REPO_URL"
  GIT_REPO_HOST_ALLOWLIST=""
  OOLONG_GIT_AUTH_TYPE=ssh
  rm -rf "$CONTENT_DIR" "$SSH_DIR"
  mkdir -p "$REVISIONS_DIR" "$SSH_DIR"
}

# Each case runs in a subshell, so exports and the working directory never leak.
# shellcheck disable=SC1090
. "$INC"

echo "test 1: clone, publish and fetch a later commit with the deploy key"
(
  fresh_content
  write_auth good hostkey
  validate_git_repo_url
  configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR"
  _before="$(log_count)"
  locked_sync_and_publish > "$ROOT/out1" 2>&1
  _first="$(git -C "$WORK_DIR" rev-parse HEAD)"
  assert test -f "$CONTENT_DIR/revisions/$_first/products/alpha/product.yaml"
  commit_products beta
  locked_sync_and_publish >> "$ROOT/out1" 2>&1
  _second="$(git -C "$WORK_DIR" rev-parse HEAD)"
  assert test "$_first" != "$_second"
  assert test -f "$CONTENT_DIR/revisions/$_second/products/beta/product.yaml"
  new_log "$_before" "$ROOT/log1"
  assert_contains "$ROOT/log1" "Accepted publickey"
  assert_contains "$ROOT/log1" "$FP_GOOD"
  assert_not_contains "$ROOT/log1" "$FP_GOOD2"
  assert_not_contains "$ROOT/log1" "$FP_WRONG"

  echo "test 7: the private key is nowhere on disk, in the remote URL, the environment or the output"
  _secret="$(sed -n 2p "$KEYS/good")"
  assert test -n "$_secret"
  assert test "$(git -C "$WORK_DIR" remote get-url origin)" = "$GIT_REPO_URL"
  if grep -rF -- "$_secret" "$CONTENT_DIR" > "$ROOT/grep7" 2>&1; then
    echo "ASSERT FAILED: the private key is under the content directory"
    exit 1
  fi
  env > "$ROOT/env7"
  assert_not_contains "$ROOT/env7" "$_secret"
  assert_not_contains "$ROOT/out1" "$_secret"
  assert_not_contains "$ROOT/log1" "$_secret"
)

echo "test 2: a mismatched host key is refused before any key is offered"
(
  fresh_content
  write_auth good impostor
  configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR"
  _before="$(log_count)"
  if locked_sync_and_publish > "$ROOT/out2" 2>&1; then
    echo "ASSERT FAILED: a sync against a mismatched host key succeeded"
    exit 1
  fi
  if ! grep -q -e 'Host key verification failed' -e 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$ROOT/out2"; then
    echo "ASSERT FAILED: the refusal does not name the host key"
    exit 1
  fi
  assert new_log "$_before" "$ROOT/log2"
  assert_not_contains "$ROOT/log2" "publickey"
  assert_not_contains "$ROOT/log2" "SHA256:"
  assert cmp "$SSH_DIR/known_hosts" "$AUTH_DIR/known_hosts"
  assert test ! -e "$POINTER_FILE"
)

echo "test 3: a known_hosts without the host is refused at start-up, before connecting"
(
  fresh_content
  write_auth good hostkey
  chmod 640 "$AUTH_DIR/known_hosts"
  printf 'other.example.test %s\n' "$(host_pub hostkey)" > "$AUTH_DIR/known_hosts"
  chmod 440 "$AUTH_DIR/known_hosts"
  _before="$(log_count)"
  if configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR" > "$ROOT/out3" 2>&1; then
    echo "ASSERT FAILED: configure_git_auth accepted a known_hosts without the host"
    exit 1
  fi
  assert_contains "$ROOT/out3" "has no entry for $KNOWN_HOST"
  sleep 1
  assert test "$(log_count)" = "$_before"
)

echo "test 4: only the configured key is offered, never an agent key or a default identity"
(
  fresh_content
  write_auth wrong hostkey
  eval "$(ssh-agent -s)" > /dev/null
  ssh-add "$KEYS/good" > /dev/null 2>&1
  configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR"
  _before="$(log_count)"
  if locked_sync_and_publish > "$ROOT/out4" 2>&1; then
    kill "$SSH_AGENT_PID" 2>/dev/null || true
    echo "ASSERT FAILED: a sync with the wrong key succeeded"
    exit 1
  fi
  assert_contains "$ROOT/out4" "Permission denied (publickey)"
  assert new_log "$_before" "$ROOT/log4"
  assert_contains "$ROOT/log4" "Failed publickey"
  assert_not_contains "$ROOT/log4" "Accepted publickey"
  # Every fingerprint in the log is the configured (wrong) key's, so exactly one key was offered.
  grep -o 'SHA256:[A-Za-z0-9+/=]*' "$ROOT/log4" | sort -u > "$ROOT/fps4"
  assert test "$(cat "$ROOT/fps4")" = "$FP_WRONG"
  sh -c "$GIT_SSH_COMMAND -G 127.0.0.1" > "$ROOT/G4" 2> "$ROOT/G4.err"
  assert test "$(grep -c '^identityfile ' "$ROOT/G4")" = 1
  assert_contains "$ROOT/G4" "identityfile $SSH_DIR/identity"
  assert_contains "$ROOT/G4" "identityagent none"
  kill "$SSH_AGENT_PID" 2>/dev/null || true
)

echo "test 5: the copies are owned by the running user with mode 0600"
(
  fresh_content
  write_auth good hostkey
  configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR"
  for _f in identity known_hosts; do
    assert test -f "$SSH_DIR/$_f"
    assert test "$(stat -c %a "$SSH_DIR/$_f")" = 600
    assert test "$(stat -c %u "$SSH_DIR/$_f")" = "$(id -u)"
    assert cmp "$SSH_DIR/$_f" "$AUTH_DIR/$_f"
  done
  assert test "$(ls -A "$SSH_DIR" | wc -l | tr -d ' ')" = 2
)

echo "test 6: the exact ssh command"
(
  fresh_content
  write_auth good hostkey
  configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR"
  assert test "$GIT_SSH_VARIANT" = ssh
  _expected="ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o IdentityFile=$SSH_DIR/identity -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$SSH_DIR/known_hosts -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
  assert test "$GIT_SSH_COMMAND" = "$_expected"
  printf '%s\n' "$GIT_SSH_COMMAND" > "$ROOT/cmd6"
  assert_contains "$ROOT/cmd6" "StrictHostKeyChecking=yes"
  assert_contains "$ROOT/cmd6" "IdentitiesOnly=yes"
  assert_not_contains "$ROOT/cmd6" "accept-new"
  assert_not_contains "$ROOT/cmd6" "StrictHostKeyChecking=no"
  assert_not_contains "$ROOT/cmd6" "$(sed -n 2p "$KEYS/good")"
  assert test -z "${GIT_CONFIG_COUNT+set}"
  env | grep -E '^GIT_CONFIG_(KEY|VALUE)_' > "$ROOT/cfg6" || true
  assert test ! -s "$ROOT/cfg6"
)

echo "test 8: start-up validation names the file and never prints its content"
expect_refused() {
  _label="$1"
  _file="$2"
  _secret="$3"
  fresh_content
  if configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR" > "$ROOT/out8" 2>&1; then
    echo "ASSERT FAILED: configure_git_auth accepted $_label"
    exit 1
  fi
  assert_contains "$ROOT/out8" "$AUTH_DIR/$_file"
  if [ -n "$_secret" ]; then
    assert_not_contains "$ROOT/out8" "$_secret"
  fi
  assert test "$(ls -A "$SSH_DIR" | wc -l | tr -d ' ')" = 0
}
(
  write_auth good hostkey
  rm -f "$AUTH_DIR/identity"
  expect_refused "a missing identity" identity ""
  write_auth good hostkey
  chmod 640 "$AUTH_DIR/identity"
  : > "$AUTH_DIR/identity"
  expect_refused "an empty identity" identity ""
  write_auth enc hostkey
  expect_refused "a passphrase-protected identity" identity "$(sed -n 2p "$KEYS/enc")"
  assert_contains "$ROOT/out8" "is not an unencrypted SSH private key"
  write_auth good hostkey
  chmod 640 "$AUTH_DIR/identity"
  cp "$KEYS/good.pub" "$AUTH_DIR/identity"
  expect_refused "a public key as identity" identity "$(cut -d' ' -f2 "$KEYS/good.pub")"
  write_auth good hostkey
  rm -f "$AUTH_DIR/known_hosts"
  expect_refused "a missing known_hosts" known_hosts ""
  write_auth good hostkey
  chmod 640 "$AUTH_DIR/known_hosts"
  : > "$AUTH_DIR/known_hosts"
  expect_refused "an empty known_hosts" known_hosts ""
)

echo "test 9: URL validation table (no network)"
url_verdict() {
  _type="$1"
  _url="$2"
  _list="${3:-}"
  if (OOLONG_GIT_AUTH_TYPE="$_type" GIT_REPO_URL="$_url" GIT_REPO_HOST_ALLOWLIST="$_list" \
      validate_git_repo_url > "$ROOT/out9" 2>&1); then
    echo accepted
  else
    echo refused
  fi
}
for _u in 'ssh://git@git.example.test/org/repo.git' 'ssh://git.example.test:2222/org/repo.git' \
  'git@git.example.test:org/repo.git' 'git.example.test:org/repo.git' \
  'git@git.example.test:/srv/git/repo.git'; do
  assert test "$(url_verdict ssh "$_u")" = accepted
done
while IFS= read -r _u; do
  if [ "$(url_verdict ssh "$_u")" != refused ]; then
    echo "ASSERT FAILED: ssh accepted the URL: $_u"
    exit 1
  fi
done <<'URLS'
https://git.example.test/org/repo.git
file:///tmp/repo.git
git://git.example.test/r
git+ssh://git@git.example.test/r
ext::sh -c true
ssh://-oProxyCommand=true/r
ssh://git@-host/r
ssh://git@@git.example.test/r
ssh://git@git.example.test:0/r
ssh://git@git.example.test:70000/r
ssh://git@git.example.test
git@git.example.test:
git@git.example.test:-x/r
git@git.example.test://r
ssh://git@[::1]/r
ssh://git@git.example.test/r x
ssh://git:not-a-real-token-0001@git.example.test/r
git:not-a-real-token-0001@git.example.test:r
URLS
assert test "$(url_verdict ssh 'git@git.example.test:org/repo.git' git.example.test)" = accepted
assert test "$(url_verdict ssh 'git@git.example.test:org/repo.git' other.example.test)" = refused
assert test "$(url_verdict ssh 'ssh://git@git.example.test:2222/org/repo.git' git.example.test)" = accepted
assert test "$(url_verdict ssh 'ssh://git@git.example.test:2222/org/repo.git' other.example.test)" = refused
MARK="$ROOT/mark9"
assert test "$(url_verdict ssh "ssh://git@git.example.test/\$(touch $MARK)")" = refused
assert test "$(url_verdict ssh "\$(touch $MARK):x")" = refused
assert test ! -e "$MARK"
for _type in token none ""; do
  assert test "$(url_verdict "$_type" 'ssh://git@git.example.test/org/repo.git')" = refused
  assert test "$(url_verdict "$_type" 'git@git.example.test:org/repo.git')" = refused
  assert test "$(url_verdict "$_type" 'https://git.example.test/org/repo.git')" = accepted
done

echo "test 10: the known_hosts name follows the URL form and the port"
(
  fresh_content
  GIT_REPO_URL='git@git.example.test:org/repo.git'
  write_auth good hostkey
  put_known_hosts "git.example.test $(host_pub hostkey)"
  configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR"
  fresh_content
  GIT_REPO_URL='git@git.example.test:org/repo.git'
  write_auth good hostkey
  put_known_hosts "[git.example.test]:2222 $(host_pub hostkey)"
  if configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR" > "$ROOT/out10" 2>&1; then
    echo "ASSERT FAILED: a port-qualified known_hosts entry matched the scp form"
    exit 1
  fi
  fresh_content
  GIT_REPO_URL='ssh://git@git.example.test:2222/org/repo.git'
  write_auth good hostkey
  put_known_hosts "[git.example.test]:2222 $(host_pub hostkey)"
  configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR"
  put_known_hosts "git.example.test $(host_pub hostkey)"
  if configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR" > "$ROOT/out10" 2>&1; then
    echo "ASSERT FAILED: a plain known_hosts entry matched a non-standard port"
    exit 1
  fi
)

echo "test 11: a rotated key is used on the next sync without reconfiguring"
(
  fresh_content
  write_auth good hostkey
  configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR"
  locked_sync_and_publish > "$ROOT/out11" 2>&1
  _pointer="$(cat "$POINTER_FILE")"
  # Rotate to good2: replace the Secret file and the server's authorized key.
  chmod 640 "$AUTH_DIR/identity"
  cp "$KEYS/good2" "$AUTH_DIR/identity"
  chmod 440 "$AUTH_DIR/identity"
  set_authorized good2
  commit_products gamma
  _before="$(log_count)"
  locked_sync_and_publish >> "$ROOT/out11" 2>&1
  _after="$(git -C "$WORK_DIR" rev-parse HEAD)"
  assert test "$(cat "$POINTER_FILE")" = "$_after"
  assert test "$_after" != "$_pointer"
  new_log "$_before" "$ROOT/log11"
  assert_contains "$ROOT/log11" "$FP_GOOD2"
  assert_not_contains "$ROOT/log11" "$FP_GOOD"
  # A bad rotation fails the sync, names the file and leaves the published pointer unchanged.
  chmod 640 "$AUTH_DIR/identity"
  printf 'not a key\n' > "$AUTH_DIR/identity"
  chmod 440 "$AUTH_DIR/identity"
  commit_products delta
  if locked_sync_and_publish > "$ROOT/out11b" 2>&1; then
    echo "ASSERT FAILED: a sync with a garbage key succeeded"
    exit 1
  fi
  assert_contains "$ROOT/out11b" "$AUTH_DIR/identity"
  assert test "$(cat "$POINTER_FILE")" = "$_after"
)
set_authorized good

echo "test 12: argument checks happen before anything is exported"
(
  fresh_content
  write_auth good hostkey
  unset GIT_SSH_COMMAND GIT_SSH_VARIANT
  if configure_git_auth "$HELPER" "$AUTH_DIR" > "$ROOT/out12" 2>&1; then
    echo "ASSERT FAILED: ssh configuration without an ssh directory was accepted"
    exit 1
  fi
  assert_contains "$ROOT/out12" "ssh directory path must match"
  if configure_git_auth "$HELPER" "$AUTH_DIR" "/tmp/a b" > "$ROOT/out12" 2>&1; then
    echo "ASSERT FAILED: an ssh directory with a space was accepted"
    exit 1
  fi
  assert_contains "$ROOT/out12" "ssh directory path must match"
  assert test -z "${GIT_SSH_COMMAND+set}"
  assert test -z "${GIT_SSH_VARIANT+set}"
)

echo "test 13: ssh itself refuses an unknown host with the start-up pre-check bypassed"
(
  fresh_content
  write_auth good hostkey
  configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR"
  locked_sync_and_publish > "$ROOT/out13a" 2>&1
  _pointer="$(cat "$POINTER_FILE")"
  commit_products epsilon
  # Overwrite the copy, not the source: sync_worktree does not call install_ssh_files.
  printf 'other.example.test %s\n' "$(host_pub hostkey)" > "$SSH_DIR/known_hosts"
  cp "$SSH_DIR/known_hosts" "$ROOT/known_hosts.kept"
  _before="$(log_count)"
  if (sync_worktree > "$ROOT/out13" 2>&1); then
    echo "ASSERT FAILED: a sync against an unknown host succeeded"
    exit 1
  fi
  assert_contains "$ROOT/out13" "Host key verification failed"
  assert new_log "$_before" "$ROOT/log13"
  assert_contains "$ROOT/log13" "Connection from 127.0.0.1"
  assert_not_contains "$ROOT/log13" "publickey"
  assert_not_contains "$ROOT/log13" "SHA256:"
  assert cmp "$SSH_DIR/known_hosts" "$ROOT/known_hosts.kept"
  assert test "$(cat "$POINTER_FILE")" = "$_pointer"
)

echo "test 14: ssh state is keyed on the auth type"
(
  fresh_content
  write_auth good hostkey
  # (a) none and token: inherited ssh state is dropped, and install_ssh_files does nothing.
  for _type in none token; do
    _empty="$ROOT/empty14"
    rm -rf "$_empty"
    mkdir -p "$_empty"
    OOLONG_GIT_AUTH_TYPE="$_type"
    if [ "$_type" = token ]; then
      _tokdir="$ROOT/tok14"
      rm -rf "$_tokdir"
      mkdir -p "$_tokdir"
      printf 'tester\n' > "$_tokdir/username"
      printf 'not-a-real-token-0001\n' > "$_tokdir/token"
      GIT_REPO_URL='https://git.example.test/org/repo.git'
      _dir="$_tokdir"
    else
      _dir="$AUTH_DIR"
    fi
    OOLONG_GIT_SSH_AUTH_DIR="$AUTH_DIR"
    OOLONG_GIT_SSH_DIR="$_empty"
    OOLONG_GIT_SSH_KNOWN_HOST="$KNOWN_HOST"
    export OOLONG_GIT_SSH_AUTH_DIR OOLONG_GIT_SSH_DIR OOLONG_GIT_SSH_KNOWN_HOST
    configure_git_auth "$HELPER" "$_dir" "$SSH_DIR"
    assert test -z "${OOLONG_GIT_SSH_AUTH_DIR+set}"
    assert test -z "${OOLONG_GIT_SSH_DIR+set}"
    assert test -z "${OOLONG_GIT_SSH_KNOWN_HOST+set}"
    OOLONG_GIT_SSH_AUTH_DIR="$AUTH_DIR"
    OOLONG_GIT_SSH_DIR="$_empty"
    OOLONG_GIT_SSH_KNOWN_HOST="$KNOWN_HOST"
    install_ssh_files
    assert test "$(ls -A "$_empty" | wc -l | tr -d ' ')" = 0
    unset OOLONG_GIT_SSH_AUTH_DIR OOLONG_GIT_SSH_DIR OOLONG_GIT_SSH_KNOWN_HOST
  done
  # (b) ssh with nothing configured fails closed.
  fresh_content
  write_auth good hostkey
  unset OOLONG_GIT_SSH_AUTH_DIR OOLONG_GIT_SSH_DIR OOLONG_GIT_SSH_KNOWN_HOST
  if install_ssh_files > "$ROOT/out14" 2>&1; then
    echo "ASSERT FAILED: install_ssh_files accepted an unconfigured ssh auth"
    exit 1
  fi
  assert_contains "$ROOT/out14" "ssh auth is not configured"
  _before="$(log_count)"
  if locked_sync_and_publish > "$ROOT/out14" 2>&1; then
    echo "ASSERT FAILED: a sync ran with an unconfigured ssh auth"
    exit 1
  fi
  sleep 1
  assert test "$(log_count)" = "$_before"
  # (c) a failed ssh configuration leaves no state behind.
  rm -f "$AUTH_DIR/identity"
  if configure_git_auth "$HELPER" "$AUTH_DIR" "$SSH_DIR" > "$ROOT/out14" 2>&1; then
    echo "ASSERT FAILED: configure_git_auth accepted a missing identity"
    exit 1
  fi
  assert test -z "${OOLONG_GIT_SSH_AUTH_DIR+set}"
  assert test -z "${OOLONG_GIT_SSH_DIR+set}"
  assert test -z "${OOLONG_GIT_SSH_KNOWN_HOST+set}"
)

echo "all git ssh auth integration tests passed"
