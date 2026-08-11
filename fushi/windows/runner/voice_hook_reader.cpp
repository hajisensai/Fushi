#include "voice_hook_reader.h"

#include <windows.h>

#include <algorithm>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <utility>

// v14 游戏内查词通道要往 Dart 投 hit / input，并接 Dart 的 present / dismiss。
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

// 🔴 IPC 契约**只有一份真相源**：`native/galgame_hook/include/voice_hook_ipc.h`。
// 这里曾经放一份 host 端手抄副本（`runner/voice_hook_ipc.h`），注释还写着「真相源在独立仓库
// hibiki-hook，须同步」——那个仓库早已合进本仓，人工同步这一步就成了纯粹的漂移源：本体
// fushi.exe 编副本、内置 helper 编真相源，两边一旦不同步，读侧就会拿旧契约去判新 helper。
// 实际已经漂开过：副本里的 `HasReadyGameResourceAudio` 漏了 Tyrano/BGI/Artemis/CatSystem2/
// Malie 五个引擎的 ready 位，这些引擎资源 hook 装好了本体也判 `raw_voice_ready=false`，
// 直接退回整机混音。副本已删除，改为直接 include 真相源——两侧编同一组常量与同一份结构布局，
// 版本漂移在结构上不再可能（守卫见 test/mining/gal_ipc_contract_single_source_test.dart）。
#include "../../../native/galgame_hook/include/voice_hook_ipc.h"
#include "../../../native/galgame_hook/include/voice_hook_utterance_window.h"

