// The patches this page names, what the tour plays through one of them, and the only
// place any of it lives.
//
// Two patches are load-bearing. The tutorial patch is the one the introduction teaches,
// and the tour names its nodes and one of its controls by id. The default patch is what a
// returning visitor opens into when they saved nothing, and it has to play on its own.
//
// That second requirement came from watching returns: the tutorial patch sounds only
// while a key is held — the tour plays it for a first-time visitor, and then lets go.
// Somebody who came back, pressed Start and heard nothing had no way to know the page was
// working, so the default a return opens into is a patch with a clock in it.
//
// All of it is checked by verify-onboarding.mjs, which imports this module rather than a
// copy of it; app.js cannot be imported without a document, and a check that restates
// the thing it is checking passes forever.

/** What the introduction teaches. Played, not self-playing: the tour plays it. */
export const TUTORIAL_PATCH = '../examples/patches/first-synth.json';

/**
 * What the tour plays through the tutorial patch: a repeating chord arpeggio, Am, F, C
 * and G, one rising eighth-note arpeggio each — the same four chords the self-playing
 * default walks, so the page has one sound however it is entered. It used to hold a
 * single middle C, which was enough for the cutoff to have something to change and not
 * enough for anybody to call it a demo. MIDI note numbers; the page plays them like a
 * keyboard player would, from the main thread.
 */
export const TOUR_ARPEGGIO = {
    bpm: 112,
    gate: 0.7,
    notes: [57, 60, 64, 69, 53, 57, 60, 65, 60, 64, 67, 72, 55, 59, 62, 67],
};

/** What a returning visitor with nothing saved opens into. Plays without a key. */
export const DEFAULT_PATCH = '../examples/patches/chord-arpeggio.json';

// A short, curated menu rather than all 280. The Godot editor scans the corpus, which is
// the right answer for an editor; a first visit wants a few good ones and a way out.
export const EXAMPLES = [
    { label: 'First Synth', path: TUTORIAL_PATCH },
    { label: 'Chord Arpeggio', path: DEFAULT_PATCH },
    { label: 'Plucked String', path: '../examples/patches/plucked-string.json' },
    { label: 'Poly Five', path: '../examples/patches/synths/poly-five.json' },
    { label: 'Acid Bass', path: '../examples/patches/synths/acid-bass.json' },
    { label: 'Warehouse', path: '../examples/patches/warehouse.json' },
    { label: '808 Kit', path: '../examples/patches/drums/kit.json' },
];
