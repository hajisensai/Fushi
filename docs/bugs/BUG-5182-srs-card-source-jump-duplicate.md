## BUG-5182 · 复习卡「回到出处」入口重复（媒体胶囊 + 例句旁 ↩）
- **报告**：2026-11-22（用户：维护者，应用内反馈 unGQ8ykXGJ「回到出处重复了吧，删掉句子旁边的合适。没有句子的咋办」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/srs/srs_fushi_card_view.dart` 的 `_withSourcePill` 在媒体左下角画胶囊，例句卡（旧 :1104）只要有出处就再画一个 ↩，两处条件都只看「有没有出处」、互不知情，有媒体又有例句的卡就画出两个入口（8f3a303a3e 引入）。
- **[x] ① 已修复** — 新增 `_sourceJumpSlot`（`srs_fushi_card_view.dart:958`）按背面区块布局只定一个入口位置：有媒体素材 → 媒体胶囊；没有媒体 → 例句卡右侧 ↩；连例句也没有 → 词条行尾 ↩（`_header(sourceJump:)`）。`_picture` / `_sentence` / `_header` 只按这个结果画，胶囊是否画出与 `_drawsPicture` 同一判据。顶栏图标不变。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_source_jump_test.dart`（真复习页 + 内存库，MD3 / Apple）：有媒体只有胶囊、例句卡无 ↩；无媒体 ↩ 在例句卡；无媒体无例句 ↩ 在词条区；各自点按落到同一跳转。还原修复后有媒体 / 无例句两组用例变红。
- **备注**：来源行（区块布局里的「来源」元信息链接）是信息展示，本次不并入去重。
