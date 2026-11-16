// 资源搜索手动检索的「识别源 / 外部 ID / 年份」一行（2026-11 所有者：识别源
// 下拉和同排两个文本框高度对不齐）与字幕搜索独立页的 M3E 改版。
//
// - 识别源保持下拉形态，但与外部 ID / 年份是同一个输入框组件：两套设计系统、
//   宽窄两种排法下同排字段的顶边与高度一致（Apple 形态下旧的
//   FushiDropdownButtonFormField 标题字号与字段高度都不同，差 20～40 px）。
// - 识别源是受控值：切分类时程序把它改成 AniDB / TMDB，显示立刻跟上（旧的
//   initialValue 型下拉在 Apple 形态下停在旧值）。
// - 字幕搜索独立页：二级页页头大字（不再是胶囊顶栏），落点选择是菜单 chip。
//
// 交互全部焦点驱动（Tab 走焦点、Enter 打开 / 确认），不做坐标点击。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_masthead_scaffold.dart'
    show FushiMastheadHeader;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _theme({required bool apple, required TargetPlatform platform}) =>
    ThemeData(
      platform: platform,
      extensions: <ThemeExtension<dynamic>>[
        FushiGlassTheme(FushiGlassMaterial.off, glassDesign: apple),
      ],
    );

Future<void> _pumpManualSurface(
  WidgetTester tester, {
  required Size size,
  bool apple = false,
  TargetPlatform platform = TargetPlatform.android,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: _theme(apple: apple, platform: platform),
        home: Scaffold(
          body: VideoResourceSearchSurface(
            registry: VideoResourceRegistry(const <VideoResourceProvider>[]),
            sources: const <MediaSourceRow>[],
            onSubmit: (VideoDiscoveryDownloadSelection selection) async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _byKey(String key) => find.byKey(ValueKey<String>(key));

/// 识别源字段当前显示的文字。
String _providerText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: _byKey('video-resource-provider'),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

bool _focusInside(Finder target) {
  final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
  if (focused is! Element) return false;
  final Set<Element> hosts = target.evaluate().toSet();
  if (hosts.contains(focused)) return true;
  bool inside = false;
  focused.visitAncestorElements((Element ancestor) {
    if (hosts.contains(ancestor)) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

/// Tab 走焦点直到焦点落进 [target]。
Future<void> _tabInto(WidgetTester tester, Finder target) async {
  for (int i = 0; i < 40 && !_focusInside(target); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(_focusInside(target), isTrue, reason: 'Tab 走不到 $target');
}

/// 焦点在菜单触发器上：Enter 打开菜单，方向键走到 [label] 那一项，Enter 选中。
Future<void> _pickFromMenu(WidgetTester tester, String label) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
  bool onItem() {
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    if (focused is! Element) return false;
    return find
        .descendant(
          of: find.byElementPredicate((Element e) => e == focused),
          matching: find.text(label),
        )
        .evaluate()
        .isNotEmpty;
  }

  // 菜单打开时焦点可能落在当前选中项上：先往下找，找不到再往上找。
  for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowUp,
  ]) {
    for (int i = 0; i < 8 && !onItem(); i++) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
  }
  expect(onItem(), isTrue, reason: '菜单里走不到「$label」');
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

void _expectSameRow(WidgetTester tester, List<String> keys, String context) {
  final Rect first = tester.getRect(_byKey(keys.first));
  for (final String key in keys.skip(1)) {
    final Rect rect = tester.getRect(_byKey(key));
    expect(
      rect.top,
      moreOrLessEquals(first.top, epsilon: 0.5),
      reason: '$context：$key 顶边应与 ${keys.first} 对齐',
    );
    expect(
      rect.height,
      moreOrLessEquals(first.height, epsilon: 0.5),
      reason: '$context：$key 高度应与 ${keys.first} 一致',
    );
  }
}

VideoMediaReference _reference() => VideoMediaReference(
  providerId: 'anilist',
  mediaId: '100',
  mediaKind: VideoMetadataMediaKind.tv,
  discoveryCategory: VideoDiscoveryCategory.anime,
  title: 'Test Anime',
  year: 2026,
  anilistId: 100,
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.windows,
    ]) {
      final String label = '${apple ? 'Apple' : 'MD3'} · ${platform.name}';
      testWidgets('$label：识别源与外部 ID / 年份同排等高、顶边对齐', (
        WidgetTester tester,
      ) async {
        // 宽排：识别源 | 外部 ID | 年份 一行。
        await _pumpManualSurface(
          tester,
          size: const Size(1000, 800),
          apple: apple,
          platform: platform,
        );
        _expectSameRow(tester, <String>[
          'video-resource-provider',
          'video-resource-external-id',
          'video-resource-year',
        ], '宽排');

        // 窄排（< 520）：识别源 | 年份 一行，外部 ID 下一行。
        await _pumpManualSurface(
          tester,
          size: const Size(400, 800),
          apple: apple,
          platform: platform,
        );
        _expectSameRow(tester, <String>[
          'video-resource-provider',
          'video-resource-year',
        ], '窄排');
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final bool apple in <bool>[false, true]) {
    testWidgets('${apple ? 'Apple' : 'MD3'}：切分类时识别源显示跟着程序改值', (
      WidgetTester tester,
    ) async {
      await _pumpManualSurface(
        tester,
        size: const Size(1000, 800),
        apple: apple,
      );
      expect(_providerText(tester), 'AniDB');

      await _tabInto(tester, _byKey('video-resource-category'));
      await _pickFromMenu(tester, t.collection_relation_movie);
      expect(
        _providerText(tester),
        'TMDB',
        reason: '电影 / 剧集的识别源被改成 TMDB，字段必须显示出来',
      );

      await _tabInto(tester, _byKey('video-resource-category'));
      await _pickFromMenu(tester, t.media_tracking_anime);
      expect(_providerText(tester), 'AniDB');

      // 手动改识别源（同样经菜单）也落到显示上。
      await _tabInto(tester, _byKey('video-resource-provider'));
      await _pickFromMenu(tester, 'AniList');
      expect(_providerText(tester), 'AniList');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('字幕搜索独立页：二级页页头大字 + 落点菜单 chip', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: VideoDiscoverySubtitleSearchPage(
            item: VideoDiscoveryItem(reference: _reference()),
            registry: VideoSubtitleRegistry(const <VideoSubtitleProvider>[]),
            pickVideo: (BuildContext context) async => null,
            pickDirectory: (BuildContext context) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(FushiMastheadHeader),
        matching: find.text(t.video_discovery_subtitle_search),
      ),
      findsOneWidget,
      reason: '页名画在二级页页头大字里，而不是胶囊顶栏',
    );
    // 落点选择是菜单 chip（维度名在 tooltip / 语义里），不再是 MD2 下拉字段。
    final Finder target = _byKey('video-subtitle-target');
    expect(target, findsOneWidget);
    expect(
      find.descendant(
        of: target,
        matching: find.byWidgetPredicate(
          (Widget w) => w is DropdownButtonFormField,
        ),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: target,
        matching: find.text(t.anime_download_kind_video),
      ),
      findsOneWidget,
    );
    expect(
      // 维度名与当前值合在同一个语义节点里（标签形如「Save subtitle to + 换行 + Video file」）。
      find.bySemanticsLabel(
        RegExp(RegExp.escape(t.video_subtitle_install_target)),
      ),
      findsWidgets,
    );

    // 焦点驱动切到「下载目录」：选择按钮仍在、落点 chip 显示新值。
    await _tabInto(tester, target);
    await _pickFromMenu(tester, t.download_save_root_title);
    expect(
      find.descendant(
        of: target,
        matching: find.text(t.download_save_root_title),
      ),
      findsOneWidget,
    );
    expect(_byKey('video-subtitle-pick-target'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
