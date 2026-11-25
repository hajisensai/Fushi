// Fushi fork: CUDA support for the Windows plugin.
//
// Two independent pieces live here:
//
//   * ProbeCudaDriver(): asks the NVIDIA *driver* (nvcuda.dll, shipped with the
//     display driver, never with us) which CUDA devices exist and which CUDA
//     version the driver supports. It does not touch ONNX Runtime and does not
//     need the (large, separately downloaded) CUDA runtime libraries, so the
//     Dart side can decide whether offering the CUDA download makes sense at
//     all - CUDA 13 needs driver >= 13000 (R580+) and sm_75+.
//
//   * CudaPluginRegistry: the ONNX Runtime *plugin* execution provider
//     (`onnxruntime_providers_cuda.dll` from the `plugin-ep-cuda` release),
//     registered at runtime from an arbitrary directory with
//     `RegisterExecutionProviderLibrary` and appended to sessions with
//     `SessionOptionsAppendExecutionProvider_V2`. The legacy
//     `AppendExecutionProvider_CUDA_V2` path cannot be used: it requires the
//     provider DLL to sit next to onnxruntime.dll, and the DirectML build of
//     the core we ship has no CUDA provider at all.
//
// Kept free of flutter headers (like dml_provider.cc) so it can be reasoned
// about - and compiled - on its own.

#ifndef FLUTTER_ONNXRUNTIME_CUDA_PROVIDER_H_
#define FLUTTER_ONNXRUNTIME_CUDA_PROVIDER_H_

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include <onnxruntime_cxx_api.h>

namespace flutter_onnxruntime {

struct CudaDeviceInfo {
  int index = 0;
  std::string name;
  int compute_major = 0;
  int compute_minor = 0;
  int64_t total_mem_bytes = 0;
};

struct CudaProbeResult {
  // cuDriverGetVersion (e.g. 13000 for CUDA 13.0); absent when nvcuda.dll is
  // missing (no NVIDIA driver) or the call failed.
  bool has_driver_version = false;
  int driver_version = 0;
  std::vector<CudaDeviceInfo> devices;
  // Empty when everything answered; otherwise the first failure.
  std::string error;
};

// Loads nvcuda.dll from System32 (kept loaded afterwards: unloading the driver
// after cuInit is not supported) and enumerates devices. Never throws.
CudaProbeResult ProbeCudaDriver();

// LUID (8 bytes, Win32 LUID layout) of the display adapter behind CUDA device
// [ordinal], as the driver reports it (cuDeviceGetLuid). This is what ties a
// CUDA device to its DXGI adapter: on hybrid-graphics machines DXGI adapter 0
// is usually the integrated GPU, not the NVIDIA card. false when the driver
// cannot answer. Never throws.
bool CudaDeviceLuid(int ordinal, uint8_t luid[8]);

// cuDevicePrimaryCtxReset on every CUDA device: destroys the primary context
// (device memory, loaded kernel modules, pinned host staging) once nothing in
// the process uses it any more. Empty on success, else the first failure.
std::string ResetCudaPrimaryContexts();

struct CudaRegistrationResult {
  bool ok = false;
  std::string error;
  int device_count = 0;
};

struct CudaReleaseResult {
  // The plugin library was loaded and has now been unregistered.
  bool released = false;
  // cuDevicePrimaryCtxReset succeeded on every CUDA device.
  bool context_reset = false;
  // Empty unless something failed (a failed context reset leaves the library
  // released; the next CUDA session re-registers it either way).
  std::string error;
};

// Registration state of the CUDA plugin EP on one Ort::Env. Thread-safe.
class CudaPluginRegistry {
public:
  static constexpr const char *kRegistrationName = "CUDAExecutionProvider";

  // Registers `<dir>\onnxruntime_providers_cuda.dll` on [env]. Idempotent: a
  // repeated call with the same directory returns the cached successful
  // result (reloading the library first if Release() dropped it). A failed attempt leaves nothing behind (library unregistered,
  // PATH restored) and may be retried, e.g. after the download completes. A
  // different directory while one is registered is rejected: sessions may be
  // running on the registered library.
  CudaRegistrationResult Register(OrtEnv *env, const std::wstring &dir);

  // Lock-free: safe to call from the platform thread while Register() (which
  // holds the mutex for as long as the provider DLLs take to load) is running.
  // True once a registration has succeeded, also while Release() has the
  // library unloaded: the CUDA EP stays available and is reloaded on demand.
  bool IsRegistered();

  // Whether the plugin library is loaded right now.
  bool IsLoaded();

  // EP names reported by GetEpDevices at registration time (empty when not
  // registered); merged into getAvailableProviders.
  std::vector<std::string> RegisteredEpNames();

  // Appends the CUDA plugin EP for CUDA device [device_index] (index into the
  // CUDA OrtEpDevices, in GetEpDevices order), reloading the library first
  // when Release() dropped it. Throws Ort::Exception when the plugin was never
  // registered, cannot be reloaded, or the index is out of range.
  //
  // The appended OrtEpDevice belongs to the loaded library: the session must
  // be built before anything can call Release() (the plugin does both on its
  // GPU work queue).
  void AppendToSessionOptions(OrtEnv *env, OrtSessionOptions *options, int device_index);

  // Unloads the plugin library (and with it cuBLAS / cuDNN) while keeping the
  // registration: directory, EP names and IsRegistered() survive, and the
  // next AppendToSessionOptions() loads it again. With [reset_context] the
  // CUDA primary context of every device is reset afterwards, returning its
  // device memory and pinned host allocations. Every session created with
  // the plugin must already be released.
  CudaReleaseResult Release(OrtEnv *env, bool reset_context);

  // Unregisters the library if registered. Every session created with it must
  // already be released. Safe to call more than once.
  void Unregister(OrtEnv *env);

private:
  // Loads dir_ and fills cuda_devices_ / ep_names_. Caller holds mutex_.
  std::string LoadLocked(OrtEnv *env);

  std::mutex mutex_;
  std::atomic<bool> registered_{false};
  bool loaded_ = false;
  std::wstring dir_;
  int device_count_ = 0;
  std::vector<const OrtEpDevice *> cuda_devices_;
  std::vector<std::string> ep_names_;
};

} // namespace flutter_onnxruntime

#endif // FLUTTER_ONNXRUNTIME_CUDA_PROVIDER_H_
