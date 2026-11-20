// 收件箱指引按 iPhone / iPad 区分（拍板台 1tOPDqYm4V）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/import_inbox_text.dart';
import 'package:fushi/src/platform/ios/ios_device_family.dart';

void main() {
  group('iosDeviceFamilyFromMachine', () {
    test('真机按 machine 前缀判', () {
      expect(iosDeviceFamilyFromMachine('iPad13,4'), IosDeviceFamily.ipad);
      expect(iosDeviceFamilyFromMachine('iPhone15,2'), IosDeviceFamily.iphone);
    });

    test('认不出的按 iPhone（iPod、空串）', () {
      expect(iosDeviceFamilyFromMachine('iPod9,1'), IosDeviceFamily.iphone);
      expect(iosDeviceFamilyFromMachine(''), IosDeviceFamily.iphone);
    });

    test('模拟器读 SIMULATOR_MODEL_IDENTIFIER，不看宿主架构', () {
      expect(
        iosDeviceFamilyFromMachine('arm64', simulatorModel: 'iPad14,3'),
        IosDeviceFamily.ipad,
      );
      expect(
        iosDeviceFamilyFromMachine('arm64', simulatorModel: 'iPhone16,1'),
        IosDeviceFamily.iphone,
      );
      expect(
        iosDeviceFamilyFromMachine('iPad13,4', simulatorModel: ''),
        IosDeviceFamily.ipad,
      );
    });

    test('非 iOS 平台固定 iPhone（不调 uname）', () {
      if (Platform.isIOS) return;
      expect(currentIosDeviceFamily, IosDeviceFamily.iphone);
    });
  });

  group('收件箱文案', () {
    setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));
    tearDown(() => LocaleSettings.setLocale(AppLocale.en));

    test('iPad 写「我的 iPad」，iPhone 写「我的 iPhone」', () {
      final String padHint = importInboxHintText(
        folder: 'Video',
        family: IosDeviceFamily.ipad,
      );
      final String phoneHint = importInboxHintText(
        folder: 'Video',
        family: IosDeviceFamily.iphone,
      );
      expect(padHint, contains('我的 iPad › Fushi › Video'));
      expect(padHint, isNot(contains('iPhone')));
      expect(phoneHint, contains('我的 iPhone › Fushi › Video'));

      final String padEmpty = importInboxEmptyText(
        folder: 'Books',
        family: IosDeviceFamily.ipad,
      );
      expect(padEmpty, contains('我的 iPad › Fushi › Books'));
      expect(padEmpty, isNot(contains('iPhone')));
      expect(
        importInboxEmptyText(folder: 'Books', family: IosDeviceFamily.iphone),
        contains('我的 iPhone › Fushi › Books'),
      );
    });

    test('每种语言的 iPad 版都不残留 iPhone', () {
      for (final AppLocale locale in AppLocale.values) {
        LocaleSettings.setLocale(locale);
        for (final String s in <String>[
          importInboxHintText(folder: 'Manga', family: IosDeviceFamily.ipad),
          importInboxEmptyText(folder: 'Manga', family: IosDeviceFamily.ipad),
        ]) {
          expect(s, contains('iPad'), reason: '${locale.languageTag}: $s');
          expect(s, isNot(contains('iPhone')), reason: '${locale.languageTag}');
        }
      }
    });
  });
}
