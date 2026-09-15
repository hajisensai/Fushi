#ifndef RUNNER_CLIPBOARD_IMAGE_CHANNEL_H_
#define RUNNER_CLIPBOARD_IMAGE_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// 复制图片到系统剪贴板：`app.fushi.reader/clipboard_image` 的 Linux 实现。
//
// 这条通道最早只有 Windows 一端（CF_DIB），服务阅读器内联图与插画查看器的
// 「复制图片」；视频截图把它铺到五端，这里补 Linux。方法名与入参逐字对齐
// Windows：`copyImageFile` + `{"path": <本地路径>}`。
//
// 返回新建的 channel，调用方持有引用（用完 g_object_unref）。
FlMethodChannel* fushi_clipboard_image_channel_new(FlBinaryMessenger* messenger);

#endif  // RUNNER_CLIPBOARD_IMAGE_CHANNEL_H_
