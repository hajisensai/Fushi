#ifndef RUNNER_SYSTEM_OCR_WINDOWS_H_
#define RUNNER_SYSTEM_OCR_WINDOWS_H_

#include <cstdint>
#include <string>
#include <vector>

// `app.fushi.reader/system_ocr` 的 Windows 实现：Windows.Media.Ocr（系统组件，模型随
// 语言包安装，不用我们下载）。契约见 docs/specs/2026-09-30-desktop-system-floating-ball.md
// 「截屏识字」与 fushi/lib/src/ocr/system_ocr_channel.dart 的 parseSystemOcrPayload。
// 纯 WRL/ABI（runner 以 _HAS_EXCEPTIONS=0 编译，不能用 C++/WinRT 投影），全程 HRESULT。
namespace fushi {

struct SystemOcrLine {
  std::string text;  // UTF-8
  // 送检图的像素坐标（左上原点）。
  double left = 0;
  double top = 0;
  double right = 0;
  double bottom = 0;
};

struct SystemOcrResult {
  // 空 = 成功。否则是 PlatformException 的 code：
  //   LANGUAGE_UNAVAILABLE（本机没装这门语言的 OCR 识别器）/ INVALID_IMAGE /
  //   OCR_UNAVAILABLE（系统 OCR 组件取不到）/ RECOGNIZE_FAILED / HOST_CLOSED。
  std::string error_code;
  std::string error_message;
  // 解码后原图的像素尺寸（坐标的分母）。
  int width = 0;
  int height = 0;
  std::vector<SystemOcrLine> lines;
};

// 本机是否有任何可用的识别语言。便宜（只枚举，不识别），可在平台线程调用。
bool SystemOcrIsAvailable();

// 识别一张 PNG / JPEG。阻塞，**只在工作线程调用**（自己 RoInitialize MTA）。
// |language| 是 BCP-47 主标签（`ja` / `en` / `zh`…）。
SystemOcrResult RecognizeImageText(const std::vector<uint8_t>& image_bytes,
                                   const std::string& language);

}  // namespace fushi

#endif  // RUNNER_SYSTEM_OCR_WINDOWS_H_
