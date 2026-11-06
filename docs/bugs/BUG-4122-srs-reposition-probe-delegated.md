## BUG-4122 · Fushi 复习下按词频重排新卡报 AnkiRepositionUnsupportedException：探测委派给了 Anki 后端
- **报告**：2026-11-05（develop 尖端 `fushi/test/srs/srs_mining_test.dart`「新卡按词频重排」组 2 个用例红，#2890 引入）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/srs/srs_mining.dart:1390`：`SrsMiningAnkiRepository` 只覆盖了静态位 `supportsDeckReposition => true`，没覆盖 `probeDeckReposition`，于是走 `fushi/lib/src/anki/delegating_anki_repository.dart:206` 的 `inner.probeDeckReposition()`——问的是内层 Anki 后端；runner 在 `fushi/lib/src/anki/anki_deck_reposition_runner.dart:195` 据此抛 `AnkiRepositionUnsupportedException`）
- **[x] ① 已修复** — `SrsMiningAnkiRepository.probeDeckReposition()` 恒 true（重排写本机复习库，与 Anki 端能力无关），与静态位成对覆盖（分支 claude/fix-srs-reposition-probe）
- **[x] ② 已加自动化测试** — `fushi/test/anki/delegating_capability_probe_pairing_test.dart`（源码扫描守卫：`DelegatingAnkiRepository` 子类覆盖 `supports<X>` 必须同时覆盖基类的 `probe<X>`，成对清单从基类解析）、`fushi/test/srs/srs_mining_test.dart`（复习目标探测为 true；内层是缺原生接口的 AnkiConnect 时复习照常出计划，同一后端直连 runner 读卡前即抛）
- **备注**：变异验证——去掉修复后守卫 + 3 个 SRS 重排用例 + 能力位用例共 5 条红。

### 根因

#2890（BUG-4111）给 `BaseAnkiRepository` 加了「静态能力位 + 当场探测」一对：`supportsDeckReposition` /
`probeDeckReposition()`（默认 = 静态位）。`DelegatingAnkiRepository` 把两者**分别**委派给 inner。
`SrsMiningAnkiRepository` 是装饰器形态的独立后端：它把静态位改成 true（重排走复习库），却没改探测，
于是探测问的是内层 Anki——AnkiDroid / AnkiMobile 默认 false，缺原生 `scheduling.repositionNewCards`
的 AnkiConnect 也 false。

用户影响（正式版、挖词目标 = Fushi 复习）：
- 手动「按词频重排」：`AnkiDeckRepositionRunner.plan` 读卡前抛 `AnkiRepositionUnsupportedException`，提示 AnkiConnect 版本不支持；
- 设置页：`AnkiViewModel.probeDeckReposition` 得 false，入口被置灰。

### 为什么不是 runner 里给 SRS 开特例

能力属于后端本身：复习后端能不能重排只有它自己知道，runner / VM 只该问「这个仓库能不能」。
所以修在 `SrsMiningAnkiRepository` 如实声明探测；Dart 不会因为漏覆盖报错，就用守卫把「改静态位必须成对改探测」
钉在所有 `DelegatingAnkiRepository` 子类上（同一形态的 `supportsMediaMaintenance` / `probeMediaMaintenance` 一并覆盖）。
没把探测做成基类抽象成员：Base 直接子类（含几十个测试假仓库）的默认「探测 = 静态位」本身就是一致的，
矛盾只会出现在委派层子类改静态位时，守卫正好卡这一处。
