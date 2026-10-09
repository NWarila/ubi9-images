# Decision records

The decisions behind this repository, in the three scopes that
[org ADR-0001](org/0001-use-architecture-decision-records.md) sets:

- `org/`: the organization's decision records, copied from `NWarila/.github`.
  `.github/workflows/workflow-containers.yaml` checks that the copies stay
  byte-identical.
- `template/`: decision records inherited from a type-template.
- `repo/`: decisions about this repository only.

Each row gives the record's title and status and, as its summary, the option
the record chose. All three are taken from the record itself.

## Org decision records

| Record | Title | Status | Summary |
| --- | --- | --- | --- |
| [org/0001](org/0001-use-architecture-decision-records.md) | Use Architecture Decision Records to Document Design Rationale | Accepted | A MADR 4.0-aligned Markdown template with small portfolio-specific extensions. |
| [org/0002](org/0002-adopt-diataxis-documentation-framework.md) | Adopt Diátaxis as the Documentation Framework | Accepted | Diátaxis. |
| [org/0003](org/0003-use-deny-all-gitignore-strategy.md) | Use a Deny-All `.gitignore` Strategy | Accepted | Deny-all with an explicit allowlist. |
| [org/0004](org/0004-use-renovate-for-dependency-updates.md) | Use Renovate for Dependency Updates with Per-Template Baselines | Accepted | Renovate with self-contained type-template baselines. |
| [org/0005](org/0005-pin-terraform-and-provider-versions-exactly.md) | Pin Terraform and Provider Versions Exactly | Accepted | Exact pins for both Terraform and providers. |
| [org/0006](org/0006-keep-github-control-planes-namespace-local.md) | Keep GitHub Control Planes Namespace-Local | Accepted | Keep org control planes namespace-local while allowing explicit type-template and tool dependencies. |
| [org/0007](org/0007-centralize-universal-ci-reusables-within-each-namespace.md) | Centralize Universal CI Reusables Within Each Namespace | Accepted | Centralize universal reusable workflows once per namespace and keep stack-specific reusable workflows in type templates. |
| [org/0008](org/0008-enforce-repo-hygiene-by-repo-type.md) | Enforce Repo Hygiene by Repo Type | Accepted | Select the enforcement mechanism by repository type while keeping the policy itself uniform. |
| [org/0009](org/0009-classify-baseline-manifest-byte-identity.md) | Classify Baseline Manifest Byte Identity | Accepted | Use byte identity only for files that are uniform governance, and classify everything else by how it is actually used. |

## Template decision records

None. This repository derives from no type-template (see
[repo ADR-0002](repo/0002-keep-the-renovate-configuration-self-contained.md)),
so `template/` holds only `.gitkeep`.

## Repo decision records

| Record | Title | Status | Summary |
| --- | --- | --- | --- |
| [repo/0001](repo/0001-rebuild-the-image-family-from-zero.md) | Rebuild the Image Family From Zero | Accepted | Remove the existing pipeline from `main` and rebuild from an empty tree. |
| [repo/0002](repo/0002-keep-the-renovate-configuration-self-contained.md) | Keep the Renovate Configuration Self-Contained | Accepted | A self-contained configuration on Renovate's built-in presets. |
