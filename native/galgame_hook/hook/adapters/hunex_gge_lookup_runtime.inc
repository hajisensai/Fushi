// HUNEX/GGE lookup runtime glue.
//
// This file intentionally owns no worker thread and contains no executable
// identity or address admission.  The adapter calls it from its existing
// worker/detour lifecycle after the exact structural scanner has admitted the
// renderer and input poller.
#if defined(_M_X64)

// Inclusion contract: voice_hook_ipc.h and hunex_gge_lookup_core.h must be
// included by dll_main.cpp before its anonymous namespace.  Adapter .inc files
// are expanded inside that namespace, so including a namespaced header here
// for the first time would accidentally create an anonymous nested namespace.

static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "HUNEX x64 lookup snapshots require lock-free 64-bit atomics");

constexpr uint32_t kHunexGgeLookupModelSlots = 3u;
constexpr uint32_t kHunexGgeLookupSubmitSlots = 8u;
constexpr uint32_t kHunexGgeShieldButtonMask = 0x7u;

struct HunexGgeLookupModelInput {
  uint64_t capture_epoch = 0u;
  uint64_t selected_text_seq = 0u;
  uint32_t render_thread_id = 0u;
  int32_t client_width = 0;
  int32_t client_height = 0;
  // Every logical_bounds rectangle in this projection must already be in game
  // client pixels.  The adapter owns the runtime-proved HUNEX viewport/scale
  // transform; this generic publication layer must not guess it.
  const fushi_voice_hook::hunex_lookup_core::RubyTextProjection
      *client_projection = nullptr;
};

struct HunexGgeLookupPointerSample {
  int32_t client_x = 0;
  int32_t client_y = 0;
  bool foreground_game_point = false;
};

struct HunexGgeLookupSampleResult {
  uint16_t filtered_state = 0u;
  bool submit_queued = false;
  bool consume = false;
  bool popup_transaction = false;
  bool thread_conflict = false;
};

struct HunexGgeLookupRuntime {
  struct AtomicGlyph {
    std::atomic<uint32_t> normalized_index{0u};
    std::atomic<uint32_t> utf16_width{0u};
    std::atomic<int32_t> x{0};
    std::atomic<int32_t> y{0};
    std::atomic<int32_t> width{0};
    std::atomic<int32_t> height{0};
  };

  struct AtomicModel {
    // Odd means a worker is replacing this slot.  Even non-zero is sealed.
    std::atomic<uint32_t> sequence{0u};
    std::atomic<uint64_t> capture_epoch{0u};
    std::atomic<uint64_t> selected_text_seq{0u};
    std::atomic<uint32_t> render_thread_id{0u};
    std::atomic<int32_t> client_width{0};
    std::atomic<int32_t> client_height{0};
    std::atomic<uint32_t> text_units{0u};
    std::array<std::atomic<uint32_t>,
               fushi_voice_hook::hunex_lookup_core::kTextCapacity>
        text = {};
    std::atomic<uint32_t> glyph_count{0u};
    std::array<std::atomic<uint32_t>,
               fushi_voice_hook::hunex_lookup_core::kGlyphCapacity>
        glyph_raw_index = {};
    std::array<AtomicGlyph, fushi_voice_hook::hunex_lookup_core::kGlyphCapacity>
        glyphs = {};
  };

  struct AtomicSubmit {
    std::atomic<uint64_t> sequence{0u};
    std::atomic<uint64_t> capture_epoch{0u};
    std::atomic<uint32_t> utf16_index{0u};
    std::atomic<uint32_t> utf16_width{0u};
    std::atomic<int32_t> x{0};
    std::atomic<int32_t> y{0};
    std::atomic<int32_t> width{0};
    std::atomic<int32_t> height{0};
  };

  struct TailState {
    uint32_t token = 0u;
    uint32_t drained_buttons = 0u;
    uint32_t acknowledged_token = 0u;
  };

  std::array<AtomicModel, kHunexGgeLookupModelSlots> models = {};
  std::atomic<uint32_t> published_model_slot{UINT32_MAX};
  std::atomic<uint32_t> next_model_slot{0u};
  std::atomic<uint32_t> next_model_sequence{2u};

  std::array<AtomicSubmit, kHunexGgeLookupSubmitSlots> submits = {};
  std::atomic<uint64_t> next_submit_sequence{0u};
  std::atomic<uint64_t> submit_count{0u};
  uint64_t processed_submit_count = 0u;

  std::atomic<bool> enabled{false};
  std::atomic<uint64_t> activation_epoch{1u};
  // The admitted story poller decides whether a fresh press hits a glyph, but
  // every other GetAsyncKeyState caller in the process still observes the
  // same physical left-button bits. Once a lookup/popup press is owned, keep
  // those callers filtered until a neutral sample drains the transaction.
  std::atomic<uint8_t> sampled_input_latched_buttons{0u};
  fushi_voice_hook::hunex_lookup_core::ClickSampleState click_state;
  fushi_voice_hook::hunex_lookup_core::ShiftSampleState shift_state;

