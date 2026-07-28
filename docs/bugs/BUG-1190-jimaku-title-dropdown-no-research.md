## BUG-1190 · 换番剧名后字幕来源不刷新
- **报告**：2026-07-28（用户：「我改了上面的番剧名，底下的字幕来源不会变」）
- **真实性**：✅ 真 bug（交互层）。根因 `hibiki/lib/src/pages/implementations/anime_download_dialog.dart:1580`（`_buildJimakuManualSearch` 里标题候选下拉的 `onSelected`）。
  - 下拉选中只做 `_jimakuQueryCtrl.text = value`，不触发任何搜索；而 `TextEditingController.text = ` 赋值本就不会触发 `onChanged`，也没有任何监听。
  - 重搜只有两个入口：输入框回车（`onSubmitted`）或点放大镜。用户从下拉里换了番剧名，看到的是「名字换了、底下的字幕来源纹丝不动」，自然判定成功能坏了。
  - 手打改名同理：改完不按回车就毫无反馈，界面上没有任何「还没生效」的提示。
- **[x] ① 已修复** — 下拉 `onSelected` 赋值后立即 `_searchJimakuManual()`；另加「未应用」提示：记录最近一次真正发起搜索时的输入条件（`_appliedJimakuSearch` = 查询词 + 集号），当前输入框与之不一致时搜索按钮转 `primary` 强调色（`ListenableBuilder` 监听两个 controller，不额外 setState）。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/anime_download_dialog_discovery_ux_test.dart`「确认阶段：下拉切标题立即重搜 Jimaku 并刷新字幕来源」：MockClient 计数 `/entries/search` 调用，断言进入确认阶段时为 0、选中下拉标题后为 1，且字幕来源 chip 换成新条目、字幕列表出现该集文件、「无字幕」消失。
- **备注**：与 [BUG-1189](BUG-1189-season-pack-jimaku-subs-empty.md) 同一次用户报告，同 PR 落地。同 PR 还把 Jimaku 设置收敛到设置页（视频 → 字幕）：API key 此前只能在三个对话框里就地填、设置页无入口，且下载对话框的输入框只在 key 为空时显示（`_showJimakuKeyField` 在 `initState` 定死），key 填错了无处可改。
