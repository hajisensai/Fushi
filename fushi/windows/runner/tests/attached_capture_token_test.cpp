#include "../attached_capture_token.h"

#include <iostream>

namespace {

using fushi::attached_capture_token::Begin;
using fushi::attached_capture_token::BeginResult;
using fushi::attached_capture_token::Release;
using fushi::attached_capture_token::State;

bool Expect(bool condition, const char *message) {
  if (condition)
    return true;
  std::cerr << message << '\n';
  return false;
}

} // namespace

int main() {
  bool ok = true;
  State state;

  ok &= Expect(Begin(&state, 7, 9, 101, 3) == BeginResult::kStarted,
               "first exact token must begin suppression");
  ok &= Expect(Begin(&state, 7, 9, 101, 3) == BeginResult::kSameToken,
               "replayed begin for the same token must be idempotent");
  ok &= Expect(Begin(&state, 7, 9, 102, 3) == BeginResult::kBusy,
               "a second token cannot replace an active capture fence");

  // The game advanced from text generation 3 to 4 while hidden. Release has
  // no text-generation argument by design: exact epoch/token authority clears
  // suppression, after which production synchronizes its internally current
  // generation (4), never the acquisition-time generation (3).
  const int64_t current_text_generation = 4;
  ok &= Expect(current_text_generation != state.acquired_text_generation,
               "test setup must exercise a sentence-generation change");
  ok &= Expect(Release(&state, 7, 9, 101),
               "same epoch/token must release after a sentence change");
  ok &= Expect(!state.active, "release must clear suppression state");

  ok &= Expect(!Release(&state, 7, 9, 101),
               "a spent token must stay stale");
  ok &= Expect(Begin(&state, 7, 10, 103, 5) == BeginResult::kStarted,
               "a new surface epoch may acquire a fresh token");
  ok &= Expect(!Release(&state, 7, 9, 103),
               "an older surface epoch cannot release the current token");
  ok &= Expect(!Release(&state, 8, 10, 103),
               "an older session epoch cannot release the current token");
  ok &= Expect(!Release(&state, 7, 10, 102),
               "a different token cannot release the current fence");
  ok &= Expect(state.active,
               "stale release attempts must preserve the active fence");
  ok &= Expect(Release(&state, 7, 10, 103),
               "the exact current epoch/token must remain releasable");

  return ok ? 0 : 1;
}
