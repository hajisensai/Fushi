import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/remote_audio_lookup_bytes.dart';
import 'package:hibiki/src/utils/misc/audio_mime.dart';
import 'package:hibiki/src/utils/misc/lookup_audio_playback.dart';
import 'package:hibiki_core/hibiki_core.dart' show kMimeTypeByExtension;

/// 单词音频 MIME 共享表（audio_mime.dart）守卫：
///  1. 两个消费端（弹窗 `data:` URL / 127.0.0.1 音频端点）映射恒同、只差兜底——
///     此前两份 switch 副本在 `.opus`（audio/ogg vs audio/opus）与兜底
///     （audio/mpeg vs octet-stream）上静默漂移。
///  2. 与 hibiki_core 通用表 `kMimeTypeByExtension` 的刻意分歧集合锁定：除
///     {mp4, aac, webm}（音频语境收窄）外，两表交集必须逐项一致。
void main() {
  group('kAudioMimeByExtension 表自身不变式', () {
    test('key 全小写、不含点；value 形如 audio/subtype', () {
      final RegExp valueRe = RegExp(r'^audio/[a-z0-9.+-]+$');
      kAudioMimeByExtension.forEach((String ext, String mime) {
        expect(ext, ext.toLowerCase(), reason: 'key 必须小写：$ext');
        expect(ext.contains('.'), isFalse, reason: 'key 不含点：$ext');
        expect(valueRe.hasMatch(mime), isTrue, reason: '非 audio MIME：$mime');
      });
    });

    test('.opus 按 RFC 7845 = audio/ogg（audio/opus 是 RTP 类型，不用于文件）', () {
      expect(kAudioMimeByExtension['opus'], 'audio/ogg');
    });
  });

  group('两个消费端共用同一张表（防再漂移）', () {
    test('表内每个扩展名两侧推断一致', () {
      for (final MapEntry<String, String> e in kAudioMimeByExtension.entries) {
        expect(audioMimeForPath('f.${e.key}'), e.value,
            reason: 'data: URL 侧 .${e.key} 偏离共享表');
        expect(remoteAudioContentTypeForPath('f.${e.key}'), e.value,
            reason: 'HTTP 端点侧 .${e.key} 偏离共享表');
      }
    });

    test('兜底是刻意的消费端差异：data: URL 必须给定 audio/*，HTTP 端点诚实报未知', () {
      expect(audioMimeForPath('f.xyz'), 'audio/mpeg');
      expect(
          remoteAudioContentTypeForPath('f.xyz'), 'application/octet-stream');
      expect(audioMimeForPath('noext'), 'audio/mpeg');
      expect(
          remoteAudioContentTypeForPath('noext'), 'application/octet-stream');
    });
  });

  group('与 hibiki_core 通用表 kMimeTypeByExtension 的一致性', () {
    // 音频语境刻意收窄的扩展名（通用表按容器给 video/* 或 audio/aac；单词音频
    // 解析出的这些文件一定是音频轨，给 audio/mp4 / audio/webm 让 <audio> 选对
    // 解码器）。改动任一侧前先读 audio_mime.dart 库注释。
    const Set<String> intentionalDivergence = <String>{'mp4', 'aac', 'webm'};

    test('分歧集合外的交集逐项一致', () {
      for (final MapEntry<String, String> e in kAudioMimeByExtension.entries) {
        final String? general = kMimeTypeByExtension[e.key];
        if (general == null || intentionalDivergence.contains(e.key)) continue;
        expect(e.value, general, reason: '.${e.key} 与通用表漂移且未登记进刻意分歧集合');
      }
    });

    test('分歧集合内确实存在分歧（防集合腐化成免检白名单）', () {
      for (final String ext in intentionalDivergence) {
        expect(kAudioMimeByExtension.containsKey(ext), isTrue,
            reason: '.$ext 已不在音频表内，请从分歧集合移除');
        expect(kAudioMimeByExtension[ext], isNot(kMimeTypeByExtension[ext]),
            reason: '.$ext 两表已一致，请从分歧集合移除');
      }
    });
  });
}
