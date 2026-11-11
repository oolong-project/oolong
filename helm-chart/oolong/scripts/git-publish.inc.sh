# Shared git content publication helpers (sourced by git-sync.sh and shell tests).
# Expects CONTENT_DIR, WORK_DIR, REVISIONS_DIR, POINTER_FILE,
# REVISION_RETENTION_COUNT, GIT_REPO_URL, and GIT_BRANCH.

ACTIVE_POINTER_FILE="${CONTENT_DIR}/.oolong-active-revision"
PUBLISH_COMPLETE_MARKER=".oolong-publish-complete"
PUBLISH_LOCK_WAIT_SECONDS="${PUBLISH_LOCK_WAIT_SECONDS:-300}"
PUBLISH_LOCK_HELD=0

validate_revision_retention_count() {
  case "$REVISION_RETENTION_COUNT" in
    ''|*[!0-9]*)
      echo "ERROR: REVISION_RETENTION_COUNT must be a positive integer" >&2
      return 1
      ;;
  esac
  if [ "$REVISION_RETENTION_COUNT" -lt 1 ] ||
     [ "$REVISION_RETENTION_COUNT" -gt 1000 ]; then
    echo "ERROR: REVISION_RETENTION_COUNT must be between 1 and 1000" >&2
    return 1
  fi
  return 0
}

# --- ssh URL grammar (also implemented in templates/_helpers.tpl; keep the two in step) ---
# Only two forms are accepted, with conservative character sets, so nothing reaches ssh that
# it could read as an option:
#   ssh://[user@]host[:port]/path        and        [user@]host:path   (no "://" in it)
# user [A-Za-z0-9_][A-Za-z0-9._-]*  host [A-Za-z0-9][A-Za-z0-9.-]*  port 1-65535
# path (URL form) "/" then [A-Za-z0-9._~+/-]+
# path (scp form) [A-Za-z0-9._~+][A-Za-z0-9._~+/-]*  or  "/" then [A-Za-z0-9._~+-][A-Za-z0-9._~+/-]*
# Nothing is evaluated. Sets _ssh_user, _ssh_host, _ssh_port and _ssh_known_host (the name ssh
# looks up in known_hosts: host, or [host]:port for a port other than 22).

ssh_user_ok() {
  case "$1" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "${1%"${1#?}"}" in
    [A-Za-z0-9_]) return 0 ;;
  esac
  return 1
}

ssh_host_ok() {
  case "$1" in
    '' | *[!A-Za-z0-9.-]*) return 1 ;;
  esac
  case "${1%"${1#?}"}" in
    [A-Za-z0-9]) return 0 ;;
  esac
  return 1
}

# Sets _ssh_port to the port without leading zeros.
ssh_port_ok() {
  _p="$1"
  case "$_p" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#_p}" -le 5 ] || return 1
  while [ "${_p#0}" != "$_p" ]; do
    _p="${_p#0}"
  done
  [ -n "$_p" ] || return 1
  [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ] || return 1
  _ssh_port="$_p"
  return 0
}

ssh_url_path_ok() {
  case "$1" in
    '' | *[!A-Za-z0-9._~+/-]*) return 1 ;;
  esac
  return 0
}

