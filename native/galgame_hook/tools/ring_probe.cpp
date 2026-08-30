#include <windows.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <limits>
#include <string>
#include <vector>

#include "voice_clip_energy.h"
#include "hunex_gge_trace.h"
#include "leaf_d3d_trace.h"
#include "voice_hook_ipc.h"
#include "voice_hook_utterance_window.h"
#include "xaudio_trace.h"

// galgame 一键制卡 C 阶段 —— 环形缓冲诊断读取器（x64 独立小工具）。
//
// 用途：injector 早注入（--launch）目标游戏、放着游戏出声后，用它旁路读共享内存，直观确认
// DirectSound/XAudio2 捕获真的在工作——hooked=1、格式被 hook 填上、total_written 在涨、峰值
// 振幅从 silent 变 SOUND。**只读**，不注入、不写共享内存，故不需与目标同位数：命名文件映射
// （Local\HibikiVoiceHook_<pid>）跨 32/64 位可读，x64 reader 能读 32 位游戏里 hook 填的缓冲。
//
// 用法：fushi_voice_ring_probe <pid> [轮数=30] [间隔ms=500]
//   <pid>    injector 建共享内存时用的目标进程 pid（injector 打印的 pid=）
//   轮数     采样轮数（缺省 30）
//   间隔ms   每轮间隔毫秒（缺省 500）
namespace {

using fushi_voice_hook::kSharedMagic;
using fushi_voice_hook::kSharedVersion;
using fushi_voice_hook::SharedHeader;
using fushi_voice_hook::SharedMemoryName;

const char* NativeLoopbackStateName(uint32_t state) {
  switch (state) {
    case fushi_voice_hook::kNativeLoopbackStateStopped:
      return "stopped";
    case fushi_voice_hook::kNativeLoopbackStateStarting:
      return "starting";
    case fushi_voice_hook::kNativeLoopbackStateRunning:
      return "running";
    case fushi_voice_hook::kNativeLoopbackStateStopping:
      return "stopping";
    case fushi_voice_hook::kNativeLoopbackStateFailed:
      return "failed";
    default:
      return "unknown";
  }
}

// int16 判定阈值：峰值 > 300（约 -40 dBFS）算 SOUND，否则 silent。float32 折算到 int16
// 量纲（*32767）后同阈值比较。
constexpr double kSoundThreshold = 300.0;

// 从环形缓冲取最近 [want] 字节（已 block 对齐）到连续缓冲 out，处理回绕。ring/cap 是环形区
// 基址与容量，write_pos 是下一写入位置，avail 是当前可读字节（<=cap）。want<=avail<=cap。
void CopyRecent(const uint8_t* ring, uint32_t cap, uint32_t write_pos,
                uint32_t want, std::vector<uint8_t>* out) {
  out->resize(want);
  if (want == 0) {
    return;
  }
  // 最近 want 字节的起点：从 write_pos 往回退 want（环形取模）。
  const uint32_t start = (write_pos + cap - want) % cap;
  const uint32_t first = (start + want <= cap) ? want : (cap - start);
  memcpy(out->data(), ring + start, first);
  if (want > first) {
    memcpy(out->data() + first, ring, want - first);
  }
}

// 按 bits/is_float 解码窗口，返回峰值 |sample|（float 归一到 32767 量纲，便于与 int16 阈值同尺
// 度比较）。bits==16 当 int16；bits==32 且 is_float 当 float32；其它格式返回 -1（未知）。
double PeakAmplitude(const std::vector<uint8_t>& buf, uint32_t bits,
                     uint32_t is_float) {
  double peak = 0.0;
  if (bits == 16) {
    const size_t n = buf.size() / sizeof(int16_t);
    const auto* s = reinterpret_cast<const int16_t*>(buf.data());
    for (size_t i = 0; i < n; i++) {
      const double v = std::fabs(static_cast<double>(s[i]));
      if (v > peak) {
        peak = v;
      }
    }
    return peak;
  }
  if (bits == 32 && is_float != 0) {
    const size_t n = buf.size() / sizeof(float);
    const auto* s = reinterpret_cast<const float*>(buf.data());
    for (size_t i = 0; i < n; i++) {
      const double v = std::fabs(static_cast<double>(s[i])) * 32767.0;
      if (v > peak) {
        peak = v;
      }
    }
    return peak;
  }
  return -1.0;  // 未知/暂不支持的格式（如 8/24 位整型）。
}

// 导出文本环里所有台词行到 stdout：每行 `seq|ts_ms|utf8文本`。供外层做卡的句子来源。
void DumpText(const SharedHeader* h) {
  // v13：文本按线程分道，寻址与归并只有契约头里那一份实现（host 读侧用的是同一个函数）。
  static const fushi_voice_hook::TextSlot*
      slots[fushi_voice_hook::kTextSlotCount];
  const uint32_t found = fushi_voice_hook::CollectTextSlotsBySeq(
      h, slots, fushi_voice_hook::kTextSlotCount, 0);
  for (uint32_t i = 0; i < found; ++i) {
    const auto* slot = slots[i];
    if (slot->byte_len == 0) continue;
    char u8[1400] = {0};
    const uint8_t* txt = reinterpret_cast<const uint8_t*>(slot) +
                         sizeof(fushi_voice_hook::TextSlot);
    if (slot->is_utf8) {
      uint32_t n = slot->byte_len;
      if (n > 1399) n = 1399;
      memcpy(u8, txt, n);
    } else {
      WideCharToMultiByte(CP_UTF8, 0, reinterpret_cast<const wchar_t*>(txt),
                          static_cast<int>(slot->byte_len / 2), u8,
                          sizeof(u8) - 1, nullptr, nullptr);
    }
    printf("%llu|%llu|%s\n", static_cast<unsigned long long>(slot->seq),
           static_cast<unsigned long long>(slot->timestamp_ms), u8);
  }
  fflush(stdout);
}

void DumpTextMeta(const SharedHeader* h) {
  // v13：按线程分道枚举（实现见契约头 CollectTextSlotsBySeq，host 读侧共用）。
  static const fushi_voice_hook::TextSlot*
      meta_slots[fushi_voice_hook::kTextSlotCount];
  const uint32_t meta_found = fushi_voice_hook::CollectTextSlotsBySeq(
      h, meta_slots, fushi_voice_hook::kTextSlotCount, 0);
  for (uint32_t mi = 0; mi < meta_found; ++mi) {
    const auto* slot = meta_slots[mi];
    const uint64_t seq = slot->seq;
    if (slot->byte_len == 0) continue;
    char text[1400] = {0};
    const uint8_t* raw = reinterpret_cast<const uint8_t*>(slot) +
                         sizeof(fushi_voice_hook::TextSlot);
    if (slot->is_utf8 != 0) {
      memcpy(text, raw, (std::min)(slot->byte_len, 1399u));
    } else {
      WideCharToMultiByte(CP_UTF8, 0,
                          reinterpret_cast<const wchar_t*>(raw),
                          static_cast<int>(slot->byte_len / 2), text,
                          sizeof(text) - 1, nullptr, nullptr);
    }
    char hook_code[600] = {0};
    WideCharToMultiByte(CP_UTF8, 0, slot->hook_code,
                        static_cast<int>(slot->hook_code_len), hook_code,
                        sizeof(hook_code) - 1, nullptr, nullptr);
    printf("%llu|%llu|%llu|%u|%.*s|%s|%s\n",
           static_cast<unsigned long long>(seq),
           static_cast<unsigned long long>(slot->timestamp_ms),
           static_cast<unsigned long long>(slot->thread_id),
           slot->source_kind, static_cast<int>(slot->hook_name_len),
           slot->hook_name, hook_code, text);
  }
  fflush(stdout);
}

void DumpTextEvents(const SharedHeader* h) {
  // v13：同上，按线程分道枚举。
  static const fushi_voice_hook::TextSlot*
      evt_slots[fushi_voice_hook::kTextSlotCount];
  const uint32_t evt_found = fushi_voice_hook::CollectTextSlotsBySeq(
      h, evt_slots, fushi_voice_hook::kTextSlotCount, 0);
  for (uint32_t ei = 0; ei < evt_found; ++ei) {
    const auto* slot = evt_slots[ei];
    const uint64_t seq = slot->seq;
    char text[1400] = {0};
    if (slot->byte_len != 0) {
      const uint8_t* raw = reinterpret_cast<const uint8_t*>(slot) +
                           sizeof(fushi_voice_hook::TextSlot);
      if (slot->is_utf8 != 0) {
        memcpy(text, raw, (std::min)(slot->byte_len, 1399u));
      } else {
        WideCharToMultiByte(CP_UTF8, 0,
                            reinterpret_cast<const wchar_t*>(raw),
                            static_cast<int>(slot->byte_len / 2), text,
                            sizeof(text) - 1, nullptr, nullptr);
      }
    }
    char hook_code[600] = {0};
    WideCharToMultiByte(CP_UTF8, 0, slot->hook_code,
                        static_cast<int>(slot->hook_code_len), hook_code,
                        sizeof(hook_code) - 1, nullptr, nullptr);
    printf("%llu|%llu|%llu|%u|%u|%u|%.*s|%s|%s\n",
           static_cast<unsigned long long>(seq),
           static_cast<unsigned long long>(slot->timestamp_ms),
           static_cast<unsigned long long>(slot->thread_id),
           slot->source_kind, slot->event_kind, slot->event_flags,
           static_cast<int>(slot->hook_name_len), slot->hook_name, hook_code,
           text);
  }
  fflush(stdout);
}

void DumpUnityEvents(const SharedHeader* h) {
  const uint64_t count = h->unity_voice_write_count;
  const uint64_t start = count > fushi_voice_hook::kUnityVoiceEventCount
                             ? count - fushi_voice_hook::kUnityVoiceEventCount
                             : 0;
  for (uint64_t seq = start + 1; seq <= count; ++seq) {
    const auto* event = &h->unity_voice_events[
        (seq - 1) % fushi_voice_hook::kUnityVoiceEventCount];
    if (event->seq != seq) continue;
    char clip[512] = {0};
    char bundle[1600] = {0};
    WideCharToMultiByte(CP_UTF8, 0, event->clip_name, -1, clip,
                        sizeof(clip) - 1, nullptr, nullptr);
    WideCharToMultiByte(CP_UTF8, 0, event->bundle_path, -1, bundle,
                        sizeof(bundle) - 1, nullptr, nullptr);
    printf("%llu|%llu|%s|%s\n",
           static_cast<unsigned long long>(seq),
           static_cast<unsigned long long>(event->timestamp_ms), clip,
           bundle);
  }
  fflush(stdout);
}

// 找时间戳最近 [ts] 的语音 clip，从音频环形取其 PCM 写成 WAV 到 [path]。成功返回 true。
bool DumpWav(const SharedHeader* h, const uint8_t* ring, uint64_t ts,
             const char* path) {
  const uint32_t cap = h->ring_capacity;
  const uint64_t clips = h->clip_write_count;
  if (cap == 0 || clips == 0) return false;
  const uint32_t cslots = fushi_voice_hook::kClipCount;
  const uint8_t* cbase =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t total = h->total_written;
  const uint64_t scan = (clips > cslots) ? clips - cslots : 0;
  const fushi_voice_hook::VoiceClip* best = nullptr;
  uint64_t bestDiff = ~0ull;
  for (uint64_t seq = scan + 1; seq <= clips; seq++) {
    const auto* c = reinterpret_cast<const fushi_voice_hook::VoiceClip*>(
        cbase + static_cast<size_t>((seq - 1) % cslots) *
                    sizeof(fushi_voice_hook::VoiceClip));
    if (c->seq != seq || c->byte_len == 0 || c->byte_len > cap) continue;
    if (total > c->total_at_write &&
        total - c->total_at_write > cap - c->byte_len)
      continue;
    const uint64_t d =
        (c->timestamp_ms > ts) ? c->timestamp_ms - ts : ts - c->timestamp_ms;
    if (d < bestDiff) { bestDiff = d; best = c; }
  }
  if (best == nullptr) return false;
  const uint32_t off = best->ring_offset % cap;
  const uint32_t len = best->byte_len;
  std::vector<uint8_t> pcm(len);
  const uint32_t first = (len <= cap - off) ? len : (cap - off);
  memcpy(pcm.data(), ring + off, first);
  if (len > first) memcpy(pcm.data() + first, ring, len - first);
  const uint32_t sr = best->sample_rate, ch = best->channels,
                 bits = best->bits_per_sample;
  const uint32_t ba = ch * (bits / 8), br = sr * ba;
  const uint16_t fmt = best->is_float ? 3 : 1;
  FILE* f = fopen(path, "wb");
  if (f == nullptr) return false;
  auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
  auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
  fwrite("RIFF", 1, 4, f); w32(36 + len); fwrite("WAVE", 1, 4, f);
  fwrite("fmt ", 1, 4, f); w32(16); w16(fmt); w16(static_cast<uint16_t>(ch));
  w32(sr); w32(br); w16(static_cast<uint16_t>(ba));
  w16(static_cast<uint16_t>(bits));
  fwrite("data", 1, 4, f); w32(len); fwrite(pcm.data(), 1, len, f);
  fclose(f);
  printf("wrote %s bytes=%u fmt=%u/%u/%u float=%u ts=%llu diff=%llu\n", path,
         len, sr, ch, bits, best->is_float,
         static_cast<unsigned long long>(best->timestamp_ms),
         static_cast<unsigned long long>(bestDiff));
  return true;
}

// 把一条 clip 的 PCM 从环形读出追加到 out；已被环形覆盖返回 false。
bool ReadClipPcm(const SharedHeader* h, const uint8_t* ring,
                 const fushi_voice_hook::VoiceClip* c,
                 std::vector<uint8_t>& out) {
  const uint32_t cap = h->ring_capacity;
  const uint32_t len = c->byte_len;
  if (len == 0 || len > cap) {
    return false;
  }
  if (h->total_written > c->total_at_write &&
      h->total_written - c->total_at_write > cap - len) {
    return false;  // 已被覆盖
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

// PCM 平均绝对幅值（能量代理），归一到 16-bit 标度、与位深/浮点无关；位深真的不认识才
// 返回 -1。算法与 host 侧 `voice_hook_reader.cpp` 共用 `voice_clip_energy.h` 的唯一一份实现
// ——这里曾是它的第二份手抄拷贝，而取证工具报「非 16-bit 无能量」会把排查直接带偏
// （BUG-1769 的定位就差点被这一点误导）。
double ClipEnergy16(const SharedHeader* h, const uint8_t* ring,
                    const fushi_voice_hook::VoiceClip* c) {
  const uint32_t cap = h->ring_capacity;
  const uint32_t len = c->byte_len;
  if (cap == 0 || len == 0 || len > cap) {
    return -1.0;
  }
  if (h->total_written > c->total_at_write &&
      h->total_written - c->total_at_write > cap - len) {
    return 0.0;  // 已被环形覆盖
  }
  return fushi_voice_hook::ClipEnergy16Scale(ring, cap, c->ring_offset % cap,
                                             len, c->bits_per_sample,
                                             c->is_float != 0);
}

// 「整句语音」根修：游戏用多个 source voice 持续并行流式（语音源没人说话时流静音）。按源做能量
// 分析选出语音源（说话前静音、文本时刻突然有能量的那条），取它从起声到静默的整段拼成一句。
// 找 ts 附近的语音源，把该源在 [ts-200ms, 起声后连续非静音段] 的 PCM 拼接、去首尾静音，写 WAV。
bool DumpUtterance(const SharedHeader* h, const uint8_t* ring, uint64_t ts,
                   const char* path) {
  const uint32_t cap = h->ring_capacity;
  const uint64_t clips = h->clip_write_count;
  if (cap == 0 || clips == 0) {
    return false;
  }
  const uint32_t cslots = fushi_voice_hook::kClipCount;
  const uint8_t* cbase =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t scan = (clips > cslots) ? clips - cslots : 0;
  // 收集有效 clip 指针。
  std::vector<const fushi_voice_hook::VoiceClip*> valid;
  for (uint64_t seq = scan + 1; seq <= clips; seq++) {
    const auto* c = reinterpret_cast<const fushi_voice_hook::VoiceClip*>(
        cbase + static_cast<size_t>((seq - 1) % cslots) *
                    sizeof(fushi_voice_hook::VoiceClip));
    if (c->seq == seq && c->byte_len != 0 && c->byte_len <= cap) {
      valid.push_back(c);
    }
  }
  if (valid.empty()) {
    return false;
  }
  // 每源：说话前窗口 [ts-900,ts-251] 与文本时刻窗口 [ts-250,ts+450] 的平均能量。
  std::map<uint64_t, double> e_before, e_at;
  std::map<uint64_t, int> n_before, n_at;
  bool any_energy = false;
  for (const auto* c : valid) {
    const double e = ClipEnergy16(h, ring, c);
    if (e < 0) {
      continue;  // 非 16-bit
    }
    any_energy = true;
    const int64_t d = static_cast<int64_t>(c->timestamp_ms) -
                      static_cast<int64_t>(ts);
    if (d >= -900 && d <= -251) {
      e_before[c->source_ptr] += e;
      n_before[c->source_ptr]++;
    }
    if (d >= -250 && d <= 450) {
      e_at[c->source_ptr] += e;
      n_at[c->source_ptr]++;
    }
  }
  // 语音源 = (文本时刻平均能量 - 说话前平均能量) 最大者：从静音跳到有声。
  uint64_t voice_src = 0;
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
      voice_src = kv.first;
    }
  }
  // 拼接语音源在 [下界, ts+6000] 的段；静音判据用该源峰值能量的 8%。下界与 host 的
  // GrabUtterance 共用同一份实现（BUG-1593）：clip 时间戳是**提交**时刻，流式引擎按缓冲
  // 深度提前灌入，固定 200ms 回看会整块丢掉句首。诊断工具必须和真实取音判据一致，否则
  // 拿它排障只会把人带偏。
  std::vector<fushi_voice_hook::UtteranceClipTiming> timings;
  for (const auto* c : valid) {
    if (any_energy && c->source_ptr != voice_src) {
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
      timings.data(), timings.size(), static_cast<int64_t>(ts));

  std::vector<uint8_t> pcm;
  const fushi_voice_hook::VoiceClip* fmt = nullptr;
  double peak = 1.0;
  for (const auto* c : valid) {
    if (any_energy && c->source_ptr != voice_src) {
      continue;
    }
    const int64_t d = static_cast<int64_t>(c->timestamp_ms) -
                      static_cast<int64_t>(ts);
    if (static_cast<int64_t>(c->timestamp_ms) < lower_ts || d > 6000) {
      continue;
    }
    const double e = ClipEnergy16(h, ring, c);
    if (e > peak) {
      peak = e;
    }
    if (ReadClipPcm(h, ring, c, pcm) && fmt == nullptr) {
      fmt = c;
    }
  }
  if (fmt == nullptr || pcm.empty()) {
    return false;
  }
  // 去首尾静音（16-bit）：阈值 = peak*0.08。
  if (fmt->bits_per_sample == 16 && !fmt->is_float) {
    const int16_t thr = static_cast<int16_t>(peak * 0.08);
    const int16_t* s = reinterpret_cast<const int16_t*>(pcm.data());
    const size_t n = pcm.size() / 2;
    size_t lo = 0, hi = n;
    while (lo < n && (s[lo] < 0 ? -s[lo] : s[lo]) < thr) lo++;
    while (hi > lo && (s[hi - 1] < 0 ? -s[hi - 1] : s[hi - 1]) < thr) hi--;
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
  // 写 WAV。
  const uint32_t sr = fmt->sample_rate, ch = fmt->channels,
                 bits = fmt->bits_per_sample;
  const uint32_t ba = ch * (bits / 8), br = sr * ba;
  const uint16_t wfmt = fmt->is_float ? 3 : 1;
  const uint32_t len = static_cast<uint32_t>(pcm.size());
  FILE* f = fopen(path, "wb");
  if (f == nullptr) {
    return false;
  }
  auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
  auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
  fwrite("RIFF", 1, 4, f); w32(36 + len); fwrite("WAVE", 1, 4, f);
  fwrite("fmt ", 1, 4, f); w32(16); w16(wfmt); w16(static_cast<uint16_t>(ch));
  w32(sr); w32(br); w16(static_cast<uint16_t>(ba));
  w16(static_cast<uint16_t>(bits));
  fwrite("data", 1, 4, f); w32(len); fwrite(pcm.data(), 1, len, f);
  fclose(f);
  const double dur = br ? static_cast<double>(len) / br * 1000.0 : 0;
  printf("utterance %s bytes=%u dur=%.0fms src=%08llx peak=%.0f\n", path, len,
         dur, static_cast<unsigned long long>(voice_src & 0xffffffffull), peak);
  return true;
}

// 分源导出：ts 附近每个活跃 source voice 的音频各拼成一个 WAV（<prefix>_<srchex>.wav），并打印
// 每源的统计（段数/时长/平均能量）。用于「手动选轨」——把各条音轨分别落盘让用户听、挑人声轨、
// 排除 BGM 轨。自动能量选源不可靠（会误选 BGM），故提供人工判定入口。
void DumpSources(const SharedHeader* h, const uint8_t* ring, uint64_t ts,
                 const char* prefix) {
  const uint32_t cap = h->ring_capacity;
  const uint64_t clips = h->clip_write_count;
  if (cap == 0 || clips == 0) {
    printf("no clips\n");
    return;
  }
  const uint32_t cslots = fushi_voice_hook::kClipCount;
  const uint8_t* cbase =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t scan = (clips > cslots) ? clips - cslots : 0;
  // 收集 [ts-300, ts+6000] 窗口内各源的 clip 指针。
  std::map<uint64_t, std::vector<const fushi_voice_hook::VoiceClip*>> by_src;
  for (uint64_t seq = scan + 1; seq <= clips; seq++) {
    const auto* c = reinterpret_cast<const fushi_voice_hook::VoiceClip*>(
        cbase + static_cast<size_t>((seq - 1) % cslots) *
                    sizeof(fushi_voice_hook::VoiceClip));
    if (c->seq != seq || c->byte_len == 0 || c->byte_len > cap) {
      continue;
    }
    const int64_t d =
        static_cast<int64_t>(c->timestamp_ms) - static_cast<int64_t>(ts);
    if (d >= -2000 && d <= 8000) {  // 宽窗：多句语音一起导出，人声爆发更易听辨
      by_src[c->source_ptr].push_back(c);
    }
  }
  int idx = 0;
  for (const auto& kv : by_src) {
    std::vector<uint8_t> pcm;
    const fushi_voice_hook::VoiceClip* fmt = nullptr;
    double eacc = 0;
    size_t esamp = 0;
    for (const auto* c : kv.second) {
      if (ReadClipPcm(h, ring, c, pcm) && fmt == nullptr) {
        fmt = c;
      }
    }
    if (fmt == nullptr || pcm.empty()) {
      continue;
    }
    if (fmt->bits_per_sample == 16 && !fmt->is_float) {
      const int16_t* s = reinterpret_cast<const int16_t*>(pcm.data());
      const size_t n = pcm.size() / 2;
      for (size_t i = 0; i < n; i++) {
        eacc += (s[i] < 0) ? -static_cast<double>(s[i]) : s[i];
      }
      esamp = n;
    }
    char path[1024];
    snprintf(path, sizeof(path), "%s_%d_%08llx.wav", prefix, idx,
             static_cast<unsigned long long>(kv.first & 0xffffffffull));
    const uint32_t sr = fmt->sample_rate, ch = fmt->channels,
                   bits = fmt->bits_per_sample;
    const uint32_t ba = ch * (bits / 8), br = sr * ba;
    const uint16_t wfmt = fmt->is_float ? 3 : 1;
    const uint32_t len = static_cast<uint32_t>(pcm.size());
    FILE* f = fopen(path, "wb");
    if (f != nullptr) {
      auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
      auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
      fwrite("RIFF", 1, 4, f); w32(36 + len); fwrite("WAVE", 1, 4, f);
      fwrite("fmt ", 1, 4, f); w32(16); w16(wfmt);
      w16(static_cast<uint16_t>(ch)); w32(sr); w32(br);
      w16(static_cast<uint16_t>(ba)); w16(static_cast<uint16_t>(bits));
      fwrite("data", 1, 4, f); w32(len); fwrite(pcm.data(), 1, len, f);
      fclose(f);
    }
    const double dur = br ? static_cast<double>(len) / br * 1000.0 : 0;
    const double eavg = esamp ? eacc / static_cast<double>(esamp) : -1;
    printf("track%d src=%08llx clips=%zu dur=%.0fms energy=%.0f fmt=%u/%u/%u %s\n",
           idx, static_cast<unsigned long long>(kv.first & 0xffffffffull),
           kv.second.size(), dur, eavg, sr, ch, bits, path);
    idx++;
  }
  fflush(stdout);
}

// ══ C.2f loopback 兜底混音取证 ═══════════════════════════════════════════════════
// 收集 loopback 标记表里有效标记（seq 校验），按序号（=时间/位置单调）排。
void CollectLoopbackMarkers(const SharedHeader* h,
                            std::vector<fushi_voice_hook::LoopbackMarker>* out) {
  out->clear();
  const uint64_t count = h->loopback_marker_count;
  const uint32_t slots = h->loopback_marker_slot_count
                             ? h->loopback_marker_slot_count
                             : fushi_voice_hook::kLoopbackMarkerCount;
  const uint8_t* base =
      reinterpret_cast<const uint8_t*>(h) + h->loopback_marker_offset;
  const uint64_t scan = (count > slots) ? count - slots : 0;
  for (uint64_t seq = scan + 1; seq <= count; seq++) {
    const auto* m = reinterpret_cast<const fushi_voice_hook::LoopbackMarker*>(
        base + static_cast<size_t>((seq - 1) % slots) *
                   sizeof(fushi_voice_hook::LoopbackMarker));
    if (m->seq == seq) {
      out->push_back(*m);
    }
  }
}

// 用标记表把墙钟 tick 映射到 loopback 环线性字节位置 total。标记单调（tick/total 同增）：tick 落
// 两标记间线性插值（自动处理静音间隙的 total 平段）；早于首标记按 byte_rate 反推夹到 [0,首total]；
// 晚于末标记按 byte_rate 外推夹到 cur_total。无标记退化为 cur_total。
uint64_t TickToTotal(const std::vector<fushi_voice_hook::LoopbackMarker>& mk,
                     uint64_t tick, uint64_t byte_rate, uint64_t cur_total) {
  if (mk.empty()) {
    return cur_total;
  }
  const auto& first = mk.front();
  const auto& last = mk.back();
  if (tick <= first.tick_ms) {
    const uint64_t back = (first.tick_ms - tick) * byte_rate / 1000;
    return (back >= first.total_written) ? 0 : (first.total_written - back);
  }
  if (tick >= last.tick_ms) {
    const uint64_t fwd = (tick - last.tick_ms) * byte_rate / 1000;
    const uint64_t t = last.total_written + fwd;
    return (t > cur_total) ? cur_total : t;
  }
  for (size_t i = 1; i < mk.size(); i++) {
    if (tick <= mk[i].tick_ms) {
      const auto& a = mk[i - 1];
      const auto& b = mk[i];
      const uint64_t dt = (b.tick_ms > a.tick_ms) ? (b.tick_ms - a.tick_ms) : 1;
      const uint64_t dtot = (b.total_written > a.total_written)
                                ? (b.total_written - a.total_written)
                                : 0;
      return a.total_written + dtot * (tick - a.tick_ms) / dt;
    }
  }
  return last.total_written;
}

// --dump-loopback：把 [ts_start, ts_end]（GetTickCount64 墙钟 ms，与文本环 timestamp 同源）经标记
// 表映射到 loopback 环字节区间，抽该段 16-bit PCM、去尾静音、写 WAV。成功返回 true。
bool DumpLoopback(const SharedHeader* h, uint64_t ts_start, uint64_t ts_end,
                  const char* path) {
  const uint32_t cap = h->loopback_ring_capacity;
  const uint32_t sr = h->loopback_sample_rate;
  const uint32_t ch = h->loopback_channels;
  if (cap == 0 || sr == 0 || ch == 0) {
    fprintf(stderr,
            "loopback 未就绪：cap=%u sr=%u ch=%u（loopback 线程没起/没抓到？看 lbdiag）\n",
            cap, sr, ch);
    return false;
  }
  const uint8_t* ring =
      reinterpret_cast<const uint8_t*>(h) + h->loopback_ring_offset;
  const uint64_t byte_rate = static_cast<uint64_t>(sr) * ch * 2u;  // 16-bit 存储
  const uint64_t cur_total = h->loopback_total_written;
  std::vector<fushi_voice_hook::LoopbackMarker> mk;
  CollectLoopbackMarkers(h, &mk);
  uint64_t start_total = TickToTotal(mk, ts_start, byte_rate, cur_total);
  uint64_t end_total = TickToTotal(mk, ts_end, byte_rate, cur_total);
  if (end_total <= start_total) {
    fprintf(stderr, "空窗口：start_total=%llu end_total=%llu\n",
            static_cast<unsigned long long>(start_total),
            static_cast<unsigned long long>(end_total));
    return false;
  }
  // 夹到环内仍存活区间 [cur_total-cap, cur_total)。
  const uint64_t floor = (cur_total > cap) ? cur_total - cap : 0;
  if (start_total < floor) {
    start_total = floor;
  }
  if (end_total > cur_total) {
    end_total = cur_total;
  }
  const uint32_t ba = ch * 2u;
  if (end_total <= start_total) {
    fprintf(stderr, "窗口已被环形覆盖或超出：start=%llu end=%llu cur=%llu cap=%u\n",
            static_cast<unsigned long long>(start_total),
            static_cast<unsigned long long>(end_total),
            static_cast<unsigned long long>(cur_total), cap);
    return false;
  }
  uint64_t len64 = end_total - start_total;
  len64 -= (len64 % ba);  // 帧对齐
  if (len64 == 0) {
    return false;
  }
  uint32_t len = (len64 > cap) ? cap : static_cast<uint32_t>(len64);
  std::vector<uint8_t> pcm(len);
  const uint32_t off = static_cast<uint32_t>(start_total % cap);
  const uint32_t first = (len <= cap - off) ? len : (cap - off);
  memcpy(pcm.data(), ring + off, first);
  if (len > first) {
    memcpy(pcm.data() + first, ring, len - first);
  }
  // 去尾静音（16-bit）：阈值取该段峰值的 8%（同 DumpUtterance 口径）。前导保留（起声可能在窗口初）。
  {
    const int16_t* s = reinterpret_cast<const int16_t*>(pcm.data());
    const size_t n = pcm.size() / 2;
    double peak = 1.0;
    for (size_t i = 0; i < n; i++) {
      const double v = (s[i] < 0) ? -static_cast<double>(s[i]) : s[i];
      if (v > peak) {
        peak = v;
      }
    }
    const int16_t thr = static_cast<int16_t>(peak * 0.08);
    size_t hi = n;
    while (hi > 0 && (s[hi - 1] < 0 ? -s[hi - 1] : s[hi - 1]) < thr) {
      hi--;
    }
    hi -= (hi % ch);  // 帧对齐
    if (hi > 0 && hi < n) {
      pcm.resize(hi * 2);
      len = static_cast<uint32_t>(pcm.size());
    }
  }
  const uint32_t br = static_cast<uint32_t>(byte_rate);
  FILE* f = fopen(path, "wb");
  if (f == nullptr) {
    return false;
  }
  auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
  auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
  fwrite("RIFF", 1, 4, f); w32(36 + len); fwrite("WAVE", 1, 4, f);
  fwrite("fmt ", 1, 4, f); w32(16); w16(1); w16(static_cast<uint16_t>(ch));
  w32(sr); w32(br); w16(static_cast<uint16_t>(ba)); w16(16);
  fwrite("data", 1, 4, f); w32(len); fwrite(pcm.data(), 1, len, f);
  fclose(f);
  const double dur = br ? static_cast<double>(len) / br * 1000.0 : 0;
  printf(
      "loopback %s bytes=%u dur=%.0fms sr=%u ch=%u markers=%zu win=[%llu,%llu] "
      "total=[%llu,%llu]\n",
      path, len, dur, sr, ch, mk.size(),
      static_cast<unsigned long long>(ts_start),
      static_cast<unsigned long long>(ts_end),
      static_cast<unsigned long long>(start_total),
      static_cast<unsigned long long>(end_total));
  return true;
}

// 列出最近的语音 clip：seq / 时间戳 / 与上一条间隔 / 源指针低32位 / 环偏移 / 字节 / 时长ms。
// 用来看播放模式（语音是不是连续多段同源、BGM 是不是另一持续源），设计整句合成分组用。
void ListClips(const SharedHeader* h) {
  const uint64_t clips = h->clip_write_count;
  const uint32_t cslots = fushi_voice_hook::kClipCount;
  const uint8_t* cbase =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t scan = (clips > cslots) ? clips - cslots : 0;
  uint64_t prev_ts = 0;
  for (uint64_t seq = scan + 1; seq <= clips; seq++) {
    const auto* c = reinterpret_cast<const fushi_voice_hook::VoiceClip*>(
        cbase + static_cast<size_t>((seq - 1) % cslots) *
                    sizeof(fushi_voice_hook::VoiceClip));
    if (c->seq != seq) {
      continue;
    }
    const uint32_t br = c->sample_rate * c->channels * (c->bits_per_sample / 8);
    const double dur = br ? static_cast<double>(c->byte_len) / br * 1000.0 : 0;
    const long long dts =
        prev_ts ? static_cast<long long>(c->timestamp_ms - prev_ts) : 0;
    printf("clip seq=%llu ts=%llu dts=%lld src=%08llx off=%u len=%u dur=%.0fms flags=0x%08x\n",
           static_cast<unsigned long long>(seq),
           static_cast<unsigned long long>(c->timestamp_ms), dts,
           static_cast<unsigned long long>(c->source_ptr & 0xffffffffull),
           c->ring_offset, c->byte_len, dur, c->pad);
    prev_ts = c->timestamp_ms;
  }
  fflush(stdout);
}

struct RemoteHookModule {
  uintptr_t base = 0;
  uint32_t image_size = 0;
  std::wstring name;
  std::wstring path;
};

struct alignas(8) XAudioTraceHeaderSnapshot {
  uint32_t magic = 0;
  uint32_t version = 0;
  uint32_t event_size = 0;
  uint32_t slot_size = 0;
  uint32_t capacity = 0;
  uint32_t reserved = 0;
  int64_t next_sequence = 0;
  int64_t dropped_busy = 0;
};

struct alignas(8) LeafD3DTraceHeaderSnapshot {
  uint32_t magic = 0;
  uint32_t version = 0;
  uint32_t event_size = 0;
  uint32_t slot_size = 0;
  uint32_t capacity = 0;
  uint32_t reserved = 0;
  int64_t next_sequence = 0;
  int64_t dropped_busy = 0;
  int64_t glyph_calls = 0;
  int64_t glyph_describe_failures = 0;
  int64_t glyph_armed_calls = 0;
  int64_t armed_draw_calls = 0;
  int64_t quad_candidates = 0;
  int64_t primary_quad_candidates = 0;
  int64_t alternate_quad_candidates = 0;
  int64_t caller_rejects = 0;
  int64_t primitive_type_rejects = 0;
  int64_t primitive_count_rejects = 0;
  int64_t vertex_stride_rejects = 0;
  int64_t bounds_rejects = 0;
  uint32_t last_primitive_type = 0;
  uint32_t last_primitive_count = 0;
  uint32_t last_vertex_stride = 0;
  uint32_t last_caller_rva = 0;
  uint32_t input_poller_owner_tid = 0;
  uint32_t input_poller_conflicts = 0;
  uint32_t input_poller_last_conflict_tid = 0;
  uint32_t input_poller_contended = 0;
};

struct alignas(8) HunexGgeTraceHeaderSnapshot {
  uint32_t magic = 0;
  uint32_t version = 0;
  uint32_t event_size = 0;
  uint32_t slot_size = 0;
  uint32_t capacity = 0;
  uint32_t scanner_status = 0;
  int64_t next_sequence = 0;
  int64_t dropped_busy = 0;
  int64_t draw_calls = 0;
  int64_t glyph_calls = 0;
  int64_t input_calls = 0;
  uint32_t module_machine = 0;
  uint32_t draw_match_count = 0;
  uint32_t glyph_match_count = 0;
  uint32_t key_poller_match_count = 0;
  uint32_t input_pump_match_count = 0;
  uint32_t draw_rva = 0;
  uint32_t glyph_rva = 0;
  uint32_t key_poller_rva = 0;
  uint32_t input_pump_rva = 0;
  uint32_t generic_return_rva = 0;
  uint32_t left_button_return_rva = 0;
  uint32_t direct_first_glyph_return_rva = 0;
  uint32_t direct_second_glyph_return_rva = 0;
  uint32_t reserved = 0;
};

static_assert(sizeof(XAudioTraceHeaderSnapshot) ==
                  offsetof(fushi_voice_hook::XAudioTraceBuffer, slots),
              "remote XAudio trace header layout drifted");
static_assert(sizeof(LeafD3DTraceHeaderSnapshot) ==
                  offsetof(fushi_voice_hook::LeafD3DTraceBuffer, slots),
              "remote Leaf D3D trace header layout drifted");
static_assert(sizeof(HunexGgeTraceHeaderSnapshot) ==
                  offsetof(fushi_voice_hook::HunexGgeTraceBuffer, slots),
              "remote HUNEX/GGE trace header layout drifted");

bool ReadRemoteExact(HANDLE process, uintptr_t address, void* destination,
                     size_t length) {
  SIZE_T read = 0;
  return destination != nullptr &&
         ReadProcessMemory(process, reinterpret_cast<const void*>(address),
                           destination, length, &read) &&
         read == length;
}

bool EnumerateRemoteModules(DWORD pid, std::vector<RemoteHookModule>* modules,
                            DWORD* error_code) {
  if (modules == nullptr) return false;
  constexpr int kSnapshotAttempts = 8;
  for (int attempt = 0; attempt < kSnapshotAttempts; ++attempt) {
    HANDLE snapshot = CreateToolhelp32Snapshot(
        TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snapshot == INVALID_HANDLE_VALUE) {
      const DWORD error = GetLastError();
      if (error == ERROR_BAD_LENGTH) continue;
      if (error_code != nullptr) *error_code = error;
      return false;
    }
    std::vector<RemoteHookModule> current;
    MODULEENTRY32W entry = {};
    entry.dwSize = sizeof(entry);
    if (Module32FirstW(snapshot, &entry)) {
      do {
        RemoteHookModule module;
        module.base = reinterpret_cast<uintptr_t>(entry.modBaseAddr);
        module.image_size = entry.modBaseSize;
        module.name = entry.szModule;
        module.path = entry.szExePath;
        current.push_back(std::move(module));
        entry.dwSize = sizeof(entry);
      } while (Module32NextW(snapshot, &entry));
    }
    const DWORD error = GetLastError();
    CloseHandle(snapshot);
    if (error == ERROR_BAD_LENGTH) continue;
    if (current.empty()) {
      if (error_code != nullptr) *error_code = error;
      return false;
    }
    *modules = std::move(current);
    return true;
  }
  if (error_code != nullptr) *error_code = ERROR_BAD_LENGTH;
  return false;
}

bool RemoteModuleAddress(const RemoteHookModule& module, uint64_t rva,
                         size_t length, uintptr_t* address) {
  if (address == nullptr || rva > module.image_size ||
      length > static_cast<uint64_t>(module.image_size) - rva ||
      rva > (std::numeric_limits<uintptr_t>::max)() - module.base) {
    return false;
  }
  *address = module.base + static_cast<uintptr_t>(rva);
  return true;
}

template <typename T>
bool ReadRemotePePod(HANDLE process, const RemoteHookModule& module,
                     uint64_t rva, T* value) {
  uintptr_t address = 0;
  return value != nullptr &&
         RemoteModuleAddress(module, rva, sizeof(T), &address) &&
         ReadRemoteExact(process, address, value, sizeof(T));
}

bool RemotePeStringEquals(HANDLE process, const RemoteHookModule& module,
                          uint32_t rva, const char* expected) {
  if (expected == nullptr) return false;
  const size_t length = std::strlen(expected);
  if (length > 512) return false;
  for (size_t i = 0; i <= length; ++i) {
    uint8_t value = 0;
    if (!ReadRemotePePod(process, module,
                         static_cast<uint64_t>(rva) + i, &value) ||
        value != static_cast<uint8_t>(expected[i])) {
      return false;
    }
  }
  return true;
}

bool ResolveRemotePeExportRva(HANDLE process,
                              const RemoteHookModule& module,
                              const char* export_name,
                              uint32_t* resolved_rva) {
  if (resolved_rva == nullptr) return false;
  IMAGE_DOS_HEADER dos = {};
  if (!ReadRemotePePod(process, module, 0, &dos) ||
      dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0) {
    return false;
  }
  const uint64_t nt_rva = static_cast<uint64_t>(dos.e_lfanew);
  DWORD signature = 0;
  IMAGE_FILE_HEADER file_header = {};
  if (!ReadRemotePePod(process, module, nt_rva, &signature) ||
      signature != IMAGE_NT_SIGNATURE ||
      !ReadRemotePePod(process, module, nt_rva + sizeof(signature),
                       &file_header)) {
    return false;
  }
  const uint64_t optional_rva =
      nt_rva + sizeof(signature) + sizeof(file_header);
  WORD optional_magic = 0;
  if (!ReadRemotePePod(process, module, optional_rva, &optional_magic)) {
    return false;
  }
  IMAGE_DATA_DIRECTORY export_directory = {};
  uint32_t size_of_image = 0;
  if (optional_magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
    if (file_header.SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER32)) {
      return false;
    }
    IMAGE_OPTIONAL_HEADER32 optional = {};
    if (!ReadRemotePePod(process, module, optional_rva, &optional) ||
        optional.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_EXPORT) {
      return false;
    }
    size_of_image = optional.SizeOfImage;
    export_directory = optional.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
  } else if (optional_magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
    if (file_header.SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER64)) {
      return false;
    }
    IMAGE_OPTIONAL_HEADER64 optional = {};
    if (!ReadRemotePePod(process, module, optional_rva, &optional) ||
        optional.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_EXPORT) {
      return false;
    }
    size_of_image = optional.SizeOfImage;
    export_directory = optional.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
  } else {
    return false;
  }
  const uint64_t export_end =
      static_cast<uint64_t>(export_directory.VirtualAddress) +
      export_directory.Size;
  if (size_of_image == 0 || size_of_image > module.image_size ||
      export_directory.VirtualAddress == 0 ||
      export_directory.Size < sizeof(IMAGE_EXPORT_DIRECTORY) ||
      export_end > size_of_image) {
    return false;
  }
  IMAGE_EXPORT_DIRECTORY exports = {};
  if (!ReadRemotePePod(process, module, export_directory.VirtualAddress,
                       &exports) ||
      exports.NumberOfNames > size_of_image / sizeof(DWORD) ||
      exports.NumberOfFunctions > size_of_image / sizeof(DWORD)) {
    return false;
  }
  for (uint32_t i = 0; i < exports.NumberOfNames; ++i) {
    DWORD name_rva = 0;
    if (!ReadRemotePePod(
            process, module,
            static_cast<uint64_t>(exports.AddressOfNames) +
                static_cast<uint64_t>(i) * sizeof(DWORD),
            &name_rva)) {
      return false;
    }
    if (!RemotePeStringEquals(process, module, name_rva, export_name)) {
      continue;
    }
    WORD ordinal = 0;
    if (!ReadRemotePePod(
            process, module,
            static_cast<uint64_t>(exports.AddressOfNameOrdinals) +
                static_cast<uint64_t>(i) * sizeof(WORD),
            &ordinal) ||
        ordinal >= exports.NumberOfFunctions) {
      return false;
    }
    DWORD value_rva = 0;
    if (!ReadRemotePePod(
            process, module,
            static_cast<uint64_t>(exports.AddressOfFunctions) +
                static_cast<uint64_t>(ordinal) * sizeof(DWORD),
            &value_rva) ||
        value_rva >= size_of_image ||
        (value_rva >= export_directory.VirtualAddress &&
         static_cast<uint64_t>(value_rva) < export_end)) {
      return false;
    }
    *resolved_rva = value_rva;
    return true;
  }
  return false;
}

bool IsExpectedHookModuleName(const std::wstring& name) {
  return _wcsicmp(name.c_str(), L"fushi_voice_hook.dll") == 0 ||
         _wcsicmp(name.c_str(), L"hibiki_voice_hook.dll") == 0;
}

bool FindRemoteXAudioTrace(HANDLE process, DWORD pid,
                           RemoteHookModule* found_module,
                           uint32_t* found_rva,
                           XAudioTraceHeaderSnapshot* found_header,
                           DWORD* error_code) {
  if (found_module == nullptr || found_rva == nullptr ||
      found_header == nullptr) {
    return false;
  }
  std::vector<RemoteHookModule> modules;
  if (!EnumerateRemoteModules(pid, &modules, error_code)) return false;
  // Prefer the production basename, but inspect every loaded module by its
  // remote export table so injector --dll renames and replaced-on-disk DLLs do
  // not make the live evidence invisible or select a stale RVA.
  std::stable_sort(modules.begin(), modules.end(),
                   [](const RemoteHookModule& left,
                      const RemoteHookModule& right) {
                     return IsExpectedHookModuleName(left.name) &&
                            !IsExpectedHookModuleName(right.name);
                   });
  for (const RemoteHookModule& module : modules) {
    uint32_t export_rva = 0;
    if (!ResolveRemotePeExportRva(
            process, module, fushi_voice_hook::kXAudioTraceExportName,
            &export_rva)) {
      continue;
    }
    uintptr_t address = 0;
    XAudioTraceHeaderSnapshot header;
    if (!RemoteModuleAddress(module, export_rva, sizeof(header), &address) ||
        !ReadRemoteExact(process, address, &header, sizeof(header)) ||
        header.magic != fushi_voice_hook::kXAudioTraceMagic ||
        header.version != fushi_voice_hook::kXAudioTraceVersion) {
      continue;
    }
    *found_module = module;
    *found_rva = export_rva;
    *found_header = header;
    return true;
  }
  if (error_code != nullptr) *error_code = ERROR_MOD_NOT_FOUND;
  return false;
}

bool FindRemoteLeafD3DTrace(HANDLE process, DWORD pid,
                            RemoteHookModule* found_module,
                            uint32_t* found_rva,
                            LeafD3DTraceHeaderSnapshot* found_header,
                            DWORD* error_code) {
  if (found_module == nullptr || found_rva == nullptr ||
      found_header == nullptr) {
    return false;
  }
  std::vector<RemoteHookModule> modules;
  if (!EnumerateRemoteModules(pid, &modules, error_code)) return false;
  std::stable_sort(modules.begin(), modules.end(),
                   [](const RemoteHookModule& left,
                      const RemoteHookModule& right) {
                     return IsExpectedHookModuleName(left.name) &&
                            !IsExpectedHookModuleName(right.name);
                   });
  for (const RemoteHookModule& module : modules) {
    uint32_t export_rva = 0;
    if (!ResolveRemotePeExportRva(
            process, module, fushi_voice_hook::kLeafD3DTraceExportName,
            &export_rva)) {
      continue;
    }
    uintptr_t address = 0;
    LeafD3DTraceHeaderSnapshot header;
    if (!RemoteModuleAddress(module, export_rva, sizeof(header), &address) ||
        !ReadRemoteExact(process, address, &header, sizeof(header)) ||
        header.magic != fushi_voice_hook::kLeafD3DTraceMagic ||
        header.version != fushi_voice_hook::kLeafD3DTraceVersion) {
      continue;
    }
    *found_module = module;
    *found_rva = export_rva;
    *found_header = header;
    return true;
  }
  if (error_code != nullptr) *error_code = ERROR_MOD_NOT_FOUND;
  return false;
}

bool FindRemoteHunexGgeTrace(HANDLE process, DWORD pid,
                             RemoteHookModule* found_module,
                             uint32_t* found_rva,
                             HunexGgeTraceHeaderSnapshot* found_header,
                             DWORD* error_code) {
  if (found_module == nullptr || found_rva == nullptr ||
      found_header == nullptr) {
    return false;
  }
  std::vector<RemoteHookModule> modules;
  if (!EnumerateRemoteModules(pid, &modules, error_code)) return false;
  std::stable_sort(modules.begin(), modules.end(),
                   [](const RemoteHookModule& left,
                      const RemoteHookModule& right) {
                     return IsExpectedHookModuleName(left.name) &&
                            !IsExpectedHookModuleName(right.name);
                   });

  uint32_t valid_candidates = 0;
  RemoteHookModule candidate_module;
  uint32_t candidate_rva = 0;
  HunexGgeTraceHeaderSnapshot candidate_header;
  for (const RemoteHookModule& module : modules) {
    uint32_t export_rva = 0;
    if (!ResolveRemotePeExportRva(
            process, module, fushi_voice_hook::kHunexGgeTraceExportName,
            &export_rva)) {
      continue;
    }
    uintptr_t address = 0;
    HunexGgeTraceHeaderSnapshot header;
    if (!RemoteModuleAddress(module, export_rva, sizeof(header), &address) ||
        !ReadRemoteExact(process, address, &header, sizeof(header)) ||
        header.magic != fushi_voice_hook::kHunexGgeTraceMagic ||
        header.version != fushi_voice_hook::kHunexGgeTraceVersion) {
      continue;
    }
    ++valid_candidates;
    if (valid_candidates == 1u) {
      candidate_module = module;
      candidate_rva = export_rva;
      candidate_header = header;
    }
  }
  if (valid_candidates != 1u) {
    if (error_code != nullptr) {
      *error_code = valid_candidates == 0u ? ERROR_MOD_NOT_FOUND
                                           : ERROR_DUP_NAME;
    }
    return false;
  }
  *found_module = candidate_module;
  *found_rva = candidate_rva;
  *found_header = candidate_header;
  return true;
}

const char* HunexGgeTraceKindName(uint32_t kind) {
  using Kind = fushi_voice_hook::HunexGgeTraceKind;
  switch (static_cast<Kind>(kind)) {
    case Kind::kDraw: return "draw";
    case Kind::kGlyphDirectFirst: return "glyph_direct_first";
    case Kind::kGlyphDirectSecond: return "glyph_direct_second";
    case Kind::kInputGeneric: return "input_generic";
    case Kind::kInputLeftButton: return "input_left_button";
  }
  return "unknown";
}

void PrintHunexGgeScannerStatus(uint32_t status) {
  constexpr uint32_t kKnownStatus =
      fushi_voice_hook::kHunexGgeTraceScannerProfileMatched |
      fushi_voice_hook::kHunexGgeTraceScannerPe64 |
      fushi_voice_hook::kHunexGgeTraceScannerDrawUnique |
      fushi_voice_hook::kHunexGgeTraceScannerGlyphUnique |
      fushi_voice_hook::kHunexGgeTraceScannerInputUnique |
      fushi_voice_hook::kHunexGgeTraceScannerDrawCallsValid |
      fushi_voice_hook::kHunexGgeTraceScannerInputCallsValid |
      fushi_voice_hook::kHunexGgeTraceScannerHooksReady;
  bool emitted = false;
  printf(" scanner=0x%08x{", status);
  const auto emit = [&emitted](const char* name) {
    printf("%s%s", emitted ? "," : "", name);
    emitted = true;
  };
  if ((status & fushi_voice_hook::kHunexGgeTraceScannerProfileMatched) != 0)
    emit("profile_matched");
  if ((status & fushi_voice_hook::kHunexGgeTraceScannerPe64) != 0)
    emit("pe64");
  if ((status & fushi_voice_hook::kHunexGgeTraceScannerDrawUnique) != 0)
    emit("draw_unique");
  if ((status & fushi_voice_hook::kHunexGgeTraceScannerGlyphUnique) != 0)
    emit("glyph_unique");
  if ((status & fushi_voice_hook::kHunexGgeTraceScannerInputUnique) != 0)
    emit("input_unique");
  if ((status & fushi_voice_hook::kHunexGgeTraceScannerDrawCallsValid) != 0)
    emit("draw_calls_valid");
  if ((status & fushi_voice_hook::kHunexGgeTraceScannerInputCallsValid) != 0)
    emit("input_calls_valid");
  if ((status & fushi_voice_hook::kHunexGgeTraceScannerHooksReady) != 0)
    emit("hooks_ready");
  const uint32_t unknown = status & ~kKnownStatus;
  if (unknown != 0) {
    printf("%sunknown=0x%08x", emitted ? "," : "", unknown);
    emitted = true;
  }
  if (!emitted) printf("none");
  printf("}");
}

template <size_t N>
void PrintHunexGgeTraceWords(const char* label,
                             const uint32_t (&words)[N]) {
  printf(" %s={", label);
  for (size_t index = 0; index < N; ++index) {
    printf("%s%zu:%08x", index == 0 ? "" : ",", index, words[index]);
  }
  printf("}");
}

void PrintHunexGgeTraceEvent(
    const fushi_voice_hook::HunexGgeTraceEvent& event) {
  printf(
      "hunex_gge seq=%llu ts=%llu draw=%llu kind=%s tid=%u caller=%08x "
      "text_hash=%016llx units=%u/%u glyph_ordinal=%u utf16_index=%u "
      "scalar_width=%u arg7=%u draw={x:%d,y:%d,width:%d,arg12_bits:%016llx,"
      "arg13:%u} result=%d(raw=0x%08x)",
      static_cast<unsigned long long>(event.sequence),
      static_cast<unsigned long long>(event.timestamp_ms),
      static_cast<unsigned long long>(event.draw_sequence),
      HunexGgeTraceKindName(event.kind), event.thread_id, event.caller_rva,
      static_cast<unsigned long long>(event.text_hash), event.text_units,
      event.visible_units, event.glyph_ordinal, event.utf16_char_index,
      event.scalar_width, event.arg7, event.draw_x, event.draw_y,
      event.draw_width,
      static_cast<unsigned long long>(event.draw_arg12_bits), event.draw_arg13,
      event.result,
      static_cast<uint32_t>(event.result));
  using Kind = fushi_voice_hook::HunexGgeTraceKind;
  const Kind kind = static_cast<Kind>(event.kind);
  if (kind == Kind::kInputGeneric || kind == Kind::kInputLeftButton) {
    constexpr uint16_t kAsyncKeyStateDownMask = 0x8000u;
    constexpr uint16_t kAsyncKeyStatePressedMask = 0x0001u;
    const uint16_t raw = static_cast<uint16_t>(event.result);
    printf(" key_state={down:%u,pressed_since_read:%u}",
           (raw & kAsyncKeyStateDownMask) != 0 ? 1u : 0u,
           (raw & kAsyncKeyStatePressedMask) != 0 ? 1u : 0u);
  }
  PrintHunexGgeTraceWords("descriptor", event.descriptor_words);
  PrintHunexGgeTraceWords("output", event.output_words);
  printf("\n");
}

const char* XAudioTraceKindName(uint32_t kind) {
  using Kind = fushi_voice_hook::XAudioTraceEventKind;
  switch (static_cast<Kind>(kind)) {
    case Kind::kCreate: return "create";
    case Kind::kSubmit: return "submit";
    case Kind::kStart: return "start";
    case Kind::kStop: return "stop";
    case Kind::kFlush: return "flush";
    case Kind::kDestroy: return "destroy";
    case Kind::kCommit: return "commit";
    case Kind::kWorkerWait: return "worker_wait";
    case Kind::kWorkerPublish: return "worker_publish";
    case Kind::kWorkerInvalidate: return "worker_invalidate";
  }
  return "unknown";
}

const char* XAudioTraceOutcomeName(uint32_t outcome) {
  using Outcome = fushi_voice_hook::XAudioTraceOutcome;
  switch (static_cast<Outcome>(outcome)) {
    case Outcome::kNone: return "none";
    case Outcome::kSucceeded: return "succeeded";
    case Outcome::kOriginalFailed: return "original_failed";
    case Outcome::kFormatUnsupported: return "format_unsupported";
    case Outcome::kRegistryRegistered: return "registry_registered";
    case Outcome::kRegistryExhausted: return "registry_exhausted";
    case Outcome::kLookupMiss: return "lookup_miss";
    case Outcome::kQueued: return "queued";
    case Outcome::kRejectedNullBuffer: return "reject_null_buffer";
    case Outcome::kRejectedNullAudioData: return "reject_null_audio_data";
    case Outcome::kRejectedZeroBytes: return "reject_zero_bytes";
    case Outcome::kRejectedTooLarge: return "reject_too_large";
    case Outcome::kRejectedQueueNotReady: return "reject_queue_not_ready";
    case Outcome::kRejectedDescriptorExhausted:
      return "reject_descriptor_exhausted";
    case Outcome::kRejectedArenaExhausted:
      return "reject_arena_exhausted";
    case Outcome::kRejectedCopyFailed: return "reject_copy_failed";
    case Outcome::kCaptureDisabled: return "capture_disabled";
    case Outcome::kImmediateApplied: return "immediate_applied";
    case Outcome::kDeferredStaged: return "deferred_staged";
    case Outcome::kDeferredStageFailed: return "deferred_stage_failed";
    case Outcome::kDeferredApplied: return "deferred_applied";
    case Outcome::kDeferredInvalidated: return "deferred_invalidated";
    case Outcome::kQueueGenerationAdvanced:
      return "queue_generation_advanced";
    case Outcome::kWaitingForStart: return "waiting_for_start";
    case Outcome::kPublished: return "published";
    case Outcome::kStaleInvalidated: return "stale_invalidated";
    case Outcome::kDecodeRejected: return "decode_rejected";
    case Outcome::kCommitQueued: return "commit_queued";
    case Outcome::kCommitApplied: return "commit_applied";
    case Outcome::kCommitQueueExhausted: return "commit_queue_exhausted";
  }
  return "unknown";
}

const char* XAudioTraceLookupName(uint32_t lookup) {
  using Lookup = fushi_voice_hook::XAudioTraceLookupResult;
  switch (static_cast<Lookup>(lookup)) {
    case Lookup::kNotAttempted: return "not_attempted";
    case Lookup::kRegistered: return "registered";
    case Lookup::kMissing: return "missing";
  }
  return "unknown";
}

void PrintXAudioTraceFormat(const fushi_voice_hook::XAudioTraceFormat& format) {
  if (format.present == 0) return;
  printf(
      " fmt={parse=%u enc=%u tag=0x%04x ch=%u rate=%u avg=%u align=%u "
      "bits=%u cb=%u}",
      format.parse_succeeded, format.normalized_encoding, format.format_tag,
      format.channels, format.samples_per_sec, format.avg_bytes_per_sec,
      format.block_align, format.bits_per_sample, format.cb_size);
  if (format.format_tag == WAVE_FORMAT_EXTENSIBLE) {
    printf(
        " ext={valid=%u mask=0x%08x guid=%08x-%04x-%04x-"
        "%02x%02x-%02x%02x%02x%02x%02x%02x}",
        format.extensible_valid_bits, format.extensible_channel_mask,
        format.subformat_data1, format.subformat_data2,
        format.subformat_data3, format.subformat_data4[0],
        format.subformat_data4[1], format.subformat_data4[2],
        format.subformat_data4[3], format.subformat_data4[4],
        format.subformat_data4[5], format.subformat_data4[6],
        format.subformat_data4[7]);
  }
  if (format.extra_bytes_copied != 0) {
    printf(" extra=");
    const uint32_t copied = (std::min)(
        format.extra_bytes_copied,
        fushi_voice_hook::kXAudioTraceExtraPrefixBytes);
    for (uint32_t i = 0; i < copied; ++i) {
      printf("%02x", format.extra_prefix[i]);
    }
  }
  if (format.adpcm_samples_per_block != 0 ||
      format.adpcm_coefficient_count != 0) {
    printf(" adpcm={spb=%u count=%u copied=%u coeff=",
           format.adpcm_samples_per_block, format.adpcm_coefficient_count,
           format.adpcm_coefficients_copied);
    const uint32_t copied = (std::min)(
        format.adpcm_coefficients_copied,
        fushi_voice_hook::kXAudioTraceAdpcmCoefficientCount);
    for (uint32_t i = 0; i < copied; ++i) {
      printf("%s%d:%d", i == 0 ? "[" : ",",
             format.adpcm_coefficients[i][0],
             format.adpcm_coefficients[i][1]);
    }
    printf("%s}", copied == 0 ? "[]" : "]");
  }
}

void PrintXAudioTraceEvent(const fushi_voice_hook::XAudioTraceEvent& event) {
  printf(
      "seq=%llu ts=%llu tid=%llu kind=%s outcome=%s hr=0x%08x "
      "src=0x%llx engine=0x%llx gen=%llu qgen=%llu",
      static_cast<unsigned long long>(event.sequence),
      static_cast<unsigned long long>(event.timestamp_ms),
      static_cast<unsigned long long>(event.thread_id),
      XAudioTraceKindName(event.kind), XAudioTraceOutcomeName(event.outcome),
      static_cast<uint32_t>(event.hresult),
      static_cast<unsigned long long>(event.source),
      static_cast<unsigned long long>(event.engine),
      static_cast<unsigned long long>(event.source_generation),
      static_cast<unsigned long long>(event.queue_generation));
  using Kind = fushi_voice_hook::XAudioTraceEventKind;
  const Kind kind = static_cast<Kind>(event.kind);
  if (kind == Kind::kSubmit) {
    printf(
        " bytes=%u play=%u+%u flags=0x%08x ctx=%u wma=%u packets=%u "
        "wma_range=%u wma_first_decoded_bytes=%u "
        "wma_last_decoded_bytes=%u "
        "lookup=%s reject=%s stale=%u submit_ts=%llu",
        event.audio_bytes, event.play_begin, event.play_length,
        event.buffer_flags, event.buffer_context_present, event.wma_present,
        event.wma_packet_count, event.wma_decoded_range_present,
        event.wma_first_decoded_bytes, event.wma_last_decoded_bytes,
        XAudioTraceLookupName(event.detail0),
        XAudioTraceOutcomeName(event.detail1), event.detail2,
        static_cast<unsigned long long>(event.submit_timestamp_ms));
  } else if (kind == Kind::kStart || kind == Kind::kStop ||
             kind == Kind::kFlush || kind == Kind::kDestroy) {
    printf(" opset=%u flags=0x%08x lookup=%s", event.operation_set,
           event.buffer_flags, XAudioTraceLookupName(event.detail0));
  } else if (kind == Kind::kCommit) {
    if (event.detail0 == static_cast<uint32_t>(
                             fushi_voice_hook::XAudioTraceCommitPhase::kObserved)) {
      const uint64_t fence = static_cast<uint64_t>(event.detail1) |
                             (static_cast<uint64_t>(event.detail2) << 32);
      printf(" opset=%u phase=observed fence=%llu", event.operation_set,
             static_cast<unsigned long long>(fence));
    } else {
      printf(" opset=%u phase=applied matched=%u applied=%u",
             event.operation_set, event.detail1, event.detail2);
    }
  } else if (kind == Kind::kWorkerWait || kind == Kind::kWorkerPublish ||
             kind == Kind::kWorkerInvalidate) {
    printf(" bytes=%u play=%u+%u submit_ts=%llu detail0=%u detail1=%u",
           event.audio_bytes, event.play_begin, event.play_length,
           static_cast<unsigned long long>(event.submit_timestamp_ms),
           event.detail0, event.detail1);
  }
  PrintXAudioTraceFormat(event.format);
  printf("\n");
}

bool DumpXAudioTrace(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
                                   PROCESS_VM_READ,
                               FALSE, pid);
  if (process == nullptr) {
    fprintf(stderr, "OpenProcess(pid=%lu) 失败：%lu\n", pid, GetLastError());
    return false;
  }
  RemoteHookModule module;
  uint32_t export_rva = 0;
  XAudioTraceHeaderSnapshot header;
  DWORD module_error = ERROR_SUCCESS;
  if (!FindRemoteXAudioTrace(process, pid, &module, &export_rva, &header,
                             &module_error)) {
    fprintf(stderr,
            "找不到 pid=%lu 中带 %s 数据导出的 live hook DLL：%lu\n",
            pid, fushi_voice_hook::kXAudioTraceExportName, module_error);
    CloseHandle(process);
    return false;
  }
  if (export_rva > module.image_size ||
      sizeof(fushi_voice_hook::XAudioTraceBuffer) >
          static_cast<size_t>(module.image_size - export_rva) ||
      module.base > (std::numeric_limits<uintptr_t>::max)() - export_rva) {
    fprintf(stderr, "XAudio trace 导出 RVA 越过远程模块边界\n");
    CloseHandle(process);
    return false;
  }
  const uintptr_t trace_address = module.base + export_rva;
  if (header.magic != fushi_voice_hook::kXAudioTraceMagic ||
      header.version != fushi_voice_hook::kXAudioTraceVersion ||
      header.event_size != sizeof(fushi_voice_hook::XAudioTraceEvent) ||
      header.slot_size != sizeof(fushi_voice_hook::XAudioTraceSlot) ||
      header.capacity != fushi_voice_hook::kXAudioTraceCapacity ||
      header.next_sequence < 0 || header.dropped_busy < 0) {
    fprintf(stderr,
            "XAudio trace ABI 不匹配：magic=0x%08x version=%u event=%u "
            "slot=%u capacity=%u\n",
            header.magic, header.version, header.event_size, header.slot_size,
            header.capacity);
    CloseHandle(process);
    return false;
  }
  printf(
      "xaudio_trace pid=%lu module=%ls base=0x%llx export_rva=0x%08x "
      "next=%llu dropped_busy=%llu capacity=%u\n",
      pid, module.path.c_str(), static_cast<unsigned long long>(module.base),
      export_rva, static_cast<unsigned long long>(header.next_sequence),
      static_cast<unsigned long long>(header.dropped_busy), header.capacity);