// galgame 一键制卡 C 阶段 —— 引擎-hook 共享内存读侧实现。见 voice_hook_reader.h。
// 纯 Win32 文件映射，无 COM、无异常（runner 以 _HAS_EXCEPTIONS=0 编译，全程句柄/契约校验）。
namespace fushi {

namespace {

using fushi_voice_hook::kSharedMagic;
using fushi_voice_hook::kSharedVersion;
using fushi_voice_hook::SharedHeader;
using fushi_voice_hook::SharedMemoryName;

struct ReaderState {
  std::mutex mutex;
  HANDLE mapping = nullptr;
  SharedHeader* header = nullptr;
  uint32_t pid = 0;
  // ── v14 查词通道游标（与上面同一把锁）───────────────────────────────────────
  // 三个游标都在 Open 时对齐到「现在」而不是 0：会话重开时把注入侧遗留的旧 hit
  // 当成新命中重放，用户会看到一张莫名其妙的卡片弹出来。
  uint64_t lookup_hit_count = 0;  // 上次见到的 header->lookup_hit_count
  uint64_t lookup_hit_seq = 0;    // 上次消费掉的 hit seq（计数变了但 seq 没前进=重复）
  uint64_t lookup_input_seq = 0;  // 上次消费到的输入环序号
  // 帧**发布序**：每投一帧（present 或 dismiss）+1。与 hit seq 分开是硬要求——两者
  // 合一时收卡帧会复用刚 present 过的 seq，被注入侧的"这帧我处理过了"过滤当场丢掉，
  // 卡片永远挂在屏幕上。见 voice_hook_ipc.h 的 LookupFrame 注释。
  uint64_t lookup_publish_seq = 0;
  // 用户的开关**意图**，与共享内存段的身份无关。
  //
  // 🔴 段会被换掉：退出一局再开一局 = 注入器建一段全新的共享内存，`lookup_enabled`
  // 从 0 开始。而 Dart 侧缓存着「我已经推过 true 了」，`desired == _pushedEnabled`
  // 当场早退，于是新段永远停在 0——传感器一个 hook 都不装，用户点字毫无反应，且
  // 表面上开关还是开着的。段的身份只有这一层知道（Open 是唯一的映射点），所以重放
  // 的责任也只能在这里，不能指望上层记得。
  bool lookup_enabled_desired = false;
};

ReaderState& State() {
  static ReaderState state;
  return state;
}

bool ProtocolMatches(const SharedHeader* h) {
  return h != nullptr && h->magic == kSharedMagic &&
         h->version == kSharedVersion &&
         h->ipc_protocol_version == fushi_voice_hook::kStableIpcVersion &&
         h->luna_bridge_abi_version ==
             fushi_voice_hook::kLunaBridgeAbiVersion &&
         h->luna_vendored_version == fushi_voice_hook::kLunaVendoredVersion;
}

// 无符号整数 → 十六进制字面（magic / vendored 版本按 hex 读才认得出来）。
std::string ToHex(uint32_t value) {
  static const char* kDigits = "0123456789abcdef";
  std::string out = "0x";
  bool leading = true;
  for (int shift = 28; shift >= 0; shift -= 4) {
    const uint32_t nibble = (value >> shift) & 0xF;
    if (nibble == 0 && leading && shift != 0) continue;
    leading = false;
    out.push_back(kDigits[nibble]);
  }
  return out;
}

// 契约不匹配时列出**不一致的字段**及双方取值（一致的不列，免得淹没结论）。
std::string ProtocolMismatchDetail(const SharedHeader* h) {
  if (h == nullptr) return "header=null";
  std::string out;
  auto add = [&out](const char* name, const std::string& got,
                    const std::string& want) {
    if (!out.empty()) out.push_back(' ');
    out += name;
    out += "=";
    out += got;
    out += "/want ";
    out += want;
  };
  if (h->magic != kSharedMagic) {
    add("magic", ToHex(h->magic), ToHex(kSharedMagic));
  }
  if (h->version != kSharedVersion) {
    add("shm", std::to_string(h->version), std::to_string(kSharedVersion));
  }
  if (h->ipc_protocol_version != fushi_voice_hook::kStableIpcVersion) {
    add("ipc", std::to_string(h->ipc_protocol_version),
        std::to_string(fushi_voice_hook::kStableIpcVersion));
  }
  if (h->luna_bridge_abi_version !=
      fushi_voice_hook::kLunaBridgeAbiVersion) {
    add("luna_abi", std::to_string(h->luna_bridge_abi_version),
        std::to_string(fushi_voice_hook::kLunaBridgeAbiVersion));
  }
  if (h->luna_vendored_version != fushi_voice_hook::kLunaVendoredVersion) {
    add("vendored", ToHex(h->luna_vendored_version),
        ToHex(fushi_voice_hook::kLunaVendoredVersion));
  }
  return out;
}

std::string WideToUtf8(const wchar_t* text, int length) {
  if (text == nullptr || length <= 0) return std::string();
  const int need = WideCharToMultiByte(CP_UTF8, 0, text, length, nullptr, 0,
                                        nullptr, nullptr);
  if (need <= 0) return std::string();
  std::string utf8(static_cast<size_t>(need), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, length, &utf8[0], need, nullptr,
                      nullptr);
  return utf8;
}

// 从 header 填状态（不读环形缓冲）。契约不匹配返回 ok=false。调用方持锁。
VoiceHookStatus StatusFromHeaderLocked(const SharedHeader* h) {
  VoiceHookStatus s;
  if (!ProtocolMatches(h)) {
    return s;  // 全零、ok=false
  }
  s.ipc_protocol_version = static_cast<int>(h->ipc_protocol_version);
  s.luna_bridge_abi_version = static_cast<int>(h->luna_bridge_abi_version);
  s.luna_vendored_version = static_cast<int>(h->luna_vendored_version);
  s.hooked = h->hooked != 0;
  s.calibrating = h->calibrating != 0;
  s.text_hooked = h->text_hooked != 0;
  s.sample_rate = static_cast<int>(h->sample_rate);
  s.channels = static_cast<int>(h->channels);
  s.bits_per_sample = static_cast<int>(h->bits_per_sample);
  s.is_float = h->is_float != 0;
  s.audio_hooks_ready =
      (h->hook_diagnostics &
       fushi_voice_hook::kDiagStartupAudioHooksReady) != 0;
  // 原始资源语音不要求共享环已有 PCM：KiriKiriZ/Siglus 直接导出逐句 Ogg；Unity
  // 由 injector 落逐句 WAV。统一契约确保资源优先，系统回环只作某句配对失败时的 fallback。
  s.raw_voice_ready = fushi_voice_hook::HasReadyGameResourceAudio(
      h->reserved_luna, h->hook_diagnostics,
      h->reserved_hook_diagnostics);
  s.text_lane_recycles = static_cast<int64_t>(h->text_lane_recycle_count);
  s.text_lane_overflows = static_cast<int64_t>(h->text_lane_overflow_count);
  // 格式就绪（hook 已填有效格式）才算 ok；hooked 但格式全 0（还没收到语音）时 ok=false。
  s.ok = s.hooked && s.sample_rate > 0 && s.channels > 0 && s.bits_per_sample > 0;
  return s;
}

// ── v14 查词通道：共享内存侧的判据与游标 ─────────────────────────────────────
//
// 三个方法（enable / present / dismiss）都要先过同一道闸，且**必须分得出**是哪一种
// 不可用：kNotOpen 要开会话，kNoRegion 要更新 helper（旧 injector 没有查词区），
// kNotEnabled 是 host 自己关着。把它们糊成一个 bool，下游就只能一律说"查词不可用"。
// 调用方持锁。
VoiceHookLookupError LookupGateLocked(const SharedHeader* h,
                                      bool require_enabled) {
  if (!ProtocolMatches(h)) {
    return VoiceHookLookupError::kNotOpen;
  }
  if (!fushi_voice_hook::HasLookupRegion(h)) {
    return VoiceHookLookupError::kNoRegion;
  }
  if (require_enabled && h->lookup_enabled == 0) {
    return VoiceHookLookupError::kNotEnabled;
  }
  return VoiceHookLookupError::kNone;
}

// 把三个游标对齐到当前计数（"从现在开始"）。调用方持锁。
void ResetLookupCursorsLocked(ReaderState& st, const SharedHeader* h) {
  st.lookup_hit_count = 0;
  st.lookup_hit_seq = 0;
  st.lookup_input_seq = 0;
  if (!fushi_voice_hook::HasLookupRegion(h)) {
    return;
  }
  st.lookup_hit_count =
      fushi_voice_hook::AtomicLoadPreview64(&h->lookup_hit_count);
  const fushi_voice_hook::LookupHitSlot* slot =
      fushi_voice_hook::LookupHitOf(h);
  if (slot != nullptr) {
    st.lookup_hit_seq = fushi_voice_hook::AtomicLoadPreview64(&slot->seq);
  }
  st.lookup_input_seq =
      fushi_voice_hook::AtomicLoadPreview64(&h->lookup_input_count);
}

// 解除映射、清句柄。调用方持锁。
void CloseLocked(ReaderState& st) {
  if (st.header != nullptr) {
    UnmapViewOfFile(st.header);
    st.header = nullptr;
  }
  if (st.mapping != nullptr) {
    CloseHandle(st.mapping);
    st.mapping = nullptr;
  }
  st.pid = 0;
  st.lookup_hit_count = 0;
  st.lookup_hit_seq = 0;
  st.lookup_input_seq = 0;
}

// 把一条 clip 的 PCM 从环形读出**追加**到 [out]（多段拼接用）；clip 已被环形覆盖返回 false。
// 调用方持锁。移植自 ring_probe.cpp 的 ReadClipPcm。
bool ReadClipPcmLocked(const SharedHeader* h, const uint8_t* ring,
                       const fushi_voice_hook::VoiceClip* c,
                       std::vector<uint8_t>& out) {
  const uint32_t cap = h->ring_capacity;
  const uint32_t len = c->byte_len;
  if (len == 0 || len > cap) {
    return false;
  }
  if (h->total_written > c->total_at_write &&
      h->total_written - c->total_at_write > cap - len) {
    return false;  // 已被环形覆盖
  }
  const uint32_t off = c->ring_offset % cap;
  const size_t base = out.size();
  out.resize(base + len);
  const uint32_t first = (len <= cap - off) ? len : (cap - off);
  memcpy(out.data() + base, ring + off, first);
  if (len > first) {
    memcpy(out.data() + base + first, ring, len - first);
  }
  return true;
}

// 一条 clip 的 16-bit PCM 平均绝对幅值（能量代理）。非 16-bit 返回 -1（调用方退化）。已被环形
// 覆盖返回 0。调用方持锁。移植自 ring_probe.cpp 的 ClipEnergy16。
double ClipEnergy16Locked(const SharedHeader* h, const uint8_t* ring,
                          const fushi_voice_hook::VoiceClip* c) {
  if (c->bits_per_sample != 16 || c->is_float) {
    return -1.0;
  }
  std::vector<uint8_t> buf;
  if (!ReadClipPcmLocked(h, ring, c, buf) || buf.size() < 2) {
    return 0.0;
  }
  const int16_t* s = reinterpret_cast<const int16_t*>(buf.data());
  const size_t n = buf.size() / 2;
  double acc = 0;
  for (size_t i = 0; i < n; i++) {
    acc += (s[i] < 0) ? -static_cast<double>(s[i]) : static_cast<double>(s[i]);
  }
  return acc / static_cast<double>(n);
}

// 收集环形里有效（seq 匹配、byte_len 合法）的语音 clip 指针（seq 升序）。调用方持锁。
std::vector<const fushi_voice_hook::VoiceClip*> CollectValidClipsLocked(
    const SharedHeader* h) {
  std::vector<const fushi_voice_hook::VoiceClip*> valid;
  const uint32_t cap = h->ring_capacity;
  const uint64_t clips = h->clip_write_count;
  if (cap == 0 || clips == 0) {
    return valid;
  }
  const uint32_t clip_slots = fushi_voice_hook::kClipCount;
  const uint8_t* clip_base =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t scan_from = (clips > clip_slots) ? clips - clip_slots : 0;
  for (uint64_t seq = scan_from + 1; seq <= clips; seq++) {
    const uint32_t idx = static_cast<uint32_t>((seq - 1) % clip_slots);
    const auto* c = reinterpret_cast<const fushi_voice_hook::VoiceClip*>(
        clip_base + static_cast<size_t>(idx) *
                        sizeof(fushi_voice_hook::VoiceClip));
    if (c->seq == seq && c->byte_len != 0 && c->byte_len <= cap) {
      valid.push_back(c);
    }
  }
  return valid;
}

// ══ v14 查词通道：轮询泵 + MethodChannel ═══════════════════════════════════════
//
// 泵是「平台线程上的 WM_TIMER」而不是后台线程，理由是两侧的线程亲和性都硬：
//   * MethodChannel::InvokeMethod 只能在平台线程调；
//   * WebView2 的 SendMouseInput / CapturePreview 是 STA，也只能在平台线程调。
// 用后台线程就必须再造一层跨线程投递，而每 16ms 读几百字节共享内存本来就不阻塞
// 消息循环——多一层只会多一个可以出错的地方。
constexpr wchar_t kLookupPumpClassName[] = L"FushiGalLookupPump";
// 事件出口复用 galgame 浮窗那条既有通道：Dart 侧 GalHookTextOverlayChannel 就在这条
// 通道上分发 onGalLookupHit / onGalLookupInput。另开一条同名通道注册 handler 会顶掉
// flutter_window 的处理器，所以这里的通道对象**只用来 InvokeMethod**。
constexpr char kGalHookTextChannel[] = "app.fushi.reader/gal_hook_text";
constexpr UINT_PTR kLookupPumpTimerId = 1;
constexpr UINT kLookupPumpIntervalMs = 16;  // ~60Hz：查词要跟手，卡片重绘也吃这个节拍

// 帧尺寸的**维度**上界，与 IsLookupFrameSane 同值。字节上界不在这里管：卡片多高才
// 放得进 3MiB 取决于它多宽，只有拿到真实宽度之后才算得出来，故字节预算统一在
// WriteLookupFrame 里按行裁（见那里）。
constexpr uint32_t kLookupMaxDimension = 0x4000u;

using LookupChannel = flutter::MethodChannel<flutter::EncodableValue>;
using LookupResult = flutter::MethodResult<flutter::EncodableValue>;

// 泵状态：**只在平台线程上访问**（Attach/Detach/Set*/WndProc 全在平台线程），
// 故不需要锁。共享内存那部分的并发由 ReaderState::mutex 管，两者不重叠。
struct LookupPumpState {
  std::unique_ptr<LookupChannel> channel;
  VoiceHookReader::LookupCaptureRequest capture;
  VoiceHookReader::LookupInputSink input_sink;
  HWND hwnd = nullptr;
  bool timer_running = false;
};

LookupPumpState& Pump() {
  static LookupPumpState pump;
  return pump;
}

void StopLookupPump() {
  LookupPumpState& pump = Pump();
  if (pump.hwnd != nullptr && pump.timer_running) {
    KillTimer(pump.hwnd, kLookupPumpTimerId);
  }
  pump.timer_running = false;
}

flutter::EncodableValue LookupErrorMap(VoiceHookLookupError error) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("error"),
       flutter::EncodableValue(std::string(
           fushi::VoiceHookLookupErrorToken(error)))}});
}

flutter::EncodableValue LookupHitMap(const VoiceHookLookupHit& hit) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("seq"),
       flutter::EncodableValue(static_cast<int64_t>(hit.seq))},
      {flutter::EncodableValue("line"), flutter::EncodableValue(hit.line_utf8)},
      {flutter::EncodableValue("charIndex"),
       flutter::EncodableValue(static_cast<int64_t>(hit.char_index))},
      {flutter::EncodableValue("charCount"),
       flutter::EncodableValue(static_cast<int64_t>(hit.char_count))},
      {flutter::EncodableValue("glyphX"), flutter::EncodableValue(hit.glyph_x)},
      {flutter::EncodableValue("glyphY"), flutter::EncodableValue(hit.glyph_y)},
      {flutter::EncodableValue("glyphW"), flutter::EncodableValue(hit.glyph_w)},
      {flutter::EncodableValue("glyphH"), flutter::EncodableValue(hit.glyph_h)},
      {flutter::EncodableValue("viewW"), flutter::EncodableValue(hit.view_w)},
      {flutter::EncodableValue("viewH"), flutter::EncodableValue(hit.view_h)},
      {flutter::EncodableValue("submit"), flutter::EncodableValue(hit.submit)},
  });
}

