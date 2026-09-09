// One patch per sfxr generator, with six rolls of that generator as its presets. See
// to_shelf.cpp for how the six graphs become one.
#ifndef SOUNDGRAPH_SFXR_TO_SHELF_H
#define SOUNDGRAPH_SFXR_TO_SHELF_H

#include <string>
#include <vector>

#include "sfxr_reference.h"

namespace sfxr_map {

struct ShelfSeed {
    std::string name;    // the corpus case name, e.g. "pickup-coin-3"
    unsigned int seed;   // what generate() was given
    sfxr_reference::Params params;
};

// Returns the patch as JSON text: the union of the seeds' graphs, a control for every
// parameter the generator rolls, and one preset per seed.
std::string to_shelf(const std::string& preset_name, const std::vector<ShelfSeed>& seeds);

}  // namespace sfxr_map

#endif