  std::atomic_flag tail_busy = ATOMIC_FLAG_INIT;
  std::atomic<uint32_t> tail_thread_id{0u};
  std::atomic<bool> tail_thread_conflict{false};
  TailState tail_state;

  std::atomic<HWND> shield_game_window{nullptr};
  HWND shield_property_window = nullptr;
  ULONGLONG shield_last_health_tick = 0u;
};

struct HunexGgeLookupModelSnapshot {
  uint64_t capture_epoch = 0u;
  uint64_t selected_text_seq = 0u;
  uint32_t render_thread_id = 0u;
  int32_t client_width = 0;
  int32_t client_height = 0;
  uint16_t text_units = 0u;
  std::array<char16_t, fushi_voice_hook::hunex_lookup_core::kTextCapacity>
      text = {};
  uint16_t glyph_count = 0u;
  std::array<fushi_voice_hook::hunex_lookup_core::ProjectedGlyph,
             fushi_voice_hook::hunex_lookup_core::kGlyphCapacity>
      glyphs = {};
};

bool IsValidHunexGgeLookupModelInput(const HunexGgeLookupModelInput &input) {
  namespace core = fushi_voice_hook::hunex_lookup_core;
  const auto *projection = input.client_projection;
  if (input.capture_epoch == 0u || input.selected_text_seq == 0u ||
      input.render_thread_id == 0u || input.client_width <= 0 ||
      input.client_height <= 0 || input.client_width > 32768 ||
      input.client_height > 32768 || projection == nullptr ||
      projection->normalized_text_count == 0u ||
      projection->normalized_text_count > core::kTextCapacity ||
      projection->glyph_count == 0u ||
      projection->glyph_count > core::kGlyphCapacity) {
    return false;
  }
  for (uint32_t index = 0u; index < projection->glyph_count; ++index) {
    const auto &glyph = projection->glyphs[index];
    if (glyph.normalized_index == core::kNoUtf16Index || glyph.width == 0u ||
        glyph.width > 2u ||
        static_cast<uint32_t>(glyph.normalized_index) + glyph.width >
            projection->normalized_text_count ||
        !core::IsSaneRect(glyph.logical_bounds)) {
      return false;
    }
  }
  return true;
}

void InvalidateHunexGgeLookupModel(HunexGgeLookupRuntime *runtime) {
  if (runtime == nullptr)
    return;
  runtime->published_model_slot.store(UINT32_MAX, std::memory_order_release);
}

bool PublishHunexGgeLookupModel(HunexGgeLookupRuntime *runtime,
                                const HunexGgeLookupModelInput &input) {
  if (runtime == nullptr || !IsValidHunexGgeLookupModelInput(input)) {
    InvalidateHunexGgeLookupModel(runtime);
    return false;
  }
  const auto &projection = *input.client_projection;
  const uint32_t slot_index =
      runtime->next_model_slot.fetch_add(1u, std::memory_order_relaxed) %
      kHunexGgeLookupModelSlots;
  auto &slot = runtime->models[slot_index];
  uint32_t sealed =
      runtime->next_model_sequence.fetch_add(2u, std::memory_order_relaxed);
  if (sealed == 0u || (sealed & 1u) != 0u)
    sealed = 2u;
  slot.sequence.store(sealed | 1u, std::memory_order_release);
  slot.capture_epoch.store(input.capture_epoch, std::memory_order_relaxed);
  slot.selected_text_seq.store(input.selected_text_seq,
                               std::memory_order_relaxed);
  slot.render_thread_id.store(input.render_thread_id,
                              std::memory_order_relaxed);
  slot.client_width.store(input.client_width, std::memory_order_relaxed);
  slot.client_height.store(input.client_height, std::memory_order_relaxed);
  slot.text_units.store(projection.normalized_text_count,
                        std::memory_order_relaxed);
  for (uint32_t index = 0u; index < projection.normalized_text_count; ++index) {
    slot.text[index].store(
        static_cast<uint16_t>(projection.normalized_text[index]),
        std::memory_order_relaxed);
  }
  slot.glyph_count.store(projection.glyph_count, std::memory_order_relaxed);
  for (uint32_t index = 0u; index < projection.glyph_count; ++index) {
    const auto &source = projection.glyphs[index];
    slot.glyph_raw_index[index].store(source.raw_index,
                                      std::memory_order_relaxed);
    auto &destination = slot.glyphs[index];
    destination.normalized_index.store(source.normalized_index,
                                       std::memory_order_relaxed);
    destination.utf16_width.store(source.width, std::memory_order_relaxed);
    destination.x.store(source.logical_bounds.x, std::memory_order_relaxed);
    destination.y.store(source.logical_bounds.y, std::memory_order_relaxed);
    destination.width.store(source.logical_bounds.width,
                            std::memory_order_relaxed);
    destination.height.store(source.logical_bounds.height,
                             std::memory_order_relaxed);
  }
  slot.sequence.store(sealed, std::memory_order_release);
  runtime->published_model_slot.store(slot_index, std::memory_order_release);
  return true;
}

