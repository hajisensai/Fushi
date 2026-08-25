## BUG-1863 · 从后台切回视频静止区域变成灰色
- **报告**：2026-08-25（用户：「从后台切回来的时候有时候静止的地方会变成灰色」+ 手机端截图：两个角色（运动区域）画得完整，天空 / 房屋 / 地面这些静止背景整片 `#808080`，角色边缘还挂着几块没被覆盖掉的彩色残片）
- **真实性**：✅ 真 bug，机制可从截图直接读出；**触发条件未在真机上复现**（报修时本机 adb 里那台手机 `offline`，见备注）。

  截图里那个灰是 `#808080`，正是 libavcodec 在**参考帧缺失**时给帧填的中性灰
  （`1 << (bit_depth - 1)`，error concealment 的 gray init）；运动区域完整则说明 P 帧的残差
  被正常解出来并叠上去了。两件事合起来只有一个含义：**解码器在播放中途被重建过，却没有
  回到关键帧就继续喂包**，DPB 里没有可参考的前帧，于是「这一帧没被残差碰到的地方」全是
  concealment 的灰。画面要等到下一个 IDR 才自愈——GOP 长的片源就是好几秒。

  中途重建的来源是 Android 平台事实：MediaCodec 是有限的系统资源，前台应用优先，app 在
  不可见期间持有的硬解实例会被回收（尤其期间开了相机 / 别的播放器）。Fushi 移动端走
  `hwdec=auto-copy` → `mediacodec-copy`（`video_mpv_config.dart` 的
  `resolvePlatformHwdec`），且真后台期间**不暂停解码**（`didChangeAppLifecycleState` 的
  `paused` 分支只落库 + 停观看计时），所以后台期间一直在用那个随时会被收走的解码器。

  media_kit 并非没管这件事：`third_party/media_kit_video/lib/src/video_controller/
  android_video_controller/real.dart` 的 `widListener` 在 `--wid` 变更后重设 `vo`，**尾部就是
  `await player.seek(currentPosition)`** —— 与本次修复同一手法。但它的触发条件是
  **surface 真的被重建**（Flutter `SurfaceProducer` 的 `onSurfaceCleanup` /
  `onSurfaceAvailable` → `wid` 这个 `ValueNotifier` 值变化）。而「surface 有没有被重建」与
  「解码器有没有被系统回收」是两件独立的事：短暂切走、或系统没有释放 surface 时 `wid` 不变，
  `ValueNotifier` 压根不通知，那条刷新路径整个不触发。**这就是「有时候才灰」的缺口。**

- **[x] ① 已修复（`implemented_unverified`）** — 视频页记下「真的进过后台」
  （`_enteredRealBackground`，`paused` / `hidden` 置真，`inactive` 不置——通知栏下拉一瞥期间
  app 仍持有解码器），回前台时经纯判据
  `VideoPlayerController.shouldRefreshDecodeOnResume`（移动端 + 有解码出画的视频轨 + 时长
  已知可 seek）决定是否调 `refreshDecodeAfterResume()`：seek 到**当前位置**本身。mpv 的 seek
  会 flush 解码器并从目标之前的关键帧重新解码，DPB 被重新填满，concealment 的灰块被真实
  像素取代。走 `Player.seek` 而不是 `seekMs`——播放位置根本没变，不该清主动跳转快照、不该
  作废「只播这一句就停」、不该触发字幕权威重算。标记在任何早退之前无条件清掉，不会攒到
  下一次 resume 变成「某次切窗后莫名 seek 一下」。直播 / 时长未知流不刷新（那一 seek 可能
  把播放头甩走，宁可留着灰屏也不打断直播）；桌面不做（窗口失焦不会让系统回收解码器）。
  提交：见本分支 `fix(video): ...` commit。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_resume_decode_refresh_guard_test.dart`：
  `shouldRefreshDecodeOnResume` 五种输入组合的行为单测 + 调用点静态守卫（标记只在
  paused/hidden 置、resumed 分支真调刷新、标记在第一个 return 之前就清、刷新不走 `seekMs`
  且确实 seek 到当前位置、判据不在页面里被重写一遍）。已做变异实测：把置标记挪进
  `inactive` 分支 → 「只有 paused / hidden 置标记」当场红；把清除挪到早退之后 →
  「标记无条件清除」当场红；还原后源文件 sha256 回到基线。
- **备注**：**真机未复测**。报修当时本机 adb 里唯一那台设备（CPH2747，无线调试）是
  `offline`，`adb reconnect` 拉不回来，没法在真机上跑「播放 → 切后台 → 抢占解码器 → 切回」
  这条原始失败路径，也就无法给出「修复后不再灰」的像素证据。系统回收 MediaCodec 这件事
  在单测里造不出来，media_kit 也跑不了 headless，所以自动化只能锁到判据与调用点。
  按上面的机制分析，本修复覆盖的是「参考帧缺失」这一**类**成因（解码器中途重建、
  surface 重建时 seek 被吞、硬解中途回落软解都在内），不是只针对某一条触发路径；但**在
  真机上复现并复测之前，只能标 `implemented_unverified`，不能宣称已修好**。
