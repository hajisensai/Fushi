import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_history_source_corpus.dart';

/// 合并守卫：MD3 对话框壳（HibikiDialogFrame / HibikiModalSheetFrame / 设计令牌）
/// 一致性静态守卫。原来每个对话框各占一个 *_md3_static_test.dart 文件，断言同形但
/// 各自钉死本文件差异化的 inline-state spacing / insetPadding / EdgeInsets 切片标记。
///
/// 【B 类要求型锚点整改，2026-08-01】本文件原来 43 条断言全部是
/// `expect(rawSource, contains('实现写法字面量'))`，四类塌陷同时存在：
///
/// 1. **零词法防护**：读的是原始源码。把 `HibikiDialogFrame(` 写进任意一条注释，
///    整组要求型断言当场变绿——要求型锚点最典型的假绿。现在一律先过
///    [maskCommentsAndStrings]（本文件锚点全是代码标识符，没有一条需要读串内容）。
/// 2. **锚点即写法**：`'HibikiDialogFrame('` 漏命名构造器形态、又被
///    `XxxHibikiDialogFrame(` 假命中；`'HibikiDesignTokens.of(context)'` 把**局部
///    变量名** `context` 写进了契约；`'return IconButton(' / 'child: IconButton(' /
///    'trailing: IconButton(' / 'suffixIcon: IconButton('` 四条前缀只是为了绕开
///    `HibikiIconButton(` 含子串 `IconButton(`，换个调用位置就整条漏。全部换成带
///    标识符边界的 [containsIdentifierCall]，四条前缀合并成一条「不得裸用
///    IconButton（含 `IconButton.filledTonal(`）」。
/// 3. **间距契约钉死拼写**：`contains('insetPadding: EdgeInsets.symmetric(')` +
///    `contains('horizontal: tokens.spacing.card')` + `contains('vertical: …')`
///    三条各自扫全文件（可以命中三个互不相干的位置），配一串
///    `isNot(contains('const EdgeInsets.symmetric(horizontal: 16, vertical: 16)'))`
///    ——后者只堵一种拼写，16 改成 20 就静默放行。换成 [namedArgumentValues] 取出
///    每个 `insetPadding:` / `padding:` / `margin:` 的**实参表达式**，断言它取自
///    `tokens.spacing.` 且没有裸数字实参：与换行、参数顺序、哪个 EdgeInsets 构造器
///    全部无关，且覆盖所有硬编码拼写而不是枚举出来的那几种。
/// 4. **窗口靠相邻声明**：`substring(0, indexOf('Widget _buildFetchTile'))` 把
///    **返回类型**写进了锚点（改成 `Future<Widget>` 就 `indexOf` 返回 -1 →
///    `substring(0, -1)` 抛 RangeError）；`_between(…, '下一个类名')` 只要下一个类
///    改名或中间插一个类就整体漂移。换成 [methodBody] 按花括号配对取**类体**，
///    并把「谁负责什么」拆成各自作用域的断言。
void main() {
  group('anki_handlebar_picker_dialog_md3_static', () {
    test('anki settings page uses MD3 spacing tokens for inline states', () {
      final String code = _readCode(
        'lib/src/pages/implementations/anki_settings_page.dart',
      );
      // 契约是「设置页正文（含 inline state 行）的间距走令牌」，作用域就是页面
      // 的 State 类，而不是「文件开头到某个 helper 首现处」这段偶然切片。
      final String pageCode = methodBody(code, 'class _AnkiSettingsBodyState');

      expect(
        containsIdentifierCall(pageCode, 'HibikiDesignTokens'),
        isTrue,
        reason: 'Anki 设置页正文的尺寸必须取自设计令牌',
      );
      _expectTokenDerivedSpacing(pageCode, 'Anki 设置页正文');
    });

    test(
        'anki handlebar picker dialog uses shared MD3 dialog chrome and tokens',
        () {
      final String code = _readCode(
        'lib/src/pages/implementations/anki_settings_page.dart',
      );
      // 壳与 insetPadding 都在 State 类的 build 里；StatefulWidget 外壳类本身
      // 不含任何 chrome，锚到它会扫到空窗口。
      final String dialogCode =
          methodBody(code, 'class _AnkiHandlebarPickerDialogState');

      _expectMd3DialogChrome(dialogCode, 'Anki handlebar 选择对话框');
      _expectTokenDerivedInsetPadding(dialogCode, 'Anki handlebar 选择对话框');
      _expectTokenDerivedSpacing(dialogCode, 'Anki handlebar 选择对话框');
    });
  });

  group('audio_recorder_dialog_md3_static', () {
    test('audio recorder dialog uses shared MD3 dialog chrome and tokens', () {
      final String code = _readCode(
        'lib/src/pages/implementations/audio_recorder_page.dart',
      );

      _expectMd3DialogChrome(code, '录音对话框');
      _expectNoLegacySpacingFacade(code, '录音对话框');
      _expectTokenDerivedInsetPadding(code, '录音对话框');
      _expectTokenDerivedSpacing(code, '录音对话框');
    });

    test('audio recorder player controls use shared MD3 icon buttons', () {
      final String code = _readCode(
        'lib/src/pages/implementations/audio_recorder_page.dart',
      );

      _expectSharedIconButtons(code, '录音对话框');
    });
  });

  group('book_profile_dialog_md3_static', () {
    test('book profile dialog owns shared MD3 dialog and sheet chrome', () {
      final String code = maskCommentsAndStrings(readReaderHistorySource());
      // 旧写法把「State 类 + Frame 类」拼成一段偶然区间（起点是 StatefulWidget、
      // 终点是**下一个**类名），谁改名都会漂。改成各自作用域各断言其职责。
      final String stateCode =
          methodBody(code, 'class _BookProfileDialogState');
      final String frameCode = methodBody(code, 'class BookProfileDialogFrame');

      expect(
        containsIdentifierCall(stateCode, 'BookProfileDialogFrame'),
        isTrue,
        reason: '书籍 Profile 对话框必须经由共享 Frame 出壳',
      );
      expect(
        containsIdentifierCall(stateCode, 'adaptiveAlertDialog'),
        isFalse,
        reason: '书籍 Profile 对话框不得回到旧 adaptiveAlertDialog 工厂',
      );
      _expectMd3DialogChrome(
        frameCode,
        'BookProfileDialogFrame',
        requireTokens: false,
      );
    });
  });

  group('crop_image_dialog_md3_static', () {
    test('crop image dialog uses shared MD3 dialog chrome and token spacing',
        () {
      final String code = _readCode(
        'lib/src/pages/implementations/crop_image_dialog_page.dart',
      );

      _expectMd3DialogChrome(code, '裁剪图片对话框');
      _expectNoLegacySpacingFacade(code, '裁剪图片对话框');
    });
  });

  group('dictionary_settings_dialog_md3_static', () {
    test('dictionary settings dialogs use shared MD3 dialog chrome and tokens',
        () {
      final String code = _readCode(
        'lib/src/pages/implementations/dictionary_settings_dialog_page.dart',
      );

      _expectMd3DialogChrome(code, '词典设置对话框');
      _expectTokenDerivedInsetPadding(code, '词典设置对话框');
      _expectTokenDerivedSpacing(code, '词典设置对话框');
    });

    test('audio source controls use shared MD3 icon buttons', () {
      final String code = _readCode(
        'lib/src/pages/implementations/dictionary_settings_dialog_page.dart',
      );

      _expectSharedIconButtons(code, '词典设置对话框');
      expect(
        code.contains('VisualDensity.compact'),
        isFalse,
        reason: '词典设置对话框的行密度由共享组件决定，不得逐处压缩',
      );
    });
  });

  group('media_source_picker_dialog_md3_static', () {
    test('media source picker uses shared MD3 dialog shell', () {
      final String code = _readCode(
        'lib/src/pages/implementations/media_source_picker_dialog_page.dart',
      );

      _expectMd3DialogChrome(code, '媒体来源选择对话框', requireTokens: false);
      expect(
        containsIdentifierCall(code, 'HibikiListItem'),
        isTrue,
        reason: '媒体来源选择对话框的行必须用共享 HibikiListItem',
      );
      _expectNoLegacySpacingFacade(code, '媒体来源选择对话框');
    });
  });

  group('example_sentences_dialog_md3_static', () {
    test('example sentences dialog uses shared MD3 dialog and card chrome', () {
      final String code = _readCode(
        'lib/src/pages/implementations/example_sentences_dialog_page.dart',
      );

      _expectMd3DialogChrome(code, '例句对话框');
      expect(
        containsIdentifierCall(code, 'HibikiCard'),
        isTrue,
        reason: '例句卡片必须用共享 HibikiCard',
      );
      _expectNoLegacySpacingFacade(code, '例句对话框');
      // 裸 Container / GestureDetector 是「自己糊一套卡片与点击态」的形态；
      // 带标识符边界后不再顺带禁掉 AnimatedContainer 这类不相干的更长名字。
      expect(
        containsIdentifierCall(code, 'Container'),
        isFalse,
        reason: '例句对话框不得用裸 Container 自造卡片外观',
      );
      expect(
        containsIdentifierCall(code, 'GestureDetector'),
        isFalse,
        reason: '例句对话框的点击态必须走共享组件的水波纹',
      );
    });
  });

  group('profile_management_dialog_md3_static', () {
    test('profile management dialogs use shared MD3 dialog chrome and tokens',
        () {
      final String code = _readCode(
        'lib/src/pages/implementations/profile_management_page.dart',
      );

      _expectMd3DialogChrome(code, 'Profile 管理对话框');
      _expectTokenDerivedInsetPadding(code, 'Profile 管理对话框');
      _expectTokenDerivedSpacing(code, 'Profile 管理对话框');
    });

    test('profile action buttons use shared MD3 icon buttons', () {
      final String code = _readCode(
        'lib/src/pages/implementations/profile_management_page.dart',
      );
      // 旧窗口终点是 `indexOf('@visibleForTesting', …)`——一个与本类无关的注解，
      // 谁在后面加/删一个 @visibleForTesting 就整体改形。
      final String actionCode = methodBody(code, 'class _ProfileActionButton');

      _expectSharedIconButtons(actionCode, 'Profile 操作按钮');
      expect(
        actionCode.contains('VisualDensity.compact'),
        isFalse,
        reason: 'Profile 操作按钮的密度由共享 HibikiIconButton 决定',
      );
    });
  });

  group('tag_management_dialog_md3_static', () {
    test('tag management dialogs use shared MD3 dialog chrome and tokens', () {
      final String code = _readCode(
        'lib/src/pages/implementations/tag_management_page.dart',
      );

      _expectMd3DialogChrome(code, '标签管理对话框');
      _expectTokenDerivedInsetPadding(code, '标签管理对话框');
      _expectTokenDerivedSpacing(code, '标签管理对话框');
    });
  });

  group('text_segmentation_dialog_md3_static', () {
    test('text segmentation dialog uses shared MD3 dialog and chip chrome', () {
      final String code = _readCode(
        'lib/src/pages/implementations/text_segmentation_dialog_page.dart',
      );

      _expectMd3DialogChrome(code, '分词对话框', requireTokens: false);
      expect(
        containsIdentifierCall(code, 'HibikiSelectableChip'),
        isTrue,
        reason: '分词对话框的词块必须用共享 HibikiSelectableChip',
      );
      _expectNoLegacySpacingFacade(code, '分词对话框');
      expect(
        containsIdentifierCall(code, 'Container'),
        isFalse,
        reason: '分词对话框不得用裸 Container 自造词块外观',
      );
    });
  });

  group('websocket_dialog_md3_static', () {
    test('websocket dialog uses shared MD3 dialog chrome', () {
      final String code = _readCode(
        'lib/src/pages/implementations/websocket_dialog_page.dart',
      );

      _expectMd3DialogChrome(code, 'WebSocket 对话框');
      _expectNoLegacySpacingFacade(code, 'WebSocket 对话框');
    });
  });
}