bool ReadHunexGgeLookupModel(const HunexGgeLookupRuntime *runtime,
                             HunexGgeLookupModelSnapshot *output) {
  namespace core = fushi_voice_hook::hunex_lookup_core;
  if (output == nullptr)
    return false;
  *output = {};
  if (runtime == nullptr)
    return false;
  const uint32_t slot_index =
      runtime->published_model_slot.load(std::memory_order_acquire);
  if (slot_index >= kHunexGgeLookupModelSlots)
    return false;
  const auto &slot = runtime->models[slot_index];
  const uint32_t before = slot.sequence.load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u)
    return false;

  HunexGgeLookupModelSnapshot candidate;
  candidate.capture_epoch = slot.capture_epoch.load(std::memory_order_relaxed);
  candidate.selected_text_seq =
      slot.selected_text_seq.load(std::memory_order_relaxed);
  candidate.render_thread_id =
      slot.render_thread_id.load(std::memory_order_relaxed);
  candidate.client_width = slot.client_width.load(std::memory_order_relaxed);
  candidate.client_height = slot.client_height.load(std::memory_order_relaxed);
  const uint32_t text_units = slot.text_units.load(std::memory_order_relaxed);
  const uint32_t glyph_count = slot.glyph_count.load(std::memory_order_relaxed);
  if (candidate.capture_epoch == 0u || candidate.selected_text_seq == 0u ||
      candidate.render_thread_id == 0u || candidate.client_width <= 0 ||
      candidate.client_height <= 0 || text_units == 0u ||
      text_units > core::kTextCapacity || glyph_count == 0u ||
      glyph_count > core::kGlyphCapacity) {
    return false;
  }
  candidate.text_units = static_cast<uint16_t>(text_units);
  candidate.glyph_count = static_cast<uint16_t>(glyph_count);
  for (uint32_t index = 0u; index < text_units; ++index) {
    candidate.text[index] =
        static_cast<char16_t>(slot.text[index].load(std::memory_order_relaxed));
  }
  for (uint32_t index = 0u; index < glyph_count; ++index) {
    auto &glyph = candidate.glyphs[index];
    glyph.raw_index = static_cast<uint16_t>(
        slot.glyph_raw_index[index].load(std::memory_order_relaxed));
    glyph.normalized_index = static_cast<uint16_t>(
        slot.glyphs[index].normalized_index.load(std::memory_order_relaxed));
    glyph.width = static_cast<uint16_t>(
        slot.glyphs[index].utf16_width.load(std::memory_order_relaxed));
    glyph.logical_bounds.x =
        slot.glyphs[index].x.load(std::memory_order_relaxed);
    glyph.logical_bounds.y =
        slot.glyphs[index].y.load(std::memory_order_relaxed);
    glyph.logical_bounds.width =
        slot.glyphs[index].width.load(std::memory_order_relaxed);
    glyph.logical_bounds.height =
        slot.glyphs[index].height.load(std::memory_order_relaxed);
    if (glyph.normalized_index == core::kNoUtf16Index || glyph.width == 0u ||
        static_cast<uint32_t>(glyph.normalized_index) + glyph.width >
            text_units ||
        !core::IsSaneRect(glyph.logical_bounds)) {
      return false;
    }
  }
  const uint32_t after = slot.sequence.load(std::memory_order_acquire);
  if (after != before || runtime->published_model_slot.load(
                             std::memory_order_acquire) != slot_index) {
    return false;
  }
  *output = candidate;
  return true;
}

bool HitTestHunexGgeLookupModel(
    const HunexGgeLookupRuntime *runtime,
    const HunexGgeLookupPointerSample &pointer,
    fushi_voice_hook::hunex_lookup_core::Hit *output) {
  namespace core = fushi_voice_hook::hunex_lookup_core;
  if (output != nullptr)
    *output = {};
  if (runtime == nullptr || !pointer.foreground_game_point)
    return false;
  const uint32_t slot_index =
      runtime->published_model_slot.load(std::memory_order_acquire);
  if (slot_index >= kHunexGgeLookupModelSlots)
    return false;
  const auto &slot = runtime->models[slot_index];
  const uint32_t before = slot.sequence.load(std::memory_order_acquire);
  if (before == 0u || (before & 1u) != 0u)
    return false;
  const uint64_t epoch = slot.capture_epoch.load(std::memory_order_relaxed);
  const uint32_t render_thread_id =
      slot.render_thread_id.load(std::memory_order_relaxed);
  const uint32_t text_units = slot.text_units.load(std::memory_order_relaxed);
  const uint32_t glyph_count = slot.glyph_count.load(std::memory_order_relaxed);
  if (epoch == 0u || render_thread_id == 0u || text_units == 0u ||
      text_units > core::kTextCapacity || glyph_count == 0u ||
      glyph_count > core::kGlyphCapacity) {
    return false;
  }

  core::Hit candidate;
  bool found = false;
  for (uint32_t index = 0u; index < glyph_count; ++index) {
    core::Rect rect;
    rect.x = slot.glyphs[index].x.load(std::memory_order_relaxed);
    rect.y = slot.glyphs[index].y.load(std::memory_order_relaxed);
    rect.width = slot.glyphs[index].width.load(std::memory_order_relaxed);
    rect.height = slot.glyphs[index].height.load(std::memory_order_relaxed);
    if (!core::ContainsPoint(rect, pointer.client_x, pointer.client_y))
      continue;
    const uint32_t normalized_index =
        slot.glyphs[index].normalized_index.load(std::memory_order_relaxed);
    const uint32_t utf16_width =
        slot.glyphs[index].utf16_width.load(std::memory_order_relaxed);
    if (normalized_index >= core::kNoUtf16Index || utf16_width == 0u ||
        normalized_index + utf16_width > text_units) {
      return false;
    }
    if (found && (candidate.utf16_index != normalized_index ||
                  candidate.utf16_width != utf16_width)) {
      return false;
    }
    found = true;
    candidate.valid = true;
    candidate.capture_epoch = epoch;
    candidate.render_thread_id = render_thread_id;
    candidate.utf16_index = static_cast<uint16_t>(normalized_index);
    candidate.utf16_width = static_cast<uint16_t>(utf16_width);
    candidate.line_utf16_count = static_cast<uint16_t>(text_units);
    candidate.rect = rect;
  }
  const uint32_t after = slot.sequence.load(std::memory_order_acquire);
  if (!found || before != after ||
      runtime->published_model_slot.load(std::memory_order_acquire) !=
          slot_index) {
    return false;
  }
  if (output != nullptr)
    *output = candidate;
  return true;
}

