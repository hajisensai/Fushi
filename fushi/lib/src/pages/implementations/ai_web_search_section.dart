/// 「设置 › AI › 联网搜索」：通用联网搜索后端（SearXNG / Brave）的设置项。
///
/// 与「联网资料」（固定维基站）并列：这里配的是真正的搜索引擎，AI 功能（字幕
/// 生成找主题曲 / 歌词等）由 app 自己去搜、去抓，与 AI 提供商有没有联网工具无关。
/// 配置是一整份 [WebSearchConfig] JSON（偏好键 `ai_web_search`，含 Brave key，
/// 设备本地 + 凭据），三个控件各改其中一个字段，读改写逻辑只在本文件。
///
/// 选项是声明式 item（后端分段 + 两个文本框），不手画控件：分段单选走
/// `SettingsSegmentedItem`（渲染器内部用 `adaptiveSegmentedButton`，MD3 / Apple
/// 两套动效随共享渲染器），API key 用 `secret: true` 的密码样式输入。
library;

import 'package:fushi_engine/ai/web_search.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 后端分段里「关闭」的取值。
const String kAiWebSearchOff = '';

/// 当前后端对应的分段取值（没配 = [kAiWebSearchOff]）。
String aiWebSearchKindValue(PreferencesRepository prefs) =>
    prefs.aiWebSearch?.kind.name ?? kAiWebSearchOff;

/// 切换后端：关闭 = 清空配置；切到另一后端时保留已填的地址 / key。
Future<void> setAiWebSearchKind(PreferencesRepository prefs, String value) {
  final WebSearchKind? kind = WebSearchKind.fromName(value);
  if (kind == null) return prefs.setAiWebSearch(null);
  final WebSearchConfig? old = prefs.aiWebSearch;
  return prefs.setAiWebSearch(
    WebSearchConfig(kind: kind, endpoint: old?.endpoint, apiKey: old?.apiKey),
  );
}

/// 改 SearXNG 地址（空白 = 清空）；没选后端时不动。
Future<void> setAiWebSearchEndpoint(PreferencesRepository prefs, String value) {
  final WebSearchConfig? old = prefs.aiWebSearch;
  if (old == null) return Future<void>.value();
  final String trimmed = value.trim();
  return prefs.setAiWebSearch(
    WebSearchConfig(
      kind: old.kind,
      endpoint: trimmed.isEmpty ? null : trimmed,
      apiKey: old.apiKey,
    ),
  );
}

/// 改 Brave API key（空白 = 清空）；没选后端时不动。
Future<void> setAiWebSearchApiKey(PreferencesRepository prefs, String value) {
  final WebSearchConfig? old = prefs.aiWebSearch;
  if (old == null) return Future<void>.value();
  final String trimmed = value.trim();
  return prefs.setAiWebSearch(
    WebSearchConfig(
      kind: old.kind,
      endpoint: old.endpoint,
      apiKey: trimmed.isEmpty ? null : trimmed,
    ),
  );
}

/// 「联网搜索」分组里的全部 item。必须零参、只用 i18n 字面量（schema 按 locale 缓存）。
List<SettingsItem> buildAiWebSearchItems() => <SettingsItem>[
  SettingsSegmentedItem<String>(
    id: 'ai.web_search.kind',
    title: t.ai_web_search_backend,
    icon: FushiIcons.globe,
    options: <SettingsSegmentOption<String>>[
      SettingsSegmentOption<String>(
        value: kAiWebSearchOff,
        label: t.ai_web_search_backend_off,
      ),
      const SettingsSegmentOption<String>(value: 'searxng', label: 'SearXNG'),
      const SettingsSegmentOption<String>(value: 'brave', label: 'Brave'),
    ],
    defaultValue: kAiWebSearchOff,
    selected: (SettingsContext c) => aiWebSearchKindValue(c.appModel.prefsRepo),
    onChanged: (SettingsContext c, String value) =>
        setAiWebSearchKind(c.appModel.prefsRepo, value),
  ),
  SettingsTextItem(
    id: 'ai.web_search.searxng_endpoint',
    title: t.ai_web_search_searxng_endpoint,
    subtitle: t.ai_web_search_searxng_hint,
    icon: FushiIcons.link,
    placeholder: 'https://searx.example.org',
    visible: (SettingsContext c) =>
        c.appModel.prefsRepo.aiWebSearch?.kind == WebSearchKind.searxng,
    value: (SettingsContext c) =>
        c.appModel.prefsRepo.aiWebSearch?.endpoint ?? '',
    onChanged: (SettingsContext c, String value) =>
        setAiWebSearchEndpoint(c.appModel.prefsRepo, value),
  ),
  SettingsTextItem(
    id: 'ai.web_search.brave_api_key',
    title: t.ai_web_search_brave_key,
    subtitle: t.ai_web_search_brave_key_hint,
    icon: FushiIcons.lock,
    secret: true,
    visible: (SettingsContext c) =>
        c.appModel.prefsRepo.aiWebSearch?.kind == WebSearchKind.brave,
    value: (SettingsContext c) =>
        c.appModel.prefsRepo.aiWebSearch?.apiKey ?? '',
    onChanged: (SettingsContext c, String value) =>
        setAiWebSearchApiKey(c.appModel.prefsRepo, value),
  ),
];