/// 读源码并把**注释和字符串内容**一起掩成等长空白。
///
/// 本文件的锚点全是代码标识符，没有一条需要读字符串内容，所以掩得越干净越好：
/// 注释里的 `HibikiDialogFrame(`、串里的 `'adaptiveAlertDialog('` 都不该算数。
String _readCode(String path) =>
    maskCommentsAndStrings(File(path).readAsStringSync());

/// 「整个实参槽位就是一个数字字面量」的形态：`EdgeInsets.all(16)` /
/// `symmetric(horizontal: 16, vertical: 16)` / `fromLTRB(12, 0, 12, 12)`。
final RegExp _numericArgument = RegExp(r'[(,:]\s*(-?\d+(?:\.\d+)?)\s*[,)]');

/// [expr] 里是否有**硬编码的非零间距**。
///
/// 两个有意的放行：
/// - `0`：零不是「魔法尺寸」，是「此边不留白」，写 `tokens.spacing.none` 没有意义；
/// - `tokens.spacing.card * 2`：以令牌为基准的算式仍然是令牌派生的，只有裸数字
///   占满一整个实参槽位才算硬编码。
///
/// 契约是「间距来自设计令牌」，不是「表达式里不许出现数字」——后者会在下一次
/// 合法重构时变成假红。
bool _hasHardcodedSpacing(String expr) {
  for (final RegExpMatch match in _numericArgument.allMatches(expr)) {
    final double? value = double.tryParse(match.group(1)!);
    if (value != null && value != 0) return true;
  }
  return false;
}

