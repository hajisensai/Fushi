import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/popup_ui_scale.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi_core/fushi_core.dart';

/// 反馈 2jGkpD-iD6：查词弹窗独立缩放（乘在界面大小之上）。
///
/// 锁住三件事：① 取值纯函数（默认 1.0 不改观感、夹紧、非法回落）；② 它确实是弹窗
/// 内容 zoom 与顶栏缩放的输入（与界面大小相乘）；③ 偏好往返 + 随 Profile 快照走。
void expectClose(double a, double b) => expect(a, closeTo(b, 1e-9));

void main() {
  group('resolvePopupUiScale', () {
    test('默认系数 1.0 → 生效缩放就是界面大小（改动前观感不变）', () {
      for (final double ui in <double>[0.8, 1.0, 1.25, 2.0]) {
        expectClose(
          resolvePopupUiScale(
            appUiScale: ui,
            popupScaleFactor: kPopupUiScaleDefault,
          ),
          ui,
        );
      }
    });

    test('系数乘在界面大小之上', () {
      expectClose(
        resolvePopupUiScale(appUiScale: 1.5, popupScaleFactor: 0.7),
        1.05,
      );
      expectClose(
        resolvePopupUiScale(appUiScale: 1.0, popupScaleFactor: 1.6),
        1.6,
      );
    });

    test('系数夹进 [0.5, 2.0]', () {
      expectClose(
        resolvePopupUiScale(appUiScale: 1.0, popupScaleFactor: 0.1),
        kPopupUiScaleMin,
      );
      expectClose(
        resolvePopupUiScale(appUiScale: 1.0, popupScaleFactor: 9),
        kPopupUiScaleMax,
      );
    });

    test('非法系数 / 非法界面大小回落 1.0', () {
      expectClose(
        resolvePopupUiScale(appUiScale: 1.2, popupScaleFactor: double.nan),
        1.2,
      );
      expectClose(
        resolvePopupUiScale(appUiScale: 1.2, popupScaleFactor: -1),
        1.2,
      );
      expectClose(
        resolvePopupUiScale(appUiScale: double.infinity, popupScaleFactor: 0.8),
        0.8,
      );
      expectClose(
        resolvePopupUiScale(appUiScale: 0, popupScaleFactor: 0.8),
        0.8,
      );
    });

    test('滑条档数与 0.05 步进一致', () {
      expectClose(
        (kPopupUiScaleMax - kPopupUiScaleMin) / kPopupUiScaleDivisions,
        0.05,
      );
    });
  });

  group('弹窗生效缩放驱动内容 zoom 与顶栏缩放', () {
    test('内容 zoom = 界面大小 × 弹窗系数 × 字号/16', () {
      final double scale = resolvePopupUiScale(
        appUiScale: 1.5,
        popupScaleFactor: 0.6,
      );
      expectClose(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: scale,
          dictionaryFontSize: 20,
        ),
        1.5 * 0.6 * 20 / 16,
      );
    });

    test('界面放大、弹窗系数缩回 → 弹窗内容回到 100%', () {
      final double scale = resolvePopupUiScale(
        appUiScale: 1.6,
        popupScaleFactor: 0.625,
      );
      expectClose(
        DictionaryPopupWebViewState.popupContentZoom(
          appUiScale: scale,
          dictionaryFontSize: 16,
        ),
        1.0,
      );
      expectClose(
        dictionaryPopupTopBarScale(appUiScale: scale, dictionaryFontSize: 16),
        1.0,
      );
    });

    test('顶栏跟随弹窗系数（仍受 [0.8, 1.5] 夹紧）', () {
      expectClose(
        dictionaryPopupTopBarScale(
          appUiScale: resolvePopupUiScale(
            appUiScale: 1.0,
            popupScaleFactor: 1.2,
          ),
          dictionaryFontSize: 16,
        ),
        1.2,
      );
      expectClose(
        dictionaryPopupTopBarScale(
          appUiScale: resolvePopupUiScale(
            appUiScale: 1.0,
            popupScaleFactor: 0.5,
          ),
          dictionaryFontSize: 16,
        ),
        0.8,
      );
    });
  });

  group('偏好 popup_ui_scale', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('已登记键、随 Profile 快照走（不是设备本地）', () {
      expect(kKnownPreferenceKeys, contains('popup_ui_scale'));
      expect(ProfileKeys.isExcludedPref('popup_ui_scale'), isFalse);
    });

    test('默认 1.0', () {
      expect(repo.popupUiScale, kPopupUiScaleDefault);
    });

    test('写入后读回，并持久化到 DB（重新加载仍在）', () async {
      await repo.setPopupUiScale(0.75);
      expect(repo.popupUiScale, 0.75);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      expect(reloaded.popupUiScale, 0.75);
      reloaded.dispose();
    });

    test('写入越界值被夹紧', () async {
      await repo.setPopupUiScale(5);
      expect(repo.popupUiScale, kPopupUiScaleMax);
      await repo.setPopupUiScale(0.01);
      expect(repo.popupUiScale, kPopupUiScaleMin);
    });

    test('写入通知监听者（已开弹窗据此重注入）', () async {
      int notified = 0;
      repo.addListener(() => notified++);
      await repo.setPopupUiScale(1.25);
      expect(notified, greaterThan(0));
    });
  });
}
