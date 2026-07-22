import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/remote_mining_anki_repository.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/utils.dart';

class AnkiUiState {
  const AnkiUiState({
    this.settings = const AnkiSettings(),
    this.isFetching = false,
    this.errorMessage,
  });
  final AnkiSettings settings;
  final bool isFetching;
  final String? errorMessage;

  List<AnkiDeck> get availableDecks => settings.availableDecks;
  List<AnkiNoteType> get availableNoteTypes => settings.availableNoteTypes;
  AnkiNoteType? get selectedNoteType => settings.selectedNoteType;
  bool get isConfigured => settings.isConfigured;

  AnkiUiState copyWith({
    AnkiSettings? settings,
    bool? isFetching,
    String? errorMessage,
    bool clearError = false,
  }) =>
      AnkiUiState(
        settings: settings ?? this.settings,
        isFetching: isFetching ?? this.isFetching,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      );
}

class AnkiViewModel extends StateNotifier<AnkiUiState> {
  AnkiViewModel(this._repository) : super(const AnkiUiState()) {
    _loadSettings();
  }
  final BaseAnkiRepository _repository;

  Future<void> _loadSettings() async {
    final settings = await _repository.loadSettings();
    state = state.copyWith(settings: settings);
    if (settings.selectedDeckId != null &&
        settings.selectedNoteTypeId != null &&
        (settings.availableDecks.isEmpty ||
            settings.availableNoteTypes.isEmpty)) {
      await fetchConfiguration();
    }
  }

  Future<void> reloadSettings() => _loadSettings();

  Future<void> fetchConfiguration() async {
    state = state.copyWith(isFetching: true, clearError: true);
    final result = await _repository.fetchConfiguration();
    switch (result) {
      case AnkiFetchSuccess():
        final settings = await _repository.loadSettings();
        state = state.copyWith(settings: settings, isFetching: false);
      case AnkiFetchError(:final message, :final code):
        state = state.copyWith(
          isFetching: false,
          errorMessage: localizeAnkiFetchError(message, code),
        );
    }
  }

  /// TODO-292: map a classified AnkiDroid fetch error to a localized,
  /// actionable hint. AnkiDroid raising "collection is not available" is
  /// external app state the host app cannot fix (collection in use / mid-sync /
  /// corrupt, AnkiDroid never opened once, API disabled, background process
  /// killed); show the user what to do instead of the raw English text.
  /// Unclassified errors keep their verbatim [message].
  static String localizeAnkiFetchError(String message, String? code) {
    if (code == AnkiErrorCode.collectionUnavailable) {
      return t.anki_error_collection_unavailable;
    }
    // TODO-752a：AnkiConnect 网络错误也按稳定码本地化（与制卡 toast 同一组码），
    // 不再透传后端拼好的英文/可能乱码的 [message]。
    final String? mineLocalized = localizeAnkiMineError(code);
    if (mineLocalized != null) return mineLocalized;
    return message;
  }

  Future<void> selectDeck(AnkiDeck deck) async {
    final updated = await _repository.updateSettings((s) => s.copyWith(
          selectedDeckId: deck.id,
          selectedDeckName: deck.name,
        ));
    state = state.copyWith(settings: updated);
  }

