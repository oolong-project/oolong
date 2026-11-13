![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)

# Oolong - lightweight TEA server implementation

This project is a lightweight implementation of [Transparency Exchange API](https://github.com/CycloneDX/transparency-exchange-api/).

Oolong was originally developed by [Reliza](https://reliza.io), a contributor to the Transparency Exchange API specification.

## Live Demo
Live demo server is currently operating at https://oolong.demo.rearmhq.com.

I.e., you can access well-known at [https://oolong.demo.rearmhq.com/.well-known/tea](https://oolong.demo.rearmhq.com/.well-known/tea).

Also you can download [ReARM CLI](https://github.com/relizaio/rearm-cli) and try out full flow with TEI tei://oolong.demo.rearmhq.com/asin/B09D6HR559

using 

```bash
rearm tea full_tea_flow --debug true --tei tei://oolong.demo.rearmhq.com/asin/B09D6HR559
```

## Sample Data
Additional sample data, in the TEA 1.0.0 content layout, can be found in the [oolong-project/oolong-demo-content](https://github.com/oolong-project/oolong-demo-content) repository. It carries the catalogs first shown in [Reliza-Demos/conferences-oolong-content-2025-11](https://github.com/Reliza-Demos/conferences-oolong-content-2025-11).

TEIs with full ReARM CLI commands (26.11.6 or later, the TEA 1.0.0 client) that can be used against it. A `purl` TEI carries the Package URL Base64URL-encoded without padding, as TEA 1.0.0 requires; the decoded PURL is shown in the comment:

#### Kauf Bulb Demo:
```bash
rearm tea full_tea_flow --debug true --tei tei://oolong.demo.rearmhq.com/uuid/9485fbc9-aa7d-4c26-95c9-d5a8ccb1c073
rearm tea full_tea_flow --debug true --tei tei://oolong.demo.rearmhq.com/asin/B09D6HR559
```

As shown on OWASP 2025 Global AppSec USA.

#### Apache Log4j Demo:
```bash
# pkg:maven/org.apache.logging.log4j/log4j-core@2.25.0
rearm tea full_tea_flow --debug true --tei tei://oolong.demo.rearmhq.com/purl/cGtnOm1hdmVuL29yZy5hcGFjaGUubG9nZ2luZy5sb2c0ai9sb2c0ai1jb3JlQDIuMjUuMA
rearm tea full_tea_flow --debug true --tei tei://oolong.demo.rearmhq.com/uuid/ff08fa6a-1df9-4ab7-b3ec-e02837845a06
# pkg:github/apache/logging-log4j2
rearm tea full_tea_flow --debug true --tei tei://oolong.demo.rearmhq.com/purl/cGtnOmdpdGh1Yi9hcGFjaGUvbG9nZ2luZy1sb2c0ajI
```

As shown on Open Source SecCon 2025 in Atlanta - video available at [https://www.youtube.com/watch?v=na30ADqKH0c](https://www.youtube.com/watch?v=na30ADqKH0c).
Slides available [here](https://www.slideshare.net/slideshow/open-source-security-con2025-in-atlanta-transparency-exchange-api-where-to-find-product-sbom/284093812).

## Content Management

We provided  `oolong/sample_content/` directory for development and testing purposes. 

Oolong serves the TEA content found under `CONTENT_DIR`. When running via npm from `oolong/oolong-server/` without `CONTENT_DIR`, it serves the test fixtures in `oolong/fixtures/tea-1.0.0/`; set `CONTENT_DIR=../sample_content` (or any other content directory) to serve something else.

The provided Dockerfile bakes the content of `oolong/fixtures/tea-1.0.0/` into the container image at `/app/src/content`. To serve your own content from the image, mount it over that path.

Alternatively, you can mount the content with docker-compose or using git pod in the helm chart installation. If using git pod option, the content will be synchronized with the git repository at the specified interval.

For content management, you may use and text editor, IDE, AI agents or [ReARM CLI](https://github.com/relizaio/rearm-cli). For the later case, see documentation for oolong content management commands [here](https://github.com/relizaio/rearm-cli/blob/main/docs/oolong.md).

## Build Container Image

```bash
cd oolong
docker build -t oolong-local .
```

## Run Container Image

The following command shows how to run the container image with a custom content directory and environment variables.

```bash
docker run -p 127.0.0.1:3000:3000 \
  -v /path/to/content:/app/src/content:ro \
  -e API_VERSION=v1.0.0 \
  -e CONTENT_DIR=/app/src/content \
  -e SERVER_HOST=https://myserver.com/tea \
  -e PAGE_TOKEN_SECRET="$(openssl rand -base64 48)" \
  oolong-local
```

It is possible to mount the content directory to the container and use it as a volume. This way, you can update the content directory and the container will use the updated content.

## Run with Docker Compose

### Production-style Compose (local image)

Builds the production image (`NODE_ENV=production`), mounts `fixtures/tea-1.0.0`, and requires `PAGE_TOKEN_SECRET`:

```bash
cd oolong
cp .env.example .env   # edit PAGE_TOKEN_SECRET
docker compose up -d --build
```

The server listens on `http://127.0.0.1:3005`.

### Development Mode

Build and run with `NODE_ENV=development` and the explicit pagination-key opt-in (`PAGE_TOKEN_DEV_FALLBACK=true`). That fallback is disabled whenever `NODE_ENV=production`.

```bash
docker-compose -f docker-compose.dev.yml up -d --build
```

`docker-compose.tea-interop.yml` is the pinned-spec interop profile: same fixtures, `TEA_SPEC_COMMIT=962a0228af1bfcc1232ac3f79239317ff33fdb04`, and a fixed local `PAGE_TOKEN_SECRET` for CI-style checks.


## Installation via helm chart

The server requires `PAGE_TOKEN_SECRET` unless `PAGE_TOKEN_DEV_FALLBACK=true` and `NODE_ENV` is not `production`. The chart always supplies the Secret and never sets the development fallback. Alternatively, create a Secret yourself and set `pageTokenSecret.create=false` and `pageTokenSecret.existingSecret`.

The TEA API is unauthenticated by design and is intended for a public catalog. Anyone who can reach the Service can read the mounted content. For private content, require authentication at the ingress and do not expose the ClusterIP Service (or pod port) without that control. Artifact download endpoints issue `302 Location` for publisher `http`/`https` URLs stored in the catalog; the server does not fetch those URLs (not server-side SSRF). Other URI schemes remain valid on the TEA object but are not used as redirect targets.

With an empty PVC, mount content via git pod or populate the volume; otherwise git mode stays unready until the first valid revision is published.

### Using local chart (development mode)

Local image on kind (after `kind load docker-image oolong-server:local`):

```bash
helm upgrade --install --create-namespace -n oolong oolong helm-chart/oolong \
  --set image=oolong-server:local \
  --set persistence.enabled=false \
  --set env.SERVER_HOST='http://127.0.0.1:3000'
```

Bring your own Secret:

```bash
kubectl create namespace oolong
kubectl create secret generic oolong-page-token -n oolong \
  --from-literal=PAGE_TOKEN_SECRET="$(openssl rand -base64 48)"
helm upgrade --install -n oolong oolong helm-chart/oolong \
  --set image=oolong-server:local \
  --set pageTokenSecret.create=false \
  --set pageTokenSecret.existingSecret=oolong-page-token
```

Sample installation on k3d:

```bash
helm upgrade --install --create-namespace -n oolong oolong helm-chart/oolong \
    --set image=oolong-server:local \
    --set useTraefikDevelopment=true \
    --set env.SERVER_HOST='http://oolong.localhost:8003'
```

### Using official chart from registry

You may use official chart from the registry, `registry.rearmhq.com/library/oolong`.

### Git Pod Configuration

Enable automatic Git synchronization to populate content from a Git repository over HTTPS (public, or private with a token) or SSH (private, with a deploy key); see Private repositories. The Git pod uses `Recreate` and a `flock` on the shared volume so an upgrade does not run two publishers against the same checkout. The lock is held by the publishing process and is released when that process exits. It rolls when the rendered Git ConfigMap changes (`checksum/git-script`). The server keeps serving its accepted snapshot while the Git pod restarts.

`gitPod.repoUrl` is `https://` with no userinfo, or with `gitPod.auth.type=ssh` an `ssh://[user@]host[:port]/path` or `[user@]host:path` URL. The Git pod always disables `git://`, `http://`, `file://` and `ext::`, and disables `ssh` unless the type is `ssh`. Optional `gitPod.allowedHosts` is an exact hostname allowlist for both URL kinds (for an ssh URL, the host after `user@` and before `:port` or `:path`); it is checked when the chart renders and again when the pod starts. Hostname checks do not follow DNS changes or Git redirects; apply a NetworkPolicy or cluster egress control so the Git pod cannot reach internal or metadata destinations.

`gitPod.revisionRetentionCount` is an integer from 1 to 1000 (`values.schema.json`). Helm passes it as the `REVISION_RETENTION_COUNT` environment variable. The Git script validates the value and never interpolates Helm values into shell text.

#### Private repositories

There are two ways to sync a private repository; pick one with `gitPod.auth.type`.

##### HTTPS token

To sync over HTTPS, create a Secret in the release namespace with the user name and the token as two keys, from files or a secret manager, not from a literal on the command line (a literal lands in your shell history):

```bash
kubectl -n oolong create secret generic oolong-git-auth \
  --from-file=username=./username --from-file=token=./token
```

Then set `gitPod.auth.type=token` and `gitPod.auth.existingSecret=oolong-git-auth` (and `gitPod.auth.token.usernameKey` / `tokenKey` if your keys are named differently). Each value must be a single line. The chart never creates this Secret, so the token is never in a values file or in the Helm release record.

Which user name goes with the token, per provider. Scope the token to read-only access on the one repository:

- GitHub fine-grained personal access token: the account's user name; token with read-only Contents permission on the one repository.
- GitLab deploy token: the username GitLab generates with it; scope `read_repository`.
- Bitbucket app password: the Bitbucket user name; repository read permission.

The Secret is mounted as files in `/etc/oolong-git-auth` and read by a credential helper that git runs only for the host of `gitPod.repoUrl`. The token is never in the URL, a command line, an environment variable, `.git/config` or a published revision. A rotated Secret is picked up on a later sync without a restart (kubelet refreshes the mount, typically within about a minute). The files are readable through the pod's `fsGroup`; if you remove `podSecurityContext.fsGroup`, the Git pod fails at start-up and names the unreadable file.

##### SSH deploy key

Create a read-only deploy key for the one repository, without a passphrase (GitHub and GitLab deploy keys are read-only by default; Bitbucket access keys are read-only). Put the private key and the host's `known_hosts` lines in a Secret from files:

```bash
kubectl -n oolong create secret generic oolong-git-ssh \
  --from-file=ssh-privatekey=./deploy_key --from-file=known_hosts=./known_hosts
```

Then set `gitPod.auth.type=ssh`, `gitPod.auth.existingSecret=oolong-git-ssh` and exactly one known_hosts source: `gitPod.auth.ssh.knownHostsKey=known_hosts` (a key in that Secret) or `--set-file gitPod.auth.ssh.knownHosts=./known_hosts` (inline, public data). The chart never creates the Secret, and the render fails without a known_hosts source. Use `ssh://[user@]host[:port]/path` (needed for a non-standard port) or `[user@]host:path` for `gitPod.repoUrl`; the user is usually `git`.

Get the known_hosts lines from the provider's published host keys, or from `ssh-keyscan` only after you compare the `ssh-keygen -lf` fingerprints with the provider's published ones. Host keys are always verified (`StrictHostKeyChecking=yes` against your known_hosts only); ssh never adds a key, and the deploy key is never offered to a host whose key does not match.

The key is copied into an in-memory volume with mode 0600 before every sync, so a rotated Secret is used on a later sync without a restart. The pod never offers an agent or default identity, and no prompt can block a sync. The Git pod needs egress to the SSH port of the host. The chart also mounts a two-line `/etc/passwd` for the Git pod's uid, because ssh refuses to run for a uid with no passwd entry. Only a passwordless URL is accepted: `user:secret@` is refused.

Two render-time refusals protect against leaks. For `none` and `token`, a `gitPod.repoUrl` that contains `@` fails the render, so a token is never written into the URL; with `ssh` a user name is allowed and a password-shaped `user:secret@` is refused. `gitPod.env` names that the chart sets or that would override or expose the credential wiring (`GIT_CONFIG_COUNT`, `GIT_ASKPASS`, `GIT_TRACE*`, `GIT_SSL_NO_VERIFY`, `GIT_ALLOW_PROTOCOL`, `GIT_SSH`, `GIT_SSH_COMMAND`, `GIT_SSH_VARIANT` and others) now fail the render with the name; before, seven of them were dropped silently.

Server pods are labeled `app.kubernetes.io/component=server` and Git pods `app.kubernetes.io/component=git`, so `kubectl logs deploy/<release>` no longer selects both. Those Deployment selectors are immutable: if an upgrade from an older chart fails, delete the two Deployments (keep the PVC) and run `helm upgrade` again.

```bash
helm upgrade --install --create-namespace -n oolong oolong helm-chart/oolong \
  --set image=oolong-server:local \
  --set gitPod.enabled=true \
  --set gitPod.repoUrl='https://github.com/your-org/your-repo.git' \
  --set gitPod.branch='main' \
  --set gitPod.syncInterval='60'
```

**Configuration options:**
- `gitPod.enabled` - Enable/disable Git pod (default: `false`)
- `gitPod.repoUrl` - `https://` Git URL without credentials, or with `gitPod.auth.type=ssh` an `ssh://[user@]host[:port]/path` or `[user@]host:path` URL (required when enabled)
- `gitPod.auth.type` - `none` (anonymous clone, default), `token` or `ssh` (see Private repositories)
- `gitPod.auth.existingSecret` - Name of an existing Secret holding the user name and token (required for `token` and `ssh`, empty for `none`)
- `gitPod.auth.token.usernameKey` - Key in that Secret holding the user name (default: `username`)
- `gitPod.auth.token.tokenKey` - Key in that Secret holding the token (default: `token`)
- `gitPod.auth.ssh.privateKeyKey` - Key in that Secret holding the unencrypted private key (default: `ssh-privatekey`)
- `gitPod.auth.ssh.knownHostsKey` / `gitPod.auth.ssh.knownHosts` - Where the known_hosts lines come from: a key in that Secret, or inline; exactly one is required for `ssh`
- `gitPod.allowedHosts` - Optional exact hostname allowlist (default: empty)
- `gitPod.branch` - Git branch to sync (default: `main`)
- `gitPod.syncInterval` - Sync interval in seconds (default: `60`)
- `gitPod.revisionRetentionCount` - Revisions to keep (1-1000, default: `5`)
- `gitPod.mountPath` - Mount path for content (default: `/content`)

The Git pod treats `/_work` as a disposable checkout: it fetches `gitPod.branch`, checks out that exact commit, copies it into `/content/revisions/<sha>/`, and atomically updates `/content/.oolong-current-revision`. The server polls automatically when git sync is enabled. Invalid revisions are rejected and the previous snapshot keeps serving.

A TEA 1.0.0 conversion of the conference demo catalog lives in the sibling
`conferences-oolong-content-2025-11` clone
([Reliza-Demos/conferences-oolong-content-2025-11](https://github.com/Reliza-Demos/conferences-oolong-content-2025-11)).
After that conversion is pushed, set `gitPod.repoUrl` to that repository. The
`conference-git-live` end-to-end test publishes a local clone of that tree,
renames Kauf Bulb, and checks that `/v1.0.0/products` returns the new name.


## Generation from TEA OpenAPI Specification

The running API is the handwritten server in `oolong/oolong-server/src/tea`. `src/generated-nest` remains the Beta 2 snapshot and is not mounted.

OpenAPI Generator CLI 7.16.0 can emit models for the pinned 1.0.0 document, and its download controllers do not preserve binary responses or the `If-None-Match` header. Do not regenerate into `src/generated-nest`. The trial is recorded in `docs/tea-upgrade/generator-strategy.md`.

## Run Locally for Development

```bash
cd oolong/oolong-server
npm ci --ignore-scripts
npm run start:dev
```

The server reads `CONTENT_DIR`, or `../fixtures/tea-1.0.0` when that variable is unset. `API_VERSION` must be `1.0.0` or `v1.0.0`.

## More Documentation
Refer to [IMPLEMENTATION_NOTES.md](oolong/oolong-server/IMPLEMENTATION_NOTES.md) for more details.

## Project Leaders

- Pavel Shukhman ([@taleodor](https://github.com/taleodor))
- Matt Rutkowski ([@mrutkows](https://github.com/mrutkows))

## Contributors
- Rhythm Garg ([@logicflakes](https://github.com/logicflakes))
- Mehrnoush Vaseghipanah ([@Mehrn0ush](https://github.com/Mehrn0ush))

## Supporters

Reliza supports Oolong development with engineering time from its [ReARM](https://github.com/relizaio/rearm) team, and currently hosts the public demo instance and container registry.
