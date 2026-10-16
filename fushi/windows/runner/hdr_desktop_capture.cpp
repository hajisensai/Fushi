#include "hdr_desktop_capture.h"

#include <cstdio>
#include <utility>

#include "hdr_capture_policy.h"
#include "hdr_tone_map.h"
#include "hdr_video_host_window.h"

namespace fushi {

namespace {

using Microsoft::WRL::ComPtr;

// 上限同 screen_ocr_overlay 的 BitBlt 路径（128 MiB 的 8bit 帧）。
constexpr uint64_t kMaxPixels = 128ull * 1024 * 1024 / 4;
// 等「Open 之后第一次合成」的总预算。藏悬浮球那次合成在 Capture 前已经 DwmFlush
// 过，正常是立即返回；等不到（目标屏上没有任何变化）就回落 BitBlt，不让平台线程
// 长时间卡住。
constexpr ULONGLONG kAcquireBudgetMs = 300;

std::string HrStep(const char* step, HRESULT hr) {
  char buffer[96];
  std::snprintf(buffer, sizeof(buffer), "%s hr=0x%08lX", step,
                static_cast<unsigned long>(hr));
  return buffer;
}

// 真实 OS build 号。RtlGetVersion 不受 manifest 兼容性声明影响（GetVersionEx 会
// 被「兼容到 Win8.1」之类的 manifest 骗）；取不到返回 0。
uint32_t QueryWindowsBuild() {
  using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) {
    return 0;
  }
  const auto rtl_get_version = reinterpret_cast<RtlGetVersionFn>(
      GetProcAddress(ntdll, "RtlGetVersion"));
  if (rtl_get_version == nullptr) {
    return 0;
  }
  RTL_OSVERSIONINFOW info = {};
  info.dwOSVersionInfoSize = sizeof(info);
  if (rtl_get_version(&info) != 0) {
    return 0;
  }
  return static_cast<uint32_t>(info.dwBuildNumber);
}

HdrMonitorCapture Failed(std::string detail) {
  HdrMonitorCapture out;
  out.status = HdrMonitorCapture::Status::kFailed;
  out.detail = std::move(detail);
  return out;
}

// 帧拿到后必须 ReleaseFrame，失败分支也一样。
class FrameGuard {
 public:
  explicit FrameGuard(IDXGIOutputDuplication* dup) : dup_(dup) {}
  ~FrameGuard() {
    if (dup_ != nullptr) dup_->ReleaseFrame();
  }
  FrameGuard(const FrameGuard&) = delete;
  FrameGuard& operator=(const FrameGuard&) = delete;

 private:
  IDXGIOutputDuplication* dup_;
};

}  // namespace

