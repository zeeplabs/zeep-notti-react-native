#!/usr/bin/env node
// Rewrites src/version.ts from package.json. Runs in the release-it
// `after:bump` hook so the published bundle carries the released version.
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const { version } = require(path.join(root, 'package.json'));
if (typeof version !== 'string' || version === '') {
  throw new Error('package.json has no version');
}
const target = path.join(root, 'src', 'version.ts');
const source = fs.readFileSync(target, 'utf8');
const next = source.replace(
  /export const SDK_VERSION = '[^']*';/,
  `export const SDK_VERSION = '${version}';`
);
if (next === source && !source.includes(`'${version}'`)) {
  throw new Error('SDK_VERSION line not found in src/version.ts');
}
fs.writeFileSync(target, next);
