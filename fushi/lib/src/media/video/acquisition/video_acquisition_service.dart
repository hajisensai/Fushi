/// 「AI 下视频」的编排器：把 reducer 产出的效果真正跑起来。
///
/// 这一层有 IO、无 Flutter。所有外部能力（搜作品 / 拉详情 / 查库 / 搜资源 / AI 解析 /
/// AI 判定 / 写偏好 / 入队 / 建订阅）都是 [VideoAcquisitionPorts] 里的闭包，由首页
/// 组合根注入；测试用假端口驱动整条对话。
///
/// 执行模型：`_dispatch(event)` → `reduceVideoAcquisition` → 新状态广播 → 逐个执行
/// 效果，每个效果的结果再变成事件回灌。效果串行执行（同一时刻最多一个 IO 在飞），
/// 事件进队列不重入——reducer 是纯函数，这里是唯一的时序真相。
library;

import 'dart:async';
import 'dart:collection';

import 'package:fushi/src/ai/ai_chat_client.dart' show AiChatFailure;
import 'package:fushi/src/ai/ai_video_acquisition_assistant.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/media/video/acquisition/video_acquisition_reducer.dart';
import 'package:fushi/src/media/video/download/video_discovery_submit.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';

/// 编排器依赖的全部外部能力。每个都是闭包，方便组合根按需现取 / 测试注入。
class VideoAcquisitionPorts {
  const VideoAcquisitionPorts({
    required this.searchWorks,
    required this.loadDetails,
    required this.queryPresence,
    required this.isSubscribed,
    required this.searchResources,
    required this.parseIntent,
    required this.decideIdentity,
    required this.persistPreference,
    required this.setSeriesSubtitleLanguage,
    required this.submitDownload,
    required this.submitSubscription,
  });

  /// 发现聚合搜索（`VideoDiscoveryController.load`）。
  final Future<ProviderBatchResult<VideoDiscoveryPage>> Function(
    VideoDiscoveryRequest request,
  )
  searchWorks;

  /// 拉完整作品资料（TMDB 搜索项没有 status，必须走它）；拿不到给 null。
  final Future<VideoMetadataWork?> Function(VideoDiscoveryItem item)
  loadDetails;

  /// 这部作品在不在库 / 已下到第几集；组合根按 `externalIds` 逐对身份试到命中。
  final Future<VideoLibraryPresence?> Function(VideoMediaReference reference)
  queryPresence;

  /// 本机是否已有启用中的订阅。
  final Future<bool> Function(VideoMediaReference reference) isSubscribed;

  final Future<ProviderBatchResult<VideoResourceCandidate>> Function(
    VideoResourceSearchRequest request,
  )
  searchResources;

  /// AI 意图解析；**null = 未指派提供商**（功能退化成纯 chip），抛 [AiChatFailure]
  /// = 调用失败。
  final Future<VideoAcquisitionIntent?> Function(
    VideoAcquisitionIntentQuery query,
  )
  parseIntent;

  /// AI 在候选里选唯一命中；null = 不确定 / 未指派 / 失败。
  final AiVideoIdentityDecider decideIdentity;

  final Future<void> Function(
    VideoAcquisitionPreference preference,
    String value,
  )
  persistPreference;

  /// 写每系列字幕语言记忆（键与导入落库的合集名同源）。
  final Future<void> Function(
    VideoMediaReference reference,
    String languageCode,
  )
  setSeriesSubtitleLanguage;

  /// 入队；返回真正入队的条数。
  final Future<int> Function(VideoAcquisitionSubmitDownloadEffect effect)
  submitDownload;

  final Future<void> Function(VideoAcquisitionSubmitSubscriptionEffect effect)
  submitSubscription;
}

class VideoAcquisitionService {
  VideoAcquisitionService({
    required VideoAcquisitionPorts ports,
    required VideoAcquisitionDefaults defaults,
    VideoAcquisitionState initial = const VideoAcquisitionState(),
  }) : _ports = ports,
       _defaults = defaults,
       _state = initial;

