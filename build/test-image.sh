#!/usr/bin/env bash
#
# test-image.sh - prove that a built image does what its folder promises.
#
# Usage, from the repository root, after build/build-image.sh has built it:
#   build/test-image.sh <image> [architecture]
#
# The architecture defaults to this machine's. It needs podman, curl, tar
# and network access: github.com for the HTTPS checks, Red Hat's registry
# and content servers for micro's helper image and for a toolset's partner
# build (build/build-image.sh, which also needs Docker Buildx), and
# nuget.org for the .NET toolset. Where /tmp is mounted noexec, set TMPDIR
# to a folder that allows running programs.
#
# What it does
#   1. loads dist/ubi9-<image>.<architecture>.tar into podman, under a name
#      unique to this run
#   2. checks what every image promises: it runs as user 65532, and a
#      runtime (any image not named *-toolset) has no shell, no package
#      manager and no language package tool
#   3. runs images/<image>/test/test.sh, which checks what is particular
#      to that image; a toolset's test also builds the runtime its
#      application runs on, with build/build-image.sh
#   4. removes the containers it started and the image names it added, and
#      deletes only the images podman did not have before this run; if any
#      of that fails, the run does not pass
#
# Every check prints "PASS <what>" or "FAIL <what>". The script exits 0 only
# when every check passed, the image test ran to its last line and the
# cleanup succeeded; 1 when a check failed; 2 when the checks could not be
# run, a test stopped early or the cleanup failed. A run stopped by a signal
# (a cancelled CI job) cleans up what it has recorded, then ends with that
# signal; a container or image made in the moment before it is recorded can
# be left behind.

