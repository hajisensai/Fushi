import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ImageProvider;
import 'package:fushi_core/fushi_core.dart';
import 'package:image/image.dart' as img;

import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;

import '../../ops/book_metadata_test_fixture.dart';

/// 缩略图链优先级：用户 override > 刮削层（每卷封面）> 内嵌封面；清除 override
/// （`clearOverrideValues`）连刮削层一起清。
List<int> png(int shade) => img.encodePng(
  img.Image(width: 4, height: 6)..clear(img.ColorRgb8(shade, shade, shade)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory thumbs;
  late BookMetaTestModel model;

  setUp(() async {
    BookArtStore.resetForTesting();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    thumbs = await Directory.systemTemp.createTemp('fushi_book_art_chain_');
    model = BookMetaTestModel(db, prefs, thumbs);
    MediaSource.setDatabase(db);
  });

  tearDown(() async {
    BookArtStore.resetForTesting();
    await db.close();
    if (thumbs.existsSync()) await thumbs.delete(recursive: true);
  });

  test('override > 刮削层 > 内嵌；清除 override 一并清刮削层', () async {
    await seedBook(db, '猫');
    final MediaItem item = (await ReaderFushiSource.instance
        .mediaItemForBookKey('猫'))!;
    final ReaderFushiSource source = ReaderFushiSource.instance;
    final String embedded = source.getThumbnailUri(appModel: model, item: item);

    final BookArtStore store = BookArtStore.of(thumbs);
    await store.write(
      record: const BookArtRecord(
        bookKey: '猫',
        source: 'mangabaka',
        seriesId: '1',
        seriesTitle: 'Cat',
        scrapedAt: 1,
      ),
      coverBytes: png(10),
    );
    final String scrapedPath = store.coverPathFor('猫');
    expect(source.getThumbnailUri(appModel: model, item: item), scrapedPath);
    // 编辑弹窗的「默认图」（noOverride）也显示刮削层；noScraped 才绕开。
    expect(
      source.getThumbnailUri(appModel: model, item: item, noOverride: true),
      scrapedPath,
    );
    expect(
      source.getDisplayThumbnailFromMediaItem(
        appModel: model,
        item: item,
        noScraped: true,
      ),
      isNot(
        source.getDisplayThumbnailFromMediaItem(appModel: model, item: item),
      ),
    );

    final File manual = File('${thumbs.path}/manual.png')
      ..writeAsBytesSync(png(200));
    await source.setOverrideThumbnailFromMediaItem(
      appModel: model,
      item: item,
      file: manual,
      clearOverrideImage: false,
    );
    final String overridden = source.getThumbnailUri(
      appModel: model,
      item: item,
    );
    expect(overridden, isNot(scrapedPath));
    expect(overridden, isNot(embedded));

    await source.clearOverrideValues(appModel: model, item: item);
    expect(store.hasCover('猫'), isFalse);
    expect(source.getThumbnailUri(appModel: model, item: item), embedded);
  });

  // 非默认解码宽度（统计页 / 外观预览的小封面）必须由缩略图链自己经
  // resizedFileImage 降采样：调用方若在返回值外面再包 ResizeImage，就成了
  // ResizeImage 套 ResizeImage（Flutter 断言禁止），且外层键不在
  // evictLocalCoverCache 的驱逐表里，同路径覆盖写后小封面仍画旧图。
  test('decodeWidth 透传到刮削层与 override 的 resizedFileImage', () async {
    await seedBook(db, '犬');
    final MediaItem item = (await ReaderFushiSource.instance
        .mediaItemForBookKey('犬'))!;
    final ReaderFushiSource source = ReaderFushiSource.instance;

    final BookArtStore store = BookArtStore.of(thumbs);
    await store.write(
      record: const BookArtRecord(
        bookKey: '犬',
        source: 'mangabaka',
        seriesId: '2',
        seriesTitle: 'Dog',
        scrapedAt: 1,
      ),
      coverBytes: png(30),
    );
    final ImageProvider<Object> scraped = source
        .getDisplayThumbnailFromMediaItem(
          appModel: model,
          item: item,
          decodeWidth: 160,
        );
    expect(
      scraped,
      resizedFileImage(File(store.coverPathFor('犬')), width: 160),
    );

    final File manual = File('${thumbs.path}/manual_dog.png')
      ..writeAsBytesSync(png(220));
    await source.setOverrideThumbnailFromMediaItem(
      appModel: model,
      item: item,
      file: manual,
      clearOverrideImage: false,
    );
    final String overridden = source.getThumbnailUri(
      appModel: model,
      item: item,
    );
    expect(
      source.getDisplayThumbnailFromMediaItem(
        appModel: model,
        item: item,
        decodeWidth: 160,
      ),
      resizedFileImage(File(overridden), width: 160),
    );
  });
}
