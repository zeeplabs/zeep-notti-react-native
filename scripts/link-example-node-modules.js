#!/usr/bin/env node
// pnpm hoists dependencies to the workspace root's node_modules; CocoaPods'
// Podfile and Gradle's react-native-gradle-plugin both resolve REACT_NATIVE_PATH
// relative to `example/`, so `example/node_modules` needs to exist and point at
// the root's. Not something `pnpm install` creates on its own for a
// single-package workspace - runs after every install (postinstall) so a
// fresh checkout (CI included) gets it too, not just a machine it was
// created on by hand before.
const fs = require('fs');
const path = require('path');

const target = '../node_modules';
const linkPath = path.join(__dirname, '..', 'example', 'node_modules');

const stat = fs.lstatSync(linkPath, { throwIfNoEntry: false });
if (stat) {
  if (stat.isSymbolicLink() && fs.readlinkSync(linkPath) === target) {
    process.exit(0);
  }
  fs.rmSync(linkPath, { recursive: true, force: true });
}

fs.symlinkSync(target, linkPath, 'dir');
