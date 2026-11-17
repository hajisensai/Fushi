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
    另一条（提交 `4e1d78fa2f8`）：替换锁的字节偏移同一目标在各 isolate 里相同、不同目标不同。
  - `packages/fushi_engine/test/utils/atomic_text_file_concurrent_test.dart` 3 条真并发压测
    （提交 `4e1d78fa2f8` 起各平台都跑，原先 `@TestOn('!windows')`）：同 isolate 12 个写者并发写
    同一目标、四个 isolate 并发写、两个 `MangaOcrFilePageCache` 并发写同一页后读回完整结果——
    全部写者成功。
  - `packages/fushi_engine/test/utils/atomic_text_file_concurrent_windows_test.dart` 4 条
    （`@TestOn('windows')`，提交 `4e1d78fa2f8` 重写；原先那条钉的是「落败的写者干净地失败」）：
    同 isolate 12 个写者 × 5 轮全部成功、目标目录里只有目标本身；四个 isolate 并发写同一目标、
    同时各写各的别的目标，全部成功；锁文件在系统临时目录、始终 0 字节，替换失败的写者不把锁
    带走；锁文件被删后下一次写入照常。把互斥拿掉这两个文件在 Windows 上 5 条变红。
- **Windows 上两个写者同时替换同一目标**（提交 `4e1d78fa2f8` 修掉）：两个 rename 在同一瞬间
  替换同一个目标时，`MoveFileEx` 让其中一个以「拒绝访问」（errno 5）失败——本机实测同 isolate
  12 个并发写者 5 轮 31 次失败、4 个 isolate 各 100 次写入各 14～17 次失败、4 个进程各 400 次
  写入各 23～39 次失败。唯一临时名不解决这个。
  - 谁和谁会撞：同一页的逐页缓存，确定有的是整卷任务的 isolate 与阅读器页级会话的 isolate
    （同进程不同 isolate）。另外两类是按代码结构推出来的、没有逐一复现：另一个进程
    （`fushi_server` 的 `ocr` 命令直接对书目录跑，与正在跑的服务端可以是同一本书）；Lens /
    系统 OCR 的逐页缓存不在 OCR isolate 里写，整卷与页级同时写同一页时是同 isolate 的并发。
  - 没走「同一目标只有一个写者」：写者在不同 isolate 里各持一个缓存对象，归一要把所有 isolate
    的写入转发给一个属主 isolate，跨进程的那一类仍然管不到。
  - 做法：`writeTextFileAtomically` 在 Windows 上把「替换目标」这一步互斥
    （`atomic_text_file.dart` 的 `_replaceTarget`）。锁是系统临时目录里一个固定锁文件
    （`fushi-atomic-write.lock`）上、按目标规范化路径的 FNV-1a 哈希取的一个字节的区间锁
    （`RandomAccessFile.lock` 阻塞独占 = `LockFileEx`）：按句柄算，同进程不同 isolate、不同
    进程都互斥，不同目标互不相干。本 isolate 内先在一条队列上排队，任何时刻最多一个锁请求
    交给 IO 线程去等。临时文件照旧在锁外写，锁里只有 rename。没有重试、没有延迟。
  - 原子性不变（仍是写临时文件再 rename 覆盖）；持锁者崩溃或被杀时句柄随进程关闭、系统自动
    放锁；锁文件始终 0 字节、整个系统一份、不在目标目录里，目标旁边不多任何文件。
  - POSIX（macOS / Linux / Android / iOS）不加锁：那里的 rename 原子且可并发，本来就全部成功；
    而且 `dart:io` 在这些平台上的文件锁按进程算，同进程的 isolate 之间互斥不了。各平台结局
    一致：全部写者成功。
- **备注**：
  - **真机复测未做，待补**：Windows 桌面并发 ≥2 时整卷识别与阅读器页级识别撞同一页，没在真 app
    里验过；跨进程只用四个 `dart` 进程手工量过（加锁 0 次失败，不加锁各 23～39 次），没有
    自动化测试。
  - **还剩一种「拒绝访问」（没修）**：Windows 上有人正把目标打开着读时，rename 同样失败——
    `dart:io` 打开文件不带 `FILE_SHARE_DELETE`。本机实测一个读者循环读、一个写者写 300 次，
    加不加上面的锁都有 50～77 次写入失败。读者不经过这个 helper。要撞上得是「同一页已经有人
    写过、另一个写者正要再写、同一毫秒又有人在读它」。修法是让读也取同一个字节的共享锁，要改
    `MangaOcrFilePageCache.read`（`manga_ocr_folder_job.dart`）与 Lens 缓存的读——这两个文件
    登记在别的在途分支名下，本条没动。
  - 路径写法不同但指向同一个文件（junction / 符号链接 / 8.3 短名）的两个写者算不到同一个字节
    上，互斥不了；两个进程的系统临时目录不同（`TEMP` 不一样）时也互斥不了，退回修之前的行为。
  - 进程在写入中途被杀会留下一个 `.tmp`（固定名时代会被下一次写入覆盖，现在不会）。
  它不以 `.json` 结尾，不会被当成缓存读到；随「重新识别」清缓存目录或删书一起消失。没有另做
  启动清扫。
