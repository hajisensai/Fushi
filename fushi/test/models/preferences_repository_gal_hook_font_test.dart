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

  test('浮窗外观偏好有兼容旧观感的默认值', () {
    expect(repo.galHookTextLetterSpacing, 0);
    expect(repo.galHookTextLineHeight, 1);
    expect(repo.galHookTextBold, isTrue);
    expect(repo.galHookTextAlignment, 'center');
    expect(repo.galHookTextColor, 0xFFFFFFFF);
    expect(repo.galHookTextBackgroundColor, 0xFF000000);
    expect(repo.galHookTextBackgroundOpacity, 0);
    expect(repo.galHookTextOutlineColor, 0xE0000000);
    expect(repo.galHookTextOutlineWidth, 1.6);
    expect(repo.galHookTextPadding, 20);
    expect(repo.galHookTextCornerRadius, 14);
  });

  test('浮窗外观偏好写入后可读回', () async {
    await repo.setGalHookTextLetterSpacing(2.5);
    await repo.setGalHookTextLineHeight(1.4);
    await repo.setGalHookTextBold(false);
    await repo.setGalHookTextAlignment('left');
    await repo.setGalHookTextColor(0xFF123456);
    await repo.setGalHookTextBackgroundColor(0xFF654321);
    await repo.setGalHookTextBackgroundOpacity(0.65);
    await repo.setGalHookTextOutlineColor(0xAA010203);
    await repo.setGalHookTextOutlineWidth(2.75);
    await repo.setGalHookTextPadding(34);
    await repo.setGalHookTextCornerRadius(22);

    expect(repo.galHookTextLetterSpacing, 2.5);
    expect(repo.galHookTextLineHeight, 1.4);
    expect(repo.galHookTextBold, isFalse);
    expect(repo.galHookTextAlignment, 'left');
    expect(repo.galHookTextColor, 0xFF123456);
    expect(repo.galHookTextBackgroundColor, 0xFF654321);
    expect(repo.galHookTextBackgroundOpacity, 0.65);
    expect(repo.galHookTextOutlineColor, 0xAA010203);
    expect(repo.galHookTextOutlineWidth, 2.75);
    expect(repo.galHookTextPadding, 34);
    expect(repo.galHookTextCornerRadius, 22);
  });

  test('浮窗外观偏好的数值边界在读写两端都会收敛', () async {
    await repo.setGalHookTextLetterSpacing(999);
    await repo.setGalHookTextLineHeight(-10);
    await repo.setGalHookTextBackgroundOpacity(5);
    await repo.setGalHookTextOutlineWidth(-2);
    await repo.setGalHookTextPadding(999);
    await repo.setGalHookTextCornerRadius(999);

    expect(repo.galHookTextLetterSpacing,
        PreferencesRepository.galHookTextLetterSpacingMax);
    expect(repo.galHookTextLineHeight,
        PreferencesRepository.galHookTextLineHeightMin);
    expect(repo.galHookTextBackgroundOpacity, 1);
    expect(repo.galHookTextOutlineWidth,
        PreferencesRepository.galHookTextOutlineWidthMin);
    expect(
        repo.galHookTextPadding, PreferencesRepository.galHookTextPaddingMax);
    expect(repo.galHookTextCornerRadius,
        PreferencesRepository.galHookTextCornerRadiusMax);

    await repo.setPref('gal_hook_text_outline_width', 999.0);
    await repo.setPref('gal_hook_text_alignment', 'right');
    expect(repo.galHookTextOutlineWidth,
        PreferencesRepository.galHookTextOutlineWidthMax);
    expect(repo.galHookTextAlignment, 'center');
  });
}
