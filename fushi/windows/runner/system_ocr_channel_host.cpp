#include "system_ocr_channel_host.h"

#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace fushi {

namespace {

// 回话计时器（工作线程识别完，平台线程回话）。
constexpr UINT_PTR kSystemOcrReplyTimerId = 0x46534F43;  // 'FSOC'
constexpr UINT kSystemOcrReplyTickMs = 16;

const flutter::EncodableValue* FindArg(const flutter::EncodableMap* args,
                                       const char* key) {
  if (args == nullptr) return nullptr;
  const auto it = args->find(flutter::EncodableValue(key));
  return it == args->end() ? nullptr : &it->second;
}

std::string StringArg(const flutter::EncodableMap* args, const char* key,
                      const std::string& fallback) {
  const flutter::EncodableValue* value = FindArg(args, key);
  const auto* s = value == nullptr ? nullptr : std::get_if<std::string>(value);
  return s != nullptr ? *s : fallback;
}

flutter::EncodableValue SystemOcrReplyMap(const SystemOcrResult& ocr) {
  flutter::EncodableList lines;
  lines.reserve(ocr.lines.size());
  for (const SystemOcrLine& line : ocr.lines) {
    // 不带 `vertical`：由 Dart 的 inferSystemOcrVertical 按包围盒推断。
    lines.push_back(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("text"), flutter::EncodableValue(line.text)},
        {flutter::EncodableValue("left"), flutter::EncodableValue(line.left)},
        {flutter::EncodableValue("top"), flutter::EncodableValue(line.top)},
        {flutter::EncodableValue("right"), flutter::EncodableValue(line.right)},
        {flutter::EncodableValue("bottom"),
         flutter::EncodableValue(line.bottom)},
    }));
  }
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("width"),
       flutter::EncodableValue(static_cast<int32_t>(ocr.width))},
      {flutter::EncodableValue("height"),
       flutter::EncodableValue(static_cast<int32_t>(ocr.height))},
      {flutter::EncodableValue("lines"),
       flutter::EncodableValue(std::move(lines))},
  });
}

}  // namespace

SystemOcrChannelHost::SystemOcrChannelHost(flutter::BinaryMessenger* messenger,
                                           HWND reply_hwnd)
    : reply_hwnd_(reply_hwnd) {
  replies_ = std::make_unique<WorkerReplyQueue<SystemOcrResult>>([] {
    SystemOcrResult cancelled;
    cancelled.error_code = "HOST_CLOSED";
    cancelled.error_message = "system OCR host closed";
    return cancelled;
  });
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "app.fushi.reader/system_ocr",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

SystemOcrChannelHost::~SystemOcrChannelHost() { Shutdown(); }

void SystemOcrChannelHost::Shutdown() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  KillTimer(reply_hwnd_, kSystemOcrReplyTimerId);
  if (replies_) {
    // 未完成的识别回 HOST_CLOSED（messenger 此刻还活着）；之后才完成的结果丢弃。
    replies_->Close();
    replies_.reset();
  }
  channel_.reset();
}

bool SystemOcrChannelHost::HandleTimer(WPARAM timer_id) {
  if (timer_id != kSystemOcrReplyTimerId) {
    return false;
  }
  if (replies_) {
    replies_->Drain();
  }
  if (!replies_ || replies_->empty()) {
    KillTimer(reply_hwnd_, kSystemOcrReplyTimerId);
  }
  return true;
}

void SystemOcrChannelHost::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "isAvailable") {
    result->Success(flutter::EncodableValue(SystemOcrIsAvailable()));
    return;
  }
  if (method != "recognize") {
    result->NotImplemented();
    return;
  }
  if (!replies_) {
    result->Error("HOST_CLOSED", "system OCR host closed");
    return;
  }
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const auto* bytes_value = FindArg(args, "bytes");
  const auto* bytes = bytes_value == nullptr
                          ? nullptr
                          : std::get_if<std::vector<uint8_t>>(bytes_value);
  if (bytes == nullptr || bytes->empty()) {
    result->Error("INVALID_IMAGE", "missing image bytes");
    return;
  }
  const std::string language = StringArg(args, "language", "ja");
  if (replies_->empty() &&
      SetTimer(reply_hwnd_, kSystemOcrReplyTimerId, kSystemOcrReplyTickMs,
               nullptr) == 0) {
    result->Error("RECOGNIZE_FAILED", "could not schedule OCR completion");
    return;
  }
  auto reply = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
      std::move(result));
  auto completion = replies_->Enqueue([reply](SystemOcrResult ocr) {
    if (!ocr.error_code.empty()) {
      reply->Error(ocr.error_code, ocr.error_message);
      return;
    }
    reply->Success(SystemOcrReplyMap(ocr));
  });
  if (completion) {
    std::thread([image = *bytes, language, completion]() {
      completion->Publish(RecognizeImageText(image, language));
    }).detach();
  }
}

}  // namespace fushi
