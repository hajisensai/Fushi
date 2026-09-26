#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "siglus_lookup.h"

namespace fushi_voice_hook {

// Choice (selection) text never reaches the message-text hook: the engine lays
// it out through its own caller of the shared glyph function, into the same
// message-window rows the previous dialogue line occupied. Measured on CLANNAD
// Steam: while the choice is shown the dialogue caller stops completely and
// the selection caller replays one complete, identically ordered pass per
// rendered frame. The line therefore comes from the glyphs themselves: a pass
// closes when its first glyph (unit and anchor) is laid out again.
struct SiglusSelectionPassBuilder {
  std::array<SiglusLookupGlyphCapture, kSiglusLookupMaxGlyphs> pass = {};
  size_t pass_count = 0;
  bool overflowed = false;
  std::array<char16_t, kSiglusLookupTextCapacity> line = {};
  size_t line_units = 0;

  void Reset() {
    pass_count = 0;
    overflowed = false;
    line_units = 0;
  }

  // Returns true when this glyph closed a complete pass and `line` now holds
  // its text. Rows split on the same rule the geometry builder uses, and are
  // joined with LF so the geometry builder treats them as exact row bounds.
  bool Push(char16_t unit, int32_t x, int32_t y, int32_t extent) {
    const SiglusLookupGlyphCapture glyph{unit, x, y, extent};
    const bool closes = pass_count != 0 && pass[0].code_unit == unit &&
                        pass[0].x == x && pass[0].y == y;
    bool produced = false;
    if (closes) {
      produced = !overflowed && BuildLine();
      pass_count = 0;
      overflowed = false;
    }
    if (pass_count == pass.size()) {
      // A pass longer than one geometry can hold is never a lookup line.
      overflowed = true;
    } else if (!overflowed) {
      pass[pass_count++] = glyph;
    }
    return produced;
  }

 private:
  bool BuildLine() {
    size_t units = 0;
    for (size_t index = 0; index < pass_count; ++index) {
      const bool row_break =
          index != 0 &&
          IsNextSiglusLookupVisualLine(pass[index - 1], pass[index], false);
      if (units + (row_break ? 2u : 1u) > line.size()) return false;
      if (row_break) line[units++] = u'\n';
      line[units++] = pass[index].code_unit;
    }
    line_units = units;
    return units != 0;
  }
};

}  // namespace fushi_voice_hook
