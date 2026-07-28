import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1204 守卫：单词发音失败的**原因**必须一路留痕，不能再被吞成一个光秃秃的 false。
///
/// 背景：`playWordAudio` 原本是 `.catch(() => false)`，把 `audio.play()` 抛的
/// DOMException 整个丢弃。于是「app 启动后第一次发音必失败、之后都成功」这种稳定可复现
/// 的症状，在日志里查不出是 autoplay 策略拦截（NotAllowedError）、解码失败
/// （NotSupportedError）还是被下一次播放掐断（AbortError）——三者修法完全不同。
///
/// 这条链路没有可跑的运行时测试面（真实 WebView2 / InAppWebView 才有 `audio.play()`），
/// 故守在**源码**这一层：三份 popup.js 镜像 + app 外 host 桥 + app 内注入脚本，各自
/// 必须保留把原因取出并回传的那一环。
///
/// flutter test 的 cwd 是 hibiki 包根。
void main() {
  const List<String> popupMirrors = <String>[
    'assets/popup/popup.js',
    'assets/browser_extension/vendor/popup.js',
    '../tools/browser-extension/vendor/popup.js',
  ];

  /// 剥掉整行 `//` 注释后再扫：解释「旧写法为何是 bug」的注释本身必然包含那段旧代码，
  /// 连注释一起扫会把文档自己判成回潮（本守卫第一版就这么误报过）。
  String stripLineComments(String src) => src
      .split('\n')
      .where((String l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  test('三份 popup.js 都记录播放失败原因，且不再无脑吞掉 catch', () {
    for (final String path in popupMirrors) {
      final File f = File(path);
      expect(f.existsSync(), true, reason: '镜像缺失：$path');
      final String src = f.readAsStringSync();

      expect(src.contains('__hibikiWordAudioLastError'), true,
          reason: '$path 必须把 audio.play() 的失败原因存到 '
              '__hibikiWordAudioLastError 供宿主回传（BUG-1204）');
      // 正是这个模式吞掉了根因，绝不允许回潮（只看真代码，不看注释）。
      expect(stripLineComments(src).contains('.catch(() => false)'), false,
          reason: '$path 不得再用 `.catch(() => false)` 丢弃 DOMException'
              '——那正是 BUG-1204 的根因');
    }
  });

  test('三份 popup.js 保持字节一致（镜像不漂）', () {
    final List<String> bodies = <String>[
      for (final String p in popupMirrors) File(p).readAsStringSync()
    ];
    expect(bodies[1], bodies[0], reason: 'assets 扩展镜像与 app 内 popup.js 漂开了');
    expect(bodies[2], bodies[0], reason: 'tools 源与 app 内 popup.js 漂开了');
  });

  test('app 外 host 桥把失败原因作为第三个参数回传', () {
    final String src =
        File('assets/popup/global_lookup_host.js').readAsStringSync();
    expect(src.contains('__hibikiWordAudioLastError'), true,
        reason: 'host 注入的 report 必须读取 realm 上的失败原因（BUG-1204）');
    // 帧未加载 / eval 失败也各有自己的原因串，不与 play() 的 DOMException 混淆。
    expect(src.contains('FrameNotLoaded'), true,
        reason: '帧未加载要有独立原因串，便于与 autoplay 拦截区分');
    expect(src.contains('PlayFunctionMissing'), true,
        reason: 'popup.js 未装载要有独立原因串');
  });

  test('app 内注入脚本同样回传失败原因', () {
    final String src =
        File('lib/src/pages/implementations/dictionary_popup_webview.dart')
            .readAsStringSync();
    expect(src.contains('__hibikiWordAudioLastError'), true,
        reason: 'app 内 wordAudioPlayed 注入脚本必须一并回传原因，'
            '否则 app 内首播失败仍无法定位（BUG-1204）');
  });

  test('两端 Dart handler 都把失败原因写进日志', () {
    final String overlay =
        File('lib/src/lookup/global_lookup_controller.dart').readAsStringSync();
    expect(overlay.contains('reason='), true,
        reason: 'app 外 wordAudioPlayed handler 必须记录 reason（BUG-1204）');

    final String inApp =
        File('lib/src/pages/implementations/dictionary_popup_webview.dart')
            .readAsStringSync();
    expect(inApp.contains('reason='), true,
        reason: 'app 内 wordAudioPlayed handler 必须记录 reason（BUG-1204）');
  });
}
