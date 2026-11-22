import 'dart:io';

import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi_engine/media/music/metadata/music_dlsite_album.dart';
import 'package:test/test.dart';

/// 与 dlsite_client_test 共用的实测 fixture。
String _fixture(String name) =>
    File('test/media/metadata/dlsite/fixtures/$name').readAsStringSync();

void main() {
  group('musicAlbumDlsiteWorkId', () {
    test('目录编号本身是作品编号时直接用', () {
      expect(
        musicAlbumDlsiteWorkId(title: '耳かき', catalogNo: 'rj01109339')?.value,
        'RJ01109339',
      );
    });

    test('专辑名里带编号', () {
      expect(
        musicAlbumDlsiteWorkId(title: '[RJ299717] ねこぐらし')?.value,
        'RJ299717',
      );
    });

    test('曲目文件夹里的编号：从文件往上找最近的一层', () {
      expect(
        musicAlbumDlsiteWorkId(
          title: '本編',
          trackPaths: <String>[
            r'D:\ASMR\RJ01109339 耳舐め\mp3\本編\01.mp3',
            r'D:\ASMR\RJ01109339 耳舐め\mp3\本編\02.mp3',
            '/mnt/asmr/RJ01109339/wav/03.wav',
          ],
        )?.value,
        'RJ01109339',
      );
    });

    test('没有编号的曲目不影响判定', () {
      expect(
        musicAlbumDlsiteWorkId(
          title: 'Disc 1',
          trackPaths: <String>['/m/RJ01109339/01.mp3', '/m/bonus/02.mp3'],
        )?.value,
        'RJ01109339',
      );
    });

    test('多首曲目给出不同编号 = 几部作品并成了一张，不猜', () {
      expect(
        musicAlbumDlsiteWorkId(
          title: 'Unknown album',
          trackPaths: <String>['/m/RJ01109339/01.mp3', '/m/RJ299717/01.mp3'],
        ),
        isNull,
      );
    });

    test('编号太靠上（超过最大层数）不算，普通音乐专辑认不出', () {
      expect(
        musicAlbumDlsiteWorkId(
          title: 'Lemon',
          trackPaths: <String>['/RJ01109339/a/b/c/d/e/01.flac'],
        ),
        isNull,
      );
      expect(
        musicAlbumDlsiteWorkId(
          title: 'Lemon',
          catalogNo: 'SECL-2270',
          trackPaths: <String>['/music/米津玄師/Lemon/01.flac'],
        ),
        isNull,
      );
    });
  });

  test('界面语言 → DLsite 请求区域', () {
    expect(dlsiteLocaleFor('zh', countryCode: 'CN'), 'zh_CN');
    expect(dlsiteLocaleFor('zh', countryCode: 'HK'), 'zh_TW');
    expect(dlsiteLocaleFor('zh'), 'zh_CN');
    expect(dlsiteLocaleFor('en'), 'en_US');
    expect(dlsiteLocaleFor('ko'), 'ko_KR');
    expect(dlsiteLocaleFor('ja'), 'ja_JP');
    expect(dlsiteLocaleFor('de'), 'ja_JP', reason: 'DLsite 没有德语，取日文原文');
  });

  group('快照编解码', () {
    final DlsiteWorkId id = DlsiteWorkId.tryParse('RJ01014447')!;

    test('原始响应体落快照后现解：作品资料 + 评分', () {
      final String raw = encodeMusicDlsiteSnapshot(
        productBody: _fixture('product_RJ01014447_zh_CN.json'),
        ratingBody: _fixture('info_RJ01014447.json'),
        locale: 'zh_CN',
      );
      final MusicDlsiteSnapshot? snap = decodeMusicDlsiteSnapshot(raw, id);
      expect(snap, isNotNull);
      expect(snap!.locale, 'zh_CN');
      final DlsiteWork work = snap.work!;
      expect(work.id, id);
      expect(work.title, isNotEmpty);
      expect(work.circle, isNotNull);
      expect(work.genres, isNotEmpty);
      expect(work.rating?.average, isNotNull);
      expect(work.rating?.downloads, isNotNull);
    });

    test('查无此作（product.json 返回空数组）也落快照：work 为 null', () {
      final MusicDlsiteSnapshot? snap = decodeMusicDlsiteSnapshot(
        encodeMusicDlsiteSnapshot(productBody: '[]', locale: 'ja_JP'),
        id,
      );
      expect(snap, isNotNull);
      expect(snap!.work, isNull);
    });

    test('没取到评分不影响主数据', () {
      final MusicDlsiteSnapshot? snap = decodeMusicDlsiteSnapshot(
        encodeMusicDlsiteSnapshot(
          productBody: _fixture('product_RJ01014447_zh_CN.json'),
          locale: 'zh_CN',
        ),
        id,
      );
      expect(snap!.work, isNotNull);
      expect(snap.work!.rating, isNull);
    });

    test('快照坏了按没取过处理', () {
      expect(decodeMusicDlsiteSnapshot('not json', id), isNull);
      expect(decodeMusicDlsiteSnapshot('[]', id), isNull);
      expect(
        decodeMusicDlsiteSnapshot('{"product":"{\\"a\\":1}"}', id),
        isNull,
        reason: 'product.json 不是数组 = 结构不对',
      );
    });
  });
}
