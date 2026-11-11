{{/*
Expand the name of the chart.
*/}}
{{- define "oolong.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "oolong.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "oolong.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "oolong.labels" -}}
helm.sh/chart: {{ include "oolong.chart" . }}
{{ include "oolong.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "oolong.selectorLabels" -}}
app.kubernetes.io/name: {{ include "oolong.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Server pods only. Must not match the Git Deployment, or kubectl logs/exec
and the Service will treat Git pods as server replicas.
*/}}
{{- define "oolong.serverSelectorLabels" -}}
{{ include "oolong.selectorLabels" . }}
app.kubernetes.io/component: server
{{- end }}

{{/*
Git publisher pods only.
*/}}
{{- define "oolong.gitSelectorLabels" -}}
{{ include "oolong.selectorLabels" . }}
app.kubernetes.io/component: git
{{- end }}

{{/*
Git remotes the Git pod accepts. none and token: https:// without credentials in the URL. ssh:
ssh://[user@]host[:port]/path or [user@]host:path (the same grammar as parse_ssh_repo_url in
scripts/git-publish.inc.sh; keep the two in step). Local file remotes stay in tests that call
sync_worktree directly, not the Git pod entrypoint. Messages are fixed text and never echo the URL.
*/}}
{{- define "oolong.requireGitRepoUrl" -}}
{{- $type := include "oolong.gitAuthType" . -}}
{{- $url := .Values.gitPod.repoUrl | default "" -}}
{{- if not $url }}
{{- fail "gitPod.repoUrl is required when gitPod.enabled is true" }}
{{- end }}
{{- $host := "" -}}
{{- if eq $type "ssh" -}}
{{- $urlForm := regexMatch `^ssh://([A-Za-z0-9_][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?/[A-Za-z0-9._~+/-]+$` $url -}}
{{- $scpForm := regexMatch `^([A-Za-z0-9_][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*:([A-Za-z0-9._~+][A-Za-z0-9._~+/-]*|/[A-Za-z0-9._~+-][A-Za-z0-9._~+/-]*)$` $url -}}
{{- if not (or $urlForm $scpForm) }}
{{- fail "gitPod.repoUrl must be ssh://[user@]host[:port]/path or [user@]host:path when gitPod.auth.type is ssh" }}
{{- end }}
{{- if $urlForm -}}
{{- $host = regexReplaceAll `^ssh://([^@/]*@)?([^:/]+).*$` $url "${2}" -}}
{{- if regexMatch `^ssh://([^@/]*@)?[^:/]+:[0-9]+/` $url -}}
{{- $port := regexReplaceAll `^ssh://([^@/]*@)?[^:/]+:([0-9]+)/.*$` $url "${2}" | atoi -}}
{{- if or (lt $port 1) (gt $port 65535) }}
{{- fail "gitPod.repoUrl port must be 1-65535" }}
{{- end }}
{{- end -}}
{{- else -}}
{{- $host = regexReplaceAll `^([^@:]*@)?([^:]+):.*$` $url "${2}" -}}
{{- end -}}
{{- else -}}
{{- if contains "@" $url }}
{{- fail "gitPod.repoUrl must not contain @ (no user name or token in the URL); set gitPod.auth for a private repository" }}
{{- end }}
{{- if not (hasPrefix "https://" $url) }}
{{- fail "gitPod.repoUrl must be an https:// URL (ssh:// needs gitPod.auth.type ssh). The Git pod disables git://, http://, and file://." }}
{{- end }}
{{- $host = regexReplaceAll `^https://([^/:]*).*$` $url "${1}" -}}
{{- end -}}
{{- if .Values.gitPod.allowedHosts }}
{{- if not (has $host .Values.gitPod.allowedHosts) }}
{{- fail "gitPod.repoUrl host is not in gitPod.allowedHosts" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Validated gitPod.auth.type: none, token or ssh. Repeats the schema rules so they also hold with
--skip-schema-validation. Messages name the value path and never include a value.
*/}}
{{- define "oolong.gitAuthType" -}}
{{- $auth := .Values.gitPod.auth | default dict -}}
{{- $type := $auth.type | default "" -}}
{{- if not (has $type (list "none" "token" "ssh")) -}}
{{- fail "gitPod.auth.type must be none, token or ssh" -}}
{{- end -}}
{{- if eq $type "token" -}}
{{- if not $auth.existingSecret -}}
{{- fail "gitPod.auth.existingSecret is required when gitPod.auth.type is token" -}}
{{- end -}}
{{- $keys := $auth.token | default dict -}}
{{- if not $keys.usernameKey -}}
{{- fail "gitPod.auth.token.usernameKey is required when gitPod.auth.type is token" -}}
{{- end -}}
{{- if not $keys.tokenKey -}}
{{- fail "gitPod.auth.token.tokenKey is required when gitPod.auth.type is token" -}}
{{- end -}}
{{- else if eq $type "ssh" -}}
{{- if not $auth.existingSecret -}}
{{- fail "gitPod.auth.existingSecret is required when gitPod.auth.type is ssh" -}}
{{- end -}}
{{- $ssh := $auth.ssh | default dict -}}
{{- if not $ssh.privateKeyKey -}}
{{- fail "gitPod.auth.ssh.privateKeyKey is required when gitPod.auth.type is ssh" -}}
{{- end -}}
{{- if and $ssh.knownHostsKey $ssh.knownHosts -}}
{{- fail "set exactly one of gitPod.auth.ssh.knownHostsKey and gitPod.auth.ssh.knownHosts when gitPod.auth.type is ssh" -}}
{{- end -}}
{{- if not (or $ssh.knownHostsKey $ssh.knownHosts) -}}
{{- fail "set exactly one of gitPod.auth.ssh.knownHostsKey and gitPod.auth.ssh.knownHosts when gitPod.auth.type is ssh" -}}
{{- end -}}
{{- if contains "PRIVATE KEY" ($ssh.knownHosts | default "") -}}
{{- fail "gitPod.auth.ssh.knownHosts must hold known_hosts lines, not a private key" -}}
{{- end -}}
{{- else if $auth.existingSecret -}}
{{- fail "gitPod.auth.existingSecret must be empty when gitPod.auth.type is none" -}}
{{- end -}}
{{- $type -}}
{{- end }}

{{/*
Numeric uid and gid of the Git pod for the chart-rendered /etc/passwd entry (auth type ssh only).
The uid is gitPod.securityContext.runAsUser, else podSecurityContext.runAsUser, and must be an
integer from 1 to 2147483647. The gid is runAsGroup from the same two places, else 0 (the primary
group Kubernetes uses when runAsGroup is unset), from 0 to 2147483647.
*/}}
{{- define "oolong.gitSshUid" -}}
{{- $sc := .Values.gitPod.securityContext | default dict -}}
{{- $psc := .Values.podSecurityContext | default dict -}}
{{- $raw := coalesce $sc.runAsUser $psc.runAsUser 0 -}}
{{- $uid := int64 $raw -}}
{{- if or (lt $uid 1) (gt $uid 2147483647) (ne (float64 $uid) (float64 $raw)) -}}
{{- fail "gitPod.securityContext.runAsUser must be set to a non-root integer uid when gitPod.auth.type is ssh" -}}
{{- end -}}
{{- $uid -}}
{{- end }}

{{- define "oolong.gitSshGid" -}}
{{- $sc := .Values.gitPod.securityContext | default dict -}}
{{- $psc := .Values.podSecurityContext | default dict -}}
{{- $raw := coalesce $sc.runAsGroup $psc.runAsGroup 0 -}}
{{- $gid := int64 $raw -}}
{{- if or (lt $gid 0) (gt $gid 2147483647) (ne (float64 $gid) (float64 $raw)) -}}
{{- fail "gitPod.securityContext.runAsGroup must be an integer gid when gitPod.auth.type is ssh" -}}
{{- end -}}
{{- $gid -}}
{{- end }}

{{/*
gitPod.env names the chart sets or relies on. A reserved name fails the render (it used to be
dropped silently) so an operator is never left believing a setting is active.
*/}}
{{- define "oolong.requireGitPodEnvNotReserved" -}}
{{- $exact := list "GIT_REPO_URL" "GIT_BRANCH" "GIT_REPO_HOST_ALLOWLIST" "REVISION_RETENTION_COUNT" "CONTENT_DIR" "SYNC_INTERVAL" "HOME" "GIT_CURL_VERBOSE" "GIT_CONFIG" "GIT_CONFIG_COUNT" "GIT_CONFIG_PARAMETERS" "GIT_CONFIG_GLOBAL" "GIT_CONFIG_SYSTEM" "GIT_CONFIG_NOSYSTEM" "GIT_ASKPASS" "SSH_ASKPASS" "SSH_ASKPASS_REQUIRE" "GIT_TERMINAL_PROMPT" "GIT_ALLOW_PROTOCOL" "GIT_SSL_NO_VERIFY" "GIT_SSH" "GIT_SSH_COMMAND" "GIT_SSH_VARIANT" -}}
{{- $prefixes := list "GIT_TRACE" "GIT_CONFIG_KEY_" "GIT_CONFIG_VALUE_" "OOLONG_GIT_" -}}
{{- range $name, $_ := .Values.gitPod.env -}}
{{- $reserved := has $name $exact -}}
{{- range $prefixes -}}
{{- if hasPrefix . $name -}}
{{- $reserved = true -}}
{{- end -}}
{{- end -}}
{{- if $reserved -}}
{{- fail (printf "gitPod.env.%s is set by the chart and cannot be overridden" $name) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Kubernetes Secret name for pagination HMAC signing.
*/}}
{{- define "oolong.pageTokenSecretName" -}}
{{- if .Values.pageTokenSecret.existingSecret -}}
{{- .Values.pageTokenSecret.existingSecret -}}
{{- else -}}
{{- printf "%s-page-token" (include "oolong.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Fail fast when the chart is not allowed to create a secret and none was named.
*/}}
{{- define "oolong.requirePageTokenSecret" -}}
{{- if not .Values.pageTokenSecret.create -}}
{{- if not .Values.pageTokenSecret.existingSecret -}}
{{- fail "pageTokenSecret.existingSecret is required when pageTokenSecret.create is false" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
This chart's probes and git snapshot loader are not in the published 25.10.6 image.
Fail closed until a compatible image is set explicitly.
*/}}
{{- define "oolong.requireCompatibleImage" -}}
{{- if not .Values.image -}}
{{- fail "image is required. The published 25.10.6 image is incompatible with this chart (/healthz and git snapshot reload). Set --set image=<compatible-image>, for example oolong-server:local." -}}
{{- end -}}
{{- if contains "oolong-server:25.10.6" .Values.image -}}
{{- fail "image 25.10.6 is incompatible with this chart: it does not implement /healthz or git snapshot reload. Set --set image=<compatible-image> built from this branch." -}}
{{- end -}}
{{- end -}}
