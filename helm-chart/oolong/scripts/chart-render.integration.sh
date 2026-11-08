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
schema_refuses "type ssh" --set gitPod.auth.type=ssh
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
  GIT_SSH_COMMAND GIT_TRACE GIT_TRACE_CURL GIT_TRACE2_EVENT GIT_TRACE_REDACT GIT_CONFIG_KEY_0 \
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
