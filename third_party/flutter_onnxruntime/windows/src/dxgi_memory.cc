// Hibiki fork: DXGI video-memory budget query (see dxgi_memory.h).

#include "src/dxgi_memory.h"

#include <dxgi1_4.h>
#include <wrl/client.h>

namespace flutter_onnxruntime {

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
  Microsoft::WRL::ComPtr<IDXGIAdapter3> adapter3;
  if (FAILED(adapter.As(&adapter3))) {
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
  return true;
}

} // namespace flutter_onnxruntime
