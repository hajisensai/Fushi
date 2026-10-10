#pragma once

// ── Symbol export ───────────────────────────────────────────────────
#ifdef _WIN32
  #define FUSHI_EXPORT __declspec(dllexport)
#else
  #define FUSHI_EXPORT __attribute__((visibility("default")))
#endif

// ── Logging ─────────────────────────────────────────────────────────
#ifdef __ANDROID__
  #include <android/log.h>
  #define FUSHI_LOGW(...) __android_log_print(ANDROID_LOG_WARN, "fushidicts", __VA_ARGS__)
  #define FUSHI_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "fushidicts", __VA_ARGS__)
#else
  #include <cstdio>
  #define FUSHI_LOGW(...) do { fprintf(stderr, "[fushidicts WARN] " __VA_ARGS__); fprintf(stderr, "\n"); } while(0)
  #define FUSHI_LOGE(...) do { fprintf(stderr, "[fushidicts ERROR] " __VA_ARGS__); fprintf(stderr, "\n"); } while(0)
#endif

// ── Import memory budget ────────────────────────────────────────────
// Android and iOS kill a foreground app on its own footprint (lmkd / jetsam)
// long before the device runs out of physical RAM, and that kill is invisible
// to every catch. The importer's low_ram mode is the bounded shape for that:
// two bank workers and single-threaded zstd training instead of a fan-out of
// hardware_concurrency()+4 workers, each holding a whole decompressed and
// parsed bank. It used to be hardwired off for every platform, which is what
// took Android down on large English dictionaries (BUG-3234). Desktop and the
// headless server keep the wide fan-out they have always had.
#if defined(__APPLE__)
  #include <TargetConditionals.h>
#endif
#if defined(__ANDROID__) || (defined(__APPLE__) && TARGET_OS_IPHONE)
  inline constexpr bool kFushiImportLowRam = true;
#else
  inline constexpr bool kFushiImportLowRam = false;
#endif

// ── Threading (large-stack import thread) ───────────────────────────
#ifdef _WIN32
  #include <windows.h>
  #include <process.h>

  struct FushiThread {
    HANDLE handle = nullptr;
  };

  using FushiThreadFn = unsigned(__stdcall*)(void*);

  inline bool fushi_thread_create(FushiThread& t, FushiThreadFn fn, void* arg, size_t stack_size) {
    t.handle = reinterpret_cast<HANDLE>(
      _beginthreadex(nullptr, static_cast<unsigned>(stack_size), fn, arg, 0, nullptr)
    );
    return t.handle != nullptr;
  }

  inline void fushi_thread_join(FushiThread& t) {
    if (t.handle) {
      WaitForSingleObject(t.handle, INFINITE);
      CloseHandle(t.handle);
      t.handle = nullptr;
    }
  }
#else
  #include <pthread.h>

  struct FushiThread {
    pthread_t handle{};
  };

  using FushiThreadFn = void*(*)(void*);

  inline bool fushi_thread_create(FushiThread& t, FushiThreadFn fn, void* arg, size_t stack_size) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, stack_size);
    int rc = pthread_create(&t.handle, &attr, fn, arg);
    pthread_attr_destroy(&attr);
    return rc == 0;
  }

  inline void fushi_thread_join(FushiThread& t) {
    pthread_join(t.handle, nullptr);
  }
#endif
