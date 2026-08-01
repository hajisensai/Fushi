## BUG-1412 · 游戏活动身份回退过宽：同名条目取第一个 / 脏 key 误绑封面
- **报告**：2026-08-02（BUG-1284 修复后的复核发现；移植自抢救分支 `codex/fix-pr578-identity-gates`）
- **真实性**：✅ 真 bug。`hibiki/lib/src/mining/galgame_library.dart:341` 的
  `findGalgameForActivity` 在 BUG-1284 引入三层兼容后缺两道闸：
  1. **脏 key 无闸** —— `mediaKey` 非空但既不等于任何 `galgames.id`、也不是 exe 路径时
     （游戏被删后残留的稳定 id、或历史脏值），代码继续下坠到标题快照层，把活动绑到
     **另一个**同名游戏的封面上；
  2. **标题层取首项** —— 标题匹配循环命中即 `return game`，库里存在同名条目时结果由
     `games` 的列表顺序决定，等于随机挑一只游戏顶包。
  两道都会让首页 Activity / 游戏首页时间线显示**错误游戏的封面**，比原本的占位图标更糟。
- **[x] ① 根因修复** — 在 `galgame_library.dart` 补两道闸：新增
  `bool _looksLikeLegacyExePath(String)`，只有带路径分隔符且以 `.exe` 结尾的 key 才具备
  旧路径身份，其余非空 key 未命中 id 即安全返回 `null`；标题层抽出
  `GalgameEntry? _findUniqueGalgameByActivityTitle(List<GalgameEntry>, String)`，
  候选必须**唯一**，零个或多个一律返回 `null`，不再依赖库顺序取首项。
  稳定 id 精确命中与旧 exePath 精确命中的既有行为不变（BUG-1284 不回归）。
- **[x] ② 自动化测试** —
  `hibiki/test/mining/galgame_launch_args_test.dart` 新增 4 个纯函数用例：重复标题下
  stable id / 旧 exePath 仍精确命中、路径迁移失效只接受唯一标题、无 key 重复标题返回
  null、deleted id 与脏非路径 key 不得回落同名游戏；
  `hibiki/test/pages/home_dashboard_page_test.dart` 新增 widget 用例，播三条历史活动
  （无 key 重复标题 / deleted stable id / 脏 key）并断言活动区**没有**任何
  `ResizeImage(FileImage)` 封面，即真回退成类型图标。
- **备注**：移植自抢救分支 `codex/fix-pr578-identity-gates`（`ae4239919`），该分支基底旧，
  按 hunk 在当前 `origin/develop` 上重做而非 cherry-pick。分支前置提交 `9d6243bd0`
  （BUG-1284）已在 develop，本条只补其上的两道闸。
