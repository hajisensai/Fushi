#include "flutter_screen_capture.h"

// Fushi game-stream patch for flutter_webrtc 1.6.2+hotfix.3.
// Keep getDisplayMedia from returning fake window-capture tracks when the
// native RTCDesktopCapturer refuses to start; remove once upstream propagates
// Start() failures and useful WGC errors through the MethodChannel.
#include "flutter_utf8_sanitize.h"

#include <stdexcept>
#include <cstdio>
#include <cstdarg>
#include <cstdlib>
#ifdef FUSHI_GAME_STREAM_WGC
#include <algorithm>
#include <cmath>
#include <variant>

#include "game_stream_webrtc_capture.h"
#include "game_stream_webrtc_capture_helpers.h"
#endif

namespace flutter_webrtc_plugin {

namespace {
#ifdef FUSHI_GAME_STREAM_WGC
// Reuse the plugin's normal track/stream disposal path. The custom source does
// not own its producer, so keep both WGC and application audio in this owner.
class FushiWindowCaptureOwner : public RTCVideoCapturer {
 public:
  FushiWindowCaptureOwner(std::shared_ptr<FushiGameStreamCapture> capture,
                         std::unique_ptr<LoopbackCapturer> audio)
      : capture_(std::move(capture)), audio_(std::move(audio)) {}
  ~FushiWindowCaptureOwner() override { StopCapture(); }
  bool StartCapture() override { return capture_ && capture_->IsRunning(); }
  bool CaptureStarted() override { return capture_ != nullptr; }
  void StopCapture() override {
    if (capture_) capture_->Stop();
    capture_.reset();
    if (audio_) audio_->Stop();
    audio_.reset();
  }

 private:
  std::shared_ptr<FushiGameStreamCapture> capture_;
  std::unique_ptr<LoopbackCapturer> audio_;
};

// Dart ints arrive as int32/int64 and doubles as double; upstream findDouble /
// findInt each accept only one of them. Returns [fallback] when absent or not
// numeric so optional constraints keep their defaults.
double FushiFindNumber(const EncodableMap& map, const char* key,
                       double fallback) {
  auto it = map.find(EncodableValue(key));
  if (it == map.end()) return fallback;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const auto* l = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*l);
  }
  return fallback;
}
#endif
// Opt-in local diagnostics: GUI runners have no stderr console. Never records
// media or signaling; the caller controls a private evidence path.
void CaptureTrace(const char* format, ...) {
  va_list args;
  va_start(args, format);
  std::vfprintf(stderr, format, args);
  va_end(args);
  std::fflush(stderr);
  FILE* file = nullptr;
#ifdef _WIN32
  char* path = nullptr;
  size_t length = 0;
  if (_dupenv_s(&path, &length, "FUSHI_GAME_STREAM_CAPTURE_TRACE") != 0) return;
  if (path && *path) fopen_s(&file, path, "a");
  std::free(path);
#else
  const char* path = std::getenv("FUSHI_GAME_STREAM_CAPTURE_TRACE");
  if (path && *path) file = std::fopen(path, "a");
#endif
  if (!file) return;
  va_start(args, format);
  std::vfprintf(file, format, args);
  va_end(args);
  std::fclose(file);
}
}  // namespace


FlutterScreenCapture::FlutterScreenCapture(FlutterWebRTCBase* base)
    : base_(base) {}

bool FlutterScreenCapture::BuildDesktopSourcesList(const EncodableList& types,
                                                   bool force_reload) {
  size_t size = types.size();
  sources_.clear();
  for (size_t i = 0; i < size; i++) {
    std::string type_str = GetValue<std::string>(types[i]);
    DesktopType desktop_type = DesktopType::kScreen;
    if (type_str == "screen") {
      desktop_type = DesktopType::kScreen;
    } else if (type_str == "window") {
      desktop_type = DesktopType::kWindow;
    } else {
      return false;
    }
    scoped_refptr<RTCDesktopMediaList> source_list;
    auto it = medialist_.find(desktop_type);
    if (it != medialist_.end()) {
      source_list = (*it).second;
    } else {
      source_list = base_->desktop_device_->GetDesktopMediaList(desktop_type);
      source_list->RegisterMediaListObserver(this);
      medialist_[desktop_type] = source_list;
    }
#ifdef __linux__
    try {
      source_list->UpdateSourceList(force_reload, false);
    } catch (...) {
      continue;
    }
#else
    source_list->UpdateSourceList(force_reload, false);
#endif
    int count = source_list->GetSourceCount();
    for (int j = 0; j < count; j++) {
      sources_.push_back(source_list->GetSource(j));
    }
  }
  return true;
}

