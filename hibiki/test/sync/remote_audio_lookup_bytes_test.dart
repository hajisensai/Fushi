import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_remote_lookup_service.dart';
import 'package:hibiki/src/sync/remote_audio_lookup_bytes.dart';

/// TODO-1335 ②：扩展/远端查词弹窗单词音频。守两点：
///  1. `remoteAudioLookupFromResolvedUrl` 把 `resolveLookupAudioUrl` 的解析结果（本地路径 /
///     远程 http(s) URL / null）正确归一成字节（远程走 download、本地走 read、缺则 null）。
///  2. server 端 `_AppModelRemoteLookupService.lookupAudio` 走全源 `resolveLookupAudioUrl`，
///     不再只查本地音频库（回归守卫：仅配远程发音源的用户过去恒无单词音频）。
void main() {
  group('remoteAudioLookupFromResolvedUrl 分支', () {
    Future<RemoteAudioLookup?> neverDownload(Uri uri) async {
      fail('远程下载不应被调用: $uri');
    }

    Future<Uint8List?> neverLocal(String path) async {
      fail('本地读取不应被调用: $path');
    }

    test('null / 空 → null（不下载不读文件）', () async {
      expect(
        await remoteAudioLookupFromResolvedUrl(null,
            downloadRemote: neverDownload, loadLocalFile: neverLocal),
        isNull,
      );
      expect(
        await remoteAudioLookupFromResolvedUrl('',
            downloadRemote: neverDownload, loadLocalFile: neverLocal),
        isNull,
      );
    });

    test('远程 http(s) URL → 走 downloadRemote 并回传其结果', () async {
      final List<Uri> downloaded = <Uri>[];
      final RemoteAudioLookup out = RemoteAudioLookup(
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        contentType: 'audio/mpeg',
      );
      final RemoteAudioLookup? r = await remoteAudioLookupFromResolvedUrl(
        'https://forvo.com/audio/hashiru.mp3',
        downloadRemote: (Uri uri) async {
          downloaded.add(uri);
          return out;
        },
        loadLocalFile: neverLocal,
      );
      expect(r, same(out));
      expect(downloaded.single.host, 'forvo.com');
    });

    test('本地路径（无 scheme）→ 走 loadLocalFile + 扩展名推 content-type', () async {
      final List<String> read = <String>[];
      final RemoteAudioLookup? r = await remoteAudioLookupFromResolvedUrl(
        '/tmp/dict/走る.m4a',
        downloadRemote: neverDownload,
        loadLocalFile: (String path) async {
          read.add(path);
          return Uint8List.fromList(<int>[9, 9]);
        },
      );
      expect(read.single, '/tmp/dict/走る.m4a');
      expect(r, isNotNull);
      expect(r!.contentType, 'audio/mp4');
      expect(r.bytes, <int>[9, 9]);
    });

    test('file:// URI → 转本地路径读取', () async {
      final List<String> read = <String>[];
      final String fileUrl = Uri.file('/tmp/a.mp3').toString();
      final RemoteAudioLookup? r = await remoteAudioLookupFromResolvedUrl(
        fileUrl,
        downloadRemote: neverDownload,
        loadLocalFile: (String path) async {
          read.add(path);
          return Uint8List.fromList(<int>[7]);
        },
      );
      expect(read.single.endsWith('a.mp3'), isTrue,
          reason: 'file:// 应转成本地路径: ${read.single}');
      expect(r?.contentType, 'audio/mpeg');
    });

    test('本地读取返回 null / 空字节 → null', () async {
      expect(
        await remoteAudioLookupFromResolvedUrl('/tmp/x.mp3',
            downloadRemote: neverDownload,
            loadLocalFile: (String _) async => null),
        isNull,
      );
      expect(
        await remoteAudioLookupFromResolvedUrl('/tmp/x.mp3',
            downloadRemote: neverDownload,
            loadLocalFile: (String _) async => Uint8List(0)),
        isNull,
      );
    });
  });

  group('content-type 推断', () {
    test('按扩展名（含未知回退）', () {
      expect(remoteAudioContentTypeForPath('a.mp3'), 'audio/mpeg');
      expect(remoteAudioContentTypeForPath('a.M4A'), 'audio/mp4');
      expect(remoteAudioContentTypeForPath('a.m4b'), 'audio/mp4');
      expect(remoteAudioContentTypeForPath('a.ogg'), 'audio/ogg');
      // RFC 7845：Ogg Opus 文件的注册类型是 audio/ogg（audio/opus 是 RTP 载荷
      // 类型，不用于文件）；与弹窗 data: URL 侧（audioMimeForPath）同表同值。
      expect(remoteAudioContentTypeForPath('a.opus'), 'audio/ogg');
      expect(remoteAudioContentTypeForPath('a.wav'), 'audio/wav');
      expect(remoteAudioContentTypeForPath('a.flac'), 'audio/flac');
      expect(
          remoteAudioContentTypeForPath('a.bin'), 'application/octet-stream');
      expect(
          remoteAudioContentTypeForPath('noext'), 'application/octet-stream');
    });

    test('响应头优先 audio/*（去参数），缺失/非音频回退路径扩展名', () {
      final Uri u = Uri.parse('https://h/x.mp3?id=abc');
      expect(
        remoteAudioContentTypeFromResponse(u, 'audio/ogg; charset=binary'),
        'audio/ogg',
      );
      // 非 audio/* 头（如误配 octet-stream）→ 回退按 URL 路径扩展名。
      expect(
        remoteAudioContentTypeFromResponse(u, 'application/octet-stream'),
        'audio/mpeg',
      );
      // 头缺失 → 路径扩展名。
      expect(remoteAudioContentTypeFromResponse(u, null), 'audio/mpeg');
    });
  });

  group('回归守卫：server 音频路径走全源解析（非只查本地库）', () {
    test('app_model.lookupAudio 复用 resolveLookupAudioUrl', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      // 定位 lookupAudio 覆盖实现，断言它经 resolveLookupAudioUrl（全源）解析。
      final int idx = src.indexOf('Future<RemoteAudioLookup?> lookupAudio({');
      expect(idx, greaterThanOrEqualTo(0), reason: '未找到 lookupAudio 实现');
      final String body = src.substring(idx, idx + 800);
      expect(body.contains('resolveLookupAudioUrl('), isTrue,
          reason: 'lookupAudio 未走全源 resolveLookupAudioUrl（回退成只查本地库？）');
      expect(body.contains('remoteAudioLookupFromResolvedUrl('), isTrue,
          reason: 'lookupAudio 未经 remoteAudioLookupFromResolvedUrl 归一字节');
    });
  });
}
