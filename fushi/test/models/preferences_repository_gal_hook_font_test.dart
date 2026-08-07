// BUG-1095：galgame Hook 台词浮窗字号偏好（真 DB，非源码扫描）。
//
// 这个值以前不存在——native 按窗口高度对硬常量 30 做 0.9~2.5 倍缩放，于是「拖高浮窗」
// 就是「放大台词」，用户「放不下想拖高」永远拖不出更多行。现在它是独立偏好；本测试锁住
// 默认值恰好等于旧公式在默认窗高（140dip）下的实际字号（老用户观感不变）、读写两端的
// 钳位、以及历史脏数据（越界 / int / 非数字）的收敛。
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/gal_hook_text_overlay_channel.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository repo;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = PreferencesRepository(db);
    await repo.loadFromDb();
  });

  tearDown(() async {
    repo.dispose();
    await db.close();
  });

  test('默认值 = 旧公式在默认窗高下的实际字号（never break userspace）', () {
    expect(
      PreferencesRepository.galHookTextFontSizeDefault,
      kGalHookTextFontSize,
      reason: '旧公式是 30 * clamp(140/140, 0.9, 2.5) = 30；两者必须一致，'
          '否则没拖过浮窗的老用户升级后会看到字号突变',
    );
    expect(repo.galHookTextFontSize, kGalHookTextFontSize);
  });

  test('写入的值原样读回', () async {
    await repo.setGalHookTextFontSize(44);
    expect(repo.galHookTextFontSize, 44);
  });

  test('写入端按 [min, max] 钳位', () async {
    await repo.setGalHookTextFontSize(9999);
    expect(
        repo.galHookTextFontSize, PreferencesRepository.galHookTextFontSizeMax);

    await repo.setGalHookTextFontSize(-1);
    expect(
        repo.galHookTextFontSize, PreferencesRepository.galHookTextFontSizeMin);
  });

  test('读取端也钳位：绕过 setter 写进来的越界脏值不会漏出去', () async {
    await repo.setPref('gal_hook_text_font_size', 500.0);
    expect(
        repo.galHookTextFontSize, PreferencesRepository.galHookTextFontSizeMax);

    await repo.setPref('gal_hook_text_font_size', 1.0);
    expect(
        repo.galHookTextFontSize, PreferencesRepository.galHookTextFontSizeMin);
  });

  test('非 double 的历史脏值不炸：int 收下、非数字回落默认', () async {
    await repo.setPref('gal_hook_text_font_size', 36);
    expect(repo.galHookTextFontSize, 36.0);

    await repo.setPref('gal_hook_text_font_size', 'not-a-number');
    expect(
      repo.galHookTextFontSize,
      PreferencesRepository.galHookTextFontSizeDefault,
    );
  });

  test('区间自洽且默认值落在区间内', () {
    expect(
      PreferencesRepository.galHookTextFontSizeMin,
      lessThan(PreferencesRepository.galHookTextFontSizeMax),
    );
    expect(
      PreferencesRepository.galHookTextFontSizeDefault,
      inInclusiveRange(
        PreferencesRepository.galHookTextFontSizeMin,
        PreferencesRepository.galHookTextFontSizeMax,
      ),
    );
  });
}