  const uint64_t next = static_cast<uint64_t>(header.next_sequence);
  const uint64_t first =
      next > header.capacity ? next - header.capacity + 1u : 1u;
  uint32_t accepted = 0;
  uint32_t unstable = 0;
  for (uint64_t expected = first; expected <= next; ++expected) {
    const uint64_t index = (expected - 1u) % header.capacity;
    const uint64_t slot_offset =
        offsetof(fushi_voice_hook::XAudioTraceBuffer, slots) +
        index * sizeof(fushi_voice_hook::XAudioTraceSlot);
    if (slot_offset > (std::numeric_limits<uintptr_t>::max)() - trace_address) {
      ++unstable;
      continue;
    }
    const uintptr_t slot_address =
        trace_address + static_cast<uintptr_t>(slot_offset);
    const uintptr_t sequence_address =
        slot_address + offsetof(fushi_voice_hook::XAudioTraceSlot, event) +
        offsetof(fushi_voice_hook::XAudioTraceEvent, sequence);
    LONG writing_before = 0;
    LONG writing_after = 0;
    uint64_t sequence_before = 0;
    uint64_t sequence_after = 0;
    fushi_voice_hook::XAudioTraceSlot slot;
    // Cross-process seqlock read: publication sequence, entire numeric slot,
    // then publication sequence again.  The try-claim flag closes the small
    // window before a wrapping writer invalidates the old sequence.
    const bool stable =
        ReadRemoteExact(process, sequence_address, &sequence_before,
                        sizeof(sequence_before)) &&
        ReadRemoteExact(process, slot_address, &writing_before,
                        sizeof(writing_before)) &&
        ReadRemoteExact(process, slot_address, &slot, sizeof(slot)) &&
        ReadRemoteExact(process, sequence_address, &sequence_after,
                        sizeof(sequence_after)) &&
        ReadRemoteExact(process, slot_address, &writing_after,
                        sizeof(writing_after)) &&
        writing_before == 0 && slot.writing == 0 && writing_after == 0 &&
        sequence_before == expected && slot.event.sequence == expected &&
        sequence_after == expected;
    if (!stable) {
      ++unstable;
      continue;
    }
    ++accepted;
    PrintXAudioTraceEvent(slot.event);
  }
  printf("xaudio_trace_summary accepted=%u gaps_or_unstable=%u\n", accepted,
         unstable);
  CloseHandle(process);
  return true;
}

