#include <windows.h>
#include <mmreg.h>

#ifdef NDEBUG
#undef NDEBUG  // This executable's assertions must remain active in Release CTest.
#endif
#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

#include "xaudio_source_format.h"
#include "xaudio_trace.h"
#include "xwma_resource.h"

namespace {

constexpr int16_t kCoefficients[7][2] = {
    {256, 0},   {512, -256}, {0, 0},      {192, 64},
    {240, 0},   {460, -208}, {392, -232},
};

std::vector<uint8_t> MakeMonoFormat() {
  std::vector<uint8_t> bytes(sizeof(WAVEFORMATEX) + 4 + sizeof(kCoefficients));
  auto* wave = reinterpret_cast<WAVEFORMATEX*>(bytes.data());
  wave->wFormatTag = WAVE_FORMAT_ADPCM;
  wave->nChannels = 1;
  wave->nSamplesPerSec = 47968;
  wave->nAvgBytesPerSec = 32978;
  wave->nBlockAlign = 22;
  wave->wBitsPerSample = 4;
  wave->cbSize = 4 + sizeof(kCoefficients);
  uint16_t samples_per_block = 32;
  uint16_t coefficient_count = 7;
  std::memcpy(bytes.data() + sizeof(WAVEFORMATEX), &samples_per_block, 2);
  std::memcpy(bytes.data() + sizeof(WAVEFORMATEX) + 2, &coefficient_count, 2);
  std::memcpy(bytes.data() + sizeof(WAVEFORMATEX) + 4, kCoefficients,
              sizeof(kCoefficients));
  return bytes;
}

}  // namespace

