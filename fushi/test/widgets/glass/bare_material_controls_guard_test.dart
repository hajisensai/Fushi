import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 守卫：lib/ 下新代码禁止直接构造 Material / Cupertino 交互控件（按钮 / 开关 /
// 复选 / 单选 / 滑块 / chip / 分段 / 进度 / FAB），一律走设计系统包装
// （FushiFilledButton / FushiSwitch / FushiSlider / FushiFab /
// FushiCircularProgressIndicator …，见 lib/src/utils/components/glass/）。
//
// 为什么：MD3 下包装才是 M3 Expressive（按压形变 / 尺寸档 / 波浪进度 /
// 开关图标），Apple 设计系统下包装才映射到 iOS 原生形态。裸控件在两套设计
// 系统里都会「漏网」——2026-10 统一 M3E 时盘点出 50 处。
//
// 白名单是**渐进**的：
// - [_implementationDirs] / [_implementationFiles]：包装本身与只在其内部构造
//   原控件的实现文件（不限次数）；
// - [_pendingFiles]：尚未迁移的存量（多为并行改动中的文件，合并后统一扫尾），
//   记的是**当前次数上限**——只许减不许增，迁完一处就把数字调小，归零删行。
void main() {
  test('lib/ 不新增裸 Material / Cupertino 交互控件', () {
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: '在 fushi/ 下运行');
    final RegExp bare = RegExp(
      r'(?<![A-Za-z0-9_.])'
      r'(ElevatedButton|FilledButton|OutlinedButton|TextButton|IconButton|'
      r'FloatingActionButton|Switch|SwitchListTile|Checkbox|CheckboxListTile|'
      r'Radio|RadioListTile|Slider|RangeSlider|FilterChip|ChoiceChip|'
      r'ActionChip|InputChip|Chip|SegmentedButton|ToggleButtons|'
      r'LinearProgressIndicator|CircularProgressIndicator|CupertinoSwitch|'
      r'CupertinoSlider|CupertinoButton|CupertinoActivityIndicator|'
      r'CupertinoSlidingSegmentedControl|CupertinoSegmentedControl)'
      r'(\.[a-z][A-Za-z]*)?(<[^>()]*>)?\(',
    );
    final Map<String, int> offenders = <String, int>{};
    for (final FileSystemEntity e in lib.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String path = e.path.replaceAll(r'\', '/');
      if (path.endsWith('.g.dart')) continue;
      if (_implementationDirs.any(path.contains)) continue;
      if (_implementationFiles.any(path.endsWith)) continue;
      int count = 0;
      for (final String line in e.readAsLinesSync()) {
        final String code = line.split('//').first;
        // `X.styleFrom(` / `X.adaptive` 的静态成员引用不是构造控件。
        for (final RegExpMatch m in bare.allMatches(code)) {
          if (m.group(2) == '.styleFrom') continue;
          count++;
        }
      }
      if (count == 0) continue;
      final String? pending = _pendingFiles.keys
          .where(path.endsWith)
          .firstOrNull;
      final int allowed = pending == null ? 0 : _pendingFiles[pending]!;
      if (count > allowed) offenders[path] = count;
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '这些文件新增了裸控件（值 = 当前处数）：请改用 Fushi* 包装（见 '
          'lib/src/utils/components/glass/fushi_glass_controls.dart）。'
          '确属包装实现的才加进 _implementationFiles。',
    );
  });

  test('待迁移白名单不留死行（迁完的文件要从清单删掉）', () {
    final List<String> stale = <String>[
      for (final String f in _pendingFiles.keys)
        if (!File('lib/$f').existsSync()) f,
    ];
    expect(stale, isEmpty);
  });
}

/// 包装 / 设计系统实现目录：在这里构造原控件是本职。
const List<String> _implementationDirs = <String>[
  'lib/src/utils/components/glass/',
];

/// 只在内部构造原控件的实现文件（包装、Cupertino 渲染器分支的适配层）。
const List<String> _implementationFiles = <String>[
  // FushiSelectableChip / FushiActionChip / FushiPreviewSwitch 等包装本体。
  'src/utils/components/fushi_material_components.dart',
  // adaptive* 系列（含隐藏的 Cupertino 渲染器分支）。
  'src/utils/adaptive/adaptive_widgets.dart',
  // 下载进度环包装（墨水屏分支的静止原环）。
  'src/utils/components/fushi_download_progress.dart',
  // 视频 M3E chrome：FushiPressMorph 的 builder 里构造原按钮。
  'src/media/video/video_m3e_chrome.dart',
];

/// 待迁移存量（相对 lib/ 的路径 → 当前处数上限）。多为 2026-10 并行改动中的
/// 文件或隐藏 Cupertino 渲染器分支，合并后统一扫尾。只许减不许增。
const Map<String, int> _pendingFiles = <String, int>{
  'src/media/audiobook/audiobook_play_bar.dart': 1,
  'src/media/audiobook/reader_quick_settings_sheet.dart': 3,
  'src/pages/implementations/home_page.dart': 1,
  'src/pages/implementations/profile_management_page.dart': 1,
  'src/pages/implementations/reader_fushi/chrome.part.dart': 1,
  'src/pages/implementations/reader_history/books.part.dart': 1,
  'src/profile/profile_selector.dart': 1,
  'src/reader/reader_panel_chrome_kit.dart': 1,
  'src/reader/reader_panel_kit.dart': 1,
  'src/settings/master_detail_settings_sheet.dart': 1,
  'src/settings/settings_kit.dart': 1,
  'src/sync/sync_settings_schema/account.part.dart': 2,
  'src/utils/components/fushi_m3e_overlays.dart': 1,
  'src/utils/components/settings_shared.dart': 1,
};