/// 该作用域内所有 `EdgeInsets` 构造都不得带裸数字实参。
///
/// 这一条顶掉旧守卫里逐条枚举的禁止型字面量
/// （`const EdgeInsets.symmetric(horizontal: 16, vertical: 16)` /
/// `fromLTRB(12, 0, 12, 12)` / `all(16)` …）：那些只堵住**被枚举到的那几种拼写**，
/// 把 16 改成 20、或换一个构造器就静默放行。改成对每个 `EdgeInsets` 调用做结构判据，
/// 覆盖全部硬编码写法，且不因换行/参数顺序变假。
void _expectTokenDerivedSpacing(String code, String label) {
  for (final RegExpMatch match
      in identifierCall('EdgeInsets').allMatches(code)) {
    final EnclosingCall call = enclosingCall(code, match.end);
    expect(
      _hasHardcodedSpacing(call.text),
      isFalse,
      reason: '$label 的间距不得硬编码（一律走 tokens.spacing），实际是：${call.text}',
    );
  }
}

void _expectMd3DialogChrome(
  String code,
  String label, {
  bool requireTokens = true,
}) {
  expect(
    containsIdentifierCall(code, 'HibikiDialogFrame'),
    isTrue,
    reason: '$label 必须用共享 MD3 对话框壳',
  );
  expect(
    containsIdentifierCall(code, 'HibikiModalSheetFrame'),
    isTrue,
    reason: '$label 必须用共享 MD3 底部弹层壳',
  );
  expect(
    containsIdentifierCall(code, 'adaptiveAlertDialog'),
    isFalse,
    reason: '$label 不得回到旧 adaptiveAlertDialog 工厂',
  );
  if (requireTokens) {
    expect(
      containsIdentifierCall(code, 'HibikiDesignTokens'),
      isTrue,
      reason: '$label 的尺寸必须取自设计令牌（`.of(context)` 的变量名不入契约）',
    );
  }
}

