// Fushi fork: DXGI video-memory budget query (see dxgi_memory.h).

#include "src/dxgi_memory.h"

#include <cstring>
#include <functional>

#include <dxgi1_4.h>
#include <wrl/client.h>

namespace flutter_onnxruntime {

namespace {

bool FillFromAdapter(IDXGIAdapter1 *adapter, const DXGI_ADAPTER_DESC1 &desc, DeviceMemoryInfo *out) {
  Microsoft::WRL::ComPtr<IDXGIAdapter3> adapter3;
  if (FAILED(adapter->QueryInterface(IID_PPV_ARGS(&adapter3)))) {
    return false;
  }
  DXGI_QUERY_VIDEO_MEMORY_INFO info = {};
  if (FAILED(adapter3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info))) {
    return false;
  }
  out->dedicated_video_memory = static_cast<int64_t>(desc.DedicatedVideoMemory);
  out->budget = static_cast<int64_t>(info.Budget);
  out->current_usage = static_cast<int64_t>(info.CurrentUsage);
  out->is_software = (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
  out->description = desc.Description;
  return true;
}

// Fills [out] from the first adapter (in DXGI enumeration order) that
// [matches]; false when none does.
bool QueryFirstMatching(const std::function<bool(const DXGI_ADAPTER_DESC1 &)> &matches, DeviceMemoryInfo *out) {
  if (out == nullptr) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIFactory4> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    return false;
  }
  for (UINT index = 0;; index++) {
    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
    if (FAILED(factory->EnumAdapters1(index, &adapter)) || adapter == nullptr) {
      // DXGI_ERROR_NOT_FOUND: past the last adapter.
      return false;
    }
    DXGI_ADAPTER_DESC1 desc = {};
    if (FAILED(adapter->GetDesc1(&desc)) || !matches(desc)) {
      continue;
    }
    return FillFromAdapter(adapter.Get(), desc, out);
  }
}

} // namespace

bool QueryDeviceMemoryInfo(int device_id, DeviceMemoryInfo *out) {
  if (out == nullptr) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIFactory4> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
  if (FAILED(factory->EnumAdapters1(static_cast<UINT>(device_id), &adapter))) {
    return false;
  }
  DXGI_ADAPTER_DESC1 desc = {};
  if (FAILED(adapter->GetDesc1(&desc))) {
    return false;
  }
  return FillFromAdapter(adapter.Get(), desc, out);
}

bool QueryDeviceMemoryInfoByLuid(const uint8_t luid[8], DeviceMemoryInfo *out) {
  static_assert(sizeof(LUID) == 8, "LUID is 8 bytes");
  return QueryFirstMatching(
      [luid](const DXGI_ADAPTER_DESC1 &desc) { return std::memcmp(&desc.AdapterLuid, luid, sizeof(LUID)) == 0; }, out);
}

bool QueryDeviceMemoryInfoByVendor(uint32_t vendor_id, DeviceMemoryInfo *out) {
  return QueryFirstMatching(
      [vendor_id](const DXGI_ADAPTER_DESC1 &desc) {
        return desc.VendorId == vendor_id && (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) == 0;
      },
      out);
}

} // namespace flutter_onnxruntime
