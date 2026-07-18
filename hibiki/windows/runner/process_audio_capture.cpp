#include "process_audio_capture.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <ks.h>
#include <ksmedia.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>
#include <propidl.h>
#include <wrl.h>
#include <wrl/implements.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <utility>

namespace hibiki {
namespace {

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::FtmBase;
using Microsoft::WRL::MakeAndInitialize;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;

constexpr DWORD kActivationTimeoutMs = 10000;
constexpr uint32_t kMinBufferSeconds = 15;
constexpr uint32_t kMaxBufferSeconds = 300;
constexpr uint64_t kMaxRingBytes = 256ULL * 1024ULL * 1024ULL;
constexpr uint32_t kMp3BytesPerSecond = 6000;  // 48 kbps.
constexpr LONGLONG kHundredNanosecondsPerSecond = 10000000LL;

std::string HResultText(const char* operation, HRESULT hr) {
  char buffer[160] = {};
  snprintf(buffer, sizeof(buffer), "%s failed (HRESULT 0x%08X)", operation,
           static_cast<unsigned>(hr));
  return std::string(buffer);
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), out.data(), size);
  return out;
}

bool WriteAll(HANDLE file, const void* data, DWORD size) {
  const auto* cursor = static_cast<const uint8_t*>(data);
  DWORD remaining = size;
  while (remaining > 0) {
    DWORD written = 0;
    if (!WriteFile(file, cursor, remaining, &written, nullptr) || written == 0) {
      return false;
    }
    cursor += written;
    remaining -= written;
  }
  return true;
}

bool WriteFourCc(HANDLE file, const char (&value)[5]) {
  return WriteAll(file, value, 4);
}