  final VideoAcquisitionPorts _ports;
  final VideoAcquisitionDefaults _defaults;
  final StreamController<VideoAcquisitionState> _states =
      StreamController<VideoAcquisitionState>.broadcast();
  final Queue<VideoAcquisitionEvent> _queue = Queue<VideoAcquisitionEvent>();
  VideoAcquisitionState _state;
  bool _draining = false;
  bool _disposed = false;

  /// 最近一次提交 / 效果失败的原始异常，页面据此选 SnackBar 动作（配置后端 /
  /// 重试）。reducer 只看得到脱敏后的 message。
  Object? lastError;

  VideoAcquisitionState get state => _state;
  VideoAcquisitionDefaults get defaults => _defaults;
  Stream<VideoAcquisitionState> get states => _states.stream;

  /// 用户输入了一句话。
  Future<void> submitText(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return Future<void>.value();
    return dispatch(VideoAcquisitionUserTextEvent(trimmed));
  }

  /// 用户点了当前问题的一个选项。
  Future<void> choose(
    VideoAcquisitionSlot slot,
    String optionId, {
    bool? remember,
  }) => dispatch(
    VideoAcquisitionChipChosenEvent(
      slot: slot,
      optionId: optionId,
      remember: remember,
    ),
  );

  /// 「换一个」。
  Future<void> next() =>
      choose(VideoAcquisitionSlot.resource, kVideoAcquisitionOptionNext);

  /// 「就这个」。
  Future<void> confirm() =>
      choose(VideoAcquisitionSlot.resource, kVideoAcquisitionOptionConfirm);

  Future<void> cancel() => dispatch(const VideoAcquisitionCancelEvent());

