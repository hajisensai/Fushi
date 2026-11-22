// Fushi fork: native test for the worker teardown contract (HBK-AUDIT-015).
//
// Exercises the real WorkQueue / DelayedTask from src/async_dispatch.cc. The
// plugin's FlutterOnnxruntimePluginImpl can't be built here (Flutter wrapper +
// ORT headers), so `Owner` below reproduces its idle-release wiring member for
// member -- idle mutex + generation, GPU queue, DelayedTask declared last, a
// CUDA close task that arms the timer, a timer that posts to the GPU queue --
// and its destructor runs the same sequence as ~FlutterOnnxruntimePluginImpl.
// fushi/test/onnx/cuda_idle_release_guard_test.dart pins that the plugin's
// destructor keeps that sequence.
//
// Build + run (x64 Native Tools prompt, from this directory):
//   cl /nologo /std:c++17 /EHsc /utf-8 /W4 /I..\src async_dispatch_teardown_test.cc
//      ..\src\async_dispatch.cc user32.lib && async_dispatch_teardown_test.exe
// Add /DFUSHI_TEARDOWN_LEGACY to get the pre-fix destructor (implicit member
// destruction only): the in-flight close case then fails.

#include "async_dispatch.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>

using flutter_onnxruntime::DelayedTask;
using flutter_onnxruntime::WorkQueue;

namespace {

int g_failures = 0;

void Check(bool ok, const char *what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) {
    ++g_failures;
  }
}

// One-shot latch.
class Latch {
public:
  void Open() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      open_ = true;
    }
    cv_.notify_all();
  }
  void Wait() {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this] { return open_; });
  }

private:
  std::mutex mutex_;
  std::condition_variable cv_;
  bool open_ = false;
};

// Observes, from outside the owner, whether its idle-release members are
// still alive when a worker reaches them.
struct Probe {
  std::atomic<bool> idle_members_alive{true};
  std::atomic<int> arms_after_destroy{0};
  std::atomic<int> arms_accepted{0};
  std::atomic<int> arms_refused{0};
  std::atomic<int> fires{0};
  std::atomic<int> fire_posts_accepted{0};
  std::atomic<int> releases_run{0};
  Latch teardown_begun;
  // Opened at the instant the GPU queue starts draining during teardown.
  Latch gpu_drain_begun;
  Latch fire_started;
};

// Destroyed together with cudaIdleMutex_ (declared right before it).
struct AliveCanary {
  explicit AliveCanary(Probe *probe) : probe_(probe) {}
  ~AliveCanary() { probe_->idle_members_alive = false; }
  Probe *probe_;
};

// Opens [latch] when destroyed (or earlier via Open()): marks the point where
// the GPU queue starts draining, whichever teardown path gets there.
struct DrainPoint {
  explicit DrainPoint(Latch *latch) : latch_(latch) {}
  ~DrainPoint() { latch_->Open(); }
  void Open() { latch_->Open(); }
  Latch *latch_;
};

class Owner {
public:
  explicit Owner(Probe *probe, bool block_fire)
      : probe_(probe), block_fire_(block_fire), drain_point_(&probe->gpu_drain_begun), canary_(probe) {}

#ifdef FUSHI_TEARDOWN_LEGACY
  ~Owner() { probe_->teardown_begun.Open(); }
#else
  // Same sequence as ~FlutterOnnxruntimePluginImpl().
  ~Owner() {
    probe_->teardown_begun.Open();
    cudaIdleRelease_.Shutdown();
    drain_point_.Open();
    gpuQueue_.Shutdown();
  }
#endif

  // As HandleCloseSession's GPU task: closing the last CUDA session arms the
  // idle release. The task is held until the GPU queue starts draining in
  // teardown -- the worst case, deterministically: every earlier teardown
  // step has finished by then.
  void PostCudaClose() {
    Latch *drain = &probe_->gpu_drain_begun;
    gpuQueue_.Post([this, drain]() {
      drain->Wait();
      ArmCudaIdleRelease(7);
    });
  }