  Future<void> selectNoteType(AnkiNoteType noteType) async {
    final updated = await _repository.updateSettings((s) => s.copyWith(
          selectedNoteTypeId: noteType.id,
          selectedNoteTypeName: noteType.name,
          fieldMappings: LapisPreset.applyDefaults(noteType, {}),
        ));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateFieldMapping(String field, String value) async {
    final trimmed = value.trim();
    final updated = await _repository.updateSettings((s) {
      final mappings = Map<String, String>.from(s.fieldMappings);
      if (trimmed.isEmpty) {
        mappings.remove(field);
      } else {
        mappings[field] = value;
      }
      return s.copyWith(fieldMappings: mappings);
    });
    state = state.copyWith(settings: updated);
  }

  Future<void> updateTags(String tags) async {
    final updated =
        await _repository.updateSettings((s) => s.copyWith(tags: tags));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateTagIncludeHibiki(bool value) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(tagIncludeHibiki: value));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateTagIncludeCategory(bool value) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(tagIncludeCategory: value));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateAllowDupes(bool value) async {
    final updated =
        await _repository.updateSettings((s) => s.copyWith(allowDupes: value));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateCompactGlossaries(bool value) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(compactGlossaries: value));
    state = state.copyWith(settings: updated);
  }

  /// TODO-614：切换「覆写已制卡片」范围（latest=仅最近一张 / all=全部已存在卡）。
  Future<void> updateOverwriteScope(AnkiOverwriteScope value) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(overwriteScope: value));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateAnkiConnectHost(String host) async {
    // 不能对含 '/'、'?'、'#' 的输入静默 return（BUG-970）：那样用户逐字符敲
    // "http://" 时，敲到第一个 '/'（"http:/"）起就全被拒，失焦回退到最后被接受的
    // "http:"，看起来像 App 把地址吃成了 "http:"。AnkiConnect 恒在 http://host:port
    // 的根路径，故把 URL 形态输入规范化成裸主机：剥 scheme / path / query / fragment /
    // userinfo，并把尾部数字 ":port" 拆到独立端口字段（保留在主机里会让
    // Uri.parse('http://$host:$port') 变成 host:port:port 破坏请求）。
    final endpoint = normalizeAnkiConnectHostInput(host);
    if (endpoint.host.isEmpty) return;
    final updated = await _repository.updateSettings(
      (s) => s.copyWith(
        ankiConnectHost: endpoint.host,
        // 仅当输入里带了合法端口才覆盖，否则保留用户在端口字段里的既有值。
        ankiConnectPort: endpoint.port ?? s.ankiConnectPort,
      ),
    );
    state = state.copyWith(settings: updated);
  }

  Future<void> updateAnkiConnectPort(String portStr) async {
    final port = int.tryParse(portStr.trim());
    if (port == null || port <= 0 || port > 65535) return;
    final updated = await _repository
        .updateSettings((s) => s.copyWith(ankiConnectPort: port));
    state = state.copyWith(settings: updated);
  }

  Future<void> updateAnkiConnectApiKey(String apiKey) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(ankiConnectApiKey: apiKey.trim()));
    state = state.copyWith(settings: updated);
  }

  Future<LapisSetupResult> createLapisSetup() async {
    state = state.copyWith(isFetching: true, clearError: true);
    try {
      final created = await _repository.createNoteType(LapisNoteType.template);
      await _repository.createDeck(LapisNoteType.deckName);

      final fetch = await _repository.fetchConfiguration();
      if (fetch is AnkiFetchError) {
        state = state.copyWith(isFetching: false, errorMessage: fetch.message);
        return LapisSetupResult(LapisSetupOutcome.failed, fetch.message);
      }

      final settings = await _repository.loadSettings();
      final noteType = settings.availableNoteTypes.firstWhere(
          (t) => t.name == LapisNoteType.modelName,
          orElse: () => settings.availableNoteTypes.first);
      final deck = settings.availableDecks.firstWhere(
          (d) => d.name == LapisNoteType.deckName,
          orElse: () => settings.availableDecks.first);

      final updated = await _repository.updateSettings((s) => s.copyWith(
            selectedDeckId: deck.id,
            selectedDeckName: deck.name,
            selectedNoteTypeId: noteType.id,
            selectedNoteTypeName: noteType.name,
            fieldMappings: LapisPreset.applyDefaults(noteType, {}),
          ));
      state = state.copyWith(settings: updated, isFetching: false);
      return LapisSetupResult(created
          ? LapisSetupOutcome.created
          : LapisSetupOutcome.alreadyExisted);
    } catch (e, stack) {
      debugPrint('AnkiViewModel.createLapisSetup: $e\n$stack');
      state = state.copyWith(isFetching: false, errorMessage: e.toString());
      return LapisSetupResult(LapisSetupOutcome.failed, e.toString());
    }
  }
}

