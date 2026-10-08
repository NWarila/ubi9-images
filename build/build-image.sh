#!/usr/bin/env bash
#
# build-image.sh - build one image from its lock, and check the result.
#
# The same command runs on a laptop and in the GitHub workflow; with the
# same builder (see HOW TO RUN IT), both produce the same image.
#
# HOW TO RUN IT
#   From the repository root:
#
#     build/build-image.sh micro              for this machine's architecture
#     build/build-image.sh micro aarch64      for another architecture
#
#   It needs "docker buildx" with a BuildKit builder selected, and jq. The
#   digest depends on the BuildKit version: to reproduce the digests recorded in
#   digests.txt, use the buildx and BuildKit versions that
#   .github/workflows/build-test-publish.yaml pins, for example
#
#     docker buildx create --use --driver docker-container \
#       --driver-opt image=<the moby/buildkit image pinned there>
#
# WHAT IT READS
#   images/<image>/Dockerfile
#   images/<image>/packages.lock.<arch>    the RPM files, and the fixed date
#   images/<image>/digests.txt             the digest these inputs give
#
# WHAT IT WRITES
#   dist/ubi9-<image>.<arch>.tar     the image, as an OCI archive
#   dist/ubi9-<image>.<arch>.json    the build's details, including the digest
#
# WHY THE SAME INPUTS ALWAYS GIVE THE SAME IMAGE
#   The image is made from the lock, the Dockerfile and the files it copies
#   in, by the pinned BuildKit. The lock fixes every RPM file. The only other
#   thing that could differ between two builds is time: the dates on files
#   the build creates, and the image's "created" date. The lock records one
#   date (source-date-epoch) and this script gives it to the build, which
#   uses it in place of the clock.
#
# WHAT IT CHECKS
#   After the build, the new digest must equal the one recorded for this
#   architecture in digests.txt, or the script stops. When the lock, the
#   Dockerfile or a file it copies in changes on purpose, replace the
#   recorded line with the one this script prints.

fail() {
  echo "build-image: $*" >&2
  exit 1
}

case $# in
  1) arch=$(uname -m) || fail 'cannot read the architecture of this machine' ;;
  2) arch=$2 ;;
  *) fail 'usage: build/build-image.sh <image> [x86_64|aarch64]' ;;
esac
image=$1

# An image is a plain folder name under images/: no path, no capitals, and
# not an option such as --help.
[[ $image =~ ^[a-z0-9][a-z0-9-]*$ ]] \
  || fail "image name '$image' must be lower-case letters, digits and" \
          'hyphens, starting with a letter or digit'

# macOS calls the 64-bit Arm architecture arm64; the locks use Linux's name.
case $arch in
  x86_64)          platform=linux/amd64 ;;
  aarch64 | arm64) platform=linux/arm64; arch=aarch64 ;;
  *) fail "unknown architecture '$arch' (expected x86_64 or aarch64)" ;;
esac

dockerfile=images/$image/Dockerfile
lock_file=images/$image/packages.lock.$arch
digests_file=images/$image/digests.txt
archive=dist/ubi9-$image.$arch.tar
metadata_file=dist/ubi9-$image.$arch.json

[[ -f $dockerfile ]] \
  || fail "$dockerfile does not exist; run this from the repository root," \
          'naming a folder under images/'
[[ -f $lock_file ]] \
  || fail "$lock_file does not exist;" \
          'run build/generate-lock.sh for this architecture'