bool QueueHunexGgeLookupSubmit(
    HunexGgeLookupRuntime *runtime,
    const fushi_voice_hook::hunex_lookup_core::Hit &hit) {
  namespace core = fushi_voice_hook::hunex_lookup_core;
  if (runtime == nullptr || !core::IsUsableHit(&hit, hit.capture_epoch)) {
    return false;
  }
  const uint64_t sequence =
      runtime->next_submit_sequence.fetch_add(1u, std::memory_order_relaxed) +
      1u;
  if (sequence == 0u)
    return false;
  auto &slot = runtime->submits[sequence % kHunexGgeLookupSubmitSlots];
  slot.sequence.store(0u, std::memory_order_release);
  slot.capture_epoch.store(hit.capture_epoch, std::memory_order_relaxed);
  slot.utf16_index.store(hit.utf16_index, std::memory_order_relaxed);
  slot.utf16_width.store(hit.utf16_width, std::memory_order_relaxed);
  slot.x.store(hit.rect.x, std::memory_order_relaxed);
  slot.y.store(hit.rect.y, std::memory_order_relaxed);
  slot.width.store(hit.rect.width, std::memory_order_relaxed);
  slot.height.store(hit.rect.height, std::memory_order_relaxed);
  slot.sequence.store(sequence, std::memory_order_release);
  uint64_t published = runtime->submit_count.load(std::memory_order_relaxed);
  while (published < sequence &&
         !runtime->submit_count.compare_exchange_weak(
             published, sequence, std::memory_order_release,
             std::memory_order_relaxed)) {
  }
  return true;
}

HWND GetValidPublishedHunexGgeShieldPopup(HWND game) {
  if (game == nullptr || !IsWindow(game) ||
      reinterpret_cast<uintptr_t>(GetPropW(
          game, fushi_voice_hook::kHunexGgeSampledInputShieldReadyProperty)) !=
          fushi_voice_hook::kHunexGgeSampledInputShieldReadyValue) {
    return nullptr;
  }
  const HWND popup = reinterpret_cast<HWND>(GetPropW(
      game, fushi_voice_hook::kHunexGgeSampledInputShieldWindowProperty));
  if (popup == nullptr || !IsWindow(popup) ||
      GetWindow(popup, GW_OWNER) != game) {
    return nullptr;
  }
  wchar_t class_name[64] = {};
  if (GetClassNameW(popup, class_name,
                    static_cast<int>(std::size(class_name))) <= 0 ||
      lstrcmpW(class_name, L"FushiGlobalLookupWindow") != 0) {
    return nullptr;
  }
  return popup;
}

uint32_t HunexGgeShieldButtonBit(int virtual_key) {
  if (virtual_key == VK_LBUTTON)
    return 0x1u;
  if (virtual_key == VK_RBUTTON)
    return 0x2u;
  if (virtual_key == VK_MBUTTON)
    return 0x4u;
  return 0u;
}

bool HunexGgeLookupShieldRequestActiveForLeft() {
  const auto request = fushi_voice_hook::ReadLookupShieldRequest(g_header);
  if (!request.valid ||
      (request.active_buttons & fushi_voice_hook::kLookupShieldButtonLeft) ==
          0u ||
      g_header == nullptr || g_header->lookup_enabled == 0u ||
      request.target_hwnd == 0u) {
    return false;
  }
  const HWND target = reinterpret_cast<HWND>(
      static_cast<uintptr_t>(request.target_hwnd));
  if (!IsWindow(target))
    return false;
  DWORD target_process_id = 0u;
  return GetWindowThreadProcessId(target, &target_process_id) != 0u &&
         target_process_id == GetCurrentProcessId();
}

