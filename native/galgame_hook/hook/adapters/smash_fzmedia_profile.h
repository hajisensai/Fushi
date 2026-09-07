#pragma once

// smash/fzmedia（TYPE-MOON smash 框架：Fate/stay night REMASTERED 系）的 profile 常量与
// 纯函数层。这里没有 Win32 / IPC 调用：准入签名、fzmedia 导出前缀、语音载荷校验、文件
// 命名、MSVC std::string 定位、段落装配器（引号平衡合并续行）与去重窗口都在此处，
// 供 smash_fzmedia_adapter.inc 使用并由 tests/smash_fzmedia_adapter_test.cpp 离线覆盖。
//
// 身份是**引擎级结构签名**，没有 exe/module 哈希白名单（见 spec「准入」）：
//   1. 主 exe 导入表存在 DLL 名以 `null-ge-` 开头且符号含 `IGameEngine@fw@smash@@` 的导入；
//   2. 进程已加载名以 `fzmedia-` 开头的模块，且导出表含 kFzmediaRequiredExportPrefixes 全部；
//   3. x64。

#include <cstddef>
#include <cstdint>
#include <cstring>

// 锚点推导头必须在这里（全局作用域，经 generated/profile_includes.inc 进入 dll_main）
// 被首次包含：dll_main 的 adapter 展开区在匿名命名空间里，若由 adapter.inc 首次包含，
// 会生出 `anonymous::fushi_voice_hook::smash_fzmedia` 遮蔽全局同名命名空间，随后所有
// `fushi_voice_hook::...` 限定名都会解析错（Leaf 的 profile.h 拉 exact_lookup_signature.h
// 是同一个原因）。
#include "smash_fzmedia_anchors.h"
#include "smash_fzmedia_shared.h"

