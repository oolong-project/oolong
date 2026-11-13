# Contributing to Oolong <!-- omit in toc -->

Thank you for investing your time in contributing to Oolong!

Read our [Code of Conduct](./CODE_OF_CONDUCT.md) to keep our community approachable and respectable.

This guide gives an overview of the contribution workflow, from opening an issue to getting a pull request merged. Before you open a pull request, please read the [Developer Certificate of Origin](#developer-certificate-of-origin-dco) and [Licensing of contributions](#licensing-of-contributions) sections: submitting a contribution means you agree to those terms.

- [New contributor guide](#new-contributor-guide)
- [Issues](#issues)
- [Making changes](#making-changes)
- [Developer Certificate of Origin (DCO)](#developer-certificate-of-origin-dco)
- [Pull requests](#pull-requests)
- [Licensing of contributions](#licensing-of-contributions)
- [Security issues](#security-issues)

## New contributor guide

To get an overview of the project, read the [README](./README.md). The server's design, content format and tests are described in [IMPLEMENTATION_NOTES.md](./oolong/oolong-server/IMPLEMENTATION_NOTES.md). Some general resources:

- [Finding ways to contribute to open source on GitHub](https://docs.github.com/en/get-started/exploring-projects-on-github/finding-ways-to-contribute-to-open-source-on-github)
- [Set up Git](https://docs.github.com/en/get-started/git-basics/set-up-git)
- [Trunk-Based Development](https://trunkbaseddevelopment.com/)
- [Collaborating with pull requests](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests)

## Issues

### Create a new issue

If you spot a problem with Oolong, first check whether a corresponding issue already exists in [open issues](https://github.com/oolong-project/oolong/issues). If it doesn't, open a new issue.

Please do **not** report security vulnerabilities in public issues; see [Security issues](#security-issues).

### Solve an issue

Scan through the [existing issues](https://github.com/oolong-project/oolong/issues) to find one that interests you. If you find an issue to work on, you are welcome to open a pull request with a fix.

## Making changes

1. [Fork the repository](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/fork-a-repo) so you can make changes without affecting the original project until you're ready to merge them.
2. Create a working branch and make your changes.
3. Run the checks for the part you changed:
   - Server (`oolong/oolong-server`): `npm ci`, `npm run build`, `npm test` and `npm run test:e2e`.
   - Helm chart (`helm-chart/oolong`): `helm lint helm-chart/oolong` and `helm-chart/oolong/scripts/chart-render.integration.sh`.
4. Commit with a sign-off (see below).

## Developer Certificate of Origin (DCO)

Oolong uses the [Developer Certificate of Origin](https://developercertificate.org/) (DCO), the contributor agreement recommended by the OWASP project policy. By signing off a commit, you certify the following:

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

Sign off every commit by adding a `Signed-off-by` line with your real name and email, matching the commit author:

```
Signed-off-by: Jane Doe <jane.doe@example.com>
```

`git commit -s` adds it for you. To add a missing sign-off to the last commit, run `git commit --amend -s`; for several commits, `git rebase --signoff <base>`. Pull requests whose commits are not signed off cannot be merged.

## Pull requests

When you're finished with the changes, open a pull request.

- Enable [allow edits from maintainers](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/allowing-changes-to-a-pull-request-branch-created-from-a-fork) so the branch can be updated for a merge.
- A maintainer will review your proposal and may ask questions, request more information, or ask for changes using [suggested changes](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/incorporating-feedback-in-your-pull-request) or comments.
- As you update your pull request and apply changes, mark each conversation as [resolved](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/commenting-on-a-pull-request#resolving-conversations).
- If you run into merge conflicts, this [tutorial](https://github.com/skills/resolve-merge-conflicts) helps you resolve them.

Once your pull request is merged, your change is included in the next Oolong release. Thank you!

## Licensing of contributions

Oolong is licensed under the [MIT License](./LICENSE). So that the project can keep the option of changing its license in the future, every contribution to this repository is accepted on the following terms, in addition to the DCO.

By submitting a contribution (a pull request, patch, or any other material you intentionally send to us for inclusion in this repository), you agree that:

1. **You have the right to contribute it.** The contribution is your original work, or you otherwise have the right to submit it under these terms, including, where applicable, permission from your employer.
2. **It is licensed to the project and to everyone under the MIT License.** Your contribution is licensed under the [MIT License](./LICENSE) that applies to this repository.
3. **You additionally grant a right to relicense it.** In addition to (2), you grant the Oolong project leaders (currently Pavel Shukhman and Matt Rutkowski, and their successors as project leaders) and Reliza Incorporated a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, reproduce, modify, distribute, sublicense and otherwise exploit your contribution, with or without modification, **under any license terms**, for example under a different open-source license should the project's license change.
4. **You keep your copyright.** Nothing here assigns your copyright to anyone. You can use your own contribution for anything else you like.
5. **No warranty.** Unless required by law or agreed in writing, you provide your contribution "as is", without warranties of any kind.

If you cannot agree to these terms, for instance because your employer's policy does not allow it, please say so in the pull request before we spend time on review, and we will work out what is possible.

These terms apply to contributions submitted after they were added to this file; they do not change the terms of anything contributed earlier.

## Security issues

Do not open a public issue for a security vulnerability. Report it privately as described in [SECURITY.md](./SECURITY.md).
