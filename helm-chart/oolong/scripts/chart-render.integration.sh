#!/bin/sh
# Render checks for image contract and Git pod checksum rollouts.
set -e

CHART="$(cd "$(dirname "$0")/.." && pwd)"
CASE_OUT="$(mktemp)"

assert() {
  if ! "$@"; then
    echo "ASSERT FAILED: $*"
    exit 1
  fi
}

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required for chart render tests"
  exit 1
fi

echo "test helm template requires a compatible image"
if helm template missing-image "$CHART" --set image= >"$CASE_OUT" 2>&1; then
  echo "ASSERT FAILED: helm template without image should fail"
  exit 1
fi

echo "test helm lint accepts a compatible image"
helm lint "$CHART" --set image=oolong-server:local >/dev/null

echo "test published 25.10.6 image is rejected"
if helm template reject-old "$CHART" \
  --set image='registry.relizahub.com/library/oolong-server:25.10.6@sha256:23718baf897d31a780b18b3d910b06407c9cddb64c7e3e7df68944ef1092235b' \
  >"$CASE_OUT" 2>&1; then
  echo "ASSERT FAILED: helm template should reject 25.10.6"
  exit 1
fi

echo "test persistence=false does not emit an empty volume"
RENDER_STATIC="$(mktemp)"
helm template static "$CHART" \
  --set image=oolong-server:local \
  --set persistence.enabled=false > "$RENDER_STATIC"
if grep -q 'name: oolong-content' "$RENDER_STATIC"; then
  echo "ASSERT FAILED: persistence=false still references oolong-content"
  exit 1
fi

echo "test git deployment recreates instead of rolling two publishers"
RENDER_A="$(mktemp)"
RENDER_B="$(mktemp)"
RENDER_C="$(mktemp)"
COMMON_ARGS="--namespace oolong --set image=oolong-server:local --set gitPod.enabled=true --set gitPod.repoUrl=https://example.invalid/repo.git"
# shellcheck disable=SC2086
helm template oolong "$CHART" $COMMON_ARGS \
  --set gitPod.revisionRetentionCount=5 > "$RENDER_A"
# shellcheck disable=SC2086
helm template oolong "$CHART" $COMMON_ARGS \
  --set gitPod.revisionRetentionCount=8 > "$RENDER_B"
# shellcheck disable=SC2086
helm template oolong "$CHART" $COMMON_ARGS \
  --set gitPod.revisionRetentionCount=5 > "$RENDER_C"

GIT_STRATEGY="$(awk '
  $1 == "kind:" && $2 == "Deployment" { dep=1; name=""; strategy="" }
  dep && $1 == "name:" && name == "" { name=$2 }
  dep && $1 == "type:" && strategy == "" { strategy=$2 }
  dep && $0 == "---" {
    if (name == "oolong-git") print strategy
    dep=0
  }
  END {
    if (dep && name == "oolong-git") print strategy
  }
' "$RENDER_A")"
SERVER_STRATEGY="$(awk '
  $1 == "kind:" && $2 == "Deployment" { dep=1; name=""; strategy="" }
  dep && $1 == "name:" && name == "" { name=$2 }
  dep && $1 == "type:" && strategy == "" { strategy=$2 }
  dep && $0 == "---" {
    if (name == "oolong") print strategy
    dep=0
  }
  END {
    if (dep && name == "oolong") print strategy
  }
' "$RENDER_A")"
assert test "$GIT_STRATEGY" = "Recreate"
assert test "$SERVER_STRATEGY" != "Recreate"

echo "test retention is an env var and is not interpolated into git-sync.sh"
assert grep -q 'name: REVISION_RETENTION_COUNT' "$RENDER_A"
assert grep -q 'value: "5"' "$RENDER_A"
assert grep -q 'value: "8"' "$RENDER_B"
if grep -q 'REVISION_RETENTION_COUNT:-{{' "$RENDER_A"; then
  echo "ASSERT FAILED: Helm interpolated retention into git-sync.sh"
  exit 1
fi
if grep -F '$( ' "$RENDER_A" | grep -q REVISION; then
  echo "ASSERT FAILED: retention env contains shell substitution"
  exit 1
fi

