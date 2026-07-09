## BUG-677 · 书架书籍进度「还是没有」——复诉根因=旧包(debug.6783)，BUG-659 修复已在 develop(TODO-1346)

- **报告**：2026-07-09（用户复诉：「书籍的进度还是没有啊」，续 BUG-659「进度好像没了·显示短板已修」）。
- **真实性**：❌ **非新 bug / 非「修了没接上」——疑旧包，已在 develop 修复且已被测试覆盖**。沿真实代码路径 + 比对用户本机 DB（`D:/APP/HIBIKI_date/support/hibiki.db`，只读）+ 用户安装记录逐条核实：BUG-659 的 `computeBookProgress` 修复正确、已接进渲染路径、已被单测覆盖用户真实书形状；用户仍看不到进度是因为**在跑修复前的旧包**。

### 排查证据（PM 假设 A 旧包 / B 修不足 二选一——判 A）

- **修复正确且已接进渲染路径**（沿 `hibikiBooksProvider -> getBooksFromDb -> _bookToMediaItem -> computeBookProgress -> MediaItem.position/duration`，再到 `card_widgets.part.dart:458 _progressBar` = `item.position/item.duration`）：
  - `reader_hibiki_source.dart:49 computeBookProgress` 纯函数：`position = 前面各章 characters 之和 + clamp(charOffset,0,本章 characters)`，`duration=全书字数`；已在 `_bookToMediaItem`（`reader_hibiki_source.dart:380`）调用并把 `prog.position/prog.duration` 写进 `MediaItem`（`:385-386,398-399`）。
  - 进度条渲染无条件（`buildMediaItem -> buildMediaItemContent(:1243) -> _bookCardLayout(metadata: _progressBar(item))`，`_progressBar` 恒返回 `LinearProgressIndicator`）。`_progressBar` 早在 TODO-587 就存在，BUG-659 只改了 position/duration 的算法，没动渲染——所以「进度条不显示」实为「进度值算成近 0」。
  - 已有单测覆盖用户真实书形状：`reader_hibiki_source_test.dart:925 computeBookProgress` 组用**安達としまむら2 现场章字数数组**（前 12 章含前言=184、当前章 15521）断言 charOffset 计入使进度前进、越界 clamp<=100%、-1 哨兵当 0、老书分母 0 回退章级、无位置=0%、无章结构 (0,1)。→ **B（修不足/没接上）被排除**。

- **用户在跑的是修复前的旧包 debug.6783（首要且决定性证据）**：
  - 安装记录 `D:/APP/HIBIKI_date/support/updates/hibiki-1.0.1-debug.6783-windows-setup.install.log`（mtime **2026-07-06 21:22**）= 用户**最后安装**的构建；`updates/` 里没有 6783 之后的任何下载（最新 meta 就是 6783）。
  - debug.6783 由 **2026-07-06 21:21 的 develop 态**（commit `2b2cf0b8b`，约 `1.0.1+513/+515`）打包，该态 `reader_hibiki_source.dart` **0 处 `computeBookProgress`** → 确为修复前。
  - 修复 `computeBookProgress`（commit `ae8ee3068`，2026-07-09 01:44，`feat(shelf,video)...TODO-1346/BUG-657`）→ 合入 `dfd7b35f8`（02:03）→ 集成 `e86b82fae`（02:31，`1.0.1+603`）；首个含修复的 debug 构建约 debug.7xxx（用户 `update_check_cache.latestTag=1.0.1-debug.7157`、`lastCheckEpochMs=2026-07-09 10:43` 已见到它，但 `update_auto_install=false` 且未下载/安装）。
  - 用户 DB 显示 07-09 仍在读（安達としまむら2 `updated_at=12:57`），但跑的是 6783 → **今天读的书在 6783 上按旧算法忽略 charOffset，进度算成近 0**。

- **对用户真实 7 本书，旧包(6783) vs 修复后的逐本进度**（`reader_positions x epub_books.chapters_json` 真值算得，按最近阅读排序）：

  | 书(sec/charOffset) | 最近读 | 旧包 6783 | 修复后 |
  |---|---|---|---|
  | 安達2 (sec=12, co=12055) | 07-09 12:57 | **0.19%** | **12.88%** |
  | 安達3 (sec=7, co=0) | 07-09 11:37 | 0.00% | 0.00%（诚实：停在第 7 节标题页，正文尚未开始） |
  | 安達 (sec=21, co=0) | 07-09 11:32 | 99.35% | 99.35% |
  | 安達9 (sec=6, co=0) | 07-06 17:42 | 0.00% | 0.00%（诚实：停在第 6 节首内容页起点） |
  | 転生王女 (sec=22, co=-1) | 06-30 | 100% | 100% |
  | リビルド (sec=8, co=11120) | 06-28 | **0.15%** | **5.96%** |
  | 謎解き (sec=30, co=-1) | 06-27 | 30.86% | 30.86% |

  → 用户今天正在读的 **安達2 在旧包只显 0.19%（看着像空条）**，正是「进度还是没有」的观感来源；修复后是 12.88%（可见）。older 完成的书（安達/転生王女/謎解き）旧包也显进度，所以复诉集中在近读的、旧包算成近 0 的书。

- **剩余诚实 0%（非 bug、非 BUG-659 回归）**：安達9(sec=6)、安達3(sec=7) 修复后仍 0%，因为读者停在「前面全是前言(0 字)、当前节是首个内容/标题节起点」→ 已读正文字符=0。这是按字符计数的诚实结果（0 字=0%），不是「进度丢失」，也不宜为好看而灌水（会谎报进度、破坏其它书的正确性）。此类书用户升级后仍会见 0%，属预期；若后续要区分「已开卷未读正文」与「从未打开」，是另一个设计项，不在本 bug 范围。

### 结论 / 处置

- **不改产品代码**：BUG-659 的 `computeBookProgress` 修复正确、已接进渲染、已被单测覆盖用户真实书形状。复诉根因是**用户仍在跑修复前的旧包 debug.6783（2026-07-06）**，需更新到含修复的构建（>= 首个 develop@+603 之后的 debug，约 debug.7xxx）。升级后今天在读的安達2 等会从近 0% 变为真实进度（安達2->12.88%）。
- **[x] ① 无需修复（已在 develop 修复）** — 修复 commit `ae8ee3068`（`computeBookProgress` + `_bookToMediaItem` 接线），集成 `e86b82fae`（`1.0.1+603`）。用户升级即生效。
- **[x] ② 已加回归守卫** — `hibiki/test/media/sources/reader_hibiki_source_test.dart` 新增「computeBookProgress wired + real-shelf data (BUG-677 复诉守卫)」组：(a) 源码守卫 `_bookToMediaItem` 必须调 `computeBookProgress` 且把 `prog.position/duration` 喂进 `MediaItem`（锁死「算了没接上=B」永不回归）；(b) 用户真实 リビルド 现场值(sec=8/co=11120) 断言章内 charOffset 让「旧包看着像 0」的书前进；(c) 安達9 现场值(sec=6/co=0，前节全前言) 断言诚实 0%（记录这是预期、不是 BUG-659 回归）。连同原 6 例共 9 例覆盖。

- **备注**：
  - 复诉的根因链：BUG-659 修复(07-09) 晚于用户最后安装的 debug.6783(07-06)；`update_auto_install=false` → 用户未自动装到含修复的 7xxx。
  - 与本地不入库的 `docs/REGRESSION_BUGS.md` 区分；本条为「疑旧包/已修」结论，非真代码 bug。