HdrMonitorDuplication::OpenResult HdrMonitorDuplication::Open(
    HMONITOR monitor, std::string* detail) {
  using Status = OpenResult;
  // 失败原因接在路径判据后面（判据之前不会走到 fail）。
  auto fail = [detail](const std::string& reason) {
    if (detail != nullptr) *detail = *detail + "; " + reason;
    return Status::kFailed;
  };
  if (monitor == nullptr) {
    return Status::kNotHdr;
  }

  // 1. 找这块显示器的 DXGI 输出，按 QueryHdrDisplayInfo 同款判据判 HDR。
  ComPtr<IDXGIFactory1> factory;
  HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    // 连 DXGI 都起不来就判不了 HDR：按 SDR 走老路，但把原因带出去。
    if (detail != nullptr) *detail = HrStep("CreateDXGIFactory1", hr);
    return Status::kNotHdr;
  }
  ComPtr<IDXGIAdapter1> adapter;
  ComPtr<IDXGIOutput6> output6;
  DXGI_OUTPUT_DESC1 desc = {};
  for (UINT a = 0;
       output6 == nullptr &&
       factory->EnumAdapters1(a, adapter.ReleaseAndGetAddressOf()) !=
           DXGI_ERROR_NOT_FOUND;
       ++a) {
    ComPtr<IDXGIOutput> output;
    for (UINT o = 0; adapter->EnumOutputs(o, output.ReleaseAndGetAddressOf()) !=
                     DXGI_ERROR_NOT_FOUND;
         ++o) {
      ComPtr<IDXGIOutput6> candidate;
      if (FAILED(output.As(&candidate))) {
        continue;
      }
      DXGI_OUTPUT_DESC1 candidate_desc;
      if (FAILED(candidate->GetDesc1(&candidate_desc)) ||
          candidate_desc.Monitor != monitor) {
        continue;
      }
      output6 = candidate;
      desc = candidate_desc;
      break;
    }
  }
  if (output6 == nullptr ||
      desc.ColorSpace != DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020) {
    return Status::kNotHdr;
  }

  // 显示器开着 HDR：按 OS 版本决定走不走 DXGI（只 Windows 10）。
  const uint32_t build = QueryWindowsBuild();
  const hdr_capture_policy::Decision decision =
      hdr_capture_policy::Decide(true, build);
  {
    char buffer[160];
    std::snprintf(buffer, sizeof(buffer), "%s (build %u)", decision.reason,
                  static_cast<unsigned>(build));
    if (detail != nullptr) *detail = buffer;
    path_reason_ = buffer;
  }
  if (!decision.use_dxgi) {
    return Status::kGdiByPolicy;
  }

  // 从这里起走 DXGI：任何一步失败都回 kFailed（调用方回落 BitBlt）。
  if (desc.Rotation != DXGI_MODE_ROTATION_IDENTITY &&
      desc.Rotation != DXGI_MODE_ROTATION_UNSPECIFIED) {
    // 旋转屏的 duplication 帧是未旋转的面，这里不做转置。
    return fail("rotated output unsupported");
  }

  // 2. 在同一块适配器上建 D3D11 设备（DuplicateOutput1 要求设备与输出同适配器）。
  hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
                         nullptr, 0, D3D11_SDK_VERSION, &device_, nullptr,
                         &context_);
  if (FAILED(hr)) {
    return fail(HrStep("D3D11CreateDevice", hr));
  }

  // 3. FP16 duplication（Win10 1803+；进程须 Per-Monitor V2 DPI 感知，runner
  //    清单已声明）。
  ComPtr<IDXGIOutput5> output5;
  hr = output6.As(&output5);
  if (FAILED(hr)) {
    return fail(HrStep("IDXGIOutput5", hr));
  }
  const DXGI_FORMAT formats[] = {DXGI_FORMAT_R16G16B16A16_FLOAT};
  hr = output5->DuplicateOutput1(device_.Get(), 0, 1, formats, &duplication_);
  if (FAILED(hr)) {
    duplication_.Reset();
    return fail(HrStep("DuplicateOutput1", hr));
  }
  DXGI_OUTDUPL_DESC dupl_desc = {};
  duplication_->GetDesc(&dupl_desc);
  if (dupl_desc.ModeDesc.Format != DXGI_FORMAT_R16G16B16A16_FLOAT) {
    duplication_.Reset();
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "duplication format %d",
                  static_cast<int>(dupl_desc.ModeDesc.Format));
    return fail(buffer);
  }
  sdr_white_nits_ = QuerySdrWhiteNits(desc.DeviceName);
  max_luminance_ = desc.MaxLuminance;
  return Status::kOpened;
}

