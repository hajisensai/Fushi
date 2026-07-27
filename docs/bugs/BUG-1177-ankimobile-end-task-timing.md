## BUG-1177 · AnkiMobile 制卡测试用 10ms 定时假设等真实 I/O，36% 概率红
- **报告**：2026-07-28（用户：）
- **真实性**：✅ 真 bug（测试自身缺陷，非产品缺陷）。根因 `hibiki/test/anki/ankimobile_repository_test.dart:269`（原）：用 `await Future<void>.delayed(const Duration(milliseconds: 10))` 当同步原语，睡 10ms 就断言 `end-background-task` 已入列。该事件的真实路径是 `hibiki/lib/src/anki/ankimobile_repository.dart:267` `Timer.run(closeLater)` → `:242 await server?.close()` → `:509-523` `_server.close(force: true)` **加 `_tempDir.delete(recursive: true)`（真删一个含 4 个媒体文件的 Windows 临时目录）** → `:244` 才 `await _endMediaImportBackgroundTask()`。这段是真实 socket + 文件系统 I/O，冷路径或机器有负载时轻易 >10ms，断言拿到的 `events` 就只有前两项。同文件 `:355` 是同型第二处：`Future.delayed(550ms)` 猜 `mediaServerLifetime(500ms)` 定时器加 close + 删目录能在 50ms 内跑完。
- **复现**：空载机器 20/20 全绿（复现不出）；**10 个 `flutter test` 并发施压后 2/10 红**，报错正是 `Actual: ['begin-background-task', 'open-ankimobile']`（缺 `end-background-task`）。即这是负载相关的竞态，用户观测到的 36% 属实，只是需要负载才暴露。
- **[x] ① 已修复** — 不改大 10ms（那是补丁式绕过），改为等**真实完成信号**：测试注入的 `endMediaImportBackgroundTask` 回调里 complete 一个 `Completer<void>`，断言前 `await backgroundTaskEnded.future`。两处（`:269` / `:355`）同一改法。该回调就是被断言的那个事件本身，等它 = 等真实完成，零时间常数。
- **[x] ② 已加自动化测试** — `hibiki/test/anki/ankimobile_repository_test.dart`（`mineEntry exposes local media as downloadable URLs for AnkiMobile` / `media URLs survive source temp cleanup until AnkiMobile fetches`）。这两条测试自身就是最强可落地层：改后若完成信号回归，它们**确定性**变红，而不是像以前那样按机器负载概率性变红。
- **验证**：修复后目标用例 `--plain-name` 单跑 20/20 绿；10 并发施压下断言失败 0 次（对照组同条件 2/10 红）。负向验证：把 `await backgroundTaskEnded.future` 换回 `Future.delayed(10ms)`，同一并发条件复现原症状。
- **备注**：与 BUG-1178 / BUG-1179 同批 —— 都属「在真实 I/O 上做定时假设」这一类模式。
</content>