// WASAPI's shared mix format is normally stereo float32. MP3 encoders accept
// PCM input, and Galgame dialogue does not benefit from preserving stereo, so
// prepare compact mono PCM16 without changing the capture ring itself.
bool ConvertWaveToMonoPcm16(std::vector<uint8_t>* format,
                            std::vector<uint8_t>* audio) {
  if (format == nullptr || audio == nullptr ||
      format->size() < sizeof(WAVEFORMATEX)) {
    return false;
  }

  WAVEFORMATEX source = {};
  memcpy(&source, format->data(), sizeof(source));
  bool is_float = source.wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
  bool is_pcm = source.wFormatTag == WAVE_FORMAT_PCM;
  if (source.wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      format->size() >= sizeof(WAVEFORMATEXTENSIBLE)) {
    WAVEFORMATEXTENSIBLE extensible = {};
    memcpy(&extensible, format->data(), sizeof(extensible));
    is_float = IsEqualGUID(extensible.SubFormat,
                          KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    is_pcm = IsEqualGUID(extensible.SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
  }
  const bool supported_float = is_float && source.wBitsPerSample == 32;
  const bool supported_pcm = is_pcm && source.wBitsPerSample == 16;
  const size_t bytes_per_sample = supported_float ? sizeof(float)
                                                   : sizeof(int16_t);
  if ((!supported_float && !supported_pcm) || source.nChannels == 0 ||
      source.nSamplesPerSec == 0 ||
      source.nBlockAlign != source.nChannels * bytes_per_sample ||
      audio->size() % source.nBlockAlign != 0) {
    return false;
  }

  const size_t frame_count = audio->size() / source.nBlockAlign;
  const uint16_t channels_to_mix = std::min<uint16_t>(source.nChannels, 2);
  std::vector<uint8_t> pcm(frame_count * sizeof(int16_t));
  for (size_t frame = 0; frame < frame_count; ++frame) {
    float sample = 0.0f;
    for (uint16_t channel = 0; channel < channels_to_mix; ++channel) {
      const size_t offset = frame * source.nBlockAlign +
                            channel * bytes_per_sample;
      if (supported_float) {
        float channel_sample = 0.0f;
        memcpy(&channel_sample, audio->data() + offset,
               sizeof(channel_sample));
        if (std::isfinite(channel_sample)) sample += channel_sample;
      } else {
        int16_t channel_sample = 0;
        memcpy(&channel_sample, audio->data() + offset,
               sizeof(channel_sample));
        sample += static_cast<float>(channel_sample) / 32768.0f;
      }
    }
    sample /= channels_to_mix;
    sample = std::clamp(sample, -1.0f, 1.0f);
    const float scale = sample < 0.0f ? 32768.0f : 32767.0f;
    const int16_t converted =
        static_cast<int16_t>(std::lround(sample * scale));
    memcpy(pcm.data() + frame * sizeof(converted), &converted,
           sizeof(converted));
  }

  WAVEFORMATEX output = {};
  output.wFormatTag = WAVE_FORMAT_PCM;
  output.nChannels = 1;
  output.nSamplesPerSec = source.nSamplesPerSec;
  output.wBitsPerSample = 16;
  output.nBlockAlign =
      output.nChannels * output.wBitsPerSample / static_cast<WORD>(8);
  output.nAvgBytesPerSec = output.nSamplesPerSec * output.nBlockAlign;

  constexpr size_t kPcmFormatSize = 16;
  format->assign(reinterpret_cast<const uint8_t*>(&output),
                 reinterpret_cast<const uint8_t*>(&output) + kPcmFormatSize);
  *audio = std::move(pcm);
  return true;
}

std::string ReplaceExtension(const std::string& path,
                             const char* extension) {
  const size_t separator = path.find_last_of("\\/");
  const size_t dot = path.find_last_of('.');
  if (dot == std::string::npos ||
      (separator != std::string::npos && dot < separator)) {
    return path + extension;
  }
  return path.substr(0, dot) + extension;
}

bool WriteMp3File(const std::string& output_path,
                  const std::vector<uint8_t>& format,
                  const std::vector<uint8_t>& audio, std::string* error) {
  constexpr size_t kWaveFormatBaseSize = 16;
  if (format.size() < kWaveFormatBaseSize || audio.empty() ||
      audio.size() > std::numeric_limits<DWORD>::max()) {
    *error = "mono PCM input is invalid for MP3 encoding";
    return false;
  }
  WAVEFORMATEX input = {};
  memcpy(&input, format.data(),
         std::min(format.size(), sizeof(WAVEFORMATEX)));
  if (input.wFormatTag != WAVE_FORMAT_PCM || input.nChannels != 1 ||
      input.nSamplesPerSec == 0 || input.wBitsPerSample != 16 ||
      input.nBlockAlign != sizeof(int16_t) ||
      audio.size() % input.nBlockAlign != 0) {
    *error = "MP3 encoding requires mono PCM16 input";
    return false;
  }
  const std::wstring wide_path = Utf8ToWide(output_path);
  if (wide_path.empty()) {
    *error = "output path is invalid UTF-8";
    return false;
  }

  HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
  if (FAILED(hr)) {
    *error = HResultText("MFStartup", hr);
    return false;
  }
  {
    ComPtr<IMFSinkWriter> writer;
    ComPtr<IMFMediaType> output_type;
    ComPtr<IMFMediaType> input_type;
    ComPtr<IMFMediaBuffer> buffer;
    ComPtr<IMFSample> sample;
    DWORD stream_index = 0;

    hr = MFCreateSinkWriterFromURL(wide_path.c_str(), nullptr, nullptr,
                                   writer.GetAddressOf());
    if (SUCCEEDED(hr)) hr = MFCreateMediaType(output_type.GetAddressOf());
    if (SUCCEEDED(hr)) {
      hr = output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    }
    if (SUCCEEDED(hr)) {
      hr = output_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_MP3);
    }
    if (SUCCEEDED(hr)) {
      hr = output_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1);
    }
    if (SUCCEEDED(hr)) {
      hr = output_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                                  input.nSamplesPerSec);
    }
    if (SUCCEEDED(hr)) {
      hr = output_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                                  kMp3BytesPerSecond);
    }
    if (SUCCEEDED(hr)) {
      hr = output_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 1);
    }
    if (SUCCEEDED(hr)) {
      hr = writer->AddStream(output_type.Get(), &stream_index);
    }

    if (SUCCEEDED(hr)) hr = MFCreateMediaType(input_type.GetAddressOf());
    if (SUCCEEDED(hr)) {
      hr = input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    }
    if (SUCCEEDED(hr)) {
      hr = input_type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    }
    if (SUCCEEDED(hr)) {
      hr = input_type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1);
    }
    if (SUCCEEDED(hr)) {
      hr = input_type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                                 input.nSamplesPerSec);
    }
    if (SUCCEEDED(hr)) {
      hr = input_type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    }
    if (SUCCEEDED(hr)) {
      hr = input_type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT,
                                 input.nBlockAlign);
    }
    if (SUCCEEDED(hr)) {
      hr = input_type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                                 input.nAvgBytesPerSec);
    }
    if (SUCCEEDED(hr)) {
      hr = input_type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
    }
    if (SUCCEEDED(hr)) {
      hr = writer->SetInputMediaType(stream_index, input_type.Get(), nullptr);
    }
    if (SUCCEEDED(hr)) hr = writer->BeginWriting();

    if (SUCCEEDED(hr)) {
      hr = MFCreateMemoryBuffer(static_cast<DWORD>(audio.size()),
                                buffer.GetAddressOf());
    }
    if (SUCCEEDED(hr)) {
      BYTE* destination = nullptr;
      DWORD capacity = 0;
      hr = buffer->Lock(&destination, &capacity, nullptr);
      if (SUCCEEDED(hr)) {
        if (capacity < audio.size()) {
          hr = E_UNEXPECTED;
        } else {
          memcpy(destination, audio.data(), audio.size());
        }
        const HRESULT unlock = buffer->Unlock();
        if (SUCCEEDED(hr)) hr = unlock;
      }
    }
    if (SUCCEEDED(hr)) {
      hr = buffer->SetCurrentLength(static_cast<DWORD>(audio.size()));
    }
    if (SUCCEEDED(hr)) hr = MFCreateSample(sample.GetAddressOf());
    if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get());
    if (SUCCEEDED(hr)) hr = sample->SetSampleTime(0);
    if (SUCCEEDED(hr)) {
      const uint64_t frames = audio.size() / input.nBlockAlign;
      const LONGLONG duration = static_cast<LONGLONG>(
          frames * kHundredNanosecondsPerSecond / input.nSamplesPerSec);
      hr = sample->SetSampleDuration(duration);
    }
    if (SUCCEEDED(hr)) hr = writer->WriteSample(stream_index, sample.Get());
    if (SUCCEEDED(hr)) hr = writer->Finalize();
  }
  MFShutdown();

  if (FAILED(hr)) {
    DeleteFileW(wide_path.c_str());
    *error = HResultText("MP3 encoding", hr);
    return false;
  }
  return true;
}

