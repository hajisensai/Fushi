import 'package:flutter_test/flutter_test.dart';

import 'source_guard.dart';

// ---------------------------------------------------------------------------
// PR#460 / BUG-951 不变式的**行为级**判据
// ---------------------------------------------------------------------------
//
// 不变式的真实语义（见 docs/bugs/BUG-951-gal-overlay-click-through-cross-process.md）：
// **定时器 / 离线程光标轮询永远不得改写浮窗的鼠标可交互性**
// （WS_EX_TRANSPARENT / pass_through_ / HTTRANSPARENT / EnableWindow）。
// PR#460 按 16ms 定时器读光标位置来回翻这个位，定时器一被饿死，用户已经把光标甩到
// 工具条上点下去时位还没清掉——点击穿进游戏推台词 / 选分支，存档被破坏。
//
// 信息只允许**单向**流动：穿透态 -> 定时器（定时器可以读到 pass_through_ 并把自己
// 停掉），反向一律禁止。
//
// 为什么不能继续用 token 判据（这个文件存在的原因）：
// 旧守卫写的是 expect(cpp.contains('SetTimer('), isFalse)——它禁的是**关键字**，
// 不是**行为**。于是 PR#749 给台词浮窗加「按住 Shift 悬停查词」的 60ms 轮询时被误伤：
// 那个定时器只读光标位置派发查词，全程碰不到任何可交互性状态（还专门写了
// if (pass_through_) { StopHoverLookupPolling(); return; } 主动让位），却让两条守卫
// 同时转红。token 判据**两个方向都错**：
// - 漏真阳：SetCoalescableTimer / TIMERPROC 回调 / SetWindowsHookEx 都能原样重建
//   PR#460，却绕开 SetTimer( 这个字面量；
// - 报假阳：任何与可交互性无关的定时器都被判红。
//
// 这里改成沿真实调用图判定：从每个定时器回调入口出发做**可达性闭包**，闭包里出现任何
// 可交互性写操作即红。同时把「定时器回调入口可枚举」本身也钉死（TIMERPROC 必须是
// nullptr，否则闭包分析就不完整），不然判据自己会被绕过去。

/// 会改写「这个窗口收不收鼠标」的写操作。命中其一即视为翻转了可交互性。
///
/// 判据故意覆盖 Win32 里**所有**能做到这件事的装置，而不只是 PR#460 用过的那个：
/// - `GWL_EXSTYLE` / `WS_EX_TRANSPARENT` / `SWP_FRAMECHANGED`：PR#460 的原装置；
/// - `HTTRANSPARENT`：BUG-951 本体那个跨进程无效的装置；
/// - `EnableWindow(`：另一条让整窗不吃鼠标的路；
/// - `SetBodyExTransparent(` / `ApplyPassThroughExStyle(`：本仓的唯一 applier 与其漏斗。
///   从定时器调到它们，等于绕过「只有三条生命周期边可以重放穿透」的结构不变式；
/// - `pass_through_ =`：状态本身的写（`pass_through_ ==` 的读不算，`(?!=)` 排掉）。
final List<RegExp> _interactivityWrites = <RegExp>[
  RegExp(r'(?<![A-Za-z0-9_])GWL_EXSTYLE(?![A-Za-z0-9_])'),
  RegExp(r'(?<![A-Za-z0-9_])WS_EX_TRANSPARENT(?![A-Za-z0-9_])'),
  RegExp(r'(?<![A-Za-z0-9_])SWP_FRAMECHANGED(?![A-Za-z0-9_])'),
  RegExp(r'(?<![A-Za-z0-9_])HTTRANSPARENT(?![A-Za-z0-9_])'),
  RegExp(r'(?<![A-Za-z0-9_])EnableWindow\s*\('),
  RegExp(r'(?<![A-Za-z0-9_])SetBodyExTransparent\s*\('),
  RegExp(r'(?<![A-Za-z0-9_])ApplyPassThroughExStyle\s*\('),
  RegExp(r'(?<![A-Za-z0-9_])pass_through_\s*=(?!=)'),
];

/// 装表的 Win32 入口。两个都认：只禁 `SetTimer` 会让 `SetCoalescableTimer` 原样
/// 重建 PR#460 还判绿。
const List<String> _timerInstallers = <String>[
  'SetTimer',
  'SetCoalescableTimer',
];

