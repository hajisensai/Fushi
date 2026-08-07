import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/anki/anki_media_dedup_runner.dart';
import 'package:fushi/src/anki/lapis_template_service.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/utils.dart';

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

  /// 切换查重范围（deck=所选卡组 / deckRoot=根卡组全部子卡组 / collection=整库）。
  /// 见 [AnkiDuplicateScope]：Anki 的 `deck:X` 不含父卡组与兄弟子卡组，所以把目标
  /// 选成子卡组时同一个词制在别的子卡组里就查不出来。
  Future<void> updateDuplicateScope(AnkiDuplicateScope value) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(duplicateScope: value));
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
        ankiConnectUseHttps: endpoint.useHttps ?? s.ankiConnectUseHttps,
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

  Future<void> updateUseAnkiConnectOnAndroid(bool value) async {
    final updated = await _repository.updateSettings(
      (s) => s.copyWith(
        useAnkiConnectOnAndroid: value,
        clearSelectedDeck: true,
        clearSelectedNoteType: true,
        availableDecks: const <AnkiDeck>[],
        availableNoteTypes: const <AnkiNoteType>[],
        fieldMappings: const <String, String>{},
      ),
    );
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

  // ── Lapis 样式客制化（备份/恢复/应用见 LapisTemplateService）──────────

  /// 当前后端能否读写已存在 note type 的模板（AnkiConnect true；AnkiDroid /
  /// AnkiMobile false，设置页据此隐藏 Lapis 样式区）。
  bool get supportsNoteTypeEditing => _repository.supportsNoteTypeEditing;

  /// 与当前仓库绑定的模板服务（无状态，随用随建）。
  LapisTemplateService get lapisTemplateService =>
      LapisTemplateService(_repository);

  Future<void> setLapisFontScalePercent(int percent) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(lapisFontScalePercent: percent));
    state = state.copyWith(settings: updated);
  }

  Future<void> setLapisCustomCss(String css) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(lapisCustomCss: css));
    state = state.copyWith(settings: updated);
  }

  /// 自定义区域整份覆盖（区域的增删改都在这一份列表里表达）。
  ///
  /// 只落 Hibiki 侧偏好，**不写 Anki**：区域要变成卡片上的东西，仍须用户点
  /// 「应用样式到 Anki」——那是模板写入的唯一闸门（模板写坏是卡片内容不显示，
  /// 不该由一条用户没点过的路径承担）。
  Future<void> setLapisCustomBlocks(List<LapisCustomBlock> blocks) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(lapisCustomBlocks: blocks));
    state = state.copyWith(settings: updated);
  }

  /// LapisTemplateService 落库（指纹/客制化对齐）后刷新 UI 侧 settings。
  Future<void> refreshSettingsFromStore() async {
    final settings = await _repository.loadSettings();
    state = state.copyWith(settings: settings);
  }

  // ── 媒体存储优化（字节级去重）──────────────────────────────────────

  /// 当前后端能否做媒体去重（AnkiConnect 且与 Anki 同机；设置页据此隐藏区块）。
  bool get supportsMediaMaintenance => _repository.supportsMediaMaintenance;

  /// 与当前仓库绑定的去重编排器（无状态，随用随建）。
  AnkiMediaDedupRunner get mediaDedupRunner =>
      AnkiMediaDedupRunner(_repository);

  /// 打开/关闭去重的自动处理。默认关；打开后自动路径**仍然只做干跑并提示**，
  /// 要真删得由用户在确认弹窗里点，或另外打开 [setMediaDedupAutoDelete]。
  Future<void> setMediaDedupAutoEnabled(bool enabled) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(mediaDedupAutoEnabled: enabled));
    state = state.copyWith(settings: updated);
  }

  /// 打开/关闭「自动直接删除」（跳过确认弹窗）。只在自动处理已打开时有意义。
  Future<void> setMediaDedupAutoDelete(bool enabled) async {
    final updated = await _repository
        .updateSettings((s) => s.copyWith(mediaDedupAutoDelete: enabled));
    state = state.copyWith(settings: updated);
  }
}

/// 把用户敲/粘进 AnkiConnect **主机**字段的自由文本规范化成裸主机、可选端口与协议。
///
/// AnkiConnect 使用 HTTP(S) 根路径，所以 `https://anki.example:48765/`
/// 之类的完整 URL不能被拒绝——保留 HTTP/HTTPS 语义，剥掉 scheme、path/query/
/// fragment 与 userinfo，并把尾部的数字 `:port` 拆出来交给独立端口字段（留在主机里
/// 会让 `Uri.parse('http://$host:$port')` 变成 `host:port:port` 破坏请求）。主机原样
/// 保留（不小写化、不做 IDNA punycode），用户看到的就是自己敲的值。返回的 [port] 仅在
/// 输入携带 1..65535 合法端口时非 null；非数字尾部（如错误的 IPv6/笔误）原样保留，
/// 尽力而为不擅自篡改。
@visibleForTesting
({String host, int? port, bool? useHttps}) normalizeAnkiConnectHostInput(
  String raw,
) {
  var s = raw.trim();
  bool? useHttps;
  // 只接受并保留明确的 HTTP(S) scheme；其它 scheme 不能被静默降级。
  final schemeSep = s.indexOf('://');
  if (schemeSep >= 0) {
    final String scheme = s.substring(0, schemeSep).toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return (host: '', port: null, useHttps: null);
    }
    useHttps = scheme == 'https';
    s = s.substring(schemeSep + 3);
  }
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
  return (host: s.trim(), port: port, useHttps: useHttps);
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
    // BUG-1185：主机拒绝互联 token 时查重根本没跑成。bool 契约表达不了「不知道」，
    // 所以在这里把它变成用户可见的失败提示，而不是让用户收到一个静默的「不重复」。
    onAuthRejected: (String message) => FushiToast.showMine(
      msg: message,
      status: MineToastStatus.failed,
    ),
  );
});

final ankiViewModelProvider =
    StateNotifierProvider<AnkiViewModel, AnkiUiState>((ref) {
  return AnkiViewModel(ref.watch(ankiRepositoryProvider));
});