echo "test server and git selectors do not overlap"
assert grep -q 'app.kubernetes.io/component: server' "$RENDER_A"
assert grep -q 'app.kubernetes.io/component: git' "$RENDER_A"
python3 - "$RENDER_A" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
assert "app.kubernetes.io/component: server" in text
assert "app.kubernetes.io/component: git" in text
# Service selector must pin the server component so Git pods are excluded.
svc = text.split("kind: Service", 1)[1].split("kind:", 1)[0]
assert "app.kubernetes.io/component: server" in svc
assert "app.kubernetes.io/component: git" not in svc
print("selector split ok")
PY

echo "test checksum is stable when only retention changes"
SUM_A="$(awk '/checksum\/git-script:/ { print $2; exit }' "$RENDER_A")"
SUM_B="$(awk '/checksum\/git-script:/ { print $2; exit }' "$RENDER_B")"
SUM_C="$(awk '/checksum\/git-script:/ { print $2; exit }' "$RENDER_C")"
assert test -n "$SUM_A"
assert test "$SUM_A" = "$SUM_B"
assert test "$SUM_A" = "$SUM_C"

echo "test helm schema rejects a command-substitution retention value without executing it"
PWN_MARK="$(mktemp)"
rm -f "$PWN_MARK"
INJECT='$(touch '"$PWN_MARK"'; echo 5)'
if helm template inject "$CHART" \
    --set image=oolong-server:local \
    --set gitPod.enabled=true \
    --set gitPod.repoUrl=https://example.invalid/repo.git \
    --set gitPod.revisionRetentionCount="$INJECT" \
    >"$CASE_OUT" 2>&1; then
  echo "ASSERT FAILED: helm template accepted \$(...) retention"
  exit 1
fi
if [ -e "$PWN_MARK" ]; then
  echo "ASSERT FAILED: \$(...) ran during helm template"
  exit 1
fi

echo "test helm schema rejects out-of-range retention"
if helm template range "$CHART" \
    --set image=oolong-server:local \
    --set gitPod.enabled=true \
    --set gitPod.repoUrl=https://example.invalid/repo.git \
    --set gitPod.revisionRetentionCount=0 \
    >"$CASE_OUT" 2>&1; then
  echo "ASSERT FAILED: helm template accepted retention 0"
  exit 1
fi

echo "test non-https gitPod.repoUrl is rejected"
if helm template badurl "$CHART" \
    --set image=oolong-server:local \
    --set gitPod.enabled=true \
    --set gitPod.repoUrl='http://example.invalid/repo.git' \
    >"$CASE_OUT" 2>&1; then
  echo "ASSERT FAILED: helm template accepted http:// repoUrl"
  exit 1
fi

NEW_OUT="$(mktemp)"

# Helper: print only the oolong-git Deployment document of a render.
git_deployment_doc() {
  python3 -I - "$1" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
for doc in text.split("\n---\n"):
    if "kind: Deployment" in doc and "name: oolong-git\n" in doc:
        print(doc)
        break
PY
}

echo "test default render has auth type none and no git-auth volume"
GIT_DOC_A="$(mktemp)"
git_deployment_doc "$RENDER_A" > "$GIT_DOC_A"
assert test -s "$GIT_DOC_A"
assert grep -q -A1 'name: OOLONG_GIT_AUTH_TYPE' "$GIT_DOC_A"
assert grep -q 'value: "none"' "$GIT_DOC_A"
for needle in 'name: git-auth' '/etc/oolong-git-auth' 'secretName'; do
  if grep -q "$needle" "$GIT_DOC_A"; then
    echo "ASSERT FAILED: default render contains $needle"
    exit 1
  fi
done

echo "test auth.type=token wires the Secret as a read-only directory mount"
RENDER_TOKEN="$(mktemp)"
# shellcheck disable=SC2086
helm template oolong "$CHART" $COMMON_ARGS \
  --set gitPod.auth.type=token \
  --set gitPod.auth.existingSecret=oolong-git-auth \
  --set gitPod.auth.token.usernameKey=user \
  --set gitPod.auth.token.tokenKey=pat > "$RENDER_TOKEN"
