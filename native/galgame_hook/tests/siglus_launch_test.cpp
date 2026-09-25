// Siglus 文件夹签名识别的离线单测（不碰真实文件系统）。
//
// 根因回归：改名 Siglus exe（iroseka_HD.exe 等 HD/Steam 版）原来只按 exe 名匹配
// SiglusEngine.exe，识别不到就走 CREATE_SUSPENDED 早注入、被 Enigma 保护壳弹掉，报
// engine.launch_or_inject_failed。改为按 Gameexe.dat + Scene.pck 文件夹签名识别后即使 exe
// 改名也能判为 Siglus 从而延迟附着。本测试用假文件表固定“两签名齐全才判定、缺一不误报”。
//
// 第二个回归：CLANNAD Steam 版（SiglusEngine_Steam.exe）选简体中文时只有
// GameexeZH.dat + SceneZH.pck。旧判据只认无后缀的那一对 → 同样被当成非 Siglus。
// 新判据允许两者共享同一个语言后缀，但后缀必须一致、必须成对。

// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cstdio>
#include <cwchar>
#include <set>
#include <string>

#include "siglus_launch.h"

using fushi_voice_hook::DirectoryLooksLikeSiglus;
using fushi_voice_hook::kSiglusSignatureConfig;
using fushi_voice_hook::kSiglusSignatureScene;
using fushi_voice_hook::SiglusScenePackSuffix;

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

// 与生产的 FindFirstFileW("Scene*.pck") 同形：只把 dir 下以 Scene 开头、.pck 结尾的名字交出去。
struct FakeSceneLister {
  const FakeFs* fs;
  template <typename Visit>
  void operator()(const std::wstring& dir, Visit visit) const {
    const std::wstring prefix = dir + L"|";
    for (const std::wstring& entry : fs->present) {
      if (entry.compare(0, prefix.size(), prefix) != 0) continue;
      const std::wstring name = entry.substr(prefix.size());
      if (name.size() < 9 || _wcsnicmp(name.c_str(), L"Scene", 5) != 0 ||
          _wcsicmp(name.c_str() + name.size() - 4, L".pck") != 0) {
        continue;
      }
      if (!visit(name)) return;
    }
  }
};

bool LooksLikeSiglus(const std::wstring& dir, const FakeFs& fs) {
  return DirectoryLooksLikeSiglus(dir, fs, FakeSceneLister{&fs});
}

void Put(FakeFs* fs, const std::wstring& dir, const wchar_t* name) {
  fs->present.insert(dir + L"|" + name);
}

}  // namespace

int main() {
  const std::wstring dir = L"C:\\Games\\iroseka_HD";

  // 1) 两个 Siglus 签名齐全 -> 判为 Siglus（即便 exe 已改名）。
  {
    FakeFs fs;
    fs.present.insert(dir + L"|" + kSiglusSignatureConfig);
    fs.present.insert(dir + L"|" + kSiglusSignatureScene);
    Check(LooksLikeSiglus(dir, fs), "both signatures -> Siglus");
  }

  // 2) 只有 Gameexe.dat -> 不判定（要求两者齐全，压低误报）。
  {
    FakeFs fs;
    fs.present.insert(dir + L"|" + kSiglusSignatureConfig);
    Check(!LooksLikeSiglus(dir, fs), "config only -> not Siglus");
  }

  // 3) 只有 Scene.pck -> 不判定。
  {
    FakeFs fs;
    fs.present.insert(dir + L"|" + kSiglusSignatureScene);
    Check(!LooksLikeSiglus(dir, fs), "scene only -> not Siglus");
  }

  // 4) 两者都没有 -> 不判定。
  {
    FakeFs fs;
    Check(!LooksLikeSiglus(dir, fs), "none -> not Siglus");
  }

  // 5) 空目录 -> 直接否定（即使谓词恒真也短路，避免对空路径拼接探测）。
  {
    auto always_true = [](const std::wstring&, const wchar_t*) { return true; };
    auto list_all = [](const std::wstring&, auto visit) {
      visit(std::wstring(L"SceneZH.pck"));
    };
    Check(!DirectoryLooksLikeSiglus(std::wstring(), always_true, list_all),
          "empty dir -> not Siglus");
  }

  // 6) CLANNAD Steam 简中布局：GameexeZH.dat + SceneZH.pck -> Siglus。
  {
    FakeFs fs;
    Put(&fs, dir, L"GameexeZH.dat");
    Put(&fs, dir, L"SceneZH.pck");
    Check(LooksLikeSiglus(dir, fs), "language-suffixed pair -> Siglus");
  }

  // 7) 后缀不一致（GameexeEN.dat + SceneZH.pck）-> 不判定：必须是同一对。
  {
    FakeFs fs;
    Put(&fs, dir, L"GameexeEN.dat");
    Put(&fs, dir, L"SceneZH.pck");
    Check(!LooksLikeSiglus(dir, fs), "mismatched suffix -> not Siglus");
  }

  // 8) 只有带后缀的剧本包、没有配置 -> 不判定。
  {
    FakeFs fs;
    Put(&fs, dir, L"SceneZH.pck");
    Check(!LooksLikeSiglus(dir, fs), "suffixed scene only -> not Siglus");
  }

  // 9) 多语言并存：无后缀剧本缺配置，但 EN 成对 -> Siglus。
  {
    FakeFs fs;
    Put(&fs, dir, L"Scene.pck");
    Put(&fs, dir, L"GameexeEN.dat");
    Put(&fs, dir, L"SceneEN.pck");
    Check(LooksLikeSiglus(dir, fs), "one complete suffixed pair -> Siglus");
  }

  // 10) 后缀解析：大小写不敏感、只收短 ASCII 字母数字。
  {
    std::wstring suffix;
    Check(SiglusScenePackSuffix(L"Scene.pck", &suffix) && suffix.empty(),
          "Scene.pck -> empty suffix");
    Check(SiglusScenePackSuffix(L"sceneZH.PCK", &suffix) && suffix == L"ZH",
          "case-insensitive suffix");
    Check(!SiglusScenePackSuffix(L"Scene_old.pck", &suffix),
          "punctuation suffix rejected");
    Check(!SiglusScenePackSuffix(L"SceneBackupCopy.pck", &suffix),
          "long suffix rejected");
    Check(!SiglusScenePackSuffix(L"Scene.dat", &suffix), "wrong extension");
    Check(!SiglusScenePackSuffix(L"Scen.pck", &suffix), "wrong prefix");
  }

  if (g_failures == 0) {
    std::printf("siglus_launch_test: all checks passed\n");
    return 0;
  }
  std::printf("siglus_launch_test: %d check(s) failed\n", g_failures);
  return 1;
}
