# ubi9-images

Container images built on Red Hat Universal Base Image 9: a minimal base, language runtimes, and the
toolsets that build software for them. Each image is published as its own package, for amd64 and
arm64, and runs as user 65532.

## Images

| Image | What it is |
| --- | --- |
| `ghcr.io/nwarila/ubi9-micro` | The minimal base: the C library, CA certificates, time zones and the validated OpenSSL FIPS provider. No shell, no package manager. Go programs run on it. |
| `ghcr.io/nwarila/ubi9-openjdk-17-runtime` | The headless OpenJDK 17 runtime. |
| `ghcr.io/nwarila/ubi9-openjdk-21-runtime` | The headless OpenJDK 21 runtime. |
| `ghcr.io/nwarila/ubi9-openjdk-25-runtime` | The headless OpenJDK 25 runtime. |
| `ghcr.io/nwarila/ubi9-python-312-runtime` | Python 3.12 and its complete standard library. No pip. |
| `ghcr.io/nwarila/ubi9-nodejs-24-runtime` | The Node.js 24 runtime, with English locale data only. No npm. |
| `ghcr.io/nwarila/ubi9-dotnet-10-runtime` | The .NET 10 runtime and the ASP.NET Core shared framework. |
| `ghcr.io/nwarila/ubi9-dotnet-runtime-deps` | The native libraries that self-contained .NET applications need. No .NET runtime. |
| `ghcr.io/nwarila/ubi9-openjdk-17-toolset` | The OpenJDK 17 development kit, a shell and a package manager. |
| `ghcr.io/nwarila/ubi9-openjdk-21-toolset` | The OpenJDK 21 development kit, a shell and a package manager. |
| `ghcr.io/nwarila/ubi9-openjdk-25-toolset` | The OpenJDK 25 development kit, a shell and a package manager. |
| `ghcr.io/nwarila/ubi9-python-312-toolset` | pip, the Python headers, a C compiler, a shell and a package manager. |
| `ghcr.io/nwarila/ubi9-nodejs-24-toolset` | Node.js, npm, a C++ compiler, a shell and a package manager. |
| `ghcr.io/nwarila/ubi9-dotnet-10-toolset` | The .NET 10 SDK, a shell and a package manager. |
| `ghcr.io/nwarila/ubi9-go-toolset` | The Go toolchain, a C compiler, a shell and a package manager. |

A runtime image has no shell, no package manager and no language package tool. A toolset is a build
environment: build in the toolset, then copy the result into the matching runtime.

## Using an image

Two tags are published:

- `latest` moves each time the image changes.
- `sha-<commit>` (the first seven characters of the commit) names the commit an image was published
  from and never moves: a publish that would move it stops instead.

Pin the digest as well, and let a tool such as Renovate keep it current. The digest `latest` names is
the `Digest:` line of `docker buildx imagetools inspect ghcr.io/nwarila/ubi9-python-312-runtime:latest`:

```dockerfile
FROM ghcr.io/nwarila/ubi9-python-312-runtime:latest@sha256:<digest>
```

## Verifying an image

Every image published by a completed publish run carries SLSA build provenance, made by this
repository's workflow `build-test-publish.yaml`. A publish that stops half-way can leave a tag whose
image does not verify until that run is re-run. To check that an image was built here, from this
repository's source (with `gh` signed in, `gh auth login`):

```sh
gh attestation verify oci://ghcr.io/nwarila/ubi9-micro:latest \
  --owner NWarila \
  --signer-workflow NWarila/ubi9-images/.github/workflows/build-test-publish.yaml
```

The same command works for a single architecture's image, by digest:
`oci://ghcr.io/nwarila/ubi9-micro@sha256:<digest>`.

## How the images are built

Each image has a folder under `images/`. It holds the Dockerfile, the list of packages, the lock of exact
package versions for each architecture, the expected image digest for each architecture
(`digests.txt`), and a `test/` folder.

- `build/build-image.sh <image> <architecture>` builds the image from its lock. The build is
  reproducible: the same lock gives the same digest, and the script stops if the digest differs from
  `digests.txt`.
- `build/test-image.sh <image> <architecture>` checks that the image does what its folder promises.
- On a pull request that changes the images, the build scripts or these workflows, CI builds and tests
  every image on native amd64 and arm64 runners. After such a change is merged to `main`, CI does the
  same and then publishes each image whose digest changed; a manual run on `main` does the same.
  Publishes run one at a time, in order. When several merges land close together, each waits its
  turn and the newest one publishes: an older one finds that its commit is no longer the tip of
  `main` and writes nothing. A publish that stops half-way is completed by re-running that workflow
  run, even after newer merges; the re-run waits its turn and never cancels a waiting publish.

## Images from the previous pipeline

The repository was rebuilt from zero on 2026-10-01; the reasons are in
[ADR-0001](docs/decision-records/repo/0001-rebuild-the-image-family-from-zero.md). The previous
pipeline is preserved at the `legacy-final` tag. Its images receive **no further updates** and will be
deleted once nothing depends on them; use the images above instead.

| Image | Last published digest |
| --- | --- |
| `ghcr.io/nwarila/ubi9-base-micro` | `sha256:8af7c28c6280a09d057fa649483ccd33c6fd25dce7863147bfb4dc68f3702eca` |
| `ghcr.io/nwarila/ubi9-base-python` | `sha256:29f17238f22163444b7bd0e7e6d4897de9f09f1ab1f39af78088c6e08d7c3cf1` |
| `ghcr.io/nwarila/ubi9-base-java` | `sha256:89db8a7428874c1204a4beaa8145f36ece7365b361fb4669ff9eb6e77a65a37d` |

## Documentation

- [Decision records](docs/decision-records/) — organization baseline under `org/`, this repository's
  under `repo/`.
- [Security policy](SECURITY.md), [contributing](CONTRIBUTING.md), [support](SUPPORT.md).

## License

[MIT](LICENSE).
