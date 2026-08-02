# 分级快车道：加功能 / 修 bug / 合并的提速流程

目标：单功能或单 bug 从 ~30 分钟压到 **~10–15 分钟**。手段只有三个——**消灭空等、按难度分工、验证按爆炸半径分级**。本文件是 [CLAUDE.md](../../CLAUDE.md) 「多使用子代理」和「验证」条目的展开，不改变真机验收、发布通道、提交纪律等硬规则。

## 现状 30 分钟花在哪（耗时解剖）

| 阶段 | 现状耗时 | 浪费点 |
|---|---|---|
| worktree + full bootstrap | 3–5 min 串行阻塞 | 根因分析根本不需要 `.dart_tool`，却在干等 pub get |
| 定位 / 根因分析 | 5–10 min 串行 | 多个独立疑点逐个查 |
| 实现 | 5–10 min | 机械面（样板/测试/多文件同构改动）没拆出去 |
| 验证 | 8–15 min | 小改动也跑全量 `flutter test`，而 CI 本来就会兜底 |
| 收尾（bug 文档/commit/PR） | 2–3 min | 等测试跑完才开始写 |

## 三条军规

1. **永不空等**：任何 >30 秒的命令（bootstrap / test / gradle / build）一律后台跑，等待期间推进别的步骤。
2. **按难度分工**：琐碎活主代理直接干（派发开销 > 收益）；机械面拆给子代理并行；根因、数据结构、整合这些错了会返工的难点主代理亲自把关。绝不让两个代理重复做同一件事。
3. **验证按爆炸半径分级**：分支上定向验证 + PR CI 兜底全量；合入 `develop` 前才要求本地全量。

## 难度分级 × 分工

| 级别 | 判据 | 谁干 | 分支上的验证 |
|---|---|---|---|
| **S 琐碎** | 文档、注释、单行改动、纯重命名 | 主代理直接干，**不派子代理**（派发开销 > 收益） | `git diff --cached --check`；涉及 Dart 再加定向 analyze |
| **A 小修** | 单文件或单模块，根因明确 | 主代理修核心；测试可拆一个子代理并行写 | `flutter analyze` 全量 + 定向 `flutter test <目标> --no-pub` |
| **B 功能 / 复杂 bug** | 跨模块、多文件、时序/状态/平台边界问题 | 主代理定根因和数据结构；机械面（样板、i18n、多文件同构、测试）拆子代理并行 | 定向 + 相邻功能测试；全量交 PR CI |
| **C 大型 / 长周期** | 多阶段、需分批审查 | 按 claim 拆多 agent；integration owner 统一收口 | 本地全量（bash 环境） |

**子代理纪律**（既有规则，重申）：后台派发，主代理不空等回传；每个子代理给明确文件清单，避免撞同一脏文件；强顺序依赖的步骤别硬拆；子代理回传必须核关键证据（`git diff --stat` / `test -f` / grep），不可全信叙述。

## 标准时间线（B 级功能，目标 ~12 min）

```
t=0   EnterWorktree → setup_worktree -SkipBootstrap（秒级，只搬密钥）
t=0   ↳ 后台: powershell -File tool/bootstrap.ps1
t=0   ↳ 并行: 主代理读代码定根因；≥2 个独立疑点 → 子代理并行定位
t=3   根因确定 → 主代理写核心修改；同时子代理并行写测试/机械面
t=8   bootstrap 已就绪 → dart format 改动文件 + flutter analyze + 定向 test --no-pub
t=8   ↳ 测试跑的同时: 子代理建 bug 文档 (dart run tool/bug.dart new)，
      主代理写 commit message / PR 描述
t=12  测试绿 → commit → push → draft PR（CI 跑全量兜底）
```

S/A 级同理裁剪：S 级连 worktree bootstrap 都可 `-SkipBootstrap` 到底（纯文档不需要 pub get）；A 级只是没有并行实现面。

## 验证分级细则

