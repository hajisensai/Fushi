import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1237：Android 弹窗自定义 ContextMenu 会先 finish 系统 ActionMode，系统默认
/// 「复制」因此是个死项。修法是**隐藏默认项 + 由 Dart 自己写系统剪贴板**。
///
/// ## 为什么判据不能再是「某段文本里有没有 `Clipboard.setData(...)`」
///
/// 旧判据是 `_between(src, 'contextMenu: ContextMenu(', 'gestureRecognizers:')`
/// 切出一个**文本窗口**，再在窗口里找那一串字面量。它守的不是不变式，是「那一行
/// 写在哪、长什么样」：
/// - PR#764（BUG-1451）把三条复制入口（Windows 右键 / Windows Ctrl+C / Android 原生
///   菜单）收口进同一个共享方法，Android 分支不再自己裸调 [_kClipboardWrite]
///   ——**不变式被保留而且加强了**（三处内联 → 单一入口 + 统一反馈），字面串却搬出了
///   那个文本窗口，守卫当场转红；
/// - 右边界 `'gestureRecognizers:'` 更脆：它假设那个命名参数写在 `contextMenu:`
///   **之后**，参数顺序一换窗口就整个塌掉（原实现直接抛 StateError）。
///
/// 本仓这已经是第四次「字面量 / 文本窗口锚点被一次有意重构打断」（PR#762 的
/// BUG-1100 降级文案、PR#758 的 `SetTimer(` token 禁令、9fd30d281 的 `_gif(` 锚点）。
///
/// ## 新判据：可达性
///
/// 窗口由**结构**给出（`ContextMenu(` 这一次调用的括号配对），断言问的是真正要守的
/// 那句话：**Android 那一项「复制」的 action，最终有没有走到 Dart 的
/// [_kClipboardWrite]？** 直接调算数；调本文件内某个自己写剪贴板的方法（一跳）也算
/// ——PR#764 的 `_copySelectionToClipboard` 正是这种。
///
/// BUG-1237 的原始形态（不提供 Dart 复制项、让它落回被 finish 掉的系统 ActionMode）
/// 无论重构成哪种形状都拿不到这条可达性。
///
/// 三处「绝不静默变绿」：
/// - `contextMenu: ContextMenu(` 整块没了 → [_contextMenuBlock] 直接 fail；
/// - 复制项没了 → [enclosingCallOf] 找不到锚点直接 fail；
/// - 中转方法把写剪贴板那一跳删了 / 换成本文件之外定义的东西 → 解析不到实现体，
///   判不可达并在失败信息里点名 action 到底调到了谁。
void main() {
  final String source =
      File('lib/src/pages/implementations/dictionary_popup_webview.dart')
          .readAsStringSync();
  // 窗口在**每条用例内部**才切：`_contextMenuBlock` 里的锚点断言会走 `expect`，
  // 在 `main()` 体里（测试之外）跑会抛 OutsideTestException —— 那是「整个 suite 装载
  // 失败、零测试执行」，而不是一条看得懂的红。
  String contextMenu() => _contextMenuBlock(source);

  group('BUG-1237 Android popup actions bypass finished ActionMode', () {
    test('Android hides broken system items while iOS is not expanded', () {
      final String menu = contextMenu();
      // 判据抬到「这个命名参数的实参表达式」上：换行、参数顺序、加不加括号都无关。
      final List<String> hide =
          namedArgumentValues(menu, 'hideDefaultSystemContextMenuItems');
      expect(hide, hasLength(1), reason: 'ContextMenuSettings 必须显式声明是否隐藏系统默认项');
      expect(
        hide.single,
        contains('Platform.isAndroid'),
        reason: 'Android 上系统默认项已被 finish 掉的 ActionMode 弄成死项，必须隐藏；'
            '现在的实参是 `${hide.single}`',
      );
      expect(
        hide.single,
        isNot(contains('Platform.isIOS')),
        reason: 'iOS 原生菜单是好的，不在本 bug 范围内，不得跟着一起隐藏',
      );
      expect(
        _elementPrefix(menu, _copyItem(menu).start),
        contains('Platform.isAndroid'),
        reason: '「复制」项是给 Android 补的死项替代，必须 Android 门控',
      );
    });

    test('copy is custom Dart clipboard action and selection is cleared', () {
      final String menu = contextMenu();
      final EnclosingCall copy = _copyItem(menu);
      expect(copy.name, 'ContextMenuItem',
          reason: '「复制」必须是 WebView 上下文菜单的一项，不是别的什么控件');

      final List<String> actions = namedArgumentValues(copy.text, 'action');
      expect(actions, hasLength(1), reason: '「复制」项必须挂一个 action');
      final String action = actions.single;

      expect(
        _clipboardWriterReachedFrom(source, action),
        isNotNull,
        reason: 'BUG-1237：Android 的「复制」必须是自定义 Dart 剪贴板动作。'
            '它现在既没有直接调 $_kClipboardWrite，也没有调用本文件里任何一个'
            '自己写剪贴板的方法（一跳可达闭包），等于又落回被 finish 掉的系统 '
            'ActionMode。当前 action 调到、且解析得到实现体的是：'
            '${_resolvableCallees(source, action)}',
      );

      expect(containsCodeLine(action, '_selectedTextAcrossFrames()'), isTrue,
          reason: '选区在同源子 iframe 里，只读顶层文档取不到（BUG-802）');
      expect(
          containsCodeLine(action, '_clearSelectedTextAcrossFrames()'), isTrue,
          reason: '复制完必须清掉选区，否则原生高亮留在页面上');
    });

    test('share and web search reuse the common action seam', () {
      final String menu = contextMenu();
      for (final String title in <String>[
        't.share',
        't.selection_web_search'
      ]) {
        final EnclosingCall item = enclosingCallOf(menu, 'title: $title');
        expect(item.name, 'ContextMenuItem');
        expect(_elementPrefix(menu, item.start), contains('Platform.isAndroid'),
            reason: '$title 项同样是给 Android 补的，必须门控');
      }
      expect(
          containsCodeLine(
              menu, 'SelectionExternalActions.instance.shareText(text)'),
          isTrue);
      expect(
          containsCodeLine(
              menu, 'SelectionExternalActions.instance.searchWeb(text)'),
          isTrue);
      expect(
          containsCodeLine(menu, 't.selection_web_search_unavailable'), isTrue);
    });
  });

  test('Windows right-click path remains unchanged', () {
    // 旧窗口是 `_between(src, 'Future<void> _showWindowsContextMenu(',
    // 'static String? _cachedStylesJson')`——那个右边界离方法真正的收口有 20 多行，
    // 中间**恰好**夹着共享写剪贴板方法的实现体，于是 PR#764 收口之后这条断言是
    // 「碰巧」还绿着的，跟 Android 那条同型、只是还没爆。改成结构窗口 + 同一条
    // 可达性判据，两侧不再有一处靠运气。
    final String? windows = topLevelFunctionBody(source, _kWindowsMenu);
    expect(windows, isNotNull, reason: '找不到 $_kWindowsMenu 的实现体：守卫失去锚点');

    final List<String> disable =
        namedArgumentValues(source, 'disableContextMenu');
    expect(disable, hasLength(1));
    expect(disable.single, contains('isWindowsPlatform'),
        reason: 'Windows 的 WebView2 原生菜单定位是错的，必须禁掉改走 Flutter showMenu');

    expect(containsCodeLine(windows!, '_selectedTextAcrossFrames()'), isTrue);
    expect(
      _clipboardWriterReachedFrom(source, windows),
      isNotNull,
      reason: 'Windows 右键「复制」同样必须落到 $_kClipboardWrite；当前调到、'
          '且解析得到实现体的是：${_resolvableCallees(source, windows)}',
    );
    expect(containsCodeLine(windows, 'SelectionExternalActions'), isFalse,
        reason: 'Windows 右键菜单只有「查词 / 复制」，不复用移动端的分享 / 网搜外部动作');
  });
}

