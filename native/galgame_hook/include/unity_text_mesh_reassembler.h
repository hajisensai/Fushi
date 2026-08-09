#ifndef FUSHI_UNITY_TEXT_MESH_REASSEMBLER_H_
#define FUSHI_UNITY_TEXT_MESH_REASSEMBLER_H_

#include <cstddef>
#include <cwchar>

namespace fushi_voice_hook {

// Legacy Unity titles may call TextMesh.set_text once per rendered glyph. This
// accumulator deliberately has no clock: a typewriter pause is not a semantic
// sentence boundary. CR/LF/TAB are visible content and remain in the line.
template <size_t Capacity>
class UnityTextMeshReassembler {
 public:
  static_assert(Capacity >= 2, "TextMesh buffer needs room for a terminator");

  bool ShouldTerminate(wchar_t c,
                       bool fullwidth_space_is_profile_terminator) const {
    return fullwidth_space_is_profile_terminator && c == L'\u3000';
  }

  bool Append(wchar_t c) {
    if (c < 0x20 && c != L'\r' && c != L'\n' && c != L'\t') {
      return false;
    }
    if (length_ + 1 >= Capacity) {
      truncated_ = true;
      return false;
    }
    text_[length_++] = c;
    text_[length_] = L'\0';
    return true;
  }

  const wchar_t* text() const { return text_; }
  int length() const { return static_cast<int>(length_); }
  bool empty() const { return length_ == 0; }
  bool truncated() const { return truncated_; }

  void Reset() {
    text_[0] = L'\0';
    length_ = 0;
    truncated_ = false;
  }

 private:
  wchar_t text_[Capacity] = {};
  size_t length_ = 0;
  bool truncated_ = false;
};

}  // namespace fushi_voice_hook

#endif  // FUSHI_UNITY_TEXT_MESH_REASSEMBLER_H_
