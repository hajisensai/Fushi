// TODO-1155：桌面隐藏「音量键」相关配置。VolumeKeyChannel 是 Android-only（桌面/iOS
// 无实现），故音量键翻页开关 / 音量键句子导航两项在非 Android 上无意义，必须隐藏。
// 渲染层 buildSectionRows 走 SettingsSection.visibleCopy(isVisible) 过滤，一处 visible
// 即同时隐藏主页设置页与阅读器快捷面板投影。
//
// 守卫：① 两项都带 visible 门控（非「总是显示」）；② 门控恰为 Platform.isAndroid（源码扫描）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_listening.dart';
import 'package:hibiki/src/settings/settings_schema_manga.dart';
import 'package:hibiki/src/settings/settings_schema_reading.dart';

void main() {
  SettingsItem itemById(SettingsDestination dest, String id) {
    final List<SettingsItem> matches = dest.sections
        .expand((SettingsSection s) => s.items)
        .where((SettingsItem i) => i.id == id)
        .toList(growable: false);
    expect(matches, hasLength(1), reason: 'exactly one item with id=$id');
    return matches.single;
  }

  group('音量键三项 desktop 门控（TODO-1155）', () {
    test('reading：音量键翻页开关带 visible 门控（非总是显示）', () {
      final SettingsDestination reading = buildReadingDestination();
      expect(
        itemById(reading, 'reading_controls.volume_page_turning').visible,
        isNotNull,
        reason: '音量键翻页开关必须平台门控，桌面不显示',
      );
    });

    test('listening：音量键句子导航项带 visible 门控（非总是显示）', () {
      final SettingsDestination listening = buildListeningDestination();
      expect(
        itemById(listening, 'listening.volume_key_sentence_nav').visible,
        isNotNull,
        reason: '音量键句子导航必须平台门控，桌面不显示',
      );
    });

    test('manga：音量键翻页项带 visible 门控（非总是显示）', () {
      final SettingsDestination manga = buildMangaDestination();
      expect(
        itemById(manga, 'manga.volume_key_paging').visible,
        isNotNull,
        reason: '漫画音量键翻页开关必须平台门控，iOS/桌面不显示',
      );
    });
  });

  group('源码守卫：门控恰为 Platform.isAndroid', () {
    File readSource(String rel) {
      final File f = File(rel);
      expect(f.existsSync(), isTrue, reason: 'missing source: $rel');
      return f;
    }

    void expectAndroidGate(String src, String id) {
      final int idIdx = src.indexOf("id: '$id'");
      expect(idIdx, greaterThan(0), reason: '$id 必须存在');
      // 在该 item 定义块内（下一个 SettingsXItem 之前）出现 Android 门控。
      final int nextItem = src.indexOf('Item(', idIdx + 10);
      final String block =
          src.substring(idIdx, nextItem > 0 ? nextItem : src.length);
      expect(
        block.contains('visible: (_) => Platform.isAndroid'),
        isTrue,
        reason: '$id 的门控必须恰为 Platform.isAndroid（VolumeKeyChannel Android-only）',
      );
    }

    test('reading schema：翻页开关门控为 Platform.isAndroid + 有 dart:io import', () {
      final String src =
          readSource('lib/src/settings/settings_schema_reading.dart')
              .readAsStringSync();
      expect(src.contains("import 'dart:io'"), isTrue,
          reason: 'reading schema 需 import dart:io 用 Platform');
      expectAndroidGate(src, 'reading_controls.volume_page_turning');
    });

    test('listening schema：句子导航门控为 Platform.isAndroid', () {
      final String src =
          readSource('lib/src/settings/settings_schema_listening.dart')
              .readAsStringSync();
      expectAndroidGate(src, 'listening.volume_key_sentence_nav');
    });

    test('manga schema：翻页开关门控为 Platform.isAndroid', () {
      final String src =
          readSource('lib/src/settings/settings_schema_manga.dart')
              .readAsStringSync();
      expect(src.contains("import 'dart:io'"), isTrue);
      expectAndroidGate(src, 'manga.volume_key_paging');
    });
  });
}
