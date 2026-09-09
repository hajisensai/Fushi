## BUG-2334 · mobile-shader-tier-desktop-chain

- **报告**：2026-09-09（用户）
  > "If I set the video quality to anything higher than 'Low,' both the playback and the entire app start lagging severely."（追问后确认：**手机上**）

- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/video_shader_tier.dart:57`（`kVideoShaderTiers`，改前是**唯一一张桌面档位表**）。

  「视频画质」= 画质增强档位（无/低/中/高/极高），它不是连续强度旋钮，而是把档位投影到两套正交状态：mpv 内置缩放开关 + GLSL 启用集。**低**=内置缩放 on + 零 GLSL；**中/高/极高**=额外叠 Anime4K 链。用户报的分界线（「高于低就卡」）与「有没有 GLSL」这条线一字不差。

  改前这张表没有移动端投影：中/高/极高 在手机上拿到的是为「1080p 片源 → 4K 桌面显示器」设计的桌面链——
  `Clamp_Highlights → Restore_CNN_M → Upscale_CNN_x2_M → AutoDownscalePre_x2 → AutoDownscalePre_x4 → Upscale_CNN_x2_S`
  （6~7 个 pass，含 2x/4x 中间帧缓冲），而档位说明文案写的门槛是「NVIDIA GTX 1660 / RX 6600」这类桌面显卡。手机屏幕不高于片源分辨率，放大出来的中间帧最终仍被压回屏幕尺寸——**GPU 代价全额付，收益被显示分辨率截断**。

  「连整个 app 一起卡」不是第二个 bug：移动端 libmpv 的 `vo=gpu` 与 Flutter 的 raster 共用同一块 GPU 与 EGL 驱动，CNN pass 占满 GPU 时 Flutter 合成排队等待，全局掉帧；持续满载再叠发热降频。

  **同一判断此前只做了一半**：`fushi/lib/src/media/video/video_mpv_config.dart:492` 的 `resolveScaleProperties` 早就为移动端把 EWA polar 降级成 spline36（"移动中端 GPU 扛不住"，TODO-1196 realme8 闪烁）。那次只改了「内置缩放」这一半，**GLSL 这一半一直漏着**。改前代码里唯一的应对是 `video_shader_dialog.dart` 加了一句「高档位可能掉帧或发热」的提示文案——那是补丁式绕过，不是修复：档位说明照旧写着桌面显卡型号，用户按说明选，然后卡死。

- **[x] ① 已修复** — 档位表改成**按平台投影**，与 `resolveScaleProperties` 同签名范式。
  - `video_shader_tier.dart`：新增 `kMobileVideoShaderTiers` + `shaderTiersFor({bool? isMobile})`；`shaderTierSpec` / `shaderFilesForTier` / `tierFromState` / `orderedEnabledForTier` 四个纯函数统一接 `isMobile`，保证「选档写入」与「反查回读」取同一张表（取不同表会让刚选的档立刻显示成「自定义」）。
  - `video_shader_downloader.dart`：新增三个**只修复、不放大**的移动端预设 `kAnime4kMobileRestoreSPreset` / `MPreset` / `MSoftPreset`，并登记进 `anime4kManifestFileNames()`（漏登记会让存储页删不掉这几个文件）。移动 中/高/极高 = `Clamp_Highlights` + `Restore_CNN_S` / `Restore_CNN_M` / `Restore_CNN_M + Restore_CNN_Soft_M`：pass 数 6~7 → 2~3，中间帧缓冲 2x/4x → 1x。1:1 观看时真正改善观感的本来就是修复 pass。
  - `video_shader_dialog.dart` / `web_video_fushi_page.dart`：档位选择器与对照表改走 `shaderTiersFor()`；`shaderTierLabelDescription` 按平台分文案（移动端不再显示 RTX 4060 这类桌面门槛）。
  - i18n：新增 4 个 `*_hint_mobile` key（经 `tool/i18n_sync.dart --add`），并改写 17 语言的 `video_shader_mobile_perf_hint`（旧文案「建议先用低/中档」已与新行为不符）。
  - **档位语义零变化**（无→极高，越高越强），持久化键与已启用集格式不动，桌面链一字未改；老用户手工勾选的自定义集仍走「自定义」通路。

- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_shader_tier_test.dart` 新增 group「移动端档位投影」8 条：
  - `shaderTiersFor` 按平台取表；移动表五档同序同 id（档位语义不变）；无/低 两端完全相同；
  - **核心不变式**：移动 中/高/极高 一个 `Upscale` / `AutoDownscale` 文件都不含，且同一断言对桌面档取反（`isNotEmpty`）作对照组——**防止写成恒真的空壳守卫**；
  - 移动档以 `Clamp_Highlights` 开头且 pass ≤ 3；移动五档文件集两两互异 → `tierFromState(isMobile: true)` 反查无歧义；`orderedEnabledForTier` 缺文件时保序过滤；移动档文件全部登记进 manifest。

- **备注**：
  - **未做真机复测**（该步骤按用户 2026-07-29 决定已取消）。因此有一种情形本次区分不了：除了上述纯 GPU 成本，是否还叠加了 **fp16 FBO 回落**——Anime4K 需要 `rgba16f` 中间缓冲，移动 GPU 上 mpv `fbo-format` 协商若回落，代价会再翻几倍。这条线有前科（BUG-465 因 Mali 16-bit 纹理 OOM 强制过 `vf=format=yuv420p`）。判据现成：`FUSHI_TEST_MPV_LOG_FILE` + `msg-level=all=v`（`video_player_controller.dart:1449`）会打出 VO / FBO 协商。
  - 移动三档的绝对开销未在真机量化。若某机型连「中」都吃不消，用户退回「低」（纯 mpv 内置 spline36，零 GLSL）即可——阶梯是可往下调的，这是保留三档而非直接封顶的理由。
  - `video_shader_mobile_copy_consistency_test.dart` 的英文文案守卫用子串 `vary` 判断，`varies` 不命中——改文案时容易撞。本次按守卫要求把限定词写成 `vary`，未动守卫。
