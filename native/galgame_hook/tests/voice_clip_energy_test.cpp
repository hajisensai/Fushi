// BUG-1769：clip 能量必须与位深/浮点无关。
//
// 为什么这条不变量是关键：`GrabUtterance` 靠能量从环里**挑出唯一一个语音源**。旧实现
// 只认 16-bit，float32 一律返回 -1 → `any_energy` 恒假 → `filter_by_src` 退化成 false →
// 拼接循环把窗口内所有源的 PCM 顺序拼进同一句，用户听到「同一句念两遍 + 断续杂音」。
// XAudio2 默认就输出 float32，没有专属 resource_audio adapter 的游戏都会落到这条通用路径。
//
// 所以下面第 ① 条（同一波形换编码后能量一致）就是整条链的守门断言：只要它成立，
// 选源就不会因为格式而失效。
//
// 不用 assert：本目录测试目标没关 NDEBUG，Release 下 assert 会被整条编掉，那样永远绿。
// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "voice_clip_energy.h"

using fushi_voice_hook::ClipEnergy16Scale;
using fushi_voice_hook::ClipSampleAbs16Scale;

namespace {

int g_failures = 0;

void Fail(const char* what, double got, double want) {
  ++g_failures;
  printf("FAIL %s: got %.6f want %.6f\n", what, got, want);
}

void ExpectNear(double got, double want, double tol_ratio, const char* what) {
  const double scale = (std::fabs(want) > 1.0) ? std::fabs(want) : 1.0;
  if (std::fabs(got - want) <= tol_ratio * scale) {
    return;
  }
  Fail(what, got, want);
}

void ExpectTrue(bool ok, const char* what) {
  if (ok) {
    return;
  }
  ++g_failures;
  printf("FAIL %s\n", what);
}

// 一段确定性测试波形：幅度归一到 [-1, 1]，避免用随机数。
std::vector<double> Waveform(size_t frames) {
  std::vector<double> v(frames);
  for (size_t i = 0; i < frames; ++i) {
    // 三角波 + 慢包络：既有过零点也有接近满刻度的样本。
    const double phase = static_cast<double>(i % 64) / 64.0;
    const double tri = (phase < 0.5) ? (4.0 * phase - 1.0) : (3.0 - 4.0 * phase);
    const double env = 0.35 + 0.6 * static_cast<double>(i % 197) / 197.0;
    v[i] = tri * env;
  }
  return v;
}

std::vector<uint8_t> Encode(const std::vector<double>& w, uint32_t bits,
                            bool is_float) {
  std::vector<uint8_t> out;
  out.resize(w.size() * (bits / 8));
  uint8_t* p = out.data();
  for (size_t i = 0; i < w.size(); ++i) {
    const double x = w[i];
    if (is_float) {
      const float f = static_cast<float>(x);
      std::memcpy(p, &f, sizeof(f));
      p += 4;
      continue;
    }
    switch (bits) {
      case 8: {
        const int v = static_cast<int>(x * 127.0);
        *p++ = static_cast<uint8_t>(v + 128);
        break;
      }
      case 16: {
        const int16_t v = static_cast<int16_t>(x * 32767.0);
        std::memcpy(p, &v, sizeof(v));
        p += 2;
        break;
      }
      case 24: {
        const int32_t v = static_cast<int32_t>(x * 8388607.0);
        const uint32_t u = static_cast<uint32_t>(v);
        *p++ = static_cast<uint8_t>(u & 0xFF);
        *p++ = static_cast<uint8_t>((u >> 8) & 0xFF);
        *p++ = static_cast<uint8_t>((u >> 16) & 0xFF);
        break;
      }
      case 32: {
        const int32_t v = static_cast<int32_t>(x * 2147483391.0);
        std::memcpy(p, &v, sizeof(v));
        p += 4;
        break;
      }
      default:
        break;
    }
  }
  return out;
}

// 把 [bytes] 放进一个容量 cap 的环，从 off 开始（可跨界），返回环缓冲。
std::vector<uint8_t> PlaceInRing(const std::vector<uint8_t>& bytes,
                                 uint32_t cap, uint32_t off) {
  std::vector<uint8_t> ring(cap, 0);
  for (size_t i = 0; i < bytes.size(); ++i) {
    ring[(off + i) % cap] = bytes[i];
  }
  return ring;
}

double EnergyOf(const std::vector<uint8_t>& bytes, uint32_t bits, bool is_float,
                uint32_t cap, uint32_t off) {
  const std::vector<uint8_t> ring = PlaceInRing(bytes, cap, off);
  return ClipEnergy16Scale(ring.data(), cap, off,
                           static_cast<uint32_t>(bytes.size()), bits, is_float);
}

}  // namespace

