# images/dotnet-10-toolset/test/test.sh - what ubi9-dotnet-10-toolset
# promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# The toolset builds the probe in probe/ twice: framework-dependent, which
# runs on ubi9-dotnet-10-runtime, and self-contained, which runs on
# ubi9-dotnet-runtime-deps. Both runtimes are built here, so this is also
# where those two images run the probe: they cannot compile it themselves.

# shellcheck shell=bash disable=SC2154,SC2034

run_in "$image_ref" dotnet --version
expect 'has the .NET 10 SDK' '10.0.'

capture image_env "$image_ref"
expect_line 'sends no usage data to Microsoft' 'DOTNET_CLI_TELEMETRY_OPTOUT=1'

# toolset <command...>: run in the toolset as this machine's user, so the
# files it writes in $work belong to us; HOME holds the NuGet cache.
toolset() {
  podman_run --userns=keep-id --user "$(id -u):$(id -g)" \
    --env HOME=/work/home --volume "$work:/work:z" --workdir /work/probe \
    "$image_ref" "$@"
}

mkdir -p "$work/home" || fail_setup 'cannot create the home folder'
cp -R "$test_dir/probe" "$work/probe" || fail_setup 'cannot copy the probe'

case $arch in
  x86_64) runtime_id=linux-x64 ;;
  aarch64) runtime_id=linux-arm64 ;;
esac

check 'publishes framework-dependent' \
  toolset dotnet publish --configuration Release --output /work/fdd
check 'publishes self-contained (the runtime pack comes from nuget.org)' \
  toolset dotnet publish --configuration Release --runtime "$runtime_id" \
  --self-contained --output /work/sc

# The runtimes run as user 65532: make the probes readable to them.
chmod -R a+rX "$work/fdd" "$work/sc" \
  || fail_setup 'cannot make the probes readable'

# Known answers: SHA-256 of "abc" and MD5 of the single byte 1.
sha256_abc=BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD
md5_1=55A54008AD1BA589AA210D2629C1DF41

# expect_probe_works <image>: what "probe" printed when every check worked.
expect_probe_works() {
  local on=$1
  expect "$on: runs .NET 10" 'PASS runtime: .NET 10.'
  expect_line "$on: formats German dates (ICU)" \
    'PASS ICU cultures: Dienstag, 6. Oktober 2026'
  expect_line "$on: converts time zones" 'PASS time zones: 07:00'
  expect_line "$on: Brotli works" 'PASS Brotli compression: round trip ok'
  expect_line "$on: SHA-256 works" "PASS SHA-256: $sha256_abc"
  expect_line "$on: AES-GCM works" 'PASS AES-GCM: round trip ok'
  expect_line "$on: HTTPS to github.com works with the CA bundle" \
    'PASS HTTPS to github.com: HTTP 200'
  expect_line "$on: no check failed" 'ALL PASS'
}

# expect_fips_behaviour <image>: what "probe fips" printed. OpenSSL's
# reasons: the FIPS provider has no such algorithm, and an RSA key that
# short is invalid under FIPS.
no_algorithm='error:0308010C:digital envelope routines::unsupported'
too_short='error:020000AE:rsa routines::invalid modulus'
refusal='OpenSslCryptographicException'
expect_fips_behaviour() {
  local on=$1
  expect_line "$on: MD5 works (.NET opts out of FIPS for MD5)" \
    "ALLOWED MD5: $md5_1"
  expect_line "$on: RSA-1024 key generation is refused" \
    "REFUSED RSA-1024 key generation: $refusal: $too_short"
  expect_line "$on: RSA-2048 key generation works" \
    'ALLOWED RSA-2048 key generation: 2048-bit key'
  expect_line "$on: 3DES is refused" \
    "REFUSED 3DES encryption: $refusal: $no_algorithm"
  expect_line "$on: ChaCha20-Poly1305 is refused" \
    "REFUSED ChaCha20-Poly1305 encryption: $refusal: $no_algorithm"
}

# ---------------------------------------------------------------------------
# The framework-dependent probe on ubi9-dotnet-10-runtime.
# ---------------------------------------------------------------------------
build_partner dotnet-10-runtime
runtime_ref=$partner_ref

on_runtime() {
  capture podman_run --volume "$work/fdd:/app:ro,z" "$runtime_ref" \
    /app/probe.dll "$@"
}

on_runtime
expect_probe_works dotnet-10-runtime
on_runtime fips
expect_fips_behaviour dotnet-10-runtime

# With no settings, an ASP.NET Core app answers on port 8080.
start_container --publish 127.0.0.1::8080 --volume "$work/fdd:/app:ro,z" \
  "$runtime_ref" /app/probe.dll serve
address=$(podman port "$container_id" 8080) \
  || fail_setup 'the web probe has no published port'
for _ in $(seq 1 30); do
  curl --silent --fail --max-time 5 --output /dev/null "http://$address/" \
    && break
  sleep 1
done
capture curl --silent --show-error --fail --max-time 5 "http://$address/"
expect 'dotnet-10-runtime: ASP.NET Core answers on port 8080' \
  'hello from .NET 10.'

# ---------------------------------------------------------------------------
# The self-contained probe on ubi9-dotnet-runtime-deps.
# ---------------------------------------------------------------------------
build_partner dotnet-runtime-deps
deps_ref=$partner_ref

on_deps() {
  capture podman_run --volume "$work/sc:/app:ro,z" --entrypoint /app/probe \
    "$deps_ref" "$@"
}

on_deps
expect_probe_works dotnet-runtime-deps
on_deps fips
expect_fips_behaviour dotnet-runtime-deps

end_of_test