bool DumpLeafD3DTrace(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
                                   PROCESS_VM_READ,
                               FALSE, pid);
  if (process == nullptr) {
    fprintf(stderr, "OpenProcess(pid=%lu) failed: %lu\n", pid,
            GetLastError());
    return false;
  }
  RemoteHookModule module;
  uint32_t export_rva = 0;
  LeafD3DTraceHeaderSnapshot header;
  DWORD module_error = ERROR_SUCCESS;
  if (!FindRemoteLeafD3DTrace(process, pid, &module, &export_rva, &header,
                              &module_error)) {
    fprintf(stderr, "live hook DLL export %s not found for pid=%lu: %lu\n",
            fushi_voice_hook::kLeafD3DTraceExportName, pid, module_error);
    CloseHandle(process);
    return false;
  }
  if (export_rva > module.image_size ||
      sizeof(fushi_voice_hook::LeafD3DTraceBuffer) >
          static_cast<size_t>(module.image_size - export_rva) ||
      module.base > (std::numeric_limits<uintptr_t>::max)() - export_rva) {
    fprintf(stderr, "Leaf D3D trace export exceeds remote module bounds\n");
    CloseHandle(process);
    return false;
  }
  if (header.event_size != sizeof(fushi_voice_hook::LeafD3DTraceEvent) ||
      header.slot_size != sizeof(fushi_voice_hook::LeafD3DTraceSlot) ||
      header.capacity != fushi_voice_hook::kLeafD3DTraceCapacity ||
      header.next_sequence < 0 || header.dropped_busy < 0) {
    fprintf(stderr,
            "Leaf D3D trace ABI mismatch: magic=0x%08x version=%u event=%u "
            "slot=%u capacity=%u\n",
            header.magic, header.version, header.event_size, header.slot_size,
            header.capacity);
    CloseHandle(process);
    return false;
  }
  const uintptr_t trace_address = module.base + export_rva;
  printf(
      "leaf_d3d_trace pid=%lu module=%ls base=0x%llx export_rva=0x%08x "
      "next=%llu dropped_busy=%llu capacity=%u flags=0x%08x "
      "glyph_calls=%llu describe_fail=%llu armed=%llu draws=%llu "
      "candidates=%llu primary=%llu alternate=%llu caller_rejects=%llu "
      "type_rejects=%llu "
      "count_rejects=%llu stride_rejects=%llu bounds_rejects=%llu "
      "last=pt:%u,pc:%u,stride:%u,caller:%08x "
      "poller=owner:%u,conflicts:%u,last_conflict:%u,contended:%u\n",
      pid, module.path.c_str(), static_cast<unsigned long long>(module.base),
      export_rva, static_cast<unsigned long long>(header.next_sequence),
      static_cast<unsigned long long>(header.dropped_busy), header.capacity,
      header.reserved,
      static_cast<unsigned long long>(header.glyph_calls),
      static_cast<unsigned long long>(header.glyph_describe_failures),
      static_cast<unsigned long long>(header.glyph_armed_calls),
      static_cast<unsigned long long>(header.armed_draw_calls),
      static_cast<unsigned long long>(header.quad_candidates),
      static_cast<unsigned long long>(header.primary_quad_candidates),
      static_cast<unsigned long long>(header.alternate_quad_candidates),
      static_cast<unsigned long long>(header.caller_rejects),
      static_cast<unsigned long long>(header.primitive_type_rejects),
      static_cast<unsigned long long>(header.primitive_count_rejects),
      static_cast<unsigned long long>(header.vertex_stride_rejects),
      static_cast<unsigned long long>(header.bounds_rejects),
      header.last_primitive_type, header.last_primitive_count,
      header.last_vertex_stride, header.last_caller_rva,
      header.input_poller_owner_tid, header.input_poller_conflicts,
      header.input_poller_last_conflict_tid, header.input_poller_contended);

  const uint64_t next = static_cast<uint64_t>(header.next_sequence);
  const uint64_t first =
      next > header.capacity ? next - header.capacity + 1u : 1u;
  uint32_t accepted = 0;
  uint32_t unstable = 0;
  for (uint64_t expected = first; expected <= next; ++expected) {
    const uint64_t index = (expected - 1u) % header.capacity;
    const uint64_t slot_offset =
        offsetof(fushi_voice_hook::LeafD3DTraceBuffer, slots) +
        index * sizeof(fushi_voice_hook::LeafD3DTraceSlot);
    if (slot_offset > (std::numeric_limits<uintptr_t>::max)() - trace_address) {
      ++unstable;
      continue;
    }
    const uintptr_t slot_address =
        trace_address + static_cast<uintptr_t>(slot_offset);
    const uintptr_t sequence_address =
        slot_address + offsetof(fushi_voice_hook::LeafD3DTraceSlot, event) +
        offsetof(fushi_voice_hook::LeafD3DTraceEvent, sequence);
    LONG writing_before = 0;
    LONG writing_after = 0;
    uint64_t sequence_before = 0;
    uint64_t sequence_after = 0;
    fushi_voice_hook::LeafD3DTraceSlot slot;
    const bool stable =
        ReadRemoteExact(process, sequence_address, &sequence_before,
                        sizeof(sequence_before)) &&
        ReadRemoteExact(process, slot_address, &writing_before,
                        sizeof(writing_before)) &&
        ReadRemoteExact(process, slot_address, &slot, sizeof(slot)) &&
        ReadRemoteExact(process, sequence_address, &sequence_after,
                        sizeof(sequence_after)) &&
        ReadRemoteExact(process, slot_address, &writing_after,
                        sizeof(writing_after)) &&
        writing_before == 0 && slot.writing == 0 && writing_after == 0 &&
        sequence_before == expected && slot.event.sequence == expected &&
        sequence_after == expected;
    if (!stable) {
      ++unstable;
      continue;
    }
    ++accepted;
    const auto& event = slot.event;
    printf(
        "leaf_d3d seq=%llu ts=%llu frame=%llu traversal=%llu "
        "glyph=%u/%u call=%08x texture=%08llx "
        "pt=%u pc=%u stride=%u fvf=%08x vertices=%u "
        "rect=%.2f,%.2f,%.2f,%.2f\n",
        static_cast<unsigned long long>(event.sequence),
        static_cast<unsigned long long>(event.timestamp_ms),
        static_cast<unsigned long long>(event.frame_sequence),
        static_cast<unsigned long long>(event.traversal_id),
        event.glyph_index, event.glyph_count, event.caller_rva,
        static_cast<unsigned long long>(event.texture0 & 0xffffffffull),
        event.primitive_type, event.primitive_count, event.vertex_stride,
        event.fvf, event.vertex_count, event.left, event.top, event.right,
        event.bottom);
  }
  printf("leaf_d3d_trace_summary accepted=%u gaps_or_unstable=%u\n", accepted,
         unstable);
  CloseHandle(process);
  return true;
}

