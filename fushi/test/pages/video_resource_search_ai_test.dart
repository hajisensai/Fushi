// 资源搜索 surface 的 AI 辅助：未指派提供商时一个 AI 按钮都不出现；假 client 回一份
// 排列后平铺列表按它重排、推荐条目带「AI 推荐」徽章；补词只出 chip，不改输入框。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi_core/fushi_core.dart';

const List<String> _titles = <String>[
  '[Group] Show - 01 [1080p]',
  '[Group] Show - 02 [1080p]',
  '[Group] Show (01-12) [1080p] [Batch]',
];

class _Provider implements VideoResourceProvider {
  @override
  String get id => 'test';
  @override
  int get priority => 1;
  @override
  Set<VideoDiscoveryCategory> get categories => <VideoDiscoveryCategory>{};
  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(
    VideoResourceSearchRequest request,
  ) async => ProviderBatchResult<VideoResourceCandidate>.success(
    <VideoResourceCandidate>[
      for (int i = 0; i < _titles.length; i++) _Candidate(i),
    ],
  );

  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) async =>
      throw UnimplementedError();
  @override
  void close() {}
}

class _Candidate extends VideoResourceCandidate {
  _Candidate(int i)
    : super(
        providerId: 'test',
        providerInstanceId: 'test',
        remoteId: 'r$i',
        title: _titles[i],
        providerPriority: 1,
        // 做种数递减：本地相关度排序会保持 0,1,2 的原序，AI 排列才是唯一变量。
        seeders: 100 - i,
      );
}

VideoMediaReference _media() => VideoMediaReference(
  providerId: 'tmdb',
  mediaId: '123',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.tv,
  title: 'Show',
  year: 2023,
  season: 1,
);

AiProviderConfig _provider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Fake',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  apiKey: 'k',
  model: 'm',
);

http.Response _openAiReply(String content) => http.Response(
  jsonEncode(<String, Object?>{
    'choices': <Object?>[
      <String, Object?>{
        'message': <String, Object?>{'content': content},
      },
    ],
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

Widget _surface({
  AiProviderConfig? provider,
  AiChatClient Function()? clientFactory,
}) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(
      body: VideoResourceSearchSurface(
        pageMode: true,
        initialItem: VideoDiscoveryItem(reference: _media()),
        registry: VideoResourceRegistry(<VideoResourceProvider>[_Provider()]),
        sources: const <MediaSourceRow>[],
        onSubmit: (VideoDiscoveryDownloadSelection selection) async {},
        resolveAiProvider: provider == null ? null : () => provider,
        aiClientFactory: clientFactory,
      ),
    ),
  ),
);

Future<void> _pump(WidgetTester tester, Widget widget) async {
  await tester.binding.setSurfaceSize(const Size(1000, 850));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

/// 平铺列表当前的标题顺序（按屏幕纵坐标）。
List<String> _shownTitles(WidgetTester tester) {
  final List<Element> rows = find
      .byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'video-resource-test:test:',
            ),
      )
      .evaluate()
      .toList();
  rows.sort(
    (Element a, Element b) => tester
        .getTopLeft(find.byElementPredicate((Element e) => e == a))
        .dy
        .compareTo(
          tester.getTopLeft(find.byElementPredicate((Element e) => e == b)).dy,
        ),
  );
  return rows
      .map(
        (Element e) => (e.widget.key! as ValueKey<String>).value.substring(
          'video-resource-'.length,
        ),
      )
      .toList();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('未指派提供商时不显示任何 AI 按钮', (WidgetTester tester) async {
    await _pump(tester, _surface());
    expect(
      find.byKey(const ValueKey<String>('video-resource-ai-expand')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('video-resource-ai-rank')),
      findsNothing,
    );
    expect(find.text(t.video_search_ai_recommended), findsNothing);
  });

  testWidgets('假 client 回排列 → 平铺列表按 AI 顺序重排、推荐徽章出现', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      _surface(
        provider: _provider(),
        clientFactory: () => AiChatClient(
          client: MockClient(
            (http.Request request) async => _openAiReply(
              '{"order":[2,0,1],"recommended":2,"notes":{"2":"整季合集"}}',
            ),
          ),
        ),
      ),
    );
    final Finder rank = find.byKey(
      const ValueKey<String>('video-resource-ai-rank'),
    );
    expect(rank, findsOneWidget);
    await tester.tap(rank);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-resource-ai-ranked')),
      findsOneWidget,
    );
    expect(_shownTitles(tester), <String>[
      'test:test:r2',
      'test:test:r0',
      'test:test:r1',
    ]);
    expect(
      find.byKey(const ValueKey<String>('video-resource-ai-pick-test:test:r2')),
      findsOneWidget,
    );
    expect(find.textContaining('整季合集'), findsOneWidget);
  });

  testWidgets('AI 补词只出 chip，不改输入框；点 chip 才填入并搜索', (WidgetTester tester) async {
    await _pump(
      tester,
      _surface(
        provider: _provider(),
        clientFactory: () => AiChatClient(
          client: MockClient(
            (http.Request request) async =>
                _openAiReply('{"queries":["ショウ","Shou"]}'),
          ),
        ),
      ),
    );
    final Finder field = find.byKey(
      const ValueKey<String>('video-resource-query'),
    );
    final String before = tester.widget<TextField>(field).controller!.text;
    await tester.tap(
      find.byKey(const ValueKey<String>('video-resource-ai-expand')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-resource-ai-queries')),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(field).controller!.text, before);

    await tester.tap(find.widgetWithText(ActionChip, 'ショウ'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'ショウ');
  });
}