flutter::EncodableValue LookupInputMap(const VoiceHookLookupInput& input) {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("seq"),
       flutter::EncodableValue(static_cast<int64_t>(input.seq))},
      {flutter::EncodableValue("x"), flutter::EncodableValue(input.x)},
      {flutter::EncodableValue("y"), flutter::EncodableValue(input.y)},
      {flutter::EncodableValue("kind"),
       flutter::EncodableValue(static_cast<int64_t>(input.kind))},
      {flutter::EncodableValue("wheel"), flutter::EncodableValue(input.wheel)},
      {flutter::EncodableValue("keys"),
       flutter::EncodableValue(static_cast<int64_t>(input.keys))},
  });
}

// 一次泵动：一条 hit（latest-wins，多的没意义）+ 环里全部新输入。
void PumpLookupOnce() {
  LookupPumpState& pump = Pump();
  VoiceHookReader& reader = VoiceHookReader::Instance();
  // 会话没了（关游戏 / Close）就把定时器停掉，别在没有映射的情况下空转。Dart 侧
  // 重开会话后本来就要再调一次 galLookupSetEnabled，泵会跟着重新起来。
  if (!reader.HasLookupChannel()) {
    StopLookupPump();
    return;
  }
  VoiceHookLookupHit hit;
  if (reader.PollLookupHit(&hit) && pump.channel != nullptr) {
    pump.channel->InvokeMethod(
        "onGalLookupHit",
        std::make_unique<flutter::EncodableValue>(LookupHitMap(hit)));
  }
  std::vector<VoiceHookLookupInput> inputs;
  reader.PollLookupInputs(inputs);
  for (const VoiceHookLookupInput& input : inputs) {
    // 只上报，**不**在这里直接喂 WebView2。注入由 Dart 经 galLookupInput 回调下来
    // （它才知道卡片这一刻显示没显示、该不该吃这个事件）。两处都喂 = 每个事件注入
    // 两次：点击变双击、滚轮翻倍。
    if (pump.channel != nullptr) {
      pump.channel->InvokeMethod(
          "onGalLookupInput",
          std::make_unique<flutter::EncodableValue>(LookupInputMap(input)));
    }
  }
}

LRESULT CALLBACK LookupPumpProc(HWND hwnd, UINT message, WPARAM wparam,
                                LPARAM lparam) {
  if (message == WM_TIMER && wparam == kLookupPumpTimerId) {
    PumpLookupOnce();
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

// HWND_MESSAGE 消息窗：在平台线程上建，它的 WndProc 因此跑在平台线程的消息循环里。
// 这就是"轮询结果能直接调 InvokeMethod / SendMouseInput"的全部依据。
void EnsureLookupPumpWindow() {
  LookupPumpState& pump = Pump();
  if (pump.hwnd != nullptr && IsWindow(pump.hwnd)) {
    return;
  }
  pump.hwnd = nullptr;
  pump.timer_running = false;
  static bool registered = false;
  if (!registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = LookupPumpProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kLookupPumpClassName;
    registered = RegisterClassExW(&wc) != 0 ||
                 GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
  }
  if (!registered) {
    return;
  }
  pump.hwnd = CreateWindowExW(0, kLookupPumpClassName, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr,
                              GetModuleHandleW(nullptr), nullptr);
}

void StartLookupPump() {
  LookupPumpState& pump = Pump();
  EnsureLookupPumpWindow();
  if (pump.hwnd == nullptr || pump.timer_running) {
    return;
  }
  pump.timer_running =
      SetTimer(pump.hwnd, kLookupPumpTimerId, kLookupPumpIntervalMs,
               nullptr) != 0;
}

int64_t ReadLookupInt(const flutter::MethodCall<flutter::EncodableValue>& call,
                      const char* key) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    return 0;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return 0;
  }
  return it->second.TryGetLongValue().value_or(0);
}

bool ReadLookupBool(const flutter::MethodCall<flutter::EncodableValue>& call,
                    const char* key) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return false;
  }
  const bool* value = std::get_if<bool>(&it->second);
  return value != nullptr && *value;
}

void HandleLookupPresent(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<LookupResult> result) {
  LookupPumpState& pump = Pump();
  VoiceHookReader& reader = VoiceHookReader::Instance();
  VoiceHookLookupPresent meta;
  meta.seq = static_cast<uint64_t>(ReadLookupInt(call, "seq"));
  meta.anchor_x = static_cast<int32_t>(ReadLookupInt(call, "anchorX"));
  meta.anchor_y = static_cast<int32_t>(ReadLookupInt(call, "anchorY"));
  meta.highlight_start =
      static_cast<uint32_t>(ReadLookupInt(call, "highlightStart"));
  meta.highlight_len =
      static_cast<uint32_t>(ReadLookupInt(call, "highlightLen"));
  // 先探一次闸再取帧：取帧要走一整轮 PNG 编解码，为一个根本投不出去的会话做这件事
  // 纯属浪费，而且会把真正的原因（旧 helper / 开关关着）掩盖成"取帧失败"。
  const VoiceHookLookupError gate = reader.PeekLookupGate(true);
  if (gate != VoiceHookLookupError::kNone) {
    result->Success(LookupErrorMap(gate));
    return;
  }
  if (!pump.capture) {
    result->Success(
        LookupErrorMap(VoiceHookLookupError::kNoCaptureSource));
    return;
  }
  // MethodResult 不可拷贝，而 continuation 要经 std::function 传递（要求可拷贝），
  // 故转成 shared_ptr。语义不变：仍然只应答一次。
  std::shared_ptr<LookupResult> reply(std::move(result));
  pump.capture(
      kLookupMaxDimension, kLookupMaxDimension,
      [reply, meta](bool ok, bool clamped, const std::vector<uint8_t>& bgra,
                    uint32_t width, uint32_t height, uint32_t pitch) {
        if (!ok || bgra.empty()) {
          reply->Success(
              LookupErrorMap(VoiceHookLookupError::kCaptureFailed));
          return;
        }
        VoiceHookLookupWriteResult wrote =
            VoiceHookReader::Instance().WriteLookupFrame(
                meta, bgra.data(), width, height, pitch);
        if (!wrote.ok()) {
          reply->Success(LookupErrorMap(wrote.error));
          return;
        }
        reply->Success(flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("ok"), flutter::EncodableValue(true)},
            {flutter::EncodableValue("width"),
             flutter::EncodableValue(static_cast<int64_t>(wrote.width))},
            {flutter::EncodableValue("height"),
             flutter::EncodableValue(static_cast<int64_t>(wrote.height))},
            {flutter::EncodableValue("pitch"),
             flutter::EncodableValue(static_cast<int64_t>(wrote.pitch))},
            // 取帧裁剪（源画面比维度上界大）与投帧裁剪（字节超预算按行裁）都算
            // "卡片被切过"，合并成一个事实交给上层——上层要做的处置是同一个：
            // 把卡片做小点重投。
            {flutter::EncodableValue("clamped"),
             flutter::EncodableValue(clamped || wrote.clamped)},
        }));
      });
}

// 返回 true = 已消费（result 已应答）。**不认识的方法必须原样返回 false**，
// 让 flutter_window 既有的 gal_hook_text 分发链继续走：这个函数是挂在别人的
// 处理器前面的，吞掉 show/hide/updateText 就等于把 galgame 浮窗整个弄坏。
bool HandleLookupCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                      std::unique_ptr<LookupResult>& out_result) {
  const std::string& method = call.method_name();
  if (method != "galLookupSetEnabled" && method != "galLookupPresent" &&
      method != "galLookupDismiss" && method != "galLookupInput") {
    return false;
  }
  std::unique_ptr<LookupResult> result = std::move(out_result);
  LookupPumpState& pump = Pump();
  VoiceHookReader& reader = VoiceHookReader::Instance();
  if (method == "galLookupInput") {
    // Dart 决定了要喂，这里只做落地。没接 sink（像素源实例还没接线）时不静默成功。
    if (!pump.input_sink) {
      result->Success(
          LookupErrorMap(VoiceHookLookupError::kNoCaptureSource));
      return true;
    }
    pump.input_sink(static_cast<uint32_t>(ReadLookupInt(call, "kind")),
                    static_cast<int32_t>(ReadLookupInt(call, "x")),
                    static_cast<int32_t>(ReadLookupInt(call, "y")),
                    static_cast<int32_t>(ReadLookupInt(call, "wheel")),
                    static_cast<uint32_t>(ReadLookupInt(call, "keys")));
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("ok"), flutter::EncodableValue(true)}}));
    return true;
  }
  if (method == "galLookupSetEnabled") {
    const VoiceHookLookupError error =
        reader.SetLookupEnabled(ReadLookupBool(call, "enabled"));
    if (error != VoiceHookLookupError::kNone) {
      result->Success(LookupErrorMap(error));
      return true;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("ok"), flutter::EncodableValue(true)}}));
    return true;
  }
  if (method == "galLookupPresentHighlight") {
    // 悬停只挪高亮：不抓帧、不拷像素。
    VoiceHookLookupPresent meta;
    meta.seq = static_cast<uint64_t>(ReadLookupInt(call, "seq"));
    meta.anchor_x = static_cast<int32_t>(ReadLookupInt(call, "anchorX"));
    meta.anchor_y = static_cast<int32_t>(ReadLookupInt(call, "anchorY"));
    meta.highlight_start =
        static_cast<uint32_t>(ReadLookupInt(call, "highlightStart"));
    meta.highlight_len =
        static_cast<uint32_t>(ReadLookupInt(call, "highlightLen"));
    const VoiceHookLookupError error =
        VoiceHookReader::Instance().WriteLookupHighlight(meta);
    if (error != VoiceHookLookupError::kNone) {
      result->Success(LookupErrorMap(error));
      return true;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("ok"), flutter::EncodableValue(true)}}));
    return true;
  }

  if (method == "galLookupPresent") {
    HandleLookupPresent(call, std::move(result));
    return true;
  }
  // 剩下的只可能是 galLookupDismiss（上面的白名单已经挡住其它一切）。
  const VoiceHookLookupError error = reader.WriteLookupDismiss(
      static_cast<uint64_t>(ReadLookupInt(call, "seq")));
  if (error != VoiceHookLookupError::kNone) {
    result->Success(LookupErrorMap(error));
    return true;
  }
  result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("ok"), flutter::EncodableValue(true)}}));
  return true;
}

}  // namespace

