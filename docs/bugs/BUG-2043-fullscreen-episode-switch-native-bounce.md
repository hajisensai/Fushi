## BUG-2043 · 全屏换集先退再进原生全屏抖动、字幕列表丢失
- **报告**：2026-09-02（用户：「全屏打开字幕列表去下一集的时候可能会卡住，字幕列表也有可能会往右靠（显示效果）」，附截图：全屏尺寸的窗口里整屏是浅色「正在准备…」加载页，顶部一条 ~32 逻辑像素的窄带里挤着上一集的控制条图标与「字幕列表」表头）
- **真实性**：✅ 真 bug（Windows 离屏 runner 复现，`fushi/.codex-test/windows-itest/win-itest-20260902-154806-194eace6/command.log` 时间线：进全屏 → 开字幕列表 → 倒计时归零换集 → **原生全屏 4.9s 掉、8.4s 才回来**，新页字幕列表 `panel=false`）。根因 `fushi/lib/src/pages/implementations/video_fushi/episode.part.dart:112`（`_switchEpisode` 本地分支）
- **[x] ① 已修复** — 本分支 `worktree-fix-fullscreen-sublist-next-episode`（提交见 git log）
- **[x] ② 已加自动化测试** — 源码守卫 `fushi/test/pages/video_fullscreen_switch_flatten_guard_test.dart`（重写：换集不得调 `_exitVideoFullscreen`、push + removeRoute 顺序、透传字幕列表可见性、认领/释放原生全屏三处齐备、分支条件必须逐字等于纯函数查询、所有权翻假点必须在全屏路由建出之后）+ 纯函数真值表 `fushi/test/media/video/video_episode_start_policy_test.dart`（`resolveEpisodeSwitchPlan` 8 组输入全钉死——源码字面扫描证明不了语句可达，把决策抽成纯函数后「条件恒真致接管块变死代码」「`wasFullscreen` 恒假」两条变异才真红）；端到端 `fushi/integration_test/video_fullscreen_sublist_next_episode_test.dart`（Windows 离屏 runner `-Visible`：换集全程原生全屏采样零掉线、新页就绪、字幕列表仍在）
- **备注**：视频播放/全屏类。BUG-839 的第一版修法引入。Windows 真机验证见下。

### 根因

BUG-839 为了让 `pushReplacement` 替换的是剧集页而不是栈顶的全屏路由，在 `_switchEpisode` 里先 `_exitVideoFullscreen` **pop** 全屏路由再 `pushReplacement`、新页就绪后再 `_pushNeutralizedVideoFullscreen` 重进。pop 会经 media_kit `FullscreenInheritedWidget` 内置的 `PopScope.onPopInvokedWithResult` 触发**未 await 的原生退全屏**（`_exitVideoNativeFullscreen` → Windows `WindowCaptionChannel.setFullscreen(false)`：runner 还原窗口矩形 / 重新最大化 + `FushiWindowsTitleBar` 释放 owner → app 标题栏行显示）。于是一次换集 = 原生退全屏（窗口 resize + 标题栏 32px 行插入）→ 加载页在窗口态显示 → 新页就绪再原生进全屏（再 resize）。三件事叠在一起：

1. **卡住**：Windows 嵌入层的窗口 resize 是同步阻塞平台线程等栅格线程出帧，而这段时间 media_kit 正在拆旧 `VideoOutput` 纹理（旧页 dispose）+ 建新纹理（新页 `_init`）+ 字幕列表在窗口侧重挂——多次尺寸变化与纹理拆建交错，偶发挂死（用户报「可能会卡住」；离屏复现三次未挂，但抖动路径每次都走）。
2. **往右靠 / 顶部窄带**：截图正是 resize 中间态——标题栏行已插入（owner 已释放）而窗口/表面仍是全屏尺寸，新页加载体被压到 32px 之下，上一帧内容残留在顶部窄带。
3. **字幕列表丢失**：新页构造时没带 `initialSubtitleListVisible`，列表随旧页一起被替换掉。

