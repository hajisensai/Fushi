// smash/fzmedia 适配核心（TYPE-MOON smash 框架：Fate/stay night REMASTERED 系）。
//
// 三块能力，各自独立装、独立失败：
//   * 准入：引擎级结构签名（主 exe 导入 null-ge-* 的 IGameEngine@fw@smash@@ + fzmedia-*
//     导出表齐全 + x64），三态缓存，没有 exe/module 哈希白名单。
//   * 资源音频：hook fzmedia 导出的 SoundManager::create / SoundObject::play。create 记
//     {SoundObject*, 类别, 资源 id}；play 时类别 5（角色语音）且 isReady 则调导出
//     convertToRawFile 取**解密后的完整 Ogg**，校验 OggS + ≤1 MiB 后 memcpy 进 8 槽 × 1 MiB
//     有界环；worker 配对（资源先于文本，ResolveFollowingSelectedText 1500ms 窗）后
//     WriteVoiceOggAt 落盘。
//   * 文本：exe 内 KAG 文本层 layoutChar 的锚点由 smash_fzmedia_anchors.h 从 RTTI + 调用
//     形状推导（fail-closed、可重试：SteamStub 正版在入口后才解包 .text，worker 每 500ms
//     重扫、上限 120s，install() 再次被调用时立即重试）。detour 只做有界拷贝与入队：
//     段落装配器（引号平衡合并续行）在游戏线程，快照经 seqlock 邮箱交给 worker 发布
//     （WriteTextLaneEvent + LookupPublishSnapshot）。
//
// 与 lookup 侧（smash_fzmedia_lookup.inc）只经 smash_fzmedia_shared.h 的 LineSnapshot 通信。
// 本文件在 dll_main.cpp 的匿名命名空间里展开。纯头（anchors / shared / exact_lookup）
// 必须已在全局作用域被包含过（profile_includes.inc → smash_fzmedia_profile.h 负责），
// 这里的包含只是 pragma once 的空操作，不得在此处首次引入任何 namespace fushi_voice_hook
// 的头，否则会生出匿名命名空间下的同名影子命名空间。
#include "smash_fzmedia_lookup.h"
#include "smash_fzmedia_profile.h"
// lookup 侧运行时（几何 provider / 点击传感 / 护盾）由 lookup 侧文件拥有，这里只展开它，
// 并经 smash_fzmedia_lookup.h 声明的四个入口调用。
#include "smash_fzmedia_lookup.inc"

#if defined(_M_X64)

volatile LONG g_smash_diagnostics = 0;

void SetSmashDiagnostic(uint32_t flag) {
  InterlockedOr(&g_smash_diagnostics, static_cast<LONG>(flag));
}

// ── 身份（三态缓存）──────────────────────────────────────────────────────────
// 0 = 未定（fzmedia 还没加载 / 映像暂不可读，稍后重探）；1 = 通过；-1 = 拒绝（主 exe
// 确实不导入 smash 引擎，或 fzmedia-* 模块导出表不是我们要的那套）。未定时不做任何不可
// 逆决策。全部在 HookWorker 线程上推进。
volatile LONG g_smash_identity_state = 0;
ULONGLONG g_smash_identity_next_probe_ms = 0u;
HMODULE g_smash_fzmedia_module = nullptr;

// 1 = 导入表含签名；0 = 映像可读但不含；-1 = 映像暂不可读。
int ProbeSmashMainExecutableImportsUnsafe() {
  HMODULE exe = GetModuleHandleW(nullptr);
  if (exe == nullptr) return -1;
  fushi_voice_hook::smash_fzmedia::ImageView view;
  int result = -1;
  __try {
    if (!fushi_voice_hook::smash_fzmedia::OpenImageView(
            reinterpret_cast<const uint8_t*>(exe),
            reinterpret_cast<uintptr_t>(exe), &view)) {
      return -1;
    }
    result = fushi_voice_hook::smash_fzmedia::ImportsSymbolFromDll(
                 view, fushi_voice_hook::smash_fzmedia::kGameEngineDllPrefix,
                 fushi_voice_hook::smash_fzmedia::kGameEngineImportSubstring)
                 ? 1
                 : 0;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    result = -1;
  }
  return result;
}

