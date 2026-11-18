import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/metadata/book_art/book_art_plan.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_models.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

MangaBakaImage _img(
  int id,
  num index, {
  String type = 'volume',
  String language = 'ja',
  String rating = 'safe',
  String? note,
  int width = 1000,
  int height = 1500,
  String format = 'jpeg',
  int? size,
}) => MangaBakaImage(
  id: id,
  index: '$index',
  indexNumeric: index,
  type: type,
  language: language,
  note: note,
  contentRating: rating,
  raw: MangaBakaRawImage(
    url: 'https://images.mangabaka.dev/$id',
    width: width,
    height: height,
    format: format,
    size: size,
  ),
);

void main() {
  test('真实图片页：只取 ja 卷封面，suggestive / 其他语言 / 封底不入选', () {
    final List<MangaBakaImage> images = parseMangaBakaImagesPage(
      File(
        'test/fixtures/mangabaka/mb_images_yagakimi_p1.json',
      ).readAsStringSync(),
    ).items;
    final Map<num, MangaBakaImage> picked = pickMangaBakaVolumeImages(images);
    expect(picked.keys.toSet(), <num>{1, 2, 3});
    for (final MangaBakaImage i in picked.values) {
      expect(i.language, 'ja');
      expect(i.type, 'volume');
    }
    expect(picked[1]!.raw.width, 1800);
  });

  test('同卷多张：safe 优先于 suggestive，常规版优先于变体，最后比面积', () {
    final Map<num, MangaBakaImage> picked =
        pickMangaBakaVolumeImages(<MangaBakaImage>[
          _img(1, 1, rating: 'suggestive', width: 4000, height: 6000),
          _img(2, 1, note: '特装版', width: 3000, height: 4500),
          _img(3, 1, width: 1200, height: 1800),
          _img(4, 1, width: 1100, height: 1700),
          _img(5, 2, rating: 'suggestive'),
          _img(6, 3, rating: 'erotica'),
          _img(7, 4, format: 'gif'),
          _img(8, 5, size: 50 * 1024 * 1024),
        ]);
    expect(picked[1]!.id, 3);
    expect(picked[2]!.id, 5, reason: '没有 safe 时用 suggestive');
    expect(picked.containsKey(3), isFalse);
    expect(picked.containsKey(4), isFalse);
    expect(picked.containsKey(5), isFalse);
  });

  group('chooseBookArtVolume', () {
    const BookArtImageOption mb = BookArtImageOption(
      source: BookArtSource.mangabaka,
      url: 'mb',
      width: 1800,
      height: 2560,
    );
    const BookArtImageOption bgm = BookArtImageOption(
      source: BookArtSource.bangumi,
      url: 'bgm',
      width: 912,
      height: 1440,
    );

    test('MangaBaka 更大 → MangaBaka；Bangumi 更大 → Bangumi；面积相同选 MangaBaka', () {
      expect(chooseBookArtVolume(mangaBaka: mb, bangumi: bgm).option, mb);
      const BookArtImageOption bigBgm = BookArtImageOption(
        source: BookArtSource.bangumi,
        url: 'big',
        width: 2000,
        height: 3000,
      );
      expect(
        chooseBookArtVolume(mangaBaka: mb, bangumi: bigBgm).option,
        bigBgm,
      );
      expect(
        chooseBookArtVolume(
          mangaBaka: mb,
          bangumi: mb.withSize(1800, 2560),
        ).option!.source,
        BookArtSource.mangabaka,
      );
    });

    test('MangaBaka 缺卷时回落 Bangumi（尺寸未知也用）', () {
      const BookArtImageOption unsized = BookArtImageOption(
        source: BookArtSource.bangumi,
        url: 'u',
      );
      final BookArtVolumeChoice c = chooseBookArtVolume(bangumi: unsized);
      expect(c.outcome, BookArtVolumeOutcome.write);
      expect(c.option, unsized);
    });

    test('本地更清晰（不到 1.2 倍）保留本地；尺寸未知且本地有图也不写', () {
      expect(
        chooseBookArtVolume(mangaBaka: mb, localArea: 1800 * 2560).outcome,
        BookArtVolumeOutcome.localSharper,
      );
      expect(
        chooseBookArtVolume(mangaBaka: mb, localArea: 600 * 900).outcome,
        BookArtVolumeOutcome.write,
      );
      expect(
        chooseBookArtVolume(
          bangumi: const BookArtImageOption(
            source: BookArtSource.bangumi,
            url: 'u',
          ),
          localArea: 600 * 900,
        ).outcome,
        BookArtVolumeOutcome.localSharper,
      );
    });

    test('两边都没有 → noCandidate', () {
      expect(chooseBookArtVolume().outcome, BookArtVolumeOutcome.noCandidate);
    });

    test('只有 MangaBaka 缺卷或短边 < 1000 才量 Bangumi', () {
      expect(bookArtNeedsBangumiProbe(null), isTrue);
      expect(bookArtNeedsBangumiProbe(mb), isFalse);
      expect(bookArtNeedsBangumiProbe(mb.withSize(800, 1200)), isTrue);
    });
  });

  test('横幅：宽高比 ≥1.6 的里取面积最大，竖图与成人向不要', () {
    final BookArtImageOption? banner = pickMangaBakaBanner(<MangaBakaImage>[
      _img(1, 1, type: 'banner', width: 800, height: 450, note: 'Kadocomi'),
      _img(2, 1, type: 'banner', width: 2000, height: 800),
      _img(3, 1, type: 'banner', width: 3000, height: 3000),
      _img(4, 1, type: 'banner', width: 4000, height: 1600, rating: 'erotica'),
      _img(5, 1, width: 5000, height: 2000),
    ]);
    expect(banner!.url, 'https://images.mangabaka.dev/2');
    expect(pickMangaBakaBanner(const <MangaBakaImage>[]), isNull);
  });

  test('从文件头读宽高（PNG / JPEG），非图片为 null', () {
    final Uint8List png = img.encodePng(img.Image(width: 30, height: 20));
    expect(bookArtImageDimensions(png), (width: 30, height: 20));
    final Uint8List jpg = img.encodeJpg(img.Image(width: 12, height: 34));
    expect(bookArtImageDimensions(jpg), (width: 12, height: 34));
    expect(bookArtImageDimensions(<int>[1, 2, 3]), isNull);
  });

  test('大 PNG 只给文件头也能量出尺寸（IHDR 固定偏移）', () {
    // 带噪点的 PNG，压缩后远大于 256 KB 的那类图只截前 64 字节也要量得出。
    final img.Image noisy = img.Image(width: 1600, height: 2400);
    final Uint8List png = img.encodePng(noisy);
    expect(bookArtImageDimensions(png.sublist(0, 64)), (
      width: 1600,
      height: 2400,
    ));
  });

  group('chooseBookArtVolume 的高清闸', () {
    const BookArtImageOption mb = BookArtImageOption(
      source: BookArtSource.mangabaka,
      url: 'mb',
      width: 1000,
      height: 1500,
    );
    const BookArtImageOption bgm = BookArtImageOption(
      source: BookArtSource.bangumi,
      url: 'bgm',
      width: 400,
      height: 600,
    );

    test('刮削层已有的同系列那张不比候选小 → kept（不降清晰度）', () {
      expect(
        chooseBookArtVolume(bangumi: bgm, keptArea: 1000 * 1500).outcome,
        BookArtVolumeOutcome.kept,
      );
      expect(
        chooseBookArtVolume(mangaBaka: mb, keptArea: 1000 * 1500).outcome,
        BookArtVolumeOutcome.kept,
      );
      expect(
        chooseBookArtVolume(mangaBaka: mb, keptArea: 400 * 600).outcome,
        BookArtVolumeOutcome.write,
      );
    });

    test('本地有封面但量不出尺寸 → localSharper，不当成没有封面', () {
      expect(
        chooseBookArtVolume(mangaBaka: mb, localUnmeasured: true).outcome,
        BookArtVolumeOutcome.localSharper,
      );
      expect(
        chooseBookArtVolume(mangaBaka: mb).outcome,
        BookArtVolumeOutcome.write,
      );
    });
  });
}