GIT_DOC_T="$(mktemp)"
git_deployment_doc "$RENDER_TOKEN" > "$GIT_DOC_T"
python3 -I - "$GIT_DOC_T" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
assert re.search(r'name: OOLONG_GIT_AUTH_TYPE\n\s+value: "token"', text)
vol = text.split("- name: git-auth\n          secret:", 1)[1]
vol = re.split(r"\n {0,8}\S", vol, maxsplit=1)[0]
assert 'secretName: "oolong-git-auth"' in vol, vol
assert "defaultMode: 0440" in vol
assert "optional: false" in vol
assert re.search(r'- key: "user"\n\s+path: username', vol)
assert re.search(r'- key: "pat"\n\s+path: token', vol)
mount = text.split("- name: git-auth\n              mountPath:", 1)[1].split("\n", 3)
assert mount[0].strip() == "/etc/oolong-git-auth"
assert mount[1].strip() == "readOnly: true"
assert "subPath" not in text
assert "secretKeyRef" not in text
assert "OOLONG_GIT_TOKEN" not in text and "OOLONG_GIT_USERNAME" not in text
print("token wiring ok")
PY

echo "test schema refuses every half-configured gitPod.auth block"
schema_refuses() {
  _label="$1"
  shift
  if helm template refuse "$CHART" --namespace oolong --set image=oolong-server:local \
      --set gitPod.enabled=true --set gitPod.repoUrl=https://example.invalid/repo.git \
      "$@" >"$NEW_OUT" 2>&1; then
    echo "ASSERT FAILED: helm template accepted $_label"
    exit 1
  fi
}
schema_refuses "token without existingSecret" --set gitPod.auth.type=token
schema_refuses "none with existingSecret" --set gitPod.auth.type=none --set gitPod.auth.existingSecret=x
schema_refuses "type Token" --set gitPod.auth.type=Token
schema_refuses "unknown field existingsecret" --set gitPod.auth.existingsecret=x
schema_refuses "empty tokenKey" --set gitPod.auth.type=token --set gitPod.auth.existingSecret=x \
  --set gitPod.auth.token.tokenKey=
schema_refuses "usernameKey with a space" --set gitPod.auth.type=token --set gitPod.auth.existingSecret=x \
  --set 'gitPod.auth.token.usernameKey=a b'
schema_refuses "existingSecret Bad_Name" --set gitPod.auth.type=token --set gitPod.auth.existingSecret=Bad_Name

echo "test template guard refuses a bad auth block with --skip-schema-validation"
if helm template guard "$CHART" --namespace oolong --set image=oolong-server:local \
    --set gitPod.enabled=true --set gitPod.repoUrl=https://example.invalid/repo.git \
    --set gitPod.auth.type=token --skip-schema-validation >"$NEW_OUT" 2>&1; then
  echo "ASSERT FAILED: helm template accepted token without existingSecret"
  exit 1
fi
assert grep -q 'gitPod.auth.existingSecret' "$NEW_OUT"
if helm template guard "$CHART" --namespace oolong --set image=oolong-server:local \
    --set gitPod.enabled=true --set gitPod.repoUrl=https://example.invalid/repo.git \
    --set gitPod.auth.type=bogus --skip-schema-validation >"$NEW_OUT" 2>&1; then
  echo "ASSERT FAILED: helm template accepted auth type bogus"
  exit 1
fi

echo "test reserved gitPod.env names fail the render and others pass through"
for NAME in GIT_REPO_URL GIT_BRANCH GIT_REPO_HOST_ALLOWLIST REVISION_RETENTION_COUNT CONTENT_DIR \
  SYNC_INTERVAL HOME GIT_CURL_VERBOSE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_ASKPASS SSH_ASKPASS \
  SSH_ASKPASS_REQUIRE GIT_TERMINAL_PROMPT GIT_ALLOW_PROTOCOL GIT_SSL_NO_VERIFY GIT_SSH \
  GIT_SSH_COMMAND GIT_SSH_VARIANT OOLONG_GIT_SSH_DIR GIT_TRACE GIT_TRACE_CURL GIT_TRACE2_EVENT GIT_TRACE_REDACT GIT_CONFIG_KEY_0 \
  GIT_CONFIG_VALUE_0 OOLONG_GIT_TOKEN; do
  # shellcheck disable=SC2086
  if helm template reserved "$CHART" $COMMON_ARGS --set "gitPod.env.$NAME=x" \
      >"$NEW_OUT" 2>&1; then
    echo "ASSERT FAILED: helm template accepted reserved gitPod.env.$NAME"
    exit 1
  fi
  if ! grep -q "gitPod.env.$NAME is set by the chart" "$NEW_OUT"; then
    echo "ASSERT FAILED: refusal of gitPod.env.$NAME does not name it"
    exit 1
  fi
