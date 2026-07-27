#include <cassert>
#include <cstdint>
#include <cstring>

#include "qlie_pack.h"

int main() {
  using hibiki_voice_hook::qlie::ContainsFilePackSignature;

  const char measured_tail[] = {
      '\0', '\0', 'F', 'i', 'l', 'e', 'P', 'a', 'c', 'k', 'V', 'e', 'r',
      '3',  '.',  '1', '\0'};
  assert(ContainsFilePackSignature(
      reinterpret_cast<const uint8_t*>(measured_tail),
      sizeof(measured_tail)));

  const char other_version[] = "FilePackVer2.0";
  assert(ContainsFilePackSignature(
      reinterpret_cast<const uint8_t*>(other_version),
      strlen(other_version)));

  const char truncated[] = "FilePackVe";
  assert(!ContainsFilePackSignature(
      reinterpret_cast<const uint8_t*>(truncated), strlen(truncated)));

  const char unrelated[] = "PackFileVer3.1";
  assert(!ContainsFilePackSignature(
      reinterpret_cast<const uint8_t*>(unrelated), strlen(unrelated)));
  assert(!ContainsFilePackSignature(nullptr, 32));
  return 0;
}