- **定向测试** = 改动直接覆盖的 test 文件 + 相邻功能的 test 文件，`flutter test test/<路径> --no-pub`。
- **`flutter analyze` 全量在 push 前必跑**（含 test 目录）——它本身只要秒级~1 分钟，而 CI 把 warning 当致命，省这一步只会在 CI 上浪费一轮。
- **分支 draft PR**：定向测试绿 + 全量 analyze 绿即可 push；全量 test 由 CI 兜底（真单测门是 **Build Release APK 的 Run unit tests**，不是 Build and Test）。声明「修好了」的真机复测门槛**不变**（[integration-testing.md](integration-testing.md)）。
- **合入 `develop`**：integration owner 本地全量 analyze + 全量 test **不变**（bash 环境跑；别 `| tail` 吞退出码；重叠跑会互抢 `sqlite3.dll`，见下节）。

## 并发伪红判别

本机常态是 5~10 个 agent 同时跑测试，**测试红有相当比例不是被测代码坏了**。下面三类都是实测形态，各有独立的定性办法。

**遇红先分型，再动手**——断言失败 / suite 装载失败 / 零输出，三者的处置完全不同，串了型就是白追一轮。

| 形态 | 症状 | 定性办法 | 处置 |
|---|---|---|---|
| ① 互抢 `sqlite3.dll` | 多个 `flutter_tester` 争用同一份 native 库；无关文件莫名失败，或进程不报错只静停 | 数一下本机在跑的并发测试进程（`dart` / `flutter_tester`） | 别重叠跑；错开或串行化后单独重跑该目标确认 |
| ② 宿主 IPC 崩溃 | VERDICT `FAILED - ...(N 个 error event(s), M 个 tests completed)`，但**零断言失败**；日志里 `Bad state: Cannot close sink while adding stream.` @ `flutter_tools/flutter_platform.dart:766` → `Connection closed before test suite loaded` | 本质是 suite **装载**失败，不是断言失败。**分片重跑并对账**：各分片完成数之和 ≈ 原批完成数 + 没装载上的数量 | 账对得上 → 伪红，按分片结果判绿，并在回报里写清对账数字 |
| ③ 结果文件被抢 | 跑很久**零输出、像卡死**；既没断言失败也没装载失败 | 看有没有并发进程在写同一份 `.codex-test/flutter-test/flutter_test.jsonl`（`flutter_test_failures.dart` 的默认输出目录就是 `../.codex-test/flutter-test`，所有 agent 共用） | **规避优先于诊断**：每次跑都显式给独立输出，`--output-dir=../.codex-test/flutter-test-<任务名>` |

出处：② PR#716 实测（7 路并发 / 27 个 dart+flutter_tester 进程；分片对账 325 + 2602 = 2927 ≈ 2923 完成 + 4 个没装载上）；③ PR#728 实测。

### 判别纪律（三条，不可打折）

1. **先分型再动手**：先看是断言失败、suite 装载失败还是零输出。只有断言失败才是「被测代码可能坏了」，另两类先按并发伪红查。
2. 🔴 **不许拿「可能是并发伪红」当借口跳过真红**。伪红是要**证明**出来的（进程数、分片对账、并发结果文件），不是默认假设。判不明就如实写一句「这条红我没判明，交给 CI」并继续推进——**不要反复重跑碰运气，也不要默认它是假的**。
3. 🔴 **零测试执行的红也不算红**。变异测试里删掉整行造成编译失败、`0 tests ran` 的，那不是行为红，是**无效变异**，必须把变异改成能编译的形态再跑。这与「零测试执行的绿是假绿」（BUG-1157）是同一枚硬币的两面：**`N tests ran` 的 N 本身就是判据的一部分**，N=0 时 PASSED 和 FAILED 都不成立。

## 合并后必跑：目录枚举型守卫清单

### 由来（真事，不是预防性条款）

2026-08-02 一天内**连续四次**「刚合的 PR 把一条红带进 `develop`」，每次都靠下一条线程偶然发现；其中一条**在 `develop` 上躺了整整一天、跨了 5 条 PR** 没人察觉。同类修复在 git log 里是一串：`724b7d3f7`（PR#679 新守卫手写 maskComments → develop 单测门红 BUG-1358）、`3d5ffb77f`（合集三处裸 Material chrome → develop 守卫红 BUG-1392）、`9fd30d281`（制卡上下文守卫锚点失效 → develop 红）、`e4ca65212`（MD3 守卫红修复）。