bool WriteWaveFile(const std::string& output_path,
                   const std::vector<uint8_t>& format,
                   const std::vector<uint8_t>& audio, std::string* error) {
  if (format.size() > std::numeric_limits<uint32_t>::max() ||
      audio.size() > std::numeric_limits<uint32_t>::max()) {
    *error = "audio clip is too large for WAV";
    return false;
  }
  const std::wstring wide_path = Utf8ToWide(output_path);
  if (wide_path.empty()) {
    *error = "output path is invalid UTF-8";
    return false;
  }
  HANDLE file = CreateFileW(wide_path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    *error = "unable to create WAV output";
    return false;
  }

  const uint32_t fmt_size = static_cast<uint32_t>(format.size());
  const uint32_t data_size = static_cast<uint32_t>(audio.size());
  const uint32_t fmt_padding = fmt_size & 1U;
  const uint64_t riff_size64 = 4ULL + 8ULL + fmt_size + fmt_padding + 8ULL +
                               static_cast<uint64_t>(data_size);
  bool ok = riff_size64 <= std::numeric_limits<uint32_t>::max();
  const uint32_t riff_size = static_cast<uint32_t>(riff_size64);
  const uint8_t zero = 0;
  if (ok) ok = WriteFourCc(file, "RIFF");
  if (ok) ok = WriteAll(file, &riff_size, sizeof(riff_size));
  if (ok) ok = WriteFourCc(file, "WAVE");
  if (ok) ok = WriteFourCc(file, "fmt ");
  if (ok) ok = WriteAll(file, &fmt_size, sizeof(fmt_size));
  if (ok) ok = WriteAll(file, format.data(), fmt_size);
  if (ok && fmt_padding != 0) ok = WriteAll(file, &zero, 1);
  if (ok) ok = WriteFourCc(file, "data");
  if (ok) ok = WriteAll(file, &data_size, sizeof(data_size));
  if (ok && data_size != 0) ok = WriteAll(file, audio.data(), data_size);
  CloseHandle(file);

  if (!ok) {
    DeleteFileW(wide_path.c_str());
    *error = "unable to write WAV output";
  }
  return ok;
}