bool DumpHunexGgeTrace(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
                                   PROCESS_VM_READ,
                               FALSE, pid);
  if (process == nullptr) {
    fprintf(stderr, "OpenProcess(pid=%lu) failed: %lu\n", pid,
            GetLastError());
    return false;
  }
  RemoteHookModule module;
  uint32_t export_rva = 0;
  HunexGgeTraceHeaderSnapshot header;
  DWORD module_error = ERROR_SUCCESS;
  if (!FindRemoteHunexGgeTrace(process, pid, &module, &export_rva, &header,
                               &module_error)) {
    if (module_error == ERROR_DUP_NAME) {
      fprintf(stderr,
              "multiple live hook DLLs export valid %s data for pid=%lu; "
              "refusing an ambiguous trace\n",
              fushi_voice_hook::kHunexGgeTraceExportName, pid);
    } else {
      fprintf(stderr, "live hook DLL export %s not found for pid=%lu: %lu\n",
              fushi_voice_hook::kHunexGgeTraceExportName, pid, module_error);
    }
    CloseHandle(process);
    return false;
  }
  if (export_rva > module.image_size ||
      sizeof(fushi_voice_hook::HunexGgeTraceBuffer) >
          static_cast<size_t>(module.image_size - export_rva) ||
      module.base > (std::numeric_limits<uintptr_t>::max)() - export_rva) {
    fprintf(stderr, "HUNEX/GGE trace export exceeds remote module bounds\n");
    CloseHandle(process);
    return false;
  }
  if (header.magic != fushi_voice_hook::kHunexGgeTraceMagic ||
      header.version != fushi_voice_hook::kHunexGgeTraceVersion ||
      header.event_size != sizeof(fushi_voice_hook::HunexGgeTraceEvent) ||
      header.slot_size != sizeof(fushi_voice_hook::HunexGgeTraceSlot) ||
      header.capacity != fushi_voice_hook::kHunexGgeTraceCapacity ||
      header.next_sequence < 0 || header.dropped_busy < 0 ||
      header.draw_calls < 0 || header.glyph_calls < 0 ||
      header.input_calls < 0) {
    fprintf(stderr,
            "HUNEX/GGE trace ABI mismatch: magic=0x%08x version=%u event=%u "
            "slot=%u capacity=%u\n",
            header.magic, header.version, header.event_size, header.slot_size,
            header.capacity);
    CloseHandle(process);
    return false;
  }

  const uintptr_t trace_address = module.base + export_rva;
  printf(
      "hunex_gge_trace pid=%lu module=%ls base=0x%llx "
      "export_rva=0x%08x next=%llu dropped_busy=%llu capacity=%u "
      "calls={draw:%llu,glyph:%llu,input:%llu}",
      pid, module.path.c_str(), static_cast<unsigned long long>(module.base),
      export_rva, static_cast<unsigned long long>(header.next_sequence),
      static_cast<unsigned long long>(header.dropped_busy), header.capacity,
      static_cast<unsigned long long>(header.draw_calls),
      static_cast<unsigned long long>(header.glyph_calls),
      static_cast<unsigned long long>(header.input_calls));
  PrintHunexGgeScannerStatus(header.scanner_status);
  printf(
      " machine=0x%04x matches={draw:%u,glyph:%u,key_poller:%u,"
      "input_pump:%u} "
      "rva={draw:%08x,glyph:%08x,key_poller:%08x,input_pump:%08x,"
      "generic_return:%08x,"
      "left_return:%08x,direct_first_glyph_return:%08x,"
      "direct_second_glyph_return:%08x}"
      "\n",
      header.module_machine, header.draw_match_count, header.glyph_match_count,
      header.key_poller_match_count, header.input_pump_match_count,
      header.draw_rva, header.glyph_rva, header.key_poller_rva,
      header.input_pump_rva, header.generic_return_rva,
      header.left_button_return_rva, header.direct_first_glyph_return_rva,
      header.direct_second_glyph_return_rva);

  const uint64_t next = static_cast<uint64_t>(header.next_sequence);
  const uint64_t first =
      next > header.capacity ? next - header.capacity + 1u : 1u;
  uint32_t accepted = 0;
  uint32_t unstable = 0;
  for (uint64_t expected = first; expected <= next; ++expected) {
    const uint64_t index = (expected - 1u) % header.capacity;
    const uint64_t slot_offset =
        offsetof(fushi_voice_hook::HunexGgeTraceBuffer, slots) +
        index * sizeof(fushi_voice_hook::HunexGgeTraceSlot);
    if (slot_offset > (std::numeric_limits<uintptr_t>::max)() - trace_address) {
      ++unstable;
      continue;
    }
    const uintptr_t slot_address =
        trace_address + static_cast<uintptr_t>(slot_offset);
    const uintptr_t sequence_address =
        slot_address + offsetof(fushi_voice_hook::HunexGgeTraceSlot, event) +
        offsetof(fushi_voice_hook::HunexGgeTraceEvent, sequence);
    LONG writing_before = 0;
    LONG writing_after = 0;
    uint64_t sequence_before = 0;
    uint64_t sequence_after = 0;
    fushi_voice_hook::HunexGgeTraceSlot slot;
    const bool stable =
        ReadRemoteExact(process, sequence_address, &sequence_before,
                        sizeof(sequence_before)) &&
        ReadRemoteExact(process, slot_address, &writing_before,
                        sizeof(writing_before)) &&
        ReadRemoteExact(process, slot_address, &slot, sizeof(slot)) &&
        ReadRemoteExact(process, sequence_address, &sequence_after,
                        sizeof(sequence_after)) &&
        ReadRemoteExact(process, slot_address, &writing_after,
                        sizeof(writing_after)) &&
        writing_before == 0 && slot.writing == 0 && writing_after == 0 &&
        sequence_before == expected && slot.event.sequence == expected &&
        sequence_after == expected;
    if (!stable) {
      ++unstable;
      continue;
    }
    ++accepted;
    PrintHunexGgeTraceEvent(slot.event);
  }
  printf("hunex_gge_trace_summary accepted=%u gaps_or_unstable=%u\n", accepted,
         unstable);
  CloseHandle(process);
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr,
            "usage: fushi_voice_ring_probe <pid> [轮数=30] [间隔ms=500]\n"
            "  或导出: <pid> --dump-text | --dump-text-events | --list-clips\n"
            "         <pid> --dump-xaudio-trace\n"
            "         <pid> --dump-leaf-d3d-trace\n"
            "         <pid> --dump-hunex-gge-trace\n"
            "         <pid> --select-text-thread <thread_id|0>\n"
            "         <pid> --dump-wav|--dump-utterance <ts_ms> <out.wav>\n"
            "         <pid> --dump-sources <ts_ms> <prefix>\n"
            "         <pid> --dump-loopback <ts_start_ms> <ts_end_ms> <out.wav>\n");
    return 1;
  }
  const DWORD pid = static_cast<DWORD>(strtoul(argv[1], nullptr, 10));
  const int rounds = (argc >= 3) ? atoi(argv[2]) : 30;
  const int interval_ms = (argc >= 4) ? atoi(argv[3]) : 500;
  const bool select_text_thread =
      argc >= 4 && strcmp(argv[2], "--select-text-thread") == 0;

  // The fixed XAudio trace is exported by the remote hook DLL rather than the
  // SharedHeader mapping.  Resolve and read it before opening shared IPC so the
  // command remains useful even when the mapping is unavailable or mismatched.
  if (argc >= 3 && strcmp(argv[2], "--dump-xaudio-trace") == 0) {
    return DumpXAudioTrace(pid) ? 0 : 2;
  }
  if (argc >= 3 && strcmp(argv[2], "--dump-leaf-d3d-trace") == 0) {
    return DumpLeafD3DTrace(pid) ? 0 : 2;
  }
  if (argc >= 3 && strcmp(argv[2], "--dump-hunex-gge-trace") == 0) {
    return DumpHunexGgeTrace(pid) ? 0 : 2;
  }

  const std::wstring shm = SharedMemoryName(pid);
  // BUG-1594：映射必须带 FILE_MAP_WRITE，哪怕本工具一个字节都不写。文本槽枚举走契约头的
  // CollectTextSlotsBySeq，它按跨进程发布纪律用 AtomicLoadPreview64 读 lane_seq，而那是
  // InterlockedCompareExchange64——一条**带锁的读改写**指令，落到只读页上就是 0xC0000005。
  // 于是「有文本行之后跑 ring_probe <pid>」必崩（本仓 host 侧一直用 READ|WRITE，只有这个
  // 诊断工具漏了）。权限放宽不改变「本工具只读不写」这个事实。
  const DWORD mapping_access = FILE_MAP_READ | FILE_MAP_WRITE;
  HANDLE mapping = OpenFileMappingW(mapping_access, FALSE, shm.c_str());
  if (mapping == nullptr) {
    fprintf(stderr,
            "OpenFileMapping 失败：%lu（injector 未对 pid=%lu 建共享内存？pid 错？）\n",
            GetLastError(), pid);
    return 1;
  }
  auto* header = static_cast<const SharedHeader*>(
      MapViewOfFile(mapping, mapping_access, 0, 0, 0));
  if (header == nullptr) {
    fprintf(stderr, "MapViewOfFile 失败：%lu\n", GetLastError());
    CloseHandle(mapping);
    return 1;
  }
  if (header->magic != kSharedMagic || header->version != kSharedVersion) {
    fprintf(stderr, "契约不匹配：magic=0x%08X version=%u（期望 0x%08X/%u）\n",
            header->magic, header->version, kSharedMagic, kSharedVersion);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 1;
  }

  const uint8_t* ring =
      reinterpret_cast<const uint8_t*>(header) + sizeof(SharedHeader);

  // Diagnostic equivalent of Hibiki VoiceHookReader::SelectTextThread. This
  // changes only the production IPC selector; text/resource events still have
  // to be produced by the live Luna/game hooks.
  if (select_text_thread) {
    const uint64_t thread_id = strtoull(argv[3], nullptr, 10);
    auto* writable_header = const_cast<SharedHeader*>(header);
    InterlockedExchange64(
        reinterpret_cast<volatile LONGLONG*>(
            &writable_header->selected_text_thread_id),
        static_cast<LONGLONG>(thread_id));
    printf("selected_text_thread_id=%llu\n",
           static_cast<unsigned long long>(thread_id));
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 0;
  }

  // 导出模式：--dump-text 打印所有台词行；--dump-wav <ts_ms> <out.wav> 导出最近该时间戳的语音。
  if (argc >= 3 && strcmp(argv[2], "--dump-text") == 0) {
    DumpText(header);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 0;
  }
  if (argc >= 3 && strcmp(argv[2], "--dump-text-meta") == 0) {
    DumpTextMeta(header);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 0;
  }
  if (argc >= 3 && strcmp(argv[2], "--dump-text-events") == 0) {
    DumpTextEvents(header);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 0;
  }
  if (argc >= 3 && strcmp(argv[2], "--dump-unity-events") == 0) {
    DumpUnityEvents(header);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 0;
  }
  if (argc >= 5 && strcmp(argv[2], "--dump-wav") == 0) {
    const uint64_t ts = strtoull(argv[3], nullptr, 10);
    const bool ok = DumpWav(header, ring, ts, argv[4]);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return ok ? 0 : 2;
  }
  if (argc >= 3 && strcmp(argv[2], "--list-clips") == 0) {
    ListClips(header);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 0;
  }
  if (argc >= 5 && strcmp(argv[2], "--dump-utterance") == 0) {
    const uint64_t ts = strtoull(argv[3], nullptr, 10);
    const bool ok = DumpUtterance(header, ring, ts, argv[4]);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return ok ? 0 : 2;
  }
  if (argc >= 5 && strcmp(argv[2], "--dump-sources") == 0) {
    const uint64_t ts = strtoull(argv[3], nullptr, 10);
    DumpSources(header, ring, ts, argv[4]);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 0;
  }
  // C.2f loopback 兜底：--dump-loopback <ts_start_ms> <ts_end_ms> <out.wav>。抽混音窗口做卡。
  if (argc >= 6 && strcmp(argv[2], "--dump-loopback") == 0) {
    const uint64_t ts0 = strtoull(argv[3], nullptr, 10);
    const uint64_t ts1 = strtoull(argv[4], nullptr, 10);
    const bool ok = DumpLoopback(header, ts0, ts1, argv[5]);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return ok ? 0 : 2;
  }

  std::vector<uint8_t> window;
  for (int r = 0; r < rounds; r++) {
    // 逐轮快照易变字段（单写单读，volatile 读至多滞后一包，对诊断无害）。
    const uint32_t hooked = header->hooked;
    const uint32_t calibrating = header->calibrating;
    const uint32_t sr = header->sample_rate;
    const uint32_t ch = header->channels;
    const uint32_t bits = header->bits_per_sample;
    const uint32_t is_float = header->is_float;
    const uint32_t cap = header->ring_capacity;
    const uint32_t ba = header->block_align;
    const uint32_t write_pos = header->write_pos;
    const uint64_t total = header->total_written;

    // 可读字节 = min(total_written, ring_capacity)。想看最近约 0.5s（sr*0.5*block_align）。
    uint32_t avail = (total < cap) ? static_cast<uint32_t>(total) : cap;
    double peak = -1.0;
    const char* state = "silent";
    if (ba != 0 && avail >= ba) {
      uint32_t want =
          static_cast<uint32_t>(static_cast<uint64_t>(sr) * ba / 2);  // 0.5s
      if (want > avail) {
        want = avail;
      }
      want -= (want % ba);  // block 对齐。
      if (want != 0) {
        // write_pos 理论上落在 [0,cap)；防御性取模避免越界读。
        CopyRecent(ring, cap, write_pos % cap, want, &window);
        peak = PeakAmplitude(window, bits, is_float);
        if (peak >= 0.0) {
          state = (peak > kSoundThreshold) ? "SOUND" : "silent";
        } else {
          state = "unknown-fmt";
        }
      }
    }

    if (peak >= 0.0) {
      printf(
          "[%02d] hooked=%u calibrating=%u sr=%u ch=%u bits=%u float=%u "
          "ring_cap=%u write_pos=%u total_written=%llu peak=%.0f (%s)\n",
          r, hooked, calibrating, sr, ch, bits, is_float, cap, write_pos,
          static_cast<unsigned long long>(total), peak, state);
    } else {
      printf(
          "[%02d] hooked=%u calibrating=%u sr=%u ch=%u bits=%u float=%u "
          "ring_cap=%u write_pos=%u total_written=%llu peak=n/a (%s)\n",
          r, hooked, calibrating, sr, ch, bits, is_float, cap, write_pos,
          static_cast<unsigned long long>(total), state);
    }
    // v10：文本事件计数 + 按句语音 clip 计数 + 最近一条台词（UTF-16LE→UTF-8）。
    const uint32_t text_hooked = header->text_hooked;
    const uint64_t twc = header->text_write_count;
    const uint64_t cwc = header->clip_write_count;
    const uint64_t uwc = header->unity_voice_write_count;
    printf("     [v10] text_hooked=%u luna_active=%u decdiag=0x%08x hookdiag=0x%08x hookio=0x%08x xaudiodiag=0x%08x text_events=%llu voice_clips=%llu unity_events=%llu",
           text_hooked, header->luna_active, header->reserved_luna,
           header->hook_diagnostics, header->reserved_hook_diagnostics,
           header->xaudio_diagnostics,
           static_cast<unsigned long long>(twc),
           static_cast<unsigned long long>(cwc),
           static_cast<unsigned long long>(uwc));
    if (twc > 0) {
      const uint32_t idx =
          static_cast<uint32_t>((twc - 1) % fushi_voice_hook::kTextSlotCount);
      const uint8_t* tbase =
          reinterpret_cast<const uint8_t*>(header) + header->text_region_offset;
      const auto* slot = reinterpret_cast<const fushi_voice_hook::TextSlot*>(
          tbase + static_cast<size_t>(idx) * fushi_voice_hook::kTextSlotBytes);
      if (slot->seq == twc && slot->byte_len > 0 && slot->is_utf8 == 0) {
        const wchar_t* w = reinterpret_cast<const wchar_t*>(
            reinterpret_cast<const uint8_t*>(slot) +
            sizeof(fushi_voice_hook::TextSlot));
        const int wlen = static_cast<int>(slot->byte_len / 2);
        char u8[700] = {0};
        WideCharToMultiByte(CP_UTF8, 0, w, wlen, u8, sizeof(u8) - 1, nullptr,
                            nullptr);
        printf(" last=\"%s\"", u8);
      }
    }
    if (uwc > 0) {
      const auto* event = &header->unity_voice_events[
          (uwc - 1) % fushi_voice_hook::kUnityVoiceEventCount];
      if (event->seq == uwc) {
        char clip_u8[512] = {0};
        char bundle_u8[1400] = {0};
        WideCharToMultiByte(CP_UTF8, 0, event->clip_name, -1, clip_u8,
                            sizeof(clip_u8) - 1, nullptr, nullptr);
        WideCharToMultiByte(CP_UTF8, 0, event->bundle_path, -1, bundle_u8,
                            sizeof(bundle_u8) - 1, nullptr, nullptr);
        printf(" unity_last=\"%s\" bundle=\"%s\"", clip_u8, bundle_u8);
      }
    }
    printf("\n");
    // C.2f/v16 loopback：policy 四元组是生命周期确认，diag/格式/字节只作观测。
    // 0x20 精确表示已准备调用 AUDCLNT_STREAMFLAGS_LOOPBACK Initialize；deny 的隐私
    // 证明必须是 requested=0、request_seq==applied_seq、state=stopped，且新会话 diag 无
    // worker/Initialize 位，而不能只看 total==0。
    const uint32_t native_loopback_requested =
        fushi_voice_hook::AtomicLoadShared32(
            &header->native_loopback_requested);
    const uint32_t native_loopback_request_seq =
        fushi_voice_hook::AtomicLoadShared32(
            &header->native_loopback_request_seq);
    const uint32_t native_loopback_state =
        fushi_voice_hook::AtomicLoadShared32(&header->native_loopback_state);
    const uint32_t native_loopback_applied_seq =
        fushi_voice_hook::AtomicLoadShared32(
            &header->native_loopback_applied_seq);
    printf(
        "     [lb] native_loopback_requested=%u request_seq=%u "
        "state=%s(%u) applied_seq=%u lbdiag=0x%08x sr=%u ch=%u bits=%u "
        "total=%llu markers=%llu\n",
        native_loopback_requested, native_loopback_request_seq,
        NativeLoopbackStateName(native_loopback_state), native_loopback_state,
        native_loopback_applied_seq,
        header->loopback_diag, header->loopback_sample_rate,
        header->loopback_channels, header->loopback_bits_per_sample,
        static_cast<unsigned long long>(header->loopback_total_written),
        static_cast<unsigned long long>(header->loopback_marker_count));
    fflush(stdout);
    if (r + 1 < rounds) {
      Sleep(static_cast<DWORD>(interval_ms));
    }
  }

  UnmapViewOfFile(header);
  CloseHandle(mapping);
  return 0;
}
