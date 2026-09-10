## BUG-2407 · Comic Days 筛选选项类型被转成 Object 导致 ArrayStoreException
- **报告**：2026-09-10（用户：Comic Days 搜索报 BRIDGE_HTTP_500: java.lang.Object。）
- **真实性**：✅ 真 bug。安装版日志为 `ArrayStoreException: java.lang.Object → AbstractCollection.toArray → g.<init> → Generated.getFilterList`。原 APK 的 `Lf;` 是 Object 的 final 子类，仅有 toString、无构造器；getFilterList 原始指令为 `new-instance v3,Lf; → invoke-direct Object.<init>() → listOf(v3)`，随后 g 的构造器将集合写入 f[]。转换后具体 f 被丢成 Object，数组写入失败。现有 DexAllocationRepair 仅检查抽象类分配，漏掉具体父类泛化。
- **[x] ① 已修复** — 将转换后的具体父类分配纳入原始 DEX 恢复，但额外要求每个被替换接收者的构造证据匹配；不将“计数缺额”单独作为修改合法 concrete NEW 的授权。提交见同批 Git 历史。
- **[x] ② 已加自动化测试** — DexConcreteAllocationTest 真实 DEX 转换先复现 ArrayStoreException，再校验修复后的 typed toArray、toString、幂等，以及无证据、合法 Object、多候选歧义不改写。
- **证据**：本机 Comic Days APK 在独立 bridge 中 sourcesManga 返回 200、filtersManga 返回 500，错误栈与 UI 一致；原始 DEX 与响应保存于 `.codex-test/schale/comicdays-{types.txt,before-results.json,before.log}`。
- **边界**：具体父类分配不能仅靠类型缺额判定，须另有原始 DEX 构造接收者证明；合法 Object、歧义候选、未知数据流均不改写。保留类型特有的 toString/筛选选项行为，不跳过筛选器。
- **验收**：首轮全 JVM39项通过；真实 APK复测已越过ArrayStoreException，暴露后续过滤器JSON编码问题，单独跟踪BUG-2408；最终联合验收见BUG-2408。
