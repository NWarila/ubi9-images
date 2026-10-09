# ADR-0002: Keep the Renovate Configuration Self-Contained

| Field            | Value                                                                              |
| ---------------- | ---------------------------------------------------------------------------------- |
| ID               | ADR-0002                                                                           |
| Scope            | Repo                                                                               |
| Status           | Accepted                                                                           |
| Decision-subject | Where the Renovate settings come from, in a repository with no type-template.      |
| Date accepted    | 2026-10-09                                                                         |
| Date             | 2026-10-09                                                                         |
| Last reviewed    | 2026-10-09                                                                         |
| Authors          | Nick Warila (@NWarila)                                                             |
| Decision-makers  | Nick Warila (sole portfolio maintainer)                                            |
| Consulted        | Renovate 44.134.1 presets and defaults; two independent reviews of the old file.   |
| Informed         | Maintainers of this repository.                                                    |
| Reversibility    | High                                                                               |
| Review-by        | 2027-10-09                                                                         |

## TL;DR

This repository derives from no type-template, so it cannot extend one as
[ADR-0004](../org/0004-use-renovate-for-dependency-updates.md) requires. `.github/renovate.json5`
holds the whole policy itself and extends only Renovate's built-in `config:best-practices` preset. It
keeps ADR-0004's controls: a weekly Monday schedule, a seven-day minimum release age with strict
timestamp handling, digest pins for actions and images, and `ci(deps)` titles for workflow updates.

## Context and Problem Statement

ADR-0004 has each repository extend its type-template's Renovate baseline, and forbids extending a
shared organization baseline (Confirmation 6). A repository with no template lineage "MUST document its
exception in a repo-specific superseding ADR" (Confirmation 2). This repository builds a family of
container images, and no type-template covers that stack.

Until this record, `.github/renovate.json5` extended `github>NWarila/.github`, which loads that
repository's `default.json`, unpinned. That preset was written for another design: none of its six
custom managers matched a file here, it set no schedule and no minimum release age, its limit of four
open pull requests held the builder update back, and it did not see the BuildKit image or the build
matrix's runner labels.

## Decision Drivers

1. ADR-0004 compliance: inherit a type-template's baseline, or record the exception.
2. The supply-chain controls ADR-0004 sets: a weekly cadence, a seven-day wait, strict timestamps and
   digest pins.
3. Coverage of the pins that decide an image's bytes: buildx with BuildKit, and the builder image.
4. No other repository changes how this one is updated without a pull request here.

## Considered Options

1. Keep extending `github>NWarila/.github`.
2. Extend a type-template's baseline.
3. A self-contained configuration on Renovate's built-in presets.

## Decision Outcome

Chosen option: **Option 3, a self-contained configuration on Renovate's built-in presets.**

`.github/renovate.json5` extends only `config:best-practices` and sets, itself:

- `schedule: ["before 6am on monday"]`, `semanticCommits: "enabled"`, and the commit type `ci` for
  updates to workflow files;
- `minimumReleaseAge: "7 days"`, `minimumReleaseAgeBehaviour: "timestamp-required"` and
  `internalChecksFilter: "strict"`;
- custom managers for the BuildKit image and the build matrix's runner labels, with buildx and BuildKit
  in one pull request and every runner label in another;
- `minimumReleaseAge: null` for the two kinds of pin that have no release date: GitHub runner labels,
  and the builder image, which is pinned by digest alone. With a required timestamp, a wait would hold
  their updates forever.

It does not set `prConcurrentLimit`, so Renovate's default of 10 applies rather than ADR-0004's 5: a
lower limit held the builder update behind updates to workflow pins.

## Pros and Cons of the Options

### Option 1: Keep extending `github>NWarila/.github`

- Bad, because ADR-0004 Confirmation 6 forbids it.
- Bad, because the preset targets another design, is unpinned, and leaves out the build tools and the
  release-age wait.

### Option 2: Extend a type-template's baseline

- Good, because it is ADR-0004's default pattern.
- Bad, because no type-template covers a container image family; one would be created for a single
  repository.

### Option 3: A self-contained configuration (chosen)

- Good, because the whole policy is in one reviewed file, and only Renovate's own presets are inherited.
- Bad, because a change to ADR-0004's baseline settings must be copied here by hand.

## Confirmation

- `.github/renovate.json5` has exactly one `extends` entry, `config:best-practices`, and no `github>`
  preset.
- `renovate-config-validator --strict` from Renovate 44.134.1 accepts it.
- `minimumReleaseAge: null` appears only in the rules for the `github-runners` datasource and for
  `registry.access.redhat.com/ubi9/ubi-minimal`.

## Consequences

### Positive

- No other repository can change how this one is updated.
- buildx and BuildKit move together, and every job moves to a new runner together.

### Negative

- ADR-0004's settings are copied here, not inherited.
- Runner and builder updates are proposed without the seven-day wait.

### Neutral

- If a type-template for container images is created, this record is revisited.

## Assumptions

- Renovate's built-in presets stay available to the Renovate GitHub App.
- Renovate still has no release date for a GitHub runner label or for an image pinned by digest alone.

## Supersedes

[ADR-0004](../org/0004-use-renovate-for-dependency-updates.md), for this repository only: its
inheritance rule (Decision Outcome and Confirmation 2), its `prConcurrentLimit: 5`, and Confirmation 8's
minimum release age for the two kinds of pin named above.

## Superseded by

None (current).

## Implementing PRs

None. The pull request that adds this record also rewrites `.github/renovate.json5`.

## Related ADRs

- [ADR-0004](../org/0004-use-renovate-for-dependency-updates.md): the organization's Renovate decision
  this record makes an exception to.
- [ADR-0001](0001-rebuild-the-image-family-from-zero.md): the rebuild this configuration serves.

## Compliance Notes

None beyond ADR-0004's.

## Changelog

| Date       | Change   | Reason                                                                | Author/Role          | Body-diff? |
| ---------- | -------- | --------------------------------------------------------------------- | -------------------- | ---------- |
| 2026-10-09 | Created. | The previous configuration extended a shared preset ADR-0004 forbids. | Portfolio maintainer | Yes        |
