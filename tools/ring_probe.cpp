#include <windows.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "voice_hook_ipc.h"

// galgame 一键制卡 C 阶段 —— 环形缓冲诊断读取器（x64 独立小工具）。
//
// 用途：injector 早注入（--launch）目标游戏、放着游戏出声后，用它旁路读共享内存，直观确认
// DirectSound/XAudio2 捕获真的在工作——hooked=1、格式被 hook 填上、total_written 在涨、峰值
// 振幅从 silent 变 SOUND。**只读**，不注入、不写共享内存，故不需与目标同位数：命名文件映射
// （Local\HibikiVoiceHook_<pid>）跨 32/64 位可读，x64 reader 能读 32 位游戏里 hook 填的缓冲。
//
// 用法：hibiki_voice_ring_probe <pid> [轮数=30] [间隔ms=500]
//   <pid>    injector 建共享内存时用的目标进程 pid（injector 打印的 pid=）
//   轮数     采样轮数（缺省 30）
//   间隔ms   每轮间隔毫秒（缺省 500）
namespace {

using hibiki_voice_hook::kSharedMagic;
using hibiki_voice_hook::kSharedVersion;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::SharedMemoryName;

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
  const uint64_t count = h->text_write_count;
  const uint32_t slots = hibiki_voice_hook::kTextSlotCount;
  const uint32_t slot_bytes = hibiki_voice_hook::kTextSlotBytes;
  const uint8_t* base =
      reinterpret_cast<const uint8_t*>(h) + h->text_region_offset;
  const uint64_t start = (count > slots) ? count - slots : 0;
  for (uint64_t seq = start + 1; seq <= count; seq++) {
    const auto* slot = reinterpret_cast<const hibiki_voice_hook::TextSlot*>(
        base + static_cast<size_t>((seq - 1) % slots) * slot_bytes);
    if (slot->seq != seq || slot->byte_len == 0) {
      continue;
    }
    char u8[1400] = {0};
    const uint8_t* txt = reinterpret_cast<const uint8_t*>(slot) +
                         sizeof(hibiki_voice_hook::TextSlot);
    if (slot->is_utf8) {
      uint32_t n = slot->byte_len;
      if (n > 1399) n = 1399;
      memcpy(u8, txt, n);
    } else {
      WideCharToMultiByte(CP_UTF8, 0, reinterpret_cast<const wchar_t*>(txt),
                          static_cast<int>(slot->byte_len / 2), u8,
                          sizeof(u8) - 1, nullptr, nullptr);
    }
    printf("%llu|%llu|%s\n", static_cast<unsigned long long>(seq),
           static_cast<unsigned long long>(slot->timestamp_ms), u8);
  }
  fflush(stdout);
}