// ---------------------------------------------------------------------------
// 「复制动作必须可达 Dart 剪贴板写入」的契约判据（BUG-1237）
// ---------------------------------------------------------------------------

/// 剪贴板写入本体：Flutter 侧把文本交给系统剪贴板的唯一 API。
const String _kClipboardWrite = 'Clipboard.setData';

/// Windows 右键菜单入口。
const String _kWindowsMenu = '_showWindowsContextMenu';

/// `contextMenu: ContextMenu(...)` 这一次调用的完整原文。
///
/// 用括号配对而不是「到 `gestureRecognizers:` 为止」：右边界由结构给出，与后面那个
/// 命名参数叫什么、写在第几位全部无关。
String _contextMenuBlock(String src) {
  const String anchor = 'contextMenu: ContextMenu(';
  final int at = maskCommentsAndStrings(src).indexOf(anchor);
  expect(at, greaterThanOrEqualTo(0),
      reason: 'WebView 的 contextMenu 参数不见了：守卫失去锚点，先修锚点再谈断言');
  return enclosingCall(src, at + anchor.length).text;
}

/// 菜单里那一项「复制」的 `ContextMenuItem(...)` 切片。
EnclosingCall _copyItem(String menu) => enclosingCallOf(menu, 'title: t.copy');

/// 从 [block] 出发，**一跳可达闭包**内第一个真正写剪贴板的落点；不可达返回 null。
///
/// 直接调 [_kClipboardWrite] 返回 `'<直接调用>'`；调本文件里某个方法、而那个方法自己
/// 调 [_kClipboardWrite] 则返回该方法名（PR#764 的 `_copySelectionToClipboard`）。
/// 除此以外一律不可达——BUG-1237 的原始形态（没有 Dart 复制动作、落回被 finish 掉的
/// 系统 ActionMode）落在这一侧。
String? _clipboardWriterReachedFrom(String src, String block) {
  if (containsIdentifierCall(block, _kClipboardWrite)) return '<直接调用>';
  for (final String callee in _calleeNames(block)) {
    final String? body = topLevelFunctionBody(src, callee);
    if (body == null) continue;
    if (containsIdentifierCall(body, _kClipboardWrite)) return callee;
  }
  return null;
}

