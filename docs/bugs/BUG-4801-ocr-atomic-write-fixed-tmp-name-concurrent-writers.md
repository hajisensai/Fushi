## BUG-4801 · 漫画 OCR 逐页缓存的原子写用固定名 .tmp，并发写同一页时互相覆盖
- **报告**：2026-11-17（用户：代码审查，漫画优化清单第 16 条）
- **真实性**：✅ 真 bug。根因 `packages/fushi_engine/lib/utils/misc/atomic_text_file.dart:16`
  （`pr/manga-ocr-pipeline` `4a5fd7a06bb`；合并前是 `manga_ocr_folder_job.dart:306-321` 的同一
  写法）—— 临时文件是 per-target 固定名 `'${target.path}.tmp'`，注释写的是「并发写者由调用方
  串行化」，但调用方并没有串行化、也串行化不了：同一页的缓存会被不同 isolate 里的写者同时写——
  整卷任务与阅读器的页级会话；取消 / 暂停后还在收尾的旧整卷 isolate 与新起的整卷 isolate
  （BUG-4800，旧的正在收尾的那一页恰好是新任务要补的第一页）。两个写者共用一个临时文件：一个
  写到一半时另一个 rename，目标就是半截 JSON（读侧当缓存未命中，这页白识别）；或者一个把文件
  rename 走了，另一个的 rename 找不到源而抛错，整卷任务以失败收场。
- **[x] ① 已修复** — 提交 `18c64f2557c`。`writeTextFileAtomically` 的临时
  文件改成每次写入一个唯一名（`temporaryFileForAtomicWrite`）：`<target>.<pid>-<本 isolate 随机
  标签>-<序号>.tmp`。序号是顶层变量、每个 isolate 各一份，所以跨 isolate 的唯一性靠随机标签，
  跨进程靠 pid。各写各的临时文件，后 rename 的覆盖先 rename 的，两份都是完整内容。写入或
  rename 失败时删掉本次的临时文件再抛原错误（唯一名不会被下一次写入覆盖）。四个调用点（本地
  逐页缓存、整卷中间产物、Lens / 系统 OCR 逐页缓存、已缓存整卷产出）都经这个 helper，一起受益。
- **[x] ② 已加自动化测试** —
  - `packages/fushi_engine/test/utils/atomic_text_file_test.dart`「BUG-4801」组 3 条（各平台都跑）：
    同 isolate 与跨 isolate 取到的临时名互不相同且在目标同目录；确定性交错（一个写者写到一半时
    另一个整个写完，各自落下完整内容）；写入失败不留临时文件。源码守卫补一条：helper 里不得再
    出现 `${target.path}.tmp` 固定名。另一条（提交 `7c3e8af6646`）：rename 失败后临时文件也
    删不掉时，抛出去的仍是 rename 的错误——原先清理的 `deleteSync` 没有保护，会顶掉原错误。
  - `packages/fushi_engine/test/utils/atomic_text_file_concurrent_windows_test.dart` 1 条
    （`@TestOn('windows')`，提交 `7c3e8af6646`）：12 个写者并发写同一目标，落败的写者只以
    `FileSystemException` 收场，目标是其中一份完整内容，不留临时文件——钉的是下面那条平台限制
    的边界，不是把它消掉。
  - `packages/fushi_engine/test/utils/atomic_text_file_concurrent_test.dart` 3 条真并发压测
    （`@TestOn('!windows')`）：同 isolate 并发写同一目标、两个 isolate 并发写、两个
    `MangaOcrFilePageCache` 并发写同一页后读回完整结果。
- **备注**：
  - **真机复测未做，待补**：Windows 桌面并发 ≥2 时整卷识别与阅读器页级识别撞同一页，实际撞不撞
    得上下面这条限制，没在设备上验过。
  - **Windows 上没完全消掉**：两个写者在同一瞬间 rename 到同一个目标时，`MoveFileEx` 会让其中
    一个以「拒绝访问」（errno 5）失败——本机实测同 isolate 12 个并发写者必现。这是平台限制，
    不是临时名的问题：目标仍是另一个写者的完整内容，失败的那个写者照常抛错（整卷任务会以失败
    收场，重跑从缓存续）。BUG-4800 修掉之后，注册表下的新旧整卷任务不再重叠，剩下能撞上的只有
    「整卷任务与页级会话在同一毫秒写完同一页」。要彻底消掉得做跨 isolate 的文件锁，本条没做。
  - 进程在写入中途被杀会留下一个 `.tmp`（固定名时代会被下一次写入覆盖，现在不会）。
  它不以 `.json` 结尾，不会被当成缓存读到；随「重新识别」清缓存目录或删书一起消失。没有另做
  启动清扫。