done
RENDER_ENV="$(mktemp)"
# shellcheck disable=SC2086
helm template oolong "$CHART" $COMMON_ARGS \
  --set gitPod.env.GIT_SSL_CAINFO=/etc/ssl/certs/ca.pem \
  --set gitPod.env.GIT_HTTP_LOW_SPEED_LIMIT=1 > "$RENDER_ENV"
assert grep -q -A1 'name: GIT_SSL_CAINFO' "$RENDER_ENV"
assert grep -q 'value: "/etc/ssl/certs/ca.pem"' "$RENDER_ENV"
assert grep -q -A1 'name: GIT_HTTP_LOW_SPEED_LIMIT' "$RENDER_ENV"

echo "test userinfo in gitPod.repoUrl is refused at render without echoing the token"
for URL in 'https://tester:not-a-real-token-0001@example.invalid/repo.git' \
  'http://tester:not-a-real-token-0001@example.invalid/repo.git'; do
  if helm template userinfo "$CHART" --namespace oolong --set image=oolong-server:local \
      --set gitPod.enabled=true --set "gitPod.repoUrl=$URL" >"$NEW_OUT" 2>&1; then
    echo "ASSERT FAILED: helm template accepted userinfo in repoUrl"
    exit 1
  fi
  if grep -q 'not-a-real-token-0001' "$NEW_OUT"; then
    echo "ASSERT FAILED: schema refusal echoed the token"
    exit 1
  fi
  if helm template userinfo "$CHART" --namespace oolong --set image=oolong-server:local \
      --set gitPod.enabled=true --set "gitPod.repoUrl=$URL" --skip-schema-validation \
      >"$NEW_OUT" 2>&1; then
    echo "ASSERT FAILED: helm template accepted userinfo in repoUrl with --skip-schema-validation"
    exit 1
  fi
  if grep -q 'not-a-real-token-0001' "$NEW_OUT"; then
    echo "ASSERT FAILED: template guard echoed the token"
    exit 1
  fi
  assert grep -q 'gitPod.repoUrl' "$NEW_OUT"
done
if helm template userinfo "$CHART" --namespace oolong --set image=oolong-server:local \
    --set gitPod.enabled=true --set 'gitPod.repoUrl=https://example.invalid/r@x.git' \
    >"$NEW_OUT" 2>&1; then
  echo "ASSERT FAILED: helm template accepted @ in the repoUrl path"
  exit 1
fi
helm template defaults "$CHART" --set image=oolong-server:local >/dev/null

echo "test git-sync.sh validates the URL before it prints the configuration"
VALIDATE_LINE="$(grep -n 'validate_git_repo_url || exit 1' "$RENDER_A" | head -1 | cut -d: -f1)"
PRINT_LINE="$(grep -n 'Repository: \$GIT_REPO_URL' "$RENDER_A" | head -1 | cut -d: -f1)"
assert test -n "$VALIDATE_LINE"
assert test -n "$PRINT_LINE"
assert test "$VALIDATE_LINE" -lt "$PRINT_LINE"

echo "test helm lint accepts both auth types"
helm lint "$CHART" --set image=oolong-server:local --set gitPod.auth.type=none >/dev/null
helm lint "$CHART" --set image=oolong-server:local --set gitPod.auth.type=token \
  --set gitPod.auth.existingSecret=x >/dev/null

# --- OOL-2: gitPod.auth.type ssh ---------------------------------------------------------
KNOWN_HOSTS_FILE="$(mktemp)"
printf 'git.example.test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOoolongTestOnlyNotARealHostKey0000000000\n' \
  > "$KNOWN_HOSTS_FILE"
SSH_URL='ssh://git@git.example.test/org/repo.git'

# ssh_helm <url> [helm args...]: render with auth type ssh and the made-up Secret name.
ssh_helm() {
  _url="$1"
  shift
  helm template ssh "$CHART" --namespace oolong --set image=oolong-server:local \
    --set gitPod.enabled=true --set "gitPod.repoUrl=$_url" --set gitPod.auth.type=ssh \
    --set gitPod.auth.existingSecret=oolong-git-ssh "$@"
}

