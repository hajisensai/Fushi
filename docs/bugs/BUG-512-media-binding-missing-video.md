## BUG-512 · TODO-1063 配置方案「媒体类型绑定」缺少 video 选项（视频毕业后未补齐）
- **报告**：2026-07-01（用户：）
- **真实性**：✅ 真 bug（完整性缺口）。视频从实验开关毕业为常驻媒体类型 tab 后，配置方案设置里的「媒体类型绑定」列表仍硬编码为 epub/srtbook/audiobook/lyrics 四行，用户无法把 profile 绑定到视频；且视频页从不解析绑定 profile，即使补 UI 也会是死配置。
- **[x] ① 已修复** — 见提交
- **[x] ② 已加自动化测试** — `hibiki/test/profile/media_type_binding_video_guard_test.dart`
- **备注**：

### 根因
- 绑定 UI 硬编码子集：`hibiki/lib/src/pages/implementations/profile_management_page.dart:89-116` 的
  `AdaptiveSettingsSection(title: t.profile_media_type_bindings)` 只显式渲染 4 个
  `_buildMediaTypeRow`（'epub' / 'srtbook' / 'audiobook' / 'lyrics'），没有 'video' 行。
  这不是白名单过滤、也不是枚举缺失——媒体类型键是纯字符串。
- 存储层对 video 本就兼容：绑定落 `media_type_profiles` 表，key 是任意 `String`
  （`profile_repository.dart:284-293` `getAllMediaTypeBindings` / `setMediaTypeBinding`），
  `resolveProfileId(mediaType:)`（`profile_repository.dart:306-321`）也接受任意 mediaType 字符串。
  故**无需 schema 迁移**，'video' 键天然可存可查。
- 消费侧缺口：阅读器/有声书/歌词在打开时调用
  `_resolveAndApplyProfile`（`reader_hibiki/audiobook.part.dart:118-157`，
  `lyrics.part.dart:34/52`）解析并 `switchProfile`，让绑定生效；但视频页
  `video_hibiki_page.dart` 的 `_init`（原 :1312）从不解析任何 profile 绑定。
  只补 UI 而不接消费侧 → 用户设的 video 绑定永不生效（假功能）。

### 修复（根因向）
1. **UI 补齐**：`profile_management_page.dart` 在 lyrics 行后新增 'video' 绑定行，
   与其它四类同构（`_buildMediaTypeRow(t.profile_media_video, 'video', ...)`）。
2. **i18n**：经 `hibiki/tool/i18n_sync.dart --add profile_media_video "Video" "视频"` 新增
   key（17 语言完整），`dart run slang` 重生成 `strings.g.dart` + `dart format`。
3. **消费接入（消除假功能）**：`video_hibiki_page.dart` 新增
   `_resolveAndApplyVideoProfile()`，在 `_init` 开头 `unawaited` 调用——打开视频即
   `resolveProfileId(bookUid: widget.bookUid, mediaType: 'video')` 并在解析 id ≠ 当前活跃
   profile 时 `switchProfile`。镜像阅读器侧的非致命范式（内部 try/catch，失败只
   `debugPrint`、不打断视频加载；与视频加载并行）。使看视频时的查词浮层 / 制卡按绑定
   profile 生效。本地与远端（`_isRemote`）路径统一覆盖。

### 测试
- `hibiki/test/profile/media_type_binding_video_guard_test.dart`（源码扫描守卫，2 用例）：
  ① 断言绑定 UI 五个媒体类型键 epub/srtbook/audiobook/lyrics/**video** 全部作为
     `_buildMediaTypeRow` 行存在，且 video 行使用 `t.profile_media_video` 标签（防复发：
     若 video 或任一同类被移除即红）。
  ② 断言视频页调用 `resolveProfileId(mediaType: 'video')` 且在 open 时触发
     `_resolveAndApplyVideoProfile()`（防止绑定 UI 退化为死配置）。
- 相邻回归：`hibiki/test/profile/` 全量 44 用例通过；`flutter analyze` No issues。
