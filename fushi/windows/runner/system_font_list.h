#ifndef RUNNER_SYSTEM_FONT_LIST_H_
#define RUNNER_SYSTEM_FONT_LIST_H_

#include <flutter/binary_messenger.h>

#include <string>
#include <vector>

namespace fushi {

// One installed font family as seen by DirectWrite's system collection.
struct SystemFontFamily {
  // UTF-8 family name (en-us localized name when present, otherwise the first
  // localized name) — the name Skia's DirectWrite font manager resolves.
  std::string family;
  // Whether the family's regular face maps both U+3042 (あ) and U+6F22 (漢).
  bool supports_japanese = false;
};

// Enumerates the DirectWrite system font collection. Skips vertical-alias
// families (names starting with '@'), dedupes case-insensitively and sorts by
// family name (case-insensitive). Returns an empty list on failure.
std::vector<SystemFontFamily> EnumerateSystemFontFamilies();

}  // namespace fushi

// Registers the `app.fushi.reader/fonts` method channel (`listSystemFonts`)
// on [messenger]. The channel object lives for the rest of the process; call
// once from the main window's OnCreate.
void RegisterSystemFontListChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SYSTEM_FONT_LIST_H_
