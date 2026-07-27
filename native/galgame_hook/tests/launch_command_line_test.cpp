// launch 模式命令行组装的根因回归：`--arg` 的每个值必须原样成为游戏的一个 argv。
//
// 断言分两层：
//   1. 逐字节期望串（含「无 extra args 时与历史输出完全一致」的向后兼容锁）；
//   2. 真的把组装结果喂给 `CommandLineToArgvW` 反解，逐 token 比对 —— 这才是子进程
//      实际看到的东西，光比对字符串证明不了转义是对的。

#include <windows.h>
// WIN32_LEAN_AND_MEAN 把 CommandLineToArgvW 挡在 windows.h 之外，必须显式引入。
#include <shellapi.h>

#include <cassert>
#include <cstddef>
#include <string>
#include <vector>

#include "launch_command_line.h"

namespace {

// 把组装好的命令行按 Windows 规则反解，模拟游戏进程收到的 argv。
std::vector<std::wstring> ParseCommandLine(const std::wstring& command_line) {
  int count = 0;
  wchar_t** argv = CommandLineToArgvW(command_line.c_str(), &count);
  assert(argv != nullptr);
  std::vector<std::wstring> parsed;
  for (int i = 0; i < count; ++i) parsed.emplace_back(argv[i]);
  LocalFree(argv);
  return parsed;
}

// exe + 参数列表 → 反解结果必须恰好是 [exe, args...]，一个不多一个不少。
void AssertRoundTrip(const std::wstring& exe,
                     const std::vector<std::wstring>& args) {
  const std::wstring command_line =
      hibiki_voice_hook::BuildLaunchCommandLine(exe, args);
  const std::vector<std::wstring> parsed = ParseCommandLine(command_line);
  assert(parsed.size() == args.size() + 1);
  assert(parsed[0] == exe);
  for (std::size_t i = 0; i < args.size(); ++i) {
    assert(parsed[i + 1] == args[i]);
  }
}

}  // namespace

int main() {
  using hibiki_voice_hook::AppendQuotedArgument;
  using hibiki_voice_hook::BuildLaunchCommandLine;

  // ── 1. 向后兼容：没有 extra args 时，输出必须与历史实现逐字节相同。
  assert(BuildLaunchCommandLine(L"C:\\Games\\Title\\game.exe", {}) ==
         L"\"C:\\Games\\Title\\game.exe\"");
  assert(BuildLaunchCommandLine(L"C:\\Program Files\\T\\game.exe", {}) ==
         L"\"C:\\Program Files\\T\\game.exe\"");

  // ── 2. 逐字节转义期望。
  // 不含空格/引号的参数不加引号（保持命令行可读，也贴合手写习惯）。
  assert(BuildLaunchCommandLine(L"C:\\g.exe", {L"-windowed"}) ==
         L"\"C:\\g.exe\" -windowed");
  // 含空格必须整体加引号，否则游戏会看到两个 argv —— 这是本次修的核心 bug。
  assert(BuildLaunchCommandLine(L"C:\\g.exe", {L"--save=C:\\My Saves\\s"}) ==
         L"\"C:\\g.exe\" \"--save=C:\\My Saves\\s\"");
  // 内嵌引号要用反斜杠转义。
  assert(BuildLaunchCommandLine(L"C:\\g.exe", {L"say \"hi\""}) ==
         L"\"C:\\g.exe\" \"say \\\"hi\\\"\"");
  // 结尾反斜杠（目录路径）必须翻倍，否则会转义掉右引号、吞掉后面所有参数。
  assert(BuildLaunchCommandLine(L"C:\\g.exe", {L"C:\\My Dir\\", L"-b"}) ==
         L"\"C:\\g.exe\" \"C:\\My Dir\\\\\" -b");
  // 空串参数必须显式写成 ""，否则会整个消失、后续参数集体错位。
  assert(BuildLaunchCommandLine(L"C:\\g.exe", {L"", L"-b"}) ==
         L"\"C:\\g.exe\" \"\" -b");
  // 中间的普通反斜杠不是转义符，不能翻倍。
  assert(BuildLaunchCommandLine(L"C:\\g.exe", {L"a\\b"}) ==
         L"\"C:\\g.exe\" a\\b");

  // ── 3. 真反解 round-trip：子进程实际拿到的 argv。
  AssertRoundTrip(L"C:\\Games\\Title\\game.exe", {});
  AssertRoundTrip(L"C:\\Program Files\\Title\\game.exe", {});
  AssertRoundTrip(L"C:\\g.exe", {L"-windowed", L"-nosound"});
  AssertRoundTrip(L"C:\\Program Files\\T\\g.exe",
                  {L"--save=C:\\My Saves\\slot 1", L"-lang", L"ja"});
  AssertRoundTrip(L"C:\\g.exe", {L"say \"hi\"", L"a\\b", L"C:\\dir\\"});
  AssertRoundTrip(L"C:\\g.exe", {L"", L"  ", L"\t"});
  AssertRoundTrip(L"C:\\g.exe", {L"a\\\\\"b", L"\\\\server\\share\\"});
  AssertRoundTrip(L"C:\\g.exe", {L"日本語 引数", L"--path=D:\\ゲーム\\セーブ"});

  // ── 4. force_quotes 语义（exe 永远带引号，参数按需）。
  std::wstring buffer;
  AppendQuotedArgument(L"plain", /*force_quotes=*/false, &buffer);
  assert(buffer == L"plain");
  buffer.clear();
  AppendQuotedArgument(L"plain", /*force_quotes=*/true, &buffer);
  assert(buffer == L"\"plain\"");
  // 空指针不崩。
  AppendQuotedArgument(L"plain", /*force_quotes=*/true, nullptr);

  return 0;
}