int main() {
  WAVEFORMATEX wmaudio2 = {};
  wmaudio2.wFormatTag = WAVE_FORMAT_WMAUDIO2;
  wmaudio2.nChannels = 1;
  wmaudio2.nSamplesPerSec = 44100;
  wmaudio2.nAvgBytesPerSec = 4000;
  wmaudio2.nBlockAlign = 1487;
  wmaudio2.wBitsPerSample = 16;
  fushi_voice_hook::XAudioSourceFormat wmaudio2_format;
  assert(fushi_voice_hook::ParseXAudioSourceFormat(
      &wmaudio2, &wmaudio2_format));
  assert(wmaudio2_format.encoding ==
         fushi_voice_hook::XAudioSourceEncoding::kWmaudio2);
  assert(wmaudio2_format.avg_bytes_per_second == 4000);

  const uint8_t original_wma[] = {0x11, 0x22, 0x33, 0x44, 0x55};
  const uint32_t original_dpds[] = {4096, 8192, 12288};
  std::vector<uint8_t> xwma;
  assert(fushi_voice_hook::BuildXwmaResource(
      wmaudio2_format, original_wma, sizeof(original_wma),
      reinterpret_cast<const uint8_t*>(original_dpds), 3, &xwma));
  assert(xwma.size() == 72);
  assert(std::memcmp(xwma.data(), "RIFF", 4) == 0);
  assert(std::memcmp(xwma.data() + 8, "XWMA", 4) == 0);
  assert(std::memcmp(xwma.data() + 12, "fmt ", 4) == 0);
  assert(std::memcmp(xwma.data() + 38, "dpds", 4) == 0);
  assert(std::memcmp(xwma.data() + 58, "data", 4) == 0);
  assert(std::memcmp(xwma.data() + 66, original_wma,
                     sizeof(original_wma)) == 0);
  const std::vector<uint8_t> format_bytes = MakeMonoFormat();
  const auto* wave =
      reinterpret_cast<const WAVEFORMATEX*>(format_bytes.data());
  fushi_voice_hook::XAudioSourceFormat format;
  assert(fushi_voice_hook::ParseXAudioSourceFormat(wave, &format));
  assert(format.encoding ==
         fushi_voice_hook::XAudioSourceEncoding::kMicrosoftAdpcm);
  assert(format.sample_rate == 47968);
  assert(format.channels == 1);
  assert(format.bits_per_sample == 4);
  assert(format.block_align == 22);
  assert(format.samples_per_block == 32);
  assert(format.coefficient_count == 7);

  fushi_voice_hook::XAudioTraceFormat trace_format;
  fushi_voice_hook::CaptureXAudioTraceFormat(
      wave, true, static_cast<uint32_t>(format.encoding), &trace_format);
  assert(trace_format.present == 1);
  assert(trace_format.parse_succeeded == 1);
  assert(trace_format.format_tag == WAVE_FORMAT_ADPCM);
  assert(trace_format.channels == 1);
  assert(trace_format.samples_per_sec == 47968);
  assert(trace_format.cb_size == 32);
  assert(trace_format.extra_bytes_copied == 32);
  assert(trace_format.adpcm_samples_per_block == 32);
  assert(trace_format.adpcm_coefficient_count == 7);
  assert(trace_format.adpcm_coefficients_copied == 7);
  assert(trace_format.adpcm_coefficients[1][0] == 512);
  assert(trace_format.adpcm_coefficients[1][1] == -256);

  WAVEFORMATEXTENSIBLE extensible = {};
  extensible.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
  extensible.Format.nChannels = 2;
  extensible.Format.nSamplesPerSec = 48000;
  extensible.Format.nAvgBytesPerSec = 192000;
  extensible.Format.nBlockAlign = 4;
  extensible.Format.wBitsPerSample = 16;
  extensible.Format.cbSize =
      sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  extensible.Samples.wValidBitsPerSample = 16;
  extensible.dwChannelMask = 3;
  extensible.SubFormat.Data1 = WAVE_FORMAT_PCM;
  extensible.SubFormat.Data2 = 0;
  extensible.SubFormat.Data3 = 0x0010;
  const uint8_t wave_subtype_tail[8] = {
      0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71,
  };
  std::memcpy(extensible.SubFormat.Data4, wave_subtype_tail,
              sizeof(wave_subtype_tail));
  fushi_voice_hook::XAudioTraceFormat extensible_trace;
  fushi_voice_hook::CaptureXAudioTraceFormat(
      &extensible.Format, true,
      static_cast<uint32_t>(
          fushi_voice_hook::XAudioSourceEncoding::kPcmInteger),
      &extensible_trace);
  assert(extensible_trace.extensible_valid_bits == 16);
  assert(extensible_trace.extensible_channel_mask == 3);
  assert(extensible_trace.subformat_data1 == WAVE_FORMAT_PCM);
  assert(extensible_trace.subformat_data3 == 0x0010);
  assert(std::memcmp(extensible_trace.subformat_data4, wave_subtype_tail,
                     sizeof(wave_subtype_tail)) == 0);

  std::vector<uint8_t> custom_bytes(sizeof(WAVEFORMATEX) + 64, 0x5a);
  auto* custom = reinterpret_cast<WAVEFORMATEX*>(custom_bytes.data());
  custom->wFormatTag = 0x7777;
  custom->cbSize = 64;
  fushi_voice_hook::XAudioTraceFormat custom_trace;
  fushi_voice_hook::CaptureXAudioTraceFormat(custom, false, 0,
                                              &custom_trace);
  assert(custom_trace.parse_succeeded == 0);
  assert(custom_trace.cb_size == 64);
  assert(custom_trace.extra_bytes_copied ==
         fushi_voice_hook::kXAudioTraceExtraPrefixBytes);
  for (uint32_t i = 0; i < custom_trace.extra_bytes_copied; ++i) {
    assert(custom_trace.extra_prefix[i] == 0x5a);
  }

  fushi_voice_hook::XAudioTraceEvent null_wma_trace;
  XAUDIO2_BUFFER_WMA null_wma = {};
  null_wma.PacketCount = 3;
  fushi_voice_hook::CaptureXAudioTraceWma(&null_wma, &null_wma_trace);
  assert(null_wma_trace.wma_present == 1);
  assert(null_wma_trace.wma_packet_count == 3);
  assert(null_wma_trace.wma_decoded_range_present == 0);
  assert(null_wma_trace.wma_first_decoded_bytes == 0);
  assert(null_wma_trace.wma_last_decoded_bytes == 0);

  const uint32_t decoded_cumulative_bytes[] = {384, 2048, 8192};
  XAUDIO2_BUFFER_WMA empty_wma = {};
  empty_wma.pDecodedPacketCumulativeBytes = decoded_cumulative_bytes;
  empty_wma.PacketCount = 0;
  fushi_voice_hook::XAudioTraceEvent empty_wma_trace;
  fushi_voice_hook::CaptureXAudioTraceWma(&empty_wma, &empty_wma_trace);
  assert(empty_wma_trace.wma_present == 1);
  assert(empty_wma_trace.wma_decoded_range_present == 0);

  XAUDIO2_BUFFER_WMA valid_wma = {};
  valid_wma.pDecodedPacketCumulativeBytes = decoded_cumulative_bytes;
  valid_wma.PacketCount = 3;
  fushi_voice_hook::XAudioTraceEvent valid_wma_trace;
  fushi_voice_hook::CaptureXAudioTraceWma(&valid_wma, &valid_wma_trace);
  assert(valid_wma_trace.wma_present == 1);
  assert(valid_wma_trace.wma_packet_count == 3);
  assert(valid_wma_trace.wma_decoded_range_present == 1);
  assert(valid_wma_trace.wma_first_decoded_bytes == 384);
  assert(valid_wma_trace.wma_last_decoded_bytes == 8192);

  // Publication is bounded and nonblocking.  A busy wrapped slot creates an
  // explicit sequence hole without touching its old committed payload.
  static fushi_voice_hook::XAudioTraceBuffer trace_buffer;
  fushi_voice_hook::XAudioTraceEvent trace_event =
      fushi_voice_hook::MakeXAudioTraceEvent(
          fushi_voice_hook::XAudioTraceEventKind::kSubmit);
  trace_event.source = 0x11223344;
  trace_event.audio_bytes = 4096;
  assert(fushi_voice_hook::PublishXAudioTraceEvent(&trace_buffer,
                                                   trace_event) == 1);
  assert(trace_buffer.slots[0].writing == 0);
  assert(trace_buffer.slots[0].event.sequence == 1);
  assert(trace_buffer.slots[0].event.source == 0x11223344);
  assert(trace_buffer.slots[0].event.audio_bytes == 4096);

  const uint64_t old_sequence = trace_buffer.slots[0].event.sequence;
  const uint64_t old_source = trace_buffer.slots[0].event.source;
  trace_buffer.next_sequence = fushi_voice_hook::kXAudioTraceCapacity;
  trace_buffer.slots[0].writing = 1;
  trace_event.source = 0x55667788;
  assert(fushi_voice_hook::PublishXAudioTraceEvent(&trace_buffer,
                                                   trace_event) == 0);
  assert(trace_buffer.next_sequence ==
         fushi_voice_hook::kXAudioTraceCapacity + 1);
  assert(trace_buffer.dropped_busy == 1);
  assert(trace_buffer.slots[0].event.sequence == old_sequence);
  assert(trace_buffer.slots[0].event.source == old_source);
  trace_buffer.slots[0].writing = 0;
  trace_buffer.next_sequence = fushi_voice_hook::kXAudioTraceCapacity * 2ull;
  assert(fushi_voice_hook::PublishXAudioTraceEvent(&trace_buffer,
                                                   trace_event) ==
         fushi_voice_hook::kXAudioTraceCapacity * 2ull + 1ull);
  assert(trace_buffer.slots[0].writing == 0);
  assert(trace_buffer.slots[0].event.sequence ==
         fushi_voice_hook::kXAudioTraceCapacity * 2ull + 1ull);
  assert(trace_buffer.slots[0].event.source == 0x55667788);

  fushi_voice_hook::XAudioSourceFormatRegistry<4> registry;
  fushi_voice_hook::XAudioSourceSnapshot registered;
  assert(registry.Register(0x1234, 0x9876, format, &registered));
  assert(registered.source == 0x1234);
  assert(registered.engine == 0x9876);
  assert(registered.generation != 0);
  assert(registered.queue_generation == 1);
  fushi_voice_hook::XAudioSourceFormat looked_up;
  assert(registry.Lookup(0x1234, &looked_up));
  assert(looked_up.samples_per_block == 32);
  assert(!registry.Lookup(0x5678, &looked_up));
  const uint64_t submit_before_start = 1000;
  assert(registry.TimestampForSubmit(registered, submit_before_start) == 0);
  assert(registry.ResolvePlaybackTimestamp(
             registered.source, registered.generation,
             registered.queue_generation, submit_before_start) == 0);
  assert(registry.MarkStarted(registered.source, registered.generation, 1400));
  assert(registry.ResolvePlaybackTimestamp(
             registered.source, registered.generation,
             registered.queue_generation, submit_before_start) == 1400);

  fushi_voice_hook::XAudioSourceSnapshot started;
  assert(registry.Lookup(registered.source, &started));
  assert(started.started);
  assert(registry.TimestampForSubmit(started, 1500) == 1500);
  assert(registry.MarkStopped(started.source, started.generation));
  fushi_voice_hook::XAudioSourceSnapshot stopped;
  assert(registry.Lookup(registered.source, &stopped));
  assert(!stopped.started);
  assert(registry.TimestampForSubmit(stopped, 1600) == 0);
  assert(registry.ResolvePlaybackTimestamp(
             stopped.source, stopped.generation, stopped.queue_generation,
             1600) == 0);
  assert(registry.MarkStarted(stopped.source, stopped.generation, 1700));
  assert(registry.ResolvePlaybackTimestamp(
             stopped.source, stopped.generation, stopped.queue_generation,
             1600) == 1700);

  // Flush invalidates submitted jobs without changing the SourceVoice lifetime
  // or its started state.
  uint64_t advanced_queue_generation = 0;
  assert(registry.AdvanceQueueGeneration(
      stopped.source, stopped.generation, &advanced_queue_generation));
  assert(advanced_queue_generation != stopped.queue_generation);
  assert(!registry.IsCurrent(stopped.source, stopped.generation,
                             stopped.queue_generation));
  assert(registry.ResolvePlaybackTimestamp(
             stopped.source, stopped.generation, stopped.queue_generation,
             1600) == 0);
  fushi_voice_hook::XAudioSourceSnapshot after_flush;
  assert(registry.Lookup(stopped.source, &after_flush));
  assert(after_flush.started);
  assert(after_flush.queue_generation == advanced_queue_generation);
  assert(registry.TimestampForSubmit(after_flush, 1800) == 1800);

  // Destroy/recreate at the same address is a new lifetime.  Old jobs and old
  // deferred operation-set records must not become current again.
  const uint64_t destroyed_generation = after_flush.generation;
  assert(registry.Unregister(after_flush.source, destroyed_generation));
  fushi_voice_hook::XAudioSourceSnapshot absent;
  assert(!registry.Lookup(after_flush.source, &absent));
  fushi_voice_hook::XAudioSourceSnapshot reused;
  assert(registry.Register(0x1234, 0x9876, format, &reused));
  assert(reused.generation != destroyed_generation);
  assert(!registry.IsCurrentSource(reused.source, destroyed_generation));
  assert(!registry.MarkStarted(reused.source, destroyed_generation, 1900));
  assert(registry.TimestampForSubmit(reused, 1900) == 0);

  std::vector<uint8_t> block(22, 0);
  block[0] = 0;
  block[1] = 16;
  block[3] = 0xe8;
  block[4] = 0x03;
  block[5] = 0x84;
  block[6] = 0x03;
  block[7] = 0x10;
  std::vector<int16_t> decoded;
  assert(fushi_voice_hook::DecodeMicrosoftAdpcm(
      format, block.data(), block.size(), &decoded));
  assert(decoded.size() == 32);
  assert(decoded[0] == 900);
  assert(decoded[1] == 1000);
  assert(decoded[2] == 1016);
  assert(decoded[3] == 1016);

  std::vector<uint8_t> malformed = format_bytes;
  reinterpret_cast<WAVEFORMATEX*>(malformed.data())->cbSize = 3;
  assert(!fushi_voice_hook::ParseXAudioSourceFormat(
      reinterpret_cast<const WAVEFORMATEX*>(malformed.data()), &format));
  return 0;
}
