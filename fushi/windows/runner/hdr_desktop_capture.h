#ifndef RUNNER_HDR_DESKTOP_CAPTURE_H_
#define RUNNER_HDR_DESKTOP_CAPTURE_H_

#include <windows.h>

#include <d3d11.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <cstdint>
#include <string>
#include <vector>

namespace fushi {

// 截屏识字在「系统开了 HDR 的显示器」上的取帧（BUG：HDR 下截图发白过曝）。
//
// GDI BitBlt 在 HDR 显示器上拿到的是 DWM 合成后被系统粗暴降到 8bit 的帧：SDR 内容
// 按「SDR 内容亮度」抬亮后又没被还原，整屏发白。这里改用 DXGI Desktop Duplication
// （IDXGIOutput5::DuplicateOutput1 + R16G16B16A16_FLOAT）拿 scRGB 原帧，再经
// hdr_tone_map.h 以该显示器的 SDR 白电平为参考白映射回 8bit sRGB。
//
// 选 Desktop Duplication 而不是 WGC CreateForMonitor：同步取帧（不用帧池 + 事件）、
// 不画黄色捕获框（Win10 19045 没有 IGraphicsCaptureSession3，WGC 的黄框关不掉，截
// 一次就闪一次整屏黄框）、FP16 格式由 DuplicateOutput1 直接给。
struct HdrMonitorCapture {
  enum class Status {
    kNotHdr,    // 该显示器没开 HDR：调用方照旧走 BitBlt（零回归）
    kCaptured,  // 成功：bgra 有效
    kFailed,    // 开了 HDR 但取帧失败：调用方回落 BitBlt，detail 写原因
  };
  Status status = Status::kNotHdr;
  // 给诊断日志的一行：成功时是参数摘要，失败时是失败的那一步与 HRESULT。
  std::string detail;
  int width = 0;
  int height = 0;
  std::vector<uint8_t> bgra;  // 32bpp BGRA，alpha = 255，stride = width * 4
};

// 一次截屏的 duplication 会话。两段式是 Desktop Duplication 的硬约束：
// 刚建好的 duplication 第一帧没有桌面图像（LastPresentTime == 0，整帧全黑，本机
// 实测），只有建好之后**该输出上发生过一次合成**的帧才带整屏画面。所以必须在把
// 悬浮球 / 旧冻结层藏起来**之前** Open，藏窗口本身就是那次合成；藏好并 DwmFlush
// 后再 Capture。
// 全部在调用线程同步执行（runner 平台线程），不抛异常。
class HdrMonitorDuplication {
 public:
  HdrMonitorDuplication() = default;
  HdrMonitorDuplication(const HdrMonitorDuplication&) = delete;
  HdrMonitorDuplication& operator=(const HdrMonitorDuplication&) = delete;

  enum class OpenResult {
    kNotHdr,   // 该显示器没开 HDR：调用方照旧走 BitBlt
    kGdiByPolicy,  // 开着 HDR 但按判据走 BitBlt（Windows 11），原因在 |detail|
    kOpened,   // 已建好 duplication，藏好窗口后调 Capture
    kFailed,   // 开了 HDR 但建不起来：回落 BitBlt，原因在 |detail|
  };
  // |monitor| 开着 HDR（DXGI 输出色彩空间 G2084/P2020，与 QueryHdrDisplayInfo 同款
  // 判据）且 hdr_capture_policy 判定走 DXGI（只 Windows 10）时建 FP16 duplication；
  // D3D 设备每次新建、不缓存。kOpened / kGdiByPolicy / kFailed 与（判不了 HDR 时的）
  // kNotHdr 都把路径与原因写进 |detail|。
  OpenResult Open(HMONITOR monitor, std::string* detail);
  bool is_open() const { return duplication_ != nullptr; }

  // 取 Open 之后合成的第一张整屏帧并色调映射；|expected| 是该显示器 rcMonitor
  // （物理像素），帧尺寸不符视为失败。只返回 kCaptured / kFailed。
  HdrMonitorCapture Capture(const RECT& expected);

 private:
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<IDXGIOutputDuplication> duplication_;
  float sdr_white_nits_ = 0.0f;
  float max_luminance_ = 0.0f;
  std::string path_reason_;  // 判据原因，进成功时的诊断摘要
};

}  // namespace fushi

#endif  // RUNNER_HDR_DESKTOP_CAPTURE_H_