ssh_scp_path_ok() {
  case "$1" in
    '' | *[!A-Za-z0-9._~+/-]*) return 1 ;;
    /*)
      _sp="${1#/}"
      case "${_sp%"${_sp#?}"}" in
        [A-Za-z0-9._~+-]) return 0 ;;
      esac
      return 1
      ;;
  esac
  case "${1%"${1#?}"}" in
    [A-Za-z0-9._~+]) return 0 ;;
  esac
  return 1
}

parse_ssh_repo_url() {
  _ssh_url="$1"
  _ssh_user=""
  _ssh_host=""
  _ssh_port=""
  _ssh_known_host=""
  case "$_ssh_url" in
    ssh://*)
      _ssh_rest="${_ssh_url#ssh://}"
      case "$_ssh_rest" in
        */*) ;;
        *) return 1 ;;
      esac
      _ssh_authority="${_ssh_rest%%/*}"
      ssh_url_path_ok "${_ssh_rest#*/}" || return 1
      case "$_ssh_authority" in
        *@*)
          _ssh_user="${_ssh_authority%%@*}"
          _ssh_hostport="${_ssh_authority#*@}"
          ssh_user_ok "$_ssh_user" || return 1
          ;;
        *)
          _ssh_hostport="$_ssh_authority"
          ;;
      esac
      case "$_ssh_hostport" in
        *@*) return 1 ;;
        *:*)
          _ssh_host="${_ssh_hostport%%:*}"
          ssh_port_ok "${_ssh_hostport#*:}" || return 1
          ;;
        *)
          _ssh_host="$_ssh_hostport"
          ;;
      esac
      ;;
    *://*)
      return 1
      ;;
    *:*)
      _ssh_left="${_ssh_url%%:*}"
      ssh_scp_path_ok "${_ssh_url#*:}" || return 1
      case "$_ssh_left" in
        *@*)
          _ssh_user="${_ssh_left%%@*}"
          _ssh_host="${_ssh_left#*@}"
          ssh_user_ok "$_ssh_user" || return 1
          ;;
        *)
          _ssh_host="$_ssh_left"
          ;;
      esac
      case "$_ssh_host" in
        *@*) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
  ssh_host_ok "$_ssh_host" || return 1
  if [ -z "$_ssh_port" ] || [ "$_ssh_port" = 22 ]; then
    _ssh_known_host="$_ssh_host"
  else
    _ssh_known_host="[$_ssh_host]:$_ssh_port"
  fi
  return 0
}

validate_git_repo_url() {
  case "$OOLONG_GIT_AUTH_TYPE" in
    ssh)
      if ! parse_ssh_repo_url "$GIT_REPO_URL"; then
        echo "ERROR: GIT_REPO_URL must be ssh://[user@]host[:port]/path or [user@]host:path for auth type ssh" >&2
        return 1
      fi
      _host="$_ssh_host"
      ;;
    *)
      case "$GIT_REPO_URL" in
        https://*)
          ;;
        *)
          echo "ERROR: GIT_REPO_URL must use https://" >&2
          return 1
          ;;
      esac
      _rest="${GIT_REPO_URL#https://}"
      case "$_rest" in
        *@*)
          echo "ERROR: GIT_REPO_URL must not include userinfo" >&2
          return 1
          ;;
      esac
      _hostport="${_rest%%/*}"
      if [ -z "$_hostport" ]; then
        echo "ERROR: GIT_REPO_URL is missing a host" >&2
        return 1
      fi
      _host="${_hostport%%:*}"
      if [ -z "$_host" ]; then
        echo "ERROR: GIT_REPO_URL is missing a host" >&2
        return 1
      fi
      ;;
  esac
  if [ -n "$GIT_REPO_HOST_ALLOWLIST" ]; then
    _ok=0
    _oldifs="$IFS"
    IFS=,
    for _allowed in $GIT_REPO_HOST_ALLOWLIST; do
      [ -z "$_allowed" ] && continue
      if [ "$_host" = "$_allowed" ]; then
        _ok=1
        break
      fi
    done
    IFS="$_oldifs"
    if [ "$_ok" != 1 ]; then
      echo "ERROR: GIT_REPO_URL host $_host is not in GIT_REPO_HOST_ALLOWLIST" >&2
      return 1
    fi
  fi
  return 0
}

