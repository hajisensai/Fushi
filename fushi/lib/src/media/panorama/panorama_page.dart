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

/// 全屏页空闲时环境动效保留的走速：公转的封面与环绕的词一直慢慢转，不会定住。
const double kPanoramaPageIdleDrift = 0.4;

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

/// 全景数据（作品 + 词，不含图集）：首页面板只要它出说明文字与分享选单，不建图集、
/// 不占显存。
final AutoDisposeFutureProvider<PanoramaLibrary> panoramaLibraryProvider =
    FutureProvider.autoDispose<PanoramaLibrary>((Ref ref) async {
      final AppModel app = ref.read(appProvider);
      SrsDbStore? srs;
      try {
        srs = await ref.watch(srsStoreProvider.future);
      } catch (e, s) {
        // 复习库打不开：照样出封面，只是没有词（记日志，不静默）。
        ErrorLogService.instance.log('panoramaLibraryProvider.srs', e, s);
        srs = null;
      }
      return loadPanoramaLibrary(db: app.database, srs: srs);
    });

/// 全景资源（数据 + 图集）：全屏页与分享动画共用；没有订阅者时释放图集显存。
final AutoDisposeFutureProvider<PanoramaAssets> panoramaAssetsProvider =
    FutureProvider.autoDispose<PanoramaAssets>((
      AutoDisposeFutureProviderRef<PanoramaAssets> ref,
    ) async {
      final AppModel app = ref.read(appProvider);
      final PanoramaLibrary library = await ref.watch(
        panoramaLibraryProvider.future,
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

IconData _workKindIcon(PanoramaWorkKind kind) => switch (kind) {
  PanoramaWorkKind.book => FushiIcons.books,
  PanoramaWorkKind.manga => FushiIcons.manga,
  PanoramaWorkKind.video => FushiIcons.video,
  PanoramaWorkKind.game => FushiIcons.games,
  PanoramaWorkKind.music => FushiIcons.music,
};

/// 分享动画的作品选单顺序（纯函数）：默认锁定的作品在最前，其余按最近打开、再按标题。
List<int> panoramaShareTargetOrder(PanoramaLibrary library) {
  final int preferred = panoramaDefaultTarget(library);
  final List<PanoramaWork> works = library.works;
  final List<int> order = <int>[for (int i = 0; i < works.length; i++) i];
  order.sort((int a, int b) {
    if (a == preferred) return -1;
    if (b == preferred) return 1;
    final int byRecent = works[b].lastOpenedAt.compareTo(works[a].lastOpenedAt);
    if (byRecent != 0) return byRecent;
    return works[a].title.compareTo(works[b].title);
  });
  return order;
}

/// 让用户选分享动画最后锁定的作品（默认项 = [panoramaDefaultTarget]）；取消返回 null。
Future<int?> pickPanoramaShareTarget(
  BuildContext context,
  PanoramaLibrary library,
) {
  return showFushiChoiceDialog<int>(
    context: context,
    title: t.panorama_share_pick_title,
    message: t.panorama_share_pick_message,
    icon: FushiIcons.share,
    selected: panoramaDefaultTarget(library),
    options: <FushiChoiceOption<int>>[
      for (final int i in panoramaShareTargetOrder(library))
        FushiChoiceOption<int>(
          value: i,
          label: library.works[i].title,
          icon: _workKindIcon(library.works[i].kind),
        ),
    ],
  );
}

/// 分享动画：先选最后锁定的作品，再全屏播放；减弱动态效果 / 墨水屏下跳过整段，直接打开
/// 选中的作品。
Future<void> playPanoramaCinematic(
  BuildContext context,
  PanoramaLibrary library,
  PanoramaOpenWork onOpen,
) async {
  if (library.isEmpty) return;
  final int? target = await pickPanoramaShareTarget(context, library);
  if (target == null || !context.mounted) return;
  if (!fushiMotionEnabled(context)) {
    await onOpen(library.works[target]);
    return;
  }
  await Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: fushiMotionDuration(context, FushiMotion.medium),
      pageBuilder: (_, _, _) =>
          PanoramaCinematicPage(target: target, onOpen: onOpen),
      transitionsBuilder: (_, Animation<double> a, _, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ),
  );
}

/// 全屏可操作全景（星系开场，拉近收拢成球幕）。顶栏：返回 + 标题；动作：切换星系 / 球幕、
/// 分享动画（先选作品）。
class PanoramaPage extends ConsumerStatefulWidget {
  const PanoramaPage({super.key, required this.onOpen});

  final PanoramaOpenWork onOpen;

  @override
  ConsumerState<PanoramaPage> createState() => _PanoramaPageState();
}

class _PanoramaPageState extends ConsumerState<PanoramaPage> {
  final PanoramaStageController _stage = PanoramaStageController();

  @override
  void dispose() {
    _stage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<PanoramaAssets> assets = ref.watch(panoramaAssetsProvider);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final PanoramaAssets? ready = assets.valueOrNull;
    final bool hasWorks = ready != null && !ready.library.isEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFF05070F),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (hasWorks)
            PanoramaStage(
              key: const ValueKey<String>('panorama-page-stage'),
              assets: ready,
              onOpen: widget.onOpen,
              controller: _stage,
              idleDrift: kPanoramaPageIdleDrift,
              autofocus: true,
            )
          else
            Center(
              child: Text(
                assets.hasError
                    ? t.panorama_load_failed
                    : assets.isLoading
                    ? t.panorama_loading
                    : t.panorama_empty,
                style: tokens.type.metadata.copyWith(color: Colors.white70),
              ),
            ),
          // 顶栏贴顶：不给它整屏高度（否则悬浮条在屏幕中间）。
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.gap,
                  tokens.spacing.page,
                  0,
                ),
                child: ListenableBuilder(
                  listenable: _stage,
                  builder: (BuildContext context, _) => FushiFloatingTopBar(
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
                    subtitle: ready == null
                        ? ''
                        : panoramaSummary(ready.library),
                    actions: <List<FushiToolbarItem>>[
                      <FushiToolbarItem>[
                        FushiToolbarItem(
                          key: const ValueKey<String>('panorama-stage-toggle'),
                          icon: _stage.sphere
                              ? FushiIcons.blur
                              : FushiIcons.globe,
                          label: _stage.sphere
                              ? t.panorama_stage_to_galaxy
                              : t.panorama_stage_to_sphere,
                          onPressed: hasWorks ? _stage.toggleStage : null,
                        ),
                        FushiToolbarItem(
                          key: const ValueKey<String>(
                            'panorama-share-animation',
                          ),
                          icon: FushiIcons.share,
                          label: t.panorama_share_animation,
                          onPressed: hasWorks
                              ? () => unawaited(
                                  playPanoramaCinematic(
                                    context,
                                    ready.library,
                                    widget.onOpen,
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ],
                  ),
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
class PanoramaCinematicPage extends ConsumerStatefulWidget {
  const PanoramaCinematicPage({
    super.key,
    required this.target,
    required this.onOpen,
  });

  /// 最后锁定的作品下标（[PanoramaLibrary.works]）。
  final int target;
  final PanoramaOpenWork onOpen;

  @override
  ConsumerState<PanoramaCinematicPage> createState() =>
      _PanoramaCinematicPageState();
}

class _PanoramaCinematicPageState extends ConsumerState<PanoramaCinematicPage> {
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
    final AsyncValue<PanoramaAssets> assets = ref.watch(panoramaAssetsProvider);
    final PanoramaAssets? ready = assets.valueOrNull;
    return Scaffold(
      backgroundColor: const Color(0xFF05070F),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (ready != null && widget.target < ready.library.works.length)
            PanoramaStage(
              key: const ValueKey<String>('panorama-cinematic-stage'),
              assets: ready,
              mode: FfcPanoMode.cinematic,
              cinematicTarget: widget.target,
              onOpen: widget.onOpen,
              onCinematicDone: () {
                if (mounted) unawaited(Navigator.of(context).maybePop());
              },
            )
          else
            Center(
              child: Text(
                assets.hasError ? t.panorama_load_failed : t.panorama_loading,
                style: FushiDesignTokens.of(
                  context,
                ).type.metadata.copyWith(color: Colors.white70),
              ),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: AnimatedOpacity(
                opacity: _chrome ? 1 : 0,
                duration: fushiMotionDuration(context, FushiMotion.long),
                child: FushiIconButton(
                  key: const ValueKey<String>('panorama-cinematic-close'),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  enabledColor: Colors.white70,
                  icon: FushiIcons.close,
                  onTap: () => unawaited(Navigator.of(context).maybePop()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