void FlutterScreenCapture::GetDesktopSources(
    const EncodableList& types,
    std::unique_ptr<MethodResultProxy> result) {
  if (!BuildDesktopSourcesList(types, true)) {
    result->Error("Bad Arguments", "Failed to get desktop sources");
    return;
  }

  EncodableList sources;
  for (auto source : sources_) {
    EncodableMap info;
    info[EncodableValue("id")] = EncodableValue(source->id().std_string());
    info[EncodableValue("name")] =
        EncodableValue(SanitizeUtf8ForFlutter(source->name().std_string()));
    info[EncodableValue("type")] =
        EncodableValue(source->type() == kWindow ? "window" : "screen");
    // TODO "thumbnailSize"
    info[EncodableValue("thumbnailSize")] = EncodableMap{
        {EncodableValue("width"), EncodableValue(0)},
        {EncodableValue("height"), EncodableValue(0)},
    };
    sources.push_back(EncodableValue(info));
  }

  auto map = EncodableMap();
  map[EncodableValue("sources")] = sources;
  result->Success(EncodableValue(map));
}

void FlutterScreenCapture::UpdateDesktopSources(
    const EncodableList& types,
    std::unique_ptr<MethodResultProxy> result) {
  if (!BuildDesktopSourcesList(types, false)) {
    result->Error("Bad Arguments", "Failed to update desktop sources");
    return;
  }
  auto map = EncodableMap();
  map[EncodableValue("result")] = true;
  result->Success(EncodableValue(map));
}

