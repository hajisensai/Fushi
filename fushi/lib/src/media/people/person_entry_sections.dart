/// 人物聚合页的两个入口区块（作品图谱 L5）：游戏详情「配音」与曲目详情「署名」。
/// 视频侧的入口是既有人物轨道 `VideoCreditRail`（点头像即进人物页）。
///
/// 两者都复用作品详情共享骨架的 [MediaDetailCastStrip]（圆形头像横滑 + 错峰进场 +
/// 可点头像的按压 / 悬停动效），不另起一套人物卡。
library;

import 'dart:async';

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/people/person_detail_page.dart';
import 'package:fushi/src/media/people/person_directory.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/people/person_identity.dart';
import 'package:fushi_engine/media/people/vndb_voice_cast.dart';
import 'package:material_ui/material_ui.dart';

/// 游戏详情页的「配音」：VNDB `va`（角色 + 声优）。只在游戏绑了 VNDB id 时有数据；
/// 首次打开（或缓存过期 / 换绑 VN）时后台向 VNDB 取一次，取到后本区块自动刷新。
class GameVoiceCastSection extends StatefulWidget {
  const GameVoiceCastSection({
    required this.database,
    required this.gameId,
    required this.vndbId,
    this.service,
    super.key,
  });

  final FushiDatabase database;
  final String gameId;

  /// 游戏已绑定的 VNDB VN id；null = 没绑 VNDB（只显示已有缓存，不发请求）。
  final String? vndbId;

  /// 测试注入；null = 用 [GameVoiceCastService] + 进程级 VNDB 客户端。
  final GameVoiceCastService? service;

  @override
  State<GameVoiceCastSection> createState() => _GameVoiceCastSectionState();
}

