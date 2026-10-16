// Fushi fork: see cuda_provider.h.

#include "src/cuda_provider.h"

#include <windows.h>

#include <algorithm>
#include <cstring>
#include <cwctype>

namespace flutter_onnxruntime {

namespace {

// -- nvcuda.dll (driver API) --
// Declared locally: the CUDA toolkit headers are not a build dependency.
using CUresult = int;
using CUdevice = int;
constexpr int kCuAttrComputeCapabilityMajor = 75;
constexpr int kCuAttrComputeCapabilityMinor = 76;

using PFN_cuInit = CUresult(__stdcall *)(unsigned int);
using PFN_cuDriverGetVersion = CUresult(__stdcall *)(int *);
using PFN_cuDeviceGetCount = CUresult(__stdcall *)(int *);
using PFN_cuDeviceGet = CUresult(__stdcall *)(CUdevice *, int);
using PFN_cuDeviceGetName = CUresult(__stdcall *)(char *, int, CUdevice);
using PFN_cuDeviceGetAttribute = CUresult(__stdcall *)(int *, int, CUdevice);
using PFN_cuDeviceTotalMem = CUresult(__stdcall *)(size_t *, CUdevice);
using PFN_cuGetErrorName = CUresult(__stdcall *)(CUresult, const char **);

std::string CuError(PFN_cuGetErrorName get_name, const char *what, CUresult code) {
  std::string message = std::string(what) + " failed: " + std::to_string(code);
  const char *name = nullptr;
  if (get_name != nullptr && get_name(code, &name) == 0 && name != nullptr) {
    message += " (" + std::string(name) + ")";
  }
  return message;
}

std::string WideToUtf8(const std::wstring &wide) {
  if (wide.empty()) {
    return std::string();
  }
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), nullptr, 0, nullptr,
                                 nullptr);
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), &out[0], size, nullptr, nullptr);
  return out;
}

std::wstring GetPath() {
  DWORD size = GetEnvironmentVariableW(L"PATH", nullptr, 0);
  if (size == 0) {
    return std::wstring();
  }
  std::wstring value(size, L'\0');
  DWORD written = GetEnvironmentVariableW(L"PATH", &value[0], size);
  value.resize(written);
  return value;
}