# The fixed date, from the lock's one "# source-date-epoch: N" line.
source_date_epoch=''
date_lines=0
# "|| [[ -n $line ]]" keeps a last line that has no newline after it.
while IFS= read -r line || [[ -n $line ]]; do
  if [[ $line == '# source-date-epoch: '* ]]; then
    source_date_epoch=${line#'# source-date-epoch: '}
    ((date_lines++))
  fi
done < "$lock_file"

((date_lines == 1)) \
  || fail "$lock_file must contain exactly one source-date-epoch line"
[[ $source_date_epoch =~ ^[0-9]+$ ]] \
  || fail "$lock_file source-date-epoch must contain digits only"
command -v jq > /dev/null || fail 'jq is not installed'

mkdir -p dist || fail 'cannot create the dist folder'

# Remove both old outputs, then build in a private directory. A failed or
# interrupted build cannot leave a stale or partial final archive behind.
rm -f "$archive" "$metadata_file" \
  || fail 'cannot remove the old build outputs'
work=$(mktemp -d dist/.build-image.XXXXXX) \
  || fail 'cannot create a working directory under dist'
cleanup() {
  rm -rf -- "$work" || echo "build-image: cannot remove $work" >&2
}
trap cleanup EXIT
archive_in_progress=$work/image.tar
metadata_in_progress=$work/metadata.json

# SOURCE_DATE_EPOCH       the fixed date; buildx hands it to the build as the
#                         build argument of that name, used for the image's
#                         "created" date and by the Dockerfile's install stage
# rewrite-timestamp=true  give that date to every file the build created;
#                         files that came out of an RPM are older and keep
#                         their own date
# --provenance, --sbom    off: they describe this particular run, so they
#                         would differ between two builds of the same lock
# BUILDX_GIT_LABELS=0     no labels naming the commit, even when the caller's
#                         environment asks buildx for them: they would change
#                         the digest with every commit
SOURCE_DATE_EPOCH=$source_date_epoch BUILDX_GIT_LABELS=0 docker buildx build \
  --file "$dockerfile" \
  --platform "$platform" \
  --provenance=false \
  --sbom=false \
  --output "type=oci,dest=$archive_in_progress,rewrite-timestamp=true" \
  --metadata-file "$metadata_in_progress" \
  . \
  || fail "the build of $image for $arch failed"

# Buildx writes result metadata as JSON; read its top-level digest field.
digest=$(jq --exit-status --raw-output \
  '."containerimage.digest" | select(type == "string")' \
  "$metadata_in_progress") \
  || fail "$metadata_file contains no image digest"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] \
  || fail "$metadata_file contains no image digest"

# Rename only after the build and metadata check pass. Because both paths are
# under dist, neither final file can be observed partially written.
mv "$archive_in_progress" "$archive" \
  || fail "cannot replace $archive"
if ! mv "$metadata_in_progress" "$metadata_file"; then
  rm -f -- "$archive" || echo "build-image: cannot remove $archive" >&2
  fail "cannot replace $metadata_file"
fi
rmdir "$work" || fail "cannot remove the working directory $work"
trap - EXIT

echo "Built $archive"
echo "Image digest: $digest"

# Compare with the digest recorded for this architecture: exactly one line
# "<arch> sha256:..." in digests.txt.
[[ -f $digests_file ]] \
  || fail "$digests_file does not exist; create it with this line:" \
          "$arch $digest"
recorded=''
recorded_lines=0
while read -r line_arch line_digest || [[ -n $line_arch ]]; do
  if [[ $line_arch == "$arch" ]]; then
    recorded=$line_digest
    ((recorded_lines++))
  fi
done < "$digests_file"

((recorded_lines == 1)) \
  || fail "$digests_file must contain exactly one $arch line; record" \
          "this line: $arch $digest"
[[ $recorded =~ ^sha256:[0-9a-f]{64}$ ]] \
  || fail "$digests_file: the $arch line is not a digest; record" \
          "this line: $arch $digest"

if [[ $digest != "$recorded" ]]; then
  echo 'build-image: the image differs from the one recorded in' >&2
  echo "  $digests_file" >&2
  echo "  recorded: $arch $recorded" >&2
  echo "  built:    $arch $digest" >&2
  echo '  If the lock, the Dockerfile or a file it copies in changed on' >&2
  echo '  purpose, replace the recorded line with the built one. If not,' >&2
  echo '  check that the builder runs the pinned BuildKit (see the header' >&2
  echo '  of build/build-image.sh).' >&2
  exit 1
fi
echo "Digest matches $digests_file."