# configure_git_auth <helper-script> <auth-dir> [<ssh-dir>]
# Wires git for OOLONG_GIT_AUTH_TYPE: none, token or ssh. Everything goes through the
# environment, so no config file holding a secret is written.
#   token: a credential helper (git 2.31+ GIT_CONFIG_*), offered only to the host of
#          GIT_REPO_URL.
#   ssh:   GIT_SSH_COMMAND with strict host key checking against the operator's known_hosts;
#          the key and known_hosts are copied into <ssh-dir> (mode 0600) by install_ssh_files.
# Call after validate_git_repo_url.
configure_git_auth() {
  _helper="$1"
  _authdir="$2"
  _sshdir="${3:-}"

  # Missing or bad credentials fail at once instead of waiting for a terminal while the
  # publish lock is held.
  export GIT_TERMINAL_PROMPT=0

  # ssh state is keyed on the auth type: nothing inherited survives into none or token, and a
  # failed ssh configuration leaves none set.
  unset OOLONG_GIT_SSH_AUTH_DIR OOLONG_GIT_SSH_DIR OOLONG_GIT_SSH_KNOWN_HOST

  # The paths end up in a git config value or in GIT_SSH_COMMAND, which git runs through a shell.
  case "$_helper" in
    '' | *[!A-Za-z0-9/._-]*)
      echo "ERROR: credential helper path must match [A-Za-z0-9/._-]+" >&2
      return 1
      ;;
  esac
  case "$_authdir" in
    '' | *[!A-Za-z0-9/._-]*)
      echo "ERROR: credential directory path must match [A-Za-z0-9/._-]+" >&2
      return 1
      ;;
  esac

  case "$OOLONG_GIT_AUTH_TYPE" in
    none)
      return 0
      ;;
    token)
      ;;
    ssh)
      configure_ssh_auth
      return $?
      ;;
    *)
      echo "ERROR: OOLONG_GIT_AUTH_TYPE must be none, token or ssh" >&2
      return 1
      ;;
  esac

  # The helper is the one reader of the two files; its output is discarded here and its
  # message names the file that is missing, empty or not a single line.
  if ! /bin/sh "$_helper" "$_authdir" get < /dev/null > /dev/null; then
    return 1
  fi

  case "$GIT_REPO_URL" in
    *://*)
      ;;
    *)
      echo "ERROR: GIT_REPO_URL has no scheme" >&2
      return 1
      ;;
  esac
  _scheme="${GIT_REPO_URL%%://*}"
  _rest="${GIT_REPO_URL#*://}"
  _hostport="${_rest%%/*}"
  case "$_hostport" in
    '' | *@*)
      echo "ERROR: GIT_REPO_URL has no usable host for credentials" >&2
      return 1
      ;;
  esac

  # The first entry empties credential.helper, which resets every helper from system and
  # global config (a "store" helper would otherwise write the token to disk).
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0="credential.helper"
  export GIT_CONFIG_VALUE_0=""
  export GIT_CONFIG_KEY_1="credential.${_scheme}://${_hostport}.helper"
  export GIT_CONFIG_VALUE_1="/bin/sh ${_helper} ${_authdir}"
  return 0
}

# The ssh half of configure_git_auth (uses _authdir and _sshdir).
configure_ssh_auth() {
  case "$_sshdir" in
    '' | *[!A-Za-z0-9/._-]*)
      echo "ERROR: ssh directory path must match [A-Za-z0-9/._-]+" >&2
      return 1
      ;;
  esac
  if ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "ERROR: ssh and ssh-keygen are required for auth type ssh" >&2
    return 1
  fi
  # -G only prints the resolved configuration: no connection and no DNS lookup. It fails when
  # the uid has no /etc/passwd entry, which ssh needs.
  if ! ssh -F /dev/null -G oolong.invalid < /dev/null > /dev/null 2>&1; then
    echo "ERROR: ssh cannot run as uid $(id -u): it needs an /etc/passwd entry" >&2
    return 1
  fi
  if ! parse_ssh_repo_url "$GIT_REPO_URL"; then
    echo "ERROR: GIT_REPO_URL must be ssh://[user@]host[:port]/path or [user@]host:path for auth type ssh" >&2
    return 1
  fi
  OOLONG_GIT_SSH_AUTH_DIR="$_authdir"
  OOLONG_GIT_SSH_DIR="$_sshdir"
  OOLONG_GIT_SSH_KNOWN_HOST="$_ssh_known_host"
  if ! install_ssh_files; then
    unset OOLONG_GIT_SSH_AUTH_DIR OOLONG_GIT_SSH_DIR OOLONG_GIT_SSH_KNOWN_HOST
    return 1
  fi
  # Host keys are never trusted on first use: strict checking against the operator's
  # known_hosts only (no system or user config, no agent, no other identity, no prompt).
  export GIT_SSH_VARIANT=ssh
  export GIT_SSH_COMMAND="ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o IdentityFile=${_sshdir}/identity -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${_sshdir}/known_hosts -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
  return 0
}

