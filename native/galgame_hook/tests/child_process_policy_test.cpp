#include "child_process_policy.h"

#include <cassert>
#include <vector>

using fushi_voice_hook::ChildProcessCandidate;
using fushi_voice_hook::SelectGameChildProcess;

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

  // Siglus 启动器链（AngelBeats 体験版）：真正的游戏进程一个 ffmpeg 模块都不加载，
  // 只有「镜像目录带引擎数据签名」这条证据认得出它。没有这条证据时全员 -1，选出 0，
  // 于是 hook 留在转手即退的启动器上——文本/音频一条都不来。
  const std::vector<ChildProcessCandidate> siglus_launcher = {
      {601, 600, L"StartMenu.exe", false, false, false},
      {602, 601, L"SiglusEngine.exe", false, false, true},
  };
  assert(SelectGameChildProcess(600, siglus_launcher) == 602);

  // 引擎签名压过 ffmpeg 全中：解码器进程可能只是 helper，引擎签名不会。
  const std::vector<ChildProcessCandidate> signature_beats_ffmpeg = {
      {701, 700, L"decoder.exe", true, true, false},
      {702, 700, L"game.exe", false, false, true},
  };
  assert(SelectGameChildProcess(700, signature_beats_ffmpeg) == 702);

  // 不是后代的进程即使带签名也不选（同机开着的另一台游戏不该被抢过来）。
  const std::vector<ChildProcessCandidate> foreign_signature = {
      {801, 999, L"SiglusEngine.exe", false, false, true},
  };
  assert(SelectGameChildProcess(800, foreign_signature) == 0);
  return 0;
}
