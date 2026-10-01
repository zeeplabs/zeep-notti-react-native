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

const generatedSection = lines
  .slice(start + 1, end)
  .join('\n')
  .trim();

// M4 (pre-release review round 3): `@release-it/conventional-changelog`
// always inserts the new version's generated section right after the
// `# Changelog` line, ahead of this file's static preamble and the manual
// `## [Unreleased]` section below it. That manual section is where
// breaking-change / upgrade notes get hand-written ahead of a release (see
// the "Breaking / attention when upgrading" entries) - without this, those
// notes never reach the GitHub Release body, no matter how far down the
// file they end up sitting after repeated releases. Appended verbatim, not
// merged by heading, since `[Unreleased]` is never renamed to the version
// number - matching this file's own header's "do not hand-edit past
// entries" rule by leaving the generated section untouched.
let unreleasedSection = '';
for (let i = 0; i < lines.length; i++) {
  if (/^##\s+\[Unreleased\]/i.test(lines[i])) {
    let unreleasedEnd = lines.length;
    for (let j = i + 1; j < lines.length; j++) {
      if (/^#{1,2}\s/.test(lines[j])) {
        unreleasedEnd = j;
        break;
      }
    }
    unreleasedSection = lines
      .slice(i + 1, unreleasedEnd)
      .join('\n')
      .trim();
    break;
  }
}

const sections = [generatedSection];
if (unreleasedSection) {
  sections.push(
    '### Notes carried from CHANGELOG.md\'s "Unreleased" section\n\n' +
      unreleasedSection
  );
}

process.stdout.write(sections.join('\n\n') + '\n');
