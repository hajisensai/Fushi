#include "startup_trace.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace fushi {

namespace {

// FILETIME（1601 起的 100ns）→ Unix epoch 微秒。
int64_t FileTimeToEpochMicros(const FILETIME& ft) {
  ULARGE_INTEGER value;
  value.LowPart = ft.dwLowDateTime;
  value.HighPart = ft.dwHighDateTime;
  constexpr int64_t kEpochDifference100ns = 116444736000000000LL;
  return (static_cast<int64_t>(value.QuadPart) - kEpochDifference100ns) / 10;
}

int64_t NowEpochMicros() {
  FILETIME now;
  ::GetSystemTimePreciseAsFileTime(&now);
  return FileTimeToEpochMicros(now);
}

int64_t ProcessStartEpochMicros() {
  FILETIME creation, exit, kernel, user;
  if (!::GetProcessTimes(::GetCurrentProcess(), &creation, &exit, &kernel,
                         &user)) {
    return 0;
  }
  return FileTimeToEpochMicros(creation);
}

std::vector<std::pair<std::string, int64_t>>& Marks() {
  static std::vector<std::pair<std::string, int64_t>> marks;
  return marks;
}

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>& Channel() {
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  return channel;
}

}  // namespace

void StartupTraceMark(const char* phase) {
  Marks().emplace_back(phase, NowEpochMicros());
}

void RegisterStartupTraceChannel(flutter::BinaryMessenger* messenger) {
  Channel() = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "app.fushi.reader/startup_trace",
      &flutter::StandardMethodCodec::GetInstance());
  Channel()->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "get") {
          result->NotImplemented();
          return;
        }
        flutter::EncodableList marks;
        for (const auto& mark : Marks()) {
          marks.emplace_back(flutter::EncodableList{
              flutter::EncodableValue(mark.first),
              flutter::EncodableValue(mark.second),
          });
        }
        result->Success(flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("processStartMicros"),
             flutter::EncodableValue(ProcessStartEpochMicros())},
            {flutter::EncodableValue("marks"),
             flutter::EncodableValue(std::move(marks))},
        }));
      });
}

}  // namespace fushi