class ActivateHandler final
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, FtmBase,
                          IActivateAudioInterfaceCompletionHandler> {
 public:
  ~ActivateHandler() override {
    if (completed_event_ != nullptr) {
      CloseHandle(completed_event_);
    }
  }

  HRESULT RuntimeClassInitialize() {
    completed_event_ = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    return completed_event_ == nullptr
               ? HRESULT_FROM_WIN32(GetLastError())
               : S_OK;
  }

  STDMETHODIMP ActivateCompleted(
      IActivateAudioInterfaceAsyncOperation* operation) override {
    ComPtr<IUnknown> activated;
    HRESULT activate_result = E_FAIL;
    const HRESULT call_result = operation->GetActivateResult(
        &activate_result, activated.GetAddressOf());
    activation_result_ = FAILED(call_result) ? call_result : activate_result;
    if (SUCCEEDED(activation_result_)) {
      activation_result_ = activated.As(&audio_client_);
    }
    SetEvent(completed_event_);
    return S_OK;
  }

  HRESULT GetAudioClient(ComPtr<IAudioClient>* client) const {
    if (FAILED(activation_result_)) {
      return activation_result_;
    }
    *client = audio_client_;
    return audio_client_ ? S_OK : E_NOINTERFACE;
  }

  HANDLE completed_event() const { return completed_event_; }

 private:
  HANDLE completed_event_ = nullptr;
  HRESULT activation_result_ = E_PENDING;
  ComPtr<IAudioClient> audio_client_;
};

HRESULT ActivateProcessLoopback(DWORD process_id, HANDLE stop_event,
                                ComPtr<IAudioClient>* audio_client) {
  ComPtr<ActivateHandler> handler;
  HRESULT hr = MakeAndInitialize<ActivateHandler>(&handler);
  if (FAILED(hr)) {
    return hr;
  }

  AUDIOCLIENT_ACTIVATION_PARAMS activation = {};
  activation.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  activation.ProcessLoopbackParams.TargetProcessId = process_id;
  activation.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;

  PROPVARIANT params = {};
  params.vt = VT_BLOB;
  params.blob.cbSize = sizeof(activation);
  params.blob.pBlobData = reinterpret_cast<BYTE*>(&activation);

  ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  hr = ActivateAudioInterfaceAsync(
      VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &params,
      handler.Get(), operation.GetAddressOf());
  if (SUCCEEDED(hr)) {
    HANDLE waits[] = {stop_event, handler->completed_event()};
    const DWORD wait = WaitForMultipleObjects(2, waits, FALSE,
                                              kActivationTimeoutMs);
    if (wait == WAIT_OBJECT_0) {
      hr = HRESULT_FROM_WIN32(ERROR_CANCELLED);
    } else if (wait == WAIT_OBJECT_0 + 1) {
      hr = handler->GetAudioClient(audio_client);
    } else if (wait == WAIT_TIMEOUT) {
      hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    } else {
      hr = HRESULT_FROM_WIN32(GetLastError());
    }
  }
  return hr;
}

}  // namespace

ProcessAudioCapture::ProcessAudioCapture() = default;

ProcessAudioCapture::~ProcessAudioCapture() {
  Stop();
}

