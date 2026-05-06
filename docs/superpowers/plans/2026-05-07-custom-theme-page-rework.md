# Custom Theme Page Rework — 修复交互 + 改善说明 + 增强预览

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复种子色选择器点击无反应的 bug，给每个颜色添加用途说明，增强预览效果，把不常用颜色收到"高级"折叠区。

**Architecture:** `flutter_colorpicker` 的 ColorPicker 放在 ListView 里，垂直拖拽手势被 ListView 滚动抢走。通过 Listener + Scrollable.position.hold() 修复。UI 重构为三个区域：基础色 → 阅读器颜色 → 界面强调色（高级折叠）。

**Tech Stack:** Flutter 3.41.6, flutter_colorpicker ^1.1.0, slang i18n (手动编辑 .g.dart)

---

### Task 1: 添加 i18n 描述字符串

**Files:**
- Modify: `hibiki/hibiki/lib/i18n/strings.i18n.json:682-697`
- Modify: `hibiki/hibiki/lib/i18n/strings_zh-CN.i18n.json:651-666`

- [ ] **Step 1: 在 strings.i18n.json 中添加新键**

在 `"color_container": "Container"` 后面添加：

```json
    "seed_color_desc": "Generates all default colors below",
    "color_primary_desc": "Audio highlight, buttons, switches",
    "color_secondary_desc": "Dictionary entries, bookshelf badges",
    "color_tertiary_desc": "Collections, reading statistics",
    "color_container_desc": "Switch tracks, play bar background",
    "font_color_desc": "Reader text color",
    "background_color_desc": "Reader page background",
    "selection_color_desc": "Reader text selection highlight",
    "section_reader_colors": "Reader Colors",
    "section_advanced_colors": "Advanced"
```

- [ ] **Step 2: 在 strings_zh-CN.i18n.json 中添加对应中文**

在 `"color_container": "容器色"` 后面添加：

```json
    "seed_color_desc": "自动生成下方所有默认颜色",
    "color_primary_desc": "音频高亮、按钮、开关",
    "color_secondary_desc": "词典条目、书架标签",
    "color_tertiary_desc": "收藏夹、阅读统计",
    "color_container_desc": "开关轨道、播放栏",
    "font_color_desc": "阅读器文字颜色",
    "background_color_desc": "阅读器页面背景",
    "selection_color_desc": "阅读器选中高亮",
    "section_reader_colors": "阅读器颜色",
    "section_advanced_colors": "高级选项"
```

---

### Task 2: 手动更新 strings.g.dart

**Files:**
- Modify: `hibiki/hibiki/lib/i18n/strings.g.dart`

build_runner 不可用，必须手动编辑。需要在三个位置添加：

- [ ] **Step 1: 在 _StringsEn 基类中添加 getter（约 line 821 之后）**

```dart
	String get seed_color_desc => 'Generates all default colors below';
	String get color_primary_desc => 'Audio highlight, buttons, switches';
	String get color_secondary_desc => 'Dictionary entries, bookshelf badges';
	String get color_tertiary_desc => 'Collections, reading statistics';
	String get color_container_desc => 'Switch tracks, play bar background';
	String get font_color_desc => 'Reader text color';
	String get background_color_desc => 'Reader page background';
	String get selection_color_desc => 'Reader text selection highlight';
	String get section_reader_colors => 'Reader Colors';
	String get section_advanced_colors => 'Advanced';
```

- [ ] **Step 2: 在 _StringsZhCn 类中添加 override（约 line 12368 之后）**

```dart
	@override String get seed_color_desc => '自动生成下方所有默认颜色';
	@override String get color_primary_desc => '音频高亮、按钮、开关';
	@override String get color_secondary_desc => '词典条目、书架标签';
	@override String get color_tertiary_desc => '收藏夹、阅读统计';
	@override String get color_container_desc => '开关轨道、播放栏';
	@override String get font_color_desc => '阅读器文字颜色';
	@override String get background_color_desc => '阅读器页面背景';
	@override String get selection_color_desc => '阅读器选中高亮';
	@override String get section_reader_colors => '阅读器颜色';
	@override String get section_advanced_colors => '高级选项';
```

- [ ] **Step 3: 在所有 17 个 locale 的 _flatMapFunction 中添加 case 分支**

每个 locale 的 flatMap switch 中，在 `'color_container'` case 之后添加 10 个新 case。EN 示例：

```dart
			case 'seed_color_desc': return 'Generates all default colors below';
			case 'color_primary_desc': return 'Audio highlight, buttons, switches';
			case 'color_secondary_desc': return 'Dictionary entries, bookshelf badges';
			case 'color_tertiary_desc': return 'Collections, reading statistics';
			case 'color_container_desc': return 'Switch tracks, play bar background';
			case 'font_color_desc': return 'Reader text color';
			case 'background_color_desc': return 'Reader page background';
			case 'selection_color_desc': return 'Reader text selection highlight';
			case 'section_reader_colors': return 'Reader Colors';
			case 'section_advanced_colors': return 'Advanced';
```

