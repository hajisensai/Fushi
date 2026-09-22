/// 「AI」设置区：用户自配的大模型提供商增删改 + 每个功能用哪家的映射。
///
/// 形态与 `opds_server_settings_section.dart` 同构（本仓「用户自配服务器列表」的
/// 标准件）：草稿态 + 600ms 防抖落盘 + dispose 冲刷 pending + 只落「校验得过」的
/// 草稿。校验判据**一律委托给 [AiProviderConfig] 的构造器**——在 UI 里再抄一份
/// URL/HTTP 放行判据必然与它漂移，而漂移的结果是「界面说没问题、保存后条目却
/// 消失了」。
///
/// 与 OPDS 那份的两处差别：
/// - AI 提供商之间**协议不同**，所以多一个协议下拉；内置预设的协议是厂商事实，
///   锁死不给改，只有「自定义」预设才开放（改错等于直接把这家配废）。
/// - 多一层「功能 → 提供商」的映射。删掉一家提供商时必须同步清理映射
///   （[AiFeatureAssignments.withoutProvider]），否则映射悬空——调用方那边虽然
///   已经会退化成「未指派」，但设置界面会继续显示一个指向空气的选择。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_feature.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/source_toggle_section.dart';
import 'package:fushi/utils.dart';

/// 输入停止多久后落盘（与 OPDS / Torznab 段同值）。
const Duration _kSaveDebounce = Duration(milliseconds: 600);

/// 调用客户端的构造口子。默认 [AiChatClient] 自己走
/// `createAppHttpIoClient()`（统一出站装配点）；测试注入假客户端，不打真网。
typedef AiChatClientFactory = AiChatClient Function();

class AiProviderSettingsSection extends ConsumerStatefulWidget {
  const AiProviderSettingsSection({super.key, this.clientFactory});

  final AiChatClientFactory? clientFactory;

  @override
  ConsumerState<AiProviderSettingsSection> createState() =>
      _AiProviderSettingsSectionState();
}