VoiceHookReader& VoiceHookReader::Instance() {
  static VoiceHookReader instance;
  return instance;
}

VoiceHookReader::~VoiceHookReader() {
  Close();
}

const char* VoiceHookOpenErrorToken(VoiceHookOpenError error) {
  switch (error) {
    case VoiceHookOpenError::kNone:
      return "none";
    case VoiceHookOpenError::kInvalidPid:
      return "invalid_pid";
    case VoiceHookOpenError::kMappingNotFound:
      return "mapping_not_found";
    case VoiceHookOpenError::kAccessDenied:
      return "access_denied";
    case VoiceHookOpenError::kMappingOpenFailed:
      return "mapping_open_failed";
    case VoiceHookOpenError::kMapViewFailed:
      return "map_view_failed";
    case VoiceHookOpenError::kProtocolMismatch:
      return "protocol_mismatch";
  }
  return "unknown";
}

VoiceHookOpenResult VoiceHookReader::Open(uint32_t pid) {
  VoiceHookOpenResult out;
  // 新段上是否要把查词开关重放回去（连带把泵拉起来）。SetTimer 要进内核，按本文件
  // 既有纪律不在持锁时做，所以在锁外收尾。
  bool reapply_lookup_enabled = false;
  {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  if (pid == 0) {
    out.error = VoiceHookOpenError::kInvalidPid;
    out.detail = "pid=0";
    return out;
  }
  // 幂等：已打开同 pid 直接回报当前状态。
  if (st.header != nullptr && st.pid == pid) {
    out.status = StatusFromHeaderLocked(st.header);
    return out;
  }
  // 打开了别的 pid：先释放。
  if (st.header != nullptr) {
    CloseLocked(st);
  }
  const std::wstring name = SharedMemoryName(static_cast<DWORD>(pid));
  const std::string name_utf8 =
      "name=" + WideToUtf8(name.c_str(), static_cast<int>(name.size()));
  HANDLE mapping =
      OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, name.c_str());
  if (mapping == nullptr) {
    // 这里必须分两种：ERROR_FILE_NOT_FOUND = helper 没建会话（重开游戏）；
    // ERROR_ACCESS_DENIED = 目标进程完整性级别更高，映射的 ACL 挡住了中完整性的
    // fushi.exe（多为游戏以管理员身份运行，须以管理员运行 Fushi）。两者都被旧实现
    // 说成同一句「重启 Fushi」，而重启对二者**都没用**。
    const DWORD code = GetLastError();
    out.win32_error = static_cast<uint32_t>(code);
    out.error = (code == ERROR_FILE_NOT_FOUND)
                    ? VoiceHookOpenError::kMappingNotFound
                    : (code == ERROR_ACCESS_DENIED
                           ? VoiceHookOpenError::kAccessDenied
                           : VoiceHookOpenError::kMappingOpenFailed);
    out.detail = name_utf8 + " win32=" + std::to_string(code);
    return out;
  }
  auto* header = static_cast<SharedHeader*>(
      MapViewOfFile(mapping, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0));
  if (header == nullptr) {
    const DWORD code = GetLastError();
    CloseHandle(mapping);
    out.error = VoiceHookOpenError::kMapViewFailed;
    out.win32_error = static_cast<uint32_t>(code);
    out.detail = name_utf8 + " win32=" + std::to_string(code);
    return out;
  }
  // 只信任契约匹配的映射（防旧/坏映射读坏内存）。不匹配时把**双方版本**带出去：
  // 用户装的 helper 与本体版本漂开时，这是唯一能一次确诊的事实。
  if (!ProtocolMatches(header)) {
    out.detail = ProtocolMismatchDetail(header);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    out.error = VoiceHookOpenError::kProtocolMismatch;
    return out;
  }
  st.mapping = mapping;
  st.header = header;
  st.pid = pid;
  // v14：查词游标对齐到「现在」。不这么做，会话重开时注入侧遗留的旧 hit 会被当成
  // 新命中重放，用户会看到一张莫名其妙的卡片弹出来。
  ResetLookupCursorsLocked(st, header);
  // 段换了就把开关意图重放进新段（见 ReaderState::lookup_enabled_desired）。
  // 走与 SetLookupEnabled 同一道闸：新段没有查词区时什么都不做，绝不盲写。
  if (st.lookup_enabled_desired &&
      LookupGateLocked(header, false) == VoiceHookLookupError::kNone) {
    InterlockedExchange(
        reinterpret_cast<volatile LONG*>(&header->lookup_enabled), 1);
    reapply_lookup_enabled = true;
  }
  out.status = StatusFromHeaderLocked(header);
  }
  if (reapply_lookup_enabled) {
    StartLookupPump();
  }
  return out;
}

VoiceHookStatus VoiceHookReader::Status() {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  return StatusFromHeaderLocked(st.header);
}

VoiceHookStatus VoiceHookReader::GrabRecent(int back_ms,
                                            std::vector<uint8_t>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  const VoiceHookStatus status = StatusFromHeaderLocked(h);
  if (!status.ok || back_ms <= 0) {
    return VoiceHookStatus{};
  }
  const uint32_t block_align = h->block_align;
  const uint32_t capacity = h->ring_capacity;
  if (block_align == 0 || capacity == 0) {
    return VoiceHookStatus{};
  }
  // 快照 volatile 计数（单写单读：读到的量至多滞后一个包）。
  const uint32_t write_pos = h->write_pos;
  const uint64_t total_written = h->total_written;
  if (total_written == 0 || write_pos > capacity) {
    return VoiceHookStatus{};
  }
  const size_t filled = static_cast<size_t>(
      (std::min)(total_written, static_cast<uint64_t>(capacity)));
  const int byte_rate = status.sample_rate * static_cast<int>(block_align);
  if (byte_rate <= 0 || filled == 0) {
    return VoiceHookStatus{};
  }
  size_t want = static_cast<size_t>(byte_rate) *
                static_cast<size_t>(back_ms) / 1000;
  want = (std::min)(want, filled);
  want -= (want % block_align);
  if (want == 0) {
    return VoiceHookStatus{};
  }
  // 环形缓冲紧跟 header 之后。最近 want 字节起点 = write_pos 往回 want（回绕）。
  const uint8_t* ring =
      reinterpret_cast<const uint8_t*>(h) + sizeof(SharedHeader);
  const size_t start =
      (static_cast<size_t>(write_pos) + capacity - want) % capacity;
  out.resize(want);
  const size_t first = (std::min)(want, static_cast<size_t>(capacity) - start);
  memcpy(out.data(), ring + start, first);
  if (want > first) {
    memcpy(out.data() + first, ring, want - first);
  }
  return status;
}

uint64_t VoiceHookReader::TextWriteCount() {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  if (!ProtocolMatches(h)) {
    return 0;
  }
  return h->text_write_count;
}

