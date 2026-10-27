/// 声优 / 人物聚合页（作品图谱 L5，spec `docs/specs/2026-10-24-cross-media-links.md`
/// §5）：一个人在视频、游戏、音乐三个模块里的全部出场——TA 配音的动画角色、游戏
/// 角色、演唱的曲目（角色歌），每张卡都点进对应模块的条目。
///
/// 「同一个人」只按可靠外部 id 合并（[loadPersonGraph]）；名字相同只出「可能是同一人」
/// 建议，用户确认才合并（写 `person_identity_bridges` manual 行）、否决写墓碑不再建议。
/// 打开页面时对还没查过的外部 id 跑一轮 Wikidata 桥接（后台、限流、缓存 30 天），
/// 查到新的等价 id 就重建本页。
///
/// 入口：视频合集 / 单文件作品详情的人物轨道、游戏详情「配音」、曲目详情「署名」。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/media_link_opener.dart';
import 'package:fushi/src/media/people/person_directory.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/people/person_identity.dart';
import 'package:fushi_engine/media/people/wikidata_person_bridge.dart';
import 'package:material_ui/material_ui.dart';

/// 打开某个本地人物（[seedNode] = `personRefNode(...)`）所在的人物页。
Future<void> openPersonPage(
  BuildContext context, {
  required String seedNode,
  String? initialName,
}) {
  final NavigatorState navigator = Navigator.of(context);
  return navigator.push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) =>
          PersonDetailPage(seedNode: seedNode, initialName: initialName),
    ),
  );
}

/// 人物页的数据加载结果（便于测试替换加载函数）。
typedef PersonPageLoader =
    Future<PersonPageData?> Function(FushiDatabase db, String seedNode);

class PersonDetailPage extends ConsumerStatefulWidget {
  const PersonDetailPage({
    required this.seedNode,
    this.initialName,
    this.loader = _defaultLoader,
    this.bridgeLookup = true,
    this.database,
    super.key,
  });

  static Future<PersonPageData?> _defaultLoader(
    FushiDatabase db,
    String seedNode,
  ) => loadPersonPage(db, seedNode);

  final String seedNode;

  /// 加载完成前顶栏显示的名字（来自入口卡片）。
  final String? initialName;

  final PersonPageLoader loader;

  /// 打开时是否跑 Wikidata 桥接（测试关掉，避免联网）。
  final bool bridgeLookup;

  /// 测试注入；null = 取 [appProvider] 的数据库。
  final FushiDatabase? database;

  @override
  ConsumerState<PersonDetailPage> createState() => _PersonDetailPageState();
}

enum _BridgeState { idle, checking, failed }

class _PersonDetailPageState extends ConsumerState<PersonDetailPage> {
  late Future<PersonPageData?> _data;
  _BridgeState _bridge = _BridgeState.idle;
  bool _bridgeTried = false;

  FushiDatabase get _db => widget.database ?? ref.read(appProvider).database;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<PersonPageData?> _load() async {
    final PersonPageData? data = await widget.loader(_db, widget.seedNode);
    if (data != null && widget.bridgeLookup && !_bridgeTried) {
      _bridgeTried = true;
      unawaited(_runBridge(data.cluster));
    }
    return data;
  }

  Future<void> _runBridge(PersonCluster cluster) async {
    if (!mounted) return;
    setState(() => _bridge = _BridgeState.checking);
    bool changed = false;
    _BridgeState next = _BridgeState.idle;
    try {
      changed = await refreshPersonWikidataBridges(_db, cluster);
    } on WikidataPersonBridgeException catch (e) {
      ErrorLogService.instance.logDiagnostic('PersonPage.wikidata', '$e');
      next = _BridgeState.failed;
    }
    if (!mounted) return;
    setState(() {
      _bridge = next;
      if (changed) _data = widget.loader(_db, widget.seedNode);
    });
  }

  void _reload() {
    setState(() {
      _data = widget.loader(_db, widget.seedNode);
    });
  }

  Future<void> _decide(
    PersonCluster self,
    PersonSuggestion s, {
    required bool same,
  }) async {
    await decidePersonIdentity(_db, self, s.other, same: same);
    if (!mounted) return;
    _reload();
  }

  Future<void> _unmerge((String, String) pair) async {
    await unmergePersonPair(_db, pair);
    if (!mounted) return;
    _reload();
  }

