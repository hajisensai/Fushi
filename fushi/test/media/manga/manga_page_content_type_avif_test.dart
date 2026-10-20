// 在线源 / 下载 / 直读缓存都按 [mangaImageContentType] 的字节嗅探定 MIME 与扩展名。
// AVIF 以前落进 octet-stream：下载存成 `.jpg`、直读存成 `.img`、封面整张不落盘，
// WebView 拿到 image/jpeg 的 AVIF。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/mihon/online_manga_reader_session.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

Uint8List _avif(String name) => File(
      p.join('..', 'packages', 'fushi_engine', 'test', 'media',
          'image_kernels', 'fixtures', 'avif', '$name.avif'),
    ).readAsBytesSync();

void main() {
  test('AVIF（单图 / grid / alpha）嗅成 image/avif', () {
    for (final String name in <String>['rgb420', 'grid', 'rgba']) {
      expect(mangaImageContentType(_avif(name)), 'image/avif', reason: name);
    }
  });

  test('既有格式与未知字节的判定不变', () {
    expect(
      mangaImageContentType(
        Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
      ),
      'image/png',
    );
    expect(
      mangaImageContentType(
        Uint8List.fromList(img.encodeJpg(img.Image(width: 2, height: 2))),
      ),
      'image/jpeg',
    );
    expect(
      mangaImageContentType(Uint8List.fromList('<html>'.codeUnits)),
      'application/octet-stream',
    );
    // 只有 ftyp 头、品牌不是 avif 的 HEIC 不算 AVIF。
    expect(
      mangaImageContentType(
        Uint8List.fromList(<int>[0, 0, 0, 12, ...'ftypheic'.codeUnits, 0, 0, 0, 0]),
      ),
      'application/octet-stream',
    );
  });

  test('直读缓存文件名按 AVIF 取扩展名', () {
    expect(onlineMangaStreamPageFileName(0, _avif('rgb444')), 'page-000001.avif');
  });
}
