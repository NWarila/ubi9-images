# images/python-312-runtime/test/test.sh - what ubi9-python-312-runtime
# promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# Python uses the FIPS-validated OpenSSL: hashlib.md5() is refused, and a
# program that uses MD5 for something other than security says so with
# usedforsecurity=False, which works.

# shellcheck shell=bash disable=SC2154,SC2034

run_in "$image_ref" /test/probe.py
expect_line 'runs as user 65532' 'PASS runs as: uid 65532'
expect_line 'every standard-library module imports' \
  'PASS standard library: every module imports'
expect 'sqlite works' 'PASS sqlite: 3.'
expect_line 'zlib, bz2 and lzma work' \
  'PASS compression: zlib, bz2 and lzma round trip ok'
expect_line 'converts time zones' 'PASS time zones: 07:00'
expect_line 'HTTPS to github.com works with the CA bundle' \
  'PASS HTTPS to github.com: HTTP 200'
no_md5='UnsupportedDigestmodError: [digital envelope routines] unsupported'
expect_line 'MD5 is refused: OpenSSL has no MD5 under FIPS' \
  "REFUSED MD5: $no_md5"
# MD5 and SHA-256 of "x", known answers.
md5_x=9dd4e461268c8034f5c8564e155c67a6
sha256_x=2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881
expect_line 'MD5 works with usedforsecurity=False' \
  "ALLOWED MD5 with usedforsecurity=False: $md5_x"
expect_line 'SHA-256 works' "ALLOWED SHA-256: $sha256_x"

end_of_test