  void _open(MediaLinkEntry entry) {
    if (!entry.inLibrary) return;
    unawaited(openMediaLinkEntry(context: context, ref: ref, entry: entry));
  }

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return FutureBuilder<PersonPageData?>(
      future: _data,
      builder: (BuildContext context, AsyncSnapshot<PersonPageData?> snap) {
        final PersonPageData? data = snap.data;
        final String title =
            data?.cluster.displayName ??
            widget.initialName ??
            t.person_page_title;
        return FushiPageScaffold(
          title: title,
          header: apple
              ? null
              : Padding(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    tokens.spacing.gap,
                    tokens.spacing.page,
                    tokens.spacing.gap,
                  ),
                  child: FushiFloatingTopBar(
                    title: title,
                    leading: <FushiToolbarItem>[
                      if (navigator != null && navigator.canPop())
                        FushiToolbarItem(
                          icon: FushiIcons.back,
                          label: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          onPressed: () => unawaited(navigator.maybePop()),
                        ),
                    ],
                  ),
                ),
          // 加载骨架 → 正文交叉淡入（时长走动效令牌，墨水屏 / 减弱动效归零）。
          body: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            child: snap.connectionState != ConnectionState.done
                ? const Center(
                    key: ValueKey<String>('person-loading'),
                    child: FushiCircularProgressIndicator(),
                  )
                : KeyedSubtree(
                    key: const ValueKey<String>('person-body'),
                    child: data == null
                        ? Center(child: Text(t.person_empty))
                        : _body(context, tokens, data),
                  ),
          ),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    FushiDesignTokens tokens,
    PersonPageData data,
  ) {
    final List<Widget> children = <Widget>[
      _PersonHeader(data: data, bridge: _bridge),
      if (data.videoRoles.isNotEmpty)
        _WorkRail(
          title: t.person_section_anime_roles,
          railKey: 'person-anime-roles',
          cards: <_WorkCardData>[
            for (final PersonVideoRole r in data.videoRoles)
              _WorkCardData(
                link: r.work,
                primary: r.characterName ?? r.work.entry.title,
                secondary: r.characterName == null ? null : r.work.entry.title,
              ),
          ],
          onOpen: _open,
        ),
      if (data.gameRoles.isNotEmpty)
        _WorkRail(
          title: t.person_section_game_roles,
          railKey: 'person-game-roles',
          cards: <_WorkCardData>[
            for (final PersonGameRole r in data.gameRoles)
              _WorkCardData(
                link: r.work,
                primary: r.characterName,
                secondary: <String>[
                  r.work.entry.title,
                  if (r.note != null) r.note!,
                ].join(' · '),
              ),
          ],
          onOpen: _open,
        ),
      _SongsSection(songs: data.songs, onOpen: _open),
      if (data.videoStaff.isNotEmpty)
        _WorkRail(
          title: t.person_section_video_staff,
          railKey: 'person-video-staff',
          cards: <_WorkCardData>[
            for (final PersonVideoRole r in data.videoStaff)
              _WorkCardData(
                link: r.work,
                primary: r.work.entry.title,
                secondary: r.roleLabel,
              ),
          ],
          onOpen: _open,
        ),
      if (data.suggestions.isNotEmpty)
        _SuggestionsSection(
          suggestions: data.suggestions,
          onDecide: (PersonSuggestion s, bool same) =>
              unawaited(_decide(data.cluster, s, same: same)),
        ),
      _IdentitiesSection(
        cluster: data.cluster,
        manualPairs: data.manualPairs,
        onUnmerge: (pair) => unawaited(_unmerge(pair)),
      ),
    ];
    return FushiEntranceScope(
      child: ListView.separated(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(
            0,
            MediaQuery.paddingOf(context).top + tokens.spacing.gap,
            0,
            tokens.spacing.section,
          ),
        ),
        itemCount: children.length,
        separatorBuilder: (_, _) => SizedBox(height: tokens.spacing.gap),
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => children[i],
        ),
      ),
    );
  }
}

/// 卡片 / 头像的图：本地文件优先，其次 URL；都没有 null。
ImageProvider? personImageOf(String? path, String? url) {
  if (path != null && path.isNotEmpty && File(path).existsSync()) {
    return FileImage(File(path));
  }
  if (url != null && url.isNotEmpty) return AppCachedHttpImage(url);
  return null;
}

String personDomainLabel(PersonRefDomain d) => switch (d) {
  PersonRefDomain.video => t.person_domain_video,
  PersonRefDomain.game => t.person_domain_game,
  PersonRefDomain.music => t.person_domain_music,
};

/// 外部 id scheme 的显示名（站点名，不翻译）。
String personIdSchemeLabel(String scheme) => switch (scheme) {
  PersonIdScheme.anidb => 'AniDB',
  PersonIdScheme.mal => 'MAL',
  PersonIdScheme.tmdb => 'TMDB',
  PersonIdScheme.vndb => 'VNDB',
  PersonIdScheme.musicbrainz => 'MusicBrainz',
  PersonIdScheme.wikidata => 'Wikidata',
  _ => scheme,
};