  void ArmCudaIdleRelease(uint64_t generation) {
    if (!probe_->idle_members_alive) {
      // The plugin would now lock a destroyed mutex and Schedule() on a
      // destroyed DelayedTask. Record it instead of committing the UB.
      ++probe_->arms_after_destroy;
      return;
    }
    {
      std::lock_guard<std::mutex> lock(cudaIdleMutex_);
      cudaIdleGeneration_ = generation;
    }
    if (cudaIdleRelease_.Schedule(std::chrono::milliseconds(0))) {
      ++probe_->arms_accepted;
    } else {
      ++probe_->arms_refused;
    }
  }

  void ArmNow() { cudaIdleRelease_.Schedule(std::chrono::milliseconds(0)); }

private:
  // As FireCudaIdleRelease: post the release onto the GPU queue.
  void FireCudaIdleRelease() {
    ++probe_->fires;
    if (block_fire_) {
      probe_->fire_started.Open();
      probe_->teardown_begun.Wait();
    }
    Probe *probe = probe_;
    if (gpuQueue_.Post([probe]() { ++probe->releases_run; })) {
      ++probe_->fire_posts_accepted;
    }
  }

  Probe *probe_;
  bool block_fire_;
  // Same relative order as FlutterOnnxruntimePluginImpl.
  WorkQueue gpuQueue_{"teardown test gpu"};
  // Declared right after the queue: in member destruction it is the last thing
  // to go before the queue's destructor drains.
  DrainPoint drain_point_;
  AliveCanary canary_;
  std::mutex cudaIdleMutex_;
  uint64_t cudaIdleGeneration_ = 0;
  DelayedTask cudaIdleRelease_{[this]() { FireCudaIdleRelease(); }};
};

// A CUDA close task still queued on the GPU queue when the owner is destroyed
// (engine shutdown right after the last transcription closed its sessions).
void TestTeardownWithCudaCloseInFlight() {
  Probe probe;
  auto owner = std::make_unique<Owner>(&probe, false);
  owner->PostCudaClose();
  owner.reset();
  Check(probe.arms_after_destroy == 0, "in-flight CUDA close never reaches destroyed idle members");
  Check(probe.arms_refused == 1, "the drained close task's re-arm is refused by the stopped timer");
  Check(probe.fires == 0, "the idle release never fires during teardown");
}

// The idle timer firing while the owner is being destroyed: its post must land
// on a queue that is still alive and gets drained.
void TestTeardownWithIdleFireInFlight() {
  Probe probe;
  auto owner = std::make_unique<Owner>(&probe, true);
  owner->ArmNow();
  probe.fire_started.Wait();
  owner.reset();
  Check(probe.fires == 1, "the idle release fired once");
  Check(probe.fire_posts_accepted == 1, "the in-flight fire posts to the live GPU queue");
  Check(probe.releases_run == 1, "the posted release is drained before the queue goes away");
}

void TestWorkQueueShutdown() {
  std::atomic<int> ran{0};
  Latch hold;
  WorkQueue queue("teardown test queue");
  queue.Post([&hold]() { hold.Wait(); });
  for (int i = 0; i < 3; ++i) {
    queue.Post([&ran]() { ++ran; });
  }
  hold.Open();
  queue.Shutdown();
  Check(ran == 3, "WorkQueue::Shutdown drains every queued task");
  Check(!queue.Post([&ran]() { ++ran; }), "WorkQueue::Post after Shutdown is refused");
  queue.Shutdown();
  Check(ran == 3, "a refused task never runs; Shutdown is idempotent");
}

void TestDelayedTaskShutdown() {
  std::atomic<int> fired{0};
  DelayedTask task([&fired]() { ++fired; });
  Check(task.Schedule(std::chrono::hours(1)), "DelayedTask::Schedule before Shutdown is accepted");
  task.Shutdown();
  Check(!task.Schedule(std::chrono::milliseconds(0)), "DelayedTask::Schedule after Shutdown is refused");
  task.Shutdown();
  Check(fired == 0, "a shut-down DelayedTask never fires");
}

} // namespace

int main() {
  TestWorkQueueShutdown();
  TestDelayedTaskShutdown();
  TestTeardownWithCudaCloseInFlight();
  TestTeardownWithIdleFireInFlight();
  std::printf("%s (%d failure(s))\n", g_failures == 0 ? "PASS" : "FAIL", g_failures);
  return g_failures == 0 ? 0 : 1;
}