# Copies the key and known_hosts from the (read-only, group-readable) auth mount into the ssh
# directory with mode 0600, owned by the running user, and validates the copies. Called by
# configure_git_auth and before every sync, so a rotated Secret is used on the next sync. A
# no-op unless the type is ssh; for ssh it fails closed when configure_git_auth did not run.
# Messages name a file, never its content.
install_ssh_files() {
  [ "$OOLONG_GIT_AUTH_TYPE" = ssh ] || return 0
  if [ -z "${OOLONG_GIT_SSH_AUTH_DIR:-}" ] || [ -z "${OOLONG_GIT_SSH_DIR:-}" ] ||
     [ -z "${OOLONG_GIT_SSH_KNOWN_HOST:-}" ]; then
    echo "ERROR: ssh auth is not configured; call configure_git_auth first" >&2
    return 1
  fi
  _isrc="$OOLONG_GIT_SSH_AUTH_DIR"
  _idst="$OOLONG_GIT_SSH_DIR"
  for _ifile in identity known_hosts; do
    if [ ! -f "$_isrc/$_ifile" ] || [ ! -r "$_isrc/$_ifile" ] || [ ! -s "$_isrc/$_ifile" ]; then
      echo "ERROR: $_isrc/$_ifile is missing or empty" >&2
      return 1
    fi
  done
  rm -f "$_idst/identity.new" "$_idst/known_hosts.new"
  # cat and a redirection, not cp -p: the copy belongs to the running user with mode 0600
  # whoever owns the source. A missing final newline is added (ssh rejects such a key).
  if ! (
    umask 077
    for _ifile in identity known_hosts; do
      cat "$_isrc/$_ifile" > "$_idst/$_ifile.new" || exit 1
      if [ -n "$(tail -c 1 "$_isrc/$_ifile")" ]; then
        printf '\n' >> "$_idst/$_ifile.new" || exit 1
      fi
    done
  ); then
    rm -f "$_idst/identity.new" "$_idst/known_hosts.new"
    echo "ERROR: cannot copy the ssh files into $_idst" >&2
    return 1
  fi
  chmod 600 "$_idst/identity.new" "$_idst/known_hosts.new"
  if ! ssh-keygen -y -P '' -f "$_idst/identity.new" < /dev/null > /dev/null 2>&1; then
    rm -f "$_idst/identity.new" "$_idst/known_hosts.new"
    echo "ERROR: $_isrc/identity is not an unencrypted SSH private key" >&2
    return 1
  fi
  if ! ssh-keygen -F "$OOLONG_GIT_SSH_KNOWN_HOST" -f "$_idst/known_hosts.new" > /dev/null 2>&1; then
    rm -f "$_idst/identity.new" "$_idst/known_hosts.new"
    echo "ERROR: $_isrc/known_hosts has no entry for $OOLONG_GIT_SSH_KNOWN_HOST" >&2
    return 1
  fi
  mv -f "$_idst/identity.new" "$_idst/identity"
  mv -f "$_idst/known_hosts.new" "$_idst/known_hosts"
  return 0
}

publish_lock_file() {
  printf '%s/.oolong-publish.lock' "$CONTENT_DIR"
}

acquire_publish_lock() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "ERROR: flock is required for single-writer publication"
    return 1
  fi
  _lock="$(publish_lock_file)"
  if ! : >> "$_lock"; then
    echo "ERROR: cannot create publish lock file $_lock"
    return 1
  fi
  if ! exec 9>>"$_lock"; then
    echo "ERROR: cannot open publish lock file $_lock"
    return 1
  fi
  _waited=0
  while ! flock -n 9; do
    _waited=$((_waited + 1))
    if [ "$_waited" -ge "$PUBLISH_LOCK_WAIT_SECONDS" ]; then
      echo "ERROR: timed out waiting for publish lock"
      return 1
    fi
    sleep 1
  done
  PUBLISH_LOCK_HELD=1
  return 0
}

