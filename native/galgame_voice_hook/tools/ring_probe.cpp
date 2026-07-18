#include <windows.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr,
            "usage: hibiki_voice_ring_probe <pid> [轮数=30] [间隔ms=500]\n");
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
  if (argc >= 5 && strcmp(argv[2], "--dump-wav") == 0) {
    const uint64_t ts = strtoull(argv[3], nullptr, 10);
    const bool ok = DumpWav(header, ring, ts, argv[4]);
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
    // v2：文本 hook 计数 + 按句语音 clip 计数 + 最近一条台词（UTF-16LE→UTF-8）。
    const uint32_t text_hooked = header->text_hooked;
    const uint64_t twc = header->text_write_count;
    const uint64_t cwc = header->clip_write_count;
    printf("     [v2] text_hooked=%u luna_active=%u text_lines=%llu voice_clips=%llu",
           text_hooked, header->luna_active,
           static_cast<unsigned long long>(twc),
           static_cast<unsigned long long>(cwc));
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
    printf("\n");
    fflush(stdout);
    if (r + 1 < rounds) {
      Sleep(static_cast<DWORD>(interval_ms));
    }
  }

  UnmapViewOfFile(header);
  CloseHandle(mapping);
  return 0;
}