bool HunexGgeUnknownLeftButtonMustConsume(
    HunexGgeLookupRuntime *runtime, uint16_t raw,
    bool bitmap_popup_visible) {
  if (runtime == nullptr)
    return false;
  namespace core = fushi_voice_hook::hunex_lookup_core;
  const HWND game = runtime->shield_game_window.load(std::memory_order_acquire);
  const HWND direct_popup = GetValidPublishedHunexGgeShieldPopup(game);
  const bool popup_shield = bitmap_popup_visible || direct_popup != nullptr;
  const uint32_t tail_request =
      game == nullptr
          ? 0u
          : static_cast<uint32_t>(reinterpret_cast<uintptr_t>(GetPropW(
                game,
                fushi_voice_hook::
                    kHunexGgeSampledInputShieldTailRequestProperty)));
  const bool tail_shield = direct_popup != nullptr &&
                           (tail_request & 0x1u) != 0u;
  const bool latched =
      (runtime->sampled_input_latched_buttons.load(
           std::memory_order_acquire) &
       0x1u) != 0u;
  const bool raw_active = (raw & core::kAsyncPressedMask) != 0u;
  return latched || tail_shield ||
         HunexGgeLookupShieldRequestActiveForLeft() ||
         (popup_shield && raw_active);
}

bool ConsumeHunexGgeShieldTail(HunexGgeLookupRuntime *runtime, int virtual_key,
                               uint16_t raw, HWND game, HWND popup) {
  if (runtime == nullptr || game == nullptr)
    return false;
  const uint32_t button_bit = HunexGgeShieldButtonBit(virtual_key);
  if (button_bit == 0u)
    return false;
  const uint32_t request =
      static_cast<uint32_t>(reinterpret_cast<uintptr_t>(GetPropW(
          game,
          fushi_voice_hook::kHunexGgeSampledInputShieldTailRequestProperty)));
  if (request == 0u)
    return false;
  if (popup == nullptr) {
    RemovePropW(
        game, fushi_voice_hook::kHunexGgeSampledInputShieldTailRequestProperty);
    RemovePropW(game,
                fushi_voice_hook::kHunexGgeSampledInputShieldTailAckProperty);
    return false;
  }
  const uint32_t requested_buttons = request & kHunexGgeShieldButtonMask;
  if ((requested_buttons & button_bit) == 0u)
    return false;
  if (runtime->tail_busy.test_and_set(std::memory_order_acquire)) {
    runtime->tail_thread_conflict.store(true, std::memory_order_release);
    return true;
  }
  const uint32_t sample_thread_id = GetCurrentThreadId();
  // Generic and left-button pollers may legitimately run on different engine
  // threads. tail_busy serializes this shared state; retain only the latest
  // caller for diagnostics instead of permanently poisoning the shield.
  runtime->tail_thread_id.store(sample_thread_id, std::memory_order_relaxed);
  bool acknowledge = false;
  if (!runtime->tail_thread_conflict.load(std::memory_order_acquire)) {
    auto &state = runtime->tail_state;
    if (state.token != request) {
      state.token = request;
      state.drained_buttons = 0u;
      state.acknowledged_token = 0u;
    }
    if ((raw & fushi_voice_hook::hunex_lookup_core::kAsyncPressedMask) != 0u) {
      state.drained_buttons &= ~button_bit;
    } else {
      state.drained_buttons |= button_bit;
    }
    acknowledge =
        (state.drained_buttons & requested_buttons) == requested_buttons &&
        state.acknowledged_token != request;
    if (acknowledge)
      state.acknowledged_token = request;
  }
  runtime->tail_busy.clear(std::memory_order_release);
  if (acknowledge) {
    const bool ack_set =
        SetPropW(
            game, fushi_voice_hook::kHunexGgeSampledInputShieldTailAckProperty,
            reinterpret_cast<HANDLE>(static_cast<uintptr_t>(request))) != FALSE;
    if (!ack_set ||
        PostMessageW(
            popup,
            static_cast<UINT>(
                fushi_voice_hook::kSampledInputShieldReleaseWindowMessage),
            0, 0) == FALSE) {
      if (!runtime->tail_busy.test_and_set(std::memory_order_acquire)) {
        runtime->tail_state.acknowledged_token = 0u;
        runtime->tail_busy.clear(std::memory_order_release);
      }
    }
  }
  return true;
}