release_publish_lock() {
  if [ "$PUBLISH_LOCK_HELD" != 1 ]; then
    return 0
  fi
  if ! flock -u 9; then
    echo "ERROR: failed to release publish lock"
    return 1
  fi
  PUBLISH_LOCK_HELD=0
  return 0
}

locked_sync_and_publish() {
  install_ssh_files || return 1
  acquire_publish_lock || return 1
  _status=0
  sync_worktree || _status=$?
  if [ "$_status" -eq 0 ]; then
    publish_revision || _status=$?
  fi
  release_publish_lock
  return $_status
}

revision_complete() {
  [ -d "$1" ] && [ -d "$1/products" ] && [ -f "$1/$PUBLISH_COMPLETE_MARKER" ]
}

read_revision_id() {
  _file="$1"
  if [ ! -f "$_file" ]; then
    REVISION_ID_RESULT=""
    return 0
  fi
  REVISION_ID_RESULT="$(tr -d ' \t\r\n' < "$_file")"
  return 0
}

revision_dir_protected() {
  _base="$1"
  read_revision_id "$POINTER_FILE"
  _cand="$REVISION_ID_RESULT"
  read_revision_id "$ACTIVE_POINTER_FILE"
  _active="$REVISION_ID_RESULT"
  [ -n "$_cand" ] && [ "$_base" = "$_cand" ] && return 0
  [ -n "$_active" ] && [ "$_base" = "$_active" ] && return 0
  return 1
}

sync_worktree() {
  if [ -z "$GIT_REPO_URL" ] || [ -z "$GIT_BRANCH" ]; then
    echo "ERROR: GIT_REPO_URL and GIT_BRANCH are required"
    return 1
  fi

  if [ -d "$WORK_DIR/.git" ]; then
    if ! git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      echo "Work checkout is unusable; replacing it"
      rm -rf "$WORK_DIR"
    else
      _url="$(git -C "$WORK_DIR" remote get-url origin 2>/dev/null || true)"
      if [ "$_url" != "$GIT_REPO_URL" ]; then
        echo "Repository URL changed; replacing work checkout"
        rm -rf "$WORK_DIR"
      fi
    fi
  fi

  if [ ! -d "$WORK_DIR/.git" ]; then
    echo "Cloning repository into work directory..."
    rm -rf "$WORK_DIR"
    if ! git clone --no-checkout "$GIT_REPO_URL" "$WORK_DIR"; then
      echo "ERROR: git clone failed"
      rm -rf "$WORK_DIR"
      return 1
    fi
  fi

  cd "$WORK_DIR"
  if ! git fetch --force origin "$GIT_BRANCH"; then
    echo "ERROR: git fetch failed for $GIT_BRANCH"
    return 1
  fi
  _sha="$(git rev-parse FETCH_HEAD)"
  if [ -z "$_sha" ]; then
    echo "ERROR: fetched revision is empty"
    return 1
  fi
  if ! git checkout --force --detach "$_sha"; then
    echo "ERROR: checkout of $_sha failed"
    return 1
  fi
  git clean -fdx
  echo "Work checkout is $_sha from $GIT_BRANCH"
}

copy_worktree_except_git() {
  _dest="$1"
  _item=""
  for _item in * .[!.]* ..?*; do
    [ -e "$_item" ] || continue
    [ "$_item" = ".git" ] && continue
    if ! cp -a "$_item" "$_dest/"; then
      return 1
    fi
  done
  return 0
}