void VoiceHookReader::PollText(uint64_t from_seq,
                               std::vector<VoiceHookText>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  if (!ProtocolMatches(h)) {
    return;
  }
  const uint64_t count = h->text_write_count;
  if (count <= from_seq) {
    return;
  }
  // v13：文本按线程分道，全局序号不再能取模定位槽。改成**遍历各道**、取本道内仍在的、
  // 全局序大于游标的行，最后按全局序排序——Dart 侧拿到的仍是一串按 seq 升序的新行，
  // `pollText(fromSeq)` 契约逐字节不变。
  //
  // 一条道只覆盖自己的旧行，所以「某条逐字重绘线程刷得飞快」只会吃掉它自己的历史，
  // 别的线程（尤其是配对候选那条）一行都不少——这正是分道要买的东西。
  const uint32_t slot_bytes = fushi_voice_hook::kTextSlotBytes;
  // 归并实现只有契约头里那一份（诊断探针 ring_probe 用的是同一个函数）。
  static const fushi_voice_hook::TextSlot*
      slots[fushi_voice_hook::kTextSlotCount];
  const uint32_t found = fushi_voice_hook::CollectTextSlotsBySeq(
      h, slots, fushi_voice_hook::kTextSlotCount, from_seq);
  for (uint32_t idx = 0; idx < found; idx++) {
    {
      const fushi_voice_hook::TextSlot* slot = slots[idx];
      const uint64_t seq = slot->seq;
      if (seq > count) {
        continue;  // 半写槽读到越界序号
      }
      uint32_t blen = slot->byte_len;
    const uint32_t maxb =
        slot_bytes - static_cast<uint32_t>(sizeof(fushi_voice_hook::TextSlot));
    if (blen > maxb) {
      blen = maxb;
    }
    const uint8_t* txt =
        reinterpret_cast<const uint8_t*>(slot) + sizeof(fushi_voice_hook::TextSlot);
    VoiceHookText line;
    line.seq = seq;
    line.timestamp_ms = slot->timestamp_ms;
    line.thread_id = slot->thread_id;
    line.face_id = slot->face_id;
    line.thread_address = slot->thread_address;
    line.thread_context = slot->thread_context;
    line.thread_context2 = slot->thread_context2;
    line.process_id = slot->process_id;
    line.source_kind = slot->source_kind;
    line.event_kind = slot->event_kind;
    line.event_flags = slot->event_flags;
    const uint32_t hook_name_len = (std::min)(
        slot->hook_name_len, fushi_voice_hook::kTextHookNameChars);
    line.hook_name.assign(slot->hook_name, hook_name_len);
    const uint32_t hook_code_len = (std::min)(
        slot->hook_code_len, fushi_voice_hook::kTextHookCodeChars);
    line.hook_code = WideToUtf8(slot->hook_code,
                                static_cast<int>(hook_code_len));
    if (slot->is_utf8) {
      line.utf8.assign(reinterpret_cast<const char*>(txt), blen);
    } else {
      const int wlen = static_cast<int>(blen / 2);
      line.utf8 = WideToUtf8(reinterpret_cast<const wchar_t*>(txt), wlen);
    }
    out.push_back(std::move(line));
    }
  }
}

uint64_t VoiceHookReader::PollThreadPreviews(
    std::vector<VoiceHookThreadPreview>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  if (!ProtocolMatches(h) || h->thread_preview_offset == 0) {
    return 0;
  }
  const uint32_t slots = (std::min)(h->thread_preview_slot_count,
                                    fushi_voice_hook::kThreadPreviewCount);
  const auto* base = reinterpret_cast<const fushi_voice_hook::ThreadPreviewSlot*>(
      reinterpret_cast<const uint8_t*>(h) + h->thread_preview_offset);
  for (uint32_t i = 0; i < slots; i++) {
    const auto& slot = base[i];
    fushi_voice_hook::ThreadPreviewSnapshot snapshot;
    // writer 用 odd/even seqlock 发布；这里最多重试四次，只接受前后 seq 相同的偶数快照。
    // 所有 64 位 seq 读都走 Interlocked，x86 不会因裸 uint64_t 访问而撕裂。
    if (!fushi_voice_hook::TryReadThreadPreviewSnapshot(slot, &snapshot) ||
        snapshot.thread_id == 0) {
      continue;
    }
    VoiceHookThreadPreview preview;
    preview.thread_id = snapshot.thread_id;
    preview.seq = snapshot.seq;
    preview.timestamp_ms = snapshot.timestamp_ms;
    preview.line_count = snapshot.line_count;
    preview.artifact_count = snapshot.artifact_count;
    preview.event_flags = snapshot.event_flags;
    uint32_t blen = snapshot.byte_len;
    const uint32_t maxb =
        fushi_voice_hook::kThreadPreviewTextChars * sizeof(wchar_t);
    if (blen > maxb) {
      blen = maxb;
    }
    preview.utf8 =
        WideToUtf8(snapshot.text, static_cast<int>(blen / 2));
    out.push_back(std::move(preview));
  }
  return fushi_voice_hook::AtomicLoadPreview64(
      &h->thread_preview_write_count);
}

bool VoiceHookReader::SelectTextThread(uint64_t thread_id) {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  SharedHeader* h = st.header;
  if (!ProtocolMatches(h)) {
    return false;
  }
  InterlockedExchange64(
      reinterpret_cast<volatile LONGLONG*>(&h->selected_text_thread_id),
      static_cast<LONGLONG>(thread_id));
  return true;
}

VoiceHookStatus VoiceHookReader::GrabClipNear(
    uint64_t ts_ms, uint64_t tolerance_ms, uint64_t target_source,
    const std::vector<uint64_t>& exclude_sources, std::vector<uint8_t>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  const VoiceHookStatus status = StatusFromHeaderLocked(h);
  if (!status.ok) {
    return VoiceHookStatus{};
  }
  const uint32_t cap = h->ring_capacity;
  const uint64_t clips = h->clip_write_count;
  if (cap == 0 || clips == 0) {
    return VoiceHookStatus{};
  }
  const uint32_t clip_slots = fushi_voice_hook::kClipCount;
  const uint8_t* clip_base =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t total = h->total_written;
  const uint64_t scan_from = (clips > clip_slots) ? clips - clip_slots : 0;
  const fushi_voice_hook::VoiceClip* best = nullptr;
  uint64_t best_diff = tolerance_ms + 1;
  for (uint64_t seq = scan_from + 1; seq <= clips; seq++) {
    const uint32_t idx = static_cast<uint32_t>((seq - 1) % clip_slots);
    const auto* c = reinterpret_cast<const fushi_voice_hook::VoiceClip*>(
        clip_base + static_cast<size_t>(idx) * sizeof(fushi_voice_hook::VoiceClip));
    if (c->seq != seq || c->byte_len == 0 || c->byte_len > cap) {
      continue;
    }
    // 选轨/排除契约与 GrabUtterance 一致：指定轨只取该轨，排除轨一律跳过。
    if (target_source != 0 && c->source_ptr != target_source) {
      continue;
    }
    bool excluded = false;
    for (const uint64_t ex : exclude_sources) {
      if (ex == c->source_ptr) {
        excluded = true;
        break;
      }
    }
    if (excluded) {
      continue;
    }
    // 已被环形覆盖（写该 clip 之后又写了几乎一整圈）则跳过。
    if (total > c->total_at_write && total - c->total_at_write > cap - c->byte_len) {
      continue;
    }
    const uint64_t diff = (c->timestamp_ms > ts_ms) ? (c->timestamp_ms - ts_ms)
                                                    : (ts_ms - c->timestamp_ms);
    if (diff < best_diff) {
      best_diff = diff;
      best = c;
    }
  }
  if (best == nullptr) {
    return VoiceHookStatus{};
  }
  const uint8_t* ring = reinterpret_cast<const uint8_t*>(h) + sizeof(SharedHeader);
  const uint32_t off = best->ring_offset % cap;
  const uint32_t len = best->byte_len;
  out.resize(len);
  const uint32_t first = (len <= cap - off) ? len : (cap - off);
  memcpy(out.data(), ring + off, first);
  if (len > first) {
    memcpy(out.data() + first, ring, len - first);
  }
  VoiceHookStatus s = status;
  s.sample_rate = static_cast<int>(best->sample_rate);
  s.channels = static_cast<int>(best->channels);
  s.bits_per_sample = static_cast<int>(best->bits_per_sample);
  s.is_float = best->is_float != 0;
  return s;
}

