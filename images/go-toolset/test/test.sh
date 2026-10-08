# images/go-toolset/test/test.sh - what ubi9-go-toolset promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# The toolset builds the probe in probe/ twice, as a static binary and with
# cgo, and both run on ubi9-micro, which is built here: Go programs need no
# runtime image of their own.

# shellcheck shell=bash disable=SC2154,SC2034

run_in "$image_ref" go version
expect 'has the Go compiler' 'go version go1.'

# toolset <cgo 0|1> <command...>: run in the toolset as this machine's user,
# so the files it writes in $work belong to us. GOTOOLCHAIN=local keeps Go
# from downloading another compiler.
toolset() {
  local cgo=$1
  shift
  podman_run --userns=keep-id --user "$(id -u):$(id -g)" \
    --env HOME=/work/home --env GOTOOLCHAIN=local --env "CGO_ENABLED=$cgo" \
    --volume "$work:/work:z" --workdir /work/probe "$image_ref" "$@"
}

mkdir -p "$work/home" "$work/out" || fail_setup 'cannot create folders'
cp -R "$test_dir/probe" "$work/probe" || fail_setup 'cannot copy the probe'

check 'builds a static binary' \
  toolset 0 go build -buildvcs=false -o /work/out/probe-static .
check 'builds a cgo binary' \
  toolset 1 go build -buildvcs=false -o /work/out/probe-cgo .

# micro runs as user 65532: make the binaries readable to it.
chmod -R a+rX "$work/out" || fail_setup 'cannot make the binaries readable'

build_partner micro
for kind in static cgo; do
  capture podman_run --volume "$work/out:/app:ro,z" \
    --entrypoint "/app/probe-$kind" "$partner_ref"
  expect "the $kind binary runs on ubi9-micro" "PASS linking: $kind"
  expect_line "the $kind binary runs as user 65532" 'PASS runs as: uid 65532'
  expect_line "the $kind binary finds micro's time zones" \
    'PASS time zones: 07:00'
  expect_line "the $kind binary reaches github.com with micro's CA bundle" \
    'PASS HTTPS to github.com: HTTP 200'
done

end_of_test
