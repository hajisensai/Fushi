#ifndef RUNNER_CLIPBOARD_IMAGE_READER_H_
#define RUNNER_CLIPBOARD_IMAGE_READER_H_

// 读系统剪贴板里的图片：`app.fushi.reader/clipboard_image` 通道的 `readImage`
// （写的那一半 `copyImageFile` 在 flutter_window.cpp）。反馈提交页的「粘贴截图」用。
//
// 三种来源，按优先级：
//   1. CF_HDROP —— 资源管理器里复制的文件，给 UTF-8 绝对路径（是不是图片由 Dart 侧
//      按扩展名过滤）；
//   2. 注册格式 "PNG" —— 浏览器 / 部分截图工具直接放 PNG 字节，原样给（保留透明）；
//   3. CF_DIB / CF_DIBV5 —— QQ / 微信 / Win+Shift+S 等截图放的位图，经 WIC 编成
//      PNG。按 24bpp 编码、**丢掉 alpha**：很多截图工具写的 32bpp DIB 的 alpha 通道
//      全是 0，照着 alpha 解出来是一张全透明的图。

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace fushi_clipboard {

struct ClipboardImage {
  std::vector<uint8_t> bytes;
  std::vector<std::string> paths;

  bool empty() const { return bytes.empty() && paths.empty(); }
};

// 读剪贴板。返回错误描述；成功返回 nullopt（剪贴板里没有图片时 [out] 为空）。
// 调用线程须已初始化 COM（runner 的主线程在 main.cpp 里初始化过）。
std::optional<std::string> ReadClipboardImage(HWND hwnd, ClipboardImage* out);

// 一段 packed DIB（BITMAPINFOHEADER / V4 / V5 + 可选掩码 / 调色板 + 像素）→ PNG。
std::optional<std::string> DibToPng(const uint8_t* dib,
                                    size_t size,
                                    std::vector<uint8_t>* png);

// CF_HDROP → UTF-8 路径列表。
std::vector<std::string> DropFilesToUtf8Paths(HDROP drop);

}  // namespace fushi_clipboard

#endif  // RUNNER_CLIPBOARD_IMAGE_READER_H_