zh-CN flatMap 用对应中文值，zh-HK 也用繁体中文值。其余 14 个 locale 用英文值。

- [ ] **Step 4: 运行 flutter analyze 确认无错误**

Run: `cd hibiki/hibiki && flutter analyze`
Expected: No errors

---

### Task 3: 修复 ColorPicker 手势冲突

**Files:**
- Modify: `hibiki/hibiki/lib/src/pages/implementations/custom_theme_page.dart:302-318`

- [ ] **Step 1: 用 Listener 包裹 ColorPicker 阻止 ListView 抢夺垂直手势**

将 seed color 的 `LayoutBuilder(builder: ... ColorPicker ...)` 包裹在一个 Listener 中：

```dart
          Listener(
            onPointerDown: (_) {
              final scrollable = Scrollable.maybeOf(context);
              scrollable?.position.hold(() {});
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final pickerWidth = constraints.maxWidth
                    .clamp(0.0, MediaQuery.of(context).size.width - 64);
                final isLandscape =
                    MediaQuery.of(context).orientation == Orientation.landscape;
                return ColorPicker(
                  pickerColor: _seed,
                  onColorChanged: _setSeed,
                  colorPickerWidth: pickerWidth,
                  pickerAreaHeightPercent: isLandscape ? 0.4 : 0.6,
                  enableAlpha: false,
                  displayThumbColor: true,
                  hexInputBar: true,
                  labelTypes: const [],
                );
              },
            ),
          ),
```

- [ ] **Step 2: 对 _buildCompactColorPicker 也做同样处理**

在 `_buildCompactColorPicker` 方法中，同样用 Listener 包裹 ColorPicker：

```dart
  Widget _buildCompactColorPicker({
    required Color color,
    required ValueChanged<Color> onChanged,
    required bool enableAlpha,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pickerWidth = constraints.maxWidth
            .clamp(0.0, MediaQuery.of(context).size.width - 64);
        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;
        return Listener(
          onPointerDown: (_) {
            final scrollable = Scrollable.maybeOf(context);
            scrollable?.position.hold(() {});
          },
          child: ColorPicker(
            pickerColor: color,
            onColorChanged: onChanged,
            colorPickerWidth: pickerWidth,
            pickerAreaHeightPercent: isLandscape ? 0.35 : 0.5,
            enableAlpha: enableAlpha,
            displayThumbColor: true,
            hexInputBar: true,
            labelTypes: const [],
          ),
        );
      },
    );
  }
```

注意：Listener 必须在 LayoutBuilder 内部（需要 context 来获取 Scrollable），所以放在 LayoutBuilder 的 builder 返回值外层。

---

### Task 4: 重构 custom_theme_page.dart UI 布局

**Files:**
- Modify: `hibiki/hibiki/lib/src/pages/implementations/custom_theme_page.dart`

- [ ] **Step 1: 增强预览卡片**

重写 `_buildPreviewCard()` 方法。在现有色块行下方添加模拟用途演示：

```dart
  Widget _buildPreviewCard() {
    final cs = _preview;
    return Card(
      color: cs.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.preview,
                style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                _swatch(cs.primary, t.color_primary, cs.onSurface),
                const SizedBox(width: 8),
                _swatch(cs.secondary, t.color_secondary, cs.onSurface),
                const SizedBox(width: 8),
                _swatch(cs.tertiary, t.color_tertiary, cs.onSurface),
                const SizedBox(width: 8),
                _swatch(
                    cs.primaryContainer, t.color_container, cs.onSurface),
              ],
            ),
            const SizedBox(height: 12),
            // 模拟阅读器区域
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _useBgColor ? _bgColor : cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      style: TextStyle(
                          color: _useFontColor ? _fontColor : cs.onSurface,
                          fontSize: 15),
                      children: [
                        const TextSpan(text: '日本語の'),
                        TextSpan(
                          text: 'テキスト',
                          style: TextStyle(
                            backgroundColor:
                                _useSelectionColor ? _selectionColor : null,
                          ),
                        ),
                        const TextSpan(text: 'プレビュー'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 模拟音频高亮效果
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.34),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '音声ハイライト',
                      style: TextStyle(
                        color: _useFontColor ? _fontColor : cs.onSurface,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 模拟 Switch 组件
            Row(
              children: [
                Container(
                  width: 40,
                  height: 22,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.all(2),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Switch',
                  style: TextStyle(color: cs.onSurface, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
```

- [ ] **Step 2: 给种子色和主色添加描述文字**

在 build() 方法中，将种子色标题和主色部分改为带描述的形式：

种子色标题区（替换原来的 `Text(t.seed_color, ...)` 行）:
```dart
          Text(t.seed_color, style: Theme.of(context).textTheme.titleSmall),
          Text(t.seed_color_desc,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).hintColor)),
```

- [ ] **Step 3: 给 _buildOptionalColorPicker 添加 description 参数**

修改 `_buildOptionalColorPicker` 方法签名，添加可选 `description` 参数：

