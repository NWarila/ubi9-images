# images/openjdk-25-runtime/test/test.sh - what ubi9-openjdk-25-runtime
# promises.
#
# Read by build/test-image.sh, which provides the check functions and the
# variables this file uses; they are listed at the top of that script.
#
# Probe.java runs with Java's single-file source launcher, which the
# headless runtime supports, so no compiler is needed here.
#
# Java does not use the FIPS-validated OpenSSL: its own providers serve
# MD5, 3DES and RSA-1024, and the system crypto policy restricts only TLS
# and certificate checks. The test records that behaviour, so a change in
# either direction is noticed.

# shellcheck shell=bash disable=SC2154,SC2034

run_in "$image_ref" /test/Probe.java
expect_line 'runs as user 65532' 'PASS runs as: uid 65532'
expect 'is Java 25' 'PASS Java: 25.'
expect_line 'formats German dates (locale data)' \
  'PASS cultures: Dienstag, 6. Oktober 2026'
expect_line 'converts time zones' 'PASS time zones: 07:00'
expect 'compresses with gzip and back' 'PASS gzip compression: 4096 -> '
expect_line 'HTTPS to github.com works with the CA bundle' \
  'PASS HTTPS to github.com: HTTP 200'
# MD5 and SHA-256 of the single byte 1, known answers.
md5_1=55a54008ad1ba589aa210d2629c1df41
sha256_1=4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a
expect_line 'Java serves MD5 (not the FIPS OpenSSL)' "ALLOWED MD5: $md5_1"
expect_line 'Java serves 3DES (not the FIPS OpenSSL)' \
  'ALLOWED 3DES encryption: 8 bytes'
expect_line 'Java generates RSA-1024 keys (not the FIPS OpenSSL)' \
  'ALLOWED RSA-1024 key generation: 1024-bit key'
expect_line 'Java generates RSA-2048 keys' \
  'ALLOWED RSA-2048 key generation: 2048-bit key'
expect_line 'SHA-256 works' "ALLOWED SHA-256: $sha256_1"

end_of_test
