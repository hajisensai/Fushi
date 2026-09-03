## BUG-1747 · 字幕来源设置三种行各有一套左右边界
- **报告**：2026-08-19（用户：设置 → 视频 → 字幕来源「这个右边的 UI 不太对劲」）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/pages/implementations/video_external_provider_settings_section.dart` 的 `_field` 局部限宽 480 与整段缺少统一宽度容器
- **[x] ① 已修复** — 整段收进 `kTorrentSettingsContentMaxWidth`（560）左对齐容器，删掉 `_field` / `_subtitleLanguageField` 各自那份 480
- **[x] ② 已加自动化测试** — `fushi/test/settings/video_external_provider_settings_section_test.dart` 的宽窗边界一致性用例（已变异实测）
- **备注**：同一份 `_field` 拷贝也在 `torrent_settings_section.dart:238`，「下载 → 外部来源」那段有同样的撕裂，本次未动（见「未修」）

### 现象（用户截图实测几何）

右侧内容 pane 从 x≈430 一直到窗口右缘（≥1415），而：

| 行 | 宽度 | 来源 |
|---|---|---|
| 单列输入框（API 端点 / API 密钥 / User-Agent / 默认字幕语言） | 约 573px | `_field` 自己的 `ConstrainedBox(maxWidth: 480)` × 界面缩放 1.19 |
| Switch（已启用 / 允许不安全的 HTTP） | 占满整个 pane，拇指贴 x≈1385 | 裸 `SwitchListTile.adaptive` 吃 `CrossAxisAlignment.stretch` 的**紧约束** |
| 用户名 / 密码 | 第三套：各占 pane 一半 | `Row` 全宽 → `Expanded` 各半 → `_field` 的 480 在半宽下不生效 |

看起来就是「输入框只占左半边、开关孤零零贴在最右、中间一大片空白」，双列行还和上下的单列框右边缘对不齐。

### 根因：同一个 Column 里三种孩子用三种方式消费约束

不是某一行写错了，是**这一段从来没有一对共同的左右边界**。`Align + ConstrainedBox` 让输入框自己缩，`stretch` 让开关自己撑满，`Expanded` 让双列行按父宽二分——三者各自都"对"，合在一起就撕。

### 这个问题修过一次，又被撤掉了

- `BUG-1084`：4K 下输入框被拉到 3000px → 引入 `_field` 的 480 局部限宽。
- `BUG-1278`（2026-07-29，**用户报的就是这次同样的现象**）→ 修法是把整组表单收进 `kTorrentSettingsContentMaxWidth = 560` 并居中。
- `040e583eac`（2026-08-03，PR #751）加了 `constrainWidth` 开关，把设置详情 pane 的两个调用点全改成 `constrainWidth: false` 走 full-bleed 分支。**BUG-1278 的修复在真实 app 里就此失效**——而守卫 `torrent_settings_field_width_test.dart` 只测 `constrainWidth: true`，所以一直是绿的，没人发现。

更关键的是：用户这次报的**字幕来源**那段走的是 `settings_schema_video.dart:1191` 的 `SettingsCustomItem`，**根本不经过 `TorrentSettingsSection`**，从来就没有任何外层宽度容器。

### 修复

`VideoExternalProviderSettingsSection` 内部新增 `_constrainSectionWidth`，build 的两个分支都套上：左对齐 + `maxWidth: kTorrentSettingsContentMaxWidth`。同时删掉 `_field` 与 `_subtitleLanguageField` 各自那份 480——它们的存在理由（BUG-1084）由外层容器完整承接。

于是三种行的宽度都等于容器宽度：单列框填满、Switch 填满、双列行两半合计填满，左右边界完全一致。

用**左对齐**而不是 BUG-1278 的居中：这一段嵌在设置详情的行流里，居中会与上下普通设置行的左基线再撕一次。

### 测试

宽窗（1400）harness 是必需的：560 的窄 harness 下输入框（旧上限 480）与开关只差 80px，肉眼和断言都容易放过；1400 下差距是几百像素，正是用户截图的样子。断言三者左右边缘重合，并保留「输入框宽度 ≤561」守住 BUG-1084。

变异实测：把 `_field` 的局部 480 加回去 → 用例必红；还原后源文件 sha256 逐字节一致。

### 未修（同源，另立）

1. `torrent_settings_section.dart:238` 有同一份 `_field` 拷贝（也是 480），「设置 → 下载 → 外部来源」那段在 `constrainWidth: false` 下有一模一样的撕裂。两份 `_field` 应当合并成一个共享组件，而不是各修各的。
2. `settings_schema_downloads.dart:58` / `downloads_page.dart:483` 的 `constrainWidth: false` 让 BUG-1278 的修复在真实 app 里失效，而守卫只测 `true` 分支。这是「修复只活在测试里」的典型，值得单独复核 PR #751 的意图。
