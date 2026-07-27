// Siglus 文件夹签名识别的离线单测（不碰真实文件系统）。
//
// 根因回归：改名 Siglus exe（iroseka_HD.exe 等 HD/Steam 版）原来只按 exe 名匹配
// SiglusEngine.exe，识别不到就走 CREATE_SUSPENDED 早注入、被 Enigma 保护壳弹掉，报
// engine.launch_or_inject_failed。改为按 Gameexe.dat + Scene.pck 文件夹签名识别后即使 exe
// 改名也能判为 Siglus 从而延迟附着。本测试用假文件表固定“两签名齐全才判定、缺一不误报”。

#include <cstdio>
#include <set>
#include <string>

#include "siglus_launch.h"

using hibiki_voice_hook::DirectoryLooksLikeSiglus;
using hibiki_voice_hook::kSiglusSignatureConfig;
using hibiki_voice_hook::kSiglusSignatureScene;

namespace {

int g_failures = 0;

void Check(bool ok, const char* what) {
  if (!ok) {
    std::printf("FAIL: %s\n", what);
    ++g_failures;
  }
}

// 假文件系统：以 "dir|name" 记录存在的文件。
struct FakeFs {
  std::set<std::wstring> present;
  bool operator()(const std::wstring& dir, const wchar_t* name) const {
    return present.count(dir + L"|" + name) != 0;
  }
};

}  // namespace

int main() {
  const std::wstring dir = L"C:\\Games\\iroseka_HD";

  // 1) 两个 Siglus 签名齐全 -> 判为 Siglus（即便 exe 已改名）。
  {
    FakeFs fs;
    fs.present.insert(dir + L"|" + kSiglusSignatureConfig);
    fs.present.insert(dir + L"|" + kSiglusSignatureScene);
    Check(DirectoryLooksLikeSiglus(dir, fs), "both signatures -> Siglus");
  }

  // 2) 只有 Gameexe.dat -> 不判定（要求两者齐全，压低误报）。
  {
    FakeFs fs;
    fs.present.insert(dir + L"|" + kSiglusSignatureConfig);
    Check(!DirectoryLooksLikeSiglus(dir, fs), "config only -> not Siglus");
  }

  // 3) 只有 Scene.pck -> 不判定。
  {
    FakeFs fs;
    fs.present.insert(dir + L"|" + kSiglusSignatureScene);
    Check(!DirectoryLooksLikeSiglus(dir, fs), "scene only -> not Siglus");
  }

  // 4) 两者都没有 -> 不判定。
  {
    FakeFs fs;
    Check(!DirectoryLooksLikeSiglus(dir, fs), "none -> not Siglus");
  }

  // 5) 空目录 -> 直接否定（即使谓词恒真也短路，避免对空路径拼接探测）。
  {
    auto always_true = [](const std::wstring&, const wchar_t*) { return true; };
    Check(!DirectoryLooksLikeSiglus(std::wstring(), always_true),
          "empty dir -> not Siglus");
  }

  if (g_failures == 0) {
    std::printf("siglus_launch_test: all checks passed\n");
    return 0;
  }
  std::printf("siglus_launch_test: %d check(s) failed\n", g_failures);
  return 1;
}