VoiceHookStatus VoiceHookReader::GrabUtterance(
    uint64_t ts_ms, uint64_t target_source,
    const std::vector<uint64_t>& exclude_sources, std::vector<uint8_t>& out,
    uint64_t end_ts_ms) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  const VoiceHookStatus status = StatusFromHeaderLocked(h);
  if (!status.ok) {
    return VoiceHookStatus{};
  }
  const std::vector<const fushi_voice_hook::VoiceClip*> valid =
      CollectValidClipsLocked(h);
  if (valid.empty()) {
    return VoiceHookStatus{};
  }
  const uint8_t* ring =
      reinterpret_cast<const uint8_t*>(h) + sizeof(SharedHeader);

  // 选语音源：target_source 非 0 直接用（手动选轨）；否则按能量自动选（排除 exclude_sources）。
  bool filter_by_src = false;
  uint64_t sel_src = 0;
  if (target_source != 0) {
    filter_by_src = true;
    sel_src = target_source;
  } else {
    // 每源：说话前窗口 [ts-900,ts-250] 与文本时刻窗口 [ts-150,ts+450] 的平均能量。
    std::map<uint64_t, double> e_before, e_at;
    std::map<uint64_t, int> n_before, n_at;
    bool any_energy = false;
    for (const auto* c : valid) {
      bool excluded = false;
      for (const uint64_t ex : exclude_sources) {
        if (ex == c->source_ptr) {
          excluded = true;
          break;
        }
      }
      if (excluded) {
        continue;  // 用户标记的 BGM 源不参与自动选源
      }
      const double e = ClipEnergy16Locked(h, ring, c);
      if (e < 0) {
        continue;  // 非 16-bit
      }
      any_energy = true;
      const int64_t d = static_cast<int64_t>(c->timestamp_ms) -
                        static_cast<int64_t>(ts_ms);
      if (d >= -900 && d <= -250) {
        e_before[c->source_ptr] += e;
        n_before[c->source_ptr]++;
      }
      if (d >= -150 && d <= 450) {
        e_at[c->source_ptr] += e;
        n_at[c->source_ptr]++;
      }
    }
    // 语音源 = (文本时刻平均能量 - 说话前平均能量) 最大者：从静音跳到有声。
    double best_delta = -1e18;
    for (const auto& kv : e_at) {
      if (kv.second <= 0 || n_at[kv.first] == 0) {
        continue;
      }
      const double at_avg = kv.second / n_at[kv.first];
      const double bef_avg =
          (n_before.count(kv.first) && n_before[kv.first] > 0)
              ? e_before[kv.first] / n_before[kv.first]
              : 0.0;
      const double delta = at_avg - bef_avg;
      if (delta > best_delta) {
        best_delta = delta;
        sel_src = kv.first;
      }
    }
    if (any_energy) {
      if (sel_src == 0) {
        return VoiceHookStatus{};  // 有能量数据却选不出源（全被排除）——交调用方回退
      }
      filter_by_src = true;
    }
    // any_energy=false（非 16-bit）：无法能量选源，退化为拼所有源（filter_by_src 保持 false）。
  }

  // 拼接选定源在 [下界, ts+forward_ms] 的段；静音判据用该源峰值能量的 8%。
  //
  // BUG-1475：forward_ms 缺省仍是 6000（旧行为逐字等价）。调用方给出 end_ts_ms
  // （下一句的时间戳）时收窄到那里——封口 grab 要拿回已进环、时间戳**严格早于**
  // 下一句的那点尾巴，同时保住 BUG-1109「不把下一句的段拼进上一句」的不变量。
  //
  // BUG-1593：下界**不再**是写死的 ts-200。clip 的时间戳是**提交**时刻不是播放时刻，
  // 流式引擎按缓冲深度提前提交（KiriKiri 每句新建 DirectSound buffer 并一次性灌满整个
  // 缓冲，实测比文本 hook 早 219ms 灌进 1500ms 音频），固定 200ms 回看会把整句的开头
  // 整块丢掉。判据见 voice_hook_utterance_window.h：只对「明显快于实时写入」的段回退，
  // 实时写入的混音 / BGM 源逐字节维持旧行为。
  int64_t forward_ms = 6000;
  if (end_ts_ms != 0 && end_ts_ms > ts_ms) {
    forward_ms = std::min<int64_t>(
        forward_ms, static_cast<int64_t>(end_ts_ms - ts_ms));
  } else if (end_ts_ms != 0) {
    // 下一句时间戳不晚于本句：拿不到任何合法的前向窗口，退化为只取本句时刻附近。
    forward_ms = 0;
  }
  // 选定源的段（按提交顺序）喂给下界推算：valid 本身就是 seq 升序。
  std::vector<fushi_voice_hook::UtteranceClipTiming> timings;
  timings.reserve(valid.size());
  for (const auto* c : valid) {
    if (filter_by_src && c->source_ptr != sel_src) {
      continue;
    }
    const uint32_t block = c->channels * (c->bits_per_sample / 8);
    const int64_t dur =
        (block == 0 || c->sample_rate == 0)
            ? 0
            : static_cast<int64_t>(static_cast<int64_t>(c->byte_len) * 1000 /
                                   (static_cast<int64_t>(block) *
                                    static_cast<int64_t>(c->sample_rate)));
    timings.push_back(fushi_voice_hook::UtteranceClipTiming{
        static_cast<int64_t>(c->timestamp_ms), dur});
  }
  const int64_t lower_ts = fushi_voice_hook::UtteranceLowerBoundMs(
      timings.data(), timings.size(), static_cast<int64_t>(ts_ms));

  std::vector<uint8_t> pcm;
  const fushi_voice_hook::VoiceClip* fmt = nullptr;
  double peak = 1.0;
  for (const auto* c : valid) {
    if (filter_by_src && c->source_ptr != sel_src) {
      continue;
    }
    const int64_t d = static_cast<int64_t>(c->timestamp_ms) -
                      static_cast<int64_t>(ts_ms);
    if (static_cast<int64_t>(c->timestamp_ms) < lower_ts || d > forward_ms) {
      continue;
    }
    const double e = ClipEnergy16Locked(h, ring, c);
    if (e > peak) {
      peak = e;
    }
    if (ReadClipPcmLocked(h, ring, c, pcm) && fmt == nullptr) {
      fmt = c;
    }
  }
  if (fmt == nullptr || pcm.empty()) {
    return VoiceHookStatus{};
  }
  // 去首尾静音（16-bit）：阈值 = peak*0.08，帧对齐。
  if (fmt->bits_per_sample == 16 && !fmt->is_float) {
    const int16_t thr = static_cast<int16_t>(peak * 0.08);
    const int16_t* s = reinterpret_cast<const int16_t*>(pcm.data());
    const size_t n = pcm.size() / 2;
    size_t lo = 0, hi = n;
    while (lo < n && (s[lo] < 0 ? -s[lo] : s[lo]) < thr) {
      lo++;
    }
    while (hi > lo && (s[hi - 1] < 0 ? -s[hi - 1] : s[hi - 1]) < thr) {
      hi--;
    }
    const uint32_t ch = fmt->channels ? fmt->channels : 1;
    lo -= (lo % ch);  // 帧对齐
    hi -= (hi % ch);
    if (hi > lo) {
      std::vector<uint8_t> trimmed(
          pcm.begin() + static_cast<long>(lo * 2),
          pcm.begin() + static_cast<long>(hi * 2));
      pcm.swap(trimmed);
    }
  }
  out.swap(pcm);
  VoiceHookStatus s = status;
  s.sample_rate = static_cast<int>(fmt->sample_rate);
  s.channels = static_cast<int>(fmt->channels);
  s.bits_per_sample = static_cast<int>(fmt->bits_per_sample);
  s.is_float = fmt->is_float != 0;
  return s;
}

void VoiceHookReader::ListAudioTracks(uint64_t ts_ms,
                                      std::vector<VoiceTrackInfo>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  const VoiceHookStatus status = StatusFromHeaderLocked(h);
  if (!status.ok) {
    return;
  }
  const std::vector<const fushi_voice_hook::VoiceClip*> valid =
      CollectValidClipsLocked(h);
  if (valid.empty()) {
    return;
  }
  const uint8_t* ring =
      reinterpret_cast<const uint8_t*>(h) + sizeof(SharedHeader);
  // 按 source_ptr 聚合；order_index 按该源首次出现（valid 已按 seq 升序）分配。
  std::map<uint64_t, VoiceTrackInfo> tracks;
  std::map<uint64_t, uint64_t> sum_bytes;    // 段字节累计
  std::map<uint64_t, double> sum_energy_at;  // 文本时刻窗能量累计
  std::map<uint64_t, int> n_energy_at;       // 文本时刻窗**能算出能量**的段数（仅 16-bit）
  std::map<uint64_t, int> n_clips_at;        // 文本时刻窗内的段数（与位深无关，BUG-1165）
  int next_order = 0;
  for (const auto* c : valid) {
    auto it = tracks.find(c->source_ptr);
    if (it == tracks.end()) {
      VoiceTrackInfo info;
      info.source_ptr = c->source_ptr;
      info.sample_rate = static_cast<int>(c->sample_rate);
      info.channels = static_cast<int>(c->channels);
      info.bits_per_sample = static_cast<int>(c->bits_per_sample);
      info.is_float = c->is_float != 0;
      info.order_index = next_order++;
      it = tracks.emplace(c->source_ptr, info).first;
    }
    it->second.clip_count++;
    sum_bytes[c->source_ptr] += c->byte_len;
    const int64_t d =
        static_cast<int64_t>(c->timestamp_ms) - static_cast<int64_t>(ts_ms);
    if (d >= -150 && d <= 450) {
      // 先无条件计数：这条轨在这句时刻窗内**有没有出声**与能不能算能量无关。
      // 能量只在 16-bit 上算得出来（ClipEnergy16Locked 其余返回 -1），拿能量兼作
      // 「有没有段」的判据会把非 16-bit 的可用轨误判成静音（BUG-1165）。
      n_clips_at[c->source_ptr]++;
      const double e = ClipEnergy16Locked(h, ring, c);
      if (e >= 0) {
        sum_energy_at[c->source_ptr] += e;
        n_energy_at[c->source_ptr]++;
      }
    }
  }
  for (const auto& kv : tracks) {
    VoiceTrackInfo info = kv.second;
    if (info.clip_count > 0) {
      info.avg_bytes =
          sum_bytes[kv.first] / static_cast<uint64_t>(info.clip_count);
    }
    const int ne = n_energy_at.count(kv.first) ? n_energy_at[kv.first] : 0;
    info.avg_energy = (ne > 0) ? sum_energy_at[kv.first] / ne : -1.0;
    info.clip_count_at_cue =
        n_clips_at.count(kv.first) ? n_clips_at[kv.first] : 0;
    out.push_back(info);
  }
  // 按创建顺序返回（UI 稳定展示）。
  std::sort(out.begin(), out.end(),
            [](const VoiceTrackInfo& a, const VoiceTrackInfo& b) {
              return a.order_index < b.order_index;
            });
}

void VoiceHookReader::Close() {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  CloseLocked(st);
}

// ══ v14 游戏内查词通道 ═════════════════════════════════════════════════════════

