// Private bounded Windows transport types, shared with the production worker test.
constexpr size_t kSiglusLookupGlyphEventSlots = 512;
constexpr size_t kSiglusLookupTextSlots = 4;
constexpr size_t kSiglusLookupClickEventSlots = 4;
constexpr size_t kSiglusLookupMaxTextUnits =
    fushi_voice_hook::kSiglusLookupTextCapacity;
constexpr ULONGLONG kSiglusLookupClickTargetMaxAgeMs = 64;
constexpr ULONGLONG kSiglusLookupDuplicateHitWindowMs = 250;

struct SiglusLookupGlyphEvent {
  volatile LONG64 seq = 0;
  uint16_t code_unit = 0;
  uint16_t reserved = 0;
  int32_t design_x = 0;
  int32_t design_y = 0;
  int32_t extent = 0;
};

using SiglusLookupTextSnapshot = fushi_voice_hook::SiglusLookupTextSnapshot;

struct SiglusLookupPayload {
  fushi_voice_hook::SiglusLookupEngineView engine_view;
  fushi_voice_hook::SiglusLookupTextIdentity text_identity;
  uint64_t geometry_generation = 0;
  uint64_t snapshot_epoch = 0;
  uint32_t text_units = 0;
  uint32_t char_index = 0;
  fushi_voice_hook::SiglusLookupRect rect;
  uintptr_t game_window = 0;
  int32_t client_screen_x = 0;
  int32_t client_screen_y = 0;
  int32_t client_width = 0;
  int32_t client_height = 0;
  wchar_t text[kSiglusLookupMaxTextUnits] = {};
};

struct SiglusLookupClickTarget {
  fushi_voice_hook::SiglusLookupEngineView engine_view;
  fushi_voice_hook::SiglusLookupTextIdentity text_identity;
  volatile LONG64 seq = 0;
  uint32_t valid = 0;
  ULONGLONG published_tick = 0;
  uintptr_t game_window = 0;
  int32_t client_screen_x = 0;
  int32_t client_screen_y = 0;
  int32_t client_width = 0;
  int32_t client_height = 0;
  uint64_t geometry_generation = 0;
  uint32_t text_units = 0;
  wchar_t text[kSiglusLookupMaxTextUnits] = {};
  fushi_voice_hook::SiglusLookupGeometry geometry;
  uint64_t snapshot_epoch = 0;
};

struct SiglusLookupClickEvent {
  volatile LONG64 seq = 0;
  SiglusLookupPayload payload;
};