根因**不是谁不小心**，是结构性的：

> **定向测试按功能域挑，而目录枚举型守卫的触发面与功能域正交。**

一条改视频合集 UI 的 PR，定向测试会挑 `test/media/collections/*`、`test/pages/video_*`——没有人会想到去跑 `test/settings/md3_design_system_static_test.dart`。可那条守卫扫的是 `lib/src` **全树**，合集 PR 新写的裸 `Card(` 正落在它的扫描面里。**按名字挑测试，就永远挑不到它**；漏掉不是概率问题，是必然。

补上「每条 PR 合入后固定加跑这批」之后，累计 **30 条合并零红**。

### 判据：目录枚举型 vs 点名清单型

区分只有一条，**不看名字、不看所在目录、不看叫不叫 guard**——看**被检对象是怎么来的**：

| 类型 | 被检对象来源 | 新 PR 的新文件 | 进清单？ |
|---|---|---|---|
| **目录枚举型** | `Directory(...).listSync(recursive: true)` 现场枚举 | **自动纳入扫描面** | ✅ 进 |
| **点名清单型** | 源码里硬编码的文件路径常量表 | **天然在扫描集外** | ❌ 不进 |

点名清单型是本仓「静态守卫」的大多数（例如 `md3_design_system_static_test.dart` 63 个 test 里有 62 个是点名的）。它们对新 PR 的新文件**零覆盖**——加进清单不会多抓到任何东西，只会让清单变长。它们由定向测试覆盖，位置正确。

**只枚举某个子树**的同样不进（`lib/src/sync` 的空 catch / PIN / TLS 三条、`lib/src/settings` 的旧 pref key、5 个媒体页根的焦点所有权……）：改动落在那个子树时，定向测试本来就会挑到它。

### 清单（35 条，2026-08-02 反向枚举全量得出；TODO-2707 补入三份新语料守卫）