/// [block] 里调用到、且能在 [src] 里解析出实现体的被调方名字（只用于失败信息）。
List<String> _resolvableCallees(String src, String block) => _calleeNames(block)
    .where((String name) => topLevelFunctionBody(src, name) != null)
    .toList();

/// 代码里以独立标识符身份被调用的名字（不含点链——那是别的对象的方法，本文件解析
/// 不到实现体，也就拿不到可达性）。注释与字符串里的同名文本不算。
List<String> _calleeNames(String block) {
  final RegExp call =
      RegExp(r'(?<![A-Za-z0-9_$.])([A-Za-z_$][A-Za-z0-9_$]*)\s*\(');
  final Set<String> names = <String>{};
  for (final RegExpMatch m in call.allMatches(maskCommentsAndStrings(block))) {
    names.add(m.group(1)!);
  }
  // 语言关键字不是被调方，剔掉只是省无谓的解析。
  names.removeAll(const <String>{'if', 'for', 'while', 'switch', 'catch'});
  return names.toList()..sort();
}

/// 列表元素在自己的构造器之前写了什么（`if (Platform.isAndroid)` 这类 collection-if）。
///
/// 从 [start] 往回扫到**同级**的 `,` 或列表左括号为止。用深度配对而不是「上一行」：
/// 前一个元素多包一层括号、或 `dart format` 重排都不影响。
String _elementPrefix(String list, int start) {
  final String structural = maskCommentsAndStrings(list);
  int depth = 0;
  for (int i = start - 1; i >= 0; i--) {
    final String c = structural[i];
    if (c == ')' || c == ']' || c == '}') {
      depth++;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') {
      if (depth == 0) return list.substring(i + 1, start);
      depth--;
      continue;
    }
    if (c == ',' && depth == 0) return list.substring(i + 1, start);
  }
  return list.substring(0, start);
}
