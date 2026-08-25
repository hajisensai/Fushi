import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 查词弹窗静态设置段的**去重完整性**守卫。
///
/// 背景：`buildStackRenderScript` 产出的渲染负载里，静态段（主题变量 + 词典字体 +
/// 词典样式 + 自定义 CSS + 各种 window.* 开关）是大头。用户导入的词典字体走 `data:`
/// URL 内联，两个 CJK 字体 base64 之后就是几十 MB。所以静态段按
/// `PopupStaticSettingsJs.revision` 去重：宿主已装过的版本不再随渲染负载重发。
///
/// 这条守卫钉的是一个**真实发生过**的事故形状：去重曾经是「可选参数 + 各调用方自己
/// 拿 Map 拼」，于是剪贴板面板那条路径一个参数都没传，整套去重对它完全失效——每次
/// 查词（包括每次在面板里点词的嵌套查词）都把几十 MB 静态段重新序列化、过平台通道、
/// 在 WebView2 里解析，然后被 host.js 按 revision 认出是旧相识、当场丢弃。纯浪费。
///
/// 形参现在是必填的，「漏传」由编译器兜住。这条测试兜的是编译器管不到的另外两半：
///   ① **忘记 commit**——渲染发出去了却不记账，等于每次都重发，静默退回事故状态；
///   ② **只做去重、不接回补**——host.js 在整块 WebView 恢复 / iframe realm 重建后会
///      发 `staticSettingsRequired` 要求重发某个版本。只去重不接这条通道，宿主一旦
///      丢掉缓存就再也等不到静态段，卡片会永远停在没主题、没字体、没词典样式的状态。
///      这两件事必须成对出现，缺一不可。
///
/// 采用目录枚举（`listSync(recursive: true)`）而不是硬编码文件清单：将来任何新增的
/// 渲染调用方都会自动落进扫描面，不会像定向清单那样漏掉。
void main() {
  test('every buildStackRenderScript caller commits and honours resend', () {
    final Directory libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: '必须在 fushi/ 下跑（工作目录应含 lib/）');

    final List<File> callers = <File>[];
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String src = _codeOnly(entity.readAsStringSync());
      if (!src.contains('buildStackRenderScript(')) continue;
      // 跳过定义处本身（它声明返回类型，调用点不会）。
      if (src.contains('StackRenderScript buildStackRenderScript(')) continue;
      callers.add(entity);
    }

    expect(
      callers,
      isNotEmpty,
      reason:
          '扫不到任何调用方 = 守卫在空转（函数被改名了？）——'
          '此时必须回来按行为重新推导扫描面，而不是让它静默通过',
    );

    for (final File caller in callers) {
      final String src = _codeOnly(caller.readAsStringSync());
      final String path = caller.path;
      expect(
        src,
        contains('.commit('),
        reason:
            '$path 调用了 buildStackRenderScript 却没有 commit 已发出的版本。'
            '不记账 = 下一次渲染仍认为宿主没装过 = 每次查词都重发几十 MB 静态段。'
            'commit 必须在平台 render 调用成功之后进行。',
      );
      expect(
        src,
        contains("== 'staticSettingsRequired'"),
        reason:
            '$path 参与了静态段去重，却没有处理 host 的 staticSettingsRequired '
            '回补请求。去重与回补是一对：宿主整块 WebView 恢复 / realm 重建后会丢掉'
            '缓存，只去重不回补会让这个表面永远等不到静态段（无主题/无字体/无词典'
            '样式），比不去重更糟。',
      );
    }
  });

  test('the render builder exposes no optional dedup escape hatch', () {
    final File render = File('lib/src/lookup/global_lookup_render.dart');
    expect(render.existsSync(), isTrue);
    final String src = _codeOnly(render.readAsStringSync());

    expect(
      src,
      contains('required PopupStaticRevisionCache staticRevisions'),
      reason:
          '宿主账本必须是必填参数——一旦退回可选（带默认值），'
          '新调用方就能像剪贴板面板当初那样静默地完全不去重',
    );
    expect(
      src,
      contains('required String hostKey'),
      reason:
          'hostKey 必须必填：不同 WebView2 realm 的账本不能混，'
          '混了会让 A 宿主的已装载记录挡住 B 宿主的首次下发',
    );
    // 旧的两个可选形参不得复活。
    expect(
      src,
      isNot(contains('Set<int> knownStaticRevisions = const <int>{}')),
      reason: '带默认值的 knownStaticRevisions 形参正是事故根源，不得复活',
    );
    expect(
      src,
      isNot(contains('Set<int>? emittedStaticRevisions')),
      reason:
          '可空的 emittedStaticRevisions 出参正是事故根源，不得复活；'
          '待确认版本应从返回值的 pendingRevisions 带出',
    );
  });
}

/// 剥掉 `//` 行注释与 `/* */` 块注释，只留下真正的代码。
///
/// 这一步不是洁癖：本仓的注释密度很高，而这条守卫要找的恰恰是
/// `staticSettingsRequired` / `commit` 这类**会被大段中文注释反复提及**的词。不剥
/// 注释直接 `contains`，守卫会被自己的说明文字喂饱、对真实代码的缺失视而不见——
/// 即「输出可信但结论错」的经典形状。实测：把面板的回补分支改名注入变异后，不剥
/// 注释的版本照样全绿，剥注释的版本才抓得住。
String _codeOnly(String source) {
  final String withoutBlocks = source.replaceAll(
    RegExp(r'/\*.*?\*/', dotAll: true),
    '',
  );
  return withoutBlocks
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}