HunexGgeLookupSampleResult SampleHunexGgeLookupLeftButton(
    HunexGgeLookupRuntime *runtime, uint32_t sample_thread_id, uint16_t raw,
    const HunexGgeLookupPointerSample &pointer, bool bitmap_popup_visible,
    bool native_lookup_allowed) {
  namespace core = fushi_voice_hook::hunex_lookup_core;
  HunexGgeLookupSampleResult result;
  result.filtered_state = raw;
  if (runtime == nullptr)
    return result;
  const HWND game = runtime->shield_game_window.load(std::memory_order_acquire);
  const HWND direct_popup = GetValidPublishedHunexGgeShieldPopup(game);
  const bool popup_visible = bitmap_popup_visible || direct_popup != nullptr;
  const bool tail_consume =
      ConsumeHunexGgeShieldTail(runtime, VK_LBUTTON, raw, game, direct_popup);
  core::Hit hit;
  // Popup/tail shielding remains available even while native lookup admission
  // is closed. A lookup owner, however, can begin only while the host admits
  // native input and the exact HUNEX geometry provider is the stable active
  // provider. HitTestHunexGgeLookupModel seals the model with a before/after
  // sequence read, so a consumed press always owns one immutable glyph.
  const bool enabled = native_lookup_allowed &&
                       runtime->enabled.load(std::memory_order_acquire);
  const bool has_hit = enabled && !popup_visible &&
                       HitTestHunexGgeLookupModel(runtime, pointer, &hit);
  uint64_t current_epoch = 0u;
  const uint32_t slot_index =
      runtime->published_model_slot.load(std::memory_order_acquire);
  if (slot_index < kHunexGgeLookupModelSlots) {
    current_epoch = runtime->models[slot_index].capture_epoch.load(
        std::memory_order_acquire);
  }
  const auto decision = core::AdvanceClickSample(
      sample_thread_id, raw, enabled, popup_visible, has_hit ? &hit : nullptr,
      current_epoch, &runtime->click_state);
  result.submit_queued =
      decision.submit && QueueHunexGgeLookupSubmit(runtime, decision.hit);
  result.consume = decision.consume || tail_consume;
  result.popup_transaction = decision.popup_transaction;
  result.thread_conflict = decision.thread_conflict;
  result.filtered_state = core::FilterAsyncKeyState(raw, result.consume);
  return result;
}

HunexGgeLookupSampleResult
SampleHunexGgeLookupOtherButton(HunexGgeLookupRuntime *runtime, int virtual_key,
                                uint16_t raw, bool bitmap_popup_visible) {
  namespace core = fushi_voice_hook::hunex_lookup_core;
  HunexGgeLookupSampleResult result;
  result.filtered_state = raw;
  if (runtime == nullptr)
    return result;
  const HWND game = runtime->shield_game_window.load(std::memory_order_acquire);
  const HWND direct_popup = GetValidPublishedHunexGgeShieldPopup(game);
  const bool popup_visible = bitmap_popup_visible || direct_popup != nullptr;
  const bool tail_consume =
      ConsumeHunexGgeShieldTail(runtime, virtual_key, raw, game, direct_popup);
  result.consume =
      tail_consume || (popup_visible && (raw & core::kAsyncPressedMask) != 0u);
  result.popup_transaction = popup_visible && result.consume;
  result.filtered_state = core::FilterAsyncKeyState(raw, result.consume);
  return result;
}

HunexGgeLookupSampleResult SampleHunexGgeLookupShift(
    HunexGgeLookupRuntime *runtime, uint32_t sample_thread_id, uint16_t raw,
    const HunexGgeLookupPointerSample &pointer, bool bitmap_popup_visible,
    bool native_lookup_allowed) {
  namespace core = fushi_voice_hook::hunex_lookup_core;
  HunexGgeLookupSampleResult result;
  result.filtered_state = raw;
  if (runtime == nullptr)
    return result;
  const HWND game = runtime->shield_game_window.load(std::memory_order_acquire);
  const bool popup_visible =
      bitmap_popup_visible ||
      GetValidPublishedHunexGgeShieldPopup(game) != nullptr;
  const bool enabled = native_lookup_allowed &&
                       runtime->enabled.load(std::memory_order_acquire);
  const uint64_t activation =
      enabled ? runtime->activation_epoch.load(std::memory_order_acquire) : 0u;
  const auto decision = core::AdvanceShiftSample(
      sample_thread_id, raw, activation, &runtime->shift_state);
  result.thread_conflict = decision.thread_conflict;
  if (!decision.submit || popup_visible || !enabled)
    return result;
  core::Hit hit;
  if (HitTestHunexGgeLookupModel(runtime, pointer, &hit)) {
    result.submit_queued = QueueHunexGgeLookupSubmit(runtime, hit);
  }
  return result;
}

HunexGgeLookupSampleResult
HandleHunexGgeGetAsyncKeyState(HunexGgeLookupRuntime *runtime, int virtual_key,
                               uint32_t sample_thread_id, uint16_t raw,
                               const HunexGgeLookupPointerSample &pointer,
                               bool bitmap_popup_visible,
                               bool native_lookup_allowed) {
  if (virtual_key == VK_LBUTTON) {
    return SampleHunexGgeLookupLeftButton(runtime, sample_thread_id, raw,
                                          pointer, bitmap_popup_visible,
                                          native_lookup_allowed);
  }
  if (virtual_key == VK_SHIFT) {
    return SampleHunexGgeLookupShift(runtime, sample_thread_id, raw, pointer,
                                     bitmap_popup_visible,
                                     native_lookup_allowed);
  }
  if (HunexGgeShieldButtonBit(virtual_key) != 0u) {
    return SampleHunexGgeLookupOtherButton(runtime, virtual_key, raw,
                                           bitmap_popup_visible);
  }
  HunexGgeLookupSampleResult result;
  result.filtered_state = raw;
  return result;
}

