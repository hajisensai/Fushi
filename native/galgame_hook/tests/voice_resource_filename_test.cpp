#include <cassert>
#include <string>

#include "voice_resource_filename.h"
#include "voice_resource_pairing.h"

int main() {
  using hibiki_voice_hook::BuildVoiceResourceFileName;
  using hibiki_voice_hook::ResolveFollowingSelectedText;
  using hibiki_voice_hook::VoiceResourcePairState;
  using hibiki_voice_hook::VoiceTextCandidate;

  // Cross-engine guard: profiles without a proved text/resource contract keep
  // the legacy filename and cannot accidentally claim stable pairing.
  assert(BuildVoiceResourceFileName(1234, L"voice.ogg") ==
         L"1234_voice.ogg");

  // A profile may opt in only after a separate causal pairing decision.
  assert(BuildVoiceResourceFileName(1234, L"voice.ogg", 57) ==
         L"1234_hibiki_textseq57_voice.ogg");

  const VoiceTextCandidate observed[] = {
      // Discovery/UI/wrong-thread rows cannot bind a resource.
      {14, 32147000, 77, 0, false},
      {15, 32147100, 99, 18, true},
      // Real runtime ordering: the complete selected line follows the resource
      // by 31 ms.
      {16, 32147218, 77, 80, true},
      {17, 32147400, 77, 44, true},
  };
  const auto matched = ResolveFollowingSelectedText(
      32147187, 32148687, 32147250, 77, 15, observed,
      sizeof(observed) / sizeof(observed[0]));
  assert(matched.state == VoiceResourcePairState::kMatched);
  assert(matched.text_event_id == 16);

  const auto unselected = ResolveFollowingSelectedText(
      32147187, 32148687, 32147250, 0, 15, observed,
      sizeof(observed) / sizeof(observed[0]));
  assert(unselected.state == VoiceResourcePairState::kUnselected);
  assert(unselected.text_event_id == 0);

  const auto waiting = ResolveFollowingSelectedText(
      32147187, 32148687, 32148000, 88, 15, observed,
      sizeof(observed) / sizeof(observed[0]));
  assert(waiting.state == VoiceResourcePairState::kWait);

  const auto expired = ResolveFollowingSelectedText(
      32147187, 32148687, 32148687, 88, 15, observed,
      sizeof(observed) / sizeof(observed[0]));
  assert(expired.state == VoiceResourcePairState::kExpired);
  assert(expired.text_event_id == 0);
  return 0;
}
