## BUG-1920 · 设置里的功能模块开关名字与底栏/侧栏对不上
- **报告**：2026-08-28（用户：截图标注「设置里叫小说 / Galgame，侧栏叫书架 / 游戏」，并要求把这一区从系统挪进外观）
- **真实性**：✅ 真 bug。设置页抄了**第二份**标签，与底栏真值各改各的：
  - 底栏/侧栏（唯一真值）`fushi/lib/src/pages/implementations/home_page.dart:191` `homeNavItemFor()` —— books=`t.books`「书架」/Books、games=`t.nav_game`「游戏」/Game、browserExtension=`t.nav_browser_extension`「浏览器扩展」/**Extension**。
  - 设置页手写副本 `fushi/lib/src/settings/settings_schema_system.dart:157/169/181/193/231`（修复前）—— `module_books_label`「小说」/**Novels**、`module_games_label`「Galgame」、`module_extension_label`「浏览器扩展」/**Browser extension**。
  - 图标同样漂移：video 设置用 `smart_display_outlined`、底栏用 `movie_outlined`；games 设置用 `videogame_asset_outlined`、底栏用 `sports_esports_outlined`。
  - 中文只看得出 books / games 两处，英文侧 books / games / extension 三处全错——是同一个根因的不同投影。
- **[x] ① 已修复** — 消除第二份真值，而不是把副本改成一样的字：新增 `_moduleSwitch()`（`fushi/lib/src/settings/settings_schema_appearance.dart`），标题与图标一律取 `homeNavItemFor(tab)`，底栏改名时设置自动跟随。同一改动按用户要求把整个「功能模块」区从 **系统** 搬到 **外观**（与同分区的「反转导航栏」同域，都管底栏形态），落在「排版」之后、「应用外壳」之前；item id 保留 `system.module_*` 历史前缀不动（id 与展示分类本就解耦，先例见 `appearance.startup_default_dictionary_tab`），故用户偏好与持久化零影响。连带：删掉四个再无引用的 key `module_{books,manga,video,games}_label`（`module_extension_label` 仍被新手引导用，保留）；`module_downloads_hidden_hint` 的 17 份译文里「设置 → 系统 → 功能模块」按各语言 UI 实际译名改成「→ 外观 →」；`settings_schema_coverage_test.dart` 的 `kCoveredElsewhere` 七个键 `system/Novels…` → `appearance/Books…`（键是 `$destId/${row.title}`，两半都变了）。
- **[x] ② 已加自动化测试** — `fushi/test/settings/settings_module_labels_match_nav_test.dart`：① 逐项断言模块开关的 `title`/`icon` **值等于** `homeNavItemFor(tab)` 的 label/icon（不是断言源码字面量，谁再塞一份手写标签就红），并锁住 id 构成与顺序；② 断言「功能模块」已不在系统 destination、系统里无 `system.module_*` 残留。变异实测：把标题改回 `t.module_extension_label` → 红；把整区搬回系统 → 红。
- **备注**：新手引导的功能选择页仍用「小说库 / 漫画库 / 视频库 / Galgame 库」（`onboarding_feature_*`，措辞是「XX 库」而非 tab 名），本轮未动——它不是用户报的那处，改动会牵动 17 语言四个 key 的语义。若要彻底一词一物，那是下一条。
