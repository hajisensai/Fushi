#include "child_process_policy.h"

#include <cassert>
#include <vector>

using hibiki_voice_hook::ChildProcessCandidate;
using hibiki_voice_hook::SelectGameChildProcess;

int main() {
  const std::vector<ChildProcessCandidate> renpy = {
      {200, 100, L"crashpad.exe", false, false},
      {201, 100, L"pythonw.exe", false, false},
      {202, 201, L"game.exe", true, true},
      {300, 999, L"python.exe", true, true},
  };
  assert(SelectGameChildProcess(100, renpy) == 202);

  const std::vector<ChildProcessCandidate> python_only = {
      {410, 400, L"helper.exe", false, false},
      {411, 400, L"python.exe", false, false},
  };
  assert(SelectGameChildProcess(400, python_only) == 411);

  const std::vector<ChildProcessCandidate> unrelated = {
      {501, 999, L"python.exe", true, true},
  };
  assert(SelectGameChildProcess(500, unrelated) == 0);
  return 0;
}