ProcessAudioCaptureResult ProcessAudioCapture::Start(
    DWORD process_id, uint32_t buffer_seconds) {
  Stop();
  ProcessAudioCaptureResult invalid;
  if (process_id == 0) {
    invalid.error = "process id must be positive";
    return invalid;
  }
  buffer_seconds =
      std::clamp(buffer_seconds, kMinBufferSeconds, kMaxBufferSeconds);

  stop_event_ = CreateEvent(nullptr, TRUE, FALSE, nullptr);
  sample_event_ = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  ready_event_ = CreateEvent(nullptr, TRUE, FALSE, nullptr);
  if (stop_event_ == nullptr || sample_event_ == nullptr ||
      ready_event_ == nullptr) {
    invalid.error = "unable to create audio capture events";
    Stop();
    return invalid;
  }

  {
    std::lock_guard<std::mutex> lock(mutex_);
    process_id_ = process_id;
    start_result_ = ProcessAudioCaptureResult();
    last_error_.clear();
  }
  capture_thread_ = std::thread(
      &ProcessAudioCapture::CaptureLoop, this, process_id, buffer_seconds);

  const DWORD wait = WaitForSingleObject(ready_event_, kActivationTimeoutMs);
  if (wait != WAIT_OBJECT_0) {
    invalid.error = wait == WAIT_TIMEOUT ? "audio capture start timed out"
                                         : "audio capture start wait failed";
    Stop();
    return invalid;
  }
  ProcessAudioCaptureResult result;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    result = start_result_;
  }
  if (!result.ok) {
    Stop();
  }
  return result;
}

void ProcessAudioCapture::Stop() {
  if (stop_event_ != nullptr) {
    SetEvent(stop_event_);
  }
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }
  if (stop_event_ != nullptr) CloseHandle(stop_event_);
  if (sample_event_ != nullptr) CloseHandle(sample_event_);
  if (ready_event_ != nullptr) CloseHandle(ready_event_);
  stop_event_ = nullptr;
  sample_event_ = nullptr;
  ready_event_ = nullptr;

  std::lock_guard<std::mutex> lock(mutex_);
  running_ = false;
  process_id_ = 0;
  sample_rate_ = 0;
  channels_ = 0;
  block_align_ = 0;
  absolute_frames_ = 0;
  capacity_frames_ = 0;
  wave_format_.clear();
  ring_.clear();
  markers_.clear();
}

void ProcessAudioCapture::PublishStartResult(
    const ProcessAudioCaptureResult& result) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    start_result_ = result;
    last_error_ = result.error;
  }
  SetEvent(ready_event_);
}