namespace fushi_voice_hook {

// ── 模块名过滤（registry onModuleLoaded 的粗筛）────────────────────────────
inline bool SmashFzmediaModuleNameStartsWith(const wchar_t* module_name,
                                             const wchar_t* prefix) {
  if (module_name == nullptr || prefix == nullptr) return false;
  for (size_t i = 0u;; ++i) {
    if (prefix[i] == L'\0') return true;
    wchar_t lhs = module_name[i];
    wchar_t rhs = prefix[i];
    if (lhs >= L'A' && lhs <= L'Z') lhs = static_cast<wchar_t>(lhs - L'A' + L'a');
    if (rhs >= L'A' && rhs <= L'Z') rhs = static_cast<wchar_t>(rhs - L'A' + L'a');
    if (lhs != rhs) return false;
  }
}

// 只回答「这个模块名是不是 smash 框架的引擎/媒体 DLL」，用来决定是否值得再跑一次
// install()。它不是准入：准入是导入表 + 导出表结构签名（见 adapter 的 ProbeIdentity）。
inline bool MatchesSmashFzmediaProfile(const wchar_t* module_name) {
  return SmashFzmediaModuleNameStartsWith(module_name, L"fzmedia-") ||
         SmashFzmediaModuleNameStartsWith(module_name, L"null-ge-");
}

namespace smash_fzmedia {

// v23 起 xaudio_diagnostics2 已被 KiriKiri 安装链占满；smash/fzmedia 的
// 分型位由 AdapterReportSlot.flags 发布，避免为单个 adapter 的私有读数扩 IPC。
inline constexpr uint32_t kDiagFamilyMatched = 0x00000001u;
inline constexpr uint32_t kDiagFzmediaHooksReady = 0x00000002u;
inline constexpr uint32_t kDiagTextAnchorsResolved = 0x00000004u;
inline constexpr uint32_t kDiagTextAnchorsUnresolved = 0x00000008u;
inline constexpr uint32_t kDiagTextHookReady = 0x00000010u;
inline constexpr uint32_t kDiagVoiceObserved = 0x00000020u;
inline constexpr uint32_t kDiagVoiceQueueFull = 0x00000040u;
inline constexpr uint32_t kDiagVoicePublished = 0x00000080u;
inline constexpr uint32_t kDiagParagraphPublished = 0x00000100u;
inline constexpr uint32_t kDiagVoiceBufferLeaked = 0x00000200u;
inline constexpr uint32_t kDiagAnchorRetryExhausted = 0x00000400u;

// ── 结构签名常量 ───────────────────────────────────────────────────────────
inline constexpr char kGameEngineDllPrefix[] = "null-ge-";
inline constexpr char kGameEngineImportSubstring[] = "IGameEngine@fw@smash@@";
inline constexpr char kMediaDllPrefix[] = "fzmedia-";
inline constexpr wchar_t kMediaDllPrefixW[] = L"fzmedia-";

// fzmedia 导出（MSVC 修饰名前缀）。create 的前缀带到参数类型，避免与重载撞名。
inline constexpr char kExportSoundManagerCreate[] =
    "?create@SoundManager@sound@fz@@QEAA?AV?$shared_ptr@VSoundObject@sound@fz@@@std@@AEBVSoundResourceId";
inline constexpr char kExportSoundObjectPlay[] =
    "?play@SoundObject@sound@fz@@QEAAXAEBVSoundPlayInfo";
inline constexpr char kExportSoundObjectGetId[] = "?getId@SoundObject@sound@fz@@";
inline constexpr char kExportSoundObjectConvertToRawFile[] =
    "?convertToRawFile@SoundObject@sound@fz@@";
inline constexpr char kExportSoundObjectIsReady[] =
    "?isReady@SoundObject@sound@fz@@";
inline constexpr const char* kFzmediaRequiredExportPrefixes[] = {
    kExportSoundManagerCreate, kExportSoundObjectPlay, kExportSoundObjectGetId,
    kExportSoundObjectConvertToRawFile, kExportSoundObjectIsReady,
};
inline constexpr size_t kFzmediaRequiredExportCount = 5u;
// fzmedia 的 std::vector 由它导入的 CRT operator delete 释放（未定尺寸 / 定尺寸两种修饰）。
inline constexpr char kImportOperatorDelete[] = "??3@YAXPEAX@Z";
inline constexpr char kImportOperatorDeleteSized[] = "??3@YAXPEAX_K@Z";

// ── 时间窗口 ───────────────────────────────────────────────────────────────
inline constexpr uint64_t kContinuationWindowMs = 2500u;   // 无续行则以 partial 发布
inline constexpr uint64_t kTextDedupeWindowMs = 1000u;      // 同文本去重
inline constexpr uint64_t kVoiceDedupeWindowMs = 2000u;     // 同 id 去重
inline constexpr uint64_t kVoicePairingWindowMs = 1500u;    // 资源先于文本的配对窗口
inline constexpr uint64_t kAnchorRetryIntervalMs = 500u;    // SteamStub 解包后重扫
inline constexpr uint64_t kAnchorRetryBudgetMs = 120000u;

// ── 语音载荷 ───────────────────────────────────────────────────────────────
inline constexpr uint32_t kVoiceSlotBytes = 1024u * 1024u;  // 单条 Ogg 上限 1 MiB
inline constexpr size_t kVoiceIdChars = 64u;

inline bool IsVoiceCategory(int32_t category) {
  return category == kVoiceSoundCategory;
}

// convertToRawFile 的输出必须是完整 Ogg 容器（`OggS` 页头）且不超过槽上限。
inline bool ValidateOggPayload(const uint8_t* data, uint64_t bytes) {
  return data != nullptr && bytes >= 4u && bytes <= kVoiceSlotBytes &&
         data[0] == 'O' && data[1] == 'g' && data[2] == 'g' && data[3] == 'S';
}

// `sav0613_shi_0010.fcd` → `sav0613_shi_0010.ogg`。去目录、去 .fcd（大小写不敏感）、
// 非 ASCII 可打印字符替换成 '_'。宿主只收 .ogg/.xwma/.wav。
inline bool BuildVoiceStorageName(const char* id, wchar_t* out, size_t out_chars) {
  if (id == nullptr || out == nullptr || out_chars < 8u) return false;
  size_t begin = 0u;
  size_t len = 0u;
  for (; id[len] != '\0' && len < 4096u; ++len) {
    if (id[len] == '/' || id[len] == '\\') begin = len + 1u;
  }
  size_t end = len;
  if (end - begin >= 4u) {
    const char* ext = id + end - 4u;
    if (ext[0] == '.' && (ext[1] == 'f' || ext[1] == 'F') &&
        (ext[2] == 'c' || ext[2] == 'C') && (ext[3] == 'd' || ext[3] == 'D')) {
      end -= 4u;
    }
  }
  if (end <= begin) return false;
  size_t written = 0u;
  for (size_t i = begin; i < end; ++i) {
    if (written + 5u >= out_chars) return false;  // 留 ".ogg" + NUL
    const char c = id[i];
    const bool printable = c > 0x20 && c < 0x7f && c != ':' && c != '*' &&
                           c != '?' && c != '"' && c != '<' && c != '>' &&
                           c != '|' && c != '/' && c != '\\';
    out[written++] = printable ? static_cast<wchar_t>(c) : L'_';
  }
  const wchar_t suffix[] = L".ogg";
  for (size_t i = 0u; i < 5u; ++i) out[written + i] = suffix[i];
  return true;
}

// MSVC x64 std::string 的 32 字节表示：{union{buf[16]; ptr}, size, capacity}；
// capacity < 16 时内联。只**定位**不解引用——解引用必须在 SEH 保护下由调用方完成。
inline bool LocateMsvcStdString(const uint8_t* repr, const char** data,
                                size_t* len) {
  if (repr == nullptr || data == nullptr || len == nullptr) return false;
  uint64_t size = 0u;
  uint64_t capacity = 0u;
  std::memcpy(&size, repr + 16u, sizeof(size));
  std::memcpy(&capacity, repr + 24u, sizeof(capacity));
  if (size > capacity || capacity > 4096u) return false;
  if (capacity < 16u) {
    *data = reinterpret_cast<const char*>(repr);
  } else {
    uint64_t pointer = 0u;
    std::memcpy(&pointer, repr, sizeof(pointer));
    if (pointer == 0u) return false;
    *data = reinterpret_cast<const char*>(static_cast<uintptr_t>(pointer));
  }
  *len = static_cast<size_t>(size);
  return true;
}

// ── MSVC STL 大块分配的释放形状 ────────────────────────────────────────────
// vc14 STL 对 ≥ 4096 字节的分配走 _Allocate_manually_vector_aligned：真正的 new 块指针
// 存在用户指针前一个槽，回退量在 [2*sizeof(void*), 2*sizeof(void*)+31]。释放必须还原到
// 那个指针，否则直接 delete(begin) 会破坏堆。形状对不上时**宁可泄漏**这一块。
inline constexpr uint64_t kMsvcBigAllocationThreshold = 4096u;
inline constexpr uint64_t kMsvcBigAllocationMinBackShift = 16u;
inline constexpr uint64_t kMsvcBigAllocationMaxBackShift = 16u + 31u;

// 返回应交给 operator delete 的指针；无法安全判定时返回 0（调用方泄漏并记诊断）。
inline uint64_t ResolveMsvcVectorDeallocationPointer(uint64_t begin,
                                                     uint64_t capacity_bytes,
                                                     uint64_t stored_container) {
  if (begin == 0u) return 0u;
  if (capacity_bytes < kMsvcBigAllocationThreshold) return begin;
  if (stored_container == 0u || stored_container >= begin) return 0u;
  const uint64_t shift = begin - stored_container;
  if (shift < kMsvcBigAllocationMinBackShift ||
      shift > kMsvcBigAllocationMaxBackShift) {
    return 0u;
  }
  return stored_container;
}

// ── 去重窗口 ───────────────────────────────────────────────────────────────
inline bool WithinDedupeWindow(uint64_t previous_ms, uint64_t now_ms,
                               uint64_t window_ms) {
  return previous_ms != 0u && now_ms >= previous_ms &&
         now_ms - previous_ms <= window_ms;
}

inline bool SameVoiceId(const char* a, const char* b) {
  return a != nullptr && b != nullptr && std::strncmp(a, b, kVoiceIdChars) == 0;
}

inline bool SameText(const wchar_t* a, uint32_t a_units, const wchar_t* b,
                     uint32_t b_units) {
  return a_units == b_units &&
         (a_units == 0u ||
          std::memcmp(a, b, static_cast<size_t>(a_units) * sizeof(wchar_t)) == 0);
}

// ── 字格计算 ───────────────────────────────────────────────────────────────
// layoutChar 前后的笔位置 (x0,y0)→(x1,y1)：x1 < x0 说明引擎自动换行了，该字占新行
// [0, x1)；否则占 [x0, x1)。高度按 font_px × scale（scale ≤ 0 视为 1）。
inline GlyphCell ComputeGlyphCell(float x0, float y0, float x1, float y1,
                                  float font_px, float scale, wchar_t unit) {
  GlyphCell cell;
  const float h = font_px * (scale > 0.0f ? scale : 1.0f);
  if (x1 < x0) {
    cell.x = 0.0f;
    cell.y = y1;
    cell.w = x1;
  } else {
    cell.x = x0;
    cell.y = y0;
    cell.w = x1 - x0;
  }
  cell.h = h;
  cell.inked = IsNonInkUnit(unit) ? 0u : 1u;
  return cell;
}

// 单空格 run 是 KAG 的等待光标，不是台词。
inline bool IsWaitCursorRun(const wchar_t* text, uint32_t units) {
  return units == 1u && text != nullptr && text[0] == L' ';
}

// ── 段落装配器（游戏主线程独占）─────────────────────────────────────────────
// 一个 KAG 段落可跨多个 run（[r]）。规则（spec「文本」）：
//   * index==0 = 新 run 开始：若上一段落 complete（引号平衡）、或距上一 run 结束
//     > kContinuationWindowMs、或 layer 指针变化 → 新段落；否则续行直接拼接。
//   * 同 layer 同文本再次从 index==0 开始 = 引擎重排（逐帧 re-layout / 重绘），
//     重置当前 run 的字格而不是把文本再拼一遍。
//   * run 结束（index==len-1）时按整段引号平衡判 complete，并要求把快照投递给 worker。
struct ParagraphAssembler {
  LineSnapshot line;
  wchar_t run_text[kMaxRunUnits] = {};
  uint32_t run_units = 0u;
  uint32_t run_base = 0u;
  const void* layer = nullptr;
  uint64_t last_run_end_ms = 0u;
  uint64_t post_seq = 0u;
  bool paragraph_open = false;
  bool run_active = false;
  // 最近一次 BeginRun 是不是同 run 重排（文本没变，只重填字格）。重排不值得在 run
  // 开头就投递：文本道不会变，字格又还是空的，投了只会让几何闪一下。
  bool last_begin_relayout = false;

