## BUG-2429 · OpenSubtitles 内置密钥却显示已停用

- **报告**：2026-09-10（用户截图：设置 → 在线服务 → 字幕，列表副标题「已停用」，详情页却写「应用身份已内置」）
- **真实性**：✅ 真 bug。用户生产库 `preferences.video_subtitle_opensubtitles_config` 实测为
  `{"apiKey":"","username":null,"password":null,"enabled":false,...}`——一份**空草稿**被原样落盘。

### 根因

「是否启用」的默认值在三处各自表达且互相矛盾，且「没配置过」（偏好返回 null）这个
特殊情况要由每个消费方各自解释一遍：

| 位置 | 未配置时的解释 |
|---|---|
| `fushi/lib/src/media/video/subtitle/open_subtitles_client.dart:62,96` | 构造 / 反序列化默认 `enabled = true` |
| `fushi/lib/src/pages/implementations/video_external_provider_settings_section.dart:1309`（原 `_OpenSubtitlesDraft.empty()`） | 硬写 `enabled: false`——**UI 开关一开始就是关的** |
| `fushi/lib/src/settings/settings_schema_services.dart:75-88` | 假造一个 `enabled = true` 的配置 → 列表显示「已内置」 |
| `fushi/lib/src/models/app_model.dart:4447` | `config == null` 直接不装配 → 内置密钥完全没参与字幕搜索 |

于是两条错误路径：
1. 从没进过详情页的用户，列表谎报「已内置」，实际运行时一次都没装配。
2. 进过详情页并碰过任意字段的用户（唯一写入路径是 `video_external_provider_settings_section.dart:412 → :377 → :166` 的 debounce 保存），
   那个**没人选过的 `false`** 被落盘，从此真的停用，且用户不知道自己何时关的。

### 修复

- **[x] ① 已修复** — 见提交（见下）。默认值收敛到唯一真相源 `OpenSubtitlesConfig.unconfigured()`；
  `PreferencesRepository.videoSubtitleOpenSubtitlesConfig` 改为**永不返回 null**（未配置 = 构造默认），
  null 这个特殊情况随之消失，运行时装配 / 列表 status / 详情页草稿看的是同一个对象、同一套判据
  （`enabled && effectiveApiKey.isNotEmpty`）；详情页草稿的 `empty()` 删除。
  存量脏数据由 `PreferencesRepository._repairOpenSubtitlesEnabledOnce()` 一次性归一
  （判据：一条自有凭据都没有却是关闭态 = 空草稿指纹），标记键
  `video_subtitle_opensubtitles_enabled_repaired` 保证只跑一次，用户之后主动关仍然关得住。
- **[x] ② 已加自动化测试** — `fushi/test/models/opensubtitles_enabled_default_test.dart`（4 条：默认启用 /
  脏值退回默认 / 一次性归一且只归一一次 / 有凭据的关闭态不动）
  + `fushi/test/settings/video_external_provider_settings_section_test.dart` 新增
  「BUG-2429：未配置时启用开关默认打开，且不会把关闭态写回」。

### 备注

行为变更：从没配置过 OpenSubtitles 的用户，此后会用内置应用密钥参与字幕搜索——这正是详情页
「应用已内置 API 密钥」一直在承诺、而代码一直没兑现的行为。入库的 `kBuiltinOpenSubtitlesApiKey`
是空 stub（CI 注入真值），所以开发/测试构建里该来源仍然不可用，行为与修复前一致。