# refused <label> <helm args...>: the render must fail, with and without schema validation
# when the next word is -2. Output goes to $NEW_OUT.
refused() {
  _label="$1"
  shift
  if "$@" >"$NEW_OUT" 2>&1; then
    echo "ASSERT FAILED: helm template accepted $_label"
    exit 1
  fi
}

echo "test ssh wiring with known_hosts from the Secret"
RENDER_SSH="$(mktemp)"
ssh_helm "$SSH_URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts > "$RENDER_SSH"
python3 -I - "$RENDER_SSH" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
docs = text.split("\n---\n")
dep = next(d for d in docs if "kind: Deployment" in d and "name: ssh-oolong-git\n" in d)
cm = next(d for d in docs if "kind: ConfigMap" in d and "name: ssh-oolong-git-ssh\n" in d)
script = next(d for d in docs if "name: ssh-oolong-git-script\n" in d)
assert re.search(r'name: OOLONG_GIT_AUTH_TYPE\n\s+value: "ssh"', dep)
vol = dep.split("- name: git-auth\n          projected:", 1)[1]
vol = re.split(r"\n        - name: git-ssh", vol, maxsplit=1)[0]
assert "defaultMode: 0440" in vol
assert 'name: "oolong-git-ssh"' in vol and "optional: false" in vol
assert re.search(r'- key: "ssh-privatekey"\n\s+path: identity', vol)
assert re.search(r'- key: "known_hosts"\n\s+path: known_hosts', vol)
assert "configMap" not in vol
mount = dep.split("- name: git-auth\n              mountPath:", 1)[1].split("\n", 3)
assert mount[0].strip() == "/etc/oolong-git-auth" and mount[1].strip() == "readOnly: true"
assert "subPath" not in dep.split("- name: git-ssh")[0].split("- name: git-auth\n              mountPath:", 1)[1].split("- name: git-passwd")[0]
assert re.search(r"- name: git-ssh\n\s+emptyDir:\n\s+medium: Memory\n\s+sizeLimit: 1Mi", dep)
assert re.search(r"- name: git-ssh\n\s+mountPath: /tmp/oolong-git-ssh", dep)
assert re.search(
    r"- name: git-passwd\n\s+mountPath: /etc/passwd\n\s+subPath: passwd\n\s+readOnly: true", dep
)
assert re.search(r"- name: git-passwd\n\s+configMap:\n\s+name: ssh-oolong-git-ssh", dep)
passwd = cm.split("passwd: |\n", 1)[1]
lines = [l.strip() for l in passwd.splitlines() if l.strip() and not l.strip().startswith("known_hosts")]
assert lines == [
    "root:x:0:0:root:/root:/sbin/nologin",
    "oolong-git:x:10001:0:oolong git sync:/tmp/git-home:/sbin/nologin",
], lines
assert "secretKeyRef" not in dep
assert "GIT_SSH_COMMAND" not in dep
assert "configure_git_auth /scripts/git-credential-oolong.sh /etc/oolong-git-auth /tmp/oolong-git-ssh" in script
assert 'if [ "$OOLONG_GIT_AUTH_TYPE" = ssh ]; then' in script
assert "protocol.ssh.allow always" in script and "protocol.ssh.allow never" in script
print("ssh wiring ok")
PY

echo "test ssh wiring with inline known_hosts"
RENDER_SSH_INLINE="$(mktemp)"
ssh_helm "$SSH_URL" --set-file gitPod.auth.ssh.knownHosts="$KNOWN_HOSTS_FILE" > "$RENDER_SSH_INLINE"
python3 -I - "$RENDER_SSH_INLINE" "$KNOWN_HOSTS_FILE" <<'PY'
import json
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
expected = open(sys.argv[2], encoding="utf-8").read()
docs = text.split("\n---\n")
dep = next(d for d in docs if "kind: Deployment" in d and "name: ssh-oolong-git\n" in d)
cm = next(d for d in docs if "kind: ConfigMap" in d and "name: ssh-oolong-git-ssh\n" in d)
vol = dep.split("- name: git-auth\n          projected:", 1)[1]
vol = re.split(r"\n        - name: git-ssh", vol, maxsplit=1)[0]
assert re.search(r'- key: "ssh-privatekey"\n\s+path: identity', vol)
assert "path: known_hosts" in vol and vol.count("path: known_hosts") == 1
assert re.search(r"- configMap:\n\s+name: ssh-oolong-git-ssh\n\s+items:\n\s+- key: known_hosts", vol)
line = next(l for l in cm.splitlines() if l.strip().startswith("known_hosts:"))
assert json.loads(line.split("known_hosts:", 1)[1].strip()) == expected
print("inline known_hosts ok")
PY
printf 'git.example.test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOoolongTestOnlyOtherHostKey00000000000\n' \
  > "$KNOWN_HOSTS_FILE.2"
