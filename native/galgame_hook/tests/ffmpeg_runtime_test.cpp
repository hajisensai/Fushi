#include "ffmpeg_runtime.h"

#include <cassert>
#include <cstdint>
#include <cstring>

using hibiki_voice_hook::AudioResourceFormat;
using hibiki_voice_hook::DetectAudioResourceFormat;
using hibiki_voice_hook::FfmpegModuleKind;
using hibiki_voice_hook::ParseFfmpegModuleName;

int main() {
  const auto legacy = ParseFfmpegModuleName(L"avcodec-54.dll");
  assert(legacy.kind == FfmpegModuleKind::kAvcodec);
  assert(legacy.major == 54);

  const auto modern =
      ParseFfmpegModuleName(L"C:\\Game\\libavformat-61-abc.dll");
  assert(modern.kind == FfmpegModuleKind::kAvformat);
  assert(modern.major == 61);
  assert(ParseFfmpegModuleName(L"avformat.dll").major == 0);
  assert(ParseFfmpegModuleName(L"avformat-61x.dll").major == 0);

  uint8_t ogg[64] = {};
  std::memcpy(ogg, "OggS", 4);
  assert(DetectAudioResourceFormat(ogg, sizeof(ogg)) ==
         AudioResourceFormat::kOgg);
  std::memcpy(ogg + 28, "OpusHead", 8);
  assert(DetectAudioResourceFormat(ogg, sizeof(ogg)) ==
         AudioResourceFormat::kOpus);

  uint8_t wave[16] = {};
  std::memcpy(wave, "RIFF", 4);
  std::memcpy(wave + 8, "WAVE", 4);
  assert(DetectAudioResourceFormat(wave, sizeof(wave)) ==
         AudioResourceFormat::kWave);

  const uint8_t flac[] = {'f', 'L', 'a', 'C'};
  assert(DetectAudioResourceFormat(flac, sizeof(flac)) ==
         AudioResourceFormat::kFlac);
  const uint8_t zip[] = {'P', 'K', 3, 4};
  assert(DetectAudioResourceFormat(zip, sizeof(zip)) ==
         AudioResourceFormat::kUnknown);
  return 0;
}