fail_setup() {
  echo "test-image: $*" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# What the image tests may use. test.sh is read by this script, so these
# functions and variables are available to it.
#
#   $image $arch $platform $image_ref $test_dir
#   $work        a fresh writable folder, deleted at the end
#   $test_files  a copy of the test folder that any user can read; mount
#                this into a container (images run as user 65532)
#   $files       every path in the image, one per line (usr/bin/bash)
#   $output      what the last capture or run_in printed
#   $run_names   the prefix for image names this run adds:
#                localhost/test-<run>, unique to this run
#
#   pass <what> / fail <what>           record a result directly
#   check <what> <command...>           PASS when the command succeeds
#   check_refused <what> <error text> <command...>
#                                       PASS when the command fails AND
#                                       prints <error text>: a refusal is
#                                       observed, not assumed
#   capture <command...>                run it and keep its output in
#                                       $output; when it exits non-zero,
#                                       that is a FAIL, its status is
#                                       returned, and every expect on that
#                                       output fails too
#   podman_run <options> <image ref> <arguments...>
#                                       podman run on this platform, with
#                                       the container removed afterwards
#   run_in <image ref> <arguments...>   capture a podman_run of the image,
#                                       with the test copy at /test
#   expect <what> <text>                PASS when $output contains <text>
#   expect_line <what> <line>           PASS when $output has that whole line
#   has_file <path>                     true when the image holds that file
#   has_file_matching <regex>           true when a file path matches
#   image_env <image ref>               the image's NAME=value settings
#   start_container <options> <image ref> <arguments...>
#                                       start a detached container on this
#                                       platform; its id is left in
#                                       $container_id, and it is removed at
#                                       the end
#   build_image <name> <podman build arguments...>
#                                       build a throwaway image for this
#                                       test, named $run_names/<name>; its
#                                       reference is left in $built_ref
#   build_partner <image>               build, digest-check and load another
#                                       image of this family; its reference
#                                       is left in $partner_ref
#   end_of_test                         the last line of every test.sh
#
# Call build_image, build_partner and start_container directly, never inside
# $( ): they record what to clean up. A container gets --timeout so a hung
# network call cannot hold the job. Volume mounts carry :z, which relabels
# them where SELinux is enforcing.
# ---------------------------------------------------------------------------
readonly container_timeout=300
passed=0
failed=0
output=''
output_ok=0
files=''
partner_ref=''
built_ref=''
container_id=''
work=''
test_finished=0
runner_finished=0
cleanup_failed=0
started_containers=()
names_added=()
images_added=()

pass() {
  echo "PASS  $*"
  passed=$((passed + 1))
  return 0
}

fail() {
  echo "FAIL  $*"
  failed=$((failed + 1))
  return 0
}

# A failure shows the last lines the command printed.
show_tail() {
  tail -n 15 <<< "$1" | sed 's/^/        /'
  return 0
}

check() {
  local what=$1 printed
  shift
  if printed=$("$@" 2>&1); then
    pass "$what"
  else
    fail "$what"
    show_tail "$printed"
  fi
}

check_refused() {
  local what=$1 refusal=$2 printed
  shift 2
  if printed=$("$@" 2>&1); then
    fail "$what (the command succeeded)"
    show_tail "$printed"
  elif [[ $printed == *"$refusal"* ]]; then
    pass "$what"
  else
    fail "$what (it failed, but not with: $refusal)"
    show_tail "$printed"
  fi
}

capture() {
  local status
  output=$("$@" 2>&1)
  status=$?
  if (( status == 0 )); then
    output_ok=1
  else
    output_ok=0
    fail "$* (exited with status $status)"
    show_tail "$output"
  fi
  return "$status"
}

podman_run() {
  podman run --rm --timeout "$container_timeout" --platform "$platform" "$@"
}

run_in() {
  local ref=$1
  shift
  capture podman_run --volume "$test_files:/test:ro,z" "$ref" "$@"
}

expect() {
  if (( output_ok == 0 )); then
    fail "$1 (the command that printed the output failed)"
  elif [[ $output == *"$2"* ]]; then
    pass "$1"
  else
    fail "$1 (expected to see: $2)"
    show_tail "$output"
  fi
}

expect_line() {
  if (( output_ok == 0 )); then
    fail "$1 (the command that printed the output failed)"
  elif grep --quiet --line-regexp --fixed-strings -- "$2" <<< "$output"; then
    pass "$1"
  else
    fail "$1 (expected the line: $2)"
    show_tail "$output"
  fi
}

has_file() {
  grep --quiet --line-regexp --fixed-strings -- "$1" <<< "$files"
}

has_file_matching() {
  grep --quiet --extended-regexp -- "$1" <<< "$files"
}

image_env() {
  podman image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "$1"
}

start_container() {
  container_id=$(podman run --detach --timeout "$container_timeout" \
    --platform "$platform" "$@") \
    || fail_setup "cannot start a container: $*"
  started_containers+=("$container_id")
}

# ---------------------------------------------------------------------------
# Images. Every image this run uses gets a name under $run_names, and an
# existing name is never moved. An image podman already had (a pulled copy
# of a byte-identical build, say) keeps its other names and is not deleted.
# ---------------------------------------------------------------------------

# known_images: the ID of every image podman has now.
known_images() {
  podman images --all --quiet --no-trunc
}

# note_if_new <id> <ids before>: remember an image to delete at the end,
# only when podman did not have it before.
note_if_new() {
  if ! grep --quiet --line-regexp --fixed-strings -- "sha256:$1" <<< "$2"
  then
    images_added+=("$1")
  fi
}

# add_name <id> <ref>: name the image; <ref> must not exist yet. The check
# and the naming are two podman commands: another process creating the same
# name in between is not guarded against, which the run's random prefix
# makes practically impossible.
add_name() {
  local id=$1 ref=$2
  podman image exists "$ref"
  case $? in
    0) fail_setup "an image named $ref already exists; it is left as it is" ;;
    1) ;;
    *) fail_setup "cannot check whether an image named $ref exists" ;;
  esac
  podman tag "$id" "$ref" || fail_setup "cannot name the image $ref"
  names_added+=("$ref")
}

