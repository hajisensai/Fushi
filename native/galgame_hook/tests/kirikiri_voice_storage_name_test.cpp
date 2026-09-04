// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cstdint>
#include <cwchar>

#include "kirikiri_voice_storage_name.h"

int main() {
  using fushi_voice_hook::IsKirikiriPathSeparator;
  using fushi_voice_hook::KirikiriVoicePayloadExtension;

  // `>` 是 KiriKiri 归档放置路径分隔符（`voice.xp3>坒`）——BUG-2115 的落盘名基名切分点。
  assert(IsKirikiriPathSeparator(L'>'));
  assert(IsKirikiriPathSeparator(L'/'));
  assert(IsKirikiriPathSeparator(L'\\'));
  assert(!IsKirikiriPathSeparator(L'.'));

  // 载荷魔数：Ogg（vorbis/opus）与 RIFF/WAVE 是音频；同前缀的 248 字节 sidecar 不是。
  const uint8_t ogg[16] = {'O', 'g', 'g', 'S', 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  const uint8_t wav[16] = {'R', 'I', 'F', 'F', 0x24, 0, 0, 0, 'W', 'A', 'V', 'E', 'f', 'm', 't', ' '};
  const uint8_t riff_not_wave[16] = {'R', 'I', 'F', 'F', 0, 0, 0, 0, 'A', 'V', 'I', ' ', 0, 0, 0, 0};
  const uint8_t sidecar[16] = {0x01, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0};
  assert(std::wcscmp(KirikiriVoicePayloadExtension(ogg, sizeof(ogg)), L".ogg") == 0);
  assert(std::wcscmp(KirikiriVoicePayloadExtension(wav, sizeof(wav)), L".wav") == 0);
  assert(KirikiriVoicePayloadExtension(riff_not_wave, sizeof(riff_not_wave)) == nullptr);
  assert(KirikiriVoicePayloadExtension(sidecar, sizeof(sidecar)) == nullptr);
  assert(KirikiriVoicePayloadExtension(ogg, 4) == nullptr);
  assert(KirikiriVoicePayloadExtension(nullptr, 16) == nullptr);
  return 0;
}
