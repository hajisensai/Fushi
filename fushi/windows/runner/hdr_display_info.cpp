#include "hdr_display_info.h"

#include <dxgi1_6.h>
#include <wrl/client.h>

#include <vector>

namespace fushi {

float QuerySdrWhiteNits(const wchar_t* gdi_device_name) {
  UINT32 path_count = 0;
  UINT32 mode_count = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count,
                                  &mode_count) != ERROR_SUCCESS) {
    return 0.0f;
  }
  std::vector<DISPLAYCONFIG_PATH_INFO> paths(path_count);
  std::vector<DISPLAYCONFIG_MODE_INFO> modes(mode_count);
  if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, paths.data(),
                         &mode_count, modes.data(),
                         nullptr) != ERROR_SUCCESS) {
    return 0.0f;
  }
  for (UINT32 i = 0; i < path_count; ++i) {
    const DISPLAYCONFIG_PATH_INFO& path = paths[i];
    DISPLAYCONFIG_SOURCE_DEVICE_NAME source = {};
    source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
    source.header.size = sizeof(source);
    source.header.adapterId = path.sourceInfo.adapterId;
    source.header.id = path.sourceInfo.id;
    if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS ||
        wcscmp(source.viewGdiDeviceName, gdi_device_name) != 0) {
      continue;
    }
    DISPLAYCONFIG_SDR_WHITE_LEVEL white = {};
    white.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
    white.header.size = sizeof(white);
    white.header.adapterId = path.targetInfo.adapterId;
    white.header.id = path.targetInfo.id;
    if (DisplayConfigGetDeviceInfo(&white.header) != ERROR_SUCCESS) {
      return 0.0f;
    }
    return static_cast<float>(white.SDRWhiteLevel) * 80.0f / 1000.0f;
  }
  return 0.0f;
}

HdrDisplayInfo QueryHdrDisplayInfo(HWND main) {
  using Microsoft::WRL::ComPtr;
  HdrDisplayInfo info;
  if (main == nullptr) {
    return info;
  }
  const HMONITOR monitor = MonitorFromWindow(main, MONITOR_DEFAULTTONEAREST);
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    return info;
  }
  ComPtr<IDXGIAdapter1> adapter;
  for (UINT a = 0; factory->EnumAdapters1(a, &adapter) != DXGI_ERROR_NOT_FOUND;
       ++a) {
    ComPtr<IDXGIOutput> output;
    for (UINT o = 0; adapter->EnumOutputs(o, &output) != DXGI_ERROR_NOT_FOUND;
         ++o) {
      ComPtr<IDXGIOutput6> output6;
      if (FAILED(output.As(&output6))) {
        continue;
      }
      DXGI_OUTPUT_DESC1 desc;
      if (FAILED(output6->GetDesc1(&desc)) || desc.Monitor != monitor) {
        continue;
      }
      info.valid = true;
      info.color_space = static_cast<int>(desc.ColorSpace);
      info.max_luminance = desc.MaxLuminance;
      info.bits_per_color = desc.BitsPerColor;
      info.sdr_white_nits = QuerySdrWhiteNits(desc.DeviceName);
      return info;
    }
  }
  return info;
}

}  // namespace fushi