void SetHunexGgeLookupRuntimeEnabled(HunexGgeLookupRuntime *runtime,
                                     bool enabled) {
  if (runtime == nullptr)
    return;
  const bool previous =
      runtime->enabled.exchange(enabled, std::memory_order_acq_rel);
  if (previous != enabled) {
    runtime->activation_epoch.fetch_add(1u, std::memory_order_acq_rel);
  }
  if (!enabled) {
    InvalidateHunexGgeLookupModel(runtime);
    runtime->processed_submit_count =
        runtime->submit_count.load(std::memory_order_acquire);
  }
}

bool PublishLatestHunexGgeLookupSubmit(HunexGgeLookupRuntime *runtime,
                                       fushi_voice_hook::SharedHeader *header) {
  namespace core = fushi_voice_hook::hunex_lookup_core;
  if (runtime == nullptr || header == nullptr ||
      !fushi_voice_hook::HasLookupRegion(header) ||
      header->lookup_enabled == 0u ||
      !runtime->enabled.load(std::memory_order_acquire)) {
    return false;
  }
  const uint64_t published =
      runtime->submit_count.load(std::memory_order_acquire);
  if (published == 0u || published == runtime->processed_submit_count) {
    return false;
  }
  runtime->processed_submit_count = published;
  const auto &submit = runtime->submits[published % kHunexGgeLookupSubmitSlots];
  if (submit.sequence.load(std::memory_order_acquire) != published) {
    return false;
  }
  core::Hit hit;
  hit.valid = true;
  hit.capture_epoch = submit.capture_epoch.load(std::memory_order_relaxed);
  hit.utf16_index =
      static_cast<uint16_t>(submit.utf16_index.load(std::memory_order_relaxed));
  hit.utf16_width =
      static_cast<uint16_t>(submit.utf16_width.load(std::memory_order_relaxed));
  hit.rect.x = submit.x.load(std::memory_order_relaxed);
  hit.rect.y = submit.y.load(std::memory_order_relaxed);
  hit.rect.width = submit.width.load(std::memory_order_relaxed);
  hit.rect.height = submit.height.load(std::memory_order_relaxed);
  if (submit.sequence.load(std::memory_order_acquire) != published) {
    return false;
  }

  HunexGgeLookupModelSnapshot model;
  if (!ReadHunexGgeLookupModel(runtime, &model) ||
      model.capture_epoch != hit.capture_epoch) {
    return false;
  }
  hit.line_utf16_count = model.text_units;
  if (!core::IsUsableHit(&hit, model.capture_epoch))
    return false;
  const wchar_t *wide = reinterpret_cast<const wchar_t *>(model.text.data());
  const int required =
      WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, model.text_units,
                          nullptr, 0, nullptr, nullptr);
  if (required <= 0 ||
      static_cast<uint32_t>(required) > fushi_voice_hook::kLookupLineBytes) {
    return false;
  }
  char utf8[fushi_voice_hook::kLookupLineBytes] = {};
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, model.text_units,
                          utf8, required, nullptr, nullptr) != required) {
    return false;
  }
  fushi_voice_hook::LookupGeometryHitPublication publication;
  publication.provider_kind =
      fushi_voice_hook::kLookupGeometryProviderEngineExactLayout;
  publication.provider_id =
      fushi_voice_hook::kLookupGeometryProviderIdHunexGge;
  publication.char_index = hit.utf16_index;
  publication.source_length = fushi_voice_hook::LookupUtf16SourceLength(
      wide, model.text_units, hit.utf16_index);
  publication.char_count = model.text_units;
  publication.coordinate_space =
      fushi_voice_hook::kLookupCoordinateSpaceClientPhysicalPixels;
  publication.writing_mode = fushi_voice_hook::kLookupWritingModeHorizontal;
  // HUNEX redraws the same selected sentence every frame. The selected Luna
  // sequence is therefore the stable semantic and layout generation used by
  // the click transaction; a new selected line always advances both values.
  publication.text_generation = model.selected_text_seq;
  publication.geometry_generation = model.capture_epoch;
  publication.glyph_x = hit.rect.x;
  publication.glyph_y = hit.rect.y;
  publication.glyph_w = hit.rect.width;
  publication.glyph_h = hit.rect.height;
  publication.view_w = model.client_width;
  publication.view_h = model.client_height;
  publication.flags = fushi_voice_hook::kLookupHitFlagSubmit;
  publication.line_utf8 = reinterpret_cast<const uint8_t *>(utf8);
  publication.line_bytes = static_cast<uint32_t>(required);
  return fushi_voice_hook::g_geometry_provider_registry.PublishHit(
      header, publication);
}

bool TickHunexGgeLookupRuntime(HunexGgeLookupRuntime *runtime,
                               fushi_voice_hook::SharedHeader *header) {
  return PublishLatestHunexGgeLookupSubmit(runtime, header);
}

