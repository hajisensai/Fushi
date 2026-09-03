// BUG-2069 审查 B3 源码守卫：**制卡编排里那一段接线**。
//
// 「动图抓够整句」这条修复由三段接线组成：① 采样循环消费预算、② 资源音频把
// `durationMs` 写回行条目、③ 编排把「本句音频时长」作为异步目标喂给采样循环。
// ①② 有行为级测试（`gal_window_gif_duration_wiring_test.dart` /
// `gal_hook_session_controller_test.dart`）；③ 结构上测不到——`_captureGifUsesDefault`
// 只有在**不注入**捕获器时才为真，而注入捕获器正是所有编排测试构造替身的方式，
// 于是生产分支在测试里永远不执行（编排源码里的注释自己说明了这点）。
//
// 整行删掉 `targetDuration:` 此前 100% 静默存活。这里在源码层钉死它，并且钉的是
// 「实参来自本句音频时长」而不只是「有这个参数名」——传个常量同样得红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  test('编排的生产动图路径必须把本句语音时长喂给采样循环', () {
    final String src = File(
      'lib/src/mining/gal_hook_mining_coordinator.dart',
    ).readAsStringSync();

    // 生产分支（未注入捕获器）直接调 captureWindowGifBytes；替身分支走 _captureGif。
    // 必须从 `_captureGifUsesDefault` 那个分支往后找：文件里更靠前的那处
    // `captureWindowGifBytes(` 是 `_defaultCaptureGif` 的二参数适配，本来就没有时长。
    final String body = maskComments(src);
    final int branch = body.indexOf('if (_captureGifUsesDefault)');
    expect(branch, greaterThan(0), reason: '生产/替身分流点消失了，守卫的锚点已失效');
    const String anchor = 'captureWindowGifBytes(';
    final int callStart = body.indexOf(anchor, branch);
    expect(callStart, greaterThan(branch));
    final EnclosingCall call = enclosingCall(src, callStart + anchor.length);
    expect(
      call.text,
      contains('targetDuration:'),
      reason: '生产动图捕获必须带上整句时长目标，否则动图恒为 1.25 s 旧行为',
    );

    final List<String> values = namedArgumentValues(src, 'targetDuration');
    expect(values, isNotEmpty);
    // 实参必须是那个从音频 Future 派生的变量，而不是常量/null。
    final String argument = values.single.trim();
    expect(argument, 'targetDuration');

    // 该变量的来源：等音频字节回来后，从行条目读 audioDurationMs。三样缺一不可，
    // 少了 audioFuture 就是没等音频、少了 audioDurationMs 就是没读时长。
    final int declaration =
        body.indexOf('final Future<Duration?> targetDuration');
    expect(declaration, greaterThan(0),
        reason: 'targetDuration 必须由音频 Future 派生，不能是外部传入的任意值');
    final String derivation = body.substring(
      declaration,
      body.indexOf(anchor, declaration),
    );
    expect(derivation, contains('audioFuture'));
    expect(derivation, contains('audioDurationMs'));
  });
}
