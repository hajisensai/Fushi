import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

import '../ratchet.dart';

/// 一种受管的框架控件：该改用什么，以及哪些「组件实现层」可以构造它。
final class DesignControl {
  const DesignControl(this.why, this.implementationLayer);

  /// 进违规消息：该用哪个设计系统入口、为什么。
  final String why;

  /// 仓库相对路径前缀：设计系统包装本身在这里构造原控件是本职，不计数。
  final List<String> implementationLayer;
}

/// `fushi/lib` 下禁止直接构造会绕过设计系统分派的原生 Material / Cupertino 控件。
///
/// 按构造调用解析出的**类**判定（不看名字字面量），所以 `FushiSegmentedButton`、
/// `SegmentedButton.styleFrom`、`extends SegmentedButton<T>`、注释和字符串都不算；
/// 被别名导入、加前缀也逃不掉。
///
/// 两种放行：
/// - [DesignControl.implementationLayer]：包装 / 设计系统实现文件，不限次数；
/// - [exemptions]：尚未迁移的存量，精确到文件、控件与个数，只减不增。
class NoRawDesignControls extends RatchetedRule {
  NoRawDesignControls()
    : super(name: ruleName, description: '页面层裸 Material / Cupertino 控件');

  static const String ruleName = 'fushi_no_raw_design_controls';

  static const LintCode code = LintCode(
    ruleName,
    "Don't build a raw {0} here: {1}",
    correctionMessage:
        'Use the design-system component; only the component implementation '
        'may build the framework control (see '
        'packages/fushi_lints/lib/src/rules/no_raw_design_controls.dart).',
    severity: DiagnosticSeverity.WARNING,
  );

  static const LintCode stale = LintCode(
    '${ruleName}_stale_allowance',
    'fushi_lints allows {1} raw {0} construction(s) in this file but found {2}.',
    correctionMessage:
        'Lower or delete the Allowance in '
        'packages/fushi_lints/lib/src/rules/no_raw_design_controls.dart.',
    severity: DiagnosticSeverity.WARNING,
  );

  /// 交互控件的包装实现层（2026-10 统一 M3E：MD3 下包装才是 M3 Expressive——
  /// 按压形变 / 尺寸档 / 波浪进度 / 开关图标，Apple 下包装才映射到 iOS 原生形态）。
  static const List<String> _interactiveLayer = <String>[
    'fushi/lib/src/utils/components/glass/',
    // FushiSelectableChip / FushiActionChip / FushiPreviewSwitch 等包装本体。
    'fushi/lib/src/utils/components/fushi_material_components.dart',
    // adaptive* 系列（含隐藏的 Cupertino 渲染器分支）。
    'fushi/lib/src/utils/adaptive/adaptive_widgets.dart',
    // 下载进度环包装（墨水屏分支的静止原环）。
    'fushi/lib/src/utils/components/fushi_download_progress.dart',
    // 视频 M3E chrome：FushiPressMorph 的 builder 里构造原按钮。
    'fushi/lib/src/media/video/video_m3e_chrome.dart',
    // FushiRefreshIndicator 包装本体：MD3 RefreshIndicator / Apple 下拉菊花。
    'fushi/lib/src/utils/components/fushi_m3e_feedback.dart',
    // FushiIconButton 包装本体：MD3 路径就是官方 M3E IconButton。
    'fushi/lib/src/utils/components/fushi_icon_button.dart',
  ];

  static const DesignControl _interactive = DesignControl(
    'use the Fushi* wrapper (FushiFilledButton / FushiSwitch / FushiSlider / '
    'FushiFab / FushiCircularProgressIndicator ..., see '
    'lib/src/utils/components/glass/fushi_glass_controls.dart).',
    _interactiveLayer,
  );

  // 分段选择一律走设计系统（用户 2026-10-16）：原生 SegmentedButton 在 Material
  // 下画旧版 MD3 描边分段，Apple 下拿不到 iOS 分段控件。BUG-4205：段宽只走
  // fushiSegmentWidths / FushiSegmentRow 一处，原生 Cupertino 分段等宽、最长段先
  // 被截断。M3E 胶囊分段 FushiPillSegmentedButton 只是继承 SegmentedButton，
  // 不构造它，所以分段控件没有实现层。
  static const DesignControl _segmented = DesignControl(
    'use adaptiveSegmentedButton(...) / AdaptiveSettingsSegmentedRow '
    '(M3E capsule / iOS segmented) or FushiSegmentedButton (multi-select, '
    'vertical, empty selection); segment widths come from fushiSegmentWidths '
    '(BUG-4205).',
    <String>[],
  );

