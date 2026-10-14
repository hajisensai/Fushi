import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart'
    show kAnimeSourceVideoIdPrefix;
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-3331（反馈 #Gk1hBkIV9F「扩展下载的视频没法制卡」）。
///
/// 在线视频源的集下载后保留原行身份 `anime-source:<扩展包>:<源>:<集 url>` 作
/// `bookUid`。制卡时本地文件要求带来源链接（[CardSourceLink]），而校验器把形如
/// `scheme:` 开头的 UID 一律当非法 → 「导出卡片失败：Video source identity could not
/// be verified: FormatException: Invalid library UID」。未下载的集是远端流、不带来源
/// 链接，所以照常能制卡——正是用户看到的分叉。
void main() {
  const String fingerprint =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const String animeUid =
      '${kAnimeSourceVideoIdPrefix}eu.kanade.tachiyomi.animeextension.en.demo:'
      '4242:https://example.org/watch/show-name/episode-2?lang=ja';

  CardSourceLink videoLink(String uid) => CardSourceLink(
    kind: CardSourceKind.video,
    uid: uid,
    sourceId: CardSourceLink.newSourceId(),
    episodeIndex: 0,
    startMs: 993000,
    endMs: 998000,
    fingerprint: fingerprint,
  );

  test('下载的扩展集身份能建来源链接，并经卡片 href 原样往返', () {
    final CardSourceLink link = videoLink(animeUid);
    final List<CardSourceLink> parsed = CardSourceLink.fromHtml(
      link.toHtml(),
    ).toList();
    expect(parsed, hasLength(1));
    expect(parsed.single.uid, animeUid);
    expect(parsed.single.sourceId, link.sourceId);
    expect(parsed.single.fingerprint, fingerprint);
  });

  test('路径形态的危险 UID 照旧拒绝（绝对路径 / 上跳段 / 反斜杠 / 控制字符）', () {
    for (final String bad in <String>[
      '/etc/passwd',
      'video/../secret',
      r'video\x',
      'video/\u0000x',
      '',
    ]) {
      expect(
        () => videoLink(bad),
        throwsFormatException,
        reason: '"$bad" 必须仍被拒绝',
      );
    }
  });
}
