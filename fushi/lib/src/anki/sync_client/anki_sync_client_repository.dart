import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/anki_sync/anki_sync_miner.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';
import 'package:fushi_engine/anki_sync/fushi_anki_sync_client.dart';

/// 「Anki 同步客户端」后端：设备上不装 Anki，Fushi 把卡写进本地 collection
/// （官方 rslib，经 `fushi-anki-sync`），再同步到 AnkiWeb 或用户自建的 Anki 同步服务器。
///
/// 制卡本身（渲染 / 查重 / 写库）在 [AnkiSyncMiner]，无头服务端当落地设备时用的是
/// 同一份；这里只负责设置（基类的 SharedPreferences）与配置界面要的查询。
/// 未同步的卡由 [AnkiSyncSession] 的日志兜底，整库下载后会重放。
///
/// 实例是无状态的：进程、库、日志都在 [session] 里（全 app 一份），
/// `createAnkiRepository()` 被频繁调用也只是新建一个薄壳。
class AnkiSyncClientRepository extends BaseAnkiRepository {
  AnkiSyncClientRepository({required AnkiSyncSession? session})
    : _session = session,
      _miner = session == null ? null : AnkiSyncMiner(session);

  /// null = 本机没有 `fushi-anki-sync`（平台 / 安装包不带）。
  final AnkiSyncSession? _session;
  final AnkiSyncMiner? _miner;

  /// 由名字派生的稳定 id（FNV-1a 32 位）：helper 只给名字，按列表下标编号会在服务器
  /// 上多一个牌组后整体错位，把卡写进别的牌组。
  static int stableIdFor(String name) {
    int hash = 0x811c9dc5;
    for (final int byte in utf8.encode(name)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async {
    final AnkiSyncSession? session = _session;
    if (session == null) {
      return const AnkiFetchResult.error(
        'fushi-anki-sync is not available on this device.',
        code: AnkiErrorCode.syncClientUnavailable,
      );
    }
    try {
      final AnkiSyncMeta meta = await session.meta();
      final List<AnkiDeck> decks = <AnkiDeck>[
        for (final String d in meta.decks)
          AnkiDeck(id: stableIdFor(d), name: d),
      ];
      final List<AnkiNoteType> noteTypes = <AnkiNoteType>[
        for (final AnkiSyncNotetype n in meta.notetypes)
          AnkiNoteType(id: stableIdFor(n.name), name: n.name, fields: n.fields),
      ];
      if (decks.isEmpty || noteTypes.isEmpty) {
        return const AnkiFetchResult.error(
          'No decks or note types in the synced collection.',
        );
      }
      final AnkiSettings updated = await updateSettings((AnkiSettings current) {
        final AnkiDeck deck = selectDeckAfterFetch(decks, current);
        final AnkiNoteType noteType = selectNoteTypeAfterFetch(
          noteTypes,
          current,
        );
        return current.copyWith(
          selectedDeckId: deck.id,
          selectedDeckName: deck.name,
          selectedNoteTypeId: noteType.id,
          selectedNoteTypeName: noteType.name,
          availableDecks: decks,
          availableNoteTypes: noteTypes,
          fieldMappings: fieldMappingsAfterFetch(noteType, current),
        );
      });
      return AnkiFetchResult.success(
        decks: updated.availableDecks,
        noteTypes: updated.availableNoteTypes,
      );
    } on AnkiSyncNotSignedIn {
      return const AnkiFetchResult.error(
        'Sign in to the Anki sync server first.',
        code: AnkiErrorCode.syncClientSignedOut,
      );
    } catch (e) {
      return AnkiFetchResult.error('$e');
    }
  }

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final AnkiSyncMiner? miner = _miner;
    if (miner == null) {
      return MineOutcome.failure(
        'fushi-anki-sync is not available on this device.',
        errorCode: AnkiErrorCode.syncClientUnavailable,
      );
    }
    return miner.mine(
      settings: await loadSettings(),
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async {
    final AnkiSyncMiner? miner = _miner;
    if (miner == null || expression.isEmpty) return false;
    final AnkiNoteType? noteType = miner.selectedNoteType(await loadSettings());
    if (noteType == null) return false;
    try {
      return await miner.session.isDuplicate(
        notetype: noteType.name,
        firstField: expression,
      );
    } catch (_) {
      // 查重是每次查词都跑的高频路径：没登录 / helper 起不来时回「不重复」，
      // 真正制卡时 mineEntry 会把原因报给用户。
      return false;
    }
  }

  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) async {
    final AnkiSyncMiner? miner = _miner;
    if (miner == null || expression.isEmpty) return const <MinedNoteRef>[];
    final AnkiNoteType? noteType = miner.selectedNoteType(await loadSettings());
    if (noteType == null) return const <MinedNoteRef>[];
    try {
      return <MinedNoteRef>[
        for (final AnkiSyncNoteHit h in await miner.session.findNotes(
          notetype: noteType.name,
          firstField: expression,
        ))
          MinedNoteRef(noteId: h.noteId, preview: h.preview),
      ];
    } catch (_) {
      return const <MinedNoteRef>[];
    }
  }

  /// 没有 Anki 界面可以打开，也不能在这里建笔记类型 / 牌组（牌组会在第一次
  /// 加卡时按名字自动建）：这些入口在这个后端上不可用。
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}