const char* VoiceHookLookupErrorToken(VoiceHookLookupError error) {
  switch (error) {
    case VoiceHookLookupError::kNone:
      return "none";
    case VoiceHookLookupError::kNotOpen:
      return "not_open";
    case VoiceHookLookupError::kNoRegion:
      return "no_lookup_region";
    case VoiceHookLookupError::kNotEnabled:
      return "lookup_disabled";
    case VoiceHookLookupError::kNoCaptureSource:
      return "no_capture_source";
    case VoiceHookLookupError::kCaptureFailed:
      return "capture_failed";
    case VoiceHookLookupError::kFrameRejected:
      return "frame_rejected";
  }
  return "unknown";
}

void VoiceHookReader::AttachLookupChannel(flutter::BinaryMessenger* messenger) {
  if (messenger == nullptr) {
    DetachLookupChannel();
    return;
  }
  LookupPumpState& pump = Pump();
  EnsureLookupPumpWindow();
  // 🔴 只建对象、**不** SetMethodCallHandler：同名通道在 messenger 里只有一个
  // handler 槽位，注册就顶掉 flutter_window 的 gal_hook_text 处理器，浮窗的
  // show/hide/updateText 会一起失效。Dart→runner 那半边走 TryHandleLookupMethodCall。
  pump.channel = std::make_unique<LookupChannel>(
      messenger, kGalHookTextChannel,
      &flutter::StandardMethodCodec::GetInstance());
}

void VoiceHookReader::DetachLookupChannel() {
  LookupPumpState& pump = Pump();
  StopLookupPump();
  // 同上：从没注册过 handler，所以这里也不能注销（注销会把 flutter_window 那份
  // 一起清掉）。只丢自己的通道对象。
  pump.channel.reset();
  pump.capture = nullptr;
  pump.input_sink = nullptr;
  if (pump.hwnd != nullptr) {
    DestroyWindow(pump.hwnd);
    pump.hwnd = nullptr;
  }
}

bool VoiceHookReader::TryHandleLookupMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  return HandleLookupCall(call, result);
}

void VoiceHookReader::SetLookupCaptureRequest(LookupCaptureRequest request) {
  Pump().capture = std::move(request);
}

void VoiceHookReader::SetLookupInputSink(LookupInputSink sink) {
  Pump().input_sink = std::move(sink);
}

bool VoiceHookReader::HasLookupChannel() {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  return LookupGateLocked(st.header, false) == VoiceHookLookupError::kNone;
}

VoiceHookLookupError VoiceHookReader::PeekLookupGate(bool require_enabled) {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  return LookupGateLocked(st.header, require_enabled);
}

VoiceHookLookupError VoiceHookReader::SetLookupEnabled(bool enabled) {
  {
    ReaderState& st = State();
    std::lock_guard<std::mutex> lock(st.mutex);
    SharedHeader* h = st.header;
    // 意图先记，且**在闸门之前**记：用户可以在游戏还没起来时就打开开关，此时没有段、
    // 写不进去，但这依然是一个有效意图——等 Open 拿到段时按它重放。把它记在闸门后面
    // 就等于「开关只在游戏已经在跑时才算数」，而那正是用户最容易踩的顺序。
    st.lookup_enabled_desired = enabled;
    const VoiceHookLookupError gate = LookupGateLocked(h, false);
    if (gate != VoiceHookLookupError::kNone) {
      return gate;
    }
    InterlockedExchange(reinterpret_cast<volatile LONG*>(&h->lookup_enabled),
                        enabled ? 1 : 0);
    if (enabled) {
      // 重新开启即重新对齐游标：关着的这段时间里注入侧可能仍在写 hit（它只在
      // lookup_enabled 时才该写，但那是它的自律，不是 host 能保证的不变量）。
      ResetLookupCursorsLocked(st, h);
    }
  }
  // SetTimer/KillTimer 在锁外：它们要进内核，没理由在持锁时做。
  if (enabled) {
    StartLookupPump();
  } else {
    StopLookupPump();
  }
  return VoiceHookLookupError::kNone;
}

bool VoiceHookReader::PollLookupHit(VoiceHookLookupHit* out) {
  if (out == nullptr) {
    return false;
  }
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  if (LookupGateLocked(h, false) != VoiceHookLookupError::kNone) {
    return false;
  }
  const uint64_t count =
      fushi_voice_hook::AtomicLoadPreview64(&h->lookup_hit_count);
  if (count == st.lookup_hit_count) {
    return false;  // 计数没动 = 没有新命中，连槽都不必读
  }
  // 注意：**读成功之前绝不推进 st.lookup_hit_count**。在这里先推进，一旦下面的
  // 撕裂重试用尽就等于把这条 hit 永久吞掉——下一拍会因为"计数没动"直接返回，
  // 用户点了字幕却什么都没发生，且没有任何痕迹。
  const fushi_voice_hook::LookupHitSlot* slot =
      fushi_voice_hook::LookupHitOf(h);
  if (slot == nullptr) {
    return false;
  }
  // 单槽 latest-wins：写者随时可能在我们读 payload 的中途发布下一条。读完复查 seq，
  // 变了就整条重读——手上那份可能是两次命中的拼接（前半行 A、后半行 B），拿去查词
  // 会得到一个谁都没说过的句子。四次仍不稳定就放弃，下一拍再来（16ms 后）。
  for (int attempt = 0; attempt < 4; attempt++) {
    const uint64_t seq = fushi_voice_hook::AtomicLoadPreview64(&slot->seq);
    if (seq == 0 || seq <= st.lookup_hit_seq) {
      // 计数动了但 seq 没前进：注入侧的重复发布，不是新命中。这条路径上推进计数
      // 是安全的（没有待读的东西），省掉后面每一拍的无效重扫。
      st.lookup_hit_count = count;
      return false;
    }
    VoiceHookLookupHit hit;
    hit.seq = seq;
    hit.char_index = slot->char_index;
    hit.char_count = slot->char_count;
    hit.glyph_x = slot->glyph_x;
    hit.glyph_y = slot->glyph_y;
    hit.glyph_w = slot->glyph_w;
    hit.glyph_h = slot->glyph_h;
    hit.view_w = slot->view_w;
    hit.view_h = slot->view_h;
    hit.submit = (slot->flags & fushi_voice_hook::kLookupHitFlagSubmit) != 0;
    uint32_t line_bytes = slot->line_bytes;
    if (line_bytes > fushi_voice_hook::kLookupLineBytes) {
      line_bytes = fushi_voice_hook::kLookupLineBytes;
    }
    hit.line_utf8.assign(reinterpret_cast<const char*>(slot->line_utf8),
                         line_bytes);
    if (fushi_voice_hook::AtomicLoadPreview64(&slot->seq) != seq) {
      continue;
    }
    st.lookup_hit_count = count;
    st.lookup_hit_seq = seq;
    *out = std::move(hit);
    return true;
  }
  return false;  // 四次都撞上写者：游标原地不动，下一拍（16ms 后）重来
}

void VoiceHookReader::PollLookupInputs(
    std::vector<VoiceHookLookupInput>& out) {
  out.clear();
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  const SharedHeader* h = st.header;
  if (LookupGateLocked(h, false) != VoiceHookLookupError::kNone) {
    return;
  }
  const uint64_t count =
      fushi_voice_hook::AtomicLoadPreview64(&h->lookup_input_count);
  if (count <= st.lookup_input_seq) {
    return;
  }
  const uint32_t slots = h->lookup_input_slot_count;
  const fushi_voice_hook::LookupInputSlot* base =
      fushi_voice_hook::LookupInputsOf(h);
  if (slots == 0 || base == nullptr) {
    return;
  }
  uint64_t from = st.lookup_input_seq;
  if (count - from > slots) {
    // 落后超过一整圈：中间那段已被覆盖。**不补**——补出来的是别的事件的残骸，
    // 把它当成鼠标轨迹喂进 WebView2 只会让卡片乱跳。直接跳到还活着的最旧一条。
    from = count - slots;
  }
  for (uint64_t seq = from + 1; seq <= count; seq++) {
    const fushi_voice_hook::LookupInputSlot& slot =
        base[static_cast<size_t>((seq - 1) % slots)];
    if (fushi_voice_hook::AtomicLoadPreview64(&slot.seq) != seq) {
      continue;  // 半写槽或刚被下一圈覆盖
    }
    VoiceHookLookupInput input;
    input.seq = seq;
    input.x = slot.x;
    input.y = slot.y;
    input.kind = slot.kind;
    input.wheel = slot.wheel;
    input.keys = slot.keys;
    // 复查：读 payload 期间写者绕回来覆盖了这一槽，本条作废（同 hit 的纪律）。
    if (fushi_voice_hook::AtomicLoadPreview64(&slot.seq) != seq) {
      continue;
    }
    out.push_back(input);
  }
  st.lookup_input_seq = count;
}

