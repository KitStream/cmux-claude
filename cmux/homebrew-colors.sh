#!/usr/bin/env bash
# Recolour THIS terminal to Terminal.app's Homebrew profile (green on black), using the
# xterm colour OSC sequences Ghostty honours per surface. Values are the Homebrew theme
# that ships with cmux's Ghostty. Undo with:  printf '\e]104\a\e]110\a\e]111\a\e]112\a'
osc() { printf '\033]%s\007' "$1"; }
osc '4;0;rgb:00/00/00'; osc '4;1;rgb:99/00/00'; osc '4;2;rgb:00/a6/00'; osc '4;3;rgb:99/99/00'
osc '4;4;rgb:5c/5c/ff'; osc '4;5;rgb:b2/00/b2'; osc '4;6;rgb:00/a6/b2'; osc '4;7;rgb:bf/bf/bf'
osc '4;8;rgb:66/66/66'; osc '4;9;rgb:e5/00/00'; osc '4;10;rgb:00/d9/00'; osc '4;11;rgb:e5/e5/00'
osc '4;12;rgb:7f/7f/ff'; osc '4;13;rgb:e5/00/e5'; osc '4;14;rgb:00/e5/e5'; osc '4;15;rgb:e5/e5/e5'
# Blue (4) and bright blue (12) are lifted from Homebrew's #0d0dbf / #0000ff: claude draws the
# selected-row marker of its pickers in blue, and Homebrew's blue is invisible on black.
osc '10;rgb:00/ff/00'    # foreground
osc '11;rgb:00/00/00'    # background
osc '12;rgb:23/ff/18'    # cursor
