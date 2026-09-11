#include "kiosk.h"

#include "board_config.h"

#if !SG_DISPLAY_PRESENT

bool kiosk_available() { return false; }
const char* kiosk_show(const char*) { return ""; }
const char* kiosk_current() { return ""; }
int kiosk_screen_count() { return 0; }
const char* kiosk_screen_name(int) { return ""; }

#else

#include <cstring>

#include "display.h"

namespace {

// ---- palette --------------------------------------------------------------------------
// One dark ground and one green accent, the phosphor pairing the instrument face already
// uses, so the kiosk and the editor's cables read as the same product. White for the
// things a reader's eye should land on first, a dim slate for the supporting copy.
const uint32_t kGround   = display_rgb(6, 8, 10);
const uint32_t kPanel    = display_rgb(14, 20, 18);
const uint32_t kBorder   = display_rgb(30, 54, 44);
const uint32_t kAccent   = display_rgb(80, 255, 170);
const uint32_t kInk      = display_rgb(230, 245, 238);
const uint32_t kInkDim   = display_rgb(120, 150, 138);

constexpr int kMargin = 28;   // reserve the bezel and coarse touch calibration

int W() { return display_width(); }
int H() { return display_height(); }

// ---- text ----------------------------------------------------------------------------
// The panel's font is 5x7, so a glyph at scale s is 6*s wide including its trailing
// column and 7*s tall. These centre and right-align without every call site redoing the
// arithmetic.
void text_center(int y, const char* s, int scale, uint32_t colour) {
    display_text((W() - display_text_width(s, scale)) / 2, y, s, scale, colour);
}
void text_at(int x, int y, const char* s, int scale, uint32_t colour) {
    display_text(x, y, s, scale, colour);
}

// ---- chrome --------------------------------------------------------------------------
// Drawn on every interior screen in the same place, so a visitor always knows where home
// is and whether sound is live. The attract screen gets only the wordmark.
void chrome(bool interior) {
    // Top-left wordmark. A label on attract, the way home on every interior screen.
    text_at(kMargin, kMargin, "MUTANT FACTORY", 2, interior ? kInk : kInkDim);
    if (interior) {
        const char* home = "HOME";
        text_at(W() - kMargin - display_text_width(home, 2), kMargin, home, 2, kAccent);
        // Audio is not wired on this board yet, so the state is the honest one.
        const char* snd = "SOUND OFF";
        text_at(W() - kMargin - display_text_width(snd, 2), kMargin + 22, snd, 2, kInkDim);
    }
}

void orientation(const char* line) {
    text_center(H() - kMargin - 14, line, 2, kInkDim);
}

// ---- primitives ----------------------------------------------------------------------
// A framed panel: a filled body with a one-pixel border, drawn as four thin rects so a
// single primitive stays cheap and nothing has to know how to stroke a rectangle.
void frame(int x, int y, int w, int h, uint32_t fill, uint32_t border) {
    display_rect(x, y, w, h, fill);
    display_rect(x, y, w, 2, border);
    display_rect(x, y + h - 2, w, 2, border);
    display_rect(x, y, 2, h, border);
    display_rect(x + w - 2, y, 2, h, border);
}

// A tap target: a framed panel with a bold label centred in it, and an optional dim
// sub-label beneath. The label is always text — open, muted, selected are words here,
// never a colour a reader has to decode.
void button(int x, int y, int w, int h, const char* label, const char* sub, bool lit) {
    frame(x, y, w, h, lit ? display_dim(kAccent, 18) : kPanel, lit ? kAccent : kBorder);
    const int label_scale = 3;
    const int lh = 7 * label_scale;
    if (sub != nullptr && sub[0] != '\0') {
        display_text(x + (w - display_text_width(label, label_scale)) / 2,
                     y + h / 2 - lh, label, label_scale, lit ? kAccent : kInk);
        display_text(x + (w - display_text_width(sub, 2)) / 2,
                     y + h / 2 + 4, sub, 2, kInkDim);
    } else {
        display_text(x + (w - display_text_width(label, label_scale)) / 2,
                     y + (h - lh) / 2, label, label_scale, lit ? kAccent : kInk);
    }
}

// A labeled node with a cable running to the next one — the editor's own vocabulary,
// drawn with the glow line the rack uses so the kiosk's diagram and the editor's patch
// look like the same thing. Returns the x where the node ends, so a caller can chain.
int node(int x, int cy, int w, int h, const char* label, bool lit) {
    frame(x, cy - h / 2, w, h, lit ? display_dim(kAccent, 22) : kPanel,
          lit ? kAccent : kBorder);
    display_text(x + (w - display_text_width(label, 2)) / 2, cy - 7, label, 2,
                 lit ? kAccent : kInk);
    return x + w;
}

void cable(int x0, int cy, int x1, uint32_t colour) {
    display_glow_line(static_cast<float>(x0), static_cast<float>(cy),
                      static_cast<float>(x1), static_cast<float>(cy),
                      3.0f, 5.0f, 60, colour);
}

// A left-aligned column of body copy, one string per line, wrapped by the caller into
// lines short enough to fit. Returns the y below the block.
int paragraph(int x, int y, const char* const* lines, int count, int scale, int leading,
              uint32_t colour) {
    for (int i = 0; i < count; ++i) {
        text_at(x, y, lines[i], scale, colour);
        y += 7 * scale + leading;
    }
    return y;
}

// ======================================================================================
//  Screens
// ======================================================================================

// Screen 00 — attract. Legible as a still: no motion is required to read it, which is
// what the script asks for and what a photograph can check.
void draw_attract() {
    display_clear(kGround);
    chrome(false);
    text_center(96, "MUTANT FACTORY / SOUNDGRAPH", 2, kInkDim);
    text_center(150, "WHAT IS EVERYTHING?", 7, kInk);
    text_center(250, "ONE PATCH. A LOT OF PLACES TO RUN IT.", 3, kInkDim);

    // The three-block signal the attract loop animates around, drawn as a still.
    const int cy = 360, bw = 210, bh = 74, gap = 60;
    const int total = bw * 3 + gap * 2;
    int x = (W() - total) / 2;
    x = node(x, cy, bw, bh, "OSCILLATOR", true);
    cable(x, cy, x + gap, kAccent);
    x = node(x + gap, cy, bw, bh, "FILTER", false);
    cable(x, cy, x + gap, kAccent);
    node(x + gap, cy, bw, bh, "OUTPUT", false);

    button(W() / 2 - 130, 452, 260, 66, "SHOW ME", nullptr, true);
    orientation("SOUND STARTS ONLY WHEN YOU ASK FOR IT.");
    display_present();
}

// Screen 01 — what is everything. The two-by-three menu of the whole kiosk.
void draw_home() {
    display_clear(kGround);
    chrome(true);
    text_center(90, "PICK A PART.", 5, kInk);

    struct Cell { const char* label; const char* sub; };
    static const Cell cells[6] = {
        {"SOUNDGRAPH",       "BUILD SOUND FROM PARTS"},
        {"THIS BOARD",       "THE CHIP AND ITS COUSINS"},
        {"FOLLOW THE SIGNAL","HOW A PATCH BECOMES SOUND"},
        {"WHERE IT RUNS",    "NOT TRAPPED IN ONE MACHINE"},
        {"LIVE LABS",        "BUILD AND ASK IN PUBLIC"},
        {"MUTANT FACTORY",   "OPEN TO MUTATION"},
    };
    const int cols = 2, rows = 3;
    const int gx = 24, gy = 18;
    const int top = 168, bottom = H() - kMargin - 30;
    const int gw = (W() - 2 * kMargin - (cols - 1) * gx) / cols;
    const int gh = (bottom - top - (rows - 1) * gy) / rows;
    for (int i = 0; i < 6; ++i) {
        const int r = i / cols, c = i % cols;
        const int x = kMargin + c * (gw + gx);
        const int y = top + r * (gh + gy);
        button(x, y, gw, gh, cells[i].label, cells[i].sub, false);
    }
    orientation("TAP ANYTHING. YOU CANNOT BREAK IT.");
    display_present();
}

// A shared layout for the copy-and-buttons explainer screens: a tag, a headline, a body
// block, and a row of up to three actions. One place so every interior screen sits on
// the same grid.
void explainer(const char* tag, const char* headline, const char* const* body,
               int body_lines, const char* a, const char* b, const char* c) {
    display_clear(kGround);
    chrome(true);
    text_at(kMargin, 92, tag, 2, kAccent);
    text_at(kMargin, 122, headline, 5, kInk);
    paragraph(kMargin, 210, body, body_lines, 3, 14, kInkDim);

    const char* actions[3] = {a, b, c};
    int n = 0;
    for (int i = 0; i < 3; ++i) if (actions[i] != nullptr) ++n;
    if (n > 0) {
        const int bw = 300, bh = 62, gap = 24;
        const int total = bw * n + gap * (n - 1);
        int x = (W() - total) / 2;
        const int y = H() - kMargin - bh - 20;
        for (int i = 0; i < 3; ++i) {
            if (actions[i] == nullptr) continue;
            button(x, y, bw, bh, actions[i], nullptr, i == 0);
            x += bw + gap;
        }
    }
    display_present();
}

void draw_soundgraph() {
    static const char* body[] = {
        "SOUNDGRAPH IS A VISUAL WAY TO BUILD",
        "INSTRUMENTS AND EFFECTS FROM",
        "CONNECTED PARTS.",
        "",
        "THE EDITOR CAN CHANGE. THE HARDWARE",
        "CAN CHANGE. THE GRAPH REMAINS THE THING.",
    };
    explainer("01 / SOUNDGRAPH", "THE GRAPH IS THE INSTRUMENT.", body, 6,
              "HEAR ONE", "FOLLOW THE SIGNAL", nullptr);
}

void draw_board() {
    static const char* body[] = {
        "YOU ARE TOUCHING AN ESP32-P4: A SMALL",
        "BOARD RUNNING THIS PATCH RIGHT NOW,",
        "DISPLAY AND SOUND FROM ONE CHIP.",
        "",
        "THE SAME PATCH RUNS ON THE AXOLOTI CORE,",
        "AND WITH NO BOARD AT ALL IN A BROWSER",
        "OR THE DESKTOP APP.",
    };
    explainer("02 / HARDWARE", "ONE OF THE HOMES.", body, 7,
              "WHERE IT RUNS", "LIVE LABS", nullptr);
}

// Screen 30 — follow the signal. The four-node patch, tappable in the finished build,
// drawn here as the still diagram the whole screen is about.
void draw_signal() {
    display_clear(kGround);
    chrome(true);
    text_at(kMargin, 92, "03 / SIGNAL PATH", 2, kAccent);
    text_at(kMargin, 122, "FOLLOW THE SIGNAL.", 5, kInk);
    text_at(kMargin, 200, "TAP ANY PART TO ASK WHAT IT DOES.", 2, kInkDim);

    const int cy = 320, bw = 190, bh = 80, gap = 56;
    const int total = bw * 4 + gap * 3;
    int x = (W() - total) / 2;
    const char* names[4] = {"NOTE", "OSCILLATOR", "FILTER", "OUTPUT"};
    for (int i = 0; i < 4; ++i) {
        x = node(x, cy, bw, bh, names[i], i == 0);
        if (i < 3) { cable(x, cy, x + gap, kAccent); x += gap; }
    }
    button(W() / 2 - 150, 430, 300, 62, "PLAY THE PATCH", nullptr, true);
    orientation("EVERY PART IS A NODE. EVERY LINE IS A CABLE.");
    display_present();
}

void draw_where() {
    display_clear(kGround);
    chrome(true);
    text_at(kMargin, 92, "04 / PORTABILITY", 2, kAccent);
    text_at(kMargin, 122, "BUILD THE IDEA ONCE.", 5, kInk);
    static const char* body[] = {
        "THE SAME GRAPH MOVES BETWEEN HOSTS AND",
        "HARDWARE WITHOUT REBUILDING THE IDEA.",
        "THE BOARD UNDER THIS SCREEN IS ONE OF THEM.",
    };
    paragraph(kMargin, 200, body, 3, 3, 14, kInkDim);

    static const char* chips[6] = {
        "WEB", "DESKTOP", "GODOT", "AUDIO PLUGIN", "ESP32-S3 / P4", "AXOLOTI CORE",
    };
    const int cols = 3, rows = 2, gx = 22, gy = 18;
    const int top = 330, bh = 70;
    const int gw = (W() - 2 * kMargin - (cols - 1) * gx) / cols;
    for (int i = 0; i < 6; ++i) {
        const int r = i / cols, c = i % cols;
        const int x = kMargin + c * (gw + gx);
        const int y = top + r * (bh + gy);
        button(x, y, gw, bh, chips[i], nullptr, i == 4);   // light the board we are on
    }
    orientation("SAME GRAPH. DIFFERENT PLACE TO RUN IT.");
    display_present();
}

void draw_labs() {
    static const char* body[] = {
        "LIVE LABS COMBINE ANNOUNCEMENTS, DEMOS,",
        "AND REAL TROUBLESHOOTING.",
        "",
        "AXOLOTI CORE PILOT PARTICIPANTS GET A KIT,",
        "FOUR LIVE SESSIONS, AND HANDS-ON HELP.",
        "",
        "TWENTY KITS. TWO SMALL COHORTS.",
    };
    explainer("05 / BUILD IT LIVE", "LEARN IT IN PUBLIC.", body, 7,
              "PILOT DETAILS", "HOW SUPPORT WORKS", nullptr);
}

void draw_factory() {
    static const char* body[] = {
        "MUTANT FACTORY BUILDS FREE, OPEN-SOURCE",
        "GAME TRANSFORMATIONS AND CREATIVE TOOLS.",
        "",
        "SOUNDGRAPH - SOUND FROM A PORTABLE GRAPH.",
        "RAVES OF MUD - CAVES OF QUD IN A NEW VIEW.",
        "GET IN LOSER - PIXELS, VOXELS, AND SOUND.",
    };
    explainer("06 / MUTANT FACTORY", "OPEN AT THE SEAMS.", body, 6,
              "SOUNDGRAPH", "RAVES OF MUD", "GET IN LOSER");
}

// ---- the roster ----------------------------------------------------------------------
struct Screen {
    const char* name;
    void (*draw)();
};

const Screen kScreens[] = {
    {"attract",    draw_attract},
    {"home",       draw_home},
    {"soundgraph", draw_soundgraph},
    {"board",      draw_board},
    {"signal",     draw_signal},
    {"where",      draw_where},
    {"labs",       draw_labs},
    {"factory",    draw_factory},
};
constexpr int kScreenCount = sizeof(kScreens) / sizeof(kScreens[0]);

int g_current = 0;

}  // namespace

bool kiosk_available() { return display_available(); }

const char* kiosk_show(const char* name) {
    int found = 0;   // default to attract
    if (name != nullptr && name[0] != '\0') {
        for (int i = 0; i < kScreenCount; ++i) {
            if (std::strcmp(name, kScreens[i].name) == 0) { found = i; break; }
        }
    }
    g_current = found;
    kScreens[found].draw();
    return kScreens[found].name;
}

const char* kiosk_current() { return kScreens[g_current].name; }

int kiosk_screen_count() { return kScreenCount; }

const char* kiosk_screen_name(int index) {
    if (index < 0 || index >= kScreenCount) return "";
    return kScreens[index].name;
}

#endif  // SG_DISPLAY_PRESENT
