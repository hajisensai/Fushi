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
      // 全部断言一律扫**剥掉注释后**的源码：解释「BUG-1204 根因长什么样」的注释里
      // 必然写着 __hibikiWordAudioLastError 和旧写法，连注释一起扫等于让文档给自己
      // 背书——把实现整段删光、只留注释也照样绿（变异实测证实过这条假绿）。
      final String code = stripLineComments(f.readAsStringSync());

      expect(code.contains('__hibikiWordAudioLastError'), true,
          reason: '$path 必须把 audio.play() 的失败原因存到 '
              '__hibikiWordAudioLastError 供宿主回传（BUG-1204）');
      // 正是这个模式吞掉了根因，绝不允许回潮。
      expect(code.contains('.catch(() => false)'), false,
          reason: '$path 不得再用 `.catch(() => false)` 丢弃 DOMException'
              '——那正是 BUG-1204 的根因');

      // 光有这个名字还不够：BUG-1204 的根因是 **play() 的 rejection 分支**把
      // DOMException 丢了。只查名字出现过，删掉 rejection 里那一句赋值照样绿
      // （名字在 EmptyUrl 分支和成功清空处仍在）——变异实测证实过。故锚到
      // `audio.play()` 之后的第一个 `.catch(`，要求它的回调体里真的记了原因。
      //
      // 括号配平精确截出回调体，**不能**用「其后 N 个字符」的窗口：那会把外层
      // `} catch (e) { noteError(e); }` 也圈进来，删掉 rejection 里的记录照样绿
      // （第一版加固就是这么漏的，变异实测才发现）。
      final int playIdx = code.indexOf('audio.play()');
      expect(playIdx, greaterThanOrEqualTo(0),
          reason: '$path 里找不到 audio.play()，守卫锚点失效，请同步更新本测试');
      final int catchIdx = code.indexOf('.catch(', playIdx);
      expect(catchIdx, greaterThanOrEqualTo(0),
          reason: '$path 的 audio.play() 之后必须有 rejection 分支');
      int depth = 0;
      int end = code.indexOf('(', catchIdx);
      for (; end < code.length; end++) {
        if (code[end] == '(') depth++;
        if (code[end] == ')') {
          depth--;
          if (depth == 0) {
            end++;
            break;
          }
        }
      }
      final String rejection = code.substring(catchIdx, end);
      expect(
          rejection.contains('noteError') ||
              rejection.contains('__hibikiWordAudioLastError'),
          true,
          reason: '$path 的 audio.play() rejection 分支必须把 DOMException 记进失败'
              '原因——删掉这一句就是 BUG-1204 的根因原样回潮');
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
    // 同样剥注释：讲根因的注释里就写着这个属性名，连注释一起扫会自我背书。
    final String src = stripLineComments(
        File('assets/popup/global_lookup_host.js').readAsStringSync());
    expect(src.contains('__hibikiWordAudioLastError'), true,
        reason: 'host 注入的 report 必须读取 realm 上的失败原因（BUG-1204）');
    // 帧未加载 / eval 失败也各有自己的原因串，不与 play() 的 DOMException 混淆。
    expect(src.contains('FrameNotLoaded'), true,
        reason: '帧未加载要有独立原因串，便于与 autoplay 拦截区分');
    expect(src.contains('PlayFunctionMissing'), true,
        reason: 'popup.js 未装载要有独立原因串');
  });

  test('app 内注入脚本同样回传失败原因', () {
    final String src = stripLineComments(
        File('lib/src/pages/implementations/dictionary_popup_webview.dart')
            .readAsStringSync());
    expect(src.contains('__hibikiWordAudioLastError'), true,
        reason: 'app 内 wordAudioPlayed 注入脚本必须一并回传原因，'
            '否则 app 内首播失败仍无法定位（BUG-1204）');
  });

  test('两端 Dart handler 都把失败原因写进日志', () {
    /// 锚到 `wordAudioPlayed` handler 之后的窗口内再找 `reason=`：这两个都是几千行的
    /// 大文件，裸 `contains('reason=')` 会被文件里任何别处的日志满足（假绿）。
    void expectReasonLoggedNearHandler(String path) {
      final String code = stripLineComments(File(path).readAsStringSync());
      // `wordAudioPlayed` 在同一文件里可能出现多次（注入脚本里的 callHandler 名 +
      // Dart 侧的 handler 注册），只要**任一**处附近记了原因即可。
      final List<int> spots = <int>[];
      for (int i = code.indexOf('wordAudioPlayed');
          i >= 0;
          i = code.indexOf('wordAudioPlayed', i + 1)) {
        spots.add(i);
      }
      expect(spots, isNotEmpty,
          reason: '$path 里找不到 wordAudioPlayed，守卫锚点失效，请同步更新本测试');
      final bool logged = spots.any((int idx) {
        final int end = idx + 1200;
        return code
            .substring(idx, end > code.length ? code.length : end)
            .contains('reason=');
      });
      expect(logged, true,
          reason: '$path 的 wordAudioPlayed handler 必须把失败原因记进日志，'
              '否则首播失败仍只是一个光秃秃的 false（BUG-1204）');
    }

    // BUG-1210：app 外的 wordAudioPlayed 处理已收口进共享 OverlayAutoRead（瞬态
    // 覆盖窗与剪贴板面板共用同一实现），故「原因落日志」这一环现在扫共享文件，
    // 而不再是 global_lookup_controller（那里只剩一行委托）。窗口锚定的严格口径
    // 保持不变。
    expectReasonLoggedNearHandler('lib/src/lookup/overlay_auto_read.dart');
    expectReasonLoggedNearHandler(
        'lib/src/pages/implementations/dictionary_popup_webview.dart');
  });
}
