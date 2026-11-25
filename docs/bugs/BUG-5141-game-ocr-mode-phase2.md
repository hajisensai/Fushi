## BUG-5141 · OCR 游戏模式第二期：等待动画卡死稳定判据、按游戏记区域、小字预处理、AI 操作路由
- **报告**：2026-11-22（拍板台 `v5GSgDau9u`「希望添加基于 OCR 的游戏模式」第一期的剩余项；同子系统 BUG-5083）
- **真实性**：✅ 功能缺口 + 一处判定缺陷（第一期：spec `docs/specs/2026-11-22-game-ocr-line-stream-design.md` §6）。本期范围：
  1. **框内持续动画让帧永远「不稳定」**（判定缺陷）：`native/fushi_compute/src/ocrline.rs` 的 `feed_rgba` 要求整框相邻两帧
     签名不变才交 OCR；台词框里「等待点击」动画图标与取帧间隔错相循环时，每帧都有 ≥2 格在变，一直 `Settling`、整句不出。
  2. **识别区域只记一份全局**（偏好 `gal_ocr_region`），换个游戏就得重框。
  3. **小字放大 / 二值化预处理**：低分辨率游戏上 Windows OCR 识别率差。
  4. **AI 操作目录**：`fushi/lib/src/ops/ctl_game_routes.dart` 没有 OCR 模式的路由。
  原清单里的「持续 WGC 会话直出框内 BGRA」与「OCR 行的游戏内嵌查词」拆到 **BUG-5299**（第三期）。
- **[x] ① 已修复** —
  1. `ocrline.rs`：每格记易变分（变一次 +2、稳一帧 -1，≥6 算易变），稳定判据与「是否已 OCR 过」都排除易变格；
     打字机每格只出墨一次不会被当成易变；易变格超过网格四分之一（整框在动）时掩码作废、退回整框判定。
  2. `GalCaptureMemory.ocrRegion` / `ocrBinarize`（按游戏 exe 记，`gal_hook_session_controller.dart`）：`startOcrCapture` /
     `setOcrRegion` / `setOcrBinarize` 写入，`rememberedOcrSettingsFor(window)` 按窗口 PID → exe 读回；工作台框选的初值
     = 本局 / 该游戏记住的 / 全局上次的框 / 默认框。
  3. `ocrline.rs` `prepare_for_ocr`：按有墨行段估字高，< 16 px 时整数倍放大到约 24 px（≤4 倍、最长边 ≤2600 =
     `OcrEngine.MaxImageDimension`）；新 FFI `ffc_ocrline_configure` 开 Otsu 二值化（少数派当字，白底黑字），
     框选对话框加「二值化文字」开关，按游戏记住。
  4. `POST /api/admin/game/ocr/start`（`game.ocr.start`，不可逆：替换当前会话；已在对该窗口跑 OCR 时只套用给出的框 /
     开关）与 `PUT /api/admin/game/ocr/region`（`game.ocr.region.set`，可撤销），`game status` 的 `session.mode = ocr`
     并带 `session.ocr`；顺带修 `game attach` 把「对同一窗口跑着 OCR」误判成「已附着」。
- **[x] ② 已加自动化测试** — Rust `ocrline.rs`（`looping_wait_icon_does_not_block_ocr_forever`、
  `typewriter_cells_never_become_volatile`、`whole_box_animation_disables_the_mask`、`small_text_is_upscaled_before_ocr`、
  `upscale_respects_ocr_max_dimension`、`binarize_makes_dark_text_on_white_for_both_polarities`、
  `configure_binarize_reoffers_the_same_frame`）；`packages/fushi_compute/test/ocr_line_test.dart`（真 FFI 放大 + 二值化）；
  `fushi/test/mining/gal_ocr_line_source_test.dart`（泵下发二值化、会话中关掉重识别）；
  `fushi/test/mining/gal_ocr_session_test.dart`（按游戏记忆读写、查不到 exe 不写）；
  `fushi/test/mining/gal_ocr_region_picker_test.dart`（对话框开关）；`fushi/test/ops/ctl_game_routes_test.dart` /
  `op_undo_games_dictionary_test.dart`（路由与撤销）。
- **备注**：只做 Windows（与 galgame 制卡同车道），不注入、不碰 Hook 适配边界。等待动画是合成帧回归，真机素材
  （联网游戏 / 模拟器窗口）未验。