| 测试 | 扫描根 | 守什么 |
|---|---|---|
| `test/tools/source_guard_adoption_test.dart` | `test/` 全树 | 禁手写注释剥离，一律走 `helpers/source_guard.dart` |
| `test/settings/md3_design_system_static_test.dart` | `lib/src` 全树（仅其中 1 个 test） | 页面 chrome 不得重开本地 MD3 决策（裸 `Card(`/`ListTile(`/`fontSize:`/`BorderRadius.circular(`…） |
| `test/tools/dart_source_no_raw_nul_guard_test.dart` | `hibiki/{lib,test}` + 5 个 `packages/*/lib` | `.dart` 不得含裸 NUL（git 判 binary 会静默丢改动） |
| `test/tools/duplicate_policy_naming_guard_test.dart` | `lib` + `test` 全树 | 7 个淘汰命名不得复活 |
| `test/tools/media_kind_persistence_guard_test.dart` | 6 个生产 `lib` 根 | MediaKind 持久化只经 `dbValue`/`compositeKey` |
| `test/tools/book_format_discipline_guard_test.dart` | `lib`+`test`+`hibiki_core/lib` | `BookFormat` 只经枚举落库/比较 |
| `test/tools/file_picker_discipline_guard_test.dart` | `lib` 全树 | 选择器走统一入口，裸调须登记 |
| `test/tools/image_picker_usage_guard_test.dart` | `lib` 全树 | 桌面可达代码不得直接用 `image_picker` |
| `test/tools/safe_file_name_guard_test.dart` | `lib` 全树 | Windows 非法文件名字符集单一真相源 |
| `test/tools/integration_test_no_tester_tap_guard_test.dart` | `integration_test/` 全树 | 集成测试禁坐标点击 |
| `test/tools/itest_focus_navigation_prerequisite_guard_test.dart` | `integration_test/` 全树 | 起真 app 的 itest 必须先开焦点导航 |
| `test/database/package_schema_version_literal_guard_test.dart` | `packages/*/test` 全树 | package 测试禁 `schemaVersion` 等值断言 |
| `test/sync/no_hardcoded_google_secret_test.dart` | `lib` 全树 | 源码不得出现 OAuth secret 明文 |
| `test/sync/mime_types_test.dart` | 6 个 `lib` 根 | 禁新增「扩展名 → image MIME」switch 副本 |
| `test/sync/desktop_lookup_foreground_guard_static_test.dart` | `lib/src` 全树 | 抢前台/任务栏闪烁只能走单一封装 |
| `test/storage/documents_whitelist_guard_test.dart` | `lib` 全树 | 新增 documents 子目录必须进迁移白名单 |
| `test/storage/path_rebase_coverage_guard_test.dart` | `lib` 全树（pref 扫描） | 新增路径形 pref / DB 列必须双向登记 |
| `test/focus/focus_architecture_static_test.dart` | `lib/src` 全树 | 焦点滚动必须走 `HibikiFocusScroll` |
| `test/lookup/auto_read_surface_coverage_guard_test.dart` | `lib` 全树 | 每个 `searchDictionary(` 调用点须声明接不接自动朗读 |
| `test/pages/lookup_overlay_dialog_gate_guard_test.dart` | `lib` 全树 | 查词浮层每个子项都能走到对话框隐藏计数 |
| `test/shortcuts/shortcut_channel_wiring_guard_test.dart` | `lib` 全树 | 开放的输入通道必须真有解析入口 |
| `test/webview/webview_render_process_gone_guard_test.dart` | `lib` 全树 | 每处 WebView 构造必须传 `onRenderProcessGone` |
| `test/widgets/horizontal_drag_scroll_guard_test.dart` | `lib` 全树 | 横向滚动区必须包 `HorizontalDragScrollable` |
| `test/widgets/reorderable_scale_safety_guard_test.dart` | `lib` 全树 | 禁用 SDK `ReorderableListView`/`GridView` |
| `test/media/collections/collection_asset_reclaim_test.dart` | `lib` 全树 | 禁裸调 DAO 删合集（须回收磁盘资产） |
| `test/media/drag_drop/drag_drop_platform_guard_test.dart` | `lib` 全树 | `desktop_drop` 只能被平台门控 wrapper 导入 |
| `test/media/media_cover_write_guard_test.dart` | `lib` 全树 | 封面写盘 → 驱逐缓存收口在 `MediaCoverService` |
| `test/media/sources/book_history_split_guard_test.dart` | `lib` 全树 | 书族源恒 `implementsHistory: false` |
| `test/media/video/real_path_directory_picker_test.dart` | `lib` 全树 | 生产代码不得用 iOS `FileType.audio` |
| `test/ios/info_plist_media_permission_guard_test.dart` | `lib` 全树（作谓词） | 用了相机/相册/音频就必须有 `Info.plist` 声明 |
| `test/i18n/i18n_completeness_test.dart` | `lib/i18n` 全部 17 份 | 17 语言 key 完整、无孤儿、插值一致 |
| `test/pages/reader_hibiki_page_source_corpus_test.dart` | `reader_hibiki/` part 目录枚举 | 合并语料覆盖每个 part（漏登记会让 90+ 条守卫真空通过） |
| `test/pages/reader_history_source_corpus_test.dart` | `reader_history/` part 目录枚举 | 同上，书架页语料 |
| `test/pages/video_hibiki_page_source_corpus_test.dart` | `video_hibiki/` part 目录枚举 | 同上，视频页语料 |
| `test/sync/sync_settings_schema_source_corpus_test.dart` | `sync_settings_schema/` part 目录枚举 | 同上，同步设置 schema 语料 |

一条命令跑完，**实测 207 tests**（2026-08-02，`origin/develop@c05a91edc` + PR#756）——比争论「这条该不该跑」便宜得多，所以**不要挑，整批跑**：

**N 的演进链要留着，别只写当前值**——「N 应该是多少」本身就是判空转的信号，只写当前值就丢掉了「它为什么变」：