```dart
  Widget _buildOptionalColorPicker({
    required String label,
    String? description,
    required bool enabled,
    required ValueChanged<bool> onEnabledChanged,
    required Color color,
    required ValueChanged<Color> onChanged,
    required bool enableAlpha,
  }) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  if (description != null)
                    Text(description,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Theme.of(context).hintColor)),
                ],
              ),
            ),
            Switch(value: enabled, onChanged: onEnabledChanged),
          ],
        ),
        if (enabled) ...[
          const SizedBox(height: 8),
          _buildCompactColorPicker(
            color: color,
            onChanged: onChanged,
            enableAlpha: enableAlpha,
          ),
        ],
      ],
    );
  }
```

- [ ] **Step 4: 重组 build() 中的颜色列表布局**

将 build() 中 ListView.children 按以下顺序重组：

1. 预览卡片
2. 暗色模式开关
3. 种子色 + 描述 + ColorPicker
4. **阅读器颜色** section header：字体色、背景色、选中色（这三个是用户最常调的）
5. 主色（带描述：音频高亮...）
6. **高级选项** ExpansionTile：辅色、第三色、容器色

```dart
          // ── 阅读器颜色 ──
          const SizedBox(height: 16),
          Text(t.section_reader_colors,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _buildReaderColorRow(
            label: t.font_color,
            description: t.font_color_desc,
            enabled: _useFontColor,
            onEnabledChanged: (v) => setState(() => _useFontColor = v),
            color: _fontColor!,
            onChanged: (c) => setState(() => _fontColor = c),
            enableAlpha: true,
          ),
          const SizedBox(height: 12),
          _buildReaderColorRow(
            label: t.background_color,
            description: t.background_color_desc,
            enabled: _useBgColor,
            onEnabledChanged: (v) => setState(() => _useBgColor = v),
            color: _bgColor!,
            onChanged: (c) => setState(() => _bgColor = c),
            enableAlpha: false,
          ),
          const SizedBox(height: 12),
          _buildReaderColorRow(
            label: t.selection_color,
            description: t.selection_color_desc,
            enabled: _useSelectionColor,
            onEnabledChanged: (v) => setState(() => _useSelectionColor = v),
            color: _selectionColor!,
            onChanged: (c) => setState(() => _selectionColor = c),
            enableAlpha: true,
          ),
          // ── 主色（音频高亮）──
          const SizedBox(height: 16),
          _buildOptionalColorPicker(
            label: t.color_primary,
            description: t.color_primary_desc,
            enabled: _usePrimaryColor,
            onEnabledChanged: (bool value) {
              setState(() {
                _usePrimaryColor = value;
                if (value) {
                  _primaryColor ??= _generatedScheme.primary;
                } else {
                  _primaryColor = _generatedScheme.primary;
                }
              });
            },
            color: _primaryColor!,
            onChanged: (Color color) => setState(() => _primaryColor = color),
            enableAlpha: false,
          ),
          // ── 高级选项（折叠）──
          const SizedBox(height: 8),
          ExpansionTile(
            title: Text(t.section_advanced_colors),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: [
              _buildOptionalColorPicker(
                label: t.color_secondary,
                description: t.color_secondary_desc,
                ...existing params...
              ),
              const SizedBox(height: 12),
              _buildOptionalColorPicker(
                label: t.color_tertiary,
                description: t.color_tertiary_desc,
                ...existing params...
              ),
              const SizedBox(height: 12),
              _buildOptionalColorPicker(
                label: t.color_container,
                description: t.color_container_desc,
                ...existing params...
              ),
            ],
          ),
          // ── 应用按钮 ──
          const SizedBox(height: 16),
          FilledButton.icon(...),
```

`_buildReaderColorRow` 复用 `_buildOptionalColorPicker` 的签名（同一个方法，只是调用时传入 description）。

- [ ] **Step 5: 运行 flutter analyze**

Run: `cd hibiki/hibiki && flutter analyze`
Expected: No errors

---

### Task 5: 编译验证 + Commit

**Files:** all modified files

- [ ] **Step 1: 编译 release APK**

Run: `cd hibiki/hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64`
Expected: BUILD SUCCESSFUL

- [ ] **Step 2: Commit**

```bash
git add hibiki/hibiki/lib/src/pages/implementations/custom_theme_page.dart hibiki/hibiki/lib/i18n/strings.i18n.json hibiki/hibiki/lib/i18n/strings_zh-CN.i18n.json hibiki/hibiki/lib/i18n/strings.g.dart
git commit -m "feat(theme): fix color picker gesture, add descriptions, improve preview

- Fix ColorPicker vertical drag conflict with ListView scroll
- Add usage descriptions for each theme color
- Enhance preview card with audio highlight and switch demos
- Group secondary/tertiary/container under Advanced section
- Reorder: seed → reader colors → primary → advanced"
```

---

### Task 6: Code Review

调用 `superpowers:requesting-code-review` 启动 code-reviewer agent 审查。
