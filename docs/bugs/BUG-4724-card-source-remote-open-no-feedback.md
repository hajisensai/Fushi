## BUG-4724 · 点卡片来源跳互联 host 上的视频时等拉清单期间毫无反馈，像点坏了
- **报告**：2026-11-16（应用内反馈 7gkdbfCXQ0，维护者待办：复习卡底部视频来源链接，点了没反应，等很久才跳到互联）
- **真实性**：✅ 真 bug。本机库里没有该视频（只在互联 host 上）时，`fushi/lib/src/anki/card_source_router.dart` 的 `_openCardSource` 在 push 远端播放页之前 `await resolveRemoteCardSourceVideo`，后者经 `remoteLibraryCacheProvider` 调 `InterconnectSyncBackend.listRemoteVideos`（`_ensureResolved` 选路 + 拉整份视频清单，探测超时每址 2 s、请求超时 15 s）。这段网络等待期间没有任何 UI 状态：五个入口（复习页 / 原生卡面 / 浏览预览 / 浏览检视器 / `fushi://source` URL）都只是 `srsRunLogged(openCardSource)` 发出去就不管，界面毫无变化直到页面推上来。
- **[x] ① 已修复** — 新增 `fushi/lib/src/anki/card_source_open_feedback.dart` 的 `awaitWithCardSourceOpeningFeedback`：等待期间在根导航上立刻挂不定态进度对话框（遮罩挡重复点击），带取消键（系统返回键同）；完成或取消后关掉并等出栈再推目标页。`resolveRemoteCardSourceVideo` 改为返回 `CardSourceAwaited`（区分「没有来源」与「用户取消」），缓存不新鲜（要真去 host 拉）时才挂反馈，新鲜缓存命中直接用不闪窗；`_openCardSource` 取消即静默放弃跳转。
- **[x] ② 已加自动化测试** — `fushi/test/anki/card_source_open_feedback_test.dart`（widget：同帧出对话框、完成后关闭并返回、取消 / 系统返回键放弃且丢弃迟到结果、失败原样抛出；接线扫描）。
- **备注**：候选地址选路已是组内并发（`rankInterconnectCandidates`），本次未改网络层；耗时本身来自网络，没有计时证据不动。未在真机复测原始失败路径。
