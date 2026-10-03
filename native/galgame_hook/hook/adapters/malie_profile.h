// Malie（light / Greenwood 系）身份探测。
//
// 结构判据：主模块里能从结构唯一解析出名为 "CFI" 的引擎 I/O scheme 表（见
// malie_engine_io_core.h）：UTF-16 名字字面量 → 唯一的逐字拷贝点 → 同一帧函数里
// `lea r,[ebp+T]; push r; call registrar` 的表交接 → T+0..0x1c 六个槽位都是帧函数、
// tell 槽是 `mov eax,[arg+pos]` 的形状、getc 槽直接调用 read 槽、registrar 同时也
// 被别的 scheme（WC_I / TC_I / LFILE_I …）的表构造调用。只用判定结果，槽位一个都不挂。
//
// exe 名、归档文件名、标题与归档密钥都不进判据。旧实现用写死的作品 CFI 密钥去解归档头
// 来认引擎，并在 worker 上自己解密归档取语音——那只认得一个作品系列。现在身份按 exe
// 结构、语音取 Ogg 解码器输入（malie_adapter.inc），密钥常量与解密代码已整体删除。
//
// 判定区分「未匹配」与「镜像未就绪」（malie_engine_io_core.h ProfileState）：首次探测
// 在游戏主线程恢复之前，加壳 / 自解密 exe 此时还没展开，找不到名字字面量或其拷贝点只
// 说明镜像未就绪；镜像（代码与只读节）采样指纹变化后重新判定——由
// MalieLibpAdapter::ProcessPendingEvents 每秒检查一次（registry 不向本 adapter 派发
// onModuleLoaded）。结构性拒绝是终局。
#pragma once

#include <windows.h>

#include <atomic>

#include "malie_engine_io_core.h"
#include "malie_lookup_core.h"

namespace fushi_voice_hook {

struct MalieProfileCache {
  std::atomic<uint32_t> state{
      static_cast<uint32_t>(malie_io::ProfileState::kUnmeasured)};
  std::atomic<uint32_t> last_result{0u};
  uint64_t fingerprint = 0u;     // image fingerprint at the last measurement
  volatile LONG measuring = 0;   // one measurement at a time
};

inline MalieProfileCache& MalieProfile() {
  static MalieProfileCache cache;
  return cache;
}

inline malie_io::ProfileState MalieProfileState() {
  return static_cast<malie_io::ProfileState>(
      MalieProfile().state.load(std::memory_order_acquire));
}

// Measures the identity when it was never measured, or when the image was
// not ready and has changed since.  Returns the state after the call; a
// concurrent caller sees the state as it was.
inline malie_io::ProfileState MeasureMalieProfile() {
  MalieProfileCache& cache = MalieProfile();
  const malie_io::ProfileState state = MalieProfileState();
  if (state == malie_io::ProfileState::kMatched ||
      state == malie_io::ProfileState::kRejected) {
    return state;
  }
  if (InterlockedCompareExchange(&cache.measuring, 1, 0) != 0) return state;
  exact_lookup::LoadedPeImage image;
  malie_io::ProfileState next = state;
  if (!exact_lookup::OpenLoadedPeImage(GetModuleHandleW(nullptr), &image)) {
    next = malie_io::ProfileState::kRejected;
    cache.last_result.store(
        static_cast<uint32_t>(malie_io::SchemeResult::kNotX86),
        std::memory_order_release);
  } else {
    const uint64_t fingerprint = malie_io::ImageFingerprint(image);
    if (malie_io::ShouldMeasureProfile(state, cache.fingerprint, fingerprint)) {
      const malie_io::SchemeResult result =
          malie_io::ResolveScheme(image, malie_io::kArchiveSchemeName);
      cache.fingerprint = fingerprint;
      cache.last_result.store(static_cast<uint32_t>(result),
                              std::memory_order_release);
      next = malie_io::ClassifyScheme(result);
    }
  }
  cache.state.store(static_cast<uint32_t>(next), std::memory_order_release);
  InterlockedExchange(&cache.measuring, 0);
  return next;
}

inline bool MatchesMalieProfile(const wchar_t*) {
  const malie_io::ProfileState state = MalieProfileState();
  if (state != malie_io::ProfileState::kUnmeasured) {
    return state == malie_io::ProfileState::kMatched;
  }
  return MeasureMalieProfile() == malie_io::ProfileState::kMatched;
}

}  // namespace fushi_voice_hook