void ProcessAudioCapture::CaptureLoop(DWORD process_id,
                                      uint32_t buffer_seconds) {
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool uninitialize = SUCCEEDED(co);
  if (FAILED(co) && co != RPC_E_CHANGED_MODE) {
    ProcessAudioCaptureResult failed;
    failed.error = HResultText("CoInitializeEx", co);
    PublishStartResult(failed);
    return;
  }

  ComPtr<IAudioClient> audio_client;
  HRESULT hr =
      ActivateProcessLoopback(process_id, stop_event_, &audio_client);
  if (FAILED(hr)) {
    ProcessAudioCaptureResult failed;
    failed.error = HResultText("process loopback activation", hr);
    PublishStartResult(failed);
    if (uninitialize) CoUninitialize();
    return;
  }

  WAVEFORMATEX* mix_format = nullptr;
  hr = audio_client->GetMixFormat(&mix_format);
  if (hr == E_NOTIMPL) {
    // The virtual process-loopback device has no endpoint mix format. Match
    // Microsoft's ApplicationLoopback-compatible implementations with the
    // shared-engine default format used by the process-loopback stream.
    auto* fallback = static_cast<WAVEFORMATEXTENSIBLE*>(
        CoTaskMemAlloc(sizeof(WAVEFORMATEXTENSIBLE)));
    if (fallback == nullptr) {
      hr = E_OUTOFMEMORY;
    } else {
      *fallback = {};
      fallback->Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
      fallback->Format.nChannels = 2;
      fallback->Format.nSamplesPerSec = 48000;
      fallback->Format.wBitsPerSample = 32;
      fallback->Format.nBlockAlign =
          fallback->Format.nChannels * fallback->Format.wBitsPerSample / 8;
      fallback->Format.nAvgBytesPerSec =
          fallback->Format.nSamplesPerSec * fallback->Format.nBlockAlign;
      fallback->Format.cbSize =
          sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
      fallback->Samples.wValidBitsPerSample = 32;
      fallback->dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
      fallback->SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
      mix_format = &fallback->Format;
      hr = S_OK;
    }
  }
  if (FAILED(hr) || mix_format == nullptr || mix_format->nSamplesPerSec == 0 ||
      mix_format->nBlockAlign == 0) {
    ProcessAudioCaptureResult failed;
    failed.error = HResultText("GetMixFormat", hr);
    PublishStartResult(failed);
    if (mix_format != nullptr) CoTaskMemFree(mix_format);
    if (uninitialize) CoUninitialize();
    return;
  }

  hr = audio_client->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0,
      mix_format, nullptr);
  if (SUCCEEDED(hr)) {
    hr = audio_client->SetEventHandle(sample_event_);
  }
  ComPtr<IAudioCaptureClient> capture_client;
  if (SUCCEEDED(hr)) {
    hr = audio_client->GetService(IID_PPV_ARGS(&capture_client));
  }
  if (FAILED(hr)) {
    ProcessAudioCaptureResult failed;
    failed.error = HResultText("audio client initialization", hr);
    PublishStartResult(failed);
    CoTaskMemFree(mix_format);
    if (uninitialize) CoUninitialize();
    return;
  }

  const size_t format_size =
      sizeof(WAVEFORMATEX) + static_cast<size_t>(mix_format->cbSize);
  const uint64_t requested_frames =
      static_cast<uint64_t>(mix_format->nSamplesPerSec) * buffer_seconds;
  const uint64_t max_frames_by_memory =
      kMaxRingBytes / mix_format->nBlockAlign;
  const uint64_t capacity_frames =
      std::max<uint64_t>(1, std::min(requested_frames, max_frames_by_memory));
  {
    std::lock_guard<std::mutex> lock(mutex_);
    sample_rate_ = mix_format->nSamplesPerSec;
    channels_ = mix_format->nChannels;
    block_align_ = mix_format->nBlockAlign;
    capacity_frames_ = capacity_frames;
    wave_format_.assign(reinterpret_cast<const uint8_t*>(mix_format),
                        reinterpret_cast<const uint8_t*>(mix_format) +
                            format_size);
    ring_.assign(static_cast<size_t>(capacity_frames_ * block_align_), 0);
    absolute_frames_ = 0;
    markers_.clear();
  }
  CoTaskMemFree(mix_format);

  hr = audio_client->Start();
  if (FAILED(hr)) {
    ProcessAudioCaptureResult failed;
    failed.error = HResultText("audio client start", hr);
    PublishStartResult(failed);
    if (uninitialize) CoUninitialize();
    return;
  }

  ProcessAudioCaptureResult started;
  started.ok = true;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = true;
    started.sample_rate = sample_rate_;
    started.channels = channels_;
  }
  PublishStartResult(started);

  HANDLE waits[] = {stop_event_, sample_event_};
  bool done = false;
  while (!done) {
    const DWORD wait = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
    if (wait == WAIT_OBJECT_0) {
      break;
    }
    if (wait != WAIT_OBJECT_0 + 1) {
      std::lock_guard<std::mutex> lock(mutex_);
      last_error_ = "audio capture wait failed";
      break;
    }

    while (!done) {
      UINT32 packet_frames = 0;
      hr = capture_client->GetNextPacketSize(&packet_frames);
      if (FAILED(hr)) {
        std::lock_guard<std::mutex> lock(mutex_);
        last_error_ = HResultText("GetNextPacketSize", hr);
        done = true;
        break;
      }
      if (packet_frames == 0) break;

      BYTE* data = nullptr;
      DWORD flags = 0;
      UINT64 device_position = 0;
      UINT64 qpc_position = 0;
      hr = capture_client->GetBuffer(&data, &packet_frames, &flags,
                                     &device_position, &qpc_position);
      if (FAILED(hr)) {
        std::lock_guard<std::mutex> lock(mutex_);
        last_error_ = HResultText("audio capture GetBuffer", hr);
        done = true;
        break;
      }
      AppendPacket(data, packet_frames,
                   (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0);
      hr = capture_client->ReleaseBuffer(packet_frames);
      if (FAILED(hr)) {
        std::lock_guard<std::mutex> lock(mutex_);
        last_error_ = HResultText("audio capture ReleaseBuffer", hr);
        done = true;
      }
    }
  }

  audio_client->Stop();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
  }
  if (uninitialize) CoUninitialize();
}

