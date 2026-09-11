// The event kiosk: a self-running explainer drawn on the panel.
//
// A separate surface from the instrument face. Where the face is knobs a player turns,
// the kiosk is a sequence of scripted screens a passer-by taps through — attract, a menu,
// and a handful of explainer screens. The script it renders is mutant-plan's
// display-kiosk.md; the copy lives in kiosk.cpp so the script can be edited in one place.
//
// Display-only for now. Touch and audio on the 7-inch P4 wait on the I2C power problem
// (see docs/known-issues.md), so screens are driven from the console — `kiosk <name>` —
// and verified with the bench camera, which is exactly what the display half needs to be
// built and checked without either.
#pragma once

// True when there is a panel to draw on.
bool kiosk_available();

// Switch to a named screen and draw it. An unknown or empty name draws the attract loop.
// Returns the canonical name of the screen actually shown.
const char* kiosk_show(const char* name);

// The screen currently shown.
const char* kiosk_current();

// The screen roster, for a console that wants to list what it can show.
int kiosk_screen_count();
const char* kiosk_screen_name(int index);
