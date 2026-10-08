# images/nodejs-24-runtime/test/test.sh - what ubi9-nodejs-24-runtime
# promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# Node.js uses the FIPS-validated OpenSSL and has no opt-out: MD5, 3DES and
# RSA-1024 keys are refused, each with OpenSSL's own reason.
#
# The image carries English locale data only (nodejs-full-i18n is left out,
# owner decision 2026-10-07): a German date falls back to English without an
# error. The test asserts that, so adding the locale data is noticed.

# shellcheck shell=bash disable=SC2154,SC2034

run_in "$image_ref" /test/probe.js
expect_line 'runs as user 65532' 'PASS runs as: uid 65532'
expect_line 'de-DE falls back to en-US: no German locale data' \
  'PASS ICU cultures: de-DE resolved to en-US: Tuesday, October 6, 2026'
expect_line 'converts time zones' 'PASS time zones: 07:00:00'
expect_line 'gzip and Brotli work' \
  'PASS gzip and Brotli compression: round trip ok'
expect_line 'HTTPS to github.com works with the CA bundle' \
  'PASS HTTPS to github.com: HTTP 200'

# OpenSSL's reasons: the FIPS provider has no such algorithm, and an RSA
# key that short is invalid under FIPS.
no_algorithm='error:0308010C:digital envelope routines::unsupported'
too_short='error:020000AE:rsa routines::invalid modulus'
expect_line 'MD5 is refused' \
  "REFUSED MD5: ERR_OSSL_EVP_UNSUPPORTED: $no_algorithm"
expect_line '3DES is refused' \
  "REFUSED 3DES encryption: ERR_OSSL_EVP_UNSUPPORTED: $no_algorithm"
expect_line 'RSA-1024 key generation is refused' \
  "REFUSED RSA-1024 key generation: Error: $too_short"
# SHA-256 of "x", a known answer.
sha256_x=2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881
expect_line 'SHA-256 works' "ALLOWED SHA-256: $sha256_x"
expect_line 'AES-256-GCM is allowed' \
  'ALLOWED AES-256-GCM encryption: cipher created'
expect_line 'RSA-2048 key generation works' \
  'ALLOWED RSA-2048 key generation: generated'

end_of_test