HdrMonitorCapture HdrMonitorDuplication::Capture(const RECT& expected) {
  if (duplication_ == nullptr) {
    return Failed("duplication not open");
  }
  const int width = expected.right - expected.left;
  const int height = expected.bottom - expected.top;
  if (width <= 0 || height <= 0 ||
      static_cast<uint64_t>(width) * static_cast<uint64_t>(height) >
          kMaxPixels) {
    return Failed("monitor rect out of range");
  }

  // 4. 取 Open 之后合成的第一帧。LastPresentTime == 0 的帧只有鼠标更新、
  //    不带桌面图像（建好后的第一帧就是这样，整帧全黑），跳过。
  const ULONGLONG started = GetTickCount64();
  const ULONGLONG deadline = started + kAcquireBudgetMs;
  ComPtr<IDXGIResource> resource;
  DXGI_OUTDUPL_FRAME_INFO frame_info = {};
  int skipped = 0;
  for (;;) {
    const ULONGLONG now = GetTickCount64();
    const UINT timeout =
        now >= deadline ? 0 : static_cast<UINT>(deadline - now);
    resource.Reset();
    HRESULT hr =
        duplication_->AcquireNextFrame(timeout, &frame_info, &resource);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer),
                    "no desktop frame within %llums (skipped %d)",
                    kAcquireBudgetMs, skipped);
      return Failed(buffer);
    }
    if (FAILED(hr)) {
      return Failed(HrStep("AcquireNextFrame", hr));
    }
    if (frame_info.LastPresentTime.QuadPart != 0) {
      break;
    }
    duplication_->ReleaseFrame();
    ++skipped;
    // 只有鼠标更新的帧可能连着来：预算同样约束这条支路。
    if (GetTickCount64() >= deadline) {
      char buffer[96];
      std::snprintf(buffer, sizeof(buffer),
                    "only pointer updates within %llums (skipped %d)",
                    kAcquireBudgetMs, skipped);
      return Failed(buffer);
    }
  }
  FrameGuard frame_guard(duplication_.Get());
  const ULONGLONG acquired = GetTickCount64();
  ComPtr<ID3D11Texture2D> frame;
  HRESULT hr = resource.As(&frame);
  if (FAILED(hr)) {
    return Failed(HrStep("frame texture", hr));
  }
  D3D11_TEXTURE2D_DESC tex_desc = {};
  frame->GetDesc(&tex_desc);
  if (static_cast<int>(tex_desc.Width) != width ||
      static_cast<int>(tex_desc.Height) != height ||
      tex_desc.Format != DXGI_FORMAT_R16G16B16A16_FLOAT) {
    char buffer[128];
    std::snprintf(buffer, sizeof(buffer),
                  "frame %ux%u fmt %d != monitor %dx%d", tex_desc.Width,
                  tex_desc.Height, static_cast<int>(tex_desc.Format), width,
                  height);
    return Failed(buffer);
  }

  // 5. 拷到 CPU 可读的暂存纹理。
  D3D11_TEXTURE2D_DESC staging_desc = tex_desc;
  staging_desc.Usage = D3D11_USAGE_STAGING;
  staging_desc.BindFlags = 0;
  staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  staging_desc.MiscFlags = 0;
  staging_desc.MipLevels = 1;
  staging_desc.ArraySize = 1;
  ComPtr<ID3D11Texture2D> staging;
  hr = device_->CreateTexture2D(&staging_desc, nullptr, &staging);
  if (FAILED(hr)) {
    return Failed(HrStep("CreateTexture2D staging", hr));
  }
  context_->CopyResource(staging.Get(), frame.Get());
  D3D11_MAPPED_SUBRESOURCE mapped = {};
  hr = context_->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
  if (FAILED(hr)) {
    return Failed(HrStep("Map staging", hr));
  }

  const ULONGLONG mapped_at = GetTickCount64();
  // 6. scRGB → 8bit sRGB。
  HdrMonitorCapture out;
  out.bgra.resize(static_cast<size_t>(width) * height * 4);
  const hdr_tone_map::ToneMapStats stats = hdr_tone_map::ToneMapScRgbToBgra8(
      static_cast<const uint8_t*>(mapped.pData), mapped.RowPitch, width,
      height, sdr_white_nits_, out.bgra.data());
  context_->Unmap(staging.Get(), 0);
  const ULONGLONG done = GetTickCount64();

  out.status = HdrMonitorCapture::Status::kCaptured;
  out.width = width;
  out.height = height;
  char buffer[384];
  std::snprintf(
      buffer, sizeof(buffer),
      "dxgi path: %s; fp16 %dx%d sdr_white=%.0fnit%s peak=%.2f "
      "max_lum=%.0f skipped=%d acquire=%llums copy=%llums tonemap=%llums",
      path_reason_.c_str(), width, height, sdr_white_nits_,
      sdr_white_nits_ > 0.0f ? "" : "(fallback 80)", stats.peak,
      max_luminance_, skipped, acquired - started, mapped_at - acquired,
      done - mapped_at);
  out.detail = buffer;
  return out;
}

}  // namespace fushi