void RevokeHunexGgeSampledInputShield(HunexGgeLookupRuntime *runtime,
                                      fushi_voice_hook::SharedHeader *header,
                                      bool remove_required) {
  if (runtime == nullptr)
    return;
  const HWND game = runtime->shield_property_window;
  if (game != nullptr && IsWindow(game)) {
    RemovePropW(game,
                fushi_voice_hook::kHunexGgeSampledInputShieldReadyProperty);
    RemovePropW(game,
                fushi_voice_hook::kHunexGgeSampledInputShieldWindowProperty);
    RemovePropW(
        game, fushi_voice_hook::kHunexGgeSampledInputShieldTailRequestProperty);
    RemovePropW(game,
                fushi_voice_hook::kHunexGgeSampledInputShieldTailAckProperty);
    if (remove_required) {
      RemovePropW(
          game, fushi_voice_hook::kHunexGgeSampledInputShieldRequiredProperty);
    }
  }
  runtime->shield_game_window.store(nullptr, std::memory_order_release);
  runtime->shield_last_health_tick = 0u;
  if (header != nullptr) {
    InterlockedAnd(reinterpret_cast<volatile LONG *>(&header->lookup_diag),
                   static_cast<LONG>(
                       ~fushi_voice_hook::kLookupDiagSampledInputShieldReady));
  }
}

bool MaintainHunexGgeSampledInputShield(HunexGgeLookupRuntime *runtime,
                                        fushi_voice_hook::SharedHeader *header,
                                        HWND game, bool exact_profile_admitted,
                                        bool input_hook_ready) {
  if (runtime == nullptr || !exact_profile_admitted || game == nullptr ||
      !IsWindow(game)) {
    if (runtime != nullptr) {
      RevokeHunexGgeSampledInputShield(runtime, header, true);
      runtime->shield_property_window = nullptr;
    }
    return false;
  }
  if (runtime->shield_property_window != game) {
    RevokeHunexGgeSampledInputShield(runtime, header, true);
    runtime->shield_property_window = game;
  }
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game,
          fushi_voice_hook::kHunexGgeSampledInputShieldRequiredProperty)) !=
          fushi_voice_hook::kHunexGgeSampledInputShieldRequiredValue &&
      !SetPropW(
          game, fushi_voice_hook::kHunexGgeSampledInputShieldRequiredProperty,
          reinterpret_cast<HANDLE>(
              fushi_voice_hook::kHunexGgeSampledInputShieldRequiredValue))) {
    RevokeHunexGgeSampledInputShield(runtime, header, false);
    return false;
  }
  if (!input_hook_ready) {
    RevokeHunexGgeSampledInputShield(runtime, header, false);
    return false;
  }
  if (reinterpret_cast<uintptr_t>(GetPropW(
          game, fushi_voice_hook::kHunexGgeSampledInputShieldReadyProperty)) !=
          fushi_voice_hook::kHunexGgeSampledInputShieldReadyValue &&
      !SetPropW(game,
                fushi_voice_hook::kHunexGgeSampledInputShieldReadyProperty,
                reinterpret_cast<HANDLE>(
                    fushi_voice_hook::kHunexGgeSampledInputShieldReadyValue))) {
    RevokeHunexGgeSampledInputShield(runtime, header, false);
    return false;
  }
  runtime->shield_game_window.store(game, std::memory_order_release);
  runtime->shield_last_health_tick = GetTickCount64();
  if (header != nullptr) {
    InterlockedOr(reinterpret_cast<volatile LONG *>(&header->lookup_diag),
                  static_cast<LONG>(
                      fushi_voice_hook::kLookupDiagSampledInputShieldReady));
  }
  return true;
}

bool ResetHunexGgeInputSampleStates(HunexGgeLookupRuntime *runtime) {
  if (runtime == nullptr)
    return false;
  const bool click_reset =
      fushi_voice_hook::hunex_lookup_core::ResetClickSampleState(
          &runtime->click_state);
  const bool shift_reset =
      fushi_voice_hook::hunex_lookup_core::ResetShiftSampleState(
          &runtime->shift_state);
  bool tail_reset = false;
  if (!runtime->tail_busy.test_and_set(std::memory_order_acquire)) {
    runtime->tail_thread_id.store(0u, std::memory_order_relaxed);
    runtime->tail_thread_conflict.store(false, std::memory_order_relaxed);
    runtime->tail_state = {};
    runtime->tail_busy.clear(std::memory_order_release);
    tail_reset = true;
  }
  if (click_reset && shift_reset && tail_reset) {
    runtime->sampled_input_latched_buttons.store(0u,
                                                 std::memory_order_release);
    return true;
  }
  return false;
}

void ShutdownHunexGgeLookupRuntime(HunexGgeLookupRuntime *runtime,
                                   fushi_voice_hook::SharedHeader *header) {
  if (runtime == nullptr)
    return;
  SetHunexGgeLookupRuntimeEnabled(runtime, false);
  RevokeHunexGgeSampledInputShield(runtime, header, true);
  runtime->shield_property_window = nullptr;
  (void)ResetHunexGgeInputSampleStates(runtime);
}

#endif // _M_X64
