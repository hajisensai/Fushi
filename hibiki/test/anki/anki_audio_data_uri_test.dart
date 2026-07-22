import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// BUG-1004 断点A 守卫：本地音频源经 `resolveWordAudio` 转成的 `data:<mime>;base64,…` URL
/// （供 WebView `<audio>` 播放）在**落卡**侧必须被识别为 [AnkiAudioRefKind.dataUri] 并解码成
/// 真实媒体字节——旧 `classify` 把 data: 当本地文件路径（`File('data:...')` 不存在）而静默丢，
/// 导致「能试听、卡里空」的不对称。
void main() {
  group('AnkiAudioRef.classify', () {
    test('data: URL → dataUri（不再误落 localFile）', () {
      const String ref = 'data:audio/mpeg;base64,SGVsbG8=';
      expect(AnkiAudioRef.classify(ref), AnkiAudioRefKind.dataUri);
    });
    test('http(s) / 本地路径 / 空 分类不变（Never break userspace）', () {
      expect(AnkiAudioRef.classify('https://forvo.example/w.mp3'),
          AnkiAudioRefKind.remoteUrl);
      expect(AnkiAudioRef.classify('/data/user/0/x/word.mp3'),
          AnkiAudioRefKind.localFile);
      expect(AnkiAudioRef.classify('C:\\audio\\word.mp3'),
          AnkiAudioRefKind.localFile);
      expect(AnkiAudioRef.classify(''), AnkiAudioRefKind.empty);
    });
  });

  group('AnkiAudioRef.decodeDataUri', () {
    test('解出 base64 字节 + 按 MIME 推断扩展名', () {
      final List<int> bytes = <int>[1, 2, 3, 4, 250];
      final String ref = 'data:audio/mpeg;base64,${base64Encode(bytes)}';
      final decoded = AnkiAudioRef.decodeDataUri(ref);
      expect(decoded, isNotNull);
      expect(decoded!.bytes, bytes);
      expect(decoded.ext, 'mp3');
    });
    test('opus/ogg MIME → ogg 扩展名', () {
      final String ref = 'data:audio/ogg;base64,${base64Encode(<int>[9, 9])}';
      expect(AnkiAudioRef.decodeDataUri(ref)?.ext, 'ogg');
    });
    test('空体 / 畸形 / 非 data: → null', () {
      expect(AnkiAudioRef.decodeDataUri('data:audio/mpeg;base64,'), isNull);
      expect(AnkiAudioRef.decodeDataUri('not-a-data-uri'), isNull);
      expect(AnkiAudioRef.decodeDataUri(''), isNull);
    });
  });

  group('AnkiAudioRef.audioExtForMime', () {
    test('常见音频 MIME 映射；未知回退 mp3', () {
      expect(AnkiAudioRef.audioExtForMime('audio/mpeg'), 'mp3');
      expect(AnkiAudioRef.audioExtForMime('audio/mp4'), 'm4a');
      expect(AnkiAudioRef.audioExtForMime('audio/aac'), 'm4a');
      expect(AnkiAudioRef.audioExtForMime('audio/wav'), 'wav');
      expect(AnkiAudioRef.audioExtForMime('audio/flac'), 'flac');
      expect(AnkiAudioRef.audioExtForMime('application/octet-stream'), 'mp3');
    });
  });
}
