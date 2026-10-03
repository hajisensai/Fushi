// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "pcm_wav_silence.h"

using fushi_voice_hook::IsSilentPcmWav;
using fushi_voice_hook::ParsePcmWav;
using fushi_voice_hook::PcmWavView;

namespace {

void Put32(std::vector<uint8_t>* v, uint32_t x) {
  for (int k = 0; k < 4; ++k) v->push_back(static_cast<uint8_t>(x >> (8 * k)));
}

void Put16(std::vector<uint8_t>* v, uint16_t x) {
  v->push_back(static_cast<uint8_t>(x));
  v->push_back(static_cast<uint8_t>(x >> 8));
}

void PutTag(std::vector<uint8_t>* v, const char* t) {
  for (int k = 0; k < 4; ++k) v->push_back(static_cast<uint8_t>(t[k]));
}

// 组一个 RIFF/WAVE：可选在 fmt 前插一个奇数长度的 LIST 块；extensible 时 fmt 长 40。
std::vector<uint8_t> Wav(uint16_t format, uint16_t channels, uint16_t bits,
                         const std::vector<uint8_t>& pcm, bool odd_list = false,
                         bool extensible = false, uint32_t data_size_override = 0) {
  std::vector<uint8_t> v;
  PutTag(&v, "RIFF");
  Put32(&v, 0);  // 消费端不信这个字段，这里也不填
  PutTag(&v, "WAVE");
  if (odd_list) {
    PutTag(&v, "LIST");
    Put32(&v, 3);
    v.push_back('a');
    v.push_back('b');
    v.push_back('c');
    v.push_back(0);  // 偶数对齐填充
  }
  PutTag(&v, "fmt ");
  Put32(&v, extensible ? 40 : 16);
  Put16(&v, extensible ? 0xFFFE : format);
  Put16(&v, channels);
  Put32(&v, 22050);
  Put32(&v, 22050u * channels * (bits / 8));
  Put16(&v, static_cast<uint16_t>(channels * (bits / 8)));
  Put16(&v, bits);
  if (extensible) {
    Put16(&v, 22);
    Put16(&v, bits);
    Put32(&v, 0);
    Put16(&v, format);  // SubFormat GUID 前两字节
    for (int k = 0; k < 14; ++k) v.push_back(0);
  }
  PutTag(&v, "data");
  Put32(&v, data_size_override != 0 ? data_size_override : static_cast<uint32_t>(pcm.size()));
  v.insert(v.end(), pcm.begin(), pcm.end());
  return v;
}

std::vector<uint8_t> Pcm16(const std::vector<int16_t>& s) {
  std::vector<uint8_t> out(s.size() * 2);
  std::memcpy(out.data(), s.data(), out.size());
  return out;
}

std::vector<uint8_t> PcmF32(const std::vector<float>& s) {
  std::vector<uint8_t> out(s.size() * 4);
  std::memcpy(out.data(), s.data(), out.size());
  return out;
}

bool Silent(const std::vector<uint8_t>& w) { return IsSilentPcmWav(w.data(), w.size()); }

}  // namespace

int main() {
  // 真机形状（Fate 的 mute.wav）：8-bit 无符号，样本在零点 128 附近 ±2 → 静音。
  {
    std::vector<uint8_t> pcm;
    for (int i = 0; i < 2373; ++i) pcm.push_back(static_cast<uint8_t>(i % 3 == 0 ? 127 : 126));
    assert(Silent(Wav(1, 1, 8, pcm)));
  }
  // 8-bit 有声：一个样本远离零点即不静音。
  {
    std::vector<uint8_t> pcm(1000, 128);
    pcm[500] = 200;
    assert(!Silent(Wav(1, 1, 8, pcm)));
  }
  // 16-bit：峰值判据，阈值 1024（-30 dBFS）两侧。
  assert(Silent(Wav(1, 1, 16, Pcm16(std::vector<int16_t>(4000, 0)))));
  assert(Silent(Wav(1, 1, 16, Pcm16({0, 1023, -1023, 0}))));
  assert(!Silent(Wav(1, 1, 16, Pcm16({0, 1024, 0, 0}))));
  assert(!Silent(Wav(1, 1, 16, Pcm16({0, 0, -1024, 0}))));
  // 真人声句子大段停顿、只有一处发声：按峰值不按均值，不得判静音。
  {
    std::vector<int16_t> s(44100, 0);
    s[30000] = 9000;
    assert(!Silent(Wav(1, 1, 16, Pcm16(s))));
  }
  // 立体声帧对齐。
  assert(Silent(Wav(1, 2, 16, Pcm16({1, -1, 2, -2}))));
  // IEEE float：0.01 ≈ 328 → 静音；0.5 → 有声。
  assert(Silent(Wav(3, 1, 32, PcmF32({0.01f, -0.01f, 0.0f}))));
  assert(!Silent(Wav(3, 1, 32, PcmF32({0.0f, 0.5f}))));
  // WAVE_FORMAT_EXTENSIBLE：子格式取 GUID 前两字节。
  assert(Silent(Wav(1, 1, 16, Pcm16({0, 3, -3}), false, true)));
  assert(!Silent(Wav(1, 1, 16, Pcm16({0, 30000}), false, true)));
  // fmt 前有奇数长度块：按偶数对齐跳过后仍能找到 fmt/data。
  assert(Silent(Wav(1, 1, 16, Pcm16({0, 5, 0}), true)));
  assert(!Silent(Wav(1, 1, 16, Pcm16({0, 20000, 0}), true)));
  // data 块声明长度超过实际：按剩余字节截断，且只计完整样本。
  {
    std::vector<uint8_t> w = Wav(1, 1, 16, Pcm16({0, 2, 0}), false, false, 100000);
    w.push_back(0x7F);  // 半个样本
    PcmWavView v;
    assert(ParsePcmWav(w.data(), w.size(), &v));
    assert(v.bytes == 6);
    assert(Silent(w));
  }
  // 解析不了的一律「不是静音」（只做减法，不误杀）。
  assert(!Silent(Wav(2, 1, 4, std::vector<uint8_t>(64, 0))));        // MS ADPCM
  assert(!Silent(Wav(1, 1, 12, std::vector<uint8_t>(64, 0))));       // 非字节对齐位深
  assert(!Silent(Wav(1, 1, 16, std::vector<uint8_t>())));            // 空 data
  {
    const uint8_t ogg[16] = {'O', 'g', 'g', 'S', 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    assert(!IsSilentPcmWav(ogg, sizeof(ogg)));
    assert(!IsSilentPcmWav(nullptr, 0));
  }
  // data 在 fmt 之前：不合规，不解析。
  {
    std::vector<uint8_t> v;
    PutTag(&v, "RIFF");
    Put32(&v, 0);
    PutTag(&v, "WAVE");
    PutTag(&v, "data");
    Put32(&v, 4);
    Put32(&v, 0);
    assert(!IsSilentPcmWav(v.data(), v.size()));
  }
  return 0;
}
