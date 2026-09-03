## BUG-1942 · 浏览器扩展查词不自动播放单词音频
- **报告**：2026-08-29（用户：查词的时候单词音频没有自动播放）
- **真实性**：✅ 真 bug（能力缺失型）。全局偏好 `autoReadOnLookup`（查词后自动朗读）此前只接了
  三个表面：app 内弹窗（`dictionary_popup_webview.dart`）、app 外瞬态查词浮窗与剪贴板面板
  （两者共用 `fushi/lib/src/lookup/overlay_auto_read.dart`，那份收口本身就是 BUG-1210 为
  「同一个开关在一个表面生效、另一个完全无效」修的）。浏览器扩展是最后一个漏掉的表面：
  `tools/browser-extension/vendor/popup.js` 只在点 ♪ 时播，扩展侧既没有这个偏好、也没有任何
  查词后自动播放的调用——查词服务响应里根本不下发这个字段。
- **[x] ① 已修复** — 两段：
  - 下发：`fushi/lib/src/sync/fushi_remote_api_handlers.dart` 的查词响应 envelope 新增
    `autoReadOnLookup`，供给器沿 `app_model → yomitan_api_server_manager → yomitan_api_server
    → handler` 注入，真相源就是 `ReaderFushiSource.instance.autoReadOnLookup`（不在扩展侧另存
    一份，免得两处语义漂开）。
  - 消费：新增 `tools/browser-extension/auto-read.js`，**页面弹窗与侧边栏弹窗共用这一份**
    （各写一份正是 BUG-1210 那个病）。解析走点 ♪ 的同一条 `resolveWordAudio` 桥，播放走
    popup.js 自己的 `playWordAudio`，音量/interrupt/失败处理与手动点 ♪ 完全一致；换词与关窗
    作废在途解析，慢响应回来不会盖掉用户已经在看的新词。
- **[x] ② 已加自动化测试** — `tools/browser-extension/auto-read.test.js`（模块本身 7 条）+
  `side-panel-lookup-on-page.test.js` 两侧接线 3 条 + `fushi/test/sync/remote_lookup_auto_read_test.dart`
  （下发字段 4 条 + 注入链/双镜像守卫 2 条）。变异实测 6/6 被抓：忽略开关、无音频源空跑、
  不作废在途解析、读音缺失不回落、两个表面各自不接线。
- **备注**：扩展不另立开关，开关仍是 app 设置里的「查词后自动朗读」。浏览器的自动播放策略
  可能拒绝无手势播放（`NotAllowedError`），popup.js 的 playWordAudio 已按失败处理，不会抛。
