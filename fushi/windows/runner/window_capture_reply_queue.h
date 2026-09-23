#ifndef RUNNER_WINDOW_CAPTURE_REPLY_QUEUE_H_
#define RUNNER_WINDOW_CAPTURE_REPLY_QUEUE_H_

#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <utility>
#include <vector>

#include "window_capture.h"

namespace fushi {

// The worker owns only pixels/status. Flutter replies remain on the UI thread,
// including when the host is destroyed before a capture finishes.
class WindowCaptureCompletion {
 public:
  void Publish(WindowCaptureResult result) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!closed_ && !result_) {
      result_ = std::move(result);
    }
  }

 private:
  friend class WindowCaptureReplyQueue;

  std::optional<WindowCaptureResult> Take() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!result_) {
      return std::nullopt;
    }
    closed_ = true;
    return std::exchange(result_, std::nullopt);
  }

  void Close() {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
    result_.reset();
  }

  std::mutex mutex_;
  std::optional<WindowCaptureResult> result_;
  bool closed_ = false;
};

// All queue methods are UI-thread-only. A timer runs only while entries exist;
// no raw pointer or HWND crosses to the capture worker or the message queue.
class WindowCaptureReplyQueue {
 public:
  using Reply = std::function<void(WindowCaptureResult)>;

  WindowCaptureReplyQueue() = default;
  WindowCaptureReplyQueue(const WindowCaptureReplyQueue&) = delete;
  WindowCaptureReplyQueue& operator=(const WindowCaptureReplyQueue&) = delete;
  ~WindowCaptureReplyQueue() { Close(); }

  std::shared_ptr<WindowCaptureCompletion> Enqueue(Reply reply) {
    if (closed_) {
      reply(CancelledResult());
      return nullptr;
    }
    auto completion = std::make_shared<WindowCaptureCompletion>();
    pending_.push_back({completion, std::move(reply)});
    return completion;
  }

  void Drain() {
    for (size_t index = 0; index < pending_.size();) {
      auto result = pending_[index].completion->Take();
      if (!result) {
        ++index;
        continue;
      }
      Reply reply = std::move(pending_[index].reply);
      pending_.erase(pending_.begin() + index);
      reply(std::move(*result));
    }
  }

  void Close() {
    closed_ = true;
    auto pending = std::move(pending_);
    pending_.clear();
    for (auto& entry : pending) {
      entry.completion->Close();
      entry.reply(CancelledResult());
    }
  }

  bool empty() const { return pending_.empty(); }

 private:
  static WindowCaptureResult CancelledResult() {
    WindowCaptureResult result;
    result.error = "capture host closed";
    result.capture_reason = "capture_host_closed";
    return result;
  }

  struct Entry {
    std::shared_ptr<WindowCaptureCompletion> completion;
    Reply reply;
  };
  std::vector<Entry> pending_;
  bool closed_ = false;
};

}  // namespace fushi

#endif  // RUNNER_WINDOW_CAPTURE_REPLY_QUEUE_H_