| N | 条数 | 变化来源 |
|---|---|---|
| 194 | 32 | 初版（34 秒） |
| **207** | **35** | PR#756 补入三条合并语料守卫 |
| 225 | 35 | PR#760 给禁止型判据补 18 条自校验（**尚未合入**，合入后以此为准） |


```bash
cd hibiki && dart run tool/flutter_test_failures.dart --no-pub \
  --output-dir=../.codex-test/flutter-test-guards \
  test/tools/source_guard_adoption_test.dart test/settings/md3_design_system_static_test.dart \
  test/tools/dart_source_no_raw_nul_guard_test.dart test/tools/duplicate_policy_naming_guard_test.dart \
  test/tools/media_kind_persistence_guard_test.dart test/tools/book_format_discipline_guard_test.dart \
  test/tools/file_picker_discipline_guard_test.dart test/tools/image_picker_usage_guard_test.dart \
  test/tools/safe_file_name_guard_test.dart test/tools/integration_test_no_tester_tap_guard_test.dart \
  test/tools/itest_focus_navigation_prerequisite_guard_test.dart \
  test/database/package_schema_version_literal_guard_test.dart \
  test/sync/no_hardcoded_google_secret_test.dart test/sync/mime_types_test.dart \
  test/sync/desktop_lookup_foreground_guard_static_test.dart \
  test/storage/documents_whitelist_guard_test.dart test/storage/path_rebase_coverage_guard_test.dart \
  test/focus/focus_architecture_static_test.dart test/lookup/auto_read_surface_coverage_guard_test.dart \
  test/pages/lookup_overlay_dialog_gate_guard_test.dart test/shortcuts/shortcut_channel_wiring_guard_test.dart \
  test/webview/webview_render_process_gone_guard_test.dart test/widgets/horizontal_drag_scroll_guard_test.dart \
  test/widgets/reorderable_scale_safety_guard_test.dart test/media/collections/collection_asset_reclaim_test.dart \
  test/media/drag_drop/drag_drop_platform_guard_test.dart test/media/media_cover_write_guard_test.dart \
  test/media/sources/book_history_split_guard_test.dart test/media/video/real_path_directory_picker_test.dart \
  test/ios/info_plist_media_permission_guard_test.dart test/i18n/i18n_completeness_test.dart \
  test/pages/reader_hibiki_page_source_corpus_test.dart \
  test/pages/reader_history_source_corpus_test.dart \
  test/pages/video_hibiki_page_source_corpus_test.dart \
  test/sync/sync_settings_schema_source_corpus_test.dart
```

### 清单会过期——怎么重新推导

**按行为反向枚举，不按名字猜**。名字里带 `guard` / `static` / `adoption` 的既不充分也不必要：`i18n_completeness_test.dart` 不带 guard 却必须进，`resume_prune_guard_test.dart` 带 guard 却是定点。

```bash
cd hibiki
grep -rlE "listSync|\.list\(" test/ --include=*.dart | sort > /tmp/a
grep -rlE "['\"](\.\./)*(lib|test|assets|integration_test|packages|\.github|tools|docs|third_party)(/[^'\"]*)?['\"]" \
  test/ --include=*.dart | sort > /tmp/b
comm -12 /tmp/a /tmp/b   # 候选集，再逐个读代码定性
```

🔴 **两个已被实测踩到的坑**：

1. **`listSync(` 会被 `dart format` 折行**成 `listSync(\n  recursive: true,\n)`。单行正则 `listSync\(recursive: true\)` 漏掉 `source_guard_adoption_test.dart` 本身——本清单第一版就是这么漏的。要么用多行匹配，要么只 grep `listSync` 裸词再逐个看。（同一个坑也存在于被守的一侧：`test/storage/data_root_migrator_test.dart` 里 `contains('listSync(recursive: true')` 这条断言就抓不到折行写法——**PR#760 已改成折行容忍正则**；例子留在这里不是因为它还没修，而是因为「精确字面量断言被 `dart format` 折行打断」这个形态还会再出现。）
2. **grep 只能定位不能定性**。命中后必须**读代码**确认扫描根是仓库源码树而不是 `Directory.systemTemp` 临时目录——63 个候选里超过一半是「在临时目录造文件再遍历」的行为测试。

