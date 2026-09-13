// Hibiki fork: off-platform-thread execution for ONNX Runtime work.
//
// Upstream runs every `runInference` / `createSession` synchronously inside the
// method-call handler, i.e. on the Flutter platform (UI) thread. A DirectML
// encoder run or a static-shape session build then freezes the UI for hundreds
// of milliseconds to several seconds, and — worse for throughput — a GPU run
// and a CPU run can never overlap because they share that one thread.
//
// This file provides:
//   * WorkQueue: a single worker thread with a FIFO of tasks. The plugin keeps
//     two of them: one for sessions on a GPU provider (DirectML runs are NOT
//     safe to issue concurrently from several threads in one process — two
//     sessions on two threads crash inside the DML provider), one for CPU
//     sessions. GPU and CPU work therefore overlap while each class stays
//     serialised.
//   * PlatformThreadDispatcher: a message-only window created on the platform
//     thread; `Post` marshals a callback back onto that thread so MethodResult
//     replies are always completed where Flutter expects them.

#ifndef FLUTTER_ONNXRUNTIME_ASYNC_DISPATCH_H_
#define FLUTTER_ONNXRUNTIME_ASYNC_DISPATCH_H_

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <windows.h>

namespace flutter_onnxruntime {

class WorkQueue {
public:
  explicit WorkQueue(const char *name);
  ~WorkQueue();

  WorkQueue(const WorkQueue &) = delete;
  WorkQueue &operator=(const WorkQueue &) = delete;

  // Enqueue a task; returns false if the queue is shutting down. In sync mode
  // (see PlatformThreadDispatcher::SyncModeRequested) the task runs inline.
  bool Post(std::function<void()> task);

private:
  void Run();

  // Declaration order matters: members are initialised in declaration order,
  // and the constructor starts the thread as part of initialising thread_.
  // With thread_ declared first, the worker enters Run() -- which immediately
  // locks mutex_, waits on cv_ and reads stopping_ -- while those four members
  // may still be uninitialised. That is UB, and its failure mode is silent:
  // stopping_ read as garbage-nonzero makes Run() return at once, every later
  // Post() then reports the queue as shutting down, tasks are dropped, and the
  // Dart Future behind each ORT call never completes (transcription just hangs,
  // no exception, no log). Keep thread_ LAST.
  std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<std::function<void()>> tasks_;
  bool stopping_ = false;
  std::thread thread_;
};

class PlatformThreadDispatcher {
public:
  // Must be constructed on the platform thread (the plugin registrar's thread).
  PlatformThreadDispatcher();
  ~PlatformThreadDispatcher();

  PlatformThreadDispatcher(const PlatformThreadDispatcher &) = delete;
  PlatformThreadDispatcher &operator=(const PlatformThreadDispatcher &) = delete;

  // Run [callback] on the platform thread. Safe to call from any thread.
  void Post(std::function<void()> callback);

  // Diagnostics escape hatch: with FLUTTER_ONNXRUNTIME_SYNC=1 in the process
  // environment every queue runs its task inline on the platform thread and
  // Post() invokes the callback directly — i.e. upstream's synchronous
  // behaviour, for A/B timing and for isolating threading bugs.
  static bool SyncModeRequested();

private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  HWND hwnd_ = nullptr;
};

} // namespace flutter_onnxruntime

#endif // FLUTTER_ONNXRUNTIME_ASYNC_DISPATCH_H_
