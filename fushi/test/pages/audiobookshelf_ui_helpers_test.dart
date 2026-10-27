// Audiobookshelf 标签页的纯函数与接线守卫：副标题、单集排序、错误转人话、字幕选项排序、
// 标签页只给已启用且已登录的服务器，以及它**不**挂在 iOS 受限的「外部发现源」门里。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_subtitle_dialog.dart';
import 'package:fushi/src/pages/implementations/audiobookshelf/audiobookshelf_ui_helpers.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

AudiobookshelfItem _item({String? author, double? seconds}) =>
    AudiobookshelfItem(
      id: 'i',
      title: 'T',
      authorName: author,
      durationSeconds: seconds,
    );

AudiobookshelfEpisode _episode(String id, {int? publishedAt, int? ms}) =>
    AudiobookshelfEpisode.parse(<String, Object?>{
      'id': id,
      'title': id,
      if (publishedAt != null) 'publishedAt': publishedAt,
      'audioFile': <String, Object?>{
        'ino': id,
        'duration': (ms ?? 60000) / 1000,
      },
    }, itemId: 'pod')!;

AudiobookshelfServerConfig _server(
  String id, {
  bool enabled = true,
  bool signedIn = true,
}) => AudiobookshelfServerConfig(
  id: id,
  name: id,
  serverUrl: Uri.parse('https://$id.example.com'),
  tokens: signedIn ? const AudiobookshelfTokens(accessToken: 'a') : null,
  enabled: enabled,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('audiobookshelfCardSubtitle', () {
    test('作者 · 时长；缺的项跳过', () {
      expect(
        audiobookshelfCardSubtitle(_item(author: 'Aesop', seconds: 3725)),
        'Aesop · 1:02:05',
      );
      expect(audiobookshelfCardSubtitle(_item(author: 'Aesop')), 'Aesop');
      expect(audiobookshelfCardSubtitle(_item(seconds: 90)), '0:01:30');
      expect(audiobookshelfCardSubtitle(_item()), '');
      expect(audiobookshelfCardSubtitle(_item(seconds: 0)), '');
    });
  });

  group('单集', () {
    test('副标题：发布日期（本地）· 时长', () {
      final DateTime published = DateTime(2023, 11, 14, 12);
      final String subtitle = audiobookshelfEpisodeSubtitle(
        _episode(
          'e',
          publishedAt: published.millisecondsSinceEpoch,
          ms: 125000,
        ),
      );
      expect(subtitle, '2023-11-14 · 0:02:05');
      expect(audiobookshelfEpisodeSubtitle(_episode('e', ms: 0)), '');
    });

    test('从新到旧排；没有发布时间的排最后并保持原序', () {
      final List<String> order =
          audiobookshelfEpisodesNewestFirst(<AudiobookshelfEpisode>[
            _episode('undated1'),
            _episode('old', publishedAt: 1000),
            _episode('new', publishedAt: 3000),
            _episode('undated2'),
            _episode('mid', publishedAt: 2000),
          ]).map((AudiobookshelfEpisode e) => e.id).toList();
      expect(order, <String>['new', 'mid', 'old', 'undated1', 'undated2']);
    });
  });

  group('audiobookshelfDescribeError', () {
    ExternalProviderFailure failure(ExternalProviderFailureKind kind) =>
        ExternalProviderFailure(
          providerId: 'p',
          operation: 'o',
          kind: kind,
          message: 'raw message',
        );

    test('登录失效 / 无权限 → 能照着做的话；其余带原因', () {
      expect(
        audiobookshelfDescribeError(
          failure(ExternalProviderFailureKind.unauthorized),
        ),
        t.discovery_audiobookshelf_session_expired,
      );
      expect(
        audiobookshelfDescribeError(
          failure(ExternalProviderFailureKind.forbidden),
        ),
        t.discovery_audiobookshelf_download_forbidden,
      );
      expect(
        audiobookshelfDescribeError(
          failure(ExternalProviderFailureKind.network),
        ),
        'raw message',
      );
      expect(audiobookshelfDescribeError(StateError('boom')), contains('boom'));
    });
  });

  group('audiobookshelfTabServers', () {
    test('只留已启用且已登录的，保持原序', () {
      final List<String> ids =
          audiobookshelfTabServers(<AudiobookshelfServerConfig>[
            _server('a'),
            _server('off', enabled: false),
            _server('out', signedIn: false),
            _server('b'),
          ]).map((AudiobookshelfServerConfig s) => s.id).toList();
      expect(ids, <String>['a', 'b']);
    });

    test('一台都没有 → 空（不出标签页）', () {
      expect(
        audiobookshelfTabServers(<AudiobookshelfServerConfig>[
          _server('off', enabled: false),
          _server('out', signedIn: false),
        ]),
        isEmpty,
      );
    });
  });

  group('orderedServerSubtitles', () {
    AudiobookshelfItemDetail detail(List<String> subtitles) =>
        AudiobookshelfItemDetail.parse(<String, Object?>{
          'id': 'i',
          'media': <String, Object?>{
            'metadata': <String, Object?>{'title': 'Fables'},
            'tracks': <Object?>[
              <String, Object?>{
                'ino': '1',
                'duration': 10,
                'metadata': <String, Object?>{'filename': 'part1.mp3'},
              },
            ],
          },
          'libraryFiles': <Object?>[
            for (int i = 0; i < subtitles.length; i++)
              <String, Object?>{
                'ino': '${50 + i}',
                'fileType': 'unknown',
                'metadata': <String, Object?>{'filename': subtitles[i]},
              },
          ],
        })!;

    test('推荐的（与音频同名）排最前，其余保持原序，不重复', () {
      final List<String> names = orderedServerSubtitles(
        detail(<String>['a.srt', 'b.srt', 'part1.srt']),
      ).map((AudiobookshelfLibraryFile f) => f.filename).toList();
      expect(names, <String>['part1.srt', 'a.srt', 'b.srt']);
    });

    test('没有推荐时按原序；没有字幕为空', () {
      expect(
        orderedServerSubtitles(
          detail(<String>['a.srt', 'b.srt']),
        ).map((f) => f.filename),
        <String>['a.srt', 'b.srt'],
      );
      expect(orderedServerSubtitles(detail(<String>[])), isEmpty);
    });
  });

  group('书库页接线（源码守卫）', () {
    final String source = File(
      'lib/src/pages/implementations/home_reader_page.dart',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), '');

    test('标签页只在有可用服务器时出现，且用的是 audiobookshelf 这个 kind', () {
      expect(
        source,
        contains('if(absServers.isNotEmpty)MediaLibraryViewSpec('),
      );
      expect(source, contains('kind:MediaLibraryViewKind.audiobookshelf,'));
      expect(source, contains('audiobookshelfTabServers('));
    });

    test('它不挂在 iOS 受限的 externalDiscovery 门里（用户自己的服务器，同 Jellyfin）', () {
      final int entry = source.indexOf('if(absServers.isNotEmpty)');
      final int discover = source.indexOf(
        'if(StoreRestrictedCapability.externalDiscovery.isAvailable)',
      );
      expect(entry, greaterThan(0));
      expect(discover, greaterThan(0));
      // 发现页那一项在 ABS 之前结束：两个 if 是并列的，不是嵌套。
      final String betweenAndAfter = source.substring(discover, entry);
      expect(
        betweenAndAfter,
        contains('MediaLibraryViewKind.discover'),
        reason: '发现页的 if 先出现并先结束',
      );
      final String absEntry = source.substring(
        entry,
        source.indexOf('if(online)', entry),
      );
      expect(absEntry, isNot(contains('externalDiscovery')));
    });
  });
}