RENDER_SSH_INLINE2="$(mktemp)"
ssh_helm "$SSH_URL" --set-file gitPod.auth.ssh.knownHosts="$KNOWN_HOSTS_FILE.2" > "$RENDER_SSH_INLINE2"
SUM_I1="$(awk '/checksum\/git-script:/ { print $2; exit }' "$RENDER_SSH_INLINE")"
SUM_I2="$(awk '/checksum\/git-script:/ { print $2; exit }' "$RENDER_SSH_INLINE2")"
assert test -n "$SUM_I1"
assert test "$SUM_I1" != "$SUM_I2"

echo "test none and token renders carry no ssh wiring"
for R in "$RENDER_A" "$RENDER_TOKEN"; do
  # The script text names /tmp/oolong-git-ssh for every type (an ignored argument), so the
  # checks are on volume, mount and ConfigMap names.
  for needle in 'name: git-ssh' 'name: git-passwd' 'mountPath: /etc/passwd' 'projected' 'name: [a-z0-9-]*-git-ssh$' \
    'mountPath: /tmp/oolong-git-ssh'; do
    if grep -q -E "$needle" "$R"; then
      echo "ASSERT FAILED: a non-ssh render contains $needle"
      exit 1
    fi
  done
  assert grep -q 'protocol.ssh.allow never' "$R"
done

echo "test the uid in the rendered passwd comes from the values"
ssh_helm "$SSH_URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts \
  --set gitPod.securityContext.runAsUser=12345 > "$NEW_OUT"
assert grep -q 'oolong-git:x:12345:0:' "$NEW_OUT"
refused "ssh without a uid" ssh_helm "$SSH_URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts \
  --set gitPod.securityContext.runAsUser=null
assert grep -q 'gitPod.securityContext.runAsUser' "$NEW_OUT"

echo "test ssh auth blocks that are half configured are refused by schema and template guard"
ssh_refused_both() {
  _label="$1"
  shift
  refused "$_label (schema)" ssh_helm "$SSH_URL" "$@"
  refused "$_label (template guard)" ssh_helm "$SSH_URL" "$@" --skip-schema-validation
}
ssh_refused_both "ssh without known_hosts" --set gitPod.auth.ssh.knownHostsKey=
assert grep -q 'gitPod.auth.ssh.knownHostsKey and gitPod.auth.ssh.knownHosts' "$NEW_OUT"
ssh_refused_both "ssh with both known_hosts sources" --set gitPod.auth.ssh.knownHostsKey=known_hosts \
  --set-file gitPod.auth.ssh.knownHosts="$KNOWN_HOSTS_FILE"
assert grep -q 'gitPod.auth.ssh.knownHostsKey and gitPod.auth.ssh.knownHosts' "$NEW_OUT"
ssh_refused_both "ssh with an empty privateKeyKey" --set gitPod.auth.ssh.knownHostsKey=known_hosts \
  --set gitPod.auth.ssh.privateKeyKey=
assert grep -q 'gitPod.auth.ssh.privateKeyKey' "$NEW_OUT"
ssh_refused_both "ssh without existingSecret" --set gitPod.auth.ssh.knownHostsKey=known_hosts \
  --set gitPod.auth.existingSecret=
assert grep -q 'gitPod.auth.existingSecret' "$NEW_OUT"
refused "knownHostsKey with a space (schema)" ssh_helm "$SSH_URL" --set 'gitPod.auth.ssh.knownHostsKey=a b'
refused "type SSH (schema)" ssh_helm "$SSH_URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts \
  --set gitPod.auth.type=SSH
refused "type SSH (template guard)" ssh_helm "$SSH_URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts \
  --set gitPod.auth.type=SSH --skip-schema-validation
assert grep -q 'gitPod.auth.type must be none, token or ssh' "$NEW_OUT"