std::wstring ToLower(std::wstring s) {
  std::transform(s.begin(), s.end(), s.begin(), [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  return s;
}

std::wstring TrimTrailingSeparators(std::wstring dir) {
  while (dir.size() > 3 && (dir.back() == L'\\' || dir.back() == L'/')) {
    dir.pop_back();
  }
  return dir;
}

// Status -> message, releasing the status. Empty when [status] is null.
std::string TakeStatus(OrtStatus *status) {
  if (status == nullptr) {
    return std::string();
  }
  std::string message = Ort::GetApi().GetErrorMessage(status);
  Ort::GetApi().ReleaseStatus(status);
  return message.empty() ? std::string("unknown ONNX Runtime error") : message;
}

} // namespace

CudaProbeResult ProbeCudaDriver() {
  CudaProbeResult result;
  // System32 only: nvcuda.dll is installed there by the display driver, and a
  // stray copy elsewhere on PATH must not be picked up.
  static HMODULE nvcuda = LoadLibraryExW(L"nvcuda.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (nvcuda == nullptr) {
    result.error = "nvcuda.dll not found (no NVIDIA driver)";
    return result;
  }
  auto get_error_name = reinterpret_cast<PFN_cuGetErrorName>(GetProcAddress(nvcuda, "cuGetErrorName"));
  auto driver_get_version = reinterpret_cast<PFN_cuDriverGetVersion>(GetProcAddress(nvcuda, "cuDriverGetVersion"));
  auto init = reinterpret_cast<PFN_cuInit>(GetProcAddress(nvcuda, "cuInit"));
  auto device_get_count = reinterpret_cast<PFN_cuDeviceGetCount>(GetProcAddress(nvcuda, "cuDeviceGetCount"));
  auto device_get = reinterpret_cast<PFN_cuDeviceGet>(GetProcAddress(nvcuda, "cuDeviceGet"));
  auto device_get_name = reinterpret_cast<PFN_cuDeviceGetName>(GetProcAddress(nvcuda, "cuDeviceGetName"));
  auto device_get_attribute =
      reinterpret_cast<PFN_cuDeviceGetAttribute>(GetProcAddress(nvcuda, "cuDeviceGetAttribute"));
  auto device_total_mem = reinterpret_cast<PFN_cuDeviceTotalMem>(GetProcAddress(nvcuda, "cuDeviceTotalMem_v2"));

  if (driver_get_version != nullptr) {
    int version = 0;
    if (driver_get_version(&version) == 0) {
      result.has_driver_version = true;
      result.driver_version = version;
    }
  }
  if (init == nullptr || device_get_count == nullptr || device_get == nullptr || device_get_name == nullptr ||
      device_get_attribute == nullptr || device_total_mem == nullptr) {
    result.error = "nvcuda.dll is missing driver API entry points";
    return result;
  }
  CUresult rc = init(0);
  if (rc != 0) {
    // 100 = CUDA_ERROR_NO_DEVICE: driver present, no usable NVIDIA GPU.
    result.error = CuError(get_error_name, "cuInit", rc);
    return result;
  }
  int count = 0;
  rc = device_get_count(&count);
  if (rc != 0) {
    result.error = CuError(get_error_name, "cuDeviceGetCount", rc);
    return result;
  }
  for (int i = 0; i < count; i++) {
    CUdevice device = 0;
    rc = device_get(&device, i);
    if (rc != 0) {
      result.error = CuError(get_error_name, "cuDeviceGet", rc);
      continue;
    }
    CudaDeviceInfo info;
    info.index = i;
    char name[256] = {0};
    if (device_get_name(name, static_cast<int>(sizeof(name) - 1), device) == 0) {
      info.name = name;
    }
    device_get_attribute(&info.compute_major, kCuAttrComputeCapabilityMajor, device);
    device_get_attribute(&info.compute_minor, kCuAttrComputeCapabilityMinor, device);
    size_t total = 0;
    if (device_total_mem(&total, device) == 0) {
      info.total_mem_bytes = static_cast<int64_t>(total);
    }
    result.devices.push_back(std::move(info));
  }
  return result;
}

CudaRegistrationResult CudaPluginRegistry::Register(OrtEnv *env, const std::wstring &raw_dir) {
  std::lock_guard<std::mutex> lock(mutex_);
  CudaRegistrationResult result;
  const std::wstring dir = TrimTrailingSeparators(raw_dir);
  if (dir.empty()) {
    result.error = "CUDA runtime directory is empty";
    return result;
  }
  if (registered_) {
    if (ToLower(dir) == ToLower(dir_)) {
      result.ok = true;
      result.device_count = device_count_;
      return result;
    }
    result.error = "CUDA execution provider is already registered from " + WideToUtf8(dir_) +
                   "; a different runtime directory needs an app restart";
    result.device_count = device_count_;
    return result;
  }

  const std::wstring library = dir + L"\\onnxruntime_providers_cuda.dll";
  if (GetFileAttributesW(library.c_str()) == INVALID_FILE_ATTRIBUTES) {
    result.error = "onnxruntime_providers_cuda.dll not found in " + WideToUtf8(dir);
    return result;
  }

  // The plugin's own imports (cublas*, cudnn64_9) would resolve through
  // AddDllDirectory, but cuDNN loads its sub-libraries (cudnn_graph64_9.dll,
  // cudnn_engines_*.dll, ...) at run time by bare name through the legacy
  // search order - AddDllDirectory does not cover that, and preloading only
  // cudnn64_9.dll is not enough either (both measured: Conv then fails with
  // CUDNN_BACKEND_API_FAILED). Prepending the directory to this process's
  // PATH is what works. Process-local; restored if registration fails.
  const std::wstring old_path = GetPath();
  bool path_changed = false;
  {
    const std::wstring lowered = ToLower(old_path);
    const std::wstring needle = ToLower(dir);
    bool present = false;
    size_t start = 0;
    while (start <= lowered.size()) {
      size_t end = lowered.find(L';', start);
      if (end == std::wstring::npos) {
        end = lowered.size();
      }
      if (TrimTrailingSeparators(lowered.substr(start, end - start)) == needle) {
        present = true;
        break;
      }
      start = end + 1;
    }
    if (!present) {
      const std::wstring new_path = old_path.empty() ? dir : dir + L";" + old_path;
      path_changed = SetEnvironmentVariableW(L"PATH", new_path.c_str()) != 0;
    }
  }
  auto restore_path = [&]() {
    if (path_changed) {
      SetEnvironmentVariableW(L"PATH", old_path.empty() ? nullptr : old_path.c_str());
    }
  };

  const OrtApi &api = Ort::GetApi();
  std::string error = TakeStatus(api.RegisterExecutionProviderLibrary(env, kRegistrationName, library.c_str()));
  if (!error.empty()) {
    restore_path();
    result.error = "RegisterExecutionProviderLibrary failed: " + error;
    return result;
  }

  const OrtEpDevice *const *devices = nullptr;
  size_t num_devices = 0;
  error = TakeStatus(api.GetEpDevices(env, &devices, &num_devices));
  std::vector<const OrtEpDevice *> cuda_devices;
  std::vector<std::string> ep_names;
  if (error.empty()) {
    for (size_t i = 0; i < num_devices; i++) {
      const char *ep_name = api.EpDevice_EpName(devices[i]);
      if (ep_name == nullptr) {
        continue;
      }
      if (std::find(ep_names.begin(), ep_names.end(), ep_name) == ep_names.end()) {
        ep_names.push_back(ep_name);
      }
      if (std::strcmp(ep_name, kRegistrationName) == 0) {
        cuda_devices.push_back(devices[i]);
      }
    }
  }
  if (!error.empty() || cuda_devices.empty()) {
    // No half-registered state: drop the library again.
    TakeStatus(api.UnregisterExecutionProviderLibrary(env, kRegistrationName));
    restore_path();
    result.error = error.empty() ? "CUDA execution provider registered but reported no device" :
                                   "GetEpDevices failed: " + error;
    return result;
  }

  registered_ = true;
  dir_ = dir;
  cuda_devices_ = std::move(cuda_devices);
  ep_names_ = std::move(ep_names);
  device_count_ = static_cast<int>(cuda_devices_.size());
  result.ok = true;
  result.device_count = device_count_;
  return result;
}

bool CudaPluginRegistry::IsRegistered() {
  std::lock_guard<std::mutex> lock(mutex_);
  return registered_;
}

std::vector<std::string> CudaPluginRegistry::RegisteredEpNames() {
  std::lock_guard<std::mutex> lock(mutex_);
  return registered_ ? ep_names_ : std::vector<std::string>();
}

void CudaPluginRegistry::AppendToSessionOptions(OrtEnv *env, OrtSessionOptions *options, int device_index) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!registered_) {
    throw Ort::Exception("CUDA execution provider is not registered (registerCudaRuntime has not succeeded)",
                         ORT_FAIL);
  }
  if (device_index < 0 || device_index >= static_cast<int>(cuda_devices_.size())) {
    throw Ort::Exception("CUDA device index " + std::to_string(device_index) + " out of range (" +
                             std::to_string(cuda_devices_.size()) + " CUDA device(s))",
                         ORT_INVALID_ARGUMENT);
  }
  const OrtEpDevice *device = cuda_devices_[static_cast<size_t>(device_index)];
  Ort::ThrowOnError(
      Ort::GetApi().SessionOptionsAppendExecutionProvider_V2(options, env, &device, 1, nullptr, nullptr, 0));
}

void CudaPluginRegistry::Unregister(OrtEnv *env) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!registered_) {
    return;
  }
  TakeStatus(Ort::GetApi().UnregisterExecutionProviderLibrary(env, kRegistrationName));
  registered_ = false;
  cuda_devices_.clear();
  ep_names_.clear();
  device_count_ = 0;
  dir_.clear();
}

} // namespace flutter_onnxruntime
