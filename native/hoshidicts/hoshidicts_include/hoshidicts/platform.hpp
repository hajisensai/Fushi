#pragma once

// ── Symbol export ───────────────────────────────────────────────────
#ifdef _WIN32
  #define HOSHI_EXPORT __declspec(dllexport)
#else
  #define HOSHI_EXPORT __attribute__((visibility("default")))
#endif

// ── Logging ─────────────────────────────────────────────────────────
#ifdef __ANDROID__
  #include <android/log.h>
  #define HOSHI_LOGW(...) __android_log_print(ANDROID_LOG_WARN, "hoshidicts", __VA_ARGS__)
  #define HOSHI_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "hoshidicts", __VA_ARGS__)
#else
  #include <cstdio>
  #define HOSHI_LOGW(...) do { fprintf(stderr, "[hoshidicts WARN] " __VA_ARGS__); fprintf(stderr, "\n"); } while(0)
  #define HOSHI_LOGE(...) do { fprintf(stderr, "[hoshidicts ERROR] " __VA_ARGS__); fprintf(stderr, "\n"); } while(0)
#endif

// ── Threading (large-stack import thread) ───────────────────────────
#ifdef _WIN32
  #include <windows.h>
  #include <process.h>

  struct HoshiThread {
    HANDLE handle = nullptr;
  };

  using HoshiThreadFn = unsigned(__stdcall*)(void*);

  inline bool hoshi_thread_create(HoshiThread& t, HoshiThreadFn fn, void* arg, size_t stack_size) {
    t.handle = reinterpret_cast<HANDLE>(
      _beginthreadex(nullptr, static_cast<unsigned>(stack_size), fn, arg, 0, nullptr)
    );
    return t.handle != nullptr;
  }

  inline void hoshi_thread_join(HoshiThread& t) {
    if (t.handle) {
      WaitForSingleObject(t.handle, INFINITE);
      CloseHandle(t.handle);
      t.handle = nullptr;
    }
  }
#else
  #include <pthread.h>

  struct HoshiThread {
    pthread_t handle{};
  };

  using HoshiThreadFn = void*(*)(void*);

  inline bool hoshi_thread_create(HoshiThread& t, HoshiThreadFn fn, void* arg, size_t stack_size) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, stack_size);
    int rc = pthread_create(&t.handle, &attr, fn, arg);
    pthread_attr_destroy(&attr);
    return rc == 0;
  }

  inline void hoshi_thread_join(HoshiThread& t) {
    pthread_join(t.handle, nullptr);
  }
#endif
