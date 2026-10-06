#include "system_transparency_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>

namespace fushi {

bool ReadReduceTransparency() {
  DWORD value = 1;
  DWORD size = sizeof(value);
  const LSTATUS status = ::RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"EnableTransparency", RRF_RT_REG_DWORD, nullptr, &value, &size);
  if (status != ERROR_SUCCESS) {
    return false;
  }
  return value == 0;
}

}  // namespace fushi

namespace {

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>&
TransparencyChannel() {
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  return channel;
}

// 上次推送（或 Dart 读取）的值，用于去重：ImmersiveColorSet 在改深浅色/强调色时
// 也会广播，透明开关没变就不打扰 Dart。只在 platform 线程读写。
bool g_last_reduce_transparency = false;

}  // namespace

void RegisterSystemTransparencyChannel(flutter::BinaryMessenger* messenger) {
  auto& channel = TransparencyChannel();
  if (channel != nullptr || messenger == nullptr) {
    return;
  }
  g_last_reduce_transparency = fushi::ReadReduceTransparency();
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "app.fushi/system_transparency",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "getReduceTransparency") {
          const bool reduce = fushi::ReadReduceTransparency();
          g_last_reduce_transparency = reduce;
          result->Success(flutter::EncodableValue(reduce));
          return;
        }
        result->NotImplemented();
      });
}

void NotifySystemTransparencySettingChanged() {
  auto& channel = TransparencyChannel();
  if (channel == nullptr) {
    return;
  }
  const bool reduce = fushi::ReadReduceTransparency();
  if (reduce == g_last_reduce_transparency) {
    return;
  }
  g_last_reduce_transparency = reduce;
  channel->InvokeMethod("reduceTransparencyChanged",
                        std::make_unique<flutter::EncodableValue>(reduce));
}
