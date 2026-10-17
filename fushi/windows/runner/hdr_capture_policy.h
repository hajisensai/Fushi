#ifndef RUNNER_HDR_CAPTURE_POLICY_H_
#define RUNNER_HDR_CAPTURE_POLICY_H_

// 截屏识字取哪条路的判据（BUG-3480，所有者 2026-10-17 拍板）：
// 只有 Windows 10（build < 22000）上开着 HDR 的显示器走 DXGI FP16 取帧 + 色调映射。
// Windows 11 上 GDI BitBlt 读回 HDR 合成帧时系统已按 SDR 白电平还原（本机 build
// 29683 实测 16 级灰阶与 SDR 逐级一致），继续走 BitBlt，零额外耗时。
// 版本号由调用方用 RtlGetVersion 取（不受 manifest 兼容性声明影响）；取不到（0）时
// 保持改动前的 BitBlt 行为。
//
// 不依赖 Windows 头，C++ 单测 tests/hdr_tone_map_test.cpp 直接 include。

#include <cstdint>

namespace fushi {
namespace hdr_capture_policy {

// Windows 11 的第一个 build。
constexpr uint32_t kFirstWindows11Build = 22000;

struct Decision {
  bool use_dxgi = false;
  // 给诊断日志的原因（静态字符串）。
  const char* reason = "";
};

inline Decision Decide(bool monitor_hdr, uint32_t windows_build) {
  if (!monitor_hdr) {
    return {false, "sdr monitor"};
  }
  if (windows_build == 0) {
    return {false, "hdr monitor, windows build unknown: keep gdi"};
  }
  if (windows_build >= kFirstWindows11Build) {
    return {false, "hdr monitor on windows 11: gdi readback is already sdr-correct"};
  }
  return {true, "hdr monitor on windows 10: gdi readback washes out"};
}

}  // namespace hdr_capture_policy
}  // namespace fushi

#endif  // RUNNER_HDR_CAPTURE_POLICY_H_
