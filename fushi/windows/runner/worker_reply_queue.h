#ifndef RUNNER_WORKER_REPLY_QUEUE_H_
#define RUNNER_WORKER_REPLY_QUEUE_H_

#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <utility>
#include <vector>

namespace fushi {

// 工作线程 → 平台线程的回话队列（与 window_capture_reply_queue.h 同一契约，按结果类型
// 泛化）：工作线程只持有结果槽，Flutter 的 MethodResult 始终留在平台线程上回话；宿主
// 销毁时（OnDestroy，messenger 还活着）对未完成的请求回取消结果，之后才完成的工作线程
// 结果被丢弃。没有裸指针 / HWND 越过线程边界。
template <typename Result>
class WorkerReplyCompletion {
 public:
  void Publish(Result result) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!closed_ && !result_) {
      result_ = std::move(result);
    }
  }

 private:
  template <typename>
  friend class WorkerReplyQueue;

  std::optional<Result> Take() {
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
  std::optional<Result> result_;
  bool closed_ = false;
};

// 全部方法只在平台线程调用。调用方在有待办时开一个计时器周期性 Drain，空了就停。
template <typename Result>
class WorkerReplyQueue {
 public:
  using Reply = std::function<void(Result)>;
  using CancelledFactory = std::function<Result()>;

  explicit WorkerReplyQueue(CancelledFactory cancelled)
      : cancelled_(std::move(cancelled)) {}
  WorkerReplyQueue(const WorkerReplyQueue&) = delete;
  WorkerReplyQueue& operator=(const WorkerReplyQueue&) = delete;
  ~WorkerReplyQueue() { Close(); }

  // 已关闭时立即回取消结果并返回 nullptr（调用方不得再起工作线程）。
  std::shared_ptr<WorkerReplyCompletion<Result>> Enqueue(Reply reply) {
    if (closed_) {
      reply(cancelled_());
      return nullptr;
    }
    auto completion = std::make_shared<WorkerReplyCompletion<Result>>();
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
      entry.reply(cancelled_());
    }
  }

  bool empty() const { return pending_.empty(); }

 private:
  struct Entry {
    std::shared_ptr<WorkerReplyCompletion<Result>> completion;
    Reply reply;
  };
  CancelledFactory cancelled_;
  std::vector<Entry> pending_;
  bool closed_ = false;
};

}  // namespace fushi

#endif  // RUNNER_WORKER_REPLY_QUEUE_H_