int main() {
  const std::vector<double> w = Waveform(4096);
  const uint32_t cap = 1 << 16;

  // ① 核心不变量：同一段波形换成任何一种支持的编码，能量必须落在同一个值附近。
  //    量化误差决定容差：8-bit 最粗（1/127 满刻度），给 2%；其余给 0.5%。
  const double e16 = EnergyOf(Encode(w, 16, false), 16, false, cap, 0);
  ExpectTrue(e16 > 0.0, "16-bit 基准能量应为正");
  ExpectNear(EnergyOf(Encode(w, 32, true), 32, true, cap, 0), e16, 0.005,
             "float32 能量应与 16-bit 一致（旧实现在这里返回 -1，正是 BUG-1769 的根）");
  ExpectNear(EnergyOf(Encode(w, 24, false), 24, false, cap, 0), e16, 0.005,
             "24-bit 能量应与 16-bit 一致");
  ExpectNear(EnergyOf(Encode(w, 32, false), 32, false, cap, 0), e16, 0.005,
             "32-bit 整数能量应与 16-bit 一致");
  ExpectNear(EnergyOf(Encode(w, 8, false), 8, false, cap, 0), e16, 0.02,
             "8-bit 能量应与 16-bit 一致（量化更粗，容差放宽）");

  // ② 支持的格式一律不得返回 -1 —— 「算不出能量」是退化分支的唯一入口。
  const uint32_t kBits[] = {8, 16, 24, 32};
  for (const uint32_t bits : kBits) {
    const double e = EnergyOf(Encode(w, bits, false), bits, false, cap, 0);
    ExpectTrue(e >= 0.0, "整数位深不得返回 -1");
  }
  ExpectTrue(EnergyOf(Encode(w, 32, true), 32, true, cap, 0) >= 0.0,
             "float32 不得返回 -1");

  // ③ 环形跨界：同一段数据放在环尾跨回环首，能量必须与不跨界时逐位一致。
  //    偏移**故意取成不是样本大小整数倍**，逼出「跨界样本按字节拼接」那条路径。
  for (const uint32_t bits : kBits) {
    const std::vector<uint8_t> enc = Encode(w, bits, false);
    const double flat = EnergyOf(enc, bits, false, cap, 0);
    for (const uint32_t skew : {1u, 2u, 3u}) {
      const uint32_t off = cap - static_cast<uint32_t>(enc.size()) / 2 - skew;
      const double wrapped = EnergyOf(enc, bits, false, cap, off);
      // 跨界最多丢/补一个样本，4096 个样本里相对影响 < 0.1%。
      ExpectNear(wrapped, flat, 0.002, "跨环边界能量应与不跨界一致");
    }
  }
  {
    const std::vector<uint8_t> enc = Encode(w, 32, true);
    const double flat = EnergyOf(enc, 32, true, cap, 0);
    const uint32_t off = cap - static_cast<uint32_t>(enc.size()) / 2 - 3;
    ExpectNear(EnergyOf(enc, 32, true, cap, off), flat, 0.002,
               "float32 跨环边界能量应与不跨界一致");
  }

  // ④ 选源判据的基础：静音段能量必须显著低于有声段，且各格式表现一致。
  const std::vector<double> silence(4096, 0.0);
  for (const uint32_t bits : kBits) {
    const double quiet = EnergyOf(Encode(silence, bits, false), bits, false,
                                  cap, 0);
    const double loud = EnergyOf(Encode(w, bits, false), bits, false, cap, 0);
    ExpectTrue(quiet >= 0.0 && quiet < loud * 0.02,
               "静音段能量应远低于有声段");
  }
  {
    const double quiet = EnergyOf(Encode(silence, 32, true), 32, true, cap, 0);
    ExpectTrue(quiet >= 0.0 && quiet < 1.0, "float32 静音段能量应接近 0");
  }

  // ⑤ 真正不认识的格式才返回 -1（否则调用方无从分辨「静音」与「不支持」）。
  {
    const uint8_t probe[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    ExpectTrue(ClipSampleAbs16Scale(probe, 12, false) < 0.0, "12-bit 应不支持");
    ExpectTrue(ClipSampleAbs16Scale(probe, 64, true) < 0.0,
               "float64 应不支持");
    std::vector<uint8_t> ring(cap, 0);
    ExpectTrue(ClipEnergy16Scale(ring.data(), cap, 0, 128, 12, false) < 0.0,
               "12-bit 段应返回 -1");
    ExpectTrue(ClipEnergy16Scale(ring.data(), cap, 0, 0, 16, false) < 0.0,
               "空段应返回 -1");
    ExpectTrue(ClipEnergy16Scale(nullptr, cap, 0, 128, 16, false) < 0.0,
               "空环应返回 -1");
  }

  if (g_failures != 0) {
    printf("voice_clip_energy_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("voice_clip_energy_test: OK\n");
  return 0;
}