void DumpTextMeta(const SharedHeader* h) {
  const uint64_t count = h->text_write_count;
  const uint8_t* base = reinterpret_cast<const uint8_t*>(h) +
                        h->text_region_offset;
  const uint64_t start = count > hibiki_voice_hook::kTextSlotCount
                             ? count - hibiki_voice_hook::kTextSlotCount
                             : 0;
  for (uint64_t seq = start + 1; seq <= count; ++seq) {
    const auto* slot = reinterpret_cast<const hibiki_voice_hook::TextSlot*>(
        base + static_cast<size_t>((seq - 1) %
                                   hibiki_voice_hook::kTextSlotCount) *
                   hibiki_voice_hook::kTextSlotBytes);
    if (slot->seq != seq || slot->byte_len == 0) continue;
    char text[1400] = {0};
    const uint8_t* raw = reinterpret_cast<const uint8_t*>(slot) +
                         sizeof(hibiki_voice_hook::TextSlot);
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

void DumpUnityEvents(const SharedHeader* h) {
  const uint64_t count = h->unity_voice_write_count;
  const uint64_t start = count > hibiki_voice_hook::kUnityVoiceEventCount
                             ? count - hibiki_voice_hook::kUnityVoiceEventCount
                             : 0;
  for (uint64_t seq = start + 1; seq <= count; ++seq) {
    const auto* event = &h->unity_voice_events[
        (seq - 1) % hibiki_voice_hook::kUnityVoiceEventCount];
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
  const uint32_t cslots = hibiki_voice_hook::kClipCount;
  const uint8_t* cbase =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t total = h->total_written;
  const uint64_t scan = (clips > cslots) ? clips - cslots : 0;
  const hibiki_voice_hook::VoiceClip* best = nullptr;
  uint64_t bestDiff = ~0ull;
  for (uint64_t seq = scan + 1; seq <= clips; seq++) {
    const auto* c = reinterpret_cast<const hibiki_voice_hook::VoiceClip*>(
        cbase + static_cast<size_t>((seq - 1) % cslots) *
                    sizeof(hibiki_voice_hook::VoiceClip));
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
                 const hibiki_voice_hook::VoiceClip* c,
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

// 16-bit PCM 平均绝对幅值（能量代理）。非 16-bit 返回 -1（调用方退化为固定窗口）。
double ClipEnergy16(const SharedHeader* h, const uint8_t* ring,
                    const hibiki_voice_hook::VoiceClip* c) {
  if (c->bits_per_sample != 16 || c->is_float) {
    return -1.0;
  }
  std::vector<uint8_t> buf;
  if (!ReadClipPcm(h, ring, c, buf) || buf.size() < 2) {
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
  const uint32_t cslots = hibiki_voice_hook::kClipCount;
  const uint8_t* cbase =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t scan = (clips > cslots) ? clips - cslots : 0;
  // 收集有效 clip 指针。
  std::vector<const hibiki_voice_hook::VoiceClip*> valid;
  for (uint64_t seq = scan + 1; seq <= clips; seq++) {
    const auto* c = reinterpret_cast<const hibiki_voice_hook::VoiceClip*>(
        cbase + static_cast<size_t>((seq - 1) % cslots) *
                    sizeof(hibiki_voice_hook::VoiceClip));
    if (c->seq == seq && c->byte_len != 0 && c->byte_len <= cap) {
      valid.push_back(c);
    }
  }
  if (valid.empty()) {
    return false;
  }
  // 每源：说话前窗口 [ts-900,ts-250] 与文本时刻窗口 [ts-150,ts+450] 的平均能量。
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
  // 拼接语音源在 [ts-200, ts+6000] 的段；静音判据用该源峰值能量的 8%。
  std::vector<uint8_t> pcm;
  const hibiki_voice_hook::VoiceClip* fmt = nullptr;
  double peak = 1.0;
  for (const auto* c : valid) {
    if (any_energy && c->source_ptr != voice_src) {
      continue;
    }
    const int64_t d = static_cast<int64_t>(c->timestamp_ms) -
                      static_cast<int64_t>(ts);
    if (d < -200 || d > 6000) {
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
  const uint32_t cslots = hibiki_voice_hook::kClipCount;
  const uint8_t* cbase =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t scan = (clips > cslots) ? clips - cslots : 0;
  // 收集 [ts-300, ts+6000] 窗口内各源的 clip 指针。
  std::map<uint64_t, std::vector<const hibiki_voice_hook::VoiceClip*>> by_src;
  for (uint64_t seq = scan + 1; seq <= clips; seq++) {
    const auto* c = reinterpret_cast<const hibiki_voice_hook::VoiceClip*>(
        cbase + static_cast<size_t>((seq - 1) % cslots) *
                    sizeof(hibiki_voice_hook::VoiceClip));
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
    const hibiki_voice_hook::VoiceClip* fmt = nullptr;
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
                            std::vector<hibiki_voice_hook::LoopbackMarker>* out) {
  out->clear();
  const uint64_t count = h->loopback_marker_count;
  const uint32_t slots = h->loopback_marker_slot_count
                             ? h->loopback_marker_slot_count
                             : hibiki_voice_hook::kLoopbackMarkerCount;
  const uint8_t* base =
      reinterpret_cast<const uint8_t*>(h) + h->loopback_marker_offset;
  const uint64_t scan = (count > slots) ? count - slots : 0;
  for (uint64_t seq = scan + 1; seq <= count; seq++) {
    const auto* m = reinterpret_cast<const hibiki_voice_hook::LoopbackMarker*>(
        base + static_cast<size_t>((seq - 1) % slots) *
                   sizeof(hibiki_voice_hook::LoopbackMarker));
    if (m->seq == seq) {
      out->push_back(*m);
    }
  }
}

// 用标记表把墙钟 tick 映射到 loopback 环线性字节位置 total。标记单调（tick/total 同增）：tick 落
// 两标记间线性插值（自动处理静音间隙的 total 平段）；早于首标记按 byte_rate 反推夹到 [0,首total]；
// 晚于末标记按 byte_rate 外推夹到 cur_total。无标记退化为 cur_total。
uint64_t TickToTotal(const std::vector<hibiki_voice_hook::LoopbackMarker>& mk,
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
  std::vector<hibiki_voice_hook::LoopbackMarker> mk;
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
  const uint32_t cslots = hibiki_voice_hook::kClipCount;
  const uint8_t* cbase =
      reinterpret_cast<const uint8_t*>(h) + h->clip_region_offset;
  const uint64_t scan = (clips > cslots) ? clips - cslots : 0;
  uint64_t prev_ts = 0;
  for (uint64_t seq = scan + 1; seq <= clips; seq++) {
    const auto* c = reinterpret_cast<const hibiki_voice_hook::VoiceClip*>(
        cbase + static_cast<size_t>((seq - 1) % cslots) *
                    sizeof(hibiki_voice_hook::VoiceClip));
    if (c->seq != seq) {
      continue;
    }
    const uint32_t br = c->sample_rate * c->channels * (c->bits_per_sample / 8);
    const double dur = br ? static_cast<double>(c->byte_len) / br * 1000.0 : 0;
    const long long dts =
        prev_ts ? static_cast<long long>(c->timestamp_ms - prev_ts) : 0;
    printf("clip seq=%llu ts=%llu dts=%lld src=%08llx off=%u len=%u dur=%.0fms\n",
           static_cast<unsigned long long>(seq),
           static_cast<unsigned long long>(c->timestamp_ms), dts,
           static_cast<unsigned long long>(c->source_ptr & 0xffffffffull),
           c->ring_offset, c->byte_len, dur);
    prev_ts = c->timestamp_ms;
  }
  fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr,
            "usage: hibiki_voice_ring_probe <pid> [轮数=30] [间隔ms=500]\n"
            "  或导出: <pid> --dump-text | --list-clips\n"
            "         <pid> --dump-wav|--dump-utterance <ts_ms> <out.wav>\n"
            "         <pid> --dump-sources <ts_ms> <prefix>\n"
            "         <pid> --dump-loopback <ts_start_ms> <ts_end_ms> <out.wav>\n");
    return 1;
  }
  const DWORD pid = static_cast<DWORD>(strtoul(argv[1], nullptr, 10));
  const int rounds = (argc >= 3) ? atoi(argv[2]) : 30;
  const int interval_ms = (argc >= 4) ? atoi(argv[3]) : 500;

  const std::wstring shm = SharedMemoryName(pid);
  HANDLE mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, shm.c_str());
  if (mapping == nullptr) {
    fprintf(stderr,
            "OpenFileMapping 失败：%lu（injector 未对 pid=%lu 建共享内存？pid 错？）\n",
            GetLastError(), pid);
    return 1;
  }
  auto* header = static_cast<const SharedHeader*>(
      MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0));
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
    printf("     [v10] text_hooked=%u luna_active=%u decdiag=0x%08x hookdiag=0x%08x hookio=0x%08x text_events=%llu voice_clips=%llu unity_events=%llu",
           text_hooked, header->luna_active, header->reserved_luna,
           header->hook_diagnostics, header->reserved_hook_diagnostics,
           static_cast<unsigned long long>(twc),
           static_cast<unsigned long long>(cwc),
           static_cast<unsigned long long>(uwc));
    if (twc > 0) {
      const uint32_t idx =
          static_cast<uint32_t>((twc - 1) % hibiki_voice_hook::kTextSlotCount);
      const uint8_t* tbase =
          reinterpret_cast<const uint8_t*>(header) + header->text_region_offset;
      const auto* slot = reinterpret_cast<const hibiki_voice_hook::TextSlot*>(
          tbase + static_cast<size_t>(idx) * hibiki_voice_hook::kTextSlotBytes);
      if (slot->seq == twc && slot->byte_len > 0 && slot->is_utf8 == 0) {
        const wchar_t* w = reinterpret_cast<const wchar_t*>(
            reinterpret_cast<const uint8_t*>(slot) +
            sizeof(hibiki_voice_hook::TextSlot));
        const int wlen = static_cast<int>(slot->byte_len / 2);
        char u8[700] = {0};
        WideCharToMultiByte(CP_UTF8, 0, w, wlen, u8, sizeof(u8) - 1, nullptr,
                            nullptr);
        printf(" last=\"%s\"", u8);
      }
    }
    if (uwc > 0) {
      const auto* event = &header->unity_voice_events[
          (uwc - 1) % hibiki_voice_hook::kUnityVoiceEventCount];
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
    // C.2f loopback 兜底捕获状态：诊断位 + 混音格式 + 累计字节 + 标记数（主代理据此确认 loopback
    // 真在抓）。lbdiag 位：0x01 线程启动/0x02 设备就绪/0x04 捕获启动/0x08 抓到非静音/0x10 见静音包/
    // 0x40 未知格式按静音填/0x80 初始化失败。
    printf(
        "     [lb] lbdiag=0x%02x sr=%u ch=%u bits=%u total=%llu markers=%llu\n",
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