  /// 受管的框架控件（按类名；类必须来自 [_isFrameworkLibrary]）。
  static const Map<String, DesignControl> controls = <String, DesignControl>{
    'ElevatedButton': _interactive,
    'FilledButton': _interactive,
    'OutlinedButton': _interactive,
    'TextButton': _interactive,
    'IconButton': _interactive,
    'FloatingActionButton': _interactive,
    'Switch': _interactive,
    'SwitchListTile': _interactive,
    'Checkbox': _interactive,
    'CheckboxListTile': _interactive,
    'Radio': _interactive,
    'RadioListTile': _interactive,
    'Slider': _interactive,
    'RangeSlider': _interactive,
    'FilterChip': _interactive,
    'ChoiceChip': _interactive,
    'ActionChip': _interactive,
    'InputChip': _interactive,
    'Chip': _interactive,
    'ToggleButtons': _interactive,
    'LinearProgressIndicator': _interactive,
    'CircularProgressIndicator': _interactive,
    'CupertinoSwitch': _interactive,
    'CupertinoSlider': _interactive,
    'CupertinoButton': _interactive,
    'CupertinoActivityIndicator': _interactive,
    'SegmentedButton': _segmented,
    'CupertinoSlidingSegmentedControl': _segmented,
    'CupertinoSegmentedControl': _segmented,
    // BUG-4205：框架 TabBar 的非滚动铺满档把每个页签包一层 Expanded 等分，最长
    // 页签先显示不全；FushiTabBar 的 MD3 分支是唯一已知存量（见豁免表）。
    'TabBar': DesignControl(
      'use FushiTabBar; the framework TabBar fill splits tabs equally '
      '(BUG-4205).',
      <String>[],
    ),
    // 列表与卡片统一为 M3E（2026-10-05）：裸控件绕过形状分级、分段列表形变、
    // Apple inset grouped 行、焦点契约与墨水屏描边。
    'ListTile': DesignControl(
      'use FushiListItem / FushiListTileControl (same parameters) or '
      'FushiGroupedList / FushiGroupedListItem / SliverFushiGroupedList.',
      <String>[],
    ),
    'Card': DesignControl(
      'use FushiCard (variant / tone) or FushiCardControl (same parameters).',
      <String>[],
    ),
  };

  /// 定义这些控件的库：拆包后的 `material_ui` / `cupertino_ui`，以及 SDK 内的
  /// 旧 `package:flutter/`（旧 import 本身另有 fushi_no_legacy_design_import 管）。
  static bool _isFrameworkLibrary(Uri uri) =>
      uri.isScheme('package') &&
      (uri.path.startsWith('material_ui/') ||
          uri.path.startsWith('cupertino_ui/') ||
          uri.path.startsWith('flutter/'));

  /// 2026-10 统一 M3E 时盘点出的待迁移存量（多为并行改动中的文件或隐藏的
  /// Cupertino 渲染器分支）。2026-11-28 迁入 lint 时按真实构造重新计数：旧文本
  /// 守卫把 books.part.dart 与 reader_quick_settings_sheet.dart 的注释 / 非构造
  /// 引用也算了进去，这里只剩真实构造。
  static const String _pending = '待迁移存量（2026-10 统一 M3E 盘点），改用 Fushi* 包装';

  // ALLOWANCES-BEGIN
  static const List<Allowance> exemptions = <Allowance>[
    Allowance(
      'fushi/lib/src/utils/components/glass/fushi_glass_bars.dart',
      'TabBar',
      4,
      'FushiTabBar 的 MD3 分支用框架 TabBar（含分段胶囊 _FushiM3eSegmentedTabs），'
          '改自绘待拍板（BUG-4205）',
    ),
    Allowance(
      'fushi/lib/src/utils/components/glass/fushi_glass_lists.dart',
      'ListTile',
      1,
      'FushiListTileControl 的 MD3 分支构造原 ListTile',
    ),
    Allowance(
      'fushi/lib/src/utils/components/glass/fushi_glass_lists.dart',
      'Card',
      3,
      'FushiCardControl 的 MD3 分支构造原 Card / Card.filled / Card.outlined',
    ),
    Allowance(
      'fushi/lib/src/media/audiobook/audiobook_play_bar.dart',
      'LinearProgressIndicator',
      1,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/media/audiobook/reader_quick_settings_sheet.dart',
      'CupertinoButton',
      1,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/profile_management_page.dart',
      'CupertinoButton',
      1,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart',
      'IconButton',
      1,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/profile/profile_selector.dart',
      'CupertinoButton',
      1,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/reader/reader_panel_chrome_kit.dart',
      'LinearProgressIndicator',
      1,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/reader/reader_panel_kit.dart',
      'FilledButton',
      1,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/settings/master_detail_settings_sheet.dart',
      'CupertinoButton',
      1,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/sync/sync_settings_schema/account.part.dart',
      'CupertinoButton',
      2,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/utils/components/fushi_m3e_overlays.dart',
      'Checkbox',
      1,
      _pending,
    ),
    Allowance(
      'fushi/lib/src/utils/components/settings_shared.dart',
      'CupertinoButton',
      1,
      _pending,
    ),
  ];
  // ALLOWANCES-END

  @override
  LintCode get violationCode => code;

  @override
  LintCode get staleCode => stale;

  @override
  List<Allowance> get allowances => exemptions;

  @override
  bool appliesTo(String repoPath) => repoPath.startsWith('fushi/lib/');

  @override
  List<RuleSite> collect(CompilationUnit unit, RuleContext context) {
    final String path = repoRelativePath(context)!;
    final _Collector collector = _Collector(path);
    unit.accept(collector);
    return collector.sites;
  }
}

class _Collector extends RecursiveAstVisitor<void> {
  _Collector(this.path);

  final String path;
  final List<RuleSite> sites = <RuleSite>[];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final Element? type = node.constructorName.type.element;
    if (type is InterfaceElement) {
      final String? name = type.name;
      final DesignControl? control = NoRawDesignControls.controls[name];
      if (control != null &&
          NoRawDesignControls._isFrameworkLibrary(type.library.uri) &&
          !control.implementationLayer.any(path.startsWith)) {
        sites.add(RuleSite(node.constructorName, name!, control.why));
      }
    }
    super.visitInstanceCreationExpression(node);
  }
}