void ProcessAudioCapture::AppendPacket(const BYTE* data, uint32_t frame_count,
                                       bool silent) {
  if (frame_count == 0) return;
  std::lock_guard<std::mutex> lock(mutex_);
  if (capacity_frames_ == 0 || block_align_ == 0 || ring_.empty()) return;

  const uint32_t original_frames = frame_count;
  uint64_t write_start = absolute_frames_;
  if (frame_count > capacity_frames_) {
    const uint64_t skipped = frame_count - capacity_frames_;
    write_start += skipped;
    if (!silent && data != nullptr) {
      data += skipped * block_align_;
    }
    frame_count = static_cast<uint32_t>(capacity_frames_);
  }

  uint64_t remaining = frame_count;
  uint64_t source_frame = 0;
  while (remaining > 0) {
    const uint64_t ring_frame = (write_start + source_frame) % capacity_frames_;
    const uint64_t contiguous =
        std::min(remaining, capacity_frames_ - ring_frame);
    uint8_t* destination =
        ring_.data() + static_cast<size_t>(ring_frame * block_align_);
    const size_t byte_count = static_cast<size_t>(contiguous * block_align_);
    if (silent || data == nullptr) {
      memset(destination, 0, byte_count);
    } else {
      memcpy(destination,
             data + static_cast<size_t>(source_frame * block_align_),
             byte_count);
    }
    source_frame += contiguous;
    remaining -= contiguous;
  }
  absolute_frames_ += original_frames;
}

ProcessAudioCaptureResult ProcessAudioCapture::Mark(
    const std::string& occurrence_id) {
  ProcessAudioCaptureResult result;
  if (occurrence_id.empty()) {
    result.error = "occurrence id is empty";
    return result;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_) {
    result.error = last_error_.empty() ? "audio capture is not running"
                                       : last_error_;
    return result;
  }
  for (const Marker& marker : markers_) {
    if (marker.id == occurrence_id) {
      result.error = "occurrence id already exists";
      return result;
    }
  }
  markers_.push_back(Marker{occurrence_id, absolute_frames_});
  while (markers_.size() > 2048) {
    markers_.pop_front();
  }
  result.ok = true;
  result.sample_rate = sample_rate_;
  result.channels = channels_;
  result.start_frame = absolute_frames_;
  return result;
}

