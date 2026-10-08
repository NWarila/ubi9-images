# images/openjdk-17-toolset/test/test.sh - what ubi9-openjdk-17-toolset
# promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# The toolset compiles the probe of its runtime
# (images/openjdk-17-runtime/test/Probe.java) with javac, packs it into a
# runnable jar, and the jar then runs on ubi9-openjdk-17-runtime, which is
# built here.

# shellcheck shell=bash disable=SC2154,SC2034

run_in "$image_ref" javac -version
expect 'has the Java 17 compiler' 'javac 17.'

# toolset <command...>: run in the toolset as this machine's user, so the
# files it writes in $work belong to us.
toolset() {
  podman_run --userns=keep-id --user "$(id -u):$(id -g)" \
    --volume "$work:/work:z" --workdir /work "$image_ref" "$@"
}

mkdir -p "$work/src" "$work/app" || fail_setup 'cannot create the folders'
cp images/openjdk-17-runtime/test/Probe.java "$work/src/" \
  || fail_setup 'cannot copy the probe'

check 'compiles with javac' \
  toolset javac -d /work/classes /work/src/Probe.java
check 'packs a runnable jar' \
  toolset jar --create --file /work/app/probe.jar --main-class Probe \
  -C /work/classes .

# The runtime runs as user 65532: make the jar readable to it.
chmod -R a+rX "$work/app" || fail_setup 'cannot make the jar readable'

build_partner openjdk-17-runtime
capture podman_run --volume "$work/app:/app:ro,z" "$partner_ref" \
  -jar /app/probe.jar
expect 'the jar runs on ubi9-openjdk-17-runtime' 'PASS Java: 17.'
expect_line 'the jar reaches github.com over HTTPS from the runtime' \
  'PASS HTTPS to github.com: HTTP 200'

end_of_test