prune_old_revisions() {
  _keep="$REVISION_RETENTION_COUNT"
  [ "$_keep" -gt 0 ] || return 0

  _eligible=""
  _dir=""
  for _dir in "$REVISIONS_DIR"/*/; do
    [ -d "$_dir" ] || continue
    _base="$(basename "$_dir")"
    case "$_base" in
      .staging-*|.*) continue ;;
    esac
    if revision_dir_protected "$_base"; then
      continue
    fi
    _eligible="${_eligible}${_dir} "
  done

  if [ -z "$_eligible" ]; then
    return 0
  fi

  _count=0
  for _dir in $_eligible; do
    _count=$((_count + 1))
  done
  if [ "$_count" -le "$_keep" ]; then
    return 0
  fi

  _to_delete=$((_count - _keep))
  _sorted="$(ls -1dt $_eligible 2>/dev/null | tail -n "$_to_delete" || true)"
  if [ -z "$_sorted" ]; then
    return 0
  fi
  for _dir in $_sorted; do
    if revision_dir_protected "$(basename "$_dir")"; then
      continue
    fi
    echo "Pruning old revision directory $_dir"
    if ! rm -rf "$_dir"; then
      echo "ERROR: failed to prune $_dir"
      return 1
    fi
  done
  return 0
}

write_text_file() {
  _path="$1"
  _data="$2"
  printf '%s' "$_data" > "$_path"
}

publish_revision() {
  if ! cd "$WORK_DIR"; then
    echo "ERROR: cannot enter work directory $WORK_DIR"
    return 1
  fi
  if ! SHA="$(git rev-parse HEAD)"; then
    echo "ERROR: cannot read HEAD"
    return 1
  fi
  if [ -z "$SHA" ]; then
    echo "ERROR: HEAD is empty"
    return 1
  fi
  TARGET="$REVISIONS_DIR/$SHA"
  STAGING="$REVISIONS_DIR/.staging-$SHA"

  if revision_complete "$TARGET"; then
    echo "Revision $SHA already published"
  else
    echo "Publishing immutable revision $SHA"
    if ! rm -rf "$STAGING"; then
      echo "ERROR: failed to clear staging for $SHA"
      return 1
    fi
    if ! mkdir -p "$STAGING"; then
      echo "ERROR: failed to create staging for $SHA"
      return 1
    fi
    if ! copy_worktree_except_git "$STAGING"; then
      echo "ERROR: failed to copy content for revision $SHA"
      rm -rf "$STAGING"
      return 1
    fi
    if [ ! -d "$STAGING/products" ]; then
      echo "ERROR: published tree for $SHA is missing products/"
      rm -rf "$STAGING"
      return 1
    fi
    if ! write_text_file "$STAGING/$PUBLISH_COMPLETE_MARKER" "$SHA"; then
      echo "ERROR: failed to write completion marker for $SHA"
      rm -rf "$STAGING"
      return 1
    fi
    if ! revision_complete "$STAGING"; then
      echo "ERROR: published tree for $SHA is incomplete"
      rm -rf "$STAGING"
      return 1
    fi
    if [ -e "$TARGET" ] && ! rm -rf "$TARGET"; then
      echo "ERROR: failed to remove incomplete revision $SHA"
      rm -rf "$STAGING"
      return 1
    fi
    if ! mv "$STAGING" "$TARGET"; then
      echo "ERROR: failed to rename staging directory for $SHA"
      rm -rf "$STAGING"
      return 1
    fi
    if ! revision_complete "$TARGET"; then
      echo "ERROR: revision $SHA is incomplete after rename"
      return 1
    fi
  fi

  if ! write_text_file "${POINTER_FILE}.new" "$SHA"; then
    echo "ERROR: failed to write candidate pointer for $SHA"
    rm -f "${POINTER_FILE}.new"
    return 1
  fi
  if ! mv "${POINTER_FILE}.new" "$POINTER_FILE"; then
    echo "ERROR: failed to publish candidate pointer for $SHA"
    rm -f "${POINTER_FILE}.new"
    return 1
  fi
  echo "Active content revision is $SHA"
  if ! prune_old_revisions; then
    echo "ERROR: failed to prune old revisions after $SHA"
    return 1
  fi
  return 0
}
