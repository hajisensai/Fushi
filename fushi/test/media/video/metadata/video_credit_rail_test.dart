/// BUG-2612：人物卡片的照片来源与回退规则，两页共用同一份轨道。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/metadata/video_credit_rail.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_credit_repository.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

VideoMetadataCreditSummary _credit({
  required String kind,
  String? profileUrl,
  String? profilePath,
  String? characterImageUrl,
  bool withCharacter = true,
}) =>
    VideoMetadataCreditSummary(
      creditKind: kind,
      person: VideoMetadataPersonSummary(
        personKey: 'person:mal:1',
        name: 'Tanezaki, Atsumi',
        profileUrl: profileUrl,
        profilePath: profilePath,
        identities: const <VideoMetadataIdentitySummary>[],
      ),
      character: withCharacter
          ? VideoMetadataCharacterSummary(
              characterKey: 'character:mal:7',
              name: 'Frieren',
              imageUrl: characterImageUrl,
              identities: const <VideoMetadataIdentitySummary>[],
            )
          : null,
      roleName: 'Frieren',
      sortOrder: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() async {
    // AppCachedHttpImage 构造即起磁盘缓存管理器，要 path_provider 应答。
    temp = await Directory.systemTemp.createTemp('credit-rail-cache-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => temp.path,
    );
  });
  tearDownAll(() => temp.delete(recursive: true));

  test('person photo wins when present', () {
    final VideoCreditCardImage? image = videoCreditCardImage(_credit(
      kind: 'voice_actor',
      profileUrl: 'https://img/person.jpg',
      characterImageUrl: 'https://img/character.jpg',
    ));
    expect(image?.image, isA<AppCachedHttpImage>());
    expect(image?.source, 'https://img/person.jpg');
  });

  test('voice actor without a photo falls back to the character image', () {
    final VideoCreditCardImage? image = videoCreditCardImage(_credit(
      kind: 'voice_actor',
      characterImageUrl: 'https://img/character.jpg',
    ));
    expect(image?.source, 'https://img/character.jpg');
  });

  test('live actors and crew never borrow the character image', () {
    expect(
      videoCreditCardImage(_credit(
        kind: 'actor',
        characterImageUrl: 'https://img/character.jpg',
      )),
      isNull,
    );
    expect(
      videoCreditCardImage(_credit(kind: 'director', withCharacter: false)),
      isNull,
    );
  });

  test('a downloaded local file beats the remote url', () async {
    final Directory dir = await Directory.systemTemp.createTemp('credit-rail-');
    addTearDown(() => dir.delete(recursive: true));
    final File file = File('${dir.path}/p.jpg')..writeAsBytesSync(<int>[0]);
    final VideoCreditCardImage? image = videoCreditCardImage(_credit(
      kind: 'voice_actor',
      profilePath: file.path,
      profileUrl: 'https://img/person.jpg',
    ));
    expect(image?.image, isA<FileImage>());
    expect(image?.source, file.path);
  });

  testWidgets('rail renders one card per credit with name and role',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => VideoCreditRail(
            title: 'Voice roles',
            credits: <VideoMetadataCreditSummary>[
              _credit(kind: 'voice_actor'),
            ],
            tokens: FushiDesignTokens.of(context),
          ),
        ),
      ),
    ));
    expect(find.text('Voice roles'), findsOneWidget);
    expect(find.text('Tanezaki, Atsumi'), findsOneWidget);
    expect(find.text('Frieren'), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('video-work-credit-person:mal:1-0')),
        findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget,
        reason: '没有任何图时显示人物占位');
  });

  test('both detail pages render credits through the shared rail', () {
    for (final String page in <String>[
      'lib/src/pages/implementations/media_collection_detail_page.dart',
      'lib/src/pages/implementations/video_work_detail_page.dart',
    ]) {
      final String source = File(page).readAsStringSync();
      expect(source, contains('VideoCreditRail('), reason: page);
    }
  });
}