### 扫描规模哨兵（TODO-2707 已补完）

TODO-2707（PR#756）已把这条补完：**35 条现在条条有扫描规模哨兵**——27 条走共享 `expectScanScale`（下界取实测值的约 80%，只在量级塌掉时才响，平时零维护）+ 4 条自带专用哨兵（`itest_focus_navigation_prerequisite` 的 `inScope >= 25`、`webview_render_process_gone` 的三重、`lookup_overlay_dialog_gate` 的多重、`book_history_split` 的集合非空）+ 4 条合并语料守卫走 `expectPartManifestMatchesDisk`。

`if (!dir.existsSync()) continue;` 这个早退写法在其中 6 条里仍然留着（`dart_source_no_raw_nul`、`duplicate_policy_naming`、`media_kind_persistence`、`book_format_discipline`、`package_schema_version_literal`、`mime_types`），但**它已经不再等于静默空转**：早退之后哨兵会因为 `scanned` 太小而红。留着早退、由哨兵兜底，比在每个扫描根上各写一遍 `fail` 更少重复。

🔴 **这件事真正的收获不是「修好了什么」，而是「以前无法证明什么」。**变异实测的做法是把 3 条守卫的扫描后缀改成永不匹配：**原判据在零文件扫描下全部保持绿色，只有哨兵响了**。也就是说此前那些「全绿」是真的绿，但**此前没有任何办法把它与「瞎着绿」区分开**。这也正是每次判绿都要自查 `N tests ran` 的 N 有没有偏小的理由——在哨兵补全之前，N 是唯一的空转信号。

### 禁止型断言的盲区：全绿 ≠ 在工作

🔴 PR#760 挖出来的结构性问题，和上面的空转是同一族：

> **禁止型断言（「不得出现 X」）在健康仓库里本来就永远零命中。于是判据本身坏掉时，扫盘那条路根本检验不到它。**

「精确字面量被 `dart format` 折行打断」这类判据缺陷能坏很久没人发现，根子就在这儿：守卫每天都绿，而绿正是它坏掉时的预期表现。**扫描规模哨兵管的是「扫到东西了没」，管不到「判得准不准」。**

应对：给禁止型守卫补**判据自校验**——手写一小段必然违规的语料，喂给判据，要求它必须报出来。自校验语料必须与磁盘扫描**互不依赖、独立枚举**，否则同一个缺陷让两边一起失明。PR#760 做了新旧判据 A/B 实测：一条真假红（旧红新绿）、两条真假绿（旧绿新红）。

配套关系：**「合并后必跑清单」管的是「该跑的守卫有没有跑到」，判据自校验管的是「跑到的守卫判得准不准」**——两层都塌过，缺一层就是另一种形式的假绿。

**新写目录枚举型守卫时，扫描规模下界断言是必需项，不是加分项**；语料型守卫的「磁盘再枚举一遍」必须与生产侧用**不同**实现，否则枚举器自身的缺陷会让守卫与被守方在同一处同时失明。

## 另一半：按触发条件加跑——**不点名，按树推导**

上面那 35 条扫的是 Dart 源码树。另一半守卫读的是 **native / 资产 / 配置树**：`hibiki/windows`、`hibiki/android`、`hibiki/{ios,macos,linux}`、`packages/*/windows`、`native/`、`tools/browser-extension`、`.github/workflows`、`third_party/`。整批清单抓不到它们，因为它们只在碰对应资产时才可能红。

### 这里曾经挂着一份手写的 9 个测试名，它烂了——而且是必然烂的

结构性成因一句话：

> **清单的分类维度是「资产种类」（workflow / 扩展 / 二进制 / native），而真实触发面的维度是「哪棵源码树」。**

两者不对齐，于是五棵最大的 native 树里只有一棵被点了一个名：

