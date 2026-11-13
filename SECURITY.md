# Security Policy

## Supported Versions

Security fixes are made on `main` and shipped in the next Oolong release. Only the latest release is supported: the most recent [GitHub release](https://github.com/oolong-project/oolong/releases), the `oolong-server` image it lists, and the matching Helm chart.

## Scope

In scope: the Oolong TEA server (`oolong/oolong-server`), its container image, and the Helm chart (`helm-chart/oolong`), including the Git pod that syncs content.

Out of scope: the content served by an Oolong instance (for example [oolong-project/oolong-demo-content](https://github.com/oolong-project/oolong-demo-content)) and the public demo deployment, unless the issue is caused by Oolong itself.

## Reporting a Vulnerability

Please report security vulnerabilities **privately**, not in public issues, pull requests or discussions.

Use GitHub's private vulnerability reporting: open the repository's [Security tab](https://github.com/oolong-project/oolong/security) and choose **Report a vulnerability** (or go to <https://github.com/oolong-project/oolong/security/advisories/new>). Only the maintainers can see the report.

Please include:

- the affected version, image digest or commit;
- a description of the issue and its impact;
- steps to reproduce, or a proof of concept;
- any suggested fix or mitigation.

The maintainers will acknowledge the report, assess it, and keep you informed in the advisory. Once a fix is released, the advisory is published, crediting you unless you prefer otherwise. Please give us a reasonable time to fix the issue before disclosing it publicly.
