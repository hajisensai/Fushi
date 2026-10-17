#ifndef RUNNER_SYSTEM_OCR_CHANNEL_HOST_H_
#define RUNNER_SYSTEM_OCR_CHANNEL_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

#include "system_ocr_windows.h"
#include "worker_reply_queue.h"

namespace fushi {

// `app.fushi.reader/system_ocr` 的 Windows 通道宿主（契约见
// fushi/lib/src/ocr/system_ocr_channel.dart）。识别实现在 system_ocr_windows.cpp。
//
// 单独成文件而不是写进 flutter_window.cpp：flutter_window 是 galgame 应用内查词的
// 路由宿主，`gal_attached_no_ocr_guard_test.dart` 要求那条链路的源码里不出现任何
// OCR 调用；系统 OCR 的通道、工作线程与回话队列整块住在这里，flutter_window 只持有
// 本对象并把计时器消息转过来。
//
// isAvailable 只枚举识别语言，平台线程同步答；recognize 在工作线程识别，结果经
// WorkerReplyQueue 由 |reply_hwnd| 上的计时器投回平台线程回话。`tiles` 忽略（整页
// 识别、行不带下标，Dart 的跨片合并对这种结果是恒等的）；modelStatus 等 Android 专有
// 方法回 NotImplemented（Dart 视为 MissingPluginException = 系统组件、恒就绪）。
class SystemOcrChannelHost {
 public:
  // 全部方法只在平台线程调用。|reply_hwnd| 必须比本对象活得久。
  SystemOcrChannelHost(flutter::BinaryMessenger* messenger, HWND reply_hwnd);
  ~SystemOcrChannelHost();
  SystemOcrChannelHost(const SystemOcrChannelHost&) = delete;
  SystemOcrChannelHost& operator=(const SystemOcrChannelHost&) = delete;

  // 窗口过程收到 WM_TIMER 时调：是本宿主的计时器就投递已完成的回话并返回 true。
  bool HandleTimer(WPARAM timer_id);

  // 撤通道、停计时器；未完成的识别回 HOST_CLOSED（须趁 messenger 还活着调）。
  // 之后才完成的工作线程结果被丢弃。可重复调用。
  void Shutdown();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND reply_hwnd_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<WorkerReplyQueue<SystemOcrResult>> replies_;
};

}  // namespace fushi

#endif  // RUNNER_SYSTEM_OCR_CHANNEL_HOST_H_
