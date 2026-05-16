# Hibiki Agent Rules

本文件是 Claude/Codex 进入 Hibiki 仓库后的长期执行规则，不是项目宣传页。只保留会影响分析、修改、验证、审查和提交的内容；项目介绍放 README，细节设计放 docs。

## 基本规则

- 始终用中文回复。
- 开始分析、修改、测试、提交或 PR 前，先读取最近层级的 `AGENTS.md`；如果子目录里还有更近的 `AGENTS.md`，按更近层级执行。
- 遇到功能异常、测试失败、运行时报错或用户要求修复时，必须做根因修复：先复现或沿真实代码路径定位，再修数据结构、状态同步、生命周期、平台边界或依赖契约。
- 不允许用延迟、重试、吞异常、硬编码、特例分支来掩盖症状。只有外部系统或平台限制不可控时，才允许临时兼容层，并说明影响范围和清理条件。
- 函数和新增 Dart helper 要有明确类型签名。
- 不从零重写现有功能；在当前实现上删减、合并、修正。
- 发现问题要直接说，不要为了顺滑而把风险说轻。

## 仓库地图

- 仓库根：`D:\APP\vs_claude_code\hibiki`
- Flutter app：`hibiki/`
- Android 工程：`hibiki/android/`
- 当前阅读器入口：`hibiki/lib/src/pages/implementations/reader_hoshi_page.dart`
- 当前书架入口：`hibiki/lib/src/pages/implementations/reader_hoshi_history_page.dart`
- 当前 reader source：`hibiki/lib/src/media/sources/reader_hoshi_source.dart`
- Drift 数据库：`hibiki/lib/src/database/database.dart` 和 `hibiki/lib/src/database/tables.dart`
- 审查报告：`docs/reviews/YYYY-MM-DD-project-review.md`
- 已复现回归：`docs/REGRESSION_BUGS.md`
- 测试证据：`.codex-test/`

## 当前技术事实

- Flutter `3.41.6` / Dart `3.11.4`，最低 Android API 24。
- 主存储是 Drift SQLite：`HibikiDatabase`，偏好也落在 Drift `preferences` 表。旧注释里出现的 `Isar` / `Hive` 不一定代表当前事实，先查代码再判断。
- EPUB 阅读器当前走 Hoshi 实现：`ReaderHoshiPage` / `ReaderHoshiSource`。`ReaderHoshiSource.uniqueKey`、`reader_ttu/hoshi://book/...` 和部分 `setTtu*` 方法名只是旧数据兼容边界，不代表当前还有 TTU 阅读器；不要在没有迁移方案时随手改持久化 key。
- 词典导入和查询核心走 `hoshidicts` C++ FFI；格式 UI 或旧 Dart format 类不一定代表真实导入路径。
- 国际化使用 Slang，源文件在 `hibiki/lib/i18n/*.i18n.json`，生成文件是 `strings.g.dart`。
- 有声书/字幕相关核心路径在 `hibiki/lib/src/media/audiobook/`，当前导入入口包括 `book_import_dialog.dart` 和 `audiobook_import_dialog.dart`。
- 旧 TTU 只保留迁移用途：`TtuMigrationServer` / `TtuIdbReader` / `assets/ttu-ebook-reader` 用来读取历史 IndexedDB 数据。当前阅读器问题不要去 `D:\ttu-fork` 修。

## 集成测试素材

测试素材存放在仓库外固定路径，不纳入 git：

