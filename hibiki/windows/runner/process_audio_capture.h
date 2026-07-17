#ifndef RUNNER_PROCESS_AUDIO_CAPTURE_H_
#define RUNNER_PROCESS_AUDIO_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace hibiki {

struct ProcessAudioCaptureResult {
  bool ok = false;
  std::string error;
  std::string path;
  uint32_t sample_rate = 0;
  uint16_t channels = 0;
  uint64_t start_frame = 0;
  uint64_t end_frame = 0;
};

struct ProcessAudioCaptureStatus {
  bool running = false;
  DWORD process_id = 0;
  uint32_t sample_rate = 0;
  uint16_t channels = 0;
  uint32_t buffered_seconds = 0;
  std::string error;
};

// Captures the render stream of one process tree into a native PCM ring buffer.
// Dart only creates markers and exports bounded WAV clips; PCM never crosses the
// method channel continuously.
class ProcessAudioCapture {
 public:
  ProcessAudioCapture();
  ~ProcessAudioCapture();

  ProcessAudioCapture(const ProcessAudioCapture&) = delete;
  ProcessAudioCapture& operator=(const ProcessAudioCapture&) = delete;

  ProcessAudioCaptureResult Start(DWORD process_id, uint32_t buffer_seconds);
  void Stop();
  ProcessAudioCaptureResult Mark(const std::string& occurrence_id);
  ProcessAudioCaptureResult ExportWav(const std::string& occurrence_id,
                                      const std::string& output_path,
                                      uint32_t pre_roll_ms,
                                      uint32_t max_clip_ms);
  ProcessAudioCaptureStatus Status() const;

 private:
  struct Marker {
    std::string id;
    uint64_t frame = 0;
  };

  void CaptureLoop(DWORD process_id, uint32_t buffer_seconds);
  void AppendPacket(const BYTE* data, uint32_t frame_count, bool silent);
  void PublishStartResult(const ProcessAudioCaptureResult& result);
  ProcessAudioCaptureResult SnapshotSegment(
      const std::string& occurrence_id, uint32_t pre_roll_ms,
      uint32_t max_clip_ms, std::vector<uint8_t>* format,
      std::vector<uint8_t>* audio) const;

  mutable std::mutex mutex_;
  std::thread capture_thread_;
  HANDLE stop_event_ = nullptr;
  HANDLE sample_event_ = nullptr;
  HANDLE ready_event_ = nullptr;

  bool running_ = false;
  DWORD process_id_ = 0;
  uint32_t sample_rate_ = 0;
  uint16_t channels_ = 0;
  uint16_t block_align_ = 0;
  uint64_t absolute_frames_ = 0;
  uint64_t capacity_frames_ = 0;
  std::vector<uint8_t> wave_format_;
  std::vector<uint8_t> ring_;
  std::deque<Marker> markers_;
  ProcessAudioCaptureResult start_result_;
  std::string last_error_;
};

}  // namespace hibiki

#endif  // RUNNER_PROCESS_AUDIO_CAPTURE_H_
