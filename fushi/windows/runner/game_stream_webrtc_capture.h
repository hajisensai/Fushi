#ifndef RUNNER_GAME_STREAM_WEBRTC_CAPTURE_H_
#define RUNNER_GAME_STREAM_WEBRTC_CAPTURE_H_

#include <windows.h>

#include <memory>
#include <string>

#include "rtc_types.h"
#include "rtc_video_source.h"

namespace flutter_webrtc_plugin {

class FushiGameStreamCapture {
 public:
  virtual ~FushiGameStreamCapture() = default;

  virtual void Stop() = 0;
  virtual bool IsRunning() const = 0;
  virtual int width() const = 0;
  virtual int height() const = 0;
  virtual std::string error() const = 0;
};

// Starts a Windows.Graphics.Capture session for [hwnd] and pushes cropped,
// scaled I420 frames into [source] via RTCVideoSource::OnCapturedFrame.
//
// Contract:
// - [hwnd] must be a live capturable window. The capture stops itself when the
//   WGC item is closed or IsWindow(hwnd) becomes false.
// - [fps] is clamped to [1, 60]. Frames are sampled from WGC callbacks; the
//   adapter never queues unbounded work and drops callbacks that arrive before
//   the next frame deadline.
// - Output is the client area, scaled to fit inside 1920x1080 while preserving
//   aspect ratio, with even dimensions required by I420.
// - Start waits until the WGC session is established and the first frame has
//   been converted and pushed to [source] (up to 5 seconds). This prevents a
//   false started state when capture can start but no frame can be delivered.
// - Destruction calls Stop(). Stop is idempotent and waits for the native
//   capture thread to tear down frame-pool/session objects.
// - On failure, returns nullptr and writes a human-readable UTF-8 reason to
//   [error] when non-null.
std::shared_ptr<FushiGameStreamCapture> StartFushiGameStreamCapture(
    HWND hwnd, libwebrtc::scoped_refptr<libwebrtc::RTCVideoSource> source,
    int fps, std::string* error);

}  // namespace flutter_webrtc_plugin

#endif  // RUNNER_GAME_STREAM_WEBRTC_CAPTURE_H_
