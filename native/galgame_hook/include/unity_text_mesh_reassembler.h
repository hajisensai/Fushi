#ifndef HIBIKI_UNITY_TEXT_MESH_REASSEMBLER_H_
#define HIBIKI_UNITY_TEXT_MESH_REASSEMBLER_H_

#include <cstddef>
#include <cstdint>
#include <cwchar>

namespace hibiki_voice_hook {

enum class UnityTextMeshUpdate {
  kNoChange,
  kPartial,
  kCompleted,
  kOverflowCompleted,
};

// Fixed-storage state machine for legacy Unity TextMesh setters. The setter may
// send one glyph at a time or redraw the full cumulative string. Empty setters
// are transient redraws, not an end-of-line signal.
template <size_t Capacity>
class UnityTextMeshReassembler {
 public:
  static_assert(Capacity >= 2, "TextMesh buffer needs room for a terminator");

  bool ShouldTerminate(wchar_t c,
                       bool fullwidth_space_is_profile_terminator) const {
    return fullwidth_space_is_profile_terminator && c == L'\u3000';
  }

  bool Append(wchar_t c) {
    if (!IsVisible(c)) return false;
    if (length_ + 1 >= Capacity) {
      truncated_ = true;
      return false;
    }
    text_[length_++] = c;
    text_[length_] = L'\0';
    return true;
  }

  UnityTextMeshUpdate ApplySnapshot(
      const wchar_t* source, size_t source_length,
      bool fullwidth_space_is_profile_terminator) {
    completed_[0] = L'\0';
    completed_length_ = 0;
    completed_truncated_ = false;
    if (source == nullptr || source_length == 0) {
      return UnityTextMeshUpdate::kNoChange;
    }

    size_t payload_length = source_length;
    bool terminated = false;
    for (size_t i = 0; i < source_length; ++i) {
      if (ShouldTerminate(source[i],
                          fullwidth_space_is_profile_terminator)) {
        payload_length = i;
        terminated = true;
        break;
      }
    }

    size_t append_from = 0;
    if (payload_length >= length_ && length_ > 0 &&
        std::wmemcmp(source, text_, length_) == 0) {
      // Full cumulative redraw: append only the newly revealed suffix.
      append_from = length_;
    } else if (payload_length > 1 && length_ > 0) {
      // A non-prefix multi-character setter is a replacement redraw. It must
      // not be concatenated with the previous visual state.
      ResetCurrent();
    }

    bool overflowed = false;
    for (size_t i = append_from; i < payload_length; ++i) {
      if (!Append(source[i])) {
        overflowed = true;
        break;
      }
    }

    if (terminated || overflowed) {
      CopyCompleted();
      ResetCurrent();
      return overflowed ? UnityTextMeshUpdate::kOverflowCompleted
                        : UnityTextMeshUpdate::kCompleted;
    }
    return payload_length == append_from ? UnityTextMeshUpdate::kNoChange
                                         : UnityTextMeshUpdate::kPartial;
  }

  const wchar_t* text() const { return text_; }
  int length() const { return static_cast<int>(length_); }
  bool empty() const { return length_ == 0; }
  bool truncated() const { return truncated_; }
  const wchar_t* completed_text() const { return completed_; }
  int completed_length() const { return static_cast<int>(completed_length_); }
  bool completed_truncated() const { return completed_truncated_; }

  void Reset() {
    ResetCurrent();
    completed_[0] = L'\0';
    completed_length_ = 0;
    completed_truncated_ = false;
  }

 private:
  static bool IsVisible(wchar_t c) {
    return c >= 0x20 || c == L'\r' || c == L'\n' || c == L'\t';
  }

  void CopyCompleted() {
    completed_length_ = length_;
    std::wmemcpy(completed_, text_, length_ + 1);
    completed_truncated_ = truncated_;
  }

  void ResetCurrent() {
    text_[0] = L'\0';
    length_ = 0;
    truncated_ = false;
  }

  wchar_t text_[Capacity] = {};
  wchar_t completed_[Capacity] = {};
  size_t length_ = 0;
  size_t completed_length_ = 0;
  bool truncated_ = false;
  bool completed_truncated_ = false;
};

template <size_t BucketCount, size_t Capacity>
class UnityTextMeshStateTable {
 public:
  struct Bucket {
    uint64_t component = 0;
    uint32_t thread_id = 0;
    uint64_t last_used = 0;
    UnityTextMeshReassembler<Capacity> line;
  };

  template <typename Evict>
  Bucket& Acquire(uint64_t component, uint32_t thread_id, uint64_t stamp,
                  Evict on_evict) {
    Bucket* empty = nullptr;
    Bucket* oldest = &buckets_[0];
    for (Bucket& bucket : buckets_) {
      if (bucket.component == component && bucket.thread_id == thread_id) {
        bucket.last_used = stamp;
        return bucket;
      }
      if (bucket.component == 0 && empty == nullptr) empty = &bucket;
      if (bucket.last_used < oldest->last_used) oldest = &bucket;
    }
    Bucket* selected = empty == nullptr ? oldest : empty;
    if (selected->component != 0 && !selected->line.empty()) {
      on_evict(*selected);
    }
    selected->line.Reset();
    selected->component = component;
    selected->thread_id = thread_id;
    selected->last_used = stamp;
    return *selected;
  }

  template <typename Flush>
  void FlushAll(Flush flush) {
    for (Bucket& bucket : buckets_) {
      if (bucket.component != 0 && !bucket.line.empty()) flush(bucket);
      bucket = Bucket{};
    }
  }

 private:
  Bucket buckets_[BucketCount] = {};
};

}  // namespace hibiki_voice_hook

#endif  // HIBIKI_UNITY_TEXT_MESH_REASSEMBLER_H_