class _GameVoiceCastSectionState extends State<GameVoiceCastSection> {
  late GameVoiceCastService _service =
      widget.service ?? GameVoiceCastService(widget.database);
  late Future<List<GameVoiceCredit>> _cast = _service.cached(widget.gameId);

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant GameVoiceCastSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gameId != widget.gameId ||
        oldWidget.vndbId != widget.vndbId ||
        oldWidget.database != widget.database) {
      _service = widget.service ?? GameVoiceCastService(widget.database);
      _cast = _service.cached(widget.gameId);
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final String? vndb = widget.vndbId;
    if (vndb == null || vndb.trim().isEmpty) return;
    final bool wrote = await _service.refreshIfStale(widget.gameId, vndb);
    if (!wrote || !mounted) return;
    setState(() {
      _cast = _service.cached(widget.gameId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<GameVoiceCredit>>(
      future: _cast,
      builder: (BuildContext context, AsyncSnapshot<List<GameVoiceCredit>> s) {
        final List<GameVoiceCredit> cast = s.data ?? const <GameVoiceCredit>[];
        if (cast.isEmpty) return const SizedBox.shrink();
        return MediaDetailCastStrip(
          key: const ValueKey<String>('game-voice-cast'),
          title: t.game_voice_cast_title,
          people: <MediaDetailPerson>[
            for (int i = 0; i < cast.length; i++)
              MediaDetailPerson(
                key: ValueKey<String>(
                  'game-voice-cast-${cast[i].staffId}-${cast[i].characterId}',
                ),
                name: cast[i].staffOriginal ?? cast[i].staffName,
                role: cast[i].characterOriginal ?? cast[i].characterName,
                image: cast[i].characterImageUrl == null
                    ? null
                    : AppCachedHttpImage(cast[i].characterImageUrl!),
                onImageError: (Object error) =>
                    ErrorLogService.instance.logDiagnostic(
                      'GameVoiceCastSection.image',
                      '${cast[i].characterImageUrl}: $error',
                    ),
                onTap: () => unawaited(
                  openPersonPage(
                    context,
                    seedNode: personRefNode(
                      PersonRefDomain.game,
                      cast[i].staffId,
                    ),
                    initialName: cast[i].staffOriginal ?? cast[i].staffName,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 一首曲目在「署名」轨道上的一位艺人：TA 的全部署名角色 + 同曲的角色名义。
@immutable
class MusicTrackPersonCredit {
  const MusicTrackPersonCredit({
    required this.artist,
    required this.roles,
    this.characterNames = const <String>[],
  });

  final MusicArtistRow artist;
  final List<String> roles;

  /// 同曲目上的角色名义（`character` 署名）；只挂在演唱者（`vocal_cv`）身上。
  final List<String> characterNames;
}

/// 把一首曲目的署名按艺人聚合（纯函数，便于测试）。`character` 角色的署名不当成
/// 「人」列出——它是角色名义，挂到该曲的 CV 演唱者上显示。
List<MusicTrackPersonCredit> groupMusicTrackCredits(
  List<MusicCreditWithArtist> credits,
) {
  final List<String> characters = <String>[
    for (final MusicCreditWithArtist c in credits)
      if (c.credit.role == 'character') c.credit.creditName,
  ];
  final Map<String, ({MusicArtistRow artist, List<String> roles})> byArtist =
      <String, ({MusicArtistRow artist, List<String> roles})>{};
  for (final MusicCreditWithArtist c in credits) {
    if (c.credit.role == 'character') continue;
    byArtist
        .putIfAbsent(
          c.artist.artistUid,
          () => (artist: c.artist, roles: <String>[]),
        )
        .roles
        .add(c.credit.role);
  }
  return <MusicTrackPersonCredit>[
    for (final ({MusicArtistRow artist, List<String> roles}) e
        in byArtist.values)
      MusicTrackPersonCredit(
        artist: e.artist,
        roles: e.roles,
        characterNames: e.roles.contains('vocal_cv')
            ? characters
            : const <String>[],
      ),
  ];
}

/// 曲目详情页的「署名」：一首歌的艺人 / 演唱者，点头像进人物页。音乐侧还没有署名
/// 数据时整块不渲染。
class MusicTrackPeopleSection extends StatefulWidget {
  const MusicTrackPeopleSection({
    required this.database,
    required this.trackUid,
    super.key,
  });

  final FushiDatabase database;
  final String trackUid;

  @override
  State<MusicTrackPeopleSection> createState() =>
      _MusicTrackPeopleSectionState();
}

class _MusicTrackPeopleSectionState extends State<MusicTrackPeopleSection> {
  late Future<List<MusicTrackPersonCredit>> _credits = _load();
  StreamSubscription<Set<TableUpdate>>? _sub;

  Future<List<MusicTrackPersonCredit>> _load() async => groupMusicTrackCredits(
    await widget.database.musicCreditsForTracks(<String>{widget.trackUid}),
  );

  @override
  void initState() {
    super.initState();
    // 音乐刮削补写署名后本区块跟着刷新（tableUpdates 手动订阅，不用 drift
    // `.watch()`：长驻页面订阅 watch 流在 dispose 时留 Timer，BUG-834 范式）。
    _sub = widget.database
        .tableUpdates(
          TableUpdateQuery.onTable(widget.database.musicTrackCredits),
        )
        .listen((_) {
          if (!mounted) return;
          setState(() {
            _credits = _load();
          });
        });
  }

  @override
  void didUpdateWidget(covariant MusicTrackPeopleSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackUid != widget.trackUid) _credits = _load();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MusicTrackPersonCredit>>(
      future: _credits,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<MusicTrackPersonCredit>> s,
          ) {
            final List<MusicTrackPersonCredit> list =
                s.data ?? const <MusicTrackPersonCredit>[];
            if (list.isEmpty) return const SizedBox.shrink();
            return MediaDetailCastStrip(
              key: const ValueKey<String>('music-track-people'),
              title: t.music_track_people_title,
              people: <MediaDetailPerson>[
                for (final MusicTrackPersonCredit c in list)
                  MediaDetailPerson(
                    key: ValueKey<String>(
                      'music-track-person-${c.artist.artistUid}',
                    ),
                    name: c.artist.name,
                    role: <String>[
                      ...c.roles.map(personMusicRoleLabel),
                      for (final String ch in c.characterNames)
                        t.person_song_character(name: ch),
                    ].join(' · '),
                    onTap: () => unawaited(
                      openPersonPage(
                        context,
                        seedNode: personRefNode(
                          PersonRefDomain.music,
                          c.artist.artistUid,
                        ),
                        initialName: c.artist.name,
                      ),
                    ),
                  ),
              ],
            );
          },
    );
  }
}