| 树 | 引用它的守卫数（实测） | 旧手写清单覆盖 |
|---|---|---|
| `hibiki/windows` | 75 | **只点了 `gal_ipc_contract_single_source` 1 个** |
| `hibiki/android` | 38 | **0，无任何触发规则** |
| `tools/browser-extension` | 49 | 2 |
| `packages/flutter_inappwebview_windows` | 20 | **0** |
| `.github/workflows` | 20 | 3 |
| `native/hoshidicts` / `native/galgame_hook` | 12 / 9 | 1（半覆盖） |
| `hibiki/macos` / `hibiki/ios` / `hibiki/linux` | 9 / 7 / 2 | **0** |
| `packages/gamepads_windows` / `third_party/desktop_drop` | 4 / 3 | **0** |

改一行 `hibiki/windows/runner/flutter_window.cpp` 会牵动 **72 条**守卫，旧清单一条都没提。这是「合入的 PR 把红带进 develop」已发生 3 次的共同根因之一（TODO-2720）。

### 现在：从仓库现状推导

```bash
cd hibiki
dart run tool/tests_for_changes.dart --base=origin/develop            # 该加跑哪些
dart run tool/tests_for_changes.dart --base=origin/develop --explain  # 顺带说明被哪条路径命中
dart run tool/tests_for_changes.dart hibiki/windows/runner/x.cpp      # 也可以直接给文件

# 直接串给测试入口：
dart run tool/flutter_test_failures.dart --no-pub \
  --output-dir=../.codex-test/flutter-test-trigger \
  $(dart run tool/tests_for_changes.dart --base=origin/develop)
```

判据一句话：

> **改动文件 F 触发测试 T ⟺ T 的源码里引用了某个仓库路径 P，且 F 落在 P 底下。**

**为什么这条不会像名字表那样烂**：被提取的字符串和被守卫断言存在的路径，是同一个文件里的**同一个字面量**。树改名时守卫必须改那个字面量（不然它自己就红），索引自动跟着走。名字表没有这种耦合，只能靠人记得去改——这次就是没人记得。

规则本身由 `test/tools/tests_for_changes_guard_test.dart` 守着，三层判据：① 被替掉的那 9 条手写规则必须仍能被推导出来（**超集，不是近似**）；② 原先零覆盖的树现在每棵都推得出测试；③ 逐树规模下界，且下界由一份**与提取器毫无共享代码**的朴素 `contains` 扫描独立算出（共用同一个枚举函数会让守卫与被守方在同一处同时失明，`tool/bug.dart` 的 `buildRenumberPlan` / `findResidualRefs` 踩过）。

**有意的偏置：过度触发，不漏触发。** 漏一条 ⇒ 红带进 develop；多跑一条 ⇒ 多几秒。所以不剥注释（注释里点名一棵树本身就是证据）、路径解析退到最近存在的祖先（构建产物 / `.../` 省略写法 / 被删的叶子都还算数）。

**不需要分层**。实测 `hibiki/windows/runner/flutter_window.cpp` 推出的 **72 条**跑完 **53 秒 / 594 tests**（`origin/develop@f0a00f410`）——比争论「该不该跑」便宜得多，整批跑。

**唯一的例外：扫描面运行时才算得出来的守卫。** 典型是 `powershell_51_compat_guard_test.dart`——它从 `.github/workflows/*.yml` 里解析 `powershell -File <脚本>`，被守的 `.ps1` 清单是 yml 内容决定的，源码里没有那些路径的字面量。这类守卫在**自己文件里**写一行声明：

```dart
// tests-for-changes: **/*.ps1
```

规则住在拥有它的那个文件里，改守卫的人一眼看得见；守卫断言每条声明至少匹配到一个真实文件，所以声明烂掉是**响的**不是哑的。

## 输出可信 ≠ 结论可信

`git push` 打印 `* [new branch] HEAD -> refs/heads/xxx`，看起来成功，**push 本身也没撒谎**——它确实把那个 ref 推上去了。撒谎的是**我们对「那个 ref 是什么」的默认假设**：detached HEAD 下 `HEAD` 早已不是工作所在的位置，推上去的是个陈旧 commit。

