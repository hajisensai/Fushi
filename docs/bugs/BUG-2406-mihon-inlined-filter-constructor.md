## BUG-2406 · SchaleNetwork 内联筛选组构造器导致抽象类实例化失败
- **报告**：2026-09-10（用户：SchaleNetwork ALL / JA 搜索显示 BRIDGE_HTTP_500 和 Filter$Group。）
- **真实性**：✅ 真 bug。用户安装版 koharu APK 的 `Lp0;` 是具体 final `Filter$Group` 子类，原始 DEX 中无方法或字段；`Lp;.getFilterList` 的 `new-instance v3, Lp0;` 与 `invoke-direct {v3,v4,v6}, Filter$Group.<init>(String,List)` 分离，其间包含构造参数的循环。转换后 NEW 被改成抽象 Group，现有 `DexAllocationRepair.kt:233` 因子类无匹配构造器而拒绝恢复，导致 InstantiationError。
- **[x] ① 已修复** — `DexAllocationRepair` 从原始 DEX 证明具体分配类型及直接父类构造调用；验证接收寄存器不变、无外部跳转/异常入口后，补缺失的转发构造器并恢复具体 NEW。提交见本文件同批 Git 历史。
- **[x] ② 已加自动化测试** — `DexInlinedConstructorTest` 使用真实 DexFileWriter → 完整 PackageTools.dex2jar 转换 → JVM 类加载与调用，校验循环、筛选组类型/name/state、幂等；负向覆盖寄存器覆盖、别名逸出、外部 branch 和异常入口。原有 DexAllocationRepairTest 继续覆盖歧义和缺失证据时不修复。
- **真实证据**：安装版日志 2026-09-10 07:47:54 显示 `Skipping abstract allocation in p.getFilterList: p0 has no constructor matching ...`，随后 InstantiationError；独立 bridge 使用同一 APK 实测 all/en/ja/zh 四个 source 的 sourcesManga 正常而 filtersManga 全部 HTTP 500。证据留在本地 `.codex-test/schale/{dex.txt,before-results.json,before.log}`。
- **修复约束**：以原始 DEX 分配/构造接收者及控制流为证据，保留具体筛选组类型和父类构造语义；不把抽象宿主类改为具体类、不按 SchaleNetwork/混淆类名硬编码、不跳过筛选器。原始 upstream_src 不修改。
- **真实 APK 验收**：修复版独立 bridge 对用户原 APK（SHA256 `e7ff9e5d70b3fd5bf47a1fc2f846da118937c5bbe3ba5dca104a31d8faa51486`）all/en/ja/zh 四语言 filtersManga 全部返回 HTTP 200，保留排序及筛选组内容；修复前四个均为 500。证据 `.codex-test/schale/after-fixed-results.json`。
- **最终验收**：全 JVM 35 项/0 失败/0 跳过、format/lint/shadowJar、Windows runtime smoke 均通过。备份本机旧 JAR/checksums 后替换最终产物（SHA256 `b2c52d2c2db80eadf7cdb704192e04767afcd36f41e2b03279158c912240899f`），重启已核身份的 Mihon 子进程；本机 Fushi 使用原始完整日文书名重搜，SchaleNetwork ALL/JA 均正常结束并显示“没有找到漫画”，原 InstantiationError 消失，Rawkuma 仍能找到目标作品。该搜索的空结果不等同于源站没有本书。其它平台和 SchaleNetwork 整书下载未验证。
