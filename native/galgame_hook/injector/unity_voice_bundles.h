// Unity 资源语音：一个 clip 该到哪个 voice bundle 里抽（injector 侧纯逻辑，可离线单测）。
//
// hook 只记得本会话**最近打开**的那个 `*voice*.bundle`（CreateFile 钩子，
// RememberUnityVoiceBundle），而 Addressables 构建常把语音按组分成多个包
// （voice(scenario) / voice(action) / voice(gimmick) …），启动时一次性全部加载——
// 「最近打开的那个」通常不是这句台词所在的那个。所以抽取按这个顺序试：
//   1. 上一次抽取成功的包（同一目录、同一命名规则；大多数台词都在同一个场景语音包里）；
//   2. hook 报来的那个包；
//   3. 同一目录下其余符合同一命名规则（文件名以 .bundle 结尾且含 "voice"，不区分大小写，
//      与 hook 侧 IsUnityVoiceBundle 同一口径）的包，按名字排序。
// 目录来自游戏实际打开的那个包的路径（运行时证据），不扫别处。
// 一个 clip 名在全部候选里都找不到——BGM / SE / jingle / 打字音不在任何语音包里——
// 就记进负缓存，之后同名的播放直接跳过，不再每次起抽取进程。
#pragma once

#include <algorithm>
#include <string>
#include <unordered_set>
#include <vector>

namespace fushi_voice_injector {

inline std::wstring LowerAscii(const std::wstring& value) {
  std::wstring out = value;
  for (wchar_t& c : out) {
    if (c >= L'A' && c <= L'Z') c = static_cast<wchar_t>(c - L'A' + L'a');
  }
  return out;
}

// 文件名（不含目录）。
inline std::wstring UnityBundleFileName(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

inline std::wstring UnityBundleDirectory(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring() : path.substr(0, slash);
}

inline bool IsUnityVoiceBundleFileName(const std::wstring& name) {
  const std::wstring lower = LowerAscii(UnityBundleFileName(name));
  static const std::wstring kSuffix = L".bundle";
  return lower.size() > kSuffix.size() &&
         lower.compare(lower.size() - kSuffix.size(), kSuffix.size(),
                       kSuffix) == 0 &&
         lower.find(L"voice") != std::wstring::npos;
}

inline constexpr size_t kMaxUnityVoiceBundleCandidates = 8;

// `opened`：hook 报来的包的完整路径；`siblings`：同一目录下的文件名（不含目录）；
// `last_success`：上一次抽取成功的包的完整路径（可空）。返回完整路径，去重，至多 8 个。
inline std::vector<std::wstring> OrderUnityVoiceBundleCandidates(
    const std::wstring& opened, std::vector<std::wstring> siblings,
    const std::wstring& last_success) {
  std::vector<std::wstring> out;
  if (opened.empty() || !IsUnityVoiceBundleFileName(opened)) return out;
  const std::wstring directory = UnityBundleDirectory(opened);
  const auto add = [&out](const std::wstring& path) {
    if (out.size() >= kMaxUnityVoiceBundleCandidates) return;
    const std::wstring key = LowerAscii(path);
    for (const std::wstring& existing : out) {
      if (LowerAscii(existing) == key) return;
    }
    out.push_back(path);
  };
  if (!last_success.empty() && IsUnityVoiceBundleFileName(last_success) &&
      LowerAscii(UnityBundleDirectory(last_success)) == LowerAscii(directory)) {
    add(last_success);
  }
  add(opened);
  std::sort(siblings.begin(), siblings.end(),
            [](const std::wstring& a, const std::wstring& b) {
              return LowerAscii(a) < LowerAscii(b);
            });
  for (const std::wstring& name : siblings) {
    // 只收裸文件名：带目录分隔符的不是这个目录里的条目。
    if (name.find_first_of(L"\\/") != std::wstring::npos ||
        !IsUnityVoiceBundleFileName(name)) {
      continue;
    }
    add(directory.empty() ? name : directory + L"\\" + name);
  }
  return out;
}

// 在全部候选包里都找不到的 clip 名（按「目录 + clip 名」区分，不区分大小写）。有界：
// 满了就整体清空重来——宁可偶尔多抽一次，不无界增长。
class UnityVoiceNegativeCache {
 public:
  static constexpr size_t kCapacity = 1024;
  bool Contains(const std::wstring& directory, const std::wstring& clip) const {
    return entries_.count(Key(directory, clip)) != 0;
  }
  void Add(const std::wstring& directory, const std::wstring& clip) {
    if (entries_.size() >= kCapacity) entries_.clear();
    entries_.insert(Key(directory, clip));
  }
  size_t size() const { return entries_.size(); }

 private:
  static std::wstring Key(const std::wstring& directory,
                          const std::wstring& clip) {
    return LowerAscii(directory) + L"|" + clip;
  }
  std::unordered_set<std::wstring> entries_;
};

}  // namespace fushi_voice_injector