/// 把用户敲/粘进 AnkiConnect **主机**字段的自由文本规范化成裸主机 + 可选端口。
///
/// AnkiConnect 恒在 `http://host:port` 的根路径，所以 `http://192.168.1.5:48765/`
/// 之类的完整 URL（或手敲的 `http://host`）不能被拒绝——剥掉 scheme、path/query/
/// fragment 与 userinfo，并把尾部的数字 `:port` 拆出来交给独立端口字段（留在主机里
/// 会让 `Uri.parse('http://$host:$port')` 变成 `host:port:port` 破坏请求）。主机原样
/// 保留（不小写化、不做 IDNA punycode），用户看到的就是自己敲的值。返回的 [port] 仅在
/// 输入携带 1..65535 合法端口时非 null；非数字尾部（如错误的 IPv6/笔误）原样保留，
/// 尽力而为不擅自篡改。
@visibleForTesting
({String host, int? port}) normalizeAnkiConnectHostInput(String raw) {
  var s = raw.trim();
  // 剥掉开头的 "scheme://"。
  final schemeSep = s.indexOf('://');
  if (schemeSep >= 0) s = s.substring(schemeSep + 3);
  // 在第一个 path / query / fragment 分隔符处截断。
  for (final sep in const ['/', '?', '#']) {
    final cut = s.indexOf(sep);
    if (cut >= 0) s = s.substring(0, cut);
  }
  // 丢弃 userinfo（"user:pass@host" / "user@host"）。
  final at = s.lastIndexOf('@');
  if (at >= 0) s = s.substring(at + 1);
  // 拆分尾部 ":<数字>" 作为端口；顺带清掉打字途中残留的孤立尾冒号。
  int? port;
  final colon = s.lastIndexOf(':');
  if (colon >= 0) {
    final tail = s.substring(colon + 1);
    if (tail.isEmpty) {
      s = s.substring(0, colon);
    } else {
      final parsed = int.tryParse(tail);
      if (parsed != null) {
        if (parsed > 0 && parsed <= 65535) port = parsed;
        // 数字尾部一律剥离（越界也剥），保证主机不残留冒号破坏 Uri。
        s = s.substring(0, colon);
      }
    }
  }
  return (host: s.trim(), port: port);
}

enum LapisSetupOutcome { created, alreadyExisted, failed }

class LapisSetupResult {
  const LapisSetupResult(this.outcome, [this.message]);
  final LapisSetupOutcome outcome;
  final String? message;
}

/// Anki 仓库 provider。默认返回按平台编译期选择的本地仓库（AnkiConnect/AnkiDroid/
/// AnkiMobile）。当用户开启「制卡到已配对设备」开关时，包一层 [RemoteMiningAnkiRepository]：
/// `mineEntry`/`isDuplicate` 经互联链路转发到主机（用主机的 Anki 落卡），配置类方法仍委派
/// 本地仓库——设置页据此照常配置本地 Anki（供开关关闭时使用）。零调用点改动：查词/阅读器/
/// 视频所有制卡入口都读本 provider，故一处切换即全量改道。
final ankiRepositoryProvider = Provider<BaseAnkiRepository>((ref) {
  final BaseAnkiRepository local =
      ref.watch(platformServicesProvider).createAnkiRepository();
  final bool mineToServer =
      ref.watch(appProvider.select((AppModel m) => m.mineToServerEnabled));
  if (!mineToServer) return local;
  final AppModel appModel = ref.read(appProvider);
  return RemoteMiningAnkiRepository(
    local: local,
    client: appModel.createRemoteMiningClient(),
  );
});

final ankiViewModelProvider =
    StateNotifierProvider<AnkiViewModel, AnkiUiState>((ref) {
  return AnkiViewModel(ref.watch(ankiRepositoryProvider));
});