echo "test a private key in knownHosts is refused without being printed"
KEY_IN_HOSTS="$(mktemp)"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key-0001\n-----END OPENSSH PRIVATE KEY-----\n' > "$KEY_IN_HOSTS"
refused "a private key in knownHosts (schema)" ssh_helm "$SSH_URL" --set-file gitPod.auth.ssh.knownHosts="$KEY_IN_HOSTS"
assert_no_key_echo() {
  if grep -q 'not-a-real-key-0001' "$NEW_OUT"; then
    echo "ASSERT FAILED: the refusal echoed the key"
    exit 1
  fi
}
assert_no_key_echo
refused "a private key in knownHosts (template guard)" ssh_helm "$SSH_URL" \
  --set-file gitPod.auth.ssh.knownHosts="$KEY_IN_HOSTS" --skip-schema-validation
assert_no_key_echo
assert grep -q 'gitPod.auth.ssh.knownHosts' "$NEW_OUT"

echo "test a password in an ssh URL is refused without being printed"
for URL in 'ssh://git:not-a-real-token-0001@git.example.test/org/repo.git' \
  'git:not-a-real-token-0001@git.example.test:org/repo.git'; do
  refused "a password in $URL (schema)" ssh_helm "$URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts
  if grep -q 'not-a-real-token-0001' "$NEW_OUT"; then
    echo "ASSERT FAILED: the schema refusal echoed the password"
    exit 1
  fi
  refused "a password in $URL (template guard)" ssh_helm "$URL" \
    --set gitPod.auth.ssh.knownHostsKey=known_hosts --skip-schema-validation
  if grep -q 'not-a-real-token-0001' "$NEW_OUT"; then
    echo "ASSERT FAILED: the template refusal echoed the password"
    exit 1
  fi
  assert grep -q 'gitPod.repoUrl' "$NEW_OUT"
done

echo "test ssh URL forms that are accepted"
for URL in 'ssh://git@git.example.test/org/repo.git' 'ssh://git.example.test:2222/org/repo.git' \
  'git@git.example.test:org/repo.git' 'git.example.test:org/repo.git' \
  'git@git.example.test:/srv/git/repo.git'; do
  ssh_helm "$URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts > "$NEW_OUT"
  if ! grep -A1 'name: GIT_REPO_URL' "$NEW_OUT" | grep -qF "value: \"$URL\""; then
    echo "ASSERT FAILED: GIT_REPO_URL is not $URL"
    exit 1
  fi
done

echo "test ssh URL forms that are refused"
while IFS= read -r URL; do
  refused "ssh URL $URL (schema)" ssh_helm "$URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts
  refused "ssh URL $URL (template guard)" ssh_helm "$URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts \
    --skip-schema-validation
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
URLS

echo "test ssh URLs are refused for none and token"
for URL in 'ssh://git@git.example.test/org/repo.git' 'git@git.example.test:org/repo.git'; do
  refused "ssh URL with type none (schema)" helm template x "$CHART" --namespace oolong \
    --set image=oolong-server:local --set gitPod.enabled=true --set "gitPod.repoUrl=$URL"
  refused "ssh URL with type none (template guard)" helm template x "$CHART" --namespace oolong \
    --set image=oolong-server:local --set gitPod.enabled=true --set "gitPod.repoUrl=$URL" \
    --skip-schema-validation
  refused "ssh URL with type token (schema)" helm template x "$CHART" --namespace oolong \
    --set image=oolong-server:local --set gitPod.enabled=true --set "gitPod.repoUrl=$URL" \
    --set gitPod.auth.type=token --set gitPod.auth.existingSecret=x
  refused "ssh URL with type token (template guard)" helm template x "$CHART" --namespace oolong \
    --set image=oolong-server:local --set gitPod.enabled=true --set "gitPod.repoUrl=$URL" \
    --set gitPod.auth.type=token --set gitPod.auth.existingSecret=x --skip-schema-validation
done
refused "ssh:// URL without @ with type none" helm template x "$CHART" --namespace oolong \
  --set image=oolong-server:local --set gitPod.enabled=true \
  --set gitPod.repoUrl=ssh://git.example.test/org/repo.git
assert grep -q 'https://' "$NEW_OUT"