class _AiProviderSettingsSectionState
    extends ConsumerState<AiProviderSettingsSection> {
  List<_AiProviderDraft> _drafts = <_AiProviderDraft>[];
  bool _loaded = false;
  Timer? _saveDebounce;

  /// build 期抓住的 AppModel。
  ///
  /// **不能**在 [dispose] 里 `ref.read`：那时 element 已经 deactivated，
  /// Riverpod 会抛「Looking up a deactivated widget's ancestor is unsafe」。而
  /// dispose 里的 flush 恰恰只在「用户在防抖窗口内切走页面」时才跑，也就是说那条
  /// 路径**必然**走到这里，用 ref 的写法在生产里 100% 触发并吞掉用户那次编辑。
  AppModel? _appModel;

  /// 每家的「测试连接 / 拉模型」结果（key = draft.id）。
  final Map<String, _ProbeState> _probes = <String, _ProbeState>{};

  /// 每家拉回来的模型名（key = draft.id）。
  final Map<String, List<String>> _models = <String, List<String>>{};

  /// 「模型」字段的 controller（key = draft.id）。
  ///
  /// 这个字段必须能被**程序**改值（从拉回来的候选里挑一个），而 `initialValue`
  /// 只在第一次 build 生效——BUG-2618 的直接表现就是：选完候选，上面的输入框
  /// 纹丝不动，界面上两处显示着不同的模型名，而落盘的是用户看不见的那一个。
  final Map<String, TextEditingController> _modelControllers =
      <String, TextEditingController>{};

  /// 功能 → 提供商映射的当前值（草稿与落盘同步推进，不存在中间态）。
  AiFeatureAssignments _assignments = const AiFeatureAssignments();

  @override
  void dispose() {
    final bool pending = _saveDebounce?.isActive ?? false;
    _saveDebounce?.cancel();
    // 用户在防抖窗口内切走页面时不能把这次编辑吞掉。
    if (pending) unawaited(_saveValidDrafts());
    for (final TextEditingController controller in _modelControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    _appModel = appModel;
    if (!appModel.isPreferencesReady) return const SizedBox.shrink();
    if (!_loaded) {
      _loaded = true;
      _drafts = <_AiProviderDraft>[
        for (final AiProviderConfig config in appModel.prefsRepo.aiProviders)
          _AiProviderDraft.fromConfig(config),
      ];
      _assignments = appModel.prefsRepo.aiFeatureAssignments;
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: Column(
        key: const ValueKey<String>('ai-provider-settings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SourceSectionHeading(
            title: t.ai_providers_section,
            hint: t.ai_providers_section_summary,
            icon: Icons.smart_toy_outlined,
          ),
          if (_drafts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                t.ai_provider_empty,
                key: const ValueKey<String>('ai-provider-empty'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (int index = 0; index < _drafts.length; index++)
            _providerCard(index),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey<String>('ai-provider-add'),
              onPressed: () => unawaited(_pickPresetAndAdd()),
              icon: const Icon(Icons.add),
              label: Text(t.ai_provider_add),
            ),
          ),
          SourceSectionHeading(
            title: t.ai_features_section,
            hint: t.ai_features_section_summary,
            icon: Icons.auto_fix_high_outlined,
          ),
          for (final AiFeature feature in AiFeature.values)
            if (_featureAvailableOnThisStore(feature)) _featureRow(feature),
        ],
      ),
    );
  }

  /// 「AI 下视频」属于下载中心 + 在线发现两类 App Store 合规受限能力：入口与
  /// 设置分类都已按 [StoreRestrictedCapability] 门控，指派行也不能漏——它的文案
  /// 写着「然后下载或订阅」，iOS 上留这一行等于把被拆掉的能力写在审核员眼前。
  /// 判据只在 store_compliance.dart 写一次，这里只是消费。
  static bool _featureAvailableOnThisStore(AiFeature feature) =>
      feature != AiFeature.videoAcquire ||
      (StoreRestrictedCapability.downloads.isAvailable &&
          StoreRestrictedCapability.externalDiscovery.isAvailable);

  // ---------------------------------------------------------------------------
  // 提供商卡片
  // ---------------------------------------------------------------------------

  Widget _providerCard(int index) {
    final _AiProviderDraft draft = _drafts[index];
    final AiProviderConfig? config = draft.toConfig();
    final _ProbeState? probe = _probes[draft.id];
    // 内置预设的协议是厂商事实，锁死；只有「自定义」才让用户自己选。
    final bool protocolLocked = draft.presetId != kAiCustomPresetId;
    final ThemeData theme = Theme.of(context);

    return FushiCard(
      key: ValueKey<String>('ai-provider-${draft.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: SwitchListTile.adaptive(
                  key: ValueKey<String>('ai-provider-$index-enabled'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(t.ai_provider_enabled),
                  // 状态标只有一个判据：[AiProviderConfig.isUsable]。
                  subtitle: Text(
                    (config?.isUsable ?? false)
                        ? t.ai_provider_ready
                        : t.ai_provider_incomplete,
                    key: ValueKey<String>('ai-provider-$index-status'),
                  ),
                  value: draft.enabled,
                  onChanged: (bool value) =>
                      _update(index, draft.copyWith(enabled: value)),
                ),
              ),
              IconButton(
                key: ValueKey<String>('ai-provider-$index-delete'),
                tooltip: t.ai_provider_delete,
                onPressed: () => _delete(index),
                icon: const Icon(Icons.remove_circle_outline),
              ),
            ],
          ),
          SettingsFormField(
            key: ValueKey<String>('ai-provider-$index-name'),
            label: t.ai_provider_name,
            initialValue: draft.name,
            onChanged: (String value) =>
                _update(index, draft.copyWith(name: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('ai-provider-$index-api-key'),
            label: t.ai_provider_api_key,
            initialValue: draft.apiKey,
            obscureText: true,
            onChanged: (String value) =>
                _update(index, draft.copyWith(apiKey: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('ai-provider-$index-base-url'),
            label: t.ai_provider_base_url,
            initialValue: draft.baseUrl,
            keyboardType: TextInputType.url,
            errorText: draft.baseUrlError,
            onChanged: (String value) =>
                _update(index, draft.copyWith(baseUrl: value)),
          ),
          SettingsFormField(
            key: ValueKey<String>('ai-provider-$index-model'),
            label: t.ai_provider_model,
            controller: _modelController(draft),
            hintText: t.ai_provider_model_hint,
            // 候选长在字段自己身上，不另起一行下拉（见 [_modelPickerButton]）。
            suffixIcon: _modelPickerButton(index, draft),
            onChanged: (String value) =>
                _update(index, draft.copyWith(model: value)),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DropdownButtonFormField<AiWireProtocol>(
              key: ValueKey<String>('ai-provider-$index-protocol'),
              isExpanded: true,
              initialValue: draft.protocol,
              decoration: InputDecoration(
                labelText: t.ai_provider_protocol,
                // 内置预设锁死协议：厂商端点的 wire 形状不是用户偏好。
                helperText: protocolLocked
                    ? '${draft.presetDisplayName} · '
                          '${t.ai_provider_protocol_locked}'
                    : null,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<AiWireProtocol>>[
                for (final AiWireProtocol protocol in AiWireProtocol.values)
                  DropdownMenuItem<AiWireProtocol>(
                    value: protocol,
                    child: Text(_protocolLabel(protocol)),
                  ),
              ],
              // onChanged 为 null = 控件禁用（Flutter 的既定语义），不必另加一层
              // IgnorePointer/AbsorbPointer。
              onChanged: protocolLocked
                  ? null
                  : (AiWireProtocol? value) {
                      if (value == null) return;
                      _update(index, draft.copyWith(protocol: value));
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DropdownButtonFormField<AiReasoningEffort>(
              key: ValueKey<String>('ai-provider-$index-reasoning'),
              isExpanded: true,
              initialValue: draft.reasoningEffort,
              decoration: InputDecoration(
                labelText: t.ai_provider_reasoning,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<AiReasoningEffort>>[
                for (final AiReasoningEffort effort in AiReasoningEffort.values)
                  DropdownMenuItem<AiReasoningEffort>(
                    value: effort,
                    child: Text(_reasoningLabel(effort)),
                  ),
              ],
              onChanged: (AiReasoningEffort? value) {
                if (value == null) return;
                _update(index, draft.copyWith(reasoningEffort: value));
              },
            ),
          ),
          SwitchListTile.adaptive(
            key: ValueKey<String>('ai-provider-$index-allow-http'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(t.ai_provider_allow_http),
            subtitle: Text(t.ai_provider_allow_http_summary),
            value: draft.allowInsecureHttp,
            onChanged: (bool value) =>
                _update(index, draft.copyWith(allowInsecureHttp: value)),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              OutlinedButton.icon(
                key: ValueKey<String>('ai-provider-$index-fetch-models'),
                // 地址还没填成合法 URL 时按钮直接不可用，而不是点了再报通用错误。
                onPressed: config == null || probe?.running == true
                    ? null
                    : () => unawaited(_fetchModels(draft)),
                icon: const Icon(Icons.download_outlined),
                label: Text(t.ai_provider_models_fetch),
              ),
              OutlinedButton.icon(
                key: ValueKey<String>('ai-provider-$index-test'),
                // 「测试连接」跑的是 listModels 而不是一次真问答：便宜、不花 token，
                // 而鉴权/网络/端点这三类真正会配错的东西它一条不漏地覆盖。
                onPressed: config == null || probe?.running == true
                    ? null
                    : () => unawaited(_testConnection(draft)),
                icon: probe?.running == true
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.network_check_outlined),
                label: Text(t.ai_provider_test),
              ),
              if (probe != null && !probe.running)
                Text(
                  probe.message,
                  key: ValueKey<String>('ai-provider-$index-probe-result'),
                  style: TextStyle(
                    color: probe.ok
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 「模型」字段的 controller（key = draft.id），随条目删除一起销毁。
  TextEditingController _modelController(_AiProviderDraft draft) =>
      _modelControllers.putIfAbsent(
        draft.id,
        () => TextEditingController(text: draft.model),
      );

  /// 贴在「模型」字段尾部的候选选择器。
  ///
  /// BUG-2618：此前候选是字段**外面**另起的一行下拉，于是同一个值有了两个输入
  /// 控件——选完下拉，上面的输入框不跟着变（它吃 `initialValue`，只认第一次
  /// build），界面当场自相矛盾，而真正落盘的偏偏是用户没在看的那一个；那行下拉
  /// 还只在拉过一次之后才凭空出现，把字段间距顶开，标签又和下方按钮同名
  /// （「获取模型列表」）。一个值只留一个输入控件，候选从字段自己身上出。
  Widget _modelPickerButton(int index, _AiProviderDraft draft) {
    final bool busy = _probes[draft.id]?.running ?? false;
    // 地址还没填成合法 URL 时拉不了候选，直接置灰，而不是点了再报通用错误。
    final bool ready = draft.toConfig() != null;
    return Builder(
      builder: (BuildContext anchor) => IconButton(
        key: ValueKey<String>('ai-provider-$index-model-picker'),
        tooltip: t.ai_provider_model_pick,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.arrow_drop_down),
        onPressed: ready && !busy
            ? () => unawaited(_pickModel(anchor, draft.id))
            : null,
      ),
    );
  }

  /// 弹出候选，把选中的模型写回「模型」字段。
  ///
  /// 还没拉过就先拉一次：用户点这个箭头的意思就是「给我看有哪些模型」，再要求他
  /// 先去点一次下面的按钮没有任何信息增量。
  Future<void> _pickModel(BuildContext anchor, String draftId) async {
    int at = _drafts.indexWhere((_AiProviderDraft d) => d.id == draftId);
    if (at < 0) return;
    if ((_models[draftId] ?? const <String>[]).isEmpty) {
      await _fetchModels(_drafts[at]);
      if (!mounted) return;
    }
    final List<String> fetched = _models[draftId] ?? const <String>[];
    // 拉失败或一条都没有：原因已经在探测结果那行文案里，不再弹一个空菜单。
    if (fetched.isEmpty || !anchor.mounted) return;
    final RenderBox? button = anchor.findRenderObject() as RenderBox?;
    final RenderBox? overlay =
        Navigator.of(anchor).overlay?.context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return;
    at = _drafts.indexWhere((_AiProviderDraft d) => d.id == draftId);
    if (at < 0) return;
    final String current = _drafts[at].model;
    final String? picked = await showMenu<String>(
      context: anchor,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          button.localToGlobal(Offset.zero, ancestor: overlay),
          button.localToGlobal(
            button.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      // 按钮只有一个图标宽，菜单不跟着缩成一条——模型名普遍很长（OpenRouter 的
      // 还带组织前缀）。
      constraints: const BoxConstraints(minWidth: 240),
      initialValue: fetched.contains(current) ? current : null,
      items: <PopupMenuEntry<String>>[
        for (final String model in fetched)
          PopupMenuItem<String>(
            value: model,
            child: Text(model, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    final int now = _drafts.indexWhere((_AiProviderDraft d) => d.id == draftId);
    if (now < 0) return;
    // 字段吃的就是这只 controller，写它即所见；草稿同步推进，两者不存在中间态。
    _modelController(_drafts[now]).text = picked;
    _update(now, _drafts[now].copyWith(model: picked));
  }

  // ---------------------------------------------------------------------------
  // 功能 → 提供商
  // ---------------------------------------------------------------------------

  Widget _featureRow(AiFeature feature) {
    // 只有「配全了」的提供商才进选项：让用户把功能指到一家没填 key 的提供商上，
    // 等于把失败推迟到功能真跑的时候，那时既没有上下文也没有配置入口。
    final List<AiProviderConfig> usable = <AiProviderConfig>[
      for (final _AiProviderDraft draft in _drafts)
        if (draft.toConfig() case final AiProviderConfig config)
          if (config.isUsable) config,
    ];
    final String? assigned = _assignments.providerIdFor(feature);
    // 指向已删除/已失效的那家时回落到「未指定」，否则 DropdownButton 会因
    // value 不在 items 里直接断言失败。
    final String? current = usable.any((AiProviderConfig c) => c.id == assigned)
        ? assigned
        : null;

    return FushiCard(
      key: ValueKey<String>('ai-feature-${feature.storageKey}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            _featureTitle(feature),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            _featureSummary(feature),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String?>(
            key: ValueKey<String>('ai-feature-${feature.storageKey}-provider'),
            isExpanded: true,
            initialValue: current,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<String?>>[
              DropdownMenuItem<String?>(child: Text(t.ai_feature_unset)),
              for (final AiProviderConfig config in usable)
                DropdownMenuItem<String?>(
                  value: config.id,
                  child: Text(
                    config.displayName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (String? value) => _setAssignment(feature, value),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 变更与落盘
  // ---------------------------------------------------------------------------

  void _update(int index, _AiProviderDraft next) {
    setState(() {
      _drafts[index] = next;
      // 配置变了，上一次自检结论作废——留着会让用户照着一条针对旧地址的
      // 「连接成功」去排查新地址的问题。
      _probes.remove(next.id);
      // 模型候选同理，而且更隐蔽：箭头的语义是「没缓存才去拉」，不清的话用户改完
      // baseUrl / apiKey / 协议再点箭头，拿到的是**旧端点**的清单且永远不会自愈。
      _models.remove(next.id);
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_kSaveDebounce, () => unawaited(_saveValidDrafts()));
  }

  void _delete(int index) {
    final String id = _drafts[index].id;
    setState(() {
      _probes.remove(id);
      _models.remove(id);
      _modelControllers.remove(id)?.dispose();
      _drafts.removeAt(index);
      // 删一家提供商必须同步清理指向它的功能映射，否则映射悬空。
      _assignments = _assignments.withoutProvider(id);
    });
    unawaited(_saveValidDrafts());
    unawaited(_persistAssignments());
  }

  void _setAssignment(AiFeature feature, String? providerId) {
    setState(() {
      _assignments = _assignments.withAssignment(feature, providerId);
    });
    unawaited(_persistAssignments());
  }

  Future<void> _persistAssignments() async {
    final AppModel? appModel = _appModel;
    if (appModel == null) return;
    await appModel.prefsRepo.setAiFeatureAssignments(_assignments);
  }

  /// 落盘**当前有效**的草稿。
  ///
  /// 无效草稿（地址还没填完、空记录）跳过而不是报错：用户正在打字，这是中间态。
  /// 它们仍留在 UI 里，等填完下一次防抖就会被保存。
  Future<void> _saveValidDrafts() async {
    // 用 build 期抓住的引用，不用 ref——本方法也从 dispose 里调（见 [_appModel]）。
    final AppModel? appModel = _appModel;
    if (appModel == null) return;
    final List<AiProviderConfig> configs = <AiProviderConfig>[
      for (final _AiProviderDraft draft in _drafts)
        if (draft.toConfig() case final AiProviderConfig config) config,
    ];
    await appModel.prefsRepo.setAiProviders(configs);
  }

  /// 「添加提供商」：先选一个内置预设（含「自定义」），再按预设建条目。
  Future<void> _pickPresetAndAdd() async {
    final AiProviderPreset? preset = await showDialog<AiProviderPreset>(
      context: context,
      builder: (BuildContext dialogContext) => FushiDialogFrame(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          key: const ValueKey<String>('ai-provider-preset-picker'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                t.ai_provider_add,
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
            ),
            for (final AiProviderPreset preset in kAiProviderPresets)
              FushiListItem(
                key: ValueKey<String>('ai-provider-preset-${preset.id}'),
                title: Text(preset.displayName),
                subtitle: preset.baseUrl.isEmpty
                    ? null
                    : Text(preset.baseUrl, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.of(dialogContext).pop(preset),
              ),
          ],
        ),
      ),
    );
    if (preset == null || !mounted) return;
    setState(() {
      _drafts.add(
        _AiProviderDraft.fromConfig(
          AiProviderConfig.fromPreset(
            preset,
            id: 'ai-${DateTime.now().microsecondsSinceEpoch}',
          ),
        ),
      );
    });
    unawaited(_saveValidDrafts());
  }

  // ---------------------------------------------------------------------------
  // 出站探测
  // ---------------------------------------------------------------------------

  /// 拉模型列表。
  ///
  /// 存在的理由：预设里的默认模型名**必然过时**（厂商迭代比本 app 发版快），把用户
  /// 钉死在写死的字符串上迟早变成「开箱即 404」。
  Future<void> _fetchModels(_AiProviderDraft draft) =>
      _probe(draft, collectModels: true);

  /// 测试连接：同样跑一次 listModels（见按钮处注释）。
  Future<void> _testConnection(_AiProviderDraft draft) =>
      _probe(draft, collectModels: false);

  Future<void> _probe(
    _AiProviderDraft draft, {
    required bool collectModels,
  }) async {
    final AiProviderConfig? config = draft.toConfig();
    if (config == null) return;
    setState(() => _probes[draft.id] = const _ProbeState.running());
    // 必须走统一出站装配点：[AiChatClient] 默认即 `createAppHttpIoClient()`。
    // 裸 `http.Client()` 既绕过应用代理与连接超时（用户在代理环境下会遇到
    // 「浏览正常、点测试连接却失败」这种自相矛盾的结果），也会被
    // `test/tools/outbound_http_discipline_guard_test.dart` 判红。
    final AiChatClient client = widget.clientFactory?.call() ?? AiChatClient();
    _ProbeState result;
    List<String>? models;
    try {
      final List<String> fetched = await client.listModels(config);
      models = collectModels ? fetched : null;
      result = _ProbeState.done(
        ok: true,
        message: collectModels
            ? t.ai_provider_models_fetched(count: fetched.length)
            : t.ai_provider_test_ok,
      );
    } on AiChatFailure catch (failure) {
      // failure.message 已经是脱敏短码（绝不含 key / 完整 URL / 响应体原文）。
      result = _ProbeState.done(
        ok: false,
        message: t.ai_provider_test_failed(
          reason: aiFailureText(failure.message),
        ),
      );
    } finally {
      client.close();
    }
    if (!mounted) return;
    setState(() {
      _probes[draft.id] = result;
      if (models != null) _models[draft.id] = models;
    });
  }

  // ---------------------------------------------------------------------------
  // 文案
  // ---------------------------------------------------------------------------

  String _featureTitle(AiFeature feature) => switch (feature) {
    AiFeature.galgameTextProcess => t.ai_feature_galgame_text_process,
    AiFeature.dictStyle => t.ai_feature_dict_style,
    AiFeature.lapisStyle => t.ai_feature_lapis_style,
    AiFeature.videoIdentify => t.ai_feature_video_identify,
    AiFeature.videoSearch => t.ai_feature_video_search,
    AiFeature.customTheme => t.ai_feature_custom_theme,
    AiFeature.videoAcquire => t.ai_feature_video_acquire,
  };

  String _featureSummary(AiFeature feature) => switch (feature) {
    AiFeature.galgameTextProcess => t.ai_feature_galgame_text_process_summary,
    AiFeature.dictStyle => t.ai_feature_dict_style_summary,
    AiFeature.lapisStyle => t.ai_feature_lapis_style_summary,
    AiFeature.videoIdentify => t.ai_feature_video_identify_summary,
    AiFeature.videoSearch => t.ai_feature_video_search_summary,
    AiFeature.customTheme => t.ai_feature_custom_theme_summary,
    AiFeature.videoAcquire => t.ai_feature_video_acquire_summary,
  };

  /// 协议名是 wire 事实（各家 API 文档里的原名），不翻译。
  String _protocolLabel(AiWireProtocol protocol) => switch (protocol) {
    AiWireProtocol.openAiCompatible => 'OpenAI Compatible',
    AiWireProtocol.anthropicMessages => 'Anthropic Messages',
    AiWireProtocol.geminiGenerateContent => 'Gemini generateContent',
  };

  /// 非 none 的档位显示的就是**发到 wire 上的那个值**（`reasoning_effort`），
  /// 翻译它反而会让用户对不上厂商文档。
  String _reasoningLabel(AiReasoningEffort effort) =>
      effort == AiReasoningEffort.none
      ? t.ai_provider_reasoning_none
      : effort.storageKey;
}

/// 把 [AiChatFailure.message] 的脱敏短码映射成界面文案。
///
/// 短码是调用层与 UI 之间的唯一契约（见 `ai_chat_client.dart`），别在别处再各自
/// 解释一遍。
String aiFailureText(String code) {
  if (code.startsWith('http_')) {
    return t.ai_error_http(code: code.substring(5));
  }
  return switch (code) {
    'unauthorized' => t.ai_error_unauthorized,
    'rate_limited' => t.ai_error_rate_limited,
    'network_error' => t.ai_error_network,
    'bad_response' => t.ai_error_bad_response,
    'empty_response' => t.ai_error_empty_response,
    'provider_not_configured' => t.ai_error_not_configured,
    _ => code,
  };
}

/// 一条提供商的编辑中状态。
///
/// baseUrl 以**原始字符串**保存：`Uri` 解析不了的中间态（用户刚打到 `htt`）也必须
/// 能停在输入框里，转成 `Uri` 只发生在落盘时。
class _AiProviderDraft {
  const _AiProviderDraft({
    required this.id,
    required this.presetId,
    required this.name,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    required this.protocol,
    required this.reasoningEffort,
    required this.enabled,
    required this.allowInsecureHttp,
  });

  factory _AiProviderDraft.fromConfig(AiProviderConfig config) =>
      _AiProviderDraft(
        id: config.id,
        presetId: config.presetId,
        name: config.name,
        apiKey: config.apiKey,
        baseUrl: config.baseUrl.toString(),
        model: config.model,
        protocol: config.protocol,
        reasoningEffort: config.reasoningEffort,
        enabled: config.enabled,
        allowInsecureHttp: config.allowInsecureHttp,
      );

  final String id;
  final String presetId;
  final String name;
  final String apiKey;
  final String baseUrl;
  final String model;
  final AiWireProtocol protocol;
  final AiReasoningEffort reasoningEffort;
  final bool enabled;
  final bool allowInsecureHttp;

  String get presetDisplayName =>
      aiProviderPresetById(presetId)?.displayName ?? presetId;

  _AiProviderDraft copyWith({
    String? name,
    String? apiKey,
    String? baseUrl,
    String? model,
    AiWireProtocol? protocol,
    AiReasoningEffort? reasoningEffort,
    bool? enabled,
    bool? allowInsecureHttp,
  }) => _AiProviderDraft(
    id: id,
    presetId: presetId,
    name: name ?? this.name,
    apiKey: apiKey ?? this.apiKey,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    protocol: protocol ?? this.protocol,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    enabled: enabled ?? this.enabled,
    allowInsecureHttp: allowInsecureHttp ?? this.allowInsecureHttp,
  );

  /// 有效即返回配置，否则 null。
  ///
  /// 校验完全交给 [AiProviderConfig] 的构造器——那里是地址合法性与明文 HTTP 放行
  /// 的唯一真相源。在 UI 再抄一份判据必然与它漂移。
  AiProviderConfig? toConfig() {
    final Uri? parsed = Uri.tryParse(baseUrl.trim());
    if (parsed == null) return null;
    try {
      return AiProviderConfig(
        id: id,
        presetId: presetId,
        name: name,
        baseUrl: parsed,
        apiKey: apiKey,
        model: model,
        protocol: protocol,
        reasoningEffort: reasoningEffort,
        enabled: enabled,
        allowInsecureHttp: allowInsecureHttp,
      );
    } on ArgumentError {
      return null;
    }
  }

  /// 输入框下方的错误提示；空地址不报错（还没开始填）。
  String? get baseUrlError {
    if (baseUrl.trim().isEmpty) return null;
    if (toConfig() != null) return null;
    // 明文 HTTP 被挡是最常见的一种「地址看着没错却存不下」（本地 Ollama /
    // LM Studio 全是 http://localhost），单独给一句话，否则用户会反复检查地址本身。
    final Uri? parsed = Uri.tryParse(baseUrl.trim());
    final bool plainHttpBlocked =
        parsed != null &&
        parsed.scheme == 'http' &&
        !allowInsecureHttp &&
        parsed.host.isNotEmpty;
    return plainHttpBlocked
        ? t.ai_provider_allow_http_summary
        : t.ai_provider_base_url_invalid;
  }
}

/// 探测状态：进行中 / 有结论。
class _ProbeState {
  const _ProbeState.running() : running = true, ok = false, message = '';

  const _ProbeState.done({required this.ok, required this.message})
    : running = false;

  final bool running;
  final bool ok;
  final String message;
}
