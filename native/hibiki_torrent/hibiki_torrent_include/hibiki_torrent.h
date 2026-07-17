#pragma once

// hibiki_torrent — minimal C ABI bridge over libtorrent 2.x.
//
// 阶段1a walking skeleton：只导出证明工具链（libtorrent 构建 → C ABI →
// Dart FFI）打通所需的最小面，不实现下载/磁力/元数据（那是阶段1b）。
// C ABI 手写（不被 libtorrent 的 BSD 之外任何依赖传染），Dart 侧用 ffigen
// 从本头文件生成绑定，与 hoshidicts 同一 FFI 范式。

// ── Symbol export（与 hoshidicts platform.hpp 一致的做法）────────────
#ifdef _WIN32
#define HT_EXPORT __declspec(dllexport)
#else
#define HT_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// 返回 libtorrent 运行时版本串（如 "2.0.11.0"）。指向 libtorrent 内部静态
// 存储，调用方**不得** free。
HT_EXPORT const char* ht_libtorrent_version(void);

// 创建一个不监听端口、不开 DHT/LSD/UPnP/NAT-PMP 的 libtorrent session，返回
// 不透明句柄；失败返回 NULL。walking skeleton 只为证明 session 类真正链接进
// 来，不承载任何下载语义。
HT_EXPORT void* ht_session_create(void);

// 销毁 ht_session_create 返回的句柄；传 NULL 为 no-op。
HT_EXPORT void ht_session_destroy(void* session);

#ifdef __cplusplus
}
#endif