void FlutterScreenCapture::OnMediaSourceAdded(
    scoped_refptr<MediaSource> source) {
  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceAdded";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  info[EncodableValue("name")] =
      EncodableValue(SanitizeUtf8ForFlutter(source->name().std_string()));
  info[EncodableValue("type")] =
      EncodableValue(source->type() == kWindow ? "window" : "screen");
  // TODO "thumbnailSize"
  info[EncodableValue("thumbnailSize")] = EncodableMap{
      {EncodableValue("width"), EncodableValue(0)},
      {EncodableValue("height"), EncodableValue(0)},
  };
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnMediaSourceRemoved(
    scoped_refptr<MediaSource> source) {
  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceRemoved";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnMediaSourceNameChanged(
    scoped_refptr<MediaSource> source) {
  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceNameChanged";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  info[EncodableValue("name")] =
      EncodableValue(SanitizeUtf8ForFlutter(source->name().std_string()));
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnMediaSourceThumbnailChanged(
    scoped_refptr<MediaSource> source) {
  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceThumbnailChanged";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  info[EncodableValue("thumbnail")] =
      EncodableValue(source->thumbnail().std_vector());
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnStart(scoped_refptr<RTCDesktopCapturer> capturer) {
  CaptureTrace( "[flutter_webrtc_screen_capture] OnStart source=%s running=%d\n",
               capturer && capturer->source() ? capturer->source()->id().std_string().c_str() : "<null>",
               capturer ? static_cast<int>(capturer->IsRunning()) : -1);
}

void FlutterScreenCapture::OnPaused(
    scoped_refptr<RTCDesktopCapturer> capturer) {
  CaptureTrace( "[flutter_webrtc_screen_capture] OnPaused source=%s running=%d\n",
               capturer && capturer->source() ? capturer->source()->id().std_string().c_str() : "<null>",
               capturer ? static_cast<int>(capturer->IsRunning()) : -1);
}

void FlutterScreenCapture::OnStop(scoped_refptr<RTCDesktopCapturer> capturer) {
  CaptureTrace( "[flutter_webrtc_screen_capture] OnStop source=%s running=%d\n",
               capturer && capturer->source() ? capturer->source()->id().std_string().c_str() : "<null>",
               capturer ? static_cast<int>(capturer->IsRunning()) : -1);
  if (loopback_capturer_) {
    loopback_capturer_->Stop();
    loopback_capturer_.reset();
    loopback_audio_source_ = nullptr;
  }
}

void FlutterScreenCapture::OnError(scoped_refptr<RTCDesktopCapturer> capturer) {
  CaptureTrace( "[flutter_webrtc_screen_capture] OnError source=%s running=%d\n",
               capturer && capturer->source() ? capturer->source()->id().std_string().c_str() : "<null>",
               capturer ? static_cast<int>(capturer->IsRunning()) : -1);
}

void FlutterScreenCapture::GetDesktopSourceThumbnail(
    std::string source_id,
    int width,
    int height,
    std::unique_ptr<MethodResultProxy> result) {
  (void)width;
  (void)height;
  scoped_refptr<MediaSource> source;
  for (auto src : sources_) {
    if (src->id().std_string() == source_id) {
      source = src;
    }
  }
  if (source.get() == nullptr) {
    result->Error("Bad Arguments", "Failed to get desktop source thumbnail");
    return;
  }
  source->UpdateThumbnail();
  result->Success(EncodableValue(source->thumbnail().std_vector()));
}

void FlutterScreenCapture::GetDisplayMedia(
    const EncodableMap& constraints,
    std::unique_ptr<MethodResultProxy> result) {
  std::string source_id = "0";
  // DesktopType source_type = kScreen;
  double fps = 30.0;
  // Whether the OS cursor is composited into the captured frames, driven by the
  // getDisplayMedia "cursor" video constraint. Defaults to true so behaviour is
  // unchanged when the constraint is absent — that is libwebrtc's own default.
  bool show_cursor = true;

  const EncodableMap video = findMap(constraints, "video");
  if (video != EncodableMap()) {
    const EncodableMap deviceId = findMap(video, "deviceId");
    if (deviceId != EncodableMap()) {
      source_id = findString(deviceId, "exact");
      if (source_id.empty()) {
        result->Error("Bad Arguments", "Incorrect video->deviceId->exact");
        return;
      }
      if (source_id != "0") {
        // source_type = DesktopType::kWindow;
      }
    }
    const EncodableMap mandatory = findMap(video, "mandatory");
    if (mandatory != EncodableMap()) {
      double frameRate = findDouble(mandatory, "frameRate");
      if (frameRate != 0.0) {
        fps = frameRate;
      }
    }
    // Accept both the spec's string form ("always"/"never") and a plain bool.
    // Only an explicitly supplied constraint moves off the default, so callers
    // that pass no "cursor" key keep exactly the behaviour they have today.
    const std::string cursor = findString(video, "cursor");
    if (!cursor.empty()) {
      show_cursor = (cursor == "always");
    } else if (video.find(EncodableValue("cursor")) != video.end()) {
      show_cursor = findBoolean(video, "cursor");
    }
  }

  std::string uuid = base_->GenerateUUID();

  scoped_refptr<RTCMediaStream> stream =
      base_->factory_->CreateStream(uuid.c_str());

  EncodableMap params;
  params[EncodableValue("streamId")] = EncodableValue(uuid);

  // AUDIO

  bool capture_audio = false;
  {
    auto audio_it = constraints.find(EncodableValue("audio"));
    if (audio_it != constraints.end()) {
      if (TypeIs<bool>(audio_it->second)) {
        capture_audio = GetValue<bool>(audio_it->second);
      } else if (TypeIs<EncodableMap>(audio_it->second)) {
        capture_audio = true;
      }
    }
  }

  if (capture_audio) {
    // Stop any previous loopback session before starting a new one.
    if (loopback_capturer_) {
      loopback_capturer_->Stop();
      loopback_capturer_.reset();
    }

    // Disable all audio processing for loopback capture.  Echo cancellation,
    // AGC, and noise suppression are designed for microphone input; applied to
    // system audio they treat the captured content as echo/noise and destroy it.
    RTCAudioOptions loopback_opts;
    loopback_opts.echo_cancellation = false;
    loopback_opts.auto_gain_control = false;
    loopback_opts.noise_suppression = false;
    const std::string loopback_source_label =
      "screen_loopback_input_" + base_->GenerateUUID();
    loopback_audio_source_ = base_->factory_->CreateAudioSource(
      loopback_source_label.c_str(), RTCAudioSource::SourceType::kCustom,
        loopback_opts);

    std::string audio_uuid = base_->GenerateUUID();
    scoped_refptr<RTCAudioTrack> audio_track =
        base_->factory_->CreateAudioTrack(loopback_audio_source_,
                                          audio_uuid.c_str());

    loopback_capturer_ = CreateLoopbackCapturer(source_id);

    if (loopback_capturer_ && loopback_capturer_->Start(loopback_audio_source_)) {
      EncodableMap audio_info;
      audio_info[EncodableValue("id")] =
          EncodableValue(audio_track->id().std_string());
      audio_info[EncodableValue("label")] =
          EncodableValue(audio_track->id().std_string());
      audio_info[EncodableValue("kind")] =
          EncodableValue(audio_track->kind().std_string());
      audio_info[EncodableValue("enabled")] =
          EncodableValue(audio_track->enabled());

      EncodableList audioTracks;
      audioTracks.push_back(EncodableValue(audio_info));
      params[EncodableValue("audioTracks")] = EncodableValue(audioTracks);

      stream->AddTrack(audio_track);
      base_->local_tracks_[audio_track->id().std_string()] = audio_track;
    } else {
      // Loopback init failed or not supported — continue without audio.
      loopback_capturer_.reset();
      loopback_audio_source_ = nullptr;
      params[EncodableValue("audioTracks")] = EncodableValue(EncodableList());
    }
  } else {
    params[EncodableValue("audioTracks")] = EncodableValue(EncodableList());
  }

  const auto discard_audio = [&] {
    if (!capture_audio) return;
    if (loopback_capturer_) loopback_capturer_->Stop();
    loopback_capturer_.reset();
    loopback_audio_source_ = nullptr;
    for (const auto& audio_track : stream->audio_tracks().std_vector()) {
      base_->local_tracks_.erase(audio_track->id().std_string());
      stream->RemoveTrack(audio_track);
    }
  };

  // VIDEO

  EncodableMap video_constraints;
  auto it = constraints.find(EncodableValue("video"));
  if (it != constraints.end() && TypeIs<EncodableMap>(it->second)) {
    video_constraints = GetValue<EncodableMap>(it->second);
  }

  scoped_refptr<MediaSource> source;
  for (auto src : sources_) {
    if (src->id().std_string() == source_id) {
      source = src;
    }
  }

#ifdef __linux__
  // If the caller didn't specify a source (source_id == "0"), fall back to
  // the first available screen. When a specific source_id was requested but
  // isn't in the (possibly stale) cached list, rebuild the list and retry
  // the match instead of silently capturing the wrong source.
  if (!source.get() && !sources_.empty() && source_id == "0") {
    source = sources_.front();
  }
  if (!source.get()) {
    EncodableList types;
    types.push_back(EncodableValue(std::string("screen")));
    BuildDesktopSourcesList(types, true);
    for (auto src : sources_) {
      if (src->id().std_string() == source_id) {
        source = src;
      }
    }
    if (!source.get() && !sources_.empty() && source_id == "0") {
      source = sources_.front();
    }
  }
#endif

  if (!source.get()) {
    discard_audio();
    result->Error("Bad Arguments", "source not found!");
    return;
  }

#ifdef FUSHI_GAME_STREAM_WGC
  if (findBoolean(video, "fushiClientArea")) {
    if (source->type() != kWindow) {
      discard_audio();
      result->Error("WindowCaptureFailed", "A game window is required");
      return;
    }
    char* end = nullptr;
    const auto window_id = std::strtoull(source_id.c_str(), &end, 10);
    if (!window_id || !end || *end) {
      discard_audio();
      result->Error("WindowCaptureFailed", "Invalid window ID");
      return;
    }
    auto custom_source = base_->factory_->CreateCustomVideoSource(
        "fushi_window_client", RTCMediaConstraints::Create());
    if (!custom_source) {
      discard_audio();
      result->Error("WindowCaptureFailed", "Video source unavailable");
      return;
    }
    // video.mandatory {frameRate, maxWidth, maxHeight}: frameRate is clamped
    // to 1..120 and the output caps to 320x180..3840x2160 (absent caps select
    // 1920x1080) inside the adapter. Read numbers of either Dart int or double
    // shape here; upstream's findDouble drops an int frameRate silently.
    const EncodableMap fushi_mandatory = findMap(video, "mandatory");
    const double fushi_fps_value =
        FushiFindNumber(fushi_mandatory, "frameRate", fps);
    const int fushi_fps = ClampCaptureFps(static_cast<int>(
        std::isfinite(fushi_fps_value) ? std::lround(fushi_fps_value) : 30));
    const double fushi_max_w =
        FushiFindNumber(fushi_mandatory, "maxWidth", 0.0);
    const double fushi_max_h =
        FushiFindNumber(fushi_mandatory, "maxHeight", 0.0);
    auto to_extent = [](double value) -> int {
      if (!std::isfinite(value) || value <= 0.0) return 0;
      return static_cast<int>((std::min)(value, 100000.0));
    };
    std::string error;
    auto capture = StartFushiGameStreamCapture(
        reinterpret_cast<HWND>(static_cast<uintptr_t>(window_id)),
        custom_source, fushi_fps, to_extent(fushi_max_w),
        to_extent(fushi_max_h), &error);
    if (!capture) {
      discard_audio();
      result->Error("WindowCaptureFailed", error);
      return;
    }
    auto track = base_->factory_->CreateVideoTrack(custom_source, uuid.c_str());
    base_->video_capturers_[uuid] = new RefCountedObject<FushiWindowCaptureOwner>(
        capture, std::move(loopback_capturer_));
    loopback_audio_source_ = nullptr;
    EncodableMap settings{
        {EncodableValue("width"), EncodableValue(capture->width())},
        {EncodableValue("height"), EncodableValue(capture->height())},
        {EncodableValue("frameRate"),
         EncodableValue(static_cast<double>(fushi_fps))},
        {EncodableValue("fushiClientArea"), EncodableValue(true)}};
    EncodableMap info{
        {EncodableValue("id"), EncodableValue(track->id().std_string())},
        {EncodableValue("label"), EncodableValue("Game window")},
        {EncodableValue("kind"), EncodableValue("video")},
        {EncodableValue("enabled"), EncodableValue(true)},
        {EncodableValue("settings"), EncodableValue(settings)}};
    params[EncodableValue("videoTracks")] = EncodableList{EncodableValue(info)};
    stream->AddTrack(track);
    base_->local_tracks_[uuid] = track;
    base_->local_streams_[uuid] = stream;
    result->Success(EncodableValue(params));
    return;
  }
#endif

  scoped_refptr<RTCDesktopCapturer> desktop_capturer =
      base_->desktop_device_->CreateDesktopCapturer(source, show_cursor);

  if (!desktop_capturer.get()) {
    discard_audio();
    result->Error("Bad Arguments", "CreateDesktopCapturer failed!");
    return;
  }

  desktop_capturer->RegisterDesktopCapturerObserver(this);

  const char* video_source_label = "screen_capture_input";

  scoped_refptr<RTCVideoSource> video_source =
      base_->factory_->CreateDesktopSource(
          desktop_capturer, video_source_label,
          base_->ParseMediaConstraints(video_constraints));

  // TODO: RTCVideoSource -> RTCVideoTrack

  scoped_refptr<RTCVideoTrack> track =
      base_->factory_->CreateVideoTrack(video_source, uuid.c_str());

  EncodableList videoTracks;
  EncodableMap info;
  info[EncodableValue("id")] = EncodableValue(track->id().std_string());
  info[EncodableValue("label")] = EncodableValue(track->id().std_string());
  info[EncodableValue("kind")] = EncodableValue(track->kind().std_string());
  info[EncodableValue("enabled")] = EncodableValue(track->enabled());
  videoTracks.push_back(EncodableValue(info));
  params[EncodableValue("videoTracks")] = EncodableValue(videoTracks);

  stream->AddTrack(track);

  base_->local_tracks_[track->id().std_string()] = track;

  base_->local_streams_[uuid] = stream;

  RTCDesktopCapturer::CaptureState capture_state =
      desktop_capturer->Start(uint32_t(fps));
  CaptureTrace(
               "[flutter_webrtc_screen_capture] Start source_id=%s fps=%u state=%d running=%d show_cursor=%d\n",
               source_id.c_str(), static_cast<unsigned>(uint32_t(fps)),
               static_cast<int>(capture_state),
               static_cast<int>(desktop_capturer->IsRunning()),
               static_cast<int>(show_cursor));

  if (capture_state != RTCDesktopCapturer::CaptureState::CS_RUNNING) {
    const char* state_name =
        capture_state == RTCDesktopCapturer::CaptureState::CS_STOPPED
            ? "stopped"
            : "failed";
    CaptureTrace(
                 "[flutter_webrtc_screen_capture] Start failed source_id=%s state=%s; cleaning up fake tracks\n",
                 source_id.c_str(), state_name);
      desktop_capturer->Stop();
    stream->RemoveTrack(track);
    base_->local_tracks_.erase(track->id().std_string());
    discard_audio();
    base_->local_streams_.erase(uuid);
    result->Error("DesktopCapturerStartFailed",
                  std::string("Desktop capturer start ") + state_name);
    return;
  }

  result->Success(EncodableValue(params));
}

}  // namespace flutter_webrtc_plugin