| 类型 | 路径 |
|------|------|
| EPUB | `.codex-test/fixtures/kagami/かがみの孤城 (辻村深月) (Z-Library).epub` |
| 音频 | `.codex-test/fixtures/kagami/かがみの孤城 [audiobook.jp 244083].m4b` |
| 字幕 | `.codex-test/fixtures/kagami/かがみの孤城 [audiobook.jp 244083].srt` |
| 字典 | `D:\辞典\` 目录下任意 `.zip`，推荐用体积小的先跑通流程 |

`D:\辞典\` 可用字典清单：
- `明镜日汉双解词典_Yomitan 1.4.4.zip`
- `[JA-JA] 日本語俗語辞書.zip`
- `[JA-JA] 実用日本語表現辞典.zip`
- `[JA Freq] BCCWJ_SUW_LUW_combined.zip`
- `[JA Freq] JPDB_v2.2_Frequency_Kana_2024-10-13.zip`
- `どんなときどう使う 日本語表現文型辞典_1_05.zip`
- `[JA-JA] 明鏡国語辞典 第三版[2025-08-18].zip`
- `（大修館）明鏡国語辞典［第二版］.zip`
- `Nihongo-Bunkei-Jiten.zip`
- `[JA-JA] ことわざ・慣用句の百科事典.zip`
- `[JA-JA] 絵でわかる慣用句 [2024-06-30].zip`
- `[JA-JA Expressions] 故事ことわざの辞典.zip`
- `[JA-JA Grammar] [画像付き] 絵でわかる日本語 v3.zip`
- `大辞泉/大辞泉 第二版[2025-04-29][no-images].zip`
- `大辞泉/大辞泉 第二版[2025-04-29].zip`
- `旺文社国語辞典 第十二版/旺文社国語辞典 第十二版[2025-04-29].zip`
- `小学館 例解学習国語 第十二版/小学館例解学習国語 第十二版[2025-08-18].zip`
- `[Pitch] NHK日本語発音アクセント新辞典.zip`

## 集成测试流程

集成测试需要一台已连接的 Android 模拟器或真机（`adb devices` 可见）。

### 冒烟测试（当前已有）

```powershell
cd hibiki
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/app_smoke_test.dart
```

验证 app 启动、渲染、导航切换不崩溃。

### 导入流程测试

1. **推送素材到设备**：
   ```powershell
   adb push ".codex-test\fixtures\kagami\かがみの孤城 (辻村深月) (Z-Library).epub" /sdcard/Download/
   adb push ".codex-test\fixtures\kagami\かがみの孤城 [audiobook.jp 244083].m4b" /sdcard/Download/
   adb push ".codex-test\fixtures\kagami\かがみの孤城 [audiobook.jp 244083].srt" /sdcard/Download/
   adb push "D:\辞典\明镜日汉双解词典_Yomitan 1.4.4.zip" /sdcard/Download/
   ```

2. **预授权限**：
   ```powershell
   adb shell pm grant app.hibiki.reader android.permission.READ_EXTERNAL_STORAGE
   adb shell pm grant app.hibiki.reader android.permission.WRITE_EXTERNAL_STORAGE
   ```

3. **验证点**：
   - EPUB 导入：文件进入书架、可打开阅读器、Scaffold 正常渲染
   - 有声书导入：m4b + srt 配对、书架可见、播放控件可渲染
   - 字典导入：zip 导入完成、搜索词条有结果返回
   - 综合：阅读器内划词查词能命中已导入字典

### 完整功能测试矩阵

以下是人工或自动化集成测试应覆盖的全部流程。

#### A. 启动与初始化

| # | 步骤 | 预期 |
|---|------|------|
| A1 | 全新安装启动（无数据库） | 自动创建 Default profile，显示首页 |
| A2 | 带历史数据启动（已有书/字典/配置） | 恢复上次状态，无崩溃 |
| A3 | 数据库迁移启动（旧 schema → 新 schema） | 迁移成功，数据完整 |

#### B. 字典导入与查词

| # | 步骤 | 预期 |
|---|------|------|
| B1 | 导入 Yomitan zip 字典（明镜日汉双解） | 导入进度显示，完成后字典列表可见 |
| B2 | 导入第二本字典（日本語俗語辞書） | 两本字典共存 |
| B3 | 搜索「猫」 | 返回包含释义的结果，多字典结果合并显示 |
| B4 | 搜索「食べる」（动词活用） | 命中词条 |
| B5 | 搜索不存在的词「xyzabc」 | 无结果，UI 不崩溃 |
| B6 | 删除一本字典 | 字典列表更新，搜索结果相应减少 |
| B7 | 导入频率字典（BCCWJ） | 频率标签显示在词条旁 |
| B8 | 导入 Pitch 字典（NHK） | 音高标注显示 |

#### C. EPUB 阅读器

| # | 步骤 | 预期 |
|---|------|------|
| C1 | 导入 EPUB（かがみの孤城） | 书架出现封面/标题 |
| C2 | 打开书籍 | 阅读器渲染首页内容 |
| C3 | 翻页（左滑/音量键） | 页面切换，进度更新 |
| C4 | 划词选中文本 | 弹出字典弹窗，显示释义 |
| C5 | 关闭阅读器再打开 | 恢复到上次阅读位置 |
| C6 | 长文本滚动（连续模式） | 无卡顿，滚动流畅 |

#### D. 有声书

| # | 步骤 | 预期 |
|---|------|------|
| D1 | 导入 m4b + srt（かがみの孤城 audiobook） | 书架出现有声书条目 |
| D2 | 播放 | 音频正常播放，字幕同步高亮 |
| D3 | 暂停/恢复 | 状态正确切换 |
| D4 | 拖动进度条 | 音频跳转，字幕重新同步 |
| D5 | 点击字幕文本查词 | 弹出字典弹窗 |
| D6 | 后台播放 | 切到其他 app 后音频继续 |
| D7 | 关闭再打开 | 恢复到上次播放位置 |

#### E. 阅读器配置项逐项测试

每项配置修改后验证阅读器立即反映变化，不崩溃。

| # | 配置项 | 测试值 | 验证 |
|---|--------|--------|------|
| E1 | fontSize | 14, 22, 36, 50 | 字体大小变化可见 |
| E2 | lineHeight | 1.0, 1.65, 2.5 | 行距变化可见 |
| E3 | writingMode | `vertical-rl`, `horizontal-tb` | 排版方向切换 |
| E4 | viewMode | `paginated`, `continuous` | 分页/滚动切换 |
| E5 | theme | `light-theme`, `dark-theme`, `sepia-theme` | 主题颜色变化 |
| E6 | furiganaMode | `show`, `hide`, `partial`, `toggle` | 振假名显示/隐藏 |
| E7 | textIndentation | 0, 1, 2 | 首行缩进变化 |
| E8 | marginTop/Bottom/Left/Right | 0, 10, 30, 50 | 边距变化可见 |
| E9 | pageColumns | 0 (auto), 1, 2 | 分栏变化 |
| E10 | enableVerticalFontKerning | true, false | 字距变化 |
| E11 | enableFontVPAL | true, false | VPAL 生效 |
| E12 | verticalTextOrientation | `mixed`, `upright` | 竖排英文方向变化 |
| E13 | enableTextJustification | true, false | 两端对齐 |
| E14 | prioritizeReaderStyles | true, false | 原书样式/自定义样式切换 |
| E15 | autoReadOnLookup | true, false | 查词时是否自动朗读 |
| E16 | highlightOnTap | true, false | 点击是否高亮 |
| E17 | keepScreenAwake | true, false | 屏幕常亮切换 |
| E18 | tapEmptyToHideChrome | true, false | 点击空白隐藏工具栏 |
| E19 | invertSwipeDirection | true, false | 翻页方向反转 |
| E20 | volumePageTurningSpeed | 50, 100, 200 | 音量键翻页速度 |
| E21 | dismissSwipeSensitivity | 0.3, 0.6, 0.9 | 滑动返回灵敏度 |
| E22 | customFonts | 添加字体、启用/禁用、排序、删除 | 自定义字体生效 |

#### F. 配置组合与随机测试

| # | 步骤 | 预期 |
|---|------|------|
| F1 | 竖排 + 分页 + 振假名显示 + 大字体(36) + 暗色主题 | 正常渲染 |
| F2 | 横排 + 连续滚动 + 振假名隐藏 + 小字体(14) + 亮色主题 | 正常渲染 |
| F3 | 竖排 + 2栏 + 大边距(30) + 自定义字体 | 正常渲染 |
| F4 | 随机 3-5 项阅读器配置同时修改 | 无崩溃，设置均生效 |
| F5 | 快速连续切换 writingMode 10 次 | 无卡死、无白屏 |
| F6 | 修改配置 → 关闭阅读器 → 重新打开 | 配置持久化，重新打开后仍然生效 |
| F7 | 修改配置 → 杀进程 → 重新启动 | 配置不丢失 |
| F8 | 字典: auto_search=true + debounce=100 + maximum_terms=1 + 大字体 | 正常工作 |
| F9 | 播放器: 后台播放 + 听力模式 + 浮动歌词 + 横屏 | 正常播放 |
| F10 | 主题: 暗色 + 自定义种子色 + 自定义字体色 + 自定义背景色 | 渲染正常，颜色不冲突 |
| F11 | 跨域: 暗色主题 + 竖排阅读器 + 字典大字体 + 播放器听力模式 | 全部生效，不互相干扰 |
| F12 | 随机跨域 5-8 项不同区域配置同时修改 | 无崩溃，各区域独立生效 |
| F13 | 模糊窗口: 全部参数设为非默认值 | 模糊遮罩正确渲染 |
| F14 | 音频源: 添加3个源 + 本地音频启用 + 查词 | 优先级正确，音频可播放 |
| F15 | 修改字典/播放器/主题配置 → 杀进程 → 重启 | 所有非阅读器配置也持久化 |

#### G. Profile 系统测试

| # | 步骤 | 预期 |
|---|------|------|
| G1 | 创建新 Profile「竖排暗色」 | Profile 列表出现 |
| G2 | 在当前配置下 snapshot 到该 Profile | 设置快照保存成功 |
| G3 | 修改若干配置项 | 当前配置改变 |
| G4 | 切换回「竖排暗色」Profile（apply） | 所有配置恢复到快照时的状态 |
| G5 | 创建第二个 Profile「横排亮色」 | 两个 Profile 共存 |
| G6 | 在两个 Profile 间反复切换 | 每次切换后配置完全对应 |
| G7 | 复制 Profile | 新 Profile 设置与源完全一致 |
| G8 | 重命名 Profile | 名称更新，设置不变 |
| G9 | 删除非活跃 Profile | 列表更新，当前配置不变 |
| G10 | 删除唯一 Profile | 阻止删除（至少保留一个） |
| G11 | 绑定 Profile 到媒体类型（EPUB → 竖排暗色） | 打开 EPUB 时自动应用该 Profile |
| G12 | 绑定 Profile 到具体书籍 | 打开该书时用书级 Profile，优先于媒体类型绑定 |
| G13 | 删除已绑定的 Profile | 绑定关系清理，回退到 Default |
| G14 | 修改配置 → 切换 Profile → 切换回来 | 未保存的修改被覆盖（apply 是全量替换） |

#### H. 字典配置项逐项测试

| # | 配置项 | 测试值 | 验证 |
|---|--------|--------|------|
| H1 | dictionary_entry_font_size | 10, 16, 24, 32 | 字典弹窗/页面字体大小变化 |
| H2 | maximum_terms | 1, 5, 10, 20 | 搜索结果条数限制生效 |
| H3 | auto_search | true, false | 输入时自动搜索 vs 需按回车 |
| H4 | auto_search_debounce_delay | 100, 300, 500, 800 | 停止输入后触发搜索的延迟可感知 |
| H5 | collapse_dictionaries | true, false | 多字典结果折叠/全展开 |
| H6 | deduplicate_pitch_accents | true, false | 相同音高条目去重/保留全部 |
| H7 | harmonic_frequency | true, false | 频率调和计算显示/隐藏 |
| H8 | custom_dict_css | 添加自定义样式、清空 | 指定字典条目样式变化 |
| H9 | global_dict_css | 添加背景色样式、清空 | 所有字典全局样式变化 |
| H10 | search_history_by_key | true, false | 搜索历史按字典分类 vs 全局合并 |
| H11 | auto_add_book_name_to_tags | true, false | Anki 导出时自动加书名标签 |
| H12 | 字典排序（拖拽调整顺序） | 把第二本拖到第一位 | 搜索结果优先显示新排第一的字典 |
| H13 | 启用/禁用单本字典 | 禁用一本字典 | 搜索结果不再包含该字典 |
| H14 | 字典显示名称修改 | 改为自定义名称 | UI 各处使用新名称 |

#### I. 播放器配置项逐项测试

| # | 配置项 | 测试值 | 验证 |
|---|--------|--------|------|
| I1 | player_listening_comprehension_mode | true, false | 字幕隐藏（听力模式）/ 正常显示 |
| I2 | player_background_play | true, false | 切到后台继续播放 / 暂停 |
| I3 | double_tap_seek_duration | 5, 10, 15, 30 | 双击快进/快退秒数变化 |
| I4 | show_floating_lyric | true, false | 浮动歌词 overlay 显示/隐藏 |
| I5 | floating_lyric_font_size | 12, 18, 24, 32 | 浮动歌词文字大小变化 |
| I6 | is_transcript_opaque | true, false | 字幕区域不透明/半透明 |
| I7 | is_transcript_player_mode | true, false | 字幕播放器模式（全屏字幕）/ 普通 |
| I8 | player_orientation_portrait | true, false | 强制竖屏 / 跟随系统 |
| I9 | player_hardware_acceleration | true, false | 硬件加速开关 |
| I10 | player_use_opensles | true, false | OpenSL ES 音频引擎切换 |
| I11 | player_subtitle_notification | true, false | 通知栏显示当前字幕 |
| I12 | stretch_to_fill_screen | true, false | 视频拉伸填满/保持比例 |
| I13 | show_play_bar | true, false | 底部播放条显示/隐藏 |
| I14 | show_media_notification | true, false | 媒体通知栏控件显示/隐藏 |

#### J. 主题与外观配置逐项测试

| # | 配置项 | 测试值 | 验证 |
|---|--------|--------|------|
| J1 | app_theme_key | 逐个切换所有内置预设 | 全局颜色方案变化 |
| J2 | custom_theme_seed | #FF0000, #00FF00, #0000FF | 种子色影响全局 Material You 配色 |
| J3 | custom_theme_dark | true, false | 深色/浅色模式切换 |
| J4 | custom_theme_font_color | #000000, #FFFFFF, #FF5722 | 全局文字颜色变化 |
| J5 | custom_theme_bg_color | #FFFFFF, #121212, #FFF8E1 | 背景颜色变化 |
| J6 | custom_theme_selection_color | #BBDEFB, #FF4081 | 文本选中高亮颜色变化 |
| J7 | custom_theme_primary_color | 多种颜色 | 主色调（AppBar、按钮）变化 |
| J8 | custom_theme_secondary_color | 多种颜色 | 次要色调变化 |
| J9 | custom_theme_tertiary_color | 多种颜色 | 第三色调变化 |
| J10 | custom_theme_container_color | 多种颜色 | 容器/卡片背景变化 |
| J11 | custom_theme_sasayaki_color | 多种颜色 | Sasayaki 弹窗颜色变化 |
| J12 | custom_theme_link_color | 多种颜色 | 链接/可点击文字颜色变化 |
| J13 | 修改主题后重启 app | — | 主题持久化，不回退 |
| J14 | 自定义主题各项 → 切回内置预设 → 再切回自定义 | — | 自定义值保留不丢失 |

#### K. UI/弹窗/浮动配置项逐项测试

| # | 配置项 | 测试值 | 验证 |
|---|--------|--------|------|
| K1 | show_floating_dict | true, false | 浮动字典服务启动/停止 |
| K2 | popup_max_width | 300, 500, 800, 全屏 | 字典弹窗宽度限制变化 |
| K3 | disable_dialog_scrim | true, false | 弹窗背景遮罩显示/隐藏 |
| K4 | populate_bookmarks | true, false | 自动填充书签列表 |
| K5 | current_home_tab_index | 0, 1, 2, 3 | 重启后恢复到上次所在 tab |
| K6 | target_language | ja, zh, ko, en | 目标语言切换影响词典/分词 |
| K7 | app_locale | zh, ja, en | app UI 语言切换 |

#### K2. 模糊窗口配置项逐项测试

| # | 配置项 | 测试值 | 验证 |
|---|--------|--------|------|
| K2-1 | blur_visible | true, false | 模糊遮罩显示/隐藏 |
| K2-2 | blur_width | 100, 200, 500 | 模糊区域宽度变化 |
| K2-3 | blur_height | 50, 100, 300 | 模糊区域高度变化 |
| K2-4 | blur_left | 0, 50, 200 | 模糊区域水平位置 |
| K2-5 | blur_top | 0, 50, 200 | 模糊区域垂直位置 |
| K2-6 | blur_red | 0, 128, 255 | 模糊颜色红通道 |
| K2-7 | blur_green | 0, 128, 255 | 模糊颜色绿通道 |
| K2-8 | blur_blue | 0, 128, 255 | 模糊颜色蓝通道 |
| K2-9 | blur_opacity | 0.0, 0.5, 1.0 | 模糊透明度 |
| K2-10 | blur_radius | 0, 5, 15, 30 | 模糊半径（强度） |

#### K3. 音频源配置项逐项测试

| # | 配置项 | 测试值 | 验证 |
|---|--------|--------|------|
| K3-1 | audio_sources | 添加远程音频源 URL | 查词时音频可播放 |
| K3-2 | audio_sources | 删除音频源 | 该源不再出现在结果中 |
| K3-3 | audio_sources | 调整音频源优先级（排序） | 优先使用排位靠前的源 |
| K3-4 | local_audio_enabled | true, false | 本地音频查找启用/禁用 |
| K3-5 | local_audio_db_path | 设置有效路径 | 本地音频可被索引和播放 |
| K3-6 | local_audio_db_path | 设置无效路径 | 友好提示，不崩溃 |

#### K4. 边界与异常

| # | 步骤 | 预期 |
|---|------|------|
| K4-1 | fontSize 设为极端值（1, 200） | 不崩溃，合理限制或渲染 |
| K4-2 | margin 设为负数 | 不崩溃，忽略或归零 |
| K4-3 | 导入损坏的 EPUB | 友好错误提示，不崩溃 |
| K4-4 | 导入损坏的字典 zip | 友好错误提示 |
| K4-5 | 导入超大字典（大辞泉 完整版） | 导入成功，不 OOM |
| K4-6 | 数据库并发写入（快速连续修改配置） | 无死锁、无数据丢失 |
| K4-7 | 断网状态下所有本地功能 | 正常工作 |
| K4-8 | 存储空间不足时导入 | 友好提示 |
| K4-9 | debounce_delay 设为 0 | 不崩溃，立即搜索 |
| K4-10 | maximum_terms 设为 0 | 不崩溃，显示空或忽略 |
| K4-11 | popup_max_width 设为极小（50） | 弹窗仍可用，不溢出 |
| K4-12 | blur_opacity 设为超出范围（-1, 2.0） | 钳位或忽略，不崩溃 |
| K4-13 | custom_fonts JSON 格式损坏 | 忽略错误，回退空列表 |
| K4-14 | 字典 CSS 包含恶意 `<script>` | XSS 被过滤或不执行 |
| K4-15 | 所有字典禁用后搜索 | 空结果，不崩溃 |
| K4-16 | profile 快照为空（无任何偏好设置） | apply 后回退默认值 |
| K4-17 | 两个 Profile 快速反复切换 50 次 | 无死锁、无数据错乱 |

#### L. Creator 与 Anki 集成

| # | 步骤 | 预期 |
|---|------|------|
| L1 | 从阅读器划词 → 打开 Creator | Creator 页面显示选中词、释义 |
| L2 | 选择 Anki deck 和 note type | 下拉列表从 AnkiDroid 加载 |
| L3 | 映射字段（word → Front, meaning → Back） | 映射保存成功 |
| L4 | 添加图片（拍照/相册） | 图片附加到卡片 |
| L5 | 添加音频（录音/选择文件/本地音频源） | 音频附加到卡片 |
| L6 | 裁剪已选图片 | 裁剪结果正确保存 |
| L7 | 从 Stash 选择文本填入字段 | 文本正确填充 |
| L8 | 选择例句 | 例句字段填充 |
| L9 | 设置标签 | 标签保存到卡片 |
| L10 | 导出到 AnkiDroid | 卡片成功写入 AnkiDroid |
| L11 | 允许重复 / 禁止重复 | 重复检查生效 |
| L12 | embedMedia: true/false | 媒体嵌入/引用切换 |
| L13 | compactGlossaries: true/false | 释义紧凑/完整显示 |

#### M. Android Intent 与系统集成

| # | 步骤 | 预期 |
|---|------|------|
| M1 | 在其他 app 选中文本 → PROCESS_TEXT intent | Popup Dictionary 弹出，显示释义 |
| M2 | 从其他 app 分享文本 → SEND intent | Popup Dictionary 接收并查词 |
| M3 | 系统搜索 → WEB_SEARCH/SEARCH intent | app 接收并在字典搜索 |
| M4 | 开启 Floating Dictionary 服务 | 前台服务启动，通知栏图标可见 |
| M5 | 剪贴板复制文本 → Floating Dict 反应 | 浮动字典自动查词 |
| M6 | Quick Settings Tile 点击 | 浮动字典开关切换 |
| M7 | 媒体通知栏控件（播放/暂停/跳转） | 控件响应，音频状态正确 |

#### N. 收藏与标注

| # | 步骤 | 预期 |
|---|------|------|
| N1 | 阅读器中长按高亮文本 | 高亮保存，颜色可见 |
| N2 | 有声书中添加书签 | 书签保存到当前时间戳 |
| N3 | 打开 Collections 页面 | 书签和收藏句子分类可见 |
| N4 | 删除书签/高亮 | 列表更新 |
| N5 | 收藏例句 | 句子出现在收藏列表 |
| N6 | 阅读器递归查词（释义中再查词） | 嵌套弹窗正常工作 |

#### O. 媒体管理与组织

| # | 步骤 | 预期 |
|---|------|------|
| O1 | 创建标签 | 标签列表出现 |
| O2 | 给书籍分配标签 | 书籍关联标签 |
| O3 | 按标签筛选书架 | 只显示匹配书籍 |
| O4 | 重命名/删除标签 | 列表更新，书籍关联清理 |
| O5 | 编辑媒体元数据（标题/作者） | 修改保存，书架显示更新 |
| O6 | 查看 EPUB 插图 | 插图列表正确提取和显示 |
| O7 | 编辑书籍自定义 CSS | CSS 保存，阅读器样式变化 |
| O8 | 查看阅读统计 | 时间/字数统计正确显示 |

#### P. 高级功能

| # | 步骤 | 预期 |
|---|------|------|
| P1 | 切换 app 语言（日/中/英） | UI 文本即时切换 |
| P2 | 文本分词（Text Segmentation） | 正确分割日语句子为词 |
| P3 | 动词活用查询 | 返回变形形态 |
| P4 | WebSocket 阅读源配置 | 连接成功，接收文本 |
| P5 | 歌词搜索 | 按曲名/歌手搜索返回结果 |
| P6 | Stash 管理（保存/搜索/删除/分享） | CRUD 正常 |
| P7 | 查看调试日志 | 日志页面正确显示 |
| P8 | 查看错误日志 | 错误记录可查看 |
| P9 | 检查更新 | 正确检查版本，弹出更新提示 |
| P10 | auto_add_book_name_to_tags: true/false | Anki 卡片自动加书名标签 |

## 审查规则

- 用户要求审查项目、继续审查、风险审计或类似任务时，默认进入持续审查模式；不要只在聊天里输出一次性总结。
- 审查报告写入 `docs/reviews/YYYY-MM-DD-project-review.md`。如果目录不存在，先创建 `docs/reviews/`。
- 每轮审查追加到同一个报告文件，不覆盖历史内容。每轮至少包含：
  - `Scope`: 本轮检查的文件、路径、提交范围或用户路径。
  - `Findings`: 按 `HBK-AUDIT-XXX` 编号列出问题；每个问题必须包含 `severity`、`status`、文件/行号、根因、影响、修复建议和验证方式。
  - `Next Scope`: 下一轮继续审查的范围。
- 审查顺序默认按风险走：数据库/迁移 -> 启动初始化 -> 阅读器状态 -> 字典导入/native FFI -> 音频 cue -> WebView/缓存 -> UI 假状态。
- 审查阶段只写报告和修复建议，不改业务代码；除非用户明确要求“开始修”“逐条修”或等价指令。
- 如果审查或手工验证发现已复现回归，必须同步更新 `docs/REGRESSION_BUGS.md`，并把截图、UI XML、logcat 或 bounds 证据放到 `.codex-test/` 后在报告中引用。
- 报告结论必须区分“代码路径审查发现的风险”“已经复现的 bug”“已验证通过的修复”。没有跑过验证时，不要写成已通过。

## 验证规则

- 文档规则改动：至少运行 `git diff --cached --check`，不需要跑 Flutter 测试。
- Dart/Flutter 改动：在 `hibiki/` 下运行：
  ```powershell
  D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat format .
  D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat test
  ```
- Android 资源、manifest、Gradle、权限、通知、前台服务或打包行为改动：还要运行：
  ```powershell
  cd hibiki\android
  .\gradlew.bat :app:assembleRelease
  ```
- 修改当前阅读器 WebView、JS、CSS、资源拦截或分页逻辑时，只在 Hibiki 侧验证 Hoshi 阅读器路径。修改旧 TTU 迁移代码或迁移资产时，验证“历史 IndexedDB -> 当前 Hoshi 存储/书架”的迁移路径。
- 声明“修好了”之前，必须验证原始失败路径；阅读器/导入/播放/布局问题必须用真实模拟器或用户指定设备复测，并留下证据路径。

## 提交规则

- 每次完成代码、文档、测试或审查报告修改后，默认提交本轮改动。
- 提交前检查 `git status --short`，只 stage 本轮相关文件；工作区已有的无关改动不得纳入提交。
- 提交前运行 `git diff --cached --check`。
- 提交信息要简洁说明真实改动，例如 `docs: rewrite claude agent rules` 或 `fix(reader): preserve restore position`。
- 提交后再次检查 `git status --short`，并在回复中说明提交哈希和仍然存在的无关未提交改动。
