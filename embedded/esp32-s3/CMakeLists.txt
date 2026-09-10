# SoundGraph generic ESP-IDF firmware.
#
#   idf.py build flash monitor                                    # DevKitC + PCM5102 (S3)
#   idf.py -DSG_BOARD=esp32-s3-audio-board build                  # another S3 board
#   idf.py -DSG_BOARD=esp32-p4-wifi6-touch-lcd-7b -B build-p4 build   # a P4 board
#
# The board profile names the chip. `target` in board.json is the processor this firmware
# is built for, so the board is the only thing a build has to be told; `idf.py set-target`
# is neither needed nor honoured. A build directory belongs to one target — the second
# form above uses its own so the S3 and P4 builds coexist rather than clobber each other.
cmake_minimum_required(VERSION 3.19)

set(SG_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)

if(NOT DEFINED SG_BOARD)
    set(SG_BOARD "esp32-s3-devkitc-pcm5102")
endif()
file(GLOB_RECURSE SG_BOARD_JSON ${SG_ROOT}/embedded/boards/*/${SG_BOARD}/board.json)
if(SG_BOARD_JSON STREQUAL "")
    message(FATAL_ERROR "No board profile named '${SG_BOARD}' under embedded/boards/")
endif()

file(READ ${SG_BOARD_JSON} SG_BOARD_MANIFEST)
string(JSON SG_BOARD_TARGET GET "${SG_BOARD_MANIFEST}" target)
# esp32-s3 -> esp32s3: the manifest spells targets the way the docs do, IDF the way
# its toolchain files do.
string(REPLACE "-" "" SG_IDF_TARGET "${SG_BOARD_TARGET}")

if(DEFINED CACHE{IDF_TARGET} AND NOT "$CACHE{IDF_TARGET}" STREQUAL "${SG_IDF_TARGET}")
    message(FATAL_ERROR
        "This build directory was configured for $CACHE{IDF_TARGET} and the board "
        "'${SG_BOARD}' is a ${SG_IDF_TARGET}. Use a separate build directory: "
        "idf.py -DSG_BOARD=${SG_BOARD} -B build-${SG_IDF_TARGET} build")
endif()
set(IDF_TARGET ${SG_IDF_TARGET})

# One sdkconfig.defaults for every chip, plus one file of what differs per chip. The
# generated sdkconfig lives with the build it belongs to rather than in the project root,
# so two targets do not fight over one file — except on the S3, where it stays where it
# has always been so that the build already on the bench for the show is not regenerated
# by a change made for a different chip. Unify after Knobcon.
set(SDKCONFIG_DEFAULTS "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.defaults")
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.defaults.${SG_IDF_TARGET}")
    list(APPEND SDKCONFIG_DEFAULTS "${CMAKE_CURRENT_LIST_DIR}/sdkconfig.defaults.${SG_IDF_TARGET}")
endif()
if(NOT SG_IDF_TARGET STREQUAL "esp32s3")
    set(SDKCONFIG "${CMAKE_BINARY_DIR}/sdkconfig")
endif()

set(EXTRA_COMPONENT_DIRS ${CMAKE_CURRENT_LIST_DIR}/../components)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(soundgraph-${SG_IDF_TARGET})