  void Reset() { *this = ParagraphAssembler(); }

  bool BeginRun(const void* run_layer, const wchar_t* text, uint32_t units,
                uint64_t now_ms, float font_px, float line_pitch) {
    if (text == nullptr || units == 0u || IsWaitCursorRun(text, units)) {
      return false;
    }
    if (units > kMaxRunUnits) units = kMaxRunUnits;
    const bool same_run =
        paragraph_open && run_layer == layer && units == run_units &&
        std::memcmp(run_text, text, static_cast<size_t>(units) * sizeof(wchar_t)) == 0;
    last_begin_relayout = same_run;
    if (same_run) {
      // 重排：把本 run 的字格清掉重来，文本不再拼接。
      for (uint32_t i = run_base; i < line.unit_count; ++i) line.cells[i] = {};
      uint32_t copy = units;
      if (run_base + copy > kMaxLineUnits) copy = kMaxLineUnits - run_base;
      line.unit_count = run_base + copy;
      line.complete = false;
      run_active = true;
      return true;
    }
    const bool continuation =
        paragraph_open && !line.complete && run_layer == layer &&
        last_run_end_ms != 0u && now_ms >= last_run_end_ms &&
        now_ms - last_run_end_ms <= kContinuationWindowMs;
    if (!continuation) {
      line = LineSnapshot();
      line.first_tick_ms = now_ms;
      line.font_px = font_px;
      line.line_pitch = line_pitch;
      paragraph_open = true;
    }
    run_base = line.unit_count;
    uint32_t copy = units;
    if (run_base + copy > kMaxLineUnits) copy = kMaxLineUnits - run_base;
    std::memcpy(line.text + run_base, text,
                static_cast<size_t>(copy) * sizeof(wchar_t));
    for (uint32_t i = 0u; i < copy; ++i) line.cells[run_base + i] = {};
    line.unit_count = run_base + copy;
    line.complete = false;
    std::memcpy(run_text, text, static_cast<size_t>(units) * sizeof(wchar_t));
    run_units = units;
    layer = run_layer;
    run_active = true;
    return true;
  }

  void AppendCell(uint32_t run_index, const GlyphCell& cell) {
    if (!run_active) return;
    const uint32_t index = run_base + run_index;
    if (index >= line.unit_count) return;
    line.cells[index] = cell;
    line.cells[index].inked = IsNonInkUnit(line.text[index]) ? 0u : 1u;
  }

  // run 结束：返回 true 表示 line 应被投递（complete 已按引号平衡更新）。
  bool EndRun(uint64_t now_ms) {
    if (!run_active) return false;
    run_active = false;
    last_run_end_ms = now_ms;
    const int32_t balance = QuoteBalanceAfter(line.text, line.unit_count, 0);
    line.complete = balance == 0;
    ++post_seq;
    return true;
  }
};

// worker 侧：一个未完成段落在 run 结束后 kContinuationWindowMs 内没有续行就以 partial 发布。
inline bool PartialPublishDue(uint64_t run_end_ms, uint64_t now_ms) {
  return run_end_ms != 0u && now_ms >= run_end_ms &&
         now_ms - run_end_ms >= kContinuationWindowMs;
}

}  // namespace smash_fzmedia
}  // namespace fushi_voice_hook
