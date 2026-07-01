import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫（TODO-148/BUG-215 ②）：连按快进/跳句时控制条自动隐藏计时不续命。
///
/// 根因=[_pokeControlsVisible] 每次都把合成 hover 派发到控制条**固定中心点**，
/// Flutter `MouseTracker` 对「同一设备落同一坐标」的连续 hover 去重 → 第二次起
/// media_kit 的 `MouseRegion.onHover` 不再触发、隐藏 `Timer` 不重置，控制条仍只
/// 活 2 秒就消失。修复=每次派发把 x 坐标 ±1px 抖动（[_pokeParity] 翻转），使坐标
/// 始终变化、强制每次都回调 onHover 续命。
///
/// media_kit headless 不可跑视频 widget（无 native player / 无 hover 管线 / 无
/// MouseTracker 去重），故在源码层钉死「合成 hover 位置每次抖动、不再用固定
/// center」契约，防回归把抖动删回固定坐标。
void main() {
  late String src;

  setUpAll(() {
    src = readVideoHibikiSource();
  });

  test('存在 _pokeParity 抖动开关字段', () {
    expect(src.contains('bool _pokeParity = false;'), isTrue,
        reason: '必须有合成 hover 位置抖动开关字段（TODO-148/BUG-215）');
  });

  /// 取 _pokeControlsVisible 方法体：从其签名到下一成员 _dispatchPokeHover 声明。
  /// 旧实现用固定 1200 字窗，但 TODO-1059（平台无关门控前置）+ BUG-425（派发拆到
  /// _dispatchPokeHover 微任务）把方法体撑过 1200 字，pokePosition/派发落到窗外 →
  /// 守卫误报。改按真实后继成员切片，抖动续命契约不变。
  String pokeBody() {
    final int at = src.indexOf('void _pokeControlsVisible()');
    expect(at, greaterThanOrEqualTo(0), reason: '缺 _pokeControlsVisible 助手');
    final int end = src.indexOf('void _dispatchPokeHover', at);
    expect(end, greaterThan(at), reason: '缺 _dispatchPokeHover（方法体终点锚）');
    return src.substring(at, end);
  }

  test('每次 poke 翻转 _pokeParity 并据此 ±1px 偏移合成 hover 位置', () {
    final String body = pokeBody();
    expect(body.contains('_pokeParity = !_pokeParity;'), isTrue,
        reason: 'poke 必须翻转 _pokeParity，使每次派发坐标都不同');
    expect(
      RegExp(r'_pokeParity \? 1\.0 : -1\.0').hasMatch(body),
      isTrue,
      reason: 'poke 必须据 _pokeParity 把 x 坐标 ±1px 偏移（绕开 MouseTracker 同坐标去重）',
    );
  });

  test('合成 hover 派发用抖动后的位置，而非固定 center', () {
    final String body = pokeBody();
    // 抖动后的位置变量喂给 PointerHoverEvent，而不是直接 position: center。
    expect(body.contains('Offset pokePosition ='), isTrue,
        reason: '必须先算出抖动后的 pokePosition');
    expect(
      RegExp(r'PointerHoverEvent\(\s*position: pokePosition,').hasMatch(body),
      isTrue,
      reason: '派发的 hover 必须用抖动后的 pokePosition（不是固定 center → 会被去重）',
    );
    expect(
      RegExp(r'PointerHoverEvent\(\s*position: center,').hasMatch(body),
      isFalse,
      reason: '不得回退用固定 center 派发（会触发 MouseTracker 同坐标去重，回归 BUG-215）',
    );
  });
}