  /// 把事件喂给 reducer 并执行它产出的效果；返回的 Future 在**本事件引发的整条
  /// 效果链**跑完后完成（含回灌事件），测试据此同步等待。
  Future<void> dispatch(VideoAcquisitionEvent event) async {
    if (_disposed) return;
    _queue.add(event);
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final VideoAcquisitionEvent next = _queue.removeFirst();
        final (
          VideoAcquisitionState nextState,
          List<VideoAcquisitionEffect> effects,
        ) = reduceVideoAcquisition(
          _state,
          next,
          _defaults,
        );
        _state = nextState;
        _states.add(nextState);
        for (final VideoAcquisitionEffect effect in effects) {
          if (_disposed) return;
          // 一批效果是一个事务：前一个失败，后面的不再跑。`_submit` 产出的是
          // `[SetSeriesSubtitleLanguage, SubmitDownload]`——记忆写失败若照旧入队，
          // 队列里就是 [Failed, Submitted]：Failed 先把会话拉回「就这个」确认态，
          // 随后 Submitted 因阶段不符被丢弃——UI 报失败、下载其实已入队，用户再点
          // 一次就是重复入队。
          if (!await _run(effect)) break;
        }
      }
    } finally {
      _draining = false;
    }
  }

  void dispose() {
    _disposed = true;
    _queue.clear();
    _states.close();
  }

  /// 返回 false 表示这个效果失败（已回灌 failed 事件），同批后续效果不再执行。
  /// 搜索类效果自己把失败变成事件、不中断批次；写入类效果经 [_guard]。
  Future<bool> _run(VideoAcquisitionEffect effect) async {
    switch (effect) {
      case VideoAcquisitionParseIntentEffect():
        await _parseIntent(effect.utterance);
      case VideoAcquisitionSearchWorksEffect():
        await _searchWorks(effect);
      case VideoAcquisitionDecideIdentityEffect():
        await _decideIdentity(effect.query);
      case VideoAcquisitionLoadDetailsEffect():
        await _loadDetails(effect.item);
      case VideoAcquisitionSearchResourcesEffect():
        await _searchResources(effect);
      case VideoAcquisitionPersistPreferenceEffect():
        return _guard(
          () => _ports.persistPreference(effect.preference, effect.value),
        );
      case VideoAcquisitionSetSeriesSubtitleLanguageEffect():
        return _guard(
          () => _ports.setSeriesSubtitleLanguage(
            effect.reference,
            effect.languageCode,
          ),
        );
      case VideoAcquisitionSubmitDownloadEffect():
        return _guard(() async {
          final int count = await _ports.submitDownload(effect);
          _queue.add(VideoAcquisitionSubmittedEvent(count: count));
        });
      case VideoAcquisitionSubmitSubscriptionEffect():
        return _guard(() async {
          await _ports.submitSubscription(effect);
          _queue.add(const VideoAcquisitionSubmittedEvent(count: 1));
        });
      case VideoAcquisitionCloseEffect():
        break;
    }
    return true;
  }

  /// 效果失败 → 记住原始异常、回灌 failed 事件、返回 false；绝不让异常冲出
  /// dispatch。
  Future<bool> _guard(Future<void> Function() body) async {
    try {
      await body();
      return true;
    } catch (error) {
      lastError = error;
      _queue.add(VideoAcquisitionFailedEvent(_describe(error)));
      return false;
    }
  }

  Future<void> _parseIntent(String utterance) async {
    final VideoAcquisitionIntentQuery query = VideoAcquisitionIntentQuery(
      locale: _defaults.locale,
      stage: _state.stage.name,
      pendingQuestion: _state.question,
      slots: _slotsSnapshot(),
      history: _recentHistory(),
      utterance: utterance,
    );
    VideoAcquisitionIntent? intent;
    String? failure;
    try {
      intent = await _ports.parseIntent(query);
    } on AiChatFailure catch (error) {
      failure = error.message;
    } catch (error) {
      lastError = error;
      failure = 'network_error';
    }
    if (intent == null) {
      _queue.add(
        VideoAcquisitionAiUnavailableEvent(
          utterance: utterance,
          code: failure ?? 'provider_not_configured',
        ),
      );
      return;
    }
    _queue.add(VideoAcquisitionAiIntentEvent(intent, utterance: utterance));
  }

  Map<String, Object?> _slotsSnapshot() {
    final VideoAcquisitionSlots slots = _state.slots;
    final VideoMediaReference? reference = _state.reference;
    return <String, Object?>{
      'workTitle': reference?.title,
      'workChosen': reference != null,
      'workKind': reference?.mediaKind.name,
      'airing': _state.airing?.name,
      'mode': slots.mode?.name,
      'quality': slots.quality?.storageKey,
      'subtitleLanguage': slots.subtitleLanguage,
      'season': slots.season,
      'episodes': switch (slots.episodes) {
        VideoAcquisitionAllEpisodes() => 'all',
        VideoAcquisitionSingleEpisode(:final int episode) => episode,
        VideoAcquisitionEpisodeRange(:final int from, :final int to) =>
          '$from-$to',
      },
    };
  }

  /// 最近 6 条对话（助手句只给种类名，页面文案不回传给模型）。
  List<({String role, String text})> _recentHistory() {
    final List<VideoAcquisitionMessage> transcript = _state.transcript;
    final int start = transcript.length > 6 ? transcript.length - 6 : 0;
    return <({String role, String text})>[
      for (final VideoAcquisitionMessage message in transcript.sublist(start))
        switch (message) {
          VideoAcquisitionUserMessage(:final String text) => (
            role: 'user',
            text: text,
          ),
          VideoAcquisitionAssistantMessage(:final VideoAcquisitionSay say) => (
            role: 'assistant',
            text: say.kind.name,
          ),
        },
    ];
  }

  Future<void> _searchWorks(VideoAcquisitionSearchWorksEffect effect) async {
    try {
      final ProviderBatchResult<VideoDiscoveryPage> result = await _ports
          .searchWorks(
            VideoDiscoveryRequest(
              query: effect.query,
              category: effect.category,
              pageSize: 10,
            ),
          );
      final List<VideoDiscoveryItem> items = <VideoDiscoveryItem>[
        for (final VideoDiscoveryPage page in result.items) ...page.items,
      ];
      // 一个来源都没成功（网络 / 限流 / 未配置）时不是「没找到」，是「搜不了」：
      // 把脱敏后的来源失败说出来，否则用户只会一遍遍换名字。
      if (items.isEmpty &&
          result.successfulProviderCount == 0 &&
          result.failures.isNotEmpty) {
        _queue.add(VideoAcquisitionFailedEvent(result.failures.first.message));
        return;
      }
      _queue.add(
        VideoAcquisitionWorksLoadedEvent(query: effect.query, items: items),
      );
    } catch (error) {
      lastError = error;
      _queue.add(VideoAcquisitionFailedEvent(_describe(error)));
    }
  }

  Future<void> _decideIdentity(AiVideoIdentityQuery query) async {
    AiVideoIdentityDecision? decision;
    try {
      decision = await _ports.decideIdentity(query);
    } catch (error, stack) {
      // AI 判定失败 = 不确定：候选照旧交给用户点选。降级是对的，但不能静默——
      // `lastError` 只在 failed 那句出现时才被页面读，这里不产生 failed。
      lastError = error;
      decision = null;
      ErrorLogService.instance.logDiagnostic(
        'VideoAcquisition.decideIdentity',
        '$error\n$stack',
      );
    }
    _queue.add(VideoAcquisitionIdentityDecidedEvent(decision));
  }

  Future<void> _loadDetails(VideoDiscoveryItem item) async {
    VideoMetadataWork? work;
    VideoLibraryPresence? presence;
    bool subscribed = false;
    try {
      work = await _ports.loadDetails(item);
    } catch (error, stack) {
      // 详情拉不到就用搜索项自带的资料；放送状态未知时对话层会照样问模式。
      // Jikan 整站 504 就落在这里，必须留痕。
      lastError = error;
      ErrorLogService.instance.logDiagnostic(
        'VideoAcquisition.loadDetails',
        '${item.reference.title}: $error\n$stack',
      );
    }
    try {
      presence = await _ports.queryPresence(item.reference);
      subscribed = await _ports.isSubscribed(item.reference);
    } catch (error, stack) {
      // 「已在库 / 已订阅」查不到时按未知继续——后果是可能重复建订阅，所以这条
      // 至少要进诊断日志，不能当 null 静默吞掉。
      lastError = error;
      ErrorLogService.instance.logDiagnostic(
        'VideoAcquisition.presence',
        '${item.reference.title}: $error\n$stack',
      );
    }
    _queue.add(
      VideoAcquisitionDetailsLoadedEvent(
        work: work,
        presence: presence,
        alreadySubscribed: subscribed,
      ),
    );
  }

  Future<void> _searchResources(
    VideoAcquisitionSearchResourcesEffect effect,
  ) async {
    try {
      final ProviderBatchResult<VideoResourceCandidate> result = await _ports
          .searchResources(
            VideoResourceSearchRequest(
              media: effect.reference,
              query: videoResourceSubscriptionSearchQuery(effect.reference),
              season: effect.season,
            ),
          );
      _queue.add(VideoAcquisitionResourcesLoadedEvent(result.items));
    } catch (error) {
      lastError = error;
      _queue.add(VideoAcquisitionFailedEvent(_describe(error)));
    }
  }

  static String _describe(Object error) {
    final String text = error.toString();
    // 已经脱敏过的短码 / 面向用户的消息直接用；其它异常只留类型名，不把 URL /
    // 凭据回显进对话。
    if (error is AiChatFailure) return error.message;
    return text.length > 200 ? error.runtimeType.toString() : text;
  }
}