load_archive() {
  local archive=$1 ref=$2 before loaded
  before=$(known_images) || fail_setup 'cannot list the images podman has'
  loaded=$(podman load --quiet --input "$archive") \
    || fail_setup "podman cannot load $archive"
  loaded=${loaded##*:}
  [[ $loaded =~ ^[0-9a-f]{64}$ ]] \
    || fail_setup "unexpected answer from podman load: $loaded"
  note_if_new "$loaded" "$before"
  add_name "$loaded" "$ref"
}

# --layers=false keeps no intermediate images. A base image the build
# pulls stays in podman's storage, as with any build; pulling it for the
# other architecture moves its registry digest name to that copy, as every
# podman pull does.
build_image() {
  local name=$1 before built
  shift
  before=$(known_images) || fail_setup 'cannot list the images podman has'
  podman build --quiet --layers=false --platform "$platform" \
    --iidfile "$work/built-$name.id" "$@" > "$work/built-$name.log" 2>&1 \
    || fail_setup "cannot build $name:
$(tail -n 20 "$work/built-$name.log")"
  built=$(< "$work/built-$name.id") || fail_setup 'podman build gave no ID'
  built=${built##*:}
  [[ $built =~ ^[0-9a-f]{64}$ ]] \
    || fail_setup "unexpected image ID from podman build: $built"
  note_if_new "$built" "$before"
  built_ref=$run_names/$name:$arch
  add_name "$built" "$built_ref"
}

build_partner() {
  local partner=$1
  build/build-image.sh "$partner" "$arch" > "$work/build-$partner.log" 2>&1 \
    || fail_setup "building $partner failed; see the log below
$(tail -n 20 "$work/build-$partner.log")"
  partner_ref=$run_names/ubi9-$partner:$arch
  load_archive "dist/ubi9-$partner.$arch.tar" "$partner_ref"
}

end_of_test() {
  test_finished=1
}

# undo <what> <command...>: one cleanup step. A failure is reported, and
# a run whose cleanup failed does not pass.
undo() {
  local what=$1
  shift
  if ! "$@" > /dev/null 2>&1; then
    echo "test-image: cannot $what" >&2
    cleanup_failed=1
  fi
}

cleanup() {
  local status=$? id ref i
  for id in "${started_containers[@]}"; do
    undo "remove container $id" podman rm --force "$id"
  done
  # "podman untag <name> <name>" removes that one name, never the image or
  # its other names.
  for ref in "${names_added[@]}"; do
    undo "remove the name $ref" podman untag "$ref" "$ref"
  done
  # Newest first: an image built FROM another goes before it. --no-prune
  # keeps podman from deleting older unnamed images beneath them.
  for (( i = ${#images_added[@]} - 1; i >= 0; i-- )); do
    undo "delete image ${images_added[i]}" \
      podman rmi --no-prune "${images_added[i]}"
  done
  # Some tools (Go's module cache) write read-only folders; make everything
  # writable again so the work folder can be deleted.
  if [[ -n $work ]]; then
    chmod -R u+w "$work" 2> /dev/null
    undo "delete the work folder $work" rm -rf "$work"
  fi
  if (( cleanup_failed == 1 && status == 0 )); then
    echo 'test-image: the cleanup failed, so the run does not pass' >&2
    exit 2
  fi
  # An "exit" inside a test must not look like a finished run, passing or
  # failing. fail_setup has already said why it stopped.
  if (( runner_finished == 0 && status != 2 )); then
    echo 'test-image: the test stopped before it finished' >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Arguments.
# ---------------------------------------------------------------------------
case $# in
  1) arch=$(uname -m) || fail_setup 'cannot read this machine architecture' ;;
  2) arch=$2 ;;
  *) fail_setup 'usage: build/test-image.sh <image> [architecture]' ;;
esac
image=$1

[[ $image =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail_setup "invalid image name: $image"
case $arch in
  x86_64) platform=linux/amd64 ;;
  aarch64 | arm64) platform=linux/arm64; arch=aarch64 ;;
  *) fail_setup "unsupported architecture: $arch" ;;
esac

test_dir=images/$image/test
archive=dist/ubi9-$image.$arch.tar

[[ -f $test_dir/test.sh ]] || fail_setup "$test_dir/test.sh does not exist"
bash -n "$test_dir/test.sh" || fail_setup "$test_dir/test.sh does not parse"
[[ -f $archive ]] || fail_setup "$archive does not exist; build it first"

trap cleanup EXIT
work=$(mktemp --directory "${TMPDIR:-/tmp}/test-image.XXXXXX") \
  || fail_setup 'cannot create a work folder'

# Image names this run adds carry the work folder's random suffix, so two
# runs, or a name someone else made, never meet.
run_suffix=${work##*.}
run_names=localhost/test-${run_suffix,,}
image_ref=$run_names/ubi9-$image:$arch

# Toolset tests run what they build in the work folder (Go binaries, a
# Python C extension). Hardened hosts often mount /tmp noexec; say so now
# rather than fail later with an unclear error.
printf '#!/bin/sh\nexit 0\n' > "$work/can-run" \
  || fail_setup "cannot write to the work folder $work"
chmod +x "$work/can-run" || fail_setup "cannot mark $work/can-run executable"
"$work/can-run" 2> /dev/null \
  || fail_setup "cannot run programs in $work (mounted noexec?);" \
                'set TMPDIR to a folder that allows it'
rm -f "$work/can-run"

test_files=$work/test
cp -R "$test_dir" "$test_files" || fail_setup 'cannot copy the test folder'
chmod -R a+rX "$test_files" || fail_setup 'cannot make the test copy readable'

load_archive "$archive" "$image_ref"
echo "Testing ubi9-$image ($arch)"

# ---------------------------------------------------------------------------
# What every image promises.
# ---------------------------------------------------------------------------
user=$(podman image inspect --format '{{.Config.User}}' "$image_ref") \
  || fail_setup "cannot inspect $image_ref"
if [[ $user == 65532:65532 ]]; then
  pass 'runs as user 65532'
else
  fail "runs as user 65532 (configured: '$user')"
fi

# The container is only exported, never started; images with no entrypoint
# (micro, dotnet-runtime-deps) still need a command name to be created.
inspect=$(podman create --platform "$platform" "$image_ref" unused) \
  || fail_setup "cannot create a container from $image_ref"
started_containers+=("$inspect")
podman export "$inspect" | tar --list > "$work/files"
statuses=("${PIPESTATUS[@]}")
(( statuses[0] == 0 && statuses[1] == 0 )) \
  || fail_setup "cannot list the image files (export ${statuses[0]}," \
                "tar ${statuses[1]})"
files=$(< "$work/files") || fail_setup 'cannot read the file list'
has_file etc/os-release || fail_setup 'the file list has no etc/os-release'

# A toolset is a build environment and keeps its shell and package manager.
# A runtime has none: no shell, package manager or language package tool,
# in any of the folders a command is looked up in (bin, sbin, usr/bin,
# usr/sbin, usr/local/bin, usr/local/sbin), with or without a version.
if [[ $image == *-toolset ]]; then
  check 'a toolset has a shell' has_file usr/bin/bash
  check 'a toolset has a package manager' has_file usr/bin/microdnf
else
  for name in sh bash dash zsh ksh mksh csh tcsh ash busybox \
              microdnf dnf dnf-3 yum rpm apt apt-get dpkg apk \
              pip pip3 npm npx
  do
    if has_file_matching "^(usr/(local/)?)?s?bin/$name(-?[0-9.]+)?\$"; then
      fail "no $name in a runtime image"
    else
      pass "no $name in a runtime image"
    fi
  done
fi

# ---------------------------------------------------------------------------
# What this image promises.
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$test_dir/test.sh"
status=$?
(( status == 0 )) || fail_setup "$test_dir/test.sh ended with status $status"
(( test_finished == 1 )) \
  || fail_setup "$test_dir/test.sh stopped before its end_of_test line"

echo "Result for ubi9-$image ($arch): $passed passed, $failed failed"
runner_finished=1
(( failed == 0 )) || exit 1
