// Fushi fork: DXGI video-memory budget query.
//
// Static-shape DirectML graphs allocate every intermediate tensor up front and
// keep the pool resident per session; on a card whose budget cannot hold them
// the allocations spill into system memory and throughput collapses instead of
// failing. The Dart side sizes its encoder buckets from this budget before it
// builds any session. Kept free of flutter headers like dml_provider.cc.

#ifndef FLUTTER_ONNXRUNTIME_DXGI_MEMORY_H_
#define FLUTTER_ONNXRUNTIME_DXGI_MEMORY_H_

#include <cstdint>
#include <string>

namespace flutter_onnxruntime {

struct DeviceMemoryInfo {
  int64_t dedicated_video_memory = 0;
  // OS-provided budget for the local (video) memory segment group; this is
  // what the process may allocate before DXGI starts evicting.
  int64_t budget = 0;
  int64_t current_usage = 0;
  bool is_software = false;
  // DXGI_ADAPTER_DESC1::Description, for logs.
  std::wstring description;
};

// Fills [out] for DXGI adapter [device_id]; false if the adapter or the
// IDXGIAdapter3 query interface is unavailable (older OS / no GPU).
bool QueryDeviceMemoryInfo(int device_id, DeviceMemoryInfo *out);

// Fills [out] for the adapter whose LUID equals the 8 bytes at [luid] (the
// layout of a Win32 LUID, which is what the CUDA driver reports for a device).
// false when no adapter matches or the query is unavailable.
bool QueryDeviceMemoryInfoByLuid(const uint8_t luid[8], DeviceMemoryInfo *out);

// Fills [out] for the first hardware adapter of PCI vendor [vendor_id]
// (0x10DE = NVIDIA). false when there is none or the query is unavailable.
bool QueryDeviceMemoryInfoByVendor(uint32_t vendor_id, DeviceMemoryInfo *out);

} // namespace flutter_onnxruntime

#endif // FLUTTER_ONNXRUNTIME_DXGI_MEMORY_H_
