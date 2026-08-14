// 启动器布局识别的离线单测（假目录树，不碰真实文件系统）。
//
// 真实样本：AngelBeats 体験版。原始启动入口 Start.exe 在根目录，Siglus 的
// Gameexe.dat + Scene.pck 在 StartData/gamedata/ 下——差两层。原判据只看被启动 exe
// 自己那一层，于是把 hook 下在启动器上，启动器拉起 SiglusEngine.exe 后自己退出，
// 文本/音频一条都不来。

#include <cstdio>
#include <set>
#include <string>
#include <vector>

#include "launcher_layout.h"

using fushi_voice_hook::FindGameDirectoryBelow;
using fushi_voice_hook::kLauncherLayoutMaxDepth;
using fushi_voice_hook::LooksLikeLauncherLayout;

namespace {

int g_failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    std::printf("FAIL: %s\n", what);
    ++g_failures;
  }
}

// 假目录树：只记录「哪些目录存在」与「哪些目录带引擎签名」。
struct FakeTree {
  std::set<std::wstring> directories;
  std::set<std::wstring> game_directories;

  bool IsGameDir(const std::wstring& dir) const {
    return game_directories.count(dir) != 0;
  }

  std::vector<std::wstring> List(const std::wstring& dir) const {
    std::vector<std::wstring> children;
    const std::wstring prefix = dir + L"\\";
    for (const std::wstring& candidate : directories) {
      if (candidate.size() <= prefix.size()) continue;
      if (candidate.compare(0, prefix.size(), prefix) != 0) continue;
      // 只要直接子目录：剩余部分不能再含分隔符。
      if (candidate.find(L'\\', prefix.size()) != std::wstring::npos) continue;
      children.push_back(candidate);
    }
    return children;
  }
};

FakeTree AngelBeatsTree() {
  FakeTree tree;
  tree.directories.insert(L"X:\\Games\\AngelBeats\\StartData");
  tree.directories.insert(L"X:\\Games\\AngelBeats\\StartData\\gamedata");
  tree.directories.insert(L"X:\\Games\\AngelBeats\\StartData\\gamedata\\koe");
  // 游戏目录里再挂一份带同样签名的副本。这不是构造出来的形态：ATRI 的安装目录下就有
  // 「原版备份/」放着整份可运行的旧版本。没有「自己那层就是游戏目录则一定不是启动器」
  // 这条短路时，直接启动引擎 exe 会因为底下搜到这份副本而被误判成启动器，白等一次
  // 子进程超时。
  tree.directories.insert(L"X:\\Games\\AngelBeats\\StartData\\gamedata\\backup");
  tree.game_directories.insert(L"X:\\Games\\AngelBeats\\StartData\\gamedata");
  tree.game_directories.insert(
      L"X:\\Games\\AngelBeats\\StartData\\gamedata\\backup");
  return tree;
}

}  // namespace

int main() {
  const FakeTree tree = AngelBeatsTree();
  const auto is_game = [&tree](const std::wstring& d) { return tree.IsGameDir(d); };
  const auto list = [&tree](const std::wstring& d) { return tree.List(d); };

  // 1) 启动器在根：自己那层没签名，两层之下有 -> 判为启动器布局。
  Check(LooksLikeLauncherLayout(L"X:\\Games\\AngelBeats",
                                kLauncherLayoutMaxDepth, is_game, list),
        "launcher at root -> launcher layout");
  Check(FindGameDirectoryBelow(L"X:\\Games\\AngelBeats",
                               kLauncherLayoutMaxDepth, is_game, list) ==
            L"X:\\Games\\AngelBeats\\StartData\\gamedata",
        "finds the real game directory");

  // 2) 直接启动引擎 exe：自己那层就有签名 -> **不是**启动器布局。
  //    否则正常游戏也会被拖去等一次子进程超时。
  Check(!LooksLikeLauncherLayout(L"X:\\Games\\AngelBeats\\StartData\\gamedata",
                                 kLauncherLayoutMaxDepth, is_game, list),
        "engine directory itself -> not launcher layout");

  // 3) 深度不够（只允许 1 层）时不误判：宁可漏，不可把无关目录树翻个底朝天。
  Check(!LooksLikeLauncherLayout(L"X:\\Games\\AngelBeats", 1, is_game, list),
        "depth 1 cannot reach gamedata -> not launcher layout");
  Check(LooksLikeLauncherLayout(L"X:\\Games\\AngelBeats", 2, is_game, list),
        "depth 2 reaches gamedata");

  // 4) 树里根本没有游戏目录 -> 不判定。
  {
    FakeTree bare;
    bare.directories.insert(L"X:\\Games\\Other\\bin");
    const auto bare_is_game = [&bare](const std::wstring& d) {
      return bare.IsGameDir(d);
    };
    const auto bare_list = [&bare](const std::wstring& d) { return bare.List(d); };
    Check(!LooksLikeLauncherLayout(L"X:\\Games\\Other", kLauncherLayoutMaxDepth,
                                   bare_is_game, bare_list),
          "no engine signature anywhere -> not launcher layout");
  }

  // 5) 空目录 / 非法深度 -> 直接否定，且不调用任何谓词。
  {
    int calls = 0;
    const auto counting = [&calls](const std::wstring&) {
      ++calls;
      return true;
    };
    const auto empty_list = [](const std::wstring&) {
      return std::vector<std::wstring>();
    };
    Check(!LooksLikeLauncherLayout(std::wstring(), kLauncherLayoutMaxDepth,
                                   counting, empty_list),
          "empty directory -> not launcher layout");
    Check(calls == 0, "empty directory must not probe anything");
    Check(FindGameDirectoryBelow(L"X:\\Games\\AngelBeats", 0, is_game, list)
              .empty(),
          "depth 0 -> no search");
  }

  if (g_failures == 0) {
    std::printf("launcher_layout_test: all checks passed\n");
    return 0;
  }
  std::printf("launcher_layout_test: %d check(s) failed\n", g_failures);
  return 1;
}