这类错误**读输出永远发现不了**，因为输出对它自己描述的那件事完全准确。唯一的定性办法是**问远端要真实 SHA**，再与本地比对：

```bash
git ls-remote origin refs/heads/<branch>
gh api repos/<owner>/<repo>/git/ref/heads/<branch> --jq .object.sha
git rev-parse <你以为推上去的那个东西>
```

这与既有的「push `develop` 假失败只信 `gh api` sha」是**同一条纪律的两个方向**：

| 方向 | 表象 | 真相 | 定性 |
|---|---|---|---|
| 假失败 | push 报 non-FF 错误 | 并发竞态，commit 其实已经进去了 | `gh api` 查远端 sha |
| **假成功** | push 报 `[new branch]` / `Everything up-to-date` | 推的 ref 不是工作所在位置（detached HEAD / 推错分支） | `git ls-remote` 查远端 sha |
| **单端点滞后** | 刚 push 成功，`gh api` 却仍返回旧 sha | 两个端点同一时刻不同值——`gh api` 有传播延迟 | `git ls-remote origin refs/heads/<branch>` 当场就是新值；判 `develop` head 一律以它为准 |

**通则：凡「远端 / 外部系统的状态」，一律以向它查询到的状态为准，不以本地命令的输出叙述为准；而「向它查询」不等于「问某一个端点」——同一份远端状态在 `gh api` 和 `git ls-remote` 上可以同时是两个值。** 本地输出只能证明「这条命令做了它说的事」，证明不了「这件事就是我要的事」。同族实例还有：`flutter test | tail` 的退出码是 `tail` 的（恒 0）、构建失败时零测试执行会被伪装成通过（BUG-1157）。

### 判「测试跑全了没」是结构问题，不是算术问题

🔴 **别去数 `test(`。** 实测：整合线想核 `test/sync` 的 `N=1937` 对不对，用 grep 数出 9 个 `test(`，算 `1933 + 9 = 1942 ≠ 1937`，差 5，于是怀疑漏跑。**这条路本身就是错的**——源码里的 `test(` 数**从来不等于**运行时用例数：`testWidgets`、参数化循环、`group` 内动态生成的用例，全都对不上。

决定性的是 **suite 层的结构对账**：`test/sync` 磁盘 **237 个 suite、装载 237、0 缺失、0 空 suite** ⇒ 运行是完整的，N 的差额来自用例本身而不是漏跑。

**`N tests ran` 的 N 仍是判据的一部分**（N=0 时 PASSED 和 FAILED 都不成立），但它是**次级信号**：N 能证伪「跑了」，证明不了「跑全了」。清单 / 推导规则要回答的问题是「**该跑的 suite 有没有都跑到**」，那是结构问题，不是算术问题。

这和既有的「grep 只能定位不能定性」是同一个坑的两个面：那条讲**查代码**，这条讲**判测试覆盖**。

## 合并流水线（integration owner）

落地范式不变：干净 worktree ff → merge → 解 i18n → analyze → bump。提速点：

- 全量 test 在后台跑的**同时**，预解下一个 PR 的冲突和 i18n（流水线化，不是并行 merge）。
- 多 PR 逐个 **rebase 叠加**，不做旧基底 merge——旧基底 merge 会静默删掉先落地 PR 的文件（并发合并竞态）。
- 合并后核对以独立 `git diff --stat` 为准，不信子代理叙述。

## 空等浪费禁止清单

- ❌ 前台跑 bootstrap / 全量 test / gradle 并盯着输出——一律后台，期间推进其它步骤。
- ❌ 同一疑点串行试三轮 grep——派一个搜索子代理一次扫完拿结论。
- ❌ 测试跑完才开始写 bug 文档 / PR 描述。
- ❌ 只为读几个文件就新建 worktree + full bootstrap——**只读/分析不需要 worktree**，直接在原工作区读。
- ❌ 同一子任务派两个子代理各做一遍「互相印证」——要印证就派**不同角度**（如实现 vs 反驳审查），不是重复劳动。
