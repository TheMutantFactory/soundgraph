#!/usr/bin/env node
// Stamps the build and exports the Godot editor as a Windows application, in that order.
//
//   node tools/export-desktop.mjs [--godot <path>] [--out <dir>]
//
// The desktop twin of export-web.mjs, for the same reason that one exists: an export
// without a fresh stamp carries whatever stamp was lying around, which is a build
// claiming to be a different build. The preset ("Windows Desktop" in export_presets.cfg)
// embeds the pack in the executable and Godot puts the extension DLL beside it, so the
// output directory is the application: zip it and it runs.
//
// Godot is found the way export-web.mjs finds it, and that recipe is imported rather
// than copied so the two cannot drift.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const argument = (flag, fallback) => {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : fallback;
};

const NAMES = [
  'godot',
  'godot4',
  'Godot_v4.7.1-stable_win64_console.exe',
  'Godot_v4.7.1-stable_win64.exe',
];
const KNOWN = [
  'C:/Users/danie/Downloads/gofo/Godot_v4.7.1-stable_win64.exe',
  'C:/Users/danie/Downloads/gofo',
];

function binaryAt(candidate) {
  if (!existsSync(candidate)) return null;
  if (!statSync(candidate).isDirectory()) return candidate;
  for (const name of NAMES) {
    const inside = join(candidate, name);
    if (existsSync(inside) && !statSync(inside).isDirectory()) return inside;
  }
  return null;
}

function gitConfigGodot() {
  try {
    return execFileSync('git', ['config', 'soundgraph.godot'], { cwd: root, encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

function resolveGodot() {
  const explicit = [argument('--godot', null), process.env.SOUNDGRAPH_GODOT, gitConfigGodot()]
    .filter(Boolean);
  for (const candidate of explicit) {
    const found = binaryAt(candidate);
    if (found !== null) return found;
    console.error(`Godot was not found at ${candidate}.`);
    process.exit(1);
  }
  for (const name of NAMES) {
    try {
      execFileSync(name, ['--version'], { stdio: 'ignore' });
      return name;
    } catch { /* not on the PATH under this name */ }
  }
  for (const candidate of KNOWN) {
    const found = binaryAt(candidate);
    if (found !== null) return found;
  }
  return null;
}

const godot = resolveGodot();
if (godot === null) {
  console.error('Could not find Godot.\n'
    + '  Set SOUNDGRAPH_GODOT to the binary, pass --godot <path>, or git config soundgraph.godot.\n'
    + `  Tried on the PATH: ${NAMES.join(', ')}`);
  process.exit(1);
}

const out = resolve(argument('--out', join(root, 'build-godot-desktop')), 'SoundGraphEditor.exe');
mkdirSync(dirname(out), { recursive: true });

execFileSync(process.execPath, [join(root, 'tools', 'stamp-build.mjs'),
  '--target', 'desktop'], { stdio: 'inherit' });

try {
  execFileSync(godot, ['--headless', '--path', join(root, 'editor-godot'),
    '--export-release', 'Windows Desktop', out], { stdio: 'inherit' });
} catch (error) {
  console.error(`\nExport failed (${godot} exited ${error.status ?? 'abnormally'}).`);
  process.exit(1);
}
for (const required of [out, join(dirname(out), 'soundgraph_godot.dll')]) {
  if (!existsSync(required)) {
    console.error(`Export finished without ${required}: the application would not run.`);
    process.exit(1);
  }
}
console.log(`exported to ${out}`);