// 1 = 五个导出前缀齐全；0 = 缺任一；-1 = 映像暂不可读。
int ProbeSmashFzmediaExportsUnsafe(HMODULE module) {
  if (module == nullptr) return -1;
  fushi_voice_hook::smash_fzmedia::ImageView view;
  int result = -1;
  __try {
    if (!fushi_voice_hook::smash_fzmedia::OpenImageView(
            reinterpret_cast<const uint8_t*>(module),
            reinterpret_cast<uintptr_t>(module), &view)) {
      return -1;
    }
    result = 1;
    for (size_t i = 0u;
         i < fushi_voice_hook::smash_fzmedia::kFzmediaRequiredExportCount; ++i) {
      if (!fushi_voice_hook::smash_fzmedia::HasExportWithPrefix(
              view, fushi_voice_hook::smash_fzmedia::kFzmediaRequiredExportPrefixes[i])) {
        result = 0;
        break;
      }
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    result = -1;
  }
  return result;
}

HMODULE FindSmashFzmediaModule() {
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
  if (snap == INVALID_HANDLE_VALUE) return nullptr;
  HMODULE found = nullptr;
  MODULEENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  if (Module32FirstW(snap, &entry)) {
    do {
      if (fushi_voice_hook::SmashFzmediaModuleNameStartsWith(
              entry.szModule, fushi_voice_hook::smash_fzmedia::kMediaDllPrefixW)) {
        found = entry.hModule;
        break;
      }
    } while (Module32NextW(snap, &entry));
  }
  CloseHandle(snap);
  return found;
}

// 准入判定。force 绕过 500ms 节流（install() 路径）；probe() 走节流。
bool RefreshSmashIdentity(bool force) {
  const LONG cached = InterlockedCompareExchange(&g_smash_identity_state, 0, 0);
  if (cached != 0) return cached == 1;
  const ULONGLONG now = GetTickCount64();
  if (!force && now < g_smash_identity_next_probe_ms) return false;
  g_smash_identity_next_probe_ms = now + 500u;
  const int imports = ProbeSmashMainExecutableImportsUnsafe();
  if (imports == 0) {
    InterlockedExchange(&g_smash_identity_state, -1);
    return false;
  }
  if (imports < 0) return false;
  HMODULE media = FindSmashFzmediaModule();
  if (media == nullptr) return false;  // 引擎对上了、媒体库还没加载：保持未定
  const int exports = ProbeSmashFzmediaExportsUnsafe(media);
  if (exports == 0) {
    InterlockedExchange(&g_smash_identity_state, -1);
    return false;
  }
  if (exports < 0) return false;
  g_smash_fzmedia_module = media;
  InterlockedExchange(&g_smash_identity_state, 1);
  SetSmashDiagnostic(fushi_voice_hook::smash_fzmedia::kDiagFamilyMatched);
  return true;
}

// ── fzmedia 资源音频 ─────────────────────────────────────────────────────────
typedef void* (*SmashSoundManagerCreateFn)(void* self, void* out_shared_ptr,
                                           const void* resource_id,
                                           int32_t category);
typedef intptr_t (*SmashSoundObjectPlayFn)(void* self, const void* play_info);
typedef uint8_t (*SmashSoundObjectIsReadyFn)(void* self);
typedef int32_t (*SmashSoundObjectConvertFn)(void* self, void* shared_ptr_vector);
typedef void (*SmashOperatorDeleteFn)(void* block);
typedef void (*SmashOperatorDeleteSizedFn)(void* block, size_t bytes);

struct SmashFzmediaApi {
  void* create_target = nullptr;
  void* play_target = nullptr;
  SmashSoundObjectIsReadyFn is_ready = nullptr;
  SmashSoundObjectConvertFn convert_to_raw_file = nullptr;
  SmashOperatorDeleteFn operator_delete = nullptr;
  SmashOperatorDeleteSizedFn operator_delete_sized = nullptr;
};

SmashFzmediaApi g_smash_api;
SmashSoundManagerCreateFn g_orig_smash_sound_manager_create = nullptr;
SmashSoundObjectPlayFn g_orig_smash_sound_object_play = nullptr;
volatile LONG g_smash_audio_enabled = 0;
volatile LONG g_smash_audio_hooks_ready = 0;

// create 记录表：{SoundObject*, 类别, 资源 id, tick}，32 项，seqlock（奇数 = 写入中）。
// 两张表都是无默认成员初始化器的 POD：静态零初始化落在 BSS，不生成会在 DllMain 时
// 摸遍 8 MiB 的静态初始化代码。
constexpr int kSmashSoundObjectSlots = 32;
struct SmashSoundObjectRecord {
  volatile LONG seq;
  void* object;
  int32_t category;
  uint64_t tick_ms;
  char id[fushi_voice_hook::smash_fzmedia::kVoiceIdChars];
};
SmashSoundObjectRecord g_smash_sound_objects[kSmashSoundObjectSlots] = {};
volatile LONG g_smash_sound_object_cursor = 0;

// 语音事件槽：8 × 1 MiB 有界环，0=free 1=producing 2=pending 3=consuming。
constexpr int kSmashVoiceSlots = 8;
struct SmashVoiceSlot {
  volatile LONG state;
  uint32_t bytes;
  uint64_t tick_ms;
  uint64_t selected_thread_id;
  uint64_t baseline_text_seq;
  bool dedupe_checked;
  char id[fushi_voice_hook::smash_fzmedia::kVoiceIdChars];
  uint8_t data[fushi_voice_hook::smash_fzmedia::kVoiceSlotBytes];
};
SmashVoiceSlot g_smash_voice_slots[kSmashVoiceSlots] = {};

bool TryClaimSmashRecordForWrite(SmashSoundObjectRecord* record) {
  const LONG seq = InterlockedCompareExchange(&record->seq, 0, 0);
  if ((seq & 1) != 0) return false;
  return InterlockedCompareExchange(&record->seq, seq + 1, seq) == seq;
}

void RecordSmashSoundObject(void* object, int32_t category, const char* id,
                            size_t id_len, uint64_t tick_ms) {
  if (object == nullptr) return;
  SmashSoundObjectRecord* target = nullptr;
  // 同一个对象再次 create：覆盖旧记录，避免地址复用时串类别。
  for (int i = 0; i < kSmashSoundObjectSlots && target == nullptr; ++i) {
    if (g_smash_sound_objects[i].object == object) target = &g_smash_sound_objects[i];
  }
  for (int attempt = 0; attempt < kSmashSoundObjectSlots; ++attempt) {
    SmashSoundObjectRecord* record =
        target != nullptr
            ? target
            : &g_smash_sound_objects[static_cast<uint32_t>(InterlockedIncrement(
                                          &g_smash_sound_object_cursor)) %
                                      kSmashSoundObjectSlots];
    if (!TryClaimSmashRecordForWrite(record)) {
      if (target != nullptr) return;  // 别的线程正在写同一条，放弃本次
      continue;
    }
    record->object = object;
    record->category = category;
    record->tick_ms = tick_ms;
    memset(record->id, 0, sizeof(record->id));
    const size_t copy = id_len < sizeof(record->id) - 1u ? id_len
                                                         : sizeof(record->id) - 1u;
    if (id != nullptr && copy != 0u) memcpy(record->id, id, copy);
    MemoryBarrier();
    InterlockedIncrement(&record->seq);
    return;
  }
}

bool LookupSmashSoundObject(void* object, int32_t* category,
                            char id[fushi_voice_hook::smash_fzmedia::kVoiceIdChars]) {
  for (int i = 0; i < kSmashSoundObjectSlots; ++i) {
    SmashSoundObjectRecord* record = &g_smash_sound_objects[i];
    const LONG before = InterlockedCompareExchange(&record->seq, 0, 0);
    if ((before & 1) != 0 || record->object != object) continue;
    const int32_t cat = record->category;
    char copy[fushi_voice_hook::smash_fzmedia::kVoiceIdChars];
    memcpy(copy, record->id, sizeof(copy));
    MemoryBarrier();
    if (InterlockedCompareExchange(&record->seq, 0, 0) != before) continue;
    *category = cat;
    memcpy(id, copy, sizeof(copy));
    return true;
  }
  return false;
}

// create 之后读 *out（shared_ptr 的首 8 字节 = SoundObject*）与 SoundResourceId 首 32 字节
// （MSVC std::string）。只在 SEH 下解引用。
void ObserveSmashSoundCreateUnsafe(void* out_shared_ptr, const void* resource_id,
                                   int32_t category, uint64_t tick_ms) {
  void* object = nullptr;
  const char* data = nullptr;
  size_t len = 0u;
  char id[fushi_voice_hook::smash_fzmedia::kVoiceIdChars] = {};
  __try {
    if (out_shared_ptr == nullptr || resource_id == nullptr) return;
    memcpy(&object, out_shared_ptr, sizeof(object));
    if (object == nullptr) return;
    if (!fushi_voice_hook::smash_fzmedia::LocateMsvcStdString(
            reinterpret_cast<const uint8_t*>(resource_id), &data, &len)) {
      return;
    }
    if (len >= sizeof(id)) len = sizeof(id) - 1u;
    if (len != 0u) memcpy(id, data, len);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }
  RecordSmashSoundObject(object, category, id, len, tick_ms);
}

// fzmedia 的 std::vector<uint8_t> 缓冲按 vc14 STL 的分配形状释放；形状不符则泄漏并记诊断。
void ReleaseSmashVectorBufferUnsafe(uint8_t* begin, uint8_t* capacity_end) {
  if (begin == nullptr || capacity_end < begin) return;
  const uint64_t capacity_bytes = static_cast<uint64_t>(capacity_end - begin);
  uint64_t stored_container = 0u;
  if (capacity_bytes >= fushi_voice_hook::smash_fzmedia::kMsvcBigAllocationThreshold) {
    memcpy(&stored_container, begin - sizeof(uint64_t), sizeof(stored_container));
  }
  const uint64_t block =
      fushi_voice_hook::smash_fzmedia::ResolveMsvcVectorDeallocationPointer(
          reinterpret_cast<uintptr_t>(begin), capacity_bytes, stored_container);
  if (block == 0u) {
    SetSmashDiagnostic(fushi_voice_hook::smash_fzmedia::kDiagVoiceBufferLeaked);
    return;
  }
  if (g_smash_api.operator_delete != nullptr) {
    g_smash_api.operator_delete(reinterpret_cast<void*>(static_cast<uintptr_t>(block)));
  } else if (g_smash_api.operator_delete_sized != nullptr) {
    g_smash_api.operator_delete_sized(
        reinterpret_cast<void*>(static_cast<uintptr_t>(block)),
        static_cast<size_t>(capacity_bytes));
  } else {
    SetSmashDiagnostic(fushi_voice_hook::smash_fzmedia::kDiagVoiceBufferLeaked);
  }
}

// 调导出 convertToRawFile(this, shared_ptr<vector<uint8_t>>)：传栈上 {vector*, ctrl=nullptr}
// 与零初始化 vector；返回后 vector.begin..end 即解密后的完整 Ogg。校验后 memcpy 进槽。
// 返回拷贝字节数（0 = 未取到 / 校验失败）。
uint32_t CaptureSmashVoiceUnsafe(void* object, uint8_t* out, uint32_t capacity) {
  struct RawVector {
    uint8_t* begin;
    uint8_t* end;
    uint8_t* capacity_end;
  } vector = {nullptr, nullptr, nullptr};
  struct RawSharedPtr {
    RawVector* pointer;
    void* control;
  } shared = {&vector, nullptr};
  uint32_t copied = 0u;
  __try {
    if (g_smash_api.is_ready == nullptr || g_smash_api.convert_to_raw_file == nullptr)
      return 0u;
    if (g_smash_api.is_ready(object) == 0u) return 0u;
    (void)g_smash_api.convert_to_raw_file(object, &shared);
    if (vector.begin != nullptr && vector.end >= vector.begin) {
      const uint64_t bytes = static_cast<uint64_t>(vector.end - vector.begin);
      if (bytes <= capacity &&
          fushi_voice_hook::smash_fzmedia::ValidateOggPayload(vector.begin, bytes)) {
        memcpy(out, vector.begin, static_cast<size_t>(bytes));
        copied = static_cast<uint32_t>(bytes);
      }
      ReleaseSmashVectorBufferUnsafe(vector.begin, vector.capacity_end);
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    copied = 0u;
  }
  return copied;
}

void ObserveSmashSoundPlay(void* object) {
  int32_t category = 0;
  char id[fushi_voice_hook::smash_fzmedia::kVoiceIdChars] = {};
  if (!LookupSmashSoundObject(object, &category, id)) return;
  if (!fushi_voice_hook::smash_fzmedia::IsVoiceCategory(category)) return;
  SmashVoiceSlot* slot = nullptr;
  for (int i = 0; i < kSmashVoiceSlots; ++i) {
    if (InterlockedCompareExchange(&g_smash_voice_slots[i].state, 1, 0) == 0) {
      slot = &g_smash_voice_slots[i];
      break;
    }
  }
  if (slot == nullptr) {
    SetSmashDiagnostic(fushi_voice_hook::smash_fzmedia::kDiagVoiceQueueFull);
    return;
  }
  const uint32_t bytes = CaptureSmashVoiceUnsafe(
      object, slot->data, fushi_voice_hook::smash_fzmedia::kVoiceSlotBytes);
  if (bytes == 0u) {
    InterlockedExchange(&slot->state, 0);
    return;
  }
  slot->bytes = bytes;
  slot->tick_ms = GetTickCount64();
  slot->dedupe_checked = false;
  memcpy(slot->id, id, sizeof(slot->id));
  slot->selected_thread_id = 0u;
  slot->baseline_text_seq = 0u;
  if (g_header != nullptr) {
    slot->selected_thread_id = static_cast<uint64_t>(InterlockedCompareExchange64(
        reinterpret_cast<volatile LONGLONG*>(&g_header->selected_text_thread_id),
        0, 0));
    if (slot->selected_thread_id != 0u) {
      slot->baseline_text_seq = static_cast<uint64_t>(InterlockedCompareExchange64(
          reinterpret_cast<volatile LONGLONG*>(&g_header->text_write_count), 0, 0));
    }
  }
  MemoryBarrier();
  InterlockedExchange(&slot->state, 2);
  SetSmashDiagnostic(fushi_voice_hook::smash_fzmedia::kDiagVoiceObserved);
}

// this=rcx, 隐藏返回缓冲(shared_ptr<SoundObject>*)=rdx, id=r8, cat=r9d。
void* Detour_SmashSoundManagerCreate(void* self, void* out_shared_ptr,
                                     const void* resource_id, int32_t category) {
  void* result = g_orig_smash_sound_manager_create(self, out_shared_ptr,
                                                   resource_id, category);
  if (g_capture_enabled &&
      InterlockedCompareExchange(&g_smash_audio_enabled, 0, 0) != 0) {
    ObserveSmashSoundCreateUnsafe(out_shared_ptr, resource_id, category,
                                  GetTickCount64());
  }
  return result;
}

intptr_t Detour_SmashSoundObjectPlay(void* self, const void* play_info) {
  if (g_capture_enabled &&
      InterlockedCompareExchange(&g_smash_audio_enabled, 0, 0) != 0) {
    ObserveSmashSoundPlay(self);
  }
  return g_orig_smash_sound_object_play(self, play_info);
}

bool ResolveSmashFzmediaApiUnsafe(HMODULE module, SmashFzmediaApi* api) {
  namespace sf = fushi_voice_hook::smash_fzmedia;
  sf::ImageView view;
  bool ok = false;
  __try {
    if (!sf::OpenImageView(reinterpret_cast<const uint8_t*>(module),
                           reinterpret_cast<uintptr_t>(module), &view)) {
      return false;
    }
    const sf::ExportMatch create =
        sf::FindExportByPrefix(view, sf::kExportSoundManagerCreate);
    const sf::ExportMatch play =
        sf::FindExportByPrefix(view, sf::kExportSoundObjectPlay);
    const sf::ExportMatch ready =
        sf::FindExportByPrefix(view, sf::kExportSoundObjectIsReady);
    const sf::ExportMatch convert =
        sf::FindExportByPrefix(view, sf::kExportSoundObjectConvertToRawFile);
    const uint32_t delete_slot =
        sf::FindImportThunkRva(view, nullptr, sf::kImportOperatorDelete);
    const uint32_t delete_sized_slot =
        sf::FindImportThunkRva(view, nullptr, sf::kImportOperatorDeleteSized);
    // 要么全有要么不装：半装状态下「没反应」与「引擎不支持」在真机上同形。
    if (create.count != 1u || create.rva == 0u || play.count != 1u ||
        play.rva == 0u || ready.count != 1u || ready.rva == 0u ||
        convert.count != 1u || convert.rva == 0u ||
        (delete_slot == 0u && delete_sized_slot == 0u)) {
      return false;
    }
    const auto base = reinterpret_cast<uintptr_t>(module);
    if (!view.IsExecutable(create.rva, 1u) || !view.IsExecutable(play.rva, 1u) ||
        !view.IsExecutable(ready.rva, 1u) || !view.IsExecutable(convert.rva, 1u)) {
      return false;
    }
    api->create_target = reinterpret_cast<void*>(base + create.rva);
    api->play_target = reinterpret_cast<void*>(base + play.rva);
    api->is_ready = reinterpret_cast<SmashSoundObjectIsReadyFn>(base + ready.rva);
    api->convert_to_raw_file =
        reinterpret_cast<SmashSoundObjectConvertFn>(base + convert.rva);
    if (delete_slot != 0u) {
      uint64_t target = 0u;
      memcpy(&target, reinterpret_cast<const void*>(base + delete_slot),
             sizeof(target));
      api->operator_delete = reinterpret_cast<SmashOperatorDeleteFn>(
          static_cast<uintptr_t>(target));
    }
    if (delete_sized_slot != 0u) {
      uint64_t target = 0u;
      memcpy(&target, reinterpret_cast<const void*>(base + delete_sized_slot),
             sizeof(target));
      api->operator_delete_sized = reinterpret_cast<SmashOperatorDeleteSizedFn>(
          static_cast<uintptr_t>(target));
    }
    ok = (api->operator_delete != nullptr &&
          fushi_voice_hook::exact_lookup::IsExecutableAddress(
              reinterpret_cast<const void*>(api->operator_delete))) ||
         (api->operator_delete_sized != nullptr &&
          fushi_voice_hook::exact_lookup::IsExecutableAddress(
              reinterpret_cast<const void*>(api->operator_delete_sized)));
    if (!ok) {
      api->operator_delete = nullptr;
      api->operator_delete_sized = nullptr;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    ok = false;
  }
  return ok;
}

bool TryHookSmashFzmediaAudio() {
  if (InterlockedCompareExchange(&g_smash_identity_state, 0, 0) != 1 ||
      g_smash_fzmedia_module == nullptr) {
    return false;
  }
  if (InterlockedCompareExchange(&g_smash_audio_hooks_ready, 0, 0) != 0) return true;
  SmashFzmediaApi api;
  if (!ResolveSmashFzmediaApiUnsafe(g_smash_fzmedia_module, &api)) return false;
  g_smash_api = api;
  HunexGgeHookSpec hooks[] = {
      {api.create_target,
       reinterpret_cast<void*>(&Detour_SmashSoundManagerCreate),
       reinterpret_cast<void**>(&g_orig_smash_sound_manager_create)},
      {api.play_target, reinterpret_cast<void*>(&Detour_SmashSoundObjectPlay),
       reinterpret_cast<void**>(&g_orig_smash_sound_object_play)},
  };
  // 与 HUNEX 共用同一套「全建再全启、任一失败整组回滚」的组装器。
  if (!InstallHunexGgeHookGroup(hooks, _countof(hooks))) {
    g_smash_api = {};
    return false;
  }
  InterlockedExchange(&g_smash_audio_enabled, 1);
  InterlockedExchange(&g_smash_audio_hooks_ready, 1);
  SetSmashDiagnostic(fushi_voice_hook::smash_fzmedia::kDiagFzmediaHooksReady);
  return true;
}

// ── 文本：layoutChar 锚点 + detour ───────────────────────────────────────────
typedef uintptr_t (*SmashLayoutCharFn)(void* layer, void* run, uint64_t index,
                                       uint64_t* next);

fushi_voice_hook::smash_fzmedia::TextAnchors g_smash_text_anchors;
uintptr_t g_smash_exe_base = 0u;
volatile LONG g_smash_text_anchor_state = 0;  // 0 未解 / 1 已解
volatile LONG g_smash_text_hook_ready = 0;
volatile LONG g_smash_text_enabled = 0;
ULONGLONG g_smash_anchor_first_attempt_ms = 0u;
ULONGLONG g_smash_anchor_next_attempt_ms = 0u;
uint32_t g_smash_anchor_attempts = 0u;
fushi_voice_hook::smash_fzmedia::TextAnchorStage g_smash_anchor_last_stage =
    fushi_voice_hook::smash_fzmedia::TextAnchorStage::kNone;
SmashLayoutCharFn g_orig_smash_layout_char = nullptr;

bool ScanSmashTextAnchorsUnsafe(fushi_voice_hook::smash_fzmedia::TextAnchors* out,
                                fushi_voice_hook::smash_fzmedia::TextAnchorStage* stage,
                                uintptr_t* base_out) {
  HMODULE exe = GetModuleHandleW(nullptr);
  if (exe == nullptr) return false;
  fushi_voice_hook::smash_fzmedia::ImageView view;
  fushi_voice_hook::smash_fzmedia::TextAnchorResult result;
  __try {
    if (!fushi_voice_hook::smash_fzmedia::OpenImageView(
            reinterpret_cast<const uint8_t*>(exe),
            reinterpret_cast<uintptr_t>(exe), &view)) {
      *stage = fushi_voice_hook::smash_fzmedia::TextAnchorStage::kImage;
      return false;
    }
    result = fushi_voice_hook::smash_fzmedia::DeriveTextAnchors(view);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    *stage = fushi_voice_hook::smash_fzmedia::TextAnchorStage::kImage;
    return false;
  }
  *stage = result.failed_stage;
  if (!result.ok) return false;
  *out = result.anchors;
  *base_out = reinterpret_cast<uintptr_t>(exe);
  return true;
}

// 游戏线程侧：段落装配器 + seqlock 邮箱。
fushi_voice_hook::smash_fzmedia::ParagraphAssembler g_smash_assembler;
wchar_t g_smash_run_scratch[fushi_voice_hook::smash_fzmedia::kMaxRunUnits] = {};
volatile LONG g_smash_assembler_busy = 0;

struct SmashParagraphPost {
  uint64_t post_seq = 0u;
  uint64_t run_end_ms = 0u;  // 0 = run 仍在排版中
  fushi_voice_hook::smash_fzmedia::LineSnapshot line;
};
struct SmashParagraphMailbox {
  volatile LONG seq = 0;  // 奇数 = 写入中
  SmashParagraphPost post;
};
SmashParagraphMailbox g_smash_paragraph_mailbox;

void PostSmashParagraph() {
  SmashParagraphMailbox* box = &g_smash_paragraph_mailbox;
  InterlockedIncrement(&box->seq);
  MemoryBarrier();
  box->post.post_seq = g_smash_assembler.post_seq;
  box->post.run_end_ms =
      g_smash_assembler.run_active ? 0u : g_smash_assembler.last_run_end_ms;
  box->post.line = g_smash_assembler.line;
  MemoryBarrier();
  InterlockedIncrement(&box->seq);
}

bool TryReadSmashParagraphMailbox(SmashParagraphPost* out, uint64_t last_seen_post) {
  SmashParagraphMailbox* box = &g_smash_paragraph_mailbox;
  const LONG before = InterlockedCompareExchange(&box->seq, 0, 0);
  if ((before & 1) != 0) return false;
  // 没有新投递就不搬那 11 KB（提示性读取，正式判定仍在拷贝后由 post_seq 决定）。
  if (box->post.post_seq <= last_seen_post) return false;
  MemoryBarrier();
  *out = box->post;
  MemoryBarrier();
  return InterlockedCompareExchange(&box->seq, 0, 0) == before;
}

struct SmashLayoutObservation {
  uint32_t units = 0u;
  float x0 = 0.0f;
  float y0 = 0.0f;
  float font_px = 0.0f;
  float scale = 0.0f;
  int32_t line_pitch = 0;
};

// onEnter：run 的 UTF-16 边界与 layer 的笔位置/字号；index==0 时顺带拷 run 文本。
bool ReadSmashLayoutBeforeUnsafe(const void* layer, const void* run, uint64_t index,
                                 SmashLayoutObservation* obs, wchar_t* text_out,
                                 uint32_t text_capacity, bool copy_text) {
  const fushi_voice_hook::smash_fzmedia::TextAnchors& a = g_smash_text_anchors;
  const auto* run_bytes = reinterpret_cast<const uint8_t*>(run);
  const auto* layer_bytes = reinterpret_cast<const uint8_t*>(layer);
  __try {
    if (run == nullptr || layer == nullptr) return false;
    const wchar_t* begin = nullptr;
    const wchar_t* end = nullptr;
    memcpy(&begin, run_bytes + a.text_begin, sizeof(begin));
    memcpy(&end, run_bytes + a.text_end, sizeof(end));
    if (begin == nullptr || end == nullptr || end < begin) return false;
    const uint64_t units = static_cast<uint64_t>(end - begin);
    if (units == 0u || units > 65536u || index >= units) return false;
    obs->units = static_cast<uint32_t>(units);
    memcpy(&obs->x0, layer_bytes + a.cursor_x, sizeof(obs->x0));
    memcpy(&obs->y0, layer_bytes + a.cursor_y, sizeof(obs->y0));
    memcpy(&obs->font_px, layer_bytes + a.font_px, sizeof(obs->font_px));
    memcpy(&obs->scale, layer_bytes + a.scale, sizeof(obs->scale));
    memcpy(&obs->line_pitch, layer_bytes + a.line_pitch, sizeof(obs->line_pitch));
    if (copy_text) {
      const uint32_t copy =
          obs->units < text_capacity ? obs->units : text_capacity;
      memcpy(text_out, begin, static_cast<size_t>(copy) * sizeof(wchar_t));
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

bool ReadSmashCursorAfterUnsafe(const void* layer, float* x1, float* y1) {
  const fushi_voice_hook::smash_fzmedia::TextAnchors& a = g_smash_text_anchors;
  const auto* layer_bytes = reinterpret_cast<const uint8_t*>(layer);
  __try {
    memcpy(x1, layer_bytes + a.cursor_x, sizeof(*x1));
    memcpy(y1, layer_bytes + a.cursor_y, sizeof(*y1));
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
  return true;
}

// bool layoutChar(layer /*rcx*/, run /*rdx*/, index /*r8*/, next /*r9*/)，返回 al。
// 只做有界拷贝：run 文本 ≤ kMaxRunUnits、每字一个 GlyphCell、run 结束时一次快照投递。
uintptr_t Detour_SmashLayoutChar(void* layer, void* run, uint64_t index,
                                 uint64_t* next) {
  namespace sf = fushi_voice_hook::smash_fzmedia;
  SmashLayoutObservation obs;
  bool observed = false;
  if (g_capture_enabled &&
      InterlockedCompareExchange(&g_smash_text_enabled, 0, 0) != 0 &&
      InterlockedCompareExchange(&g_smash_assembler_busy, 1, 0) == 0) {
    const bool run_start = index == 0u;
    observed = ReadSmashLayoutBeforeUnsafe(layer, run, index, &obs,
                                           g_smash_run_scratch, sf::kMaxRunUnits,
                                           run_start);
    if (observed && run_start) {
      const ULONGLONG now = GetTickCount64();
      observed = g_smash_assembler.BeginRun(
          layer, g_smash_run_scratch,
          obs.units < sf::kMaxRunUnits ? obs.units : sf::kMaxRunUnits, now,
          obs.font_px, static_cast<float>(obs.line_pitch));
      // 文本在 run 开头就完整可得：平衡段落立即投递（worker 立刻写文本道，配对窗口
      // 不吃排版时长）；字格随后在 run 结束时再投递一次。同 run 重排不投。
      if (observed && !g_smash_assembler.last_begin_relayout) PostSmashParagraph();
    } else if (observed && !g_smash_assembler.run_active) {
      observed = false;  // hook 装在 run 中途：等下一个 run 从 0 开始
    }
    InterlockedExchange(&g_smash_assembler_busy, 0);
  }
  const uintptr_t result = g_orig_smash_layout_char(layer, run, index, next);
  if (observed && InterlockedCompareExchange(&g_smash_assembler_busy, 1, 0) == 0) {
    if ((result & 0xffu) != 0u) {
      float x1 = 0.0f;
      float y1 = 0.0f;
      if (ReadSmashCursorAfterUnsafe(layer, &x1, &y1)) {
        g_smash_assembler.AppendCell(
            static_cast<uint32_t>(index),
            sf::ComputeGlyphCell(obs.x0, obs.y0, x1, y1, obs.font_px, obs.scale,
                                 L'x'));
      }
    }
    if (index + 1u >= obs.units) {
      if (g_smash_assembler.EndRun(GetTickCount64())) PostSmashParagraph();
    }
    InterlockedExchange(&g_smash_assembler_busy, 0);
  }
  return result;
}

// 锚点重扫策略：SteamStub 正版在入口后才解包 .text，扫失败每 500ms 重试、上限 120s；
// install() 再次被调用（模块加载 / 启动）时 force 立即重试且不计预算。
bool TryHookSmashText(ULONGLONG now, bool force) {
  namespace sf = fushi_voice_hook::smash_fzmedia;
  if (InterlockedCompareExchange(&g_smash_identity_state, 0, 0) != 1) return false;
  if (InterlockedCompareExchange(&g_smash_text_hook_ready, 0, 0) != 0) return true;
  if (InterlockedCompareExchange(&g_smash_text_anchor_state, 0, 0) == 0) {
    if (!force) {
      if (now < g_smash_anchor_next_attempt_ms) return false;
      if (g_smash_anchor_first_attempt_ms != 0u &&
          now - g_smash_anchor_first_attempt_ms > sf::kAnchorRetryBudgetMs) {
        SetSmashDiagnostic(
            fushi_voice_hook::smash_fzmedia::kDiagAnchorRetryExhausted);
        return false;
      }
    }
    if (g_smash_anchor_first_attempt_ms == 0u) g_smash_anchor_first_attempt_ms = now;
    g_smash_anchor_next_attempt_ms = now + sf::kAnchorRetryIntervalMs;
    ++g_smash_anchor_attempts;
    sf::TextAnchors anchors;
    sf::TextAnchorStage stage = sf::TextAnchorStage::kNone;
    uintptr_t base = 0u;
    if (!ScanSmashTextAnchorsUnsafe(&anchors, &stage, &base)) {
      g_smash_anchor_last_stage = stage;
      SetSmashDiagnostic(
          fushi_voice_hook::smash_fzmedia::kDiagTextAnchorsUnresolved);
      return false;
    }
    g_smash_text_anchors = anchors;
    g_smash_exe_base = base;
    g_smash_anchor_last_stage = stage;
    InterlockedExchange(&g_smash_text_anchor_state, 1);
    SetSmashDiagnostic(
        fushi_voice_hook::smash_fzmedia::kDiagTextAnchorsResolved);
  }
  void* target = reinterpret_cast<void*>(g_smash_exe_base +
                                         g_smash_text_anchors.layout_char_rva);
  if (!fushi_voice_hook::exact_lookup::IsExecutableAddress(target)) return false;
  HunexGgeHookSpec hooks[] = {
      {target, reinterpret_cast<void*>(&Detour_SmashLayoutChar),
       reinterpret_cast<void**>(&g_orig_smash_layout_char)},
  };
  if (!InstallHunexGgeHookGroup(hooks, _countof(hooks))) return false;
  InterlockedExchange(&g_smash_text_enabled, 1);
  InterlockedExchange(&g_smash_text_hook_ready, 1);
  SetSmashDiagnostic(fushi_voice_hook::smash_fzmedia::kDiagTextHookReady);
  return true;
}

// ── worker：段落发布 ─────────────────────────────────────────────────────────
struct SmashTextWorkerState {
  uint64_t last_taken_post_seq = 0u;
  bool pending_valid = false;
  SmashParagraphPost pending;
  wchar_t last_text[fushi_voice_hook::smash_fzmedia::kMaxLineUnits] = {};
  uint32_t last_text_units = 0u;
  uint64_t last_first_tick_ms = 0u;
  uint64_t last_lane_write_ms = 0u;
  uint64_t last_text_event_id = 0u;
  uint64_t generation = 0u;
};
SmashTextWorkerState g_smash_text_worker;

// 同一段落的两次投递（run 开头写文本、run 结束带字格）只写一次文本道；同文本 1000ms
// 内也不重写。每次投递都推进 generation 交给 lookup 侧。
void PublishSmashParagraph(fushi_voice_hook::smash_fzmedia::LineSnapshot* line,
                           ULONGLONG now) {
  namespace sf = fushi_voice_hook::smash_fzmedia;
  if (!g_capture_enabled || g_header == nullptr || g_text_base == nullptr ||
      !g_text_cs_ready || line->unit_count == 0u ||
      line->unit_count > sf::kMaxLineUnits) {
    return;
  }
  SmashTextWorkerState* worker = &g_smash_text_worker;
  const bool same_text = sf::SameText(worker->last_text, worker->last_text_units,
                                      line->text, line->unit_count);
  const bool same_paragraph = worker->last_first_tick_ms == line->first_tick_ms;
  const bool suppress_lane_write =
      same_text && worker->last_text_event_id != 0u &&
      (same_paragraph ||
       sf::WithinDedupeWindow(worker->last_lane_write_ms, now,
                              sf::kTextDedupeWindowMs));
  uint64_t text_event_id = suppress_lane_write ? worker->last_text_event_id : 0u;
  if (!suppress_lane_write) {
    // 这个身份描述 smash KAG 文本层的布局 ABI，不含 RVA、基址或 exe 哈希。
    constexpr uint64_t kSmashFzmediaTextComponentIdentity = 0x534D415348545854ull;
    constexpr wchar_t kSmashTextHookCode[] = L"ENGINE:SMASH:kag_text_layer";
    constexpr char kSmashTextHookName[] = "smash exact";
    const uint64_t thread_id = fushi_voice_hook::NativeTextThreadIdFrom(
        kSmashFzmediaTextComponentIdentity, kSmashTextHookCode,
        kSmashTextHookName);
    EnterCriticalSection(&g_text_cs);
    fushi_voice_hook::TextLaneWrite write;
    write.thread_id = thread_id;
    write.thread_address = g_smash_text_anchors.layout_char_rva;
    write.process_id = GetCurrentProcessId();
    write.source_kind = fushi_voice_hook::kTextSourceSmashFzmedia;
    write.is_utf8 = 0;
    write.text = line->text;
    write.byte_len = line->unit_count * static_cast<uint32_t>(sizeof(wchar_t));
    write.hook_name = kSmashTextHookName;
    write.hook_code = kSmashTextHookCode;
    text_event_id = fushi_voice_hook::WriteTextLaneEvent(
        g_header, fushi_voice_hook::kNativeThreadPreviewStart,
        fushi_voice_hook::kTextLaneCount, write);
    LeaveCriticalSection(&g_text_cs);
    if (text_event_id == 0u) return;
    memcpy(worker->last_text, line->text,
           static_cast<size_t>(line->unit_count) * sizeof(wchar_t));
    worker->last_text_units = line->unit_count;
    worker->last_first_tick_ms = line->first_tick_ms;
    worker->last_lane_write_ms = now;
    worker->last_text_event_id = text_event_id;
    // 精确引擎文本比 GDI 字形回退干净；字段名历史上叫 luna，契约只是「有精确文本生产者」。
    g_header->luna_active = 1;
    SetSmashDiagnostic(
        fushi_voice_hook::smash_fzmedia::kDiagParagraphPublished);
  }
  line->text_event_id = text_event_id;
  line->generation = ++worker->generation;
  fushi_voice_hook::smash_fzmedia::LookupPublishSnapshot(*line);
}

void ProcessSmashParagraphMailbox(ULONGLONG now) {
  namespace sf = fushi_voice_hook::smash_fzmedia;
  SmashTextWorkerState* worker = &g_smash_text_worker;
  if (InterlockedCompareExchange(&g_smash_text_hook_ready, 0, 0) == 0) return;
  SmashParagraphPost post;
  if (TryReadSmashParagraphMailbox(&post, worker->last_taken_post_seq) &&
      post.post_seq > worker->last_taken_post_seq) {
    worker->last_taken_post_seq = post.post_seq;
    if (post.line.complete) {
      PublishSmashParagraph(&post.line, now);
      worker->pending_valid = false;
    } else {
      worker->pending = post;
      worker->pending_valid = true;
    }
  }
  if (worker->pending_valid &&
      sf::PartialPublishDue(worker->pending.run_end_ms, now)) {
    PublishSmashParagraph(&worker->pending.line, now);
    worker->pending_valid = false;
  }
}

// ── worker：语音落盘 ─────────────────────────────────────────────────────────
char g_smash_last_voice_id[fushi_voice_hook::smash_fzmedia::kVoiceIdChars] = {};
uint64_t g_smash_last_voice_tick_ms = 0u;

uint64_t ReadSmashSharedU64(volatile uint64_t* value) {
  return value == nullptr
             ? 0u
             : static_cast<uint64_t>(InterlockedCompareExchange64(
                   reinterpret_cast<volatile LONGLONG*>(value), 0, 0));
}

// 只扫选定线程那一条道（v13 分道后其余道与本次配对无关）。
size_t CollectSmashSelectedLaneCandidates(
    uint64_t selected_thread_id, fushi_voice_hook::VoiceTextCandidate* candidates,
    size_t capacity) {
  if (g_header == nullptr || g_text_base == nullptr || selected_thread_id == 0u)
    return 0u;
  fushi_voice_hook::TextLane* lanes = fushi_voice_hook::TextLanesOf(g_header);
  const uint32_t lane_count = lanes == nullptr ? 0u : g_header->text_lane_count;
  uint32_t lane_index = 0u;
  bool lane_found = false;
  for (uint32_t i = 0u; i < lane_count; ++i) {
    if (ReadSmashSharedU64(&lanes[i].thread_id) == selected_thread_id) {
      lane_index = i;
      lane_found = true;
      break;
    }
  }
  if (!lane_found) return 0u;
  const uint64_t lane_written = ReadSmashSharedU64(&lanes[lane_index].write_count);
  const uint32_t lane_slots = g_header->text_lane_slot_count;
  const uint64_t first_lane_seq =
      lane_written > lane_slots ? lane_written - lane_slots + 1u : 1u;
  size_t count = 0u;
  for (uint64_t lane_seq = first_lane_seq;
       lane_seq <= lane_written && count < capacity; ++lane_seq) {
    auto* slot = reinterpret_cast<fushi_voice_hook::TextSlot*>(
        fushi_voice_hook::TextLaneSlotAt(g_header, lane_index, lane_seq));
    if (slot == nullptr) continue;
    if (ReadSmashSharedU64(&slot->lane_seq) != lane_seq) continue;
    MemoryBarrier();
    fushi_voice_hook::VoiceTextCandidate candidate;
    candidate.seq = ReadSmashSharedU64(&slot->seq);
    candidate.timestamp_ms = slot->timestamp_ms;
    candidate.thread_id = slot->thread_id;
    candidate.byte_len = slot->byte_len;
    candidate.is_line = slot->event_kind == fushi_voice_hook::kTextEventLine;
    MemoryBarrier();
    if (ReadSmashSharedU64(&slot->lane_seq) != lane_seq) continue;
    candidates[count++] = candidate;
  }
  return count;
}

void ProcessSmashVoiceSlots(ULONGLONG now) {
  namespace sf = fushi_voice_hook::smash_fzmedia;
  for (int i = 0; i < kSmashVoiceSlots; ++i) {
    SmashVoiceSlot* slot = &g_smash_voice_slots[i];
    if (InterlockedCompareExchange(&slot->state, 3, 2) != 2) continue;
    if (!slot->dedupe_checked) {
      slot->dedupe_checked = true;
      if (sf::SameVoiceId(g_smash_last_voice_id, slot->id) &&
          sf::WithinDedupeWindow(g_smash_last_voice_tick_ms, slot->tick_ms,
                                 sf::kVoiceDedupeWindowMs)) {
        InterlockedExchange(&slot->state, 0);
        continue;
      }
      memcpy(g_smash_last_voice_id, slot->id, sizeof(g_smash_last_voice_id));
      g_smash_last_voice_tick_ms = slot->tick_ms;
    }
    fushi_voice_hook::VoiceTextCandidate
        candidates[fushi_voice_hook::kTextLaneSlotCount] = {};
    uint64_t selected_thread_id = slot->selected_thread_id;
    if (g_header == nullptr ||
        ReadSmashSharedU64(&g_header->selected_text_thread_id) != selected_thread_id) {
      selected_thread_id = 0u;
    }
    const size_t candidate_count = CollectSmashSelectedLaneCandidates(
        selected_thread_id, candidates, _countof(candidates));
    const uint64_t deadline_ms = slot->tick_ms + sf::kVoicePairingWindowMs;
    const auto decision = fushi_voice_hook::ResolveFollowingSelectedText(
        slot->tick_ms, deadline_ms, now, selected_thread_id,
        slot->baseline_text_seq, candidates, candidate_count);
    if (decision.state == fushi_voice_hook::VoiceResourcePairState::kWait) {
      InterlockedExchange(&slot->state, 2);
      continue;
    }
    wchar_t storage_name[sf::kVoiceIdChars + 8u] = {};
    bool written = false;
    if (sf::BuildVoiceStorageName(slot->id, storage_name, _countof(storage_name))) {
      written = WriteVoiceOggAt(slot->data, slot->bytes, storage_name,
                                slot->tick_ms, decision.text_event_id);
    }
    if (written) {
      SetXAudioDiagnostic(fushi_voice_hook::kXAudioDiagGameResourcePublished);
      SetSmashDiagnostic(fushi_voice_hook::smash_fzmedia::kDiagVoicePublished);
    }
    slot->bytes = 0u;
    slot->id[0] = '\0';
    InterlockedExchange(&slot->state, 0);
  }
}

void ResetSmashWorkerState() {
  g_smash_text_worker = SmashTextWorkerState();
  memset(g_smash_last_voice_id, 0, sizeof(g_smash_last_voice_id));
  g_smash_last_voice_tick_ms = 0u;
  for (int i = 0; i < kSmashVoiceSlots; ++i) {
    InterlockedExchange(&g_smash_voice_slots[i].state, 0);
  }
}

#endif  // _M_X64

class SmashFzmediaAdapter final : public fushi_voice_hook::EngineAdapter {
 public:
  const char* id() const override { return "smash_fzmedia"; }
  bool probe() const override {
#if defined(_M_X64)
    return RefreshSmashIdentity(false);
#else
    return false;
#endif
  }
  bool install() override { return Install(true); }
  fushi_voice_hook::AdapterCapability capabilities() const override {
    return fushi_voice_hook::AdapterCapability::kText |
           fushi_voice_hook::AdapterCapability::kResourceAudio;
  }
  void onModuleLoaded(const wchar_t* module_name) override {
    if (module_name == nullptr ||
        fushi_voice_hook::MatchesSmashFzmediaProfile(module_name)) {
      install();
    }
  }
  void ProcessPendingEvents() {
#if defined(_M_X64)
    const ULONGLONG now = GetTickCount64();
    Install(false);
    ProcessSmashParagraphMailbox(now);
    ProcessSmashVoiceSlots(now);
    if (lookup_installed_) fushi_voice_hook::smash_fzmedia::LookupPoll(g_header, now);
#endif
  }
  fushi_voice_hook::LookupAdmissionReport lookupAdmission() const override {
    fushi_voice_hook::LookupAdmissionReport report;
#if defined(_M_X64)
    report.state = lookup_sensor_available()
                       ? fushi_voice_hook::kLookupAdmissionSensorInstalled
                       : fushi_voice_hook::kLookupAdmissionIdentityAccepted;
#else
    report.state = fushi_voice_hook::kLookupAdmissionEngineUnsupported;
#endif
    return report;
  }
  bool lookup_sensor_available() const {
#if defined(_M_X64)
    return InterlockedCompareExchange(&g_smash_identity_state, 0, 0) == 1 &&
           InterlockedCompareExchange(&g_smash_text_hook_ready, 0, 0) != 0 &&
           lookup_installed_;
#else
    return false;
#endif
  }
  void shutdown() override {
#if defined(_M_X64)
    InterlockedExchange(&g_smash_text_enabled, 0);
    InterlockedExchange(&g_smash_audio_enabled, 0);
    if (lookup_installed_) {
      fushi_voice_hook::smash_fzmedia::LookupShutdown(g_header);
      lookup_installed_ = false;
    }
    ResetSmashWorkerState();
#endif
    installed_ = false;
  }
  fushi_voice_hook::AdapterDiagnostics diagnostics() const override {
    return {id(), probe(), installed_,
            static_cast<uint32_t>(
                InterlockedCompareExchange(&g_smash_diagnostics, 0, 0))};
  }

 private:
  bool Install(bool force) {
#if defined(_M_X64)
    if (!RefreshSmashIdentity(force)) return installed_;
    const ULONGLONG now = GetTickCount64();
    bool audio_ready = InterlockedCompareExchange(&g_smash_audio_hooks_ready, 0, 0) != 0;
    if (!audio_ready && (force || now >= audio_next_attempt_ms_)) {
      audio_next_attempt_ms_ = now + 500u;
      audio_ready = TryHookSmashFzmediaAudio();
    }
    const bool text_ready = TryHookSmashText(now, force);
    if (text_ready && !lookup_installed_ && g_header != nullptr &&
        (force || now >= lookup_next_attempt_ms_)) {
      lookup_next_attempt_ms_ = now + 500u;
      lookup_installed_ = fushi_voice_hook::smash_fzmedia::LookupInstall(g_header);
    }
    installed_ = installed_ || audio_ready || text_ready;
#else
    (void)force;
#endif
    return installed_;
  }

  bool installed_ = false;
  bool lookup_installed_ = false;
  ULONGLONG lookup_next_attempt_ms_ = 0u;
  ULONGLONG audio_next_attempt_ms_ = 0u;
};
