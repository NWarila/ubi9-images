// A local package for images/nodejs-24-toolset/test: packed with npm in the
// toolset and installed into the app, which runs on the runtime.
'use strict';
const crypto = require('crypto');

exports.sha256 = (text) =>
  crypto.createHash('sha256').update(text).digest('hex');
