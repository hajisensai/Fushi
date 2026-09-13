#ifndef RUNNER_SINGLE_INSTANCE_MUTEX_H_
#define RUNNER_SINGLE_INSTANCE_MUTEX_H_

#include <windows.h>

namespace fushi {

// BUG-2279: Creating a handle is not ownership. Keep the main thread's
// ownership until after the Flutter window/engine have been destroyed.
// Use only on the creating thread (Win32 mutex ownership is thread-affine).
class SingleInstanceMutex {
 public:
  explicit SingleInstanceMutex(const wchar_t* name, bool enabled = true) {
    if (!enabled) return;
    ::SetLastError(ERROR_SUCCESS);
    handle_ = ::CreateMutexW(nullptr, TRUE, name);
    const bool existing = ::GetLastError() == ERROR_ALREADY_EXISTS;
    owns_ = handle_ != nullptr && !existing;
    // A prior process can already be gone while another candidate still has
    // an open handle. Object existence alone must not prevent taking over.
    if (handle_ != nullptr && existing) Wait(0);
  }

  ~SingleInstanceMutex() {
    if (owns_) ::ReleaseMutex(handle_);
    if (handle_ != nullptr) ::CloseHandle(handle_);
  }

  SingleInstanceMutex(const SingleInstanceMutex&) = delete;
  SingleInstanceMutex& operator=(const SingleInstanceMutex&) = delete;

  bool valid() const { return handle_ != nullptr; }
  bool owns() const { return owns_; }

  bool Wait(DWORD timeout_ms) {
    // Avoid recursively acquiring a Win32 mutex: one release must suffice.
    if (owns_) return true;
    if (handle_ == nullptr) return false;
    const DWORD result = ::WaitForSingleObject(handle_, timeout_ms);
    owns_ = result == WAIT_OBJECT_0 || result == WAIT_ABANDONED;
    return owns_;
  }

 private:
  HANDLE handle_ = nullptr;
  bool owns_ = false;
};

}  // namespace fushi

#endif  // RUNNER_SINGLE_INSTANCE_MUTEX_H_
