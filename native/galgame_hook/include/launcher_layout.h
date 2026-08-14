#pragma once

// 启动器布局识别（launcher layout）。
//
// 背景：一批游戏的原始启动入口不是引擎 exe 本身，而是同目录或上层的一个启动器。用户报的
// 「原始启动路径」是那个启动器，注入器却把 hook 下在了启动器进程上——它转手拉起真正的游戏
// 进程后自己退出，于是文本/音频一条都不来，表面症状是「装上了但什么都抓不到」。
//
// 判据不能靠 exe 名（各家启动器名字五花八门），要靠**引擎数据签名在哪一层**：
//
//   AngelBeats 体験版：Start.exe（根目录，无签名）
//                      └─ StartData/StartMenu.exe
//                         └─ StartData/gamedata/SiglusEngine.exe   ← Gameexe.dat + Scene.pck 在这
//
// 被启动 exe 自己那层没有引擎签名、而受限深度内的某个子目录有 ⇒ 这个 exe 是启动器，注入器
// 必须改走「跟随子进程」。反过来，exe 自己那层就有签名时**一定不是**启动器布局——否则把正常
// 游戏也拖进子进程等待，白等一次超时。
//
// 已知边界（不在本判据覆盖内，故意留白而不是瞎猜）：启动器与游戏 exe 在**同一个目录**时
// （如 BootStrap.exe 与 tenshi_sz.exe 并排），静态上无法区分谁是启动器，只能靠调用方显式
// 传 --follow-child-processes。
//
// 全部逻辑用注入的谓词表达（生产 = Win32；测试 = 假目录树），不碰真实文件系统。

#include <string>
#include <vector>

namespace fushi_voice_hook {

// 子目录搜索的默认深度上限。启动器再套也就两层（Start → StartData → gamedata），给到 3 层
// 足够；再深就是在别人的资源树里乱翻，代价与误报都不划算。
inline constexpr int kLauncherLayoutMaxDepth = 3;

// 在 root 之下按广度优先找第一个「看起来是游戏目录」的子目录，不含 root 自身。
//
//   is_game_dir(dir)          -> bool，该目录是否具备某个引擎的数据签名
//   list_subdirectories(dir)  -> 可迭代的子目录**全路径**容器
//
// 返回空串表示没找到。广度优先而不是深度优先：真实布局里游戏目录总在浅层，先找到的那个也
// 更可能是主目录而不是某个附属资源目录。
template <typename IsGameDir, typename ListSubdirectories>
std::wstring FindGameDirectoryBelow(const std::wstring& root, int max_depth,
                                    IsGameDir is_game_dir,
                                    ListSubdirectories list_subdirectories) {
  if (root.empty() || max_depth <= 0) return std::wstring();
  std::vector<std::wstring> frontier = {root};
  for (int depth = 1; depth <= max_depth && !frontier.empty(); ++depth) {
    std::vector<std::wstring> next;
    for (const std::wstring& dir : frontier) {
      for (const std::wstring& child : list_subdirectories(dir)) {
        if (child.empty()) continue;
        if (is_game_dir(child)) return child;
        next.push_back(child);
      }
    }
    frontier.swap(next);
  }
  return std::wstring();
}

// 被启动的 exe 是不是启动器：自己那层没签名，底下某层有。
template <typename IsGameDir, typename ListSubdirectories>
bool LooksLikeLauncherLayout(const std::wstring& executable_directory,
                             int max_depth, IsGameDir is_game_dir,
                             ListSubdirectories list_subdirectories) {
  if (executable_directory.empty()) return false;
  if (is_game_dir(executable_directory)) return false;
  return !FindGameDirectoryBelow(executable_directory, max_depth, is_game_dir,
                                 list_subdirectories)
              .empty();
}

}  // namespace fushi_voice_hook