VoiceHookLookupWriteResult VoiceHookReader::WriteLookupFrame(
    const VoiceHookLookupPresent& meta, const uint8_t* bgra, uint32_t width,
    uint32_t height, uint32_t pitch) {
  VoiceHookLookupWriteResult out;
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  SharedHeader* h = st.header;
  out.error = LookupGateLocked(h, true);
  if (out.error != VoiceHookLookupError::kNone) {
    return out;
  }
  if (bgra == nullptr || width == 0 || height == 0 ||
      pitch < static_cast<uint64_t>(width) * 4u) {
    out.error = VoiceHookLookupError::kFrameRejected;
    return out;
  }
  const uint32_t budget = h->lookup_bitmap_bytes;
  if (pitch == 0 || pitch > budget) {
    // 一行都放不下：卡片宽得离谱（或 pitch 本身是坏值）。这不是"裁一裁就能投"的
    // 情形，裁行只会得到一张宽度错的图。
    out.error = VoiceHookLookupError::kFrameRejected;
    return out;
  }
  // 字节预算按**行**裁：位图是行优先的，裁尾部若干行既不改宽度也不动 pitch，
  // 是唯一不需要重排像素的钳制方式。裁过就一定要让上层知道（out.clamped）——
  // 静默投一张缺下半截的卡片，症状是"玄学缺字"，谁也查不出原因。
  uint32_t rows = height;
  const uint32_t max_rows = budget / pitch;
  if (rows > max_rows) {
    rows = max_rows;
    out.clamped = true;
  }
  if (rows == 0) {
    out.error = VoiceHookLookupError::kFrameRejected;
    return out;
  }
  // 🔴 槽下标是契约的一部分：元数据槽与像素块**同用** seq % lookup_frame_count
  // （voice_hook_ipc.h 的 LookupFrame 注释）。注入侧按这个下标读两边，用自己的轮转
  // 计数器放元数据就会全量拒帧——而"卡片永远不出现"与"host 压根没投帧"完全同形，
  // 真机上分不开。所以这里只算**一个** index，两处共用。
  // 下标用**发布序**（不是 hit seq）：同一次 hit 可能先 present 再 dismiss，用 hit seq
  // 算下标会让这两帧落进同一个槽、后者覆盖前者，双缓冲直接失效。
  const uint64_t publish_seq = ++st.lookup_publish_seq;
  const uint32_t index =
      static_cast<uint32_t>(publish_seq % h->lookup_frame_count);
  fushi_voice_hook::LookupFrame* frame =
      fushi_voice_hook::LookupFrameAt(h, index);
  uint8_t* dst = fushi_voice_hook::LookupBitmapAt(h, index);
  if (frame == nullptr || dst == nullptr) {
    out.error = VoiceHookLookupError::kNoRegion;
    return out;
  }
  // 先在**本地**组装并过 IsLookupFrameSane，再决定要不要动共享内存。反过来（先写
  // 进去再判断）等于把一张不合契约的帧短暂暴露给注入侧，而它那边正拿着 ready 位轮询。
  fushi_voice_hook::LookupFrame staged = {};
  staged.seq = publish_seq;   // 发布序：注入侧据此判新/去重/算槽
  staged.hit_seq = meta.seq;  // 这帧回应哪次 hit：注入侧据此判是否已被更新命中作废
  staged.flags = 0;
  staged.width = width;
  staged.height = rows;
  staged.pitch = pitch;
  staged.anchor_x = meta.anchor_x;
  staged.anchor_y = meta.anchor_y;
  staged.highlight_start = meta.highlight_start;
  staged.highlight_len = meta.highlight_len;
  staged.byte_len = pitch * rows;
  staged.ready = 1;
  if (!fushi_voice_hook::IsLookupFrameSane(h, &staged)) {
    out.error = VoiceHookLookupError::kFrameRejected;
    return out;
  }
  // ① ready=0：注入侧看到 0 就不拷这块缓冲，后面的像素写入不会被读到半截。
  InterlockedExchange(reinterpret_cast<volatile LONG*>(&frame->ready), 0);
  // ② 像素。
  memcpy(dst, bgra, staged.byte_len);
  // ③ 元数据（seq 之外）。
  frame->width = staged.width;
  frame->height = staged.height;
  frame->pitch = staged.pitch;
  frame->anchor_x = staged.anchor_x;
  frame->anchor_y = staged.anchor_y;
  frame->highlight_start = staged.highlight_start;
  frame->highlight_len = staged.highlight_len;
  frame->byte_len = staged.byte_len;
  frame->hit_seq = staged.hit_seq;
  frame->flags = staged.flags;
  frame->reserved = 0;
  frame->reserved2 = 0;
  // ④ seq：Interlocked，x86 上 64 位普通写会被拆成两次 32 位写而撕裂。
  fushi_voice_hook::AtomicStorePreview64(&frame->seq, publish_seq);
  // ⑤ ready=1 **最后**写：Interlocked 是全栅栏，把 ①-④ 一次性对注入侧公开。
  InterlockedExchange(reinterpret_cast<volatile LONG*>(&frame->ready), 1);
  // ⑥ 帧计数（注入侧/诊断据此判"有没有新帧"）。
  InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&h->lookup_frame_count_written));
  out.width = width;
  out.height = rows;
  out.pitch = pitch;
  return out;
}

VoiceHookLookupError VoiceHookReader::WriteLookupHighlight(
    const VoiceHookLookupPresent& meta) {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  SharedHeader* h = st.header;
  const VoiceHookLookupError gate = LookupGateLocked(h, true);
  if (gate != VoiceHookLookupError::kNone) {
    return gate;
  }
  // 只更新高亮：与收卡同构的"无像素帧"，区别只在 flags。
  //
  // 为什么值得单开一条路：悬停换一个字，卡片内容一个像素都没变，但普通 present 会
  // 走完整的「CapturePreview → PNG 编码 → WIC 解码 → 全卡 memcpy」。鼠标划过一行就是
  // 几十次，真机症状就是"太卡了"。高亮画在游戏自己的图层上、不在卡片位图里，所以这条
  // 路一个像素都不需要。
  const uint64_t publish_seq = ++st.lookup_publish_seq;
  const uint32_t index =
      static_cast<uint32_t>(publish_seq % h->lookup_frame_count);
  fushi_voice_hook::LookupFrame* frame =
      fushi_voice_hook::LookupFrameAt(h, index);
  if (frame == nullptr) {
    return VoiceHookLookupError::kNoRegion;
  }
  InterlockedExchange(reinterpret_cast<volatile LONG*>(&frame->ready), 0);
  frame->width = 0;
  frame->height = 0;
  frame->pitch = 0;
  frame->anchor_x = meta.anchor_x;
  frame->anchor_y = meta.anchor_y;
  frame->highlight_start = meta.highlight_start;
  frame->highlight_len = meta.highlight_len;
  frame->byte_len = 0;
  frame->hit_seq = meta.seq;
  frame->flags = fushi_voice_hook::kLookupFrameHighlightOnly;
  frame->reserved = 0;
  frame->reserved2 = 0;
  fushi_voice_hook::AtomicStorePreview64(&frame->seq, publish_seq);
  InterlockedExchange(reinterpret_cast<volatile LONG*>(&frame->ready), 1);
  InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&h->lookup_frame_count_written));
  return VoiceHookLookupError::kNone;
}

VoiceHookLookupError VoiceHookReader::WriteLookupDismiss(uint64_t seq) {
  ReaderState& st = State();
  std::lock_guard<std::mutex> lock(st.mutex);
  SharedHeader* h = st.header;
  // require_enabled=false：收卡这条路在开关已经被关掉之后仍然必须走得通，否则
  // "关掉游戏内查词"会把最后一张卡片永久留在游戏画面上。
  const VoiceHookLookupError gate = LookupGateLocked(h, false);
  if (gate != VoiceHookLookupError::kNone) {
    return gate;
  }
  // 收卡是**普通一帧**：拿一个新的发布序，落进它自己的槽，靠 kLookupFrameDismiss 自述。
  //
  // 这里曾经是整条链上唯一不通的地方，根因是数据结构而不是漏了分支：`seq` 当时既当发布序
  // 又当"回应哪次 hit"，于是收卡帧只能复用被撤那张卡的 seq，而那个 seq 刚 present 过，
  // 被注入侧的 `seq <= presented_seq` 当陈旧帧扔掉——补 0×0 分支也救不回来，因为帧压根
  // 进不了候选。两个序号拆开之后收卡不需要任何特例。
  const uint64_t publish_seq = ++st.lookup_publish_seq;
  const uint32_t index =
      static_cast<uint32_t>(publish_seq % h->lookup_frame_count);
  fushi_voice_hook::LookupFrame* frame =
      fushi_voice_hook::LookupFrameAt(h, index);
  if (frame == nullptr) {
    return VoiceHookLookupError::kNoRegion;
  }
  // 收卡帧按定义没有像素，故不过 IsLookupFrameSane（那个函数守的是"按收到的尺寸盲拷"
  // 这条越界路径，按定义拒绝 0 宽高）。注入侧同样在 sane 校验**之前**按 flags 认掉。
  InterlockedExchange(reinterpret_cast<volatile LONG*>(&frame->ready), 0);
  frame->width = 0;
  frame->height = 0;
  frame->pitch = 0;
  frame->anchor_x = 0;
  frame->anchor_y = 0;
  frame->highlight_start = 0;
  frame->highlight_len = 0;
  frame->byte_len = 0;
  frame->hit_seq = seq;
  frame->flags = fushi_voice_hook::kLookupFrameDismiss;
  frame->reserved = 0;
  frame->reserved2 = 0;
  fushi_voice_hook::AtomicStorePreview64(&frame->seq, publish_seq);
  InterlockedExchange(reinterpret_cast<volatile LONG*>(&frame->ready), 1);
  InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&h->lookup_frame_count_written));
  return VoiceHookLookupError::kNone;
}

}  // namespace fushi
