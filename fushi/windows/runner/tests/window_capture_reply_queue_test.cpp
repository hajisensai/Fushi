#include "../window_capture_reply_queue.h"

#include <cstdlib>
#include <iostream>
#include <thread>

namespace {
void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}

fushi::WindowCaptureResult CapturedFrame() {
  fushi::WindowCaptureResult result;
  result.ok = true;
  result.png = {1, 2, 3};
  return result;
}
}  // namespace

int main() {
  const auto ui_thread = std::this_thread::get_id();
  int delivered = 0;
  fushi::WindowCaptureReplyQueue queue;
  auto first = queue.Enqueue([&](fushi::WindowCaptureResult result) {
    Check(std::this_thread::get_id() == ui_thread, "reply left UI thread");
    Check(result.ok && result.png.size() == 3, "lost completed frame");
    ++delivered;
  });
  std::thread worker([first]() { first->Publish(CapturedFrame()); });
  worker.join();
  Check(delivered == 0, "worker delivered Flutter reply");
  queue.Drain();
  first->Publish(CapturedFrame());
  queue.Drain();
  Check(delivered == 1 && queue.empty(), "reply was not exactly once");

  int cancelled = 0;
  auto cancel_reply = [&](fushi::WindowCaptureResult result) {
    Check(std::this_thread::get_id() == ui_thread, "cancel left UI thread");
    Check(!result.ok && result.png.empty() &&
              result.capture_reason == "capture_host_closed",
          "close delivered a stale success");
    ++cancelled;
  };
  auto late = queue.Enqueue(cancel_reply);
  auto already_ready = queue.Enqueue(cancel_reply);
  already_ready->Publish(CapturedFrame());
  queue.Close();
  std::thread late_worker([late]() { late->Publish(CapturedFrame()); });
  late_worker.join();
  queue.Drain();
  queue.Close();
  Check(cancelled == 2 && queue.empty(), "teardown lost or repeated a reply");
  Check(queue.Enqueue(cancel_reply) == nullptr && cancelled == 3,
        "closed host accepted new capture");

  std::shared_ptr<fushi::WindowCaptureCompletion> orphan;
  {
    fushi::WindowCaptureReplyQueue destroyed;
    orphan = destroyed.Enqueue(cancel_reply);
  }
  orphan->Publish(CapturedFrame());
  Check(cancelled == 4, "queue destruction left pending reply");

  fushi::WindowCaptureReplyQueue reordered;
  int order = 0;
  auto slow = reordered.Enqueue([&](fushi::WindowCaptureResult result) {
    Check(result.ok && order == 1, "slow reply order");
    ++order;
  });
  auto fast = reordered.Enqueue([&](fushi::WindowCaptureResult result) {
    Check(result.ok && order == 0, "ready reply blocked behind slow capture");
    ++order;
  });
  fast->Publish(CapturedFrame());
  reordered.Drain();
  slow->Publish(CapturedFrame());
  reordered.Drain();
  Check(order == 2 && reordered.empty(), "concurrent capture lost");

  std::cout << "window capture reply queue: 5 lifecycle cases passed\n";
  return 0;
}
