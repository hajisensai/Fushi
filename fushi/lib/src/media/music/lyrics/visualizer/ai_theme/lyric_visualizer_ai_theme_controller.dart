/// 全屏歌词动画的 AI 主题状态（[AiFeature.musicVisualizerTheme]）：读每首缓存、按需生成、
/// 撤销 / 改回封面取色。宿主（`MusicLyricVisualizerView`）把 [themeFor] 当 `context.theme`
/// 交给样式。
///
/// 纪律（`fushi/CLAUDE.md` §13）：
/// - 没指派提供商（含 AI 模块关着——`resolveAiFeatureProvider` 那一处门）**一个请求都不发**：
///   手动生成进 [LyricVisualizerAiThemeStatus.noProvider]，由面板引导去「设置 › AI」；
///   自动生成静默跳过，不弹不扰。
/// - 结果过 `sanitizeAiMusicVisualizerTheme` 才落地；每次改动留上一版可撤销（见 store）。
/// - 自动生成只给「从没有过记录」的歌：用户改回过封面取色（记录非空）就不再自动生成。
library;

import 'dart:async';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_music/fushi_music.dart' show LyricTimeline;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_music_visualizer_theme_assistant.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/ai_theme/lyric_visualizer_ai_theme_store.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';

/// 要生成主题的那首歌。
@immutable
class LyricVisualizerAiThemeTrack {
  const LyricVisualizerAiThemeTrack({
    required this.uid,
    this.title,
    this.artist,
    this.timeline,
  });

  final String uid;
  final String? title;
  final String? artist;

  /// 歌词；null / 空 = 纯音乐（按歌名生成）。
  final LyricTimeline? timeline;
}

enum LyricVisualizerAiThemeStatus {
  /// 空闲（有没有主题看 [LyricVisualizerAiThemeController.record]）。
  idle,

  /// 正在读缓存。
  loading,

  /// 正在请求 AI。
  generating,

  /// 上一次生成失败（原因见 [LyricVisualizerAiThemeController.failure]）。
  failed,

  /// 手动生成时发现没有可用提供商：没发请求。
  noProvider,
}

/// 生成函数（测试替身注入点）：与 [requestAiMusicVisualizerTheme] 同签名的子集。
typedef LyricVisualizerAiThemeGenerator =
    Future<AiMusicVisualizerTheme?> Function({
      required AiProviderConfig provider,
      required String? title,
      required String? artist,
      required String lyricsSnippet,
    });

class LyricVisualizerAiThemeController extends ChangeNotifier {
  LyricVisualizerAiThemeController({
    required AiProviderConfig? Function() resolveProvider,
    required bool Function() autoGenerate,
    required bool Function() aiEnabled,
    LyricVisualizerAiThemeStore? store,
    LyricVisualizerAiThemeGenerator? generator,
    this.openAiSettings,
    int Function()? nowMs,
  }) : _resolveProvider = resolveProvider,
       _autoGenerate = autoGenerate,
       _aiEnabled = aiEnabled,
       _store = store ?? LyricVisualizerAiThemeStore(),
       _generator = generator ?? _defaultGenerator,
       _nowMs = nowMs ?? _wallClockMs;

  /// app 里的标准装配：提供商与模块门都走 [PreferencesRepository]。
  factory LyricVisualizerAiThemeController.forPrefs(
    PreferencesRepository prefs, {
    Future<void> Function(BuildContext context)? openAiSettings,
  }) => LyricVisualizerAiThemeController(
    resolveProvider: () =>
        prefs.resolveAiFeatureProvider(AiFeature.musicVisualizerTheme),
    autoGenerate: () => prefs.musicVisualizerAiThemeAuto,
    aiEnabled: () => prefs.moduleEnabled(ModuleId.ai),
    openAiSettings: openAiSettings,
  );

  final AiProviderConfig? Function() _resolveProvider;
  final bool Function() _autoGenerate;
  final bool Function() _aiEnabled;
  final LyricVisualizerAiThemeStore _store;
  final LyricVisualizerAiThemeGenerator _generator;
  final int Function() _nowMs;

  /// 「去设置 › AI」（面板里没有提供商时的按钮）。null = 不给跳转按钮。
  final Future<void> Function(BuildContext context)? openAiSettings;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  static Future<AiMusicVisualizerTheme?> _defaultGenerator({
    required AiProviderConfig provider,
    required String? title,
    required String? artist,
    required String lyricsSnippet,
  }) async {
    final AiChatClient client = AiChatClient();
    try {
      return await requestAiMusicVisualizerTheme(
        client: client,
        provider: provider,
        title: title,
        artist: artist,
        lyricsSnippet: lyricsSnippet,
        uiLanguage: LocaleSettings.currentLocale.languageTag,
      );
    } finally {
      client.close();
    }
  }

  LyricVisualizerAiThemeTrack? _track;
  LyricVisualizerAiThemeRecord _record = LyricVisualizerAiThemeRecord.empty;
  LyricVisualizerAiThemeStatus _status = LyricVisualizerAiThemeStatus.idle;
  String? _failure;

  /// 正在生成的曲目 uid（只允许一首在途：换歌后旧请求的结果照样写进它自己的缓存）。
  final Set<String> _inFlight = <String>{};
  bool _disposed = false;

