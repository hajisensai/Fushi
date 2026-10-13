import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// [RemoteDictionaryPopupResources]：结果来自电脑时弹框的样式 / 媒体 / 发音缓存规则。
void main() {
  DictionarySearchResult resultFrom(List<String> dictionaries) =>
      DictionarySearchResult(
        searchTerm: '猫',
        entries: <DictionaryEntry>[
          for (final String name in dictionaries)
            DictionaryEntry(word: '猫', reading: 'ねこ', dictionaryName: name),
        ],
      );

  test(
    'styles are fetched once, then only for dictionaries never seen',
    () async {
      int fetches = 0;
      Map<String, String> remote = <String, String>{'明鏡': '.a{}'};
      final RemoteDictionaryPopupResources resources =
          RemoteDictionaryPopupResources(
            fetchStyles: () async {
              fetches++;
              return remote;
            },
            fetchMedia: (String d, String p) async => null,
            fetchWordAudio: (String e, String r) async => null,
          );

      expect(resources.dictionaryStyles, isEmpty);
      await resources.prefetchStyles(resultFrom(<String>['明鏡', '無樣式']));
      expect(fetches, 1);
      final Map<String, String> first = resources.dictionaryStyles;
      expect(first, <String, String>{'明鏡': '.a{}'});

      // 已知词典（含「对端就没给它样式」的）不再重拉，样式表实例不变。
      await resources.prefetchStyles(resultFrom(<String>['明鏡', '無樣式']));
      expect(fetches, 1);
      expect(identical(resources.dictionaryStyles, first), isTrue);

      // 会话中途电脑导入了新词典：出现没见过的名字才重拉，并换新实例。
      remote = <String, String>{'明鏡': '.a{}', '大辞林': '.b{}'};
      await resources.prefetchStyles(resultFrom(<String>['大辞林']));
      expect(fetches, 2);
      expect(identical(resources.dictionaryStyles, first), isFalse);
      expect(resources.dictionaryStyles['大辞林'], '.b{}');
    },
  );

  test('a failed style fetch propagates and is retried next time', () async {
    int fetches = 0;
    final RemoteDictionaryPopupResources resources =
        RemoteDictionaryPopupResources(
          fetchStyles: () async {
            fetches++;
            if (fetches == 1) throw StateError('offline');
            return <String, String>{'明鏡': '.a{}'};
          },
          fetchMedia: (String d, String p) async => null,
          fetchWordAudio: (String e, String r) async => null,
        );
    await expectLater(
      resources.prefetchStyles(resultFrom(<String>['明鏡'])),
      throwsStateError,
    );
    await resources.prefetchStyles(resultFrom(<String>['明鏡']));
    expect(fetches, 2);
    expect(resources.dictionaryStyles, <String, String>{'明鏡': '.a{}'});
  });

  test(
    'media is cached, concurrent requests share one fetch, LRU bounded',
    () async {
      final List<String> fetched = <String>[];
      final Completer<void> gate = Completer<void>();
      final RemoteDictionaryPopupResources resources =
          RemoteDictionaryPopupResources(
            fetchStyles: () async => const <String, String>{},
            fetchMedia: (String dictionary, String path) async {
              fetched.add(path);
              if (path == 'slow.png') await gate.future;
              if (path == 'missing.png') return null;
              return DictionaryPopupMedia(
                bytes: Uint8List(4),
                contentType: 'image/png',
              );
            },
            fetchWordAudio: (String e, String r) async => null,
            mediaCacheMaxBytes: 8,
          );

      final Future<DictionaryPopupMedia?> a = resources.mediaFile(
        '明鏡',
        'slow.png',
      );
      final Future<DictionaryPopupMedia?> b = resources.mediaFile(
        '明鏡',
        'slow.png',
      );
      gate.complete();
      expect(await a, isNotNull);
      expect(identical(await a, await b), isTrue);
      expect(fetched, <String>['slow.png']);

      await resources.mediaFile('明鏡', 'slow.png');
      expect(fetched, <String>['slow.png'], reason: 'cache hit');

      // 未命中不缓存：下次还会再问。
      expect(await resources.mediaFile('明鏡', 'missing.png'), isNull);
      expect(await resources.mediaFile('明鏡', 'missing.png'), isNull);
      expect(fetched.where((String p) => p == 'missing.png'), hasLength(2));

      // 上限 8 字节 = 两张 4 字节图：第三张进来时最久未用的被淘汰。
      await resources.mediaFile('明鏡', 'b.png');
      await resources.mediaFile('明鏡', 'c.png');
      await resources.mediaFile('明鏡', 'slow.png');
      expect(fetched.where((String p) => p == 'slow.png'), hasLength(2));
    },
  );

  test('word audio is always asked of the remote source', () async {
    final List<String> asked = <String>[];
    final RemoteDictionaryPopupResources resources =
        RemoteDictionaryPopupResources(
          fetchStyles: () async => const <String, String>{},
          fetchMedia: (String d, String p) async => null,
          fetchWordAudio: (String expression, String reading) async {
            asked.add('$expression/$reading');
            return 'https://desk/api/lookup/audio/file?id=x';
          },
        );
    expect(
      await resources.wordAudioRef('猫', 'ねこ'),
      'https://desk/api/lookup/audio/file?id=x',
    );
    expect(asked, <String>['猫/ねこ']);
  });
}
