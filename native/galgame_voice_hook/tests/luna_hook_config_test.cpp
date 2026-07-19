#include <cstdio>

#include "luna_hook_config.h"

int main() {
  using hibiki_voice_hook::KnownLunaHookCodesForExecutable;
  const auto nine = KnownLunaHookCodesForExecutable(
      LR"(D:\9-nine\9-nine-Episode 1\nine_kokoiro.exe)");
  if (nine.size() != 1 ||
      nine.front() != L"EXHVXN0@2198:nine_kokoiro.exe") {
    std::fprintf(stderr, "9-nine hook config mismatch\n");
    return 1;
  }
  if (!KnownLunaHookCodesForExecutable(
           LR"(D:\other\nine_kokoiro.exe)")
           .empty()) {
    std::fprintf(stderr, "unrelated KiriKiri target must not get 9-nine offset\n");
    return 2;
  }
  if (!KnownLunaHookCodesForExecutable(
           LR"(D:\anemoi\anemoi (正式版)\SiglusEngine.exe)")
           .empty()) {
    std::fprintf(stderr, "anemoi uses the direct Siglus hook, not a fixed Luna offset\n");
    return 3;
  }
  return 0;
}
