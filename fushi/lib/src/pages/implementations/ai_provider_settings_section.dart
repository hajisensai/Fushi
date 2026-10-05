/// 「AI」设置区：用户自配的大模型提供商增删改 + 每个功能用哪家的映射。
///
/// 形态与 `opds_server_settings_section.dart` 同构（本仓「用户自配服务器列表」的
/// 标准件）：草稿态 + 600ms 防抖落盘 + dispose 冲刷 pending + 校验不过的草稿在
/// 磁盘上保留上一次的有效版本（见 [_AiProviderSettingsSectionState._saveValidDrafts]）。
/// 校验判据**一律委托给 [AiProviderConfig] 的构造器**——在 UI 里再抄一份
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

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_schema_widgets.dart'
    show SettingsSectionFooter;
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/settings/settings_kit.dart';

// 历史上 aiFailureText 住在这里，五处调用方按 `show aiFailureText` 从本文件引；
// 搬到 lib/src/ai/ 后保留这条再导出，不逐个改调用方。
export 'package:fushi/src/ai/ai_failure_text.dart' show aiFailureText;

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

    // 与同页 schema 段同一套分组（MD3 分段卡 / Apple inset grouped）：渲染器已经
    // 给整列加了详情页左右留白，这里不再自己缩进一层。
    return Column(
      key: const ValueKey<String>('ai-provider-settings'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 提供商：每家一行（名称 / 模型 / 状态 / chevron），点进去是这家的
        // 编辑页（[_openEditor]）；末行「添加提供商」。
        AdaptiveSettingsSection(
          key: const ValueKey<String>('ai-provider-list'),
          title: t.ai_providers_section,
          children: <Widget>[
            for (int index = 0; index < _drafts.length; index++)
              _providerRow(index),
            AdaptiveSettingsRow(
              key: const ValueKey<String>('ai-provider-add'),
              icon: Icons.add_rounded,
              showIcon: true,
              title: t.ai_provider_add,
              onTap: () => unawaited(_pickPresetAndAdd()),
            ),
          ],
        ),
        SettingsSectionFooter(
          _drafts.isEmpty
              ? '${t.ai_provider_empty}\n${t.ai_providers_section_summary}'
              : t.ai_providers_section_summary,
          key: _drafts.isEmpty
              ? const ValueKey<String>('ai-provider-empty')
              : null,
        ),
        // 功能 → 提供商：每个功能一条选择行（行尾是当前值 + 弹出菜单）。
        AdaptiveSettingsSection(
          key: const ValueKey<String>('ai-feature-list'),
          title: t.ai_features_section,
          children: <Widget>[
            _defaultProviderRow(),
            for (final AiFeature feature in AiFeature.values)
              if (_featureAvailableOnThisStore(feature)) _featureRow(feature),
          ],
        ),
        SettingsSectionFooter(t.ai_features_section_summary),
      ],
    );
  }

  /// 「AI 下载」属于下载中心 + 在线发现两类 App Store 合规受限能力：入口与
  /// 设置分类都已按 [StoreRestrictedCapability] 门控，指派行也不能漏——它的文案
  /// 写着「然后下载或订阅」，iOS 上留这一行等于把被拆掉的能力写在审核员眼前。
  /// 判据只在 store_compliance.dart 写一次，这里只是消费。
  static bool _featureAvailableOnThisStore(AiFeature feature) =>
      feature != AiFeature.acquire ||
      (StoreRestrictedCapability.downloads.isAvailable &&
          StoreRestrictedCapability.externalDiscovery.isAvailable);

  // ---------------------------------------------------------------------------
  // 提供商列表行 + 编辑页
  // ---------------------------------------------------------------------------

  /// 列表里的一家：图标 / 名称 / 模型（副标题）/ 状态 / chevron，点进编辑页。
  Widget _providerRow(int index) {
    final _AiProviderDraft draft = _drafts[index];
    // 状态标只有一个判据：[AiProviderConfig.isUsable]。
    final bool ready = draft.toConfig()?.isUsable ?? false;
    final String model = draft.model.trim();
    final bool glass = isGlassDesign(context);
    return AdaptiveSettingsRow(
      key: ValueKey<String>('ai-provider-${draft.id}'),
      icon: _presetIcon(draft),
      showIcon: true,
      title: draft.displayName,
      subtitle: model.isEmpty ? draft.presetDisplayName : model,
      subtitleMaxLines: 1,
      onTap: () => unawaited(_openEditor(draft.id)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              ready ? t.ai_provider_ready : t.ai_provider_incomplete,
              key: ValueKey<String>('ai-provider-$index-status'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 就绪是次要灰字（与系统设置行尾的当前值同色）；没配全才上警告色。
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: ready
                    ? fushiNeutralSecondaryForeground(context)
                    : fushiStatusColor(context, FushiStatusTone.warning),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (glass)
            const FushiAppleChevron()
          else
            FushiIcon(
              Icons.chevron_right,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
  }

  /// 本地服务（Ollama / LM Studio）是电脑，其余是云端 API。
  static IconData _presetIcon(_AiProviderDraft draft) =>
      (aiProviderPresetById(draft.presetId)?.isLocal ?? false)
      ? Icons.computer_outlined
      : Icons.cloud_outlined;

  /// 编辑页跟随本 State 重建：草稿 / 探测结果 / 模型候选都只活在这里（防抖落盘与
  /// dispose 冲刷照旧由本 State 负责），编辑页只是另一处渲染。每次 [setState]
  /// 都会推进它（见下方覆写）。
  ///
  /// 不 dispose：编辑页的监听者可能比本 State 晚一帧摘除，一个整数 notifier
  /// 留给 GC 即可。
  final ValueNotifier<int> _editorRevision = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _editorRevision.value++;
  }

  /// 推入一家的编辑页（系统设置「账户 › 某账户」的形态）。
  Future<void> _openEditor(String draftId) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext pageContext) => ValueListenableBuilder<int>(
          valueListenable: _editorRevision,
          builder: (BuildContext pageContext, int _, Widget? __) =>
              _buildEditorPage(pageContext, draftId),
        ),
      ),
    );
  }

  Widget _buildEditorPage(BuildContext pageContext, String draftId) {
    final int index = _drafts.indexWhere(
      (_AiProviderDraft d) => d.id == draftId,
    );
    // 已删除（删除按钮先 pop 再删，这里只兜退场动画那几帧）。
    if (index < 0) return const SizedBox.shrink();
    final _AiProviderDraft draft = _drafts[index];
    final FushiDesignTokens tokens = FushiDesignTokens.of(pageContext);
    final double inset = isGlassDesign(pageContext)
        ? GlassSettingsRenderer.detailHorizontalInset(pageContext)
        : tokens.spacing.page;
    // 设置子页统一壳（settings kit）：浮动页头 + 分组跳转条（编辑表单的
    // 连接 / 请求方式 / 自检等分组 ≥ 2 时自动出现）。
    return SettingsKitScaffold(
      title: draft.displayName,
      leadingIcon: FushiIcons.ai,
      leadingTone: SettingsIconTone.purple,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => ListView(
        controller: controller,
        key: ValueKey<String>('ai-provider-editor-${draft.id}'),
        padding: EdgeInsets.fromLTRB(
          inset,
          tokens.spacing.gap,
          inset,
          tokens.spacing.page + bottomSafeInsetOf(pageContext),
        ),
        children: <Widget>[_providerEditor(pageContext, index)],
      ),
    );
  }

  /// 一家提供商的编辑表单：启用 / 连接（名称、密钥、地址、模型）/ 请求方式
  /// （协议、推理、明文 HTTP）/ 自检，最后是删除。都是共享设置分组里的标准行。
  Widget _providerEditor(BuildContext pageContext, int index) {
    final _AiProviderDraft draft = _drafts[index];
    final AiProviderConfig? config = draft.toConfig();
    final _ProbeState? probe = _probes[draft.id];
    final bool busy = probe?.running ?? false;
    // 内置预设的协议是厂商事实，锁死；只有「自定义」才让用户自己选。
    final bool protocolLocked = draft.presetId != kAiCustomPresetId;
    final double rowInset = FushiDesignTokens.of(
      pageContext,
    ).spacing.rowHorizontal;
    Widget field(Widget child) => Padding(
      padding: EdgeInsets.fromLTRB(rowInset, 12, rowInset, 10),
      child: child,
    );

    return Column(
      key: ValueKey<String>('ai-provider-${draft.id}-editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsSection(
          children: <Widget>[
            AdaptiveSettingsSwitchRow(
              key: ValueKey<String>('ai-provider-$index-enabled'),
              title: t.ai_provider_enabled,
              subtitle: (config?.isUsable ?? false)
                  ? t.ai_provider_ready
                  : t.ai_provider_incomplete,
              value: draft.enabled,
              onChanged: (bool value) =>
                  _update(index, draft.copyWith(enabled: value)),
            ),
          ],
        ),
        AdaptiveSettingsSection(
          title: draft.presetDisplayName,
          children: <Widget>[
            field(
              _textField(
                key: ValueKey<String>('ai-provider-$index-name'),
                label: t.ai_provider_name,
                initialValue: draft.name,
                onChanged: (String value) =>
                    _update(index, draft.copyWith(name: value)),
              ),
            ),
            field(
              _textField(
                key: ValueKey<String>('ai-provider-$index-api-key'),
                label: t.ai_provider_api_key,
                initialValue: draft.apiKey,
                obscureText: true,
                onChanged: (String value) =>
                    _update(index, draft.copyWith(apiKey: value)),
              ),
            ),
            field(
              _textField(
                key: ValueKey<String>('ai-provider-$index-base-url'),
                label: t.ai_provider_base_url,
                initialValue: draft.baseUrl,
                keyboardType: TextInputType.url,
                errorText: draft.baseUrlError,
                onChanged: (String value) =>
                    _update(index, draft.copyWith(baseUrl: value)),
              ),
            ),
            field(
              _textField(
                key: ValueKey<String>('ai-provider-$index-model'),
                label: t.ai_provider_model,
                controller: _modelController(draft),
                hintText: t.ai_provider_model_hint,
                // 候选长在字段自己身上，不另起一行下拉（见 [_modelPickerButton]）。
                suffixIcon: _modelPickerButton(index, draft),
                onChanged: (String value) =>
                    _update(index, draft.copyWith(model: value)),
              ),
            ),
          ],
        ),
        AdaptiveSettingsSection(
          children: <Widget>[
            KeyedSubtree(
              key: ValueKey<String>('ai-provider-$index-protocol'),
              child: AdaptiveSettingsRow(
                title: t.ai_provider_protocol,
                // 内置预设锁死协议：厂商端点的 wire 形状不是用户偏好，只读显示。
                subtitle: protocolLocked ? t.ai_provider_protocol_locked : null,
                trailing: protocolLocked
                    ? Text(
                        _protocolLabel(draft.protocol),
                        style: Theme.of(pageContext).textTheme.bodyMedium
                            ?.copyWith(
                              color: fushiNeutralSecondaryForeground(
                                pageContext,
                              ),
                            ),
                      )
                    : _AiChoiceButton(
                        semanticLabel: t.ai_provider_protocol,
                        labels: <String>[
                          for (final AiWireProtocol protocol
                              in AiWireProtocol.values)
                            _protocolLabel(protocol),
                        ],
                        selectedIndex: draft.protocol.index,
                        onChanged: (int value) => _update(
                          index,
                          draft.copyWith(
                            protocol: AiWireProtocol.values[value],
                          ),
                        ),
                      ),
              ),
            ),
            KeyedSubtree(
              key: ValueKey<String>('ai-provider-$index-reasoning'),
              child: AdaptiveSettingsRow(
                title: t.ai_provider_reasoning,
                trailing: _AiChoiceButton(
                  semanticLabel: t.ai_provider_reasoning,
                  labels: <String>[
                    for (final AiReasoningEffort effort
                        in AiReasoningEffort.values)
                      _reasoningLabel(effort),
                  ],
                  selectedIndex: draft.reasoningEffort.index,
                  onChanged: (int value) => _update(
                    index,
                    draft.copyWith(
                      reasoningEffort: AiReasoningEffort.values[value],
                    ),
                  ),
                ),
              ),
            ),
            AdaptiveSettingsSwitchRow(
              key: ValueKey<String>('ai-provider-$index-allow-http'),
              title: t.ai_provider_allow_http,
              subtitle: t.ai_provider_allow_http_summary,
              value: draft.allowInsecureHttp,
              onChanged: (bool value) =>
                  _update(index, draft.copyWith(allowInsecureHttp: value)),
            ),
          ],
        ),
        AdaptiveSettingsSection(
          children: <Widget>[
            AdaptiveSettingsRow(
              key: ValueKey<String>('ai-provider-$index-fetch-models'),
              icon: Icons.download_outlined,
              showIcon: true,
              title: t.ai_provider_models_fetch,
              // 地址还没填成合法 URL 时这一行不可点，而不是点了再报通用错误。
              onTap: config == null || busy
                  ? null
                  : () => unawaited(_fetchModels(draft)),
            ),
            AdaptiveSettingsRow(
              key: ValueKey<String>('ai-provider-$index-test'),
              icon: Icons.network_check_outlined,
              showIcon: true,
              title: t.ai_provider_test,
              // 「测试连接」对所配模型发一次最小问答（见 [_testConnection]）：
              // listModels 验不出模型名拼错 / 未开通 / 端点不支持 chat。
              onTap: config == null || busy
                  ? null
                  : () => unawaited(_testConnection(draft)),
              trailing: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: FushiCircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
          ],
        ),
        if (probe != null && !probe.running)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            // 成功走状态绿（MD3 按主色 harmonize / Apple systemGreen），失败走
            // 错误色——语义只上在图标上，底是中性提示块。
            child: FushiInlineNotice(
              key: ValueKey<String>('ai-provider-$index-probe-result'),
              severity: probe.ok
                  ? FushiNoticeSeverity.success
                  : FushiNoticeSeverity.error,
              message: probe.message,
            ),
          ),
        Center(
          child: FushiTextButton.icon(
            key: ValueKey<String>('ai-provider-$index-delete'),
            destructive: true,
            onPressed: () {
              // 先退出编辑页再删：编辑页按 id 渲染，删在前会闪一帧空页。
              Navigator.of(pageContext).pop();
              _delete(index);
            },
            icon: const FushiIcon(Icons.delete_outline),
            label: Text(t.ai_provider_delete),
          ),
        ),
      ],
    );
  }

  /// 编辑页的输入框：MD3 填充式 / Apple 实色字段（[FushiTextFormFieldControl]），
  /// 错误与说明在框下。
  Widget _textField({
    required Key key,
    required String label,
    required ValueChanged<String> onChanged,
    String? initialValue,
    TextEditingController? controller,
    String? hintText,
    String? errorText,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffixIcon,
  }) {
    return FushiTextFormFieldControl(
      key: key,
      initialValue: initialValue,
      controller: controller,
      obscureText: obscureText,
      // 密钥：关掉输入建议与自动纠错（与 SettingsFormField 同口径）。
      enableSuggestions: !obscureText,
      autocorrect: !obscureText,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        errorText: errorText,
        errorMaxLines: 3,
        suffixIcon: suffixIcon,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
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
      builder: (BuildContext anchor) => FushiIconButtonControl(
        key: ValueKey<String>('ai-provider-$index-model-picker'),
        tooltip: t.ai_provider_model_pick,
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: FushiCircularProgressIndicator(strokeWidth: 2),
              )
            : const FushiIcon(Icons.arrow_drop_down),
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
    final String? picked = await showFushiMenu<String>(
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

  /// 只有「配全了」的提供商才进选项：让用户把功能指到一家没填 key 的提供商上，
  /// 等于把失败推迟到功能真跑的时候，那时既没有上下文也没有配置入口。
  List<AiProviderConfig> _usableProviders() => <AiProviderConfig>[
    for (final _AiProviderDraft draft in _drafts)
      if (draft.toConfig() case final AiProviderConfig config)
        if (config.isUsable) config,
  ];

  /// 默认提供商：没单独指派的功能都用它，配一家只要选这一次。
  Widget _defaultProviderRow() {
    final List<AiProviderConfig> usable = _usableProviders();
    final String? assigned = _assignments.defaultProviderId;
    // 指向已删除/已失效的那家时回落到「未指定」，否则当前值会落在选项之外。
    final String? current = usable.any((AiProviderConfig c) => c.id == assigned)
        ? assigned
        : null;
    return _assignmentRow(
      key: const ValueKey<String>('ai-feature-default'),
      menuKey: const ValueKey<String>('ai-feature-default-provider'),
      icon: Icons.auto_awesome_outlined,
      title: t.ai_feature_default_provider,
      summary: t.ai_feature_default_provider_summary,
      current: current,
      options: <(String?, String)>[
        (null, t.ai_feature_unset),
        for (final AiProviderConfig config in usable)
          (config.id, config.displayName),
      ],
      onChanged: _setDefault,
    );
  }

  Widget _featureRow(AiFeature feature) {
    final List<AiProviderConfig> usable = _usableProviders();
    final String? assigned = _assignments.providerIdFor(feature);
    // 显式指派的那家没配全 / 已停用 / 根本不在清单里：运行时 resolve 一律回 null、
    // 不退回默认，所以这里也不能把它显示成「跟随默认」——那等于告诉用户能用，实际
    // 点下去提示没配 AI。「不在清单里」不止删除一条来路（删除时 withoutProvider
    // 已清映射）：备份恢复、旧版本写入、提供商条目解码失败被逐条丢弃都会留下它。
    final bool assignedUnavailable =
        assigned != null &&
        assigned != kAiFeatureDisabled &&
        !usable.any((AiProviderConfig c) => c.id == assigned);
    // 显式指派的每一种取值（可用的那家 / 关掉 / 不可用）在选项里都有对应项，
    // 所以当前值就是指派本身；只有「没显式指派」才落到「跟随默认」那一项。
    final String? current = assigned;
    final String? defaultName = usable
        .where((AiProviderConfig c) => c.id == _assignments.defaultProviderId)
        .map((AiProviderConfig c) => c.displayName)
        .firstOrNull;

    return _assignmentRow(
      key: ValueKey<String>('ai-feature-${feature.storageKey}'),
      menuKey: ValueKey<String>('ai-feature-${feature.storageKey}-provider'),
      icon: _featureIcon(feature),
      title: _featureTitle(feature),
      summary: _featureSummary(feature),
      current: current,
      options: <(String?, String)>[
        (
          null,
          defaultName == null
              ? t.ai_feature_unset
              : t.ai_feature_follow_default(name: defaultName),
        ),
        for (final AiProviderConfig config in usable)
          (config.id, config.displayName),
        if (assignedUnavailable) (assigned, t.ai_feature_assigned_unavailable),
        (kAiFeatureDisabled, t.ai_feature_disabled),
      ],
      onChanged: (String? value) => _setAssignment(feature, value),
    );
  }

  /// 「功能 → 提供商」的一条设置选择行：标题 + 说明，行尾是当前值 + 弹出菜单
  /// （MD3 菜单 / Apple 弹出按钮，当前项打勾）。
  Widget _assignmentRow({
    required Key key,
    required Key menuKey,
    required IconData icon,
    required String title,
    required String summary,
    required String? current,
    required List<(String?, String)> options,
    required ValueChanged<String?> onChanged,
  }) {
    final int selected = options.indexWhere(
      ((String?, String) option) => option.$1 == current,
    );
    return KeyedSubtree(
      key: key,
      child: AdaptiveSettingsRow(
        icon: icon,
        showIcon: true,
        title: title,
        subtitle: summary,
        trailing: _AiChoiceButton(
          key: menuKey,
          semanticLabel: title,
          labels: <String>[
            for (final (String?, String) option in options) option.$2,
          ],
          selectedIndex: selected < 0 ? null : selected,
          onChanged: (int index) => onChanged(options[index].$1),
        ),
      ),
    );
  }

  /// 功能行的单色图标（只做辨识，不上彩色底块）。
  static IconData _featureIcon(AiFeature feature) => switch (feature) {
    AiFeature.galgameTextProcess => Icons.sports_esports_outlined,
    AiFeature.dictStyle => Icons.style_outlined,
    AiFeature.lapisStyle => Icons.dashboard_customize_outlined,
    AiFeature.videoIdentify => Icons.movie_outlined,
    AiFeature.videoSearch => Icons.subtitles_outlined,
    AiFeature.customTheme => Icons.palette_outlined,
    AiFeature.acquire => Icons.download_outlined,
    AiFeature.mangaOcr => Icons.document_scanner_outlined,
    AiFeature.lookupContext => Icons.manage_search_outlined,
  };

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

  void _setDefault(String? providerId) {
    setState(() {
      _assignments = _assignments.withDefault(providerId);
    });
    unawaited(_persistAssignments());
  }

  Future<void> _persistAssignments() async {
    final AppModel? appModel = _appModel;
    if (appModel == null) return;
    await appModel.prefsRepo.setAiFeatureAssignments(_assignments);
  }

  /// 按草稿列表落盘；**只有显式删除（[_delete]）能让一家提供商从磁盘消失**。
  ///
  /// 无效草稿（地址改到一半、关掉明文 HTTP 放行）是用户正在编辑的中间态：它留在
  /// UI 里，磁盘上则保留这一 id **上一次落盘的有效版本**。此前直接跳过它——整份
  /// 覆盖的写法于是把这家从磁盘删掉，指向它的功能映射当场悬空，用户此时离开页面
  /// 就永久丢了这家的 key 与模型。从没有效过的新草稿磁盘上本来就没有，照旧不写。
  ///
  /// 保留的旧版本一律**停用**落盘：用户正在改它，旧配置不该在后台继续被调用——
  /// 尤其草稿是在收紧（关掉明文 HTTP、停用这家）时，照原样保留旧版等于把用户
  /// 刚撤回的放行悄悄留着。草稿重新有效时按草稿自己的启用状态写回。
  Future<void> _saveValidDrafts() async {
    // 用 build 期抓住的引用，不用 ref——本方法也从 dispose 里调（见 [_appModel]）。
    final AppModel? appModel = _appModel;
    if (appModel == null) return;
    final Map<String, AiProviderConfig> persisted = <String, AiProviderConfig>{
      for (final AiProviderConfig config in appModel.prefsRepo.aiProviders)
        config.id: config,
    };
    final List<AiProviderConfig> configs = <AiProviderConfig>[
      for (final _AiProviderDraft draft in _drafts)
        if ((draft.toConfig() ?? persisted[draft.id]?.copyWith(enabled: false))
            case final AiProviderConfig config)
          config,
    ];
    await appModel.prefsRepo.setAiProviders(configs);
  }

  /// 「添加提供商」：先选一个内置预设（含「自定义」），再按预设建条目。
  Future<void> _pickPresetAndAdd() async {
    final AiProviderPreset? preset = await showAppDialog<AiProviderPreset>(
      context: context,
      // 共享弹窗骨架（标题行 + 可滚动正文），预设是一列标准列表行：图标区分
      // 本地 / 云端，副标题是默认地址。
      builder: (BuildContext dialogContext) => FushiDialogFrame(
        maxWidth: 480,
        scrollable: false,
        child: FushiModalSheetFrame(
          title: t.ai_provider_add,
          leadingIcon: Icons.add_rounded,
          scrollable: true,
          bodyPadding: const EdgeInsets.only(bottom: 12),
          body: Column(
            key: const ValueKey<String>('ai-provider-preset-picker'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final AiProviderPreset preset in kAiProviderPresets)
                FushiListItem(
                  key: ValueKey<String>('ai-provider-preset-${preset.id}'),
                  leading: FushiIcon(
                    preset.isLocal
                        ? Icons.computer_outlined
                        : Icons.cloud_outlined,
                  ),
                  title: Text(preset.displayName),
                  subtitle: preset.baseUrl.isEmpty
                      ? null
                      : Text(preset.baseUrl, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.of(dialogContext).pop(preset),
                ),
            ],
          ),
        ),
      ),
    );
    if (preset == null || !mounted) return;
    final String id = 'ai-${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _drafts.add(_AiProviderDraft.fromPreset(preset, id: id));
    });
    unawaited(_saveValidDrafts());
    // 新加的一家直接进编辑页：接下来要做的就是填密钥 / 模型。
    unawaited(_openEditor(id));
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

  /// 测试连接：对所配模型发一次最小 chat 请求（[AiChatClient.ping]），验证的是
  /// 功能真正要走的 chat 端点 + 鉴权 + 模型名。
  ///
  /// 还没填模型时无从 chat，退回 listModels——它至少能验地址与鉴权，而「模型」
  /// 字段的提示本来就是「可留空，再拉取列表」；此时卡片状态标仍是「未配置完整」，
  /// 不会让人误以为这家已经能用。
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
      if (collectModels) {
        final List<String> fetched = await client.listModels(config);
        models = fetched;
        result = _ProbeState.done(
          ok: true,
          message: t.ai_provider_models_fetched(count: fetched.length),
        );
      } else {
        if (config.model.trim().isEmpty) {
          await client.listModels(config);
        } else {
          await client.ping(config);
        }
        result = _ProbeState.done(ok: true, message: t.ai_provider_test_ok);
      }
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
    AiFeature.acquire => t.ai_feature_acquire,
    AiFeature.mangaOcr => t.ai_feature_manga_ocr,
    AiFeature.lookupContext => t.ai_feature_lookup_context,
  };

  String _featureSummary(AiFeature feature) => switch (feature) {
    AiFeature.galgameTextProcess => t.ai_feature_galgame_text_process_summary,
    AiFeature.dictStyle => t.ai_feature_dict_style_summary,
    AiFeature.lapisStyle => t.ai_feature_lapis_style_summary,
    AiFeature.videoIdentify => t.ai_feature_video_identify_assist_summary,
    AiFeature.videoSearch => t.ai_feature_video_search_subtitle_summary,
    AiFeature.customTheme => t.ai_feature_custom_theme_summary,
    AiFeature.acquire => t.ai_feature_acquire_summary,
    AiFeature.mangaOcr => t.ai_feature_manga_ocr_summary,
    AiFeature.lookupContext => t.ai_feature_lookup_context_summary,
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

  /// 选了一家预设后的新草稿。
  ///
  /// 不经 [AiProviderConfig.fromPreset]：那是**已校验**的配置构造，「自定义」预设
  /// 地址为空，构造器当场抛 ArgumentError——以前这一项点了什么都不会发生（异常从
  /// setState 里冒出去，草稿没加上）。草稿本来就允许是无效中间态，填好地址后
  /// 由 [toConfig] 校验落盘。字段默认值与 [AiProviderConfig.fromPreset] 一致。
  factory _AiProviderDraft.fromPreset(
    AiProviderPreset preset, {
    required String id,
  }) => _AiProviderDraft(
    id: id,
    presetId: preset.id,
    name: preset.displayName,
    apiKey: '',
    baseUrl: preset.baseUrl,
    model: preset.suggestedModel,
    protocol: preset.protocol,
    reasoningEffort: AiReasoningEffort.none,
    enabled: true,
    // 本地服务默认地址是 loopback HTTP，不勾这个开关就连构造都过不去。
    allowInsecureHttp: preset.isLocal,
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

  /// 列表行 / 编辑页标题：名称清空时回落到预设名，不显示一行空白。
  String get displayName => name.trim().isEmpty ? presetDisplayName : name;

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

/// 设置行尾的单选弹出按钮：当前值 + 下拉箭头，点开菜单（当前项打勾）。
///
/// - Apple：共享的 [GlassSettingsPopUpButton]（macOS 弹出按钮 / iOS pull-down）；
/// - MD3：无底文字按钮 + `arrow_drop_down`，点开 MD3 菜单（[showFushiMenu]）。
///
/// 当前值是独立的一段文字（不和说明拼在一起），整枚按钮是一个焦点停靠点，
/// Enter / 手柄 A 打开菜单。
class _AiChoiceButton extends StatefulWidget {
  const _AiChoiceButton({
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    required this.semanticLabel,
    super.key,
  });

  final List<String> labels;
  final int? selectedIndex;
  final ValueChanged<int> onChanged;
  final String semanticLabel;

  @override
  State<_AiChoiceButton> createState() => _AiChoiceButtonState();
}

class _AiChoiceButtonState extends State<_AiChoiceButton> {
  final GlobalKey _anchorKey = GlobalKey();
  bool _open = false;

  Future<void> _openMenu() async {
    if (_open || widget.labels.isEmpty) return;
    final BuildContext? anchor = _anchorKey.currentContext;
    if (anchor == null) return;
    final RenderBox box = anchor.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final Offset topLeft = box.localToGlobal(
      Offset(0, box.size.height),
      ancestor: overlay,
    );
    _open = true;
    final int? picked = await showFushiMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        topLeft & Size(box.size.width, 0),
        Offset.zero & overlay.size,
      ),
      initialValue: widget.selectedIndex,
      semanticLabel: widget.semanticLabel,
      // 按钮只有当前值那么宽，菜单不跟着缩——提供商 / 模型名普遍偏长。
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 360),
      items: <PopupMenuEntry<int>>[
        for (int i = 0; i < widget.labels.length; i++)
          CheckedPopupMenuItem<int>(
            value: i,
            checked: i == widget.selectedIndex,
            child: Text(
              widget.labels[i],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
    _open = false;
    if (!mounted || picked == null) return;
    if (picked != widget.selectedIndex) widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return GlassSettingsPopUpButton(
        semanticLabel: widget.semanticLabel,
        labels: widget.labels,
        selectedIndex: widget.selectedIndex,
        onChanged: widget.onChanged,
        maxLabelWidth: 200,
      );
    }
    final int? selected = widget.selectedIndex;
    final String value =
        selected != null && selected >= 0 && selected < widget.labels.length
        ? widget.labels[selected]
        : '';
    final ThemeData theme = Theme.of(context);
    return KeyedSubtree(
      key: _anchorKey,
      child: FushiTextButton(
        onPressed: () => unawaited(_openMenu()),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 2),
            FushiIcon(
              Icons.arrow_drop_down_rounded,
              size: 22,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}
