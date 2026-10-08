# images/nodejs-24-toolset/test/test.sh - what ubi9-nodejs-24-toolset
# promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# The toolset packs the package in lib/ with npm and installs it into the
# app in app/, without the npm registry; the app then runs on
# ubi9-nodejs-24-runtime, which is built here.

# shellcheck shell=bash disable=SC2154,SC2034

check 'has npm' podman_run "$image_ref" npm --version

# toolset <folder> <command...>: run in the toolset as this machine's user,
# so the files it writes in $work belong to us; HOME holds npm's cache.
toolset() {
  local folder=$1
  shift
  podman_run --userns=keep-id --user "$(id -u):$(id -g)" \
    --env HOME=/work/home --volume "$work:/work:z" \
    --workdir "/work/$folder" "$image_ref" "$@"
}

mkdir -p "$work/home" || fail_setup 'cannot create the home folder'
cp -R "$test_dir/lib" "$test_dir/app" "$work/" \
  || fail_setup 'cannot copy the packages'

check 'packs a package with npm' \
  toolset lib npm pack --pack-destination /work
check 'installs it into the app without the registry' \
  toolset app npm install --offline --no-audit --no-fund \
  /work/probe-lib-1.0.0.tgz

# The runtime runs as user 65532: make the app readable to it.
chmod -R a+rX "$work/app" || fail_setup 'cannot make the app readable'

build_partner nodejs-24-runtime
capture podman_run --volume "$work/app:/app:ro,z" "$partner_ref" /app/app.js
# The package returns SHA-256 of "x", a known answer.
sha256_x=2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881
expect_line 'the app runs on ubi9-nodejs-24-runtime' \
  "PASS npm-installed package works: sha256 $sha256_x"

end_of_test
