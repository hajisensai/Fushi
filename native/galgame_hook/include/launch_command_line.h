#ifndef FUSHI_LAUNCH_COMMAND_LINE_H_
#define FUSHI_LAUNCH_COMMAND_LINE_H_

#include <string>
#include <vector>

namespace fushi_voice_hook {

// `CreateProcessW` 的 lpCommandLine 是**一个字符串**，子进程用 `CommandLineToArgvW`
// （以及等价的 MSVCRT 启动代码）反解成 argv。因此 host 侧的「一个参数」要原样到达
// 游戏，必须按同一套反解规则转义后再拼接——直接空格拼接是错的：
//
//   --arg "C:\Program Files\save"   拼成 ... C:\Program Files\save
//   → 游戏收到两个 argv：`C:\Program` 和 `Files\save`
//
// 规则（与 CommandLineToArgvW 严格互逆）：
//   * 参数含空格/制表/换行/垂直制表/引号，或为空串时，整体加双引号；
//   * 引号前的连续反斜杠数量翻倍再补一个反斜杠转义该引号；
//   * 结尾（右引号前）的连续反斜杠数量翻倍，避免它转义掉右引号；
//   * 其余位置的反斜杠是普通字符，原样输出。
//
// 这是 Windows 官方的 ArgvQuote 算法，不是自创转义；不要改成「把引号替换成 \"」之类
// 的简化版，那对 `a\"b`、`a\\` 这类输入会静默产生错误 argv。
inline void AppendQuotedArgument(const std::wstring& argument,
                                 bool force_quotes, std::wstring* out) {
  if (out == nullptr) return;
  if (!force_quotes && !argument.empty() &&
      argument.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    out->append(argument);
    return;
  }
  out->push_back(L'"');
  for (std::wstring::const_iterator it = argument.begin();; ++it) {
    std::size_t backslashes = 0;
    while (it != argument.end() && *it == L'\\') {
      ++it;
      ++backslashes;
    }
    if (it == argument.end()) {
      // 右引号前的反斜杠必须翻倍，否则会把右引号转义掉。
      out->append(backslashes * 2, L'\\');
      break;
    }
    if (*it == L'"') {
      out->append(backslashes * 2 + 1, L'\\');
    } else {
      out->append(backslashes, L'\\');
    }
    out->push_back(*it);
  }
  out->push_back(L'"');
}

// 组装 launch 模式的 lpCommandLine：首 token 必须是 exe 自身（CreateProcessW 约定），
// 其后是用户配置的游戏参数。exe 强制加引号（历史行为逐字节保持：普通路径下输出与旧的
// `L"\"" + exe + L"\""` 完全一致，同时顺带修好路径以反斜杠结尾这种边角）。
//
// [extra_args] 为空时输出与历史实现逐字节相同 —— 未配置参数的用户不受任何影响。
inline std::wstring BuildLaunchCommandLine(
    const std::wstring& executable,
    const std::vector<std::wstring>& extra_args) {
  std::wstring command_line;
  AppendQuotedArgument(executable, /*force_quotes=*/true, &command_line);
  for (const std::wstring& argument : extra_args) {
    command_line.push_back(L' ');
    AppendQuotedArgument(argument, /*force_quotes=*/false, &command_line);
  }
  return command_line;
}

}  // namespace fushi_voice_hook

#endif  // FUSHI_LAUNCH_COMMAND_LINE_H_
