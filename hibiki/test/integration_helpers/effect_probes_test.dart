import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

import '../../integration_test/helpers/effect_probes.dart';

void main() {
  test('readerCssProbe detects a font-size change taking effect', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    final ReaderCssEffectProbe probe = ReaderCssEffectProbe(() => settings);

    final EffectSnapshot before = probe.capture();
    await settings.setFontSize(40); // 默认 22 → 40
    final EffectSnapshot after = probe.capture();

    final EffectVerdict verdict = probe.compare(before, after);
    expect(verdict.changed, isTrue, reason: 'CSS 输出必须随字号变化');
    // ReaderSettings.fontSize 是 double，CSS 行渲染为 `font-size: 40.0px`，
    // 故证据含 `40.0px`（忠实反映真实渲染输入，不做任何规整/伪造）。
    expect(verdict.evidence, contains('40.0px'),
        reason: '生效证据必须含新值 40.0px（渲染输入真的变了）');
    expect(probe.kind, EffectTier.t1RenderInput);
  });

  test('readerCssProbe reports unchanged when nothing changes', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    final ReaderCssEffectProbe probe = ReaderCssEffectProbe(() => settings);
    final EffectSnapshot a = probe.capture();
    final EffectSnapshot b = probe.capture();
    expect(probe.compare(a, b).changed, isFalse);
  });
}
