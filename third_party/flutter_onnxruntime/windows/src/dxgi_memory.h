// Hibiki fork: DXGI video-memory budget query.
//
// Static-shape DirectML graphs allocate every intermediate tensor up front and
// keep the pool resident per session; on a card whose budget cannot hold them
// the allocations spill into system memory and throughput collapses instead of
// failing. The Dart side sizes its encoder buckets from this budget before it
// builds any session. Kept free of flutter headers like dml_provider.cc.

#ifndef FLUTTER_ONNXRUNTIME_DXGI_MEMORY_H_
#define FLUTTER_ONNXRUNTIME_DXGI_MEMORY_H_

#include <cstdint>

namespace flutter_onnxruntime {

struct DeviceMemoryInfo {
  int64_t dedicated_video_memory = 0;
  // OS-provided budget for the local (video) memory segment group; this is
  // what the process may allocate before DXGI starts evicting.
  int64_t budget = 0;
  int64_t current_usage = 0;
  bool is_software = false;
};

// Fills [out] for DXGI adapter [device_id]; false if the adapter or the
// IDXGIAdapter3 query interface is unavailable (older OS / no GPU).
bool QueryDeviceMemoryInfo(int device_id, DeviceMemoryInfo *out);

} // namespace flutter_onnxruntime

#endif // FLUTTER_ONNXRUNTIME_DXGI_MEMORY_H_
