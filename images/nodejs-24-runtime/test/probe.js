// Probe for ubi9-nodejs-24-runtime, run by images/nodejs-24-runtime/test.
//
// Prints one line per check: "PASS <check>: <what it saw>" or
// "FAIL <check>: <error>", and for the FIPS configuration one
// "ALLOWED <operation>: <result>" or "REFUSED <operation>: <error>" line
// each. Exits 1 when any check failed.

'use strict';
const crypto = require('crypto');
const https = require('https');
const zlib = require('zlib');

function check(name, body) {
  try {
    console.log(`PASS ${name}: ${body()}`);
  } catch (error) {
    console.log(`FAIL ${name}: ${error.code || error.name}: ${error.message}`);
    process.exitCode = 1;
  }
}

function report(name, body) {
  try {
    console.log(`ALLOWED ${name}: ${body()}`);
  } catch (error) {
    const why = `${error.code || error.name}: ${error.message}`;
    console.log(`REFUSED ${name}: ${why}`);
  }
}

check('runs as', () => `uid ${process.getuid()}`);
// Node falls back to English without an error when a culture's data is
// missing, so report which culture was actually used.
check('ICU cultures', () => {
  const german = new Intl.DateTimeFormat('de-DE', {
    dateStyle: 'full', timeZone: 'UTC' });
  const used = german.resolvedOptions().locale;
  return `de-DE resolved to ${used}: ` + german.format(Date.UTC(2026, 9, 6));
});
check('time zones', () =>
  new Date(Date.UTC(2026, 6, 1, 12)).toLocaleTimeString('en-US', {
    timeZone: 'America/Chicago', hour12: false }));
check('gzip and Brotli compression', () => {
  const data = Buffer.from('x'.repeat(4096));
  const gzip = zlib.gunzipSync(zlib.gzipSync(data));
  const brotli = zlib.brotliDecompressSync(zlib.brotliCompressSync(data));
  if (!gzip.equals(data) || !brotli.equals(data)) throw new Error('mismatch');
  return 'round trip ok';
});

report('MD5', () => crypto.createHash('md5').update('x').digest('hex'));
report('SHA-256', () => crypto.createHash('sha256').update('x').digest('hex'));
report('3DES encryption', () => {
  crypto.createCipheriv('des-ede3-cbc', Buffer.alloc(24), Buffer.alloc(8));
  return 'cipher created';
});
report('AES-256-GCM encryption', () => {
  crypto.createCipheriv('aes-256-gcm', Buffer.alloc(32), Buffer.alloc(12));
  return 'cipher created';
});
report('RSA-1024 key generation', () => {
  crypto.generateKeyPairSync('rsa', { modulusLength: 1024 });
  return 'generated';
});
report('RSA-2048 key generation', () => {
  crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  return 'generated';
});

// The timeout only reports that the socket went quiet; destroying the
// request is what stops it.
const request = https.get('https://github.com/', { timeout: 20000 },
  (response) => {
    console.log(`PASS HTTPS to github.com: HTTP ${response.statusCode}`);
    response.resume();
  });
request.on('timeout', () => request.destroy(new Error('no answer in 20 s')));
request.on('error', (error) => {
  const why = `${error.code || error.name}: ${error.message}`;
  console.log(`FAIL HTTPS to github.com: ${why}`);
  process.exitCode = 1;
});
