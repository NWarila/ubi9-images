#!/usr/bin/env bash
#
# test-image.sh - prove that a built image does what its folder promises.
#
# HOW TO RUN IT
#   From the repository root, after build/build-image.sh has built it:
#
#     build/test-image.sh micro            for this machine's architecture
#     build/test-image.sh micro aarch64    for another architecture, which
#                                          runs under emulation (QEMU)
#
#   It needs podman, curl, tar and network access: github.com for the
#   HTTPS checks, Red Hat's registry and content servers for micro's helper
#   image and for a toolset's partner build (build/build-image.sh, which
#   also needs Docker Buildx), and nuget.org for the .NET toolset. Where
#   /tmp is mounted noexec, set TMPDIR to a folder that allows running
#   programs.
#
# WHAT IT READS
#   dist/ubi9-<image>.<arch>.tar     the image, from build/build-image.sh
#   images/<image>/test/test.sh      what this image promises, with the
#                                    files it uses beside it
#
# WHAT IT WRITES
#   dist/ubi9-<runtime>.<arch>.*     a toolset's runtime, built by its test
#
# WHAT IT CHECKS
#   1. what every image promises: it runs as user 65532; a toolset (an
#      image named *-toolset) has bash and microdnf; every other image, a
#      runtime, has no shell, no package manager and no language package
#      tool
#   2. what images/<image>/test/test.sh checks, which is particular to that
#      image; a toolset's test also builds the runtime its application
#      runs on, with build/build-image.sh
#   Every check prints "PASS <what>" or "FAIL <what>".
#
# CLEANUP
#   The image is loaded under a name unique to this run. At the end the
#   script removes the containers it made and the image names it added,
#   and deletes only the images podman did not have before this run; if
#   any of that fails, the run does not pass. A base image that a build
#   pulls stays, as after any build.
#
# EXIT STATUS
#   0  every check passed, the image test ran to its last line, and the
#      cleanup succeeded
#   1  a check failed
#   2  the checks could not be run, the image test stopped early or checked
#      nothing, or the cleanup failed (even if a check failed too)
#   A run stopped by a signal (a cancelled CI job) cleans up what it has
#   recorded, then ends with that signal; an image made in the moment
#   before it is recorded can be left behind.

