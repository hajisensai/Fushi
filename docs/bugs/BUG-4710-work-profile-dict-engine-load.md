## BUG-4710 · 书籍指定配置后查不到词：引擎装载集合只看激活配置
- **报告**：2026-11-16（用户：应用内反馈 r9SgiayKxa，录屏：新建配置「英语」只开英语词典、关日语词典，书「指定配置」选它；激活配置 Default 里 OALD 10 / LDOCE5 等英语词典是停用的；进书点 teacher 等词均「没有找到结果」）
- **真实性**：✅ 真 bug。作品级配置（反馈 kEFPY4cuKZ）是会话覆盖层，本机查词按 `WorkProfileScope.lookupView` 的 `lookupFilters` 过滤，但：
  - 引擎装载集合只按激活配置分桶：`fushi/lib/src/models/app_model.dart` `_rebuildDictPathsCache` / `_scheduleDictPathsAsync` 的 `hidden: d.isHidden(JapaneseLanguage.instance)`（修前 3773 / 4020 行），配合 BUG-3454「隐藏词典不进引擎」——作品配置开着、激活配置关着的词典根本不在引擎里，会话的过滤又把引擎里的日语词典全排除，一个词都查不到。会话装上 / 撤下时（`_reloadForWorkProfileScope`）也从不重排引擎。
  - 弹窗注入的隐藏名单 `AppModel.hiddenDictionaryNames`（修前 3546 行）只看激活配置，popup.js 按它再滤一遍：即使引擎装了，作品配置开着的词典的释义也会被弹窗藏掉。
- **[x] ① 已修复** — `DictionaryRepository.engineLoadStatesOf`：引擎装载集合 = 激活配置 ∪ 当前作品会话视图里开着的词典（混合词典汉字部分同理），两条装载路径共用（`AppModel._engineLoadStates`）；可见性仍由每次查词的 `lookupFilters` 在引擎里排除（排除在截断之前，不复现 BUG-3454）。`_reloadForWorkProfileScope` 会话变化时重排引擎并清查词结果缓存。`hiddenDictionaryNames` 有作品会话时取会话视图的隐藏名单。
- **[x] ② 已加自动化测试** — `fushi/test/profile/work_profile_engine_load_test.dart`：并集判据单测；真 `ProfileRepository` 视图 + 真 `AppModel` 下进入绑定作品，作品配置开着的词典进术语桶、`hiddenDictionaryNames` 按会话视图、离开后回到激活配置；源码守卫钉两条装载路径与会话重排。
- **备注**：浏览器扩展所选的非激活配置（`_hostProfileViewForUid`，按请求临时构造的视图）仍只能查到激活配置 ∪ 作品会话装载的词典，不在本次范围；`engineTermDictionaryNames` 的合并去重已据实处理（服务器那份不会被误丢）。真机未复测。