  /// 入口是否显示（AI 模块开着）。没指派提供商时入口仍显示，点了引导去设置。
  bool get available => _aiEnabled();

  LyricVisualizerAiThemeTrack? get track => _track;
  LyricVisualizerAiThemeRecord get record => _record;
  LyricVisualizerAiThemeStatus get status => _status;

  /// 失败短码（已脱敏，交 `aiFailureText` 转文案）；`empty` = 回复不可用。
  String? get failure => _failure;

  AiMusicVisualizerTheme? get current => _record.current;

  /// 交给样式的主题：只认当前这首的记录（换歌后、读到新记录前不把上一首的配色套过来）。
  /// AI 模块关着时一律不套（与「从没配过 AI」一致）。
  LyricVisualizerTheme? themeFor(String trackUid, Brightness brightness) {
    if (_track?.uid != trackUid || !_aiEnabled()) return null;
    return _record.current?.toVisualizerTheme(brightness);
  }

  void _set(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  /// 宿主换到 [track] 时调。同一首重复调只更新歌词等信息，不重读。
  Future<void> attach(LyricVisualizerAiThemeTrack track) async {
    final bool same = _track?.uid == track.uid;
    _track = track;
    if (same) return;
    // 不在这里通知：宿主在 initState / didUpdateWidget 里调，同步通知会在建树中途 setState。
    // 宿主随后的 build 本来就会读到新状态（[themeFor] 对新 uid 先回 null）。
    _record = LyricVisualizerAiThemeRecord.empty;
    _failure = null;
    _status = _inFlight.contains(track.uid)
        ? LyricVisualizerAiThemeStatus.generating
        : LyricVisualizerAiThemeStatus.loading;
    final LyricVisualizerAiThemeRecord loaded = await _store.load(track.uid);
    if (_disposed || _track?.uid != track.uid) return;
    _set(() {
      _record = loaded;
      if (_status == LyricVisualizerAiThemeStatus.loading) {
        _status = LyricVisualizerAiThemeStatus.idle;
      }
    });
    if (loaded.isEmpty &&
        !_inFlight.contains(track.uid) &&
        _aiEnabled() &&
        _autoGenerate() &&
        _resolveProvider() != null) {
      await generate(auto: true);
    }
  }

  /// 为当前这首生成（覆盖已有的，旧的进上一版）。返回是否生成成功。
  /// 没有可用提供商：不发请求，手动时进 [LyricVisualizerAiThemeStatus.noProvider]。
  Future<bool> generate({bool auto = false}) async {
    final LyricVisualizerAiThemeTrack? track = _track;
    if (track == null || track.uid.isEmpty) return false;
    if (_inFlight.contains(track.uid)) return false;
    final AiProviderConfig? provider = _aiEnabled() ? _resolveProvider() : null;
    if (provider == null) {
      if (!auto) {
        _set(() => _status = LyricVisualizerAiThemeStatus.noProvider);
      }
      return false;
    }
    _inFlight.add(track.uid);
    _set(() {
      _status = LyricVisualizerAiThemeStatus.generating;
      _failure = null;
    });
    AiMusicVisualizerTheme? theme;
    String? failure;
    try {
      theme = await _generator(
        provider: provider,
        title: track.title,
        artist: track.artist,
        lyricsSnippet: aiVisualizerLyricsSnippet(track.timeline),
      );
      if (theme == null) failure = 'empty';
    } on AiChatFailure catch (e) {
      failure = e.message;
    } finally {
      _inFlight.remove(track.uid);
    }
    if (theme != null) {
      // 以磁盘上的为底：换歌期间界面上的 _record 可能已经是别的歌。
      final LyricVisualizerAiThemeRecord base = _track?.uid == track.uid
          ? _record
          : await _store.load(track.uid);
      final LyricVisualizerAiThemeRecord next = base.replacedWith(
        theme,
        nowMs: _nowMs(),
      );
      await _store.save(track.uid, next);
      if (_track?.uid == track.uid) {
        _set(() {
          _record = next;
          _status = LyricVisualizerAiThemeStatus.idle;
        });
      }
      return true;
    }
    if (_track?.uid == track.uid) {
      _set(() {
        _failure = failure;
        _status = LyricVisualizerAiThemeStatus.failed;
      });
    }
    return false;
  }

  /// 撤销上一次改动（生成 / 改回封面取色 / 撤销都算）。
  Future<void> revert() async {
    final LyricVisualizerAiThemeTrack? track = _track;
    if (track == null || !_record.hasPrevious) return;
    final LyricVisualizerAiThemeRecord next = _record.reverted(nowMs: _nowMs());
    await _store.save(track.uid, next);
    if (_track?.uid != track.uid) return;
    _set(() {
      _record = next;
      _status = LyricVisualizerAiThemeStatus.idle;
    });
  }

  /// 改回封面取色（当前主题进上一版，可撤销）。
  Future<void> clear() async {
    final LyricVisualizerAiThemeTrack? track = _track;
    if (track == null || _record.current == null) return;
    final LyricVisualizerAiThemeRecord next = _record.replacedWith(
      null,
      nowMs: _nowMs(),
    );
    await _store.save(track.uid, next);
    if (_track?.uid != track.uid) return;
    _set(() {
      _record = next;
      _status = LyricVisualizerAiThemeStatus.idle;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
