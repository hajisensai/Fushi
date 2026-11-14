// 三套卡面共用的两段宿主行为（srs_card_face.dart）：
// - 发音键在没有宿主播放序列时的落地（外观 / 模板预览）：媒体库里找文件直接播；
// - 原生卡面的选区上报（复习时编辑）。
import 'dart:io';

import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_edit.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';

SrsCardFace _face({void Function(SrsCardSelection)? onEditSelection}) =>
    SrsCardFace(
      cardId: 'c1',
      showingAnswer: true,
      bodyHtml: '',
      css: '',
      languageCode: 'ja',
      onBridgeKey: (_) {},
      onEditSelection: onEditSelection,
    );

void main() {
  group('srsPlayCardSoundFile', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('fushi_srs_play_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<List<String>> play(
      WidgetTester tester,
      String name, {
      required Future<SrsMediaStore?> Function() store,
    }) async {
      final List<String> played = <String>[];
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          // 每次一个新容器（同一条测试里换媒体库）。
          key: UniqueKey(),
          overrides: <Override>[
            srsMediaStoreProvider.overrideWith((Ref ref) => store()),
            srsSoundPlayerProvider.overrideWithValue((String path) async {
              played.add(path);
              return true;
            }),
          ],
          child: Consumer(
            builder: (BuildContext context, WidgetRef r, Widget? child) {
              ref = r;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.runAsync(
        () => srsPlayCardSoundFile(ref, name, logTag: 'test.mediaStore'),
      );
      return played;
    }

    testWidgets('媒体库里有这个文件：播它的本地路径', (WidgetTester tester) async {
      File('${tmp.path}/a.mp3').writeAsBytesSync(<int>[1, 2, 3]);
      final List<String> played = await play(
        tester,
        'a.mp3',
        store: () async => SrsMediaStore(tmp),
      );
      expect(played, hasLength(1));
      expect(File(played.single).readAsBytesSync(), <int>[1, 2, 3]);
    });

    testWidgets('文件不在 / 名字不安全：不播', (WidgetTester tester) async {
      expect(
        await play(tester, 'nope.mp3', store: () async => SrsMediaStore(tmp)),
        isEmpty,
      );
      expect(
        await play(tester, '../a.mp3', store: () async => SrsMediaStore(tmp)),
        isEmpty,
      );
    });

    testWidgets('没有媒体库（模块没开）/ 取媒体库失败：不播、不抛', (WidgetTester tester) async {
      expect(await play(tester, 'a.mp3', store: () async => null), isEmpty);
      expect(
        await play(
          tester,
          'a.mp3',
          store: () async => throw StateError('no media store'),
        ),
        isEmpty,
      );
    });
  });

  group('srsCardSelectionReporter', () {
    test('宿主没接复习时编辑：不挂回调', () {
      expect(srsCardSelectionReporter(_face()), isNull);
    });

    test('选中的文字交给宿主（没有序号）；清空选区 / 只选中空白不报', () {
      final List<SrsCardSelection> got = <SrsCardSelection>[];
      final ValueChanged<SelectedContent?> report = srsCardSelectionReporter(
        _face(onEditSelection: got.add),
      )!;
      report(null);
      report(const SelectedContent(plainText: ''));
      report(const SelectedContent(plainText: ' \n'));
      expect(got, isEmpty);
      report(const SelectedContent(plainText: ' 図書館 '));
      expect(got, hasLength(1));
      expect(got.single.text, ' 図書館 ');
      expect(got.single.occurrence, isNull);
      expect(got.single.definitionsOnly, isFalse);
    });
  });
}