/// 从已掩码语料 [structural] 的下标 [openParen]（指向 `(`）起做圆括号配对，
/// 返回配对上的 `)` 的下标；不配对返回 -1。
int _matchingParen(String structural, int openParen) {
  int depth = 0;
  for (int i = openParen; i < structural.length; i++) {
    final String c = structural[i];
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 把 `(a, b, c)` 的实参按**顶层**逗号切开（嵌套括号内的逗号不切）。
List<String> _topLevelArgs(String call) {
  final String inner = call.substring(1, call.length - 1);
  final String structural = maskCommentsAndStrings(inner);
  final List<String> out = <String>[];
  int depth = 0;
  int start = 0;
  for (int i = 0; i < structural.length; i++) {
    final String c = structural[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ',' && depth == 0) {
      out.add(inner.substring(start, i).trim());
      start = i + 1;
    }
  }
  out.add(inner.substring(start).trim());
  return out;
}

/// 取 [source] 里 [name] 每一次调用的完整实参表原文（含首尾圆括号）。
List<String> _callArgumentLists(String source, String name) {
  final String searchable = maskComments(source);
  final String structural = maskCommentsAndStrings(source);
  final RegExp call =
      RegExp(r'(?<![A-Za-z0-9_])' + RegExp.escape(name) + r'\s*\(');
  final List<String> out = <String>[];
  for (final RegExpMatch m in call.allMatches(searchable)) {
    final int open = m.end - 1;
    final int close = _matchingParen(structural, open);
    if (close < 0) {
      fail('$name 的实参表圆括号不配对（下标 $open）');
    }
    out.add(source.substring(open, close + 1));
  }
  return out;
}

/// 取出 [source] 里每一个 `case WM_TIMER:` 分支体（花括号配对）。
///
/// 分支体必须是带花括号的形式；裸 `case WM_TIMER: Foo(); break;` 直接 `fail`——
/// 没有花括号就没有可靠的右边界，闭包会一路吞到下一个 case，判据会静默变宽。
List<String> _timerHandlerBodies(String source) {
  const String label = 'case WM_TIMER:';
  final String searchable = maskComments(source);
  final String structural = maskCommentsAndStrings(source);
  final List<String> out = <String>[];
  int from = 0;
  while (true) {
    final int idx = searchable.indexOf(label, from);
    if (idx < 0) break;
    int probe = idx + label.length;
    while (probe < structural.length &&
        (structural[probe] == ' ' ||
            structural[probe] == '\n' ||
            structural[probe] == '\r' ||
            structural[probe] == '\t')) {
      probe++;
    }
    if (probe >= structural.length || structural[probe] != '{') {
      fail('case WM_TIMER 分支体必须用花括号包起来，否则闭包分析取不到右边界');
    }
    out.add(balancedBlockFrom(source, idx,
        openSearchFrom: probe, what: 'case WM_TIMER 分支体'));
    from = idx + label.length;
  }
  return out;
}

/// 找 `[className]::[name]` 的**定义**体；只有声明或根本没有时返回 null。
String? _memberDefinitionBody(String source, String className, String name) {
  final String searchable = maskComments(source);
  final String structural = maskCommentsAndStrings(source);
  final RegExp def = RegExp(r'(?<![A-Za-z0-9_])' +
      RegExp.escape(className) +
      r'::' +
      RegExp.escape(name) +
      r'\s*\(');
  for (final RegExpMatch m in def.allMatches(searchable)) {
    final int open = m.end - 1;
    final int close = _matchingParen(structural, open);
    if (close < 0) continue;
    int probe = close + 1;
    // 跳过 const / noexcept / 空白，落到定义体的左花括号上。
    while (probe < structural.length) {
      final String c = structural[probe];
      if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
        probe++;
        continue;
      }
      final RegExpMatch? word = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*')
          .firstMatch(structural.substring(probe));
      if (word != null) {
        probe += word.group(0)!.length;
        continue;
      }
      break;
    }
    if (probe < structural.length && structural[probe] == '{') {
      return balancedBlockFrom(source, m.start,
          openSearchFrom: probe, what: '$className::$name 定义体');
    }
  }
  return null;
}

/// [body] 的代码里以标识符身份被调用的所有名字。
Set<String> _calledIdentifiers(String body) {
  final RegExp call = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\s*\(');
  return call
      .allMatches(maskCommentsAndStrings(body))
      .map((RegExpMatch m) => m.group(1)!)
      .toSet();
}

/// 从 [seed] 出发、在 [source] 里可达的 [className] 成员函数体的并集（含 [seed]）。
///
/// 判据必须是**可达性**而不是「WM_TIMER 分支体这一屏里有没有」：PR#460 正是
/// `case WM_TIMER:` 里只写一行 `UpdatePassThroughFromCursor();`，真正翻位的
/// `SetWindowLongPtr(hwnd_, GWL_EXSTYLE, ...)` 在两跳之外。
String reachableFromTimerCallback(
  String source,
  String className,
  String seed,
) {
  final StringBuffer closure = StringBuffer(seed);
  final Set<String> seen = <String>{};
  final List<String> queue = _calledIdentifiers(seed).toList();
  while (queue.isNotEmpty) {
    final String name = queue.removeLast();
    if (!seen.add(name)) continue;
    final String? body = _memberDefinitionBody(source, className, name);
    if (body == null) continue;
    closure.writeln(body);
    queue.addAll(_calledIdentifiers(body));
  }
  return closure.toString();
}

/// 断言 [source] 里**没有任何定时器回调**能改写窗口的鼠标可交互性（PR#460 不变式）。
///
/// [className] 是被扫文件里那个窗口类的名字（成员函数定义写作 `类名::方法`）。
/// [label] 只进失败原因，方便一眼看出是哪份语料红的。
///
/// 三条一起才成立，缺一条判据就有洞：
/// 1. 定时器回调入口**可枚举**——每次装表都必须把 TIMERPROC 传 `nullptr`，
///    这样 `case WM_TIMER:` 就是唯一入口，第 3 条的闭包才是完整的；
/// 2. 没有 `SetWindowsHookEx`——离线程钩子是另一条轮询光标的路，源码扫描分析不了
///    它的回调，所以整个禁掉；
/// 3. 每个 `case WM_TIMER:` 分支体的**可达性闭包**里不得出现任何可交互性写操作。
void expectTimerCannotFlipInteractivity(
  String source, {
  required String className,
  required String label,
}) {
  // 1) 入口可枚举。
  for (final String installer in _timerInstallers) {
    for (final String args in _callArgumentLists(source, installer)) {
      final List<String> parts = _topLevelArgs(args);
      expect(parts.length, greaterThanOrEqualTo(4),
          reason: '$label：$installer$args 参数个数不对，判据读不到 TIMERPROC');
      expect(parts[3], 'nullptr',
          reason: '$label：$installer 必须把 TIMERPROC 传 nullptr，'
              '否则定时器回调不止 case WM_TIMER 一处，'
              '「定时器不翻转可交互性」这条判据就分析不完整了（PR#460 不变式）。');
    }
  }

  // 2) 离线程光标钩子整个禁掉。
  expect(maskComments(source).contains('SetWindowsHookEx'), isFalse,
      reason: '$label：低级鼠标钩子是绕开消息循环轮询光标的另一条路，'
          '源码扫描分析不了它的回调，因此不许出现在这份语料里（PR#460 不变式）。');

  // 3) 每个定时器回调的可达闭包里不得有可交互性写操作。
  for (final String handler in _timerHandlerBodies(source)) {
    final String closure =
        reachableFromTimerCallback(source, className, handler);
    final String structural = maskCommentsAndStrings(closure);
    for (final RegExp write in _interactivityWrites) {
      expect(write.hasMatch(structural), isFalse,
          reason: '$label：从 case WM_TIMER 可达的代码里出现了 '
              '${write.pattern} —— 定时器又在翻转窗口的鼠标可交互性了。'
              '这正是 PR#460 被 revert 的原因：表被饿死时，用户已经把光标甩到'
              '工具条上点下去，位还没清掉，点击穿进游戏推台词 / 选分支。'
              '定时器只许**读**穿透态（读到就把自己停掉），不许写。');
    }
  }
}