/// 曲目署名角色的显示名（未知角色原样显示）。
String personMusicRoleLabel(String role) => switch (role) {
  'vocal_cv' => t.person_music_role_vocal_cv,
  'artist' => t.person_music_role_artist,
  'album_artist' => t.person_music_role_album_artist,
  'featured' => t.person_music_role_featured,
  'composer' => t.person_music_role_composer,
  'lyricist' => t.person_music_role_lyricist,
  'arranger' => t.person_music_role_arranger,
  'character' => t.person_music_role_character,
  _ => role,
};

class _PersonHeader extends StatelessWidget {
  const _PersonHeader({required this.data, required this.bridge});

  final PersonPageData data;
  final _BridgeState bridge;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ImageProvider? photo = personImageOf(data.photoPath, data.photoUrl);
    final List<String> others = data.cluster.otherNames;
    final Widget placeholder = ColoredBox(
      color: cs.secondaryContainer,
      child: Center(
        child: FushiIcon(
          FushiIcons.person,
          size: 40,
          color: cs.onSecondaryContainer,
        ),
      ),
    );
    final List<Widget> chips = <Widget>[
      for (final String scheme in PersonIdScheme.all)
        for (final String v in data.cluster.idsOf(scheme))
          FushiChip(label: Text('${personIdSchemeLabel(scheme)} $v')),
    ];
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: FushiAnimatedSize(
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.standard,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ClipOval(
                  child: SizedBox.square(
                    dimension: 96,
                    child: photo == null
                        ? placeholder
                        : Image(
                            image: photo,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => placeholder,
                          ),
                  ),
                ),
                SizedBox(width: tokens.spacing.section),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        data.cluster.displayName,
                        key: const ValueKey<String>('person-name'),
                        style: context.fushiType.headlineSmall,
                      ),
                      if (others.isNotEmpty)
                        Text(
                          others.join(' / '),
                          style: context.fushiType.bodyMedium.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (chips.isNotEmpty) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Wrap(spacing: 6, runSpacing: 6, children: chips),
            ],
            if (bridge != _BridgeState.idle) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                bridge == _BridgeState.checking
                    ? t.person_bridge_checking
                    : t.person_bridge_failed,
                key: const ValueKey<String>('person-bridge-status'),
                style: context.fushiType.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkCardData {
  const _WorkCardData({
    required this.link,
    required this.primary,
    this.secondary,
  });

  final PersonWorkLink link;
  final String primary;
  final String? secondary;
}

/// 一条横滚作品卡轨道（区块标题 + 错峰进场卡片；鼠标拖动横滚）。
class _WorkRail extends StatelessWidget {
  const _WorkRail({
    required this.title,
    required this.cards,
    required this.onOpen,
    required this.railKey,
  });

  static const double _cardWidth = 116;
  static const double _imageHeight = 156;
  static const double _textHeight = 72;