/// 对话框的 `insetPadding` 必须取自设计令牌。
///
/// 断言的是**实参表达式本身**，不是它在文件里的拼写：既覆盖所有硬编码写法
/// （不止旧守卫枚举的那两三种），也不会因为换行、参数顺序或换个 EdgeInsets
/// 构造器而变假。
void _expectTokenDerivedInsetPadding(String code, String label) {
  final List<String> values = namedArgumentValues(code, 'insetPadding');
  expect(
    values,
    isNotEmpty,
    reason: '$label 的对话框必须显式给出 insetPadding',
  );
  for (final String value in values) {
    expect(
      value.contains('tokens.spacing.'),
      isTrue,
      reason: '$label 的 insetPadding 必须取自 tokens.spacing，实际是：$value',
    );
  }
}

/// 旧的 `Spacing.of(context)` 间距门面已被设计令牌取代，不得复活。
void _expectNoLegacySpacingFacade(String code, String label) {
  expect(
    containsIdentifierCall(code, 'Spacing'),
    isFalse,
    reason: '$label 不得回到旧 Spacing 门面，间距统一走 HibikiDesignTokens',
  );
}

/// 图标按钮必须走共享 [HibikiIconButton]。
///
/// 旧守卫写成 `isNot(contains('return IconButton('))` 等四条**调用位置前缀**，
/// 唯一目的是绕开「`HibikiIconButton(` 含子串 `IconButton(`」；代价是换个调用位置
/// （`actions: <Widget>[IconButton(...)]`）就整条漏，也匹配不到
/// `IconButton.filledTonal(`。带标识符边界后一条顶四条，且严格更强。
void _expectSharedIconButtons(String code, String label) {
  expect(
    containsIdentifierCall(code, 'HibikiIconButton'),
    isTrue,
    reason: '$label 必须用共享 HibikiIconButton',
  );
  expect(
    containsIdentifierCall(code, 'IconButton'),
    isFalse,
    reason: '$label 不得裸用 IconButton（含 IconButton.filledTonal 等命名构造器）',
  );
}