### 修复

`_switchEpisode` 本地分支改为**接管**而非**退出再进**：
- 全屏时（`_videoFullscreenRoute.isActive` 或本页仍持有接管来的原生全屏）：`navigator.push` 把新页压在全屏路由之上（`initialFullscreen: true`、`initialSubtitleListVisible: _subtitleListVisible.value`），随即 `rootNavigator.removeRoute(旧全屏路由)` + `navigator.removeRoute(本页)`。`removeRoute` 不经 pop → 不触发 media_kit PopScope 的原生退全屏；栈从 `[home, 旧集页, 旧全屏]` 直接变 `[home, 新集页]`，恒平（BUG-839 不回归）。窗口模式仍 `pushReplacement`。
- 新页 `initState` 经 `_claimHandedOverNativeFullscreen` 认领原生全屏：记下「本页负责收尾」+ Windows 立刻持有标题栏 owner（旧页 dispose 释放它自己的 owner 时标题栏不会闪出）。就绪后 `_scheduleInitialFullscreenIfNeeded` 压自己的全屏路由并把所有权移交路由（退出改由路由 pop 收口；`_enterVideoNativeFullscreen` 在已全屏时各平台幂等）。就绪失败 / 超时 / 加载中被退出（dispose）→ `_releaseHandedOverNativeFullscreen` 亲自退原生全屏，不留「原生全屏但栈上无全屏路由」的悬空态。再次换集时所有权继续传给下一集页。

审查跟进（同 PR 补齐）：

- **决策收敛进纯函数**：`_switchEpisode` 不再手写 `wasFullscreen` 布尔表达式与分支条件，改为消费 `resolveEpisodeSwitchPlan`（`fushi/lib/src/media/video/video_episode_start_policy.dart`，与 `shouldAutoPlayNextOnCompletion` 同一处纯决策层）。行为级复现需要 media_kit + 真 navigator 栈 + 原生全屏，headless 跑不了；纯源码守卫只看字面、不检查语句可达性——两条实测能穿过旧守卫的变异（分支条件恒真让接管块变死代码 / `wasFullscreen` 恒假）现在由真值表直接判红。
- **所有权翻假点后移**：原先在 `_scheduleInitialFullscreenIfNeeded` 调用点先把 `_ownsHandedOverNativeFullscreen` 翻假再调 `_pushNeutralizedVideoFullscreen`，而后者开头有 `_videoFullscreenTransitioning` 一道提前 return——提前 return 时所有权已放手、路由却没压上，窗口停在「原生全屏但栈上无全屏路由」的悬空态，且 dispose 的 `_releaseHandedOverNativeFullscreen` 已成 no-op、退不回去（本仓已知的「bool 镜像只有成功路径复位」形态）。现在翻假点搬到 `_pushNeutralizedVideoFullscreen` 内部、紧挨 `_videoFullscreenRoute = fullscreenRoute` 之前（两道提前 return 之后、首个 `await` 之前，同步不可分割）；调用点只在「栈上已有全屏路由」这一分支放手。

### 验证

- `flutter analyze`（lib + test）clean；`flutter test test/pages/video_fullscreen_switch_flatten_guard_test.dart`
- Windows 离屏 runner（`fushi/tool/run_windows_itest.ps1 -Visible integration_test/video_fullscreen_sublist_next_episode_test.dart`）：修前（run `win-itest-20260902-154806-194eace6`）原生全屏掉线 ~3.5s + 换集后 `panel=false`；修后（run `win-itest-20260902-155823-13909b83`）40s 采样原生全屏零掉线、第 2 集 3.4s 接管 / 6.7s 就绪、`panel=true`、零 FlutterError，`All tests passed`。
- 前置：离屏 runner 焦点闸门修复（原 c571ab161a，`worktree-onboarding-rewrite`）已作为独立提交带进本分支（不含其 onboarding itest），否则 runner 下 primaryFocus 卡 View Scope、F/L 键到不了视频页。
