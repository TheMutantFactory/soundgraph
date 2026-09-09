#!/usr/bin/env node
// Every preset of every sfxr shelf patch must render sample for sample as the corpus
// patch it came from.
//
// The shelf patches (examples/patches/sfxr, written by `sfxr-ref shelf`) are the union
// of six rolls' graphs, with switches so that a preset can take a part out of the sound
// exactly — a Mixer at 1 and 0, an arpeggio at 0 semitones, a repeat multiplied by 0.
// "Exactly" is a claim about floating point, and the only way to hold it is to render
// both graphs and compare the samples. A preset that merely sounded like its roll would
// pass a listener and hide the day the union graph quietly stopped being a union.
//
// For each preset: its values are written onto the controls' targets, the patch is
// rendered, `sfxr-ref patch` writes the single-roll patch for the same seed, that is
// rendered too, and the two must be identical. A silent render fails as well, so two
// silences cannot agree their way through.
//
//   node tools/sfxr-shelf-check.mjs [--dir examples/patches/sfxr]
//                                   [--render build/bin/sg-render] [--ref build/bin/sfxr-ref]
import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join, basename } from 'node:path';
import { tmpdir } from 'node:os';
import { readWav } from './compare-waveforms.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
};
const directory = option('--dir', 'examples/patches/sfxr');
const renderer = option('--render', 'build/bin/sg-render');
const referenceTool = option('--ref', 'build/bin/sfxr-ref');

// Long enough to hold the longest roll in the corpus (explosions run past a second) and
// short enough to keep the whole check under the test budget. What matters is that both
// renders are the same length; the tail of a shorter sound is silence in both.
const SECONDS = 1.5;
const SAMPLE_RATE = 44100;

function render(patchPath, wavPath) {
  execFileSync(renderer, [
    patchPath, wavPath,
    '--seconds', String(SECONDS), '--sample-rate', String(SAMPLE_RATE),
    // One note at frame zero, held throughout: the single rising edge every corpus
    // comparison uses (see tools/sfxr-report.mjs).
    '--notes', '60', '--gate', '1', '--float', '--quiet',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
}

function withPreset(patch, preset) {
  const copy = JSON.parse(JSON.stringify(patch));
  const nodes = new Map(copy.nodes.map((node) => [node.id, node]));
  for (const control of copy.controls ?? []) {
    if (!(control.id in preset.values)) {
      throw new Error(`preset ${preset.name} has no value for control ${control.id}`);
    }
    const node = nodes.get(control.target.node);
    if (!node) throw new Error(`control ${control.id} targets missing node ${control.target.node}`);
    node.parameters = node.parameters ?? {};
    node.parameters[control.target.parameter] = preset.values[control.id];
  }
  return copy;
}

const scratch = mkdtempSync(join(tmpdir(), 'sfxr-shelf-'));
let failures = 0;
let checked = 0;
try {
  const files = readdirSync(directory).filter((name) => name.endsWith('.json')).sort();
  if (files.length === 0) throw new Error(`no shelf patches in ${directory}`);
  for (const file of files) {
    const generator = basename(file, '.json');
    const patch = JSON.parse(readFileSync(join(directory, file), 'utf8'));
    const presets = patch.presets ?? [];
    if (presets.length !== 6) {
      console.log(`  FAIL ${generator}: ${presets.length} presets, expected 6`);
      failures += 1;
      continue;
    }
    for (const preset of presets) {
      const seedTag = (preset.tags ?? []).find((tag) => tag.startsWith('seed:'));
      if (!seedTag) {
        console.log(`  FAIL ${generator}/${preset.name}: no seed tag`);
        failures += 1;
        continue;
      }
      const seed = seedTag.slice('seed:'.length);
      const shelfPatch = join(scratch, `${preset.name}.shelf.json`);
      const shelfWav = join(scratch, `${preset.name}.shelf.wav`);
      const rollPatch = join(scratch, `${preset.name}.roll.json`);
      const rollWav = join(scratch, `${preset.name}.roll.wav`);
      try {
        writeFileSync(shelfPatch, JSON.stringify(withPreset(patch, preset)));
        execFileSync(referenceTool, [
          'patch', '--preset', generator, '--seed', seed, '--out', rollPatch,
        ], { stdio: ['ignore', 'ignore', 'pipe'] });
        render(shelfPatch, shelfWav);
        render(rollPatch, rollWav);
      } catch (error) {
        console.log(`  FAIL ${generator}/${preset.name}: ${String(error.message).trim()}`);
        failures += 1;
        continue;
      }
      const a = readWav(shelfWav);
      const b = readWav(rollWav);
      let worst = 0;
      let peak = 0;
      const frames = Math.min(a.samples.length, b.samples.length);
      for (let i = 0; i < frames; i += 1) {
        const difference = Math.abs(a.samples[i] - b.samples[i]);
        if (difference > worst) worst = difference;
        if (Math.abs(b.samples[i]) > peak) peak = Math.abs(b.samples[i]);
      }
      checked += 1;
      if (a.samples.length !== b.samples.length || worst > 0 || peak < 1e-4) {
        console.log(`  FAIL ${generator}/${preset.name}: worst difference ${worst}, `
          + `peak ${peak.toFixed(4)}, ${a.samples.length} vs ${b.samples.length} samples`);
        failures += 1;
      } else {
        console.log(`  ok   ${generator}/${preset.name} (peak ${peak.toFixed(4)})`);
      }
    }
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

if (failures > 0) {
  console.log(`${failures} of ${checked + failures} preset renders differ from their roll`);
  process.exit(1);
}
console.log(`${checked} presets across ${checked / 6} shelf patches render bit for bit as their rolls`);
