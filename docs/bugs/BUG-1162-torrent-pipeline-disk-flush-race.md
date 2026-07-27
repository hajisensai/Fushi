## BUG-1162 · hibiki_torrent 端到端测试在字节落盘前就比对，CI Windows 约 24% 概率红
- **报告**：2026-07-27（用户：CI 巡检）
- **真实性**：✅ 真 bug（测试自身的时序假设错，不是引擎功能坏）。根因
  `packages/hibiki_torrent/test/embedded_pipeline_test.dart:151`（修复前）——
  测试等到 `isFinished` / `progress>=1.0` / `left==0` / `haveCount==numPieces`
  就直接 `File(contentPath).readAsBytesSync()` 逐字节比对。这四个信号说的都是
  「piece 已在内存里校验通过」，**不是**「字节已经躺在文件系统里」：写盘 job 还
  排在 libtorrent 的 disk io 线程上，且 2.x 的 mmap 磁盘后端写进去的是映射视图，
  Windows 不保证映射视图与 `ReadFile` 之间的一致性；内容文件又是稀疏的，尚未落
  实的尾部区域直接读成 0。
  表现（workflow `Build and Test …` 的 windows job，步骤
  `Run hibiki_torrent FFI tests against the freshly built DLL`）：
  `downloaded bytes must equal seeded bytes` → `at location [8273920] is <0>
  instead of <38>`，8MiB 文件距尾约 114KB 处一串 0。近 17 次 develop 运行挂 4 次
  （约 24%），失败偏移恒定落在文件尾部（`8273920` ×2、`8257536` ×2）。
  它是该 workflow 唯一会判红的失败源（android job 有 `continue-on-error`）。
- **[x] ① 已修复** — 把「读盘比对」挪到 `leecher.close()` **之后**：销毁
  `lt::session` 会走完关停流程，等 disk io 线程把写盘 job 做完、解除映射并关句柄，
  这是唯一确定性的落盘完成信号（没有加任何 sleep / 重试 / 超时放宽）。原来排在
  比对之后的「移除（连数据）」用例改为用 rig 的 .torrent 把同一个种子加进一个
  不联网的新 session（零 peer）再删，删除路径覆盖面不变。
  改动：`packages/hibiki_torrent/test/embedded_pipeline_test.dart`。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/torrent/torrent_disk_flush_order_guard_test.dart`：纯文本
  守卫，钉住「`readAsBytesSync` 必须排在 `leecher.close()` 之后」「逐字节比对断言
  不许被删」「close 与比对之间不许出现 `Future.delayed` / `sleep` / `_pollUntil`
  这类『等它落盘』的补丁」。放在主 app 测试套件里，因为
  `packages/hibiki_torrent` 自己的测试在没有 DLL 的平台整组 skip，只有 Windows
  CI 会真跑。
- **备注**：本机（NVMe，负载轻）复现不出这个竞态 —— 专门写的探针在关闭 session
  **之前**读盘，8MiB × 8 次、128MiB × 3 次全部字节一致，说明本地写盘快到窗口关不
  上；证据只在 CI 上。因此「本地连跑 N 次全绿」不能证明根除，真正的依据是读盘
  被挪到了确定性的落盘屏障之后。