# Results and the runner's own messages go to file descriptors 3 and 4: the
# run's output and error streams, saved by the first line of the run (at
# the bottom). A check sends its command's output to a file, and a result
# line or a cleanup message must never land there.
fail_setup() {
  echo "test-image: $*" >&4
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
#                localhost/test-<random hex word>, unique to this run
#
#   pass <what> / fail <what>           record a result directly
#   check <what> <command...>           PASS when the command succeeds
#   check_refused <what> <error text> <command...>
#                                       PASS when the command fails AND
#                                       prints <error text>: a refusal is
#                                       observed, not assumed
#   capture <command...>                run it in this shell and keep its
#                                       output in $output; when it exits
#                                       non-zero, that is a FAIL, and every
#                                       expect on that output fails too
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
# Every other command in test.sh must succeed, or be checked with
# "|| fail_setup". A command at the top level of test.sh that fails on its
# own line is recorded as a FAIL with its line number, and so is a call to
# a test.sh function that returns non-zero. Bash does not report a failure
# in the middle of a function or a pipeline, in the condition of an if, or
# before an && or ||: check every command in a function, and never put a
# check behind a condition.
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
test_end_line=0
runner_finished=0
cleanup_failed=0
containers_added=()
names_added=()
images_added=()

write_output() {
  printf '%s\n' "$*" >&3 || fail_setup 'cannot write the test output'
}

pass() {
  write_output "PASS  $*"
  passed=$((passed + 1))
  return 0
}

fail() {
  write_output "FAIL  $*"
  failed=$((failed + 1))
  return 0
}

# A failure shows the last lines the command printed, if it printed any.
show_tail() {
  [[ -n $1 ]] || return 0
  tail -n 15 <<< "$1" | sed 's/^/        /' >&3
  return 0
}

# check and check_refused run the command in this shell, not a subshell,
# so a failure that a helper records inside it (run_in, say) still counts.
# check then adds no PASS of its own: that FAIL is the result. A check
# with no command, or with no text to look for, would pass whatever
# happened, so it stops the run instead.
check() {
  local what=$1 failed_before=$failed
  shift
  (( $# > 0 )) || fail_setup "check '$what' has no command"
  if ! "$@" > "$work/check.out" 2>&1; then
    fail "$what"
    show_tail "$(< "$work/check.out")"
  elif (( failed == failed_before )); then
    pass "$what"
  fi
}

check_refused() {
  local what=$1 refusal=$2 printed
  shift 2
  [[ -n $refusal ]] || fail_setup "check_refused '$what' has no error text"
  (( $# > 0 )) || fail_setup "check_refused '$what' has no command"
  if "$@" > "$work/check.out" 2>&1; then
    fail "$what (the command succeeded)"
    show_tail "$(< "$work/check.out")"
    return 0
  fi
  printed=$(< "$work/check.out")
  if [[ $printed == *"$refusal"* ]]; then
    pass "$what"
  else
    fail "$what (it failed, but not with: $refusal)"
    show_tail "$printed"
  fi
}

# capture runs the command in this shell too, so a result or a cleanup
# record made inside it counts. It records its own FAIL; it returns 0 so
# that the failure is not counted a second time as a failed command of
# test.sh.
capture() {
  local status
  "$@" > "$work/capture.out" 2>&1
  status=$?
  output=$(< "$work/capture.out") || fail_setup 'cannot read the output'
  if (( status == 0 )); then
    output_ok=1
  else
    output_ok=0
    fail "$* (exited with status $status)"
    show_tail "$output"
  fi
  return 0
}

podman_run() {
  podman run --rm --pull=never --timeout "$container_timeout" \
    --platform "$platform" "$@"
}

run_in() {
  local ref=$1
  shift
  capture podman_run --volume "$test_files:/test:ro,z" "$ref" "$@"
}

expect() {
  [[ -n $2 ]] || fail_setup "expect '$1' has no text to look for"
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
  [[ -n $2 ]] || fail_setup "expect_line '$1' has no line to look for"
  if (( output_ok == 0 )); then
    fail "$1 (the command that printed the output failed)"
  elif grep --quiet --line-regexp --fixed-strings -- "$2" <<< "$output"; then
    pass "$1"
  else
    fail "$1 (expected the line: $2)"
    show_tail "$output"
  fi
}

# search_files <grep options...> <pattern>: true when a path matches. A
# search that cannot run (a bad pattern, say) stops the run, so it is never
# taken for "no such file".
search_files() {
  grep --quiet "$@" <<< "$files"
  case $? in
    0) return 0 ;;
    1) return 1 ;;
    *) fail_setup "cannot search the file list for: ${*: -1}" ;;
  esac
}

has_file() {
  search_files --line-regexp --fixed-strings -- "$1"
}

has_file_matching() {
  search_files --extended-regexp -- "$1"
}

image_env() {
  podman image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "$1"
}

# The container is named, and the name recorded, before podman runs it:
# podman keeps a container that it created but could not start.
start_container() {
  local name=test-$run_word-${#containers_added[@]}
  containers_added+=("$name")
  # shellcheck disable=SC2034  # test.sh reads it
  container_id=$(podman run --detach --pull=never --name "$name" \
    --timeout "$container_timeout" --platform "$platform" "$@") \
    || fail_setup "cannot start a container: $*"
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

# --layers=false keeps no intermediate images. A base image that the build
# pulls stays in podman's storage, as after any build (see CLEANUP above).
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

# end_of_test records the line it was called from, so the runner can prove
# the test reached its last line: a test that returned early never calls it
# from there.
end_of_test() {
  test_end_line=${BASH_LINENO[0]}
}

# undo <what> <command...>: one cleanup step. A failure is reported, with
# the command's own error, and a run whose cleanup failed does not pass.
undo() {
  local what=$1
  shift
  if ! "$@" > /dev/null; then
    echo "test-image: cannot $what" >&4
    cleanup_failed=1
  fi
}

cleanup() {
  local status=$? id ref i
  # A signal can arrive while a check has the output sent to a file; send it
  # back to the run's own streams first.
  exec 1>&3 2>&4
  # --ignore: a container podman never created is not an error.
  for id in "${containers_added[@]}"; do
    undo "remove container $id" podman rm --force --ignore "$id"
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
  # Some tools (Go's module cache) write read-only folders; make them
  # writable so the work folder can be deleted. Whether that worked shows in
  # the deletion, which is checked.
  if [[ -n $work ]]; then
    chmod -R u+w "$work" 2> /dev/null || :
    undo "delete the work folder $work" rm -rf "$work"
  fi
  if (( cleanup_failed == 1 )); then
    echo 'test-image: the cleanup failed, so the run does not pass' >&4
    exit 2
  fi
  # An "exit" inside a test must not look like a finished run, passing or
  # failing. fail_setup has already said why it stopped.
  if (( runner_finished == 0 && status != 2 )); then
    echo 'test-image: the test stopped before it finished' >&4
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# The steps of a run, in the order the run at the bottom takes them.
# ---------------------------------------------------------------------------

# read_arguments <image> [architecture]: sets image, arch and platform, and
# the paths that follow from them.
read_arguments() {
  case $# in
    1) arch=$(uname -m) || fail_setup 'cannot read the architecture' ;;
    2) arch=$2 ;;
    *) fail_setup 'usage: build/test-image.sh <image> [x86_64|aarch64]' ;;
  esac
  image=$1

  # An image is a plain folder name under images/: no path, no capitals,
  # and not an option such as --help.
  [[ $image =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail_setup "image name '$image' must be lower-case letters, digits" \
                  'and hyphens, starting with a letter or digit'

  # macOS calls the 64-bit Arm architecture arm64; the archives use Linux's.
  case $arch in
    x86_64)
      platform=linux/amd64
      ;;
    aarch64 | arm64)
      platform=linux/arm64
      arch=aarch64
      ;;
    *) fail_setup "unknown architecture '$arch' (expected x86_64 or aarch64)" ;;
  esac

  test_dir=images/$image/test
  archive=dist/ubi9-$image.$arch.tar
}

check_inputs() {
  [[ -f $test_dir/test.sh ]] \
    || fail_setup "$test_dir/test.sh does not exist; run this from the" \
                  'repository root, naming a folder under images/'
  bash -n "$test_dir/test.sh" \
    || fail_setup "$test_dir/test.sh does not parse"
  [[ -f $archive ]] || fail_setup "$archive does not exist; build it first"
}

# make_work_folder: sets work and test_files.
make_work_folder() {
  # podman takes a mount source that does not start with / for the name of
  # a volume, not a folder.
  [[ ${TMPDIR:-/tmp} == /* ]] || fail_setup 'TMPDIR must be an absolute path'
  work=$(mktemp --directory "${TMPDIR:-/tmp}/test-image.XXXXXX") \
    || fail_setup 'cannot create a work folder'

  # Toolset tests run what they build in the work folder (Go binaries, a
  # Python C extension). Hardened hosts often mount /tmp noexec; say so now
  # rather than fail later with an unclear error.
  printf '#!/bin/sh\nexit 0\n' > "$work/can-run" \
    || fail_setup "cannot write to the work folder $work"
  chmod +x "$work/can-run" \
    || fail_setup "cannot mark $work/can-run executable"
  "$work/can-run" 2> /dev/null \
    || fail_setup "cannot run programs in $work (mounted noexec?);" \
                  'set TMPDIR to a folder that allows it'
  rm -f "$work/can-run" || fail_setup "cannot remove $work/can-run"

  test_files=$work/test
  cp -R "$test_dir" "$test_files" || fail_setup 'cannot copy the test folder'
  chmod -R a+rX "$test_files" \
    || fail_setup 'cannot make the test copy readable'
}

# name_this_run: sets run_word, run_names and image_ref. Image names this
# run adds carry a random hex word, so two runs, or a name someone else
# made, do not meet (add_name refuses one that exists).
name_this_run() {
  run_word=$(od -An -N6 -tx1 /dev/urandom) \
    || fail_setup 'cannot read a random word from /dev/urandom'
  run_word=${run_word//[[:space:]]/}
  [[ $run_word =~ ^[0-9a-f]{12}$ ]] \
    || fail_setup "unexpected random word: $run_word"
  run_names=localhost/test-$run_word
  image_ref=$run_names/ubi9-$image:$arch
}

check_user() {
  local user
  user=$(podman image inspect --format '{{.Config.User}}' "$image_ref") \
    || fail_setup "cannot inspect $image_ref"
  if [[ $user == 65532:65532 ]]; then
    pass 'runs as user 65532'
  else
    fail "runs as user 65532 (configured: '$user')"
  fi
}

# list_files: sets files, every path in the image.
list_files() {
  local inspect=test-$run_word-files statuses
  # The container is only exported, never started; images with no
  # entrypoint (micro, dotnet-runtime-deps) still need a command name to be
  # created.
  containers_added+=("$inspect")
  podman create --pull=never --name "$inspect" --platform "$platform" \
    "$image_ref" unused > /dev/null \
    || fail_setup "cannot create a container from $image_ref"
  podman export "$inspect" | tar --list > "$work/files"
  statuses=("${PIPESTATUS[@]}")
  (( statuses[0] == 0 && statuses[1] == 0 )) \
    || fail_setup "cannot list the image files (export ${statuses[0]}," \
                  "tar ${statuses[1]})"
  files=$(< "$work/files") || fail_setup 'cannot read the file list'
  has_file etc/os-release || fail_setup 'the file list has no etc/os-release'
}

# A toolset is a build environment and keeps its shell and package manager.
check_toolset_tools() {
  check 'a toolset has a shell' has_file usr/bin/bash
  check 'a toolset has a package manager' has_file usr/bin/microdnf
}

# A runtime has no shell, package manager or language package tool, in any
# of the folders a command is looked up in (bin, sbin, usr/bin, usr/sbin,
# usr/local/bin, usr/local/sbin), with or without a version.
check_runtime_has_no_tools() {
  local name pattern
  for name in sh bash dash zsh ksh mksh csh tcsh ash busybox \
              microdnf dnf dnf-3 yum rpm apt apt-get dpkg apk \
              pip pip3 npm npx
  do
    pattern="^(usr/(local/)?)?s?bin/$name(-?[0-9.]+)?\$"
    if has_file_matching "$pattern"; then
      fail "no $name in a runtime image"
      show_tail "$(grep --extended-regexp -- "$pattern" <<< "$files")"
    else
      pass "no $name in a runtime image"
    fi
  done
}

# failed_command <line> <command>: a command of test.sh failed on its own
# line, outside the check functions; that is a FAIL too. For a call to a
# function, <command> is the last command bash ran inside it.
# BASH_SOURCE[1] is the file the failed line is in: test.sh, or this
# script when "source" itself returns test.sh's last failure.
failed_command() {
  local status=$?
  fail "${BASH_SOURCE[1]} line $1: '$2' exited with status $status"
}

# check_test_ran <status of test.sh>: it ended with status 0, its last line
# is the end_of_test call that ran, and it recorded at least one result.
check_test_ran() {
  local -a test_lines
  (( $1 == 0 )) || fail_setup "$test_dir/test.sh ended with status $1"
  # mapfile counts a last line that has no newline after it, as bash runs it;
  # wc --lines counts newlines and would not.
  mapfile -t test_lines < "$test_dir/test.sh" \
    || fail_setup "cannot read $test_dir/test.sh"
  (( test_end_line == ${#test_lines[@]} )) \
    || fail_setup "$test_dir/test.sh did not end with end_of_test"
  (( passed + failed > results_before )) \
    || fail_setup "$test_dir/test.sh checked nothing"
}

# ---------------------------------------------------------------------------
# The run.
# ---------------------------------------------------------------------------
exec 3>&1 4>&2
read_arguments "$@"
check_inputs
trap cleanup EXIT
make_work_folder
name_this_run
load_archive "$archive" "$image_ref"
write_output "Testing ubi9-$image ($arch)"

# What every image promises.
check_user
list_files
if [[ $image == *-toolset ]]; then
  check_toolset_tools
else
  check_runtime_has_no_tools
fi

# What this image promises.
results_before=$((passed + failed))
trap 'failed_command "$LINENO" "$BASH_COMMAND"' ERR
# shellcheck source=/dev/null
source "$test_dir/test.sh"
test_status=$?
trap - ERR
check_test_ran "$test_status"

write_output "Result for ubi9-$image ($arch): $passed passed, $failed failed"
runner_finished=1
(( failed == 0 )) || exit 1
