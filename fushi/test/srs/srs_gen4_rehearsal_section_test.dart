// 同步页「存储换代预检」一节的结论文案：本进程里预演正在跑（内核报 running）显示「预检进行中」、不给导出入口，
// 不当成「预检中途中断」；真正中途死掉的（started 残留）才是中断、可导出。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_gen4_rehearsal_section.dart';
import 'package:fushi_engine/srs/sync2/srs_gen4_rehearsal.dart';

void main() {
  test('a running rehearsal reads as running, not interrupted', () {
    final SrsGen4RehearsalVerdict running = SrsGen4RehearsalVerdict.parse(
      'running',
    );
    expect(running, SrsGen4RehearsalVerdict.running);
    expect(srsGen4RehearsalTitle(running), t.srs_gen4_rehearsal_running);
    expect(
      srsGen4RehearsalTitle(running),
      isNot(t.srs_gen4_rehearsal_interrupted),
    );
    expect(srsGen4RehearsalNeedsDiagnostics(running), isFalse);
  });

  test('a started marker left by a dead run is an exportable interruption', () {
    final SrsGen4RehearsalVerdict v = SrsGen4RehearsalVerdict.parse(
      SrsGen4RehearsalVerdict.kernelStarted,
    );
    expect(v, SrsGen4RehearsalVerdict.interrupted);
    expect(srsGen4RehearsalTitle(v), t.srs_gen4_rehearsal_interrupted);
    expect(srsGen4RehearsalNeedsDiagnostics(v), isTrue);
  });

  test('only pass and empty hide the diagnostics export among conclusions', () {
    for (final SrsGen4RehearsalVerdict v in SrsGen4RehearsalVerdict.values) {
      final bool hidden =
          v == SrsGen4RehearsalVerdict.pass ||
          v == SrsGen4RehearsalVerdict.empty ||
          v == SrsGen4RehearsalVerdict.running;
      expect(srsGen4RehearsalNeedsDiagnostics(v), !hidden, reason: v.name);
    }
  });
}