echo "test gitPod.allowedHosts is checked at render for ssh and https URLs"
ssh_helm 'ssh://git@git.example.test/org/repo.git' --set gitPod.auth.ssh.knownHostsKey=known_hosts \
  --set 'gitPod.allowedHosts={git.example.test}' > "$NEW_OUT"
assert grep -q -A1 'name: GIT_REPO_HOST_ALLOWLIST' "$NEW_OUT"
ssh_helm 'git@git.example.test:org/repo.git' --set gitPod.auth.ssh.knownHostsKey=known_hosts \
  --set 'gitPod.allowedHosts={git.example.test}' >/dev/null
for URL in 'ssh://git@git.example.test/org/repo.git' 'git@git.example.test:org/repo.git'; do
  refused "ssh host outside the allowlist" ssh_helm "$URL" --set gitPod.auth.ssh.knownHostsKey=known_hosts \
    --set 'gitPod.allowedHosts={other.example.test}'
  assert grep -q 'gitPod.repoUrl host is not in gitPod.allowedHosts' "$NEW_OUT"
done
helm template x "$CHART" --namespace oolong --set image=oolong-server:local --set gitPod.enabled=true \
  --set gitPod.repoUrl=https://example.invalid/repo.git --set 'gitPod.allowedHosts={example.invalid}' >/dev/null
refused "https host outside the allowlist" helm template x "$CHART" --namespace oolong \
  --set image=oolong-server:local --set gitPod.enabled=true \
  --set gitPod.repoUrl=https://example.invalid/repo.git --set 'gitPod.allowedHosts={other.example.test}'
assert grep -q 'gitPod.repoUrl host is not in gitPod.allowedHosts' "$NEW_OUT"

echo "test helm lint accepts auth type ssh"
helm lint "$CHART" --set image=oolong-server:local --set gitPod.auth.type=ssh \
  --set gitPod.auth.existingSecret=x --set gitPod.auth.ssh.knownHostsKey=k >/dev/null

echo "test git-sync.sh validates and configures auth before it prints the ssh configuration"
SSH_VALIDATE_LINE="$(grep -n 'validate_git_repo_url || exit 1' "$RENDER_SSH" | head -1 | cut -d: -f1)"
SSH_CONFIGURE_LINE="$(grep -n 'configure_git_auth /scripts' "$RENDER_SSH" | head -1 | cut -d: -f1)"
SSH_PRINT_LINE="$(grep -n 'Repository: \$GIT_REPO_URL' "$RENDER_SSH" | head -1 | cut -d: -f1)"
assert test "$SSH_VALIDATE_LINE" -lt "$SSH_CONFIGURE_LINE"
assert test "$SSH_CONFIGURE_LINE" -lt "$SSH_PRINT_LINE"

SCRIPT_CHART="$(mktemp -d)"
cp -R "$CHART/." "$SCRIPT_CHART/"
printf '\n# checksum probe\n' >> "$SCRIPT_CHART/scripts/git-publish.inc.sh"
RENDER_SCRIPT="$(mktemp)"
# shellcheck disable=SC2086
helm template oolong "$SCRIPT_CHART" $COMMON_ARGS \
  --set gitPod.revisionRetentionCount=5 > "$RENDER_SCRIPT"
SUM_SCRIPT="$(awk '/checksum\/git-script:/ { print $2; exit }' "$RENDER_SCRIPT")"
assert test -n "$SUM_SCRIPT"
assert test "$SUM_A" != "$SUM_SCRIPT"
rm -rf "$SCRIPT_CHART"

echo "test checksum changes when only the credential helper changes"
HELPER_CHART="$(mktemp -d)"
cp -R "$CHART/." "$HELPER_CHART/"
printf '\n# checksum probe\n' >> "$HELPER_CHART/scripts/git-credential-oolong.sh"
RENDER_HELPER="$(mktemp)"
# shellcheck disable=SC2086
helm template oolong "$HELPER_CHART" $COMMON_ARGS \
  --set gitPod.revisionRetentionCount=5 > "$RENDER_HELPER"
SUM_HELPER="$(awk '/checksum\/git-script:/ { print $2; exit }' "$RENDER_HELPER")"
assert test -n "$SUM_HELPER"
assert test "$SUM_A" != "$SUM_HELPER"
rm -rf "$HELPER_CHART"

echo "all chart render integration tests passed"
