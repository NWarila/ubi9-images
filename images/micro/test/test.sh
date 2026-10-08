# images/micro/test/test.sh - what ubi9-micro promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# micro has no shell and no language, so nothing inside it can run a probe.
# The test adds only the openssl command (see Containerfile in this folder)
# and drives micro's own OpenSSL with it.

# shellcheck shell=bash disable=SC2154,SC2034

# The builder image, read from micro's Dockerfile so there is one pin.
builder_line=$(grep --max-count=1 '^ARG BUILDER=' images/micro/Dockerfile) \
  || fail_setup 'images/micro/Dockerfile has no ARG BUILDER line'
builder=${builder_line#ARG BUILDER=}

# A throwaway image: micro plus the openssl command (see Containerfile).
build_image ubi9-micro-openssl \
  --build-arg "BUILDER=$builder" --build-arg "MICRO=$image_ref" \
  --file "$test_dir/Containerfile" "$test_dir"
tool_ref=$built_ref

# openssl <arguments>: run micro's OpenSSL in the test image.
openssl() {
  podman_run "$tool_ref" openssl "$@"
}

# The validated FIPS provider is loaded, beside the base and default ones.
capture openssl list -providers
expect 'the FIPS provider is loaded' \
  'name: Red Hat Enterprise Linux 9 - OpenSSL FIPS Provider'

# FIPS by default: approved algorithms work, others are refused. A refusal
# counts only when OpenSSL itself says why, so a container that failed to
# start is not mistaken for one.
check 'SHA-256 works' openssl dgst -sha256 /etc/os-release
check_refused 'MD5 is refused: the FIPS provider has no MD5' \
  'Algorithm (MD5' \
  openssl dgst -md5 /etc/os-release
check 'MD5 works when a program explicitly opts out of FIPS' \
  openssl dgst -md5 -propquery '-fips' /etc/os-release
check_refused '3DES encryption is refused: the FIPS provider has no 3DES' \
  'Algorithm (DES-EDE3-CBC' \
  openssl enc -des-ede3-cbc -K "$(printf '0%.0s' {1..48})" \
  -iv 0000000000000000 -in /etc/os-release -out /dev/null
check_refused 'RSA-1024 key generation is refused: the key is too short' \
  'invalid modulus' \
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024
check 'RSA-2048 key generation works' \
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048

# TLS to a public site, verified with micro's CA bundle.
capture openssl s_client -connect github.com:443 -servername github.com \
  -verify_return_error -brief
expect_line 'TLS to github.com verifies with the CA bundle' 'Verification: OK'

end_of_test
