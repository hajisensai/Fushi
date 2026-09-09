import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「功能模块」把「下载」/「查词」tab 关掉后，`_selectTab` 会拒绝切到隐藏 tab
/// （`if (!_activeTabs().contains(tab)) return;`）。这条守卫钉住**所有指向这两个
/// 隐藏 tab 的入口**都不会因此变成静默失效：
///
/// ① 指向下载页的导航必须先判可达、再动导航栈。原始坏路径是
///    `popUntil(isFirst)` 已经把用户的详情页 / 放送日历弹掉，随后 `_selectTab`
///    才拒绝切换 —— 用户丢了整个导航栈、停在首页且毫无提示，比「什么都不做」更坏。
/// ② 发现页那两个「查看下载」/「管理订阅」端口在下载模块关掉时不接线（端口本就
///    nullable，消费端已按 null 不渲染）：页面不可达 ⇒ 入口不该在。
/// ③ 查词的三条全局入口（homeTabDict 热键 / homeFocusSearch 热键 / 悬浮字幕点词的
///    homeDictionaryTabRequest）必须走 `_revealDictionary` 而不是裸
///    `_selectTab(HomeTab.dictionaries)` —— 隐藏的是导航项，不是查词能力，tab 不在
///    时改推独立路由承载同一个 HomeDictionaryPage。
///
/// 这些是「调用顺序 / 接线与否」的结构约束，widget 测试只能看到它们的下游效果；
/// 源码扫描是能钉住成因的最强可落地层。全文先归一化换行，避免 CRLF 检出恒不匹配。
void main() {
  final File file = File('lib/src/pages/implementations/home_page.dart');
  final String source = file.readAsStringSync().replaceAll('\r\n', '\n');

  setUpAll(() {
    expect(file.existsSync(), isTrue, reason: '守卫语料文件必须存在：${file.path}');
  });

  test('① _popToDownloadsTab 先判可达再 popUntil（绝不先毁导航栈再发现去不了）', () {
    final int body = source.indexOf('bool _popToDownloadsTab(int tabIndex) {');
    expect(body, greaterThan(0),
        reason: 'popUntil + 切下载 tab 必须收口在唯一出口 _popToDownloadsTab');
    final int end = source.indexOf('\n  }', body);
    expect(end, greaterThan(body));
    final String fn = source.substring(body, end);

    final int gate = fn.indexOf('if (!_downloadsReachable) return false;');
    final int pop = fn.indexOf('popUntil');
    expect(gate, greaterThan(-1), reason: '必须有可达性早退');
    expect(pop, greaterThan(-1), reason: '必须仍用 popUntil 收口（与栈深无关）');
    expect(
      gate,
      lessThan(pop),
      reason: '可达性判定必须在动导航栈之前；顺序反了就是「先弹掉用户的页面再发现去不了」。',
    );
  });

  test('② _openDownloadsTab 只能从可达性门控过的两处调用', () {
    final List<int> calls = <int>[];
    for (int i = source.indexOf('_openDownloadsTab(');
        i >= 0;
        i = source.indexOf('_openDownloadsTab(', i + 1)) {
      calls.add(i);
    }
    expect(calls.length, 2,
        reason: '期望恰好两处：声明 + _popToDownloadsTab 内。'
            '所有端口都必须经 _popToDownloadsTab —— 它同时管可达性门控与「先回到 '
            'home 这一层路由」，而 _openDownloadsTab 只 setState 切 tab、不动导航栈。'
            '新增调用点必须走 _popToDownloadsTab，然后更新本守卫。');

    expect(
      source.contains('void _openDownloadsTab(int tabIndex) {'),
      isTrue,
      reason: '第一处是声明本身',
    );
    expect(
      source.contains('    _openDownloadsTab(tabIndex);\n    return true;'),
      isTrue,
      reason: '第二处在 _popToDownloadsTab 的可达分支里',
    );
    expect(
      source.contains(
          'onOpenDownloads: downloadsReachable ? () => _popToDownloadsTab(0) : null,'),
      isTrue,
      reason: '「查看下载」端口必须走 _popToDownloadsTab：作品**详情页**永远是 '
          'pushed route，只切 tab 的话 tab 在底下换了、用户还停在详情页上，'
          '看起来什么都没发生。内联在 home 里的发现页已在栈顶，popUntil 是 no-op。',
    );
  });

  test('② onOpenSubscriptions 端口同样按下载可达性接线', () {
    // 归一化空白后再比：换行位置由 dart format 按行宽决定，不是本守卫要钉的不变式
    // （钉它只会让任何挪动这一行的无关改动凭空报红）。要钉的是「端口按可达性三目
    // 接线」这件事本身。
    final String flat = source.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      flat.contains(
        'onOpenSubscriptions: downloadsReachable '
        '? _openVideoDiscoverySubscriptionsPanel : null,',
      ),
      isTrue,
      reason: '下载页不可达时「管理订阅」端口必须不接线，消费端按 null 不渲染该按钮。',
    );
  });

  test('② 已订阅回退分支去不了下载页时给提示，而不是无声消失', () {
    expect(
      source.contains('if (!_popToDownloadsTab(2)) {\n'
          '        _showVideoDiscoveryMessage(context, t.module_downloads_hidden_hint);'),
      isTrue,
      reason: '端口不接线时订阅按钮会退化成 onSubscribe，这条分支仍可达，'
          '去不了下载页必须给一句可操作提示。',
    );
  });

  test(
    '③ 查词的三条全局入口都走 _revealDictionary，没有裸 _selectTab(HomeTab.dictionaries)',
    () {
      // 全文里 `_selectTab(HomeTab.dictionaries)` 只允许出现一次，且必须落在
      // _revealDictionary 的「tab 可见」分支里。别处出现即是绕过落地面的裸切 tab。
      final int revealStart = source.indexOf('void _revealDictionary({');
      // 取**函数体**的右花括号，不是参数表的 `}) {`——签名换行之后 '\n  }' 会先
      // 命中后者，把整个函数体压成零长度区间。
      final int revealEnd = source.indexOf(
        '\n  }',
        source.indexOf(') {', revealStart),
      );
      expect(revealStart, greaterThan(0));
      final List<int> bare = <int>[];
      for (
        int i = source.indexOf('_selectTab(HomeTab.dictionaries)');
        i >= 0;
        i = source.indexOf('_selectTab(HomeTab.dictionaries)', i + 1)) {
      bare.add(i);
    }
    expect(
      bare.length,
      1,
      reason: '裸切 tab 在查词模块关掉时会被 _selectTab 直接吞掉：用户按热键只会看到'
          '窗口弹到前台却什么都不显示，pendingText 永远挂着。所有查词入口必须走'
          '_revealDictionary。',
    );
    expect(
      bare.single > revealStart && bare.single < revealEnd,
      isTrue,
      reason: '唯一一处必须在 _revealDictionary 的「tab 可见」分支里',
    );

      // 热键两条。它们是**主动导航**：查词模块关掉时必须先返回 ignored 再落地。
      // ignored 而不是 handled —— handled 会把按键认领掉，同一物理键上绑的
      // universal / global 动作再也收不到它，于是「关掉查词后 Ctrl+F 既不开页、
      // 也不再冒泡」，变成一个吃键的黑洞。
      for (final String action in <String>['homeTabDict', 'homeFocusSearch']) {
        final int caseAt = source.indexOf('case ShortcutAction.$action:');
        expect(caseAt, greaterThan(0), reason: '$action 分支应存在');
        final int caseEnd = source.indexOf('      case ', caseAt + 1);
        final String branch = source.substring(caseAt, caseEnd);
        expect(
          branch.contains('ModuleId.lookup') &&
              branch.contains('KeyEventResult.ignored'),
          isTrue,
          reason: '$action 是主动导航，查词模块关掉时不认领按键（看不见也到不了）',
        );
        expect(
          branch.contains('_revealDictionary('),
          isTrue,
          reason: '$action 通过模块门之后仍必须走 _revealDictionary',
        );
      }
      // 桌面悬浮字幕点词 / 剪贴板 mainTab 分区一条。
      expect(source.contains('void _onHomeDictionaryTabRequested() {'), isTrue);
      final int handler = source.indexOf(
        'void _onHomeDictionaryTabRequested() {',
      );
      final int handlerEnd = source.indexOf('\n  }', handler);
      expect(
        source
            .substring(handler, handlerEnd)
            .contains('_revealDictionary(carryingPendingLookup: true)'),
        isTrue,
        reason:
            'homeDictionaryTabRequest（桌面取词 / 悬浮字幕点词 / 扩展回流）必须走 '
            '_revealDictionary，且必须带 carryingPendingLookup: true —— 它携带一次'
            '**已经发生**的查词请求，查词模块关着也要给它落地面。漏掉这个实参会让'
            '请求被模块门吞掉：用户只看到窗口弹到前台却什么都不显示，'
            'DesktopLookupService.pendingText 永远挂着。',
      );
    },
  );

  test('③ _revealDictionary：tab 在切 tab、tab 不在推独立路由且不叠第二份', () {
    final int body = source.indexOf('void _revealDictionary({');
    expect(body, greaterThan(0));
    // 同上：跳过多行参数表的 `}) {`，从函数体的开花括号开始找收尾。
    final int end = source.indexOf('\n  }', source.indexOf(') {', body));
    final String fn = source.substring(body, end);

    expect(
      fn.contains('if (_activeTabs().contains(HomeTab.dictionaries)) {'),
      isTrue,
      reason: 'tab 可见时仍走原来的切 tab 路径',
    );
    expect(
      fn.contains('_StandaloneDictionaryRoute(focusSignal: _dictFocusSignal)'),
      isTrue,
      reason: 'tab 隐藏时必须推独立路由承载同一个 HomeDictionaryPage',
    );
    expect(
      fn.contains('existing != null && existing.isActive'),
      isTrue,
      reason: '已经开着就翻到最上层，绝不叠第二个 HomeDictionaryPage —— '
          '否则 mainTab 分区的 pending 查词会被双消费。',
    );
    expect(
      fn.contains('!carryingPendingLookup') &&
          fn.contains('isEnabled(ModuleId.lookup)'),
      isTrue,
      reason:
          '模块门必须**按调用来源分流**：主动导航（热键）在查词模块关掉时不开页，'
          '携带 pending 的（桌面取词/悬浮字幕点词/扩展回流）照常开。合成一个门就'
          '必然牺牲其中一边——要么「关了还能按 Ctrl+F 弹出查词页」，要么「取词请求'
          '永远挂着」。',
    );
  });
}
