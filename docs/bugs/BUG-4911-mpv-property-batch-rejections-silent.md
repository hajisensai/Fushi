## BUG-4911 · mpv 属性批量下发有五份同形实现，mpv 拒绝写入不留任何痕迹
- **报告**：2026-11-20（路线图 #3722 c46 video-36m，代码复核；非用户反馈）
- **真实性**：✅ 真问题（读代码确证 + 真 libmpv 验证结果码）。根因（基准 `7745effa2e`）：
  - `ci/patches/hosted/media_kit-1.2.6/lib/src/player/native/player/real.dart:1248-1305`（修前）：补丁的异步 `setProperty` 拿到 `MPV_EVENT_SET_PROPERTY_REPLY` 的错误码（`:1661-1672` 把 `event.ref.error` 交给 completer）后直接丢掉，注释写明「Errors stay silent」。
  - 五份批量循环各自 `try { await native.setProperty(k, v) } catch (_) {}`：`fushi/lib/src/media/video/video_mpv_config.dart:804`（`applyMpvConfigToPlayer`）、`:899`（`applyNetworkCachePropertiesToPlayer`）、`:1031`（`applySubtitleMpvPropertiesToPlayer`）、`:1120`（`_setMpvProperties`，header 注入 / 清除）、`fushi/lib/src/media/video/video_player_controller.dart:6000`（`_setMpvProperties`，Lua 基线 / OSD）。属性名拼错、值非法、用户 rawConf 里写了运行时不可设的选项，一律无声。
- **[x] ① 已修复** — 补丁加 `NativePlayer.setPropertyWithResult`（返回 libmpv 结果码，`setProperty` 委托给它、行为不变）；五份循环合成 `setMpvPropertiesInOrder`（`video_mpv_config.dart`）：逐条 await 保序（libmpv 异步写不保序，`volume-max` 先于 `volume`、rawConf 最后覆盖都靠它），被拒的那条写一行 `[mpv-prop] <属性名> rejected: <错误名> (<码>)` 再继续（不记值，header / proxy 带凭据），播放器已销毁（`uninitialized` 或写入抛出）整批放弃，非 libmpv 后端整批 no-op。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_mpv_property_batch_test.dart`：保序且同一时刻只有一条在途、被拒写入留痕且不含值、销毁即停、非 libmpv 后端静默、五个入口都走同一实现。`fushi/test/third_party/media_kit_async_property_test.dart` 新增真 libmpv 用例：合法写入返回 0，不存在的属性 / 非法值返回负码。
- **备注**：
  - 音乐侧还有两份同形循环（`fushi/lib/src/media/music/mpv_music_output_backend.dart:452`、`fushi/lib/src/pages/implementations/music/music_mv_page.dart:597`），不在本组范围，未改。
