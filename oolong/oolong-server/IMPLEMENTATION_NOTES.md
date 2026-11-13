# TEA Service Implementation

## Overview

Oolong serves the Transparency Exchange API (TEA) **1.0.0** from YAML content on disk. There is no
database. The served contract is pinned: `tea-spec/openapi.yaml` is a byte copy of CycloneDX
transparency-exchange-api commit `962a0228af1bfcc1232ac3f79239317ff33fdb04` (provenance in
`tea-spec/SPEC_PIN.md`; the previous `0.2.0-beta.2` document is kept in `tea-spec/archive/`).

Routes are mounted at `/v1.0.0`. `/.well-known/tea` and `/healthz` stay outside that prefix.

Detailed API behaviour (error bodies, pagination tokens, discovery ordering, download validators) and
the upgrade audit are in [`docs/tea-upgrade/implementation-report.md`](../../docs/tea-upgrade/implementation-report.md)
and the other notes in `docs/tea-upgrade/`. This file describes the code as it is now.

## Code Layout

The mounted application is `src/tea/`. `src/main.ts` calls `createApp()` and listens on `PORT`;
`AppModule` wires these controllers and providers:

| File | Role |
|---|---|
| `create-app.ts` | Builds the Nest app: checks `API_VERSION` and `PAGE_TOKEN_SECRET` at startup, sets the `/v1.0.0` prefix, installs the TEA error filter, serves `HEAD` without a body, disables Express ETags and `X-Powered-By` |
| `tea.controller.ts` | All `/v1.0.0` routes (see [API Surface](#api-surface)) |
| `tea.service.ts` | Request handling over the active content snapshot: lookups, listings, collections, discovery, downloads |
| `content-store.ts` | Loads and validates one content root into in-memory maps (`ContentStore`); the authority on the content format |
| `content-snapshot.ts` | `ContentSnapshotRegistry`: picks the content root (static or a Git revision), reloads new revisions, keeps the last good one |
| `pagination.ts` | Page size limits and HMAC page tokens |
| `representation.ts` | Advertised version (`1.0.0`), `/v1.0.0` prefix, `SERVER_HOST`, response shaping |
| `path-guard.ts` | Keeps every file read inside the content root (`realpath` checks, segment rules) |
| `errors.ts` | `TeaException` and the filter that writes TEA error bodies |
| `well-known.controller.ts` | `GET /.well-known/tea`; `503` until a content snapshot is ready |
| `health.controller.ts` | `GET /healthz`: process liveness only, independent of content |

Not mounted and not imported by the running server: `src/handlers/`, `src/utils/content-loader.ts`,
`src/controllers/well-known.controller.ts` (the pre-1.0 implementation) and `src/generated-nest/`
(the OpenAPI Generator snapshot of the Beta 2 contract; see `docs/tea-upgrade/generator-strategy.md`).

## API Surface

All under `/v1.0.0`:

- **Products:** `GET /products`, `/product/{uuid}`, `/product/{uuid}/releases`
- **Product releases:** `GET /productReleases`, `/productRelease/{uuid}`, `/productRelease/{uuid}/collections`,
  `/productRelease/{uuid}/collection/latest`, `/productRelease/{uuid}/collection/{collectionVersion}`
- **Components:** `GET /components`, `/component/{uuid}`, `/component/{uuid}/releases`
- **Component releases:** `GET /componentReleases`, `/componentRelease/{uuid}`, `/componentRelease/{uuid}/collections`,
  `/componentRelease/{uuid}/collection/latest`, `/componentRelease/{uuid}/collection/{collectionVersion}`
- **Artifacts:** `GET /artifact/{uuid}/latest`, `/artifact/{uuid}/{artifactVersion}`, each with `/download` and
  `/signature/download`. A format with a local `bodyFile` is served from disk; a format with only a `url`
  answers `302` to it.
- **Discovery:** `GET /discovery?tei=...` or `?purl=...` (exactly one). Matches a product release's `TEI` or
  `PURL` identifier exactly. Several matches are ordered by product-release UUID; none is `404 OBJECT_UNKNOWN`.
- **CLE:** `GET /product/{uuid}/cle`, `/productRelease/{uuid}/cle`, `/component/{uuid}/cle`,
  `/componentRelease/{uuid}/cle` return `404 NOT_IMPLEMENTED` for an existing object.

A release response is flat and includes `latestCollection`; a release with no collection files gets a
synthetic version 1 collection in the response only. Authentication is not implemented: `POST /token`
returns `404 NOT_IMPLEMENTED` and `Authorization: Bearer` is ignored.

### Pagination
List operations default to 25 items and reject `pageSize` above 100 (`400 INVALID_REQUEST`). Responses
carry `hasNext` and an opaque `nextPageToken`, an HMAC (keyed by `PAGE_TOKEN_SECRET`) bound to the
operation, parent, filters, sort, page size and position. A malformed or mismatched token is
`400 INVALID_PAGE_TOKEN`.

### Identifier Filtering
Query methods search each object's `identifiers` array:
- `idType` and `idValue` together match one identifier that has both.
- `idType` alone matches an object that has at least one identifier of that type.
- `idValue` alone is rejected. The TEA 1.0 text does not settle that case, so this rejection is Oolong behavior, not a claimed specification requirement.

### Errors
Known operations answer `{ "error", "message"? }` with one of `OBJECT_UNKNOWN`, `NOT_IMPLEMENTED`,
`INVALID_REQUEST`, `INVALID_PAGE_TOKEN`, `NO_ACCEPTABLE_FORMAT` and `SIGNATURE_NOT_FOUND`. UUID path
parameters are validated before lookup.

## Content Format

`ContentStore` reads the TEA 1.0.0 content layout and refuses to load content that breaks it:

```
<content root>/
├── products/<name>/product.yaml
├── products/<name>/releases/<version>/release.yaml
├── products/<name>/releases/<version>/collections/<n>.yaml
├── components/<name>/component.yaml
├── components/<name>/releases/<version>/release.yaml         # distributions
├── components/<name>/releases/<version>/collections/<n>.yaml
└── artifacts/<uuid>/v<n>.yaml                                # one file per artifact revision,
                                                              # plus optional bodyFile / signatureFile
```

- Releases may name their parent (`product:` / `component:`); when present it must match the enclosing
  directory. Every component-release distribution has a `distributionId` (UUID).
- Collections carry `version` (matching the file name), `createdDate`, `belongsTo`
  (`PRODUCT_RELEASE` / `COMPONENT_RELEASE`), `updateReason`, and artifacts as `{uuid, version}`
  references to existing artifact revisions.
- Artifact revisions carry `uuid`, `version`, `type`, `createdDate` and `formats`, each with a
  `mediaType` unique within the revision; a format with a `url` must have `checksums`. Optional
  `distributionIds` link the artifact to distributions.
- UUIDs are lowercase; dates are UTC RFC 3339; URIs must be valid; checksums use the TEA 1.0.0 types
  (no MD5) with the exact lowercase-hex length; identifiers are `CPE`, `TEI`, `PURL` or
  `COMPLIANCE_DOCUMENT` (the last only where TEA allows it). TEIs use `tei://<domain>/<type>/<id>`,
  with a `purl` TEI Base64URL-encoded.
- YAML is parsed with the JSON schema and no aliases; a YAML file is limited to 1,000,000 bytes and an
  artifact body to 32,000,000 bytes. Paths, including symlink targets, that resolve outside the
  content root are ignored or refused; symlinks inside it are followed without looping.

Examples: `fixtures/tea-1.0.0` (the default content root and test fixtures; identifiers in
`docs/tea-upgrade/fixture-reference.md`), `sample_content/`, and the demo catalog in
[oolong-project/oolong-demo-content](https://github.com/oolong-project/oolong-demo-content).
The `rearm oolong` content commands of [ReARM CLI](https://github.com/relizaio/rearm-cli) write this
layout from the release after 26.11.6 (relizaio/rearm-cli#193); 26.11.6 and earlier write the pre-1.0
layout, which this server rejects.

## Content Snapshots and Git Sync

`ContentSnapshotRegistry` decides what is served:

- **Static content:** when `CONTENT_DIR` holds `products/` directly (fixtures, a mounted directory, the
  content baked into the image), it is loaded once at startup as revision `static`.
- **Git-published revisions:** the Helm chart's Git pod clones the content repository, writes each commit
  to `revisions/<40-hex commit>/` and points `.oolong-current-revision` at it. The server polls every
  `CONTENT_RELOAD_INTERVAL_MS` (default 60 s when `CONTENT_GIT_SYNC_ENABLED=true`, otherwise no
  polling), loads and validates the new revision, and only then switches to it and records it in
  `.oolong-active-revision`.
- **Last good revision:** a revision that fails validation is logged
  (`content reload rejected for <commit>: <reason>`) and the previous revision keeps being served. At
  startup the server falls back from the candidate to the last active revision.
- **Readiness:** with `CONTENT_AWAIT_GIT_REVISION=true` and no revision published yet, `/.well-known/tea`
  answers `503` until one loads. `/healthz` reports liveness only. The Helm chart uses
  `/.well-known/tea` for readiness and `/healthz` for liveness; the image's `HEALTHCHECK` runs
  `docker/tea-ready.js`.

The Git pod can clone public repositories over HTTPS and private ones over HTTPS with a token or over
SSH with a deploy key; see the README's Helm section.

## Configuration

### Environment Variables

- **`API_VERSION`** (required value: `1.0.0` or `v1.0.0`) - Advertised TEA version. Routes are mounted at `/v1.0.0`. Any other value stops startup.
  - `/.well-known/tea` stays outside that prefix and lists `1.0.0` without a leading `v`
- **`CONTENT_DIR`** - Filesystem content root. Defaults to `../fixtures/tea-1.0.0` from the server working directory
- **`CONTENT_GIT_SYNC_ENABLED`** - `true` when a Git pod publishes revisions under `CONTENT_DIR`; turns on polling (60 s by default)
- **`CONTENT_RELOAD_INTERVAL_MS`** - Polling interval for new revisions, in milliseconds (positive integer). Set by the Helm chart when the Git pod is enabled
- **`CONTENT_AWAIT_GIT_REVISION`** - `true` to start without content and wait for the first Git revision (`/.well-known/tea` returns `503` until then) instead of loading `CONTENT_DIR` as static content
- **`PAGE_TOKEN_SECRET`** - HMAC key for pagination tokens. Required unless `PAGE_TOKEN_DEV_FALLBACK=true` and `NODE_ENV` is not `production`. The known development key is never used in deployment configurations. The value is never logged.
- **`PAGE_TOKEN_DEV_FALLBACK`** - Set to `true` only for local development and tests. Ignored when `NODE_ENV=production`.
- **`SERVER_HOST`** (default: `http://localhost:3000`) - Public URL for the TEA API
  - Used in the `/.well-known/tea` discovery endpoint and in discovery results
- **`PORT`** (default: `3000`) - Server port

Create a `.env` file based on `.env.example` to customize these values.

### Discovery Endpoint

The server provides a `.well-known/tea` endpoint (without version prefix) for TEA discovery:

```
GET /.well-known/tea
```

Returns:
```json
{
  "schemaVersion": 1,
  "endpoints": [
    {
      "url": "http://localhost:3000",
      "versions": ["1.0.0"],
      "priority": 1
    }
  ]
}
```

The URL is the `SERVER_HOST` value.

## Build and Run

- **Install:** `npm ci`. It works on npm 9, 10 and 11. `package.json` overrides `@nestjs/cli`'s
  pinned webpack to the top-level 5.112.2; `nest build` uses the `tsc` builder, so webpack is not on the
  build path. Lockfile URLs point at `registry.npmjs.org`.
- **Build:** `npm run build`
- **Run locally:**
  ```bash
  PAGE_TOKEN_DEV_FALLBACK=true npm run start:dev                                 # serves ../fixtures/tea-1.0.0
  PAGE_TOKEN_DEV_FALLBACK=true CONTENT_DIR=../sample_content npm run start:dev   # or any content root
  ```
  Then e.g. `GET /.well-known/tea`, `GET /v1.0.0/products`, `GET /v1.0.0/product/{uuid}/releases`.
- **Container:** the Dockerfile (Node 24 on Alpine, runs as an unprivileged user) bakes in
  `fixtures/tea-1.0.0` as `/app/src/content`; mount another directory over it, or use the Git pod, to
  serve your own content.

## Testing

- `npm test` - specs under `src/` (`*.spec.ts`): content loading and validation, release parents,
  symlink traversal, snapshots and reload, pagination, representation, errors, path guard, plus the
  Helm chart rendering and Git pod credential integration specs.
- `npm run test:e2e` - `test/*.e2e-spec.ts`: the TEA operations against the fixtures, distributions,
  content readiness, and the Git live-reload test.
  - `conference-git-live.e2e-spec.ts` runs only when a TEA 1.0.0 catalog is checked out as a real
    directory at `../conferences-oolong-content-2025-11` next to this repository (for example a copy of
    oolong-project/oolong-demo-content). It is skipped otherwise. Do not use a symlink: the test copies
    that path with `fs.cpSync`, which copies a symlink as a symlink, so its `git init` and test identity
    (`review@example.invalid`) would land in the linked repository.
- `test/git-*.integration.sh` - Git pod publication and HTTPS / SSH authentication against local servers.
