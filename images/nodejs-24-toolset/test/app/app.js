// An app for images/nodejs-24-toolset/test: its dependency was packed and
// installed with npm in the toolset; it runs on ubi9-nodejs-24-runtime.
'use strict';
const { sha256 } = require('probe-lib');

console.log(`PASS npm-installed package works: sha256 ${sha256('x')}`);
