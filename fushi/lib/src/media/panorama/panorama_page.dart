/// 媒体库全景的 Riverpod 装配与页面：可操作的全屏页 [PanoramaPage]、分享用的 16 秒开场
/// 动画 [PanoramaCinematicPage]。首页面板见 `home_panorama_panel.dart`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/panorama/panorama_atlas.dart';
import 'package:fushi/src/media/panorama/panorama_library.dart';
import 'package:fushi/src/media/panorama/panorama_stage.dart';
import 'package:fushi/src/models/app_font_loader.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/srs/srs_providers.dart' show srsStoreProvider;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 打开一部作品（由首页按各域既有路径实现）。
typedef PanoramaOpenWork = Future<void> Function(PanoramaWork work);

/// 字体套：小说正文字体、app 界面字体、复习卡片字体、游戏文本字体里各取不同的族，最多 4 套；
/// 缺字回退 app 界面字体链。一个都没有时只有系统默认一套。
Future<List<PanoramaFontSet>> panoramaFontSets(AppModel app) async {
  final ReaderSettings settings = ReaderSettings(app.database);
  await settings.refreshFromDb();
  final List<String> body = await AppFontLoader.resolveAndLoadAll(
    settings.customFonts,
  );
  final List<String> chain = app.appFontChain;
  final List<String> families = <String>[];
  for (final String f in <String>[
    ...body,
    ...chain,
    ...app.srsCardFontFamilies,
    ...app.gameLookupFontFamilies,
  ]) {
    if (f.isNotEmpty && !families.contains(f)) families.add(f);
    if (families.length == 4) break;
  }
  if (families.isEmpty) return const <PanoramaFontSet>[PanoramaFontSet(null)];
  return <PanoramaFontSet>[
    for (final String f in families) PanoramaFontSet(f, fallback: chain),
  ];
}

/// 全景资源（数据 + 图集）：首页面板与全屏页共用；没有订阅者时释放图集显存。
final AutoDisposeFutureProvider<PanoramaAssets> panoramaAssetsProvider =
    FutureProvider.autoDispose<PanoramaAssets>((Ref ref) async {
      final AppModel app = ref.read(appProvider);
      SrsDbStore? srs;
      try {
        srs = await ref.watch(srsStoreProvider.future);
      } catch (_) {
        // 复习库打不开：照样出封面，只是没有词。
        srs = null;
      }
      final PanoramaLibrary library = await loadPanoramaLibrary(
        db: app.database,
        srs: srs,
      );
      final List<PanoramaFontSet> fonts = await panoramaFontSets(app);
      final PanoramaAtlas atlas = await buildPanoramaAtlas(
        library,
        fonts: fonts,
        spec: PanoramaAtlasSpec.current,
      );
      final PanoramaAssets assets = PanoramaAssets(
        library: library,
        atlas: atlas,
        db: app.database,
        bookFont: fonts.first,
      );
      ref.onDispose(assets.dispose);
      return assets;
    });

/// 说明文字：作品数 + 制卡总数 + 展示词数。
String panoramaSummary(PanoramaLibrary library) => t.panorama_summary(
  works: library.works.length,
  mined: library.minedTotal,
  shown: library.shownWords,
);

/// 播放分享动画；减弱动态效果 / 墨水屏下跳过整段，直接打开最后要锁定的作品。
Future<void> playPanoramaCinematic(
  BuildContext context,
  PanoramaAssets assets,
  PanoramaOpenWork onOpen,
) async {
  final int target = assets.defaultTarget;
  if (!fushiMotionEnabled(context)) {
    if (target >= 0) await onOpen(assets.library.works[target]);
    return;
  }
  await Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: fushiMotionDuration(context, FushiMotion.medium),
      pageBuilder: (_, _, _) =>
          PanoramaCinematicPage(assets: assets, target: target, onOpen: onOpen),
      transitionsBuilder: (_, Animation<double> a, _, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ),
  );
}

/// 全屏可操作全景（星系开场，拉近收拢成球幕）。
class PanoramaPage extends ConsumerWidget {
  const PanoramaPage({super.key, required this.onOpen});

  final PanoramaOpenWork onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PanoramaAssets> assets = ref.watch(panoramaAssetsProvider);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final PanoramaAssets? ready = assets.valueOrNull;
    return Scaffold(
      backgroundColor: const Color(0xFF05070F),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (ready != null && !ready.library.isEmpty)
            PanoramaStage(
              key: const ValueKey<String>('panorama-page-stage'),
              assets: ready,
              onOpen: onOpen,
            )
          else
            Center(
              child: Text(
                assets.isLoading ? t.panorama_loading : t.panorama_empty,
                style: tokens.type.metadata.copyWith(color: Colors.white70),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap,
                tokens.spacing.page,
                0,
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: FushiFloatingTopBar(
                  key: const ValueKey<String>('panorama-top-bar'),
                  leading: <FushiToolbarItem>[
                    FushiToolbarItem(
                      key: const ValueKey<String>('panorama-back'),
                      icon: FushiIcons.back,
                      label: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: () =>
                          unawaited(Navigator.of(context).maybePop()),
                    ),
                  ],
                  title: t.home_panel_panorama_title,
                  subtitle: ready == null ? '' : panoramaSummary(ready.library),
                  actions: <List<FushiToolbarItem>>[
                    <FushiToolbarItem>[
                      FushiToolbarItem(
                        key: const ValueKey<String>('panorama-share-animation'),
                        icon: FushiIcons.play,
                        label: t.panorama_share_animation,
                        onPressed: ready == null || ready.library.isEmpty
                            ? null
                            : () => unawaited(
                                playPanoramaCinematic(context, ready, onOpen),
                              ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分享用开场动画：全屏无界面元素（便于录屏），右上角一个淡出的关闭钮。
class PanoramaCinematicPage extends StatefulWidget {
  const PanoramaCinematicPage({
    super.key,
    required this.assets,
    required this.target,
    required this.onOpen,
  });

  final PanoramaAssets assets;
  final int target;
  final PanoramaOpenWork onOpen;

  @override
  State<PanoramaCinematicPage> createState() => _PanoramaCinematicPageState();
}

class _PanoramaCinematicPageState extends State<PanoramaCinematicPage> {
  bool _chrome = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _hide = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _chrome = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05070F),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          PanoramaStage(
            key: const ValueKey<String>('panorama-cinematic-stage'),
            assets: widget.assets,
            mode: FfcPanoMode.cinematic,
            cinematicTarget: widget.target,
            onOpen: widget.onOpen,
            onCinematicDone: () {
              if (mounted) unawaited(Navigator.of(context).maybePop());
            },
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: AnimatedOpacity(
                opacity: _chrome ? 1 : 0,
                duration: fushiMotionDuration(context, FushiMotion.long),
                child: IconButton(
                  key: const ValueKey<String>('panorama-cinematic-close'),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  color: Colors.white70,
                  icon: const Icon(FushiIcons.close),
                  onPressed: () => unawaited(Navigator.of(context).maybePop()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