  final String title;
  final List<_WorkCardData> cards;
  final ValueChanged<MediaLinkEntry> onOpen;
  final String railKey;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      key: ValueKey<String>(railKey),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          child: FushiSectionTitle('$title · ${cards.length}'),
        ),
        SizedBox(
          height: _imageHeight + _textHeight + 8,
          child: FushiEntranceScope(
            replayKey: cards.length,
            child: HorizontalDragScrollable(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: desktopAwareScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
                itemCount: cards.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int i) => _WorkCard(
                    key: ValueKey<String>('$railKey-$i'),
                    data: cards[i],
                    onOpen: onOpen,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WorkCard extends StatelessWidget {
  const _WorkCard({required this.data, required this.onOpen, super.key});

  final _WorkCardData data;
  final ValueChanged<MediaLinkEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MediaLinkEntry entry = data.link.entry;
    final ImageProvider? image = personImageOf(
      data.link.imagePath,
      data.link.imageUrl,
    );
    final Widget placeholder = ColoredBox(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: FushiIcon(
          mediaLinkKindIcon(entry.endpoint.kind),
          size: 32,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
    final bool enabled = entry.inLibrary;
    return FushiHoverLift(
      enabled: enabled,
      builder: (BuildContext context, bool _) => SizedBox(
        width: _WorkRail._cardWidth,
        child: FushiCard(
          padding: EdgeInsets.zero,
          onTap: enabled ? () => onOpen(entry) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: _WorkRail._cardWidth,
                height: _WorkRail._imageHeight,
                child: Opacity(
                  opacity: enabled ? 1 : 0.45,
                  child: image == null
                      ? placeholder
                      : Image(
                          image: image,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => placeholder,
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      data.primary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.labelLargeEmphasized,
                    ),
                    if (data.secondary case final String s)
                      Text(
                        s,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.fushiType.bodySmall.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SongsSection extends StatelessWidget {
  const _SongsSection({required this.songs, required this.onOpen});

  final List<PersonSong> songs;
  final ValueChanged<MediaLinkEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (songs.isEmpty) {
      // 音乐侧还没有演唱署名（音乐刮削未写入 vocal_cv / character）时的空态。
      return Padding(
        key: const ValueKey<String>('person-songs-empty'),
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiSectionTitle(t.person_section_songs),
            Text(
              t.person_songs_empty,
              style: context.fushiType.bodyMedium.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      key: const ValueKey<String>('person-songs'),
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSectionTitle('${t.person_section_songs} · ${songs.length}'),
          for (int i = 0; i < songs.length; i++)
            FushiStaggeredEntrance(
              index: i,
              child: FushiListItem(
                key: ValueKey<String>('person-song-$i'),
                leading: const FushiIcon(FushiIcons.music),
                title: Text(songs[i].work.entry.title),
                subtitle: Text(
                  <String>[
                    ...songs[i].roles.map(personMusicRoleLabel),
                    for (final String c in songs[i].characterNames)
                      t.person_song_character(name: c),
                  ].join(' · '),
                ),
                onTap: () => onOpen(songs[i].work.entry),
              ),
            ),
        ],
      ),
    );
  }
}

class _SuggestionsSection extends StatelessWidget {
  const _SuggestionsSection({
    required this.suggestions,
    required this.onDecide,
  });

  final List<PersonSuggestion> suggestions;
  final void Function(PersonSuggestion s, bool same) onDecide;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      key: const ValueKey<String>('person-suggestions'),
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSectionTitle(t.person_section_suggestions),
          for (int i = 0; i < suggestions.length; i++)
            FushiStaggeredEntrance(
              index: i,
              child: Padding(
                padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                child: FushiCard(
                  key: ValueKey<String>('person-suggestion-$i'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        suggestions[i].other.displayName,
                        style: context.fushiType.titleSmall,
                      ),
                      Text(
                        <String>[
                          t.person_suggestion_reason(
                            name: suggestions[i].matchedName,
                          ),
                          ...<PersonRefDomain>{
                            for (final PersonRecord r
                                in suggestions[i].other.records)
                              r.domain,
                          }.map(personDomainLabel),
                        ].join(' · '),
                        style: context.fushiType.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: <Widget>[
                          FushiTextButton(
                            key: ValueKey<String>('person-suggestion-$i-yes'),
                            onPressed: () => onDecide(suggestions[i], true),
                            child: Text(t.person_suggestion_confirm),
                          ),
                          FushiTextButton(
                            key: ValueKey<String>('person-suggestion-$i-no'),
                            onPressed: () => onDecide(suggestions[i], false),
                            child: Text(t.person_suggestion_reject),
                          ),
                        ],
                      ),
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

class _IdentitiesSection extends StatelessWidget {
  const _IdentitiesSection({
    required this.cluster,
    required this.manualPairs,
    required this.onUnmerge,
  });

  final PersonCluster cluster;
  final List<(String, String)> manualPairs;
  final ValueChanged<(String, String)> onUnmerge;

  String _nodeLabel(String node) {
    for (final PersonRecord r in cluster.records) {
      if (r.node == node) return '${personDomainLabel(r.domain)} · ${r.name}';
    }
    final ({String kind, String head, String value})? p = parsePersonNode(node);
    return p == null ? node : '${personIdSchemeLabel(p.head)} ${p.value}';
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      key: const ValueKey<String>('person-identities'),
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSectionTitle(t.person_section_identities),
          for (final PersonRecord r in cluster.records)
            Text(
              '${personDomainLabel(r.domain)} · ${r.name}'
              '${r.originalName == null ? '' : ' (${r.originalName})'}',
              style: context.fushiType.bodyMedium,
            ),
          for (int i = 0; i < manualPairs.length; i++)
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t.person_identity_manual_pair(
                      a: _nodeLabel(manualPairs[i].$1),
                      b: _nodeLabel(manualPairs[i].$2),
                    ),
                    style: context.fushiType.bodySmall,
                  ),
                ),
                FushiTextButton(
                  key: ValueKey<String>('person-unmerge-$i'),
                  onPressed: () => onUnmerge(manualPairs[i]),
                  child: Text(t.person_identity_unmerge),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
