## BUG-5054 · 音调词典 H/L 模式串只显示成文本、不画高低线，且与同型数字位分成两行
- **报告**：2026-11-19（应用内反馈 ax68AKUrex，Android，「音调词典不显示」；截图查「関係」：`音调·2｜NHK-meta｜大辞泉+ [LHHHH]` 一行只有文字，`アクセント辞典 かんけい[0]` 另起一行）
- **真实性**：✅ 真 bug。大辞泉+ / NHK-meta 的 Yomitan pitch `position` 是 H/L 模式串（Yomitan schema 允许，上游 `isMoraPitchHigh` 按逐拍字符画图）。原生层已原样解析进 popup JSON 的 `patterns`（`native/fushidicts/fushidicts_src/popup_json.cpp:262`），但 popup.js 消费端：
  - 弹窗 `createPitchGroup` 把 patterns 一律当纯文本 `[LHHHH]`（修前 `fushi/assets/popup/popup.js:4512-4518`），`isMoraPitchHigh`（修前 `:4350`）只认数字位，画不了图；
  - 弹窗 `createPitchSection`（修前 `:4590`）与制卡 `buildMinePayload`（修前 `:2860`）都没把 H/L 串换算成下降位，于是 [LHHHH] 与 [0] 同为平板型却进不了 `mergeIdenticalPitchGroups` / 去重，分成两行；制卡 `{pitch-accent-positions}` 写成 `[LHHHH]`，`{pitch-accent-categories}` 对这类词典为空。NHK-meta 没有丢，是与大辞泉+ payload 全等被合并进了同一行。
- **[x] ① 已修复** — popup.js（三份镜像同步）：`isMoraPitchHigh` 支持 H/L 串；新增 `normalizePitchPatterns` / `pitchPatternToDownstep`，长度为「拍数 + 1」（或拍数且可唯一判定）的 H/L 串换算成数字下降位，在弹窗与制卡两条路径的 `mergeIdenticalPitchGroups` 之前跑，制卡分类也吃换算后的分组；只给拍数且末拍高（平板 / 尾高不可分）或不规则的串不硬猜，仍留作 pattern，但长度对得上读音时按逐拍高低画高低线。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_pitch_hl_pattern_test.dart` + `.js`（Node 真跑 popup.js：换算、合并成一行并画图、不规则串画图、制卡字段 [0] + heiban 分类；三份镜像源码级钉接线）
- **备注**：NHK-meta 的 devoice / nasal（无声化 / 鼻浊音）目前在原生 popup JSON / FFI 都没有导出，数字位词典也一样不显示，属于新增展示能力，本次未做。Dart 制卡字段 `pitch_accent_field.dart` 走自己的 `PitchSvg`（本就按 H/L 画），不受影响。阅读器弹窗是 WebView 布局，未在真机复测。