ProcessAudioCaptureResult ProcessAudioCapture::SnapshotSegment(
    const std::string& occurrence_id, uint32_t pre_roll_ms,
    uint32_t max_clip_ms, std::vector<uint8_t>* format,
    std::vector<uint8_t>* audio) const {
  ProcessAudioCaptureResult result;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_ || capacity_frames_ == 0 || block_align_ == 0) {
    result.error = last_error_.empty() ? "audio capture is not running"
                                       : last_error_;
    return result;
  }

  size_t marker_index = markers_.size();
  for (size_t i = 0; i < markers_.size(); ++i) {
    if (markers_[i].id == occurrence_id) {
      marker_index = i;
      break;
    }
  }
  if (marker_index == markers_.size()) {
    result.error = "audio marker was not found";
    return result;
  }

  const uint64_t marker_frame = markers_[marker_index].frame;
  const uint64_t earliest_frame =
      absolute_frames_ > capacity_frames_ ? absolute_frames_ - capacity_frames_
                                          : 0;
  if (marker_frame < earliest_frame) {
    result.error = "audio marker has expired";
    return result;
  }

  const uint64_t pre_roll_frames =
      static_cast<uint64_t>(sample_rate_) * pre_roll_ms / 1000ULL;
  uint64_t start_frame = marker_frame > pre_roll_frames
                             ? marker_frame - pre_roll_frames
                             : 0;
  start_frame = std::max(start_frame, earliest_frame);

  uint64_t end_frame = absolute_frames_;
  if (marker_index + 1 < markers_.size()) {
    end_frame = std::min(end_frame, markers_[marker_index + 1].frame);
  }
  const uint64_t max_frames =
      static_cast<uint64_t>(sample_rate_) * max_clip_ms / 1000ULL;
  if (max_frames > 0 && end_frame > marker_frame + max_frames) {
    end_frame = marker_frame + max_frames;
  }
  if (end_frame <= start_frame) {
    result.error = "audio segment is empty";
    return result;
  }

  const uint64_t frames = end_frame - start_frame;
  const uint64_t byte_count = frames * block_align_;
  if (byte_count > std::numeric_limits<size_t>::max()) {
    result.error = "audio segment is too large";
    return result;
  }
  format->assign(wave_format_.begin(), wave_format_.end());
  audio->resize(static_cast<size_t>(byte_count));

  uint64_t remaining = frames;
  uint64_t copied_frames = 0;
  while (remaining > 0) {
    const uint64_t ring_frame =
        (start_frame + copied_frames) % capacity_frames_;
    const uint64_t contiguous =
        std::min(remaining, capacity_frames_ - ring_frame);
    memcpy(audio->data() + static_cast<size_t>(copied_frames * block_align_),
           ring_.data() + static_cast<size_t>(ring_frame * block_align_),
           static_cast<size_t>(contiguous * block_align_));
    copied_frames += contiguous;
    remaining -= contiguous;
  }

  result.ok = true;
  result.sample_rate = sample_rate_;
  result.channels = channels_;
  result.start_frame = start_frame;
  result.end_frame = end_frame;
  return result;
}

ProcessAudioCaptureResult ProcessAudioCapture::ExportAudio(
    const std::string& occurrence_id, const std::string& output_path,
    uint32_t pre_roll_ms, uint32_t max_clip_ms) {
  std::vector<uint8_t> format;
  std::vector<uint8_t> audio;
  ProcessAudioCaptureResult result = SnapshotSegment(
      occurrence_id, pre_roll_ms, max_clip_ms, &format, &audio);
  if (!result.ok) return result;

  const bool has_mono_pcm = ConvertWaveToMonoPcm16(&format, &audio);
  if (has_mono_pcm &&
      WriteMp3File(output_path, format, audio, &result.error)) {
    result.path = output_path;
    result.channels = 1;
    return result;
  }

  const std::string mp3_error = result.error;
  const std::string fallback_path = ReplaceExtension(output_path, ".wav");
  if (!WriteWaveFile(fallback_path, format, audio, &result.error)) {
    result.ok = false;
    if (!mp3_error.empty()) {
      result.error = mp3_error + "; WAV fallback: " + result.error;
    }
    return result;
  }
  result.path = fallback_path;
  if (has_mono_pcm) result.channels = 1;
  result.error.clear();
  return result;
}

ProcessAudioCaptureStatus ProcessAudioCapture::Status() const {
  std::lock_guard<std::mutex> lock(mutex_);
  ProcessAudioCaptureStatus status;
  status.running = running_;
  status.process_id = process_id_;
  status.sample_rate = sample_rate_;
  status.channels = channels_;
  status.error = last_error_;
  if (sample_rate_ > 0) {
    status.buffered_seconds = static_cast<uint32_t>(
        std::min<uint64_t>(absolute_frames_, capacity_frames_) / sample_rate_);
  }
  return status;
}

}  // namespace hibiki
