## BUG-2408 · Mihon 裸 FilterList 绕过类型化序列化导致选项对象报错
- **报告**：2026-09-10（用户：Comic Days筛选器不可用，沿原始路径修复BUG-2407后继续复测发现。）
- **真实性**：✅ 真 bug。MihonInvoker.invokeFiltersManga返回裸FilterList，但overlay DalvikHandler.kt:87只为FiltersResponse包装类型调用既有toBridgeMap；裸列表直接交给Jackson，将Filter.Select的自定义无字段选项f当Java Bean序列化，抛FAIL_ON_EMPTY_BEANS。既有codec已正确按toString输出显示标签，实际路径却未接入。
- **[x] ① 已修复** — filterResponseForBridge同时处理裸FilterList和包装FiltersResponse，复用既有显式codec，保持各自wire形状。提交见同批Git历史。
- **[x] ② 已加自动化测试** — 新增Jackson真实序列化测试覆盖无字段自定义选项、日文显示标签、嵌套Group、TriState/Sort及两种响应形状；联合完整JVM41项通过、0跳过，lint/shadowJar和Windows运行时smoke通过。
- **边界**：同时支持实际裸FilterList数组与历史FiltersResponse包装形状，复用现有显式filter codec，保留type/state/values/children及顺序；不关闭Jackson序列化错误，不为具体扩展对象加特例。
- **证据**：`.codex-test/schale/comicdays-after-results.json`含真实APK的`No serializer found for class f ... FilterList[0]->g[values]->f[0]`错误。
- **真实APK验收**：Comic Days的filtersManga由500恢复200，返回`コレクション`、`連載作品一覧`；SchaleNetwork四语言同样200，type/state/values/children均经统一codec。证据`.codex-test/schale/comicdays-final-results.json`、`schale-after-codec-results.json`。最终JAR SHA256为`90d60e9cf6e0fc33a9c2b82974a729f57143930f80422973c4e203efd3986c22`，已备份并应用本机。其他平台未验证。
- **用户UI验收**：本机Fushi重新提交原始完整日文书名，Comic Days正常结束并显示“没有找到漫画”，原Object错误消失；该查询空结果不代表站点不存在作品。
