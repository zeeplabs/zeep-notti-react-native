#!/usr/bin/env node
// Extracts one version's section body from CHANGELOG.md (as written by
// @release-it/conventional-changelog's Angular preset) so CI can use it
// verbatim as the GitHub Release body - instead of GitHub's PR-based
// auto-generated notes.
'use strict';

const fs = require('node:fs');

const version = process.argv[2];
if (!version) {
  console.error('Usage: extract-changelog-section.js <version>');
  process.exit(1);
}

const lines = fs.readFileSync('CHANGELOG.md', 'utf8').split('\n');

// Angular preset headers: "# 1.0.0 (date)" for the very first release,
// "## [1.2.0](compare-url) (date)" for every one after.
const headingRe = /^(#{1,2})\s+(?:\[)?v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)/;

let start = -1;
for (let i = 0; i < lines.length; i++) {
  const match = lines[i].match(headingRe);
  if (match && match[2] === version) {
    start = i;
    break;
  }
}

if (start === -1) {
  console.error(`Version ${version} not found in CHANGELOG.md`);
  process.exit(1);
}

let end = lines.length;
for (let i = start + 1; i < lines.length; i++) {
  if (/^#{1,2}\s/.test(lines[i])) {
    end = i;
    break;
  }
}

process.stdout.write(
  lines
    .slice(start + 1, end)
    .join('\n')
    .trim() + '\n'
);
