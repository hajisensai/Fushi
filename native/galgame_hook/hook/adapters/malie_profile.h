// Malie（light / Greenwood 系）身份探测。
//
// 结构判据：主模块里能从结构唯一解析出名为 "CFI" 的引擎 I/O scheme 表（见
// malie_engine_io_core.h）：UTF-16 名字字面量 → 唯一的逐字拷贝点 → 同一帧函数里
// `lea r,[ebp+T]; push r; call registrar` 的表交接 → T+0..0x1c 六个槽位都是帧函数、
// tell 槽是 `mov eax,[arg+pos]` 的形状、getc 槽直接调用 read 槽、registrar 同时也
// 被别的 scheme（WC_I / TC_I / LFILE_I …）的表构造调用。只用判定结果，槽位一个都不挂。
//
// exe 名、归档文件名、标题与归档密钥都不进判据。旧实现用写死的《Dies irae Amantes
// amentes》CFI 密钥去解 `data2.dat` 头来认引擎，并在 worker 上自己解密归档取语音——那
// 只认得那一个作品系列（同引擎 2016 年的 Kaziklu Bey 解出来不是 LIBP）。现在身份按 exe
// 结构、语音取 Ogg 解码器输入（malie_adapter.inc），密钥常量与解密代码已整体删除。
#pragma once

#include <windows.h>

#include "malie_engine_io_core.h"
#include "malie_lookup_core.h"

namespace fushi_voice_hook {

inline malie_io::SchemeResult ResolveMalieArchiveScheme() {
  exact_lookup::LoadedPeImage image;
  if (!exact_lookup::OpenLoadedPeImage(GetModuleHandleW(nullptr), &image)) {
    return malie_io::SchemeResult::kNotX86;
  }
  return malie_io::ResolveScheme(image, malie_io::kArchiveSchemeName);
}

inline bool MatchesMalieProfile(const wchar_t*) {
  // The image never changes while the process lives; resolve once.
  static const bool matched =
      ResolveMalieArchiveScheme() == malie_io::SchemeResult::kResolved;
  return matched;
}

}  // namespace fushi_voice_hook
