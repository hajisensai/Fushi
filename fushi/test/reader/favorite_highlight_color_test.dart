import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/highlight_stroke_preview.dart';
import 'package:fushi/src/reader/highlight_stroke_style.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

/// 反馈 fMicnouU6V（拍板台「做」）④：收藏句（书摘）颜色可选。
///
/// 正文早就按 `FavoriteSentence.color` 画五色（`fushi-hl-<色>`），但此前没有任何入口
/// 写非默认色，所有收藏都是黄色。现在「高亮样式 → 收藏」的色点就是新收藏的颜色
/// （持久化偏好），收藏动作把它写进收藏句。本文件钉：偏好往返与非法值回落、五色名
/// 与正文 / 预览两侧一致、收藏动作确实写入该颜色、设置页色点会持久化。
void main() {
  Future<ReaderSettings> freshSettings() async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    return settings;
  }

  test('默认黄色；选色往返；不认识的值回落到黄色', () async {
    final ReaderSettings s = await freshSettings();
    expect(s.favoriteHighlightColor, kDefaultFavoriteHighlightColor);
    expect(kDefaultFavoriteHighlightColor, 'yellow');

    await s.setFavoriteHighlightColor('blue');
    expect(s.favoriteHighlightColor, 'blue');

    await s.setFavoriteHighlightColor('turquoise');
    expect(s.favoriteHighlightColor, 'yellow');

    expect(normalizeFavoriteHighlightColor(null), 'yellow');
    expect(normalizeFavoriteHighlightColor('pink'), 'pink');
  });

  test('偏好键不与收藏笔触配置的键撞', () {
    expect(HighlightKind.favorite.prefPrefix, 'favorite_highlight');
    for (final String suffix in <String>[
      'style',
      'thickness',
      'opacity',
      'cover_ruby',
      'roughness',
      'animate',
      'underline_form',
      'underline_offset',
    ]) {
      expect(
        kFavoriteHighlightColorPrefKey,
        isNot('${HighlightKind.favorite.prefPrefix}_$suffix'),
      );
    }
  });

  test('五色名与预览色表、正文窄条层 JS 一致', () {
    expect(
      kFavoriteHighlightColors.keys.toList(),
      kFavoriteHighlightColorNames,
    );
    final String js = ReaderSelectionScripts.source();
    expect(
      js,
      contains(
        "[${kFavoriteHighlightColorNames.map((String c) => "'$c'").join(', ')}]",
      ),
    );
  });

  test('书内收藏把所选颜色写进收藏句', () {
    final String chrome = File(
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
    ).readAsStringSync();
    expect(
      chrome,
      contains('color: ReaderFushiSource.instance.favoriteHighlightColor,'),
    );
  });

  test('高亮样式页的收藏色点读写持久化偏好', () {
    final String page = File(
      'lib/src/pages/implementations/highlight_style_page.dart',
    ).readAsStringSync();
    expect(
      page,
      contains(
        'late String _favoriteColor = widget.source.favoriteHighlightColor;',
      ),
    );
    expect(page, contains('widget.source.setFavoriteHighlightColor(color)'));
    expect(page, contains('onTap: () => _selectFavoriteColor(e.key),'));
  });
}
