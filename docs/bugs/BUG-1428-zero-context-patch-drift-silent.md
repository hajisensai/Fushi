## BUG-1428 · 零上下文补丁漂移无声：git apply --unidiff-zero 对上游漂移 exit 0 后盲插
- **报告**：2026-08-02（用户：TODO-2636，来自 PR#709 写守卫时的实测发现）
- **真实性**：✅ 真 bug（两个独立根因）
  - 根因 A：`tool/mihon/build_desktop_runtime.sh:45` / `tool/mihon/build_desktop_runtime.ps1:82`
    用 `git apply --unidiff-zero` 应用零上下文补丁 `third_party/m_extension_server/server-build.gradle.patch`。
    零上下文补丁里**纯插入的 hunk**（`@@ -69,0 +70 @@`）没有任何可校验内容，
    upstream_src 漂移后 `git apply --check --unidiff-zero` 仍 exit 0，真 apply 时
    按行号盲插到错误位置。构建脚本对补丁漂移完全无声。
  - 根因 B：`hibiki/test/build/mihon_vendored_server_guard_test.dart:171`（PR#709 原始版本）
    那条 `git apply --check` 守卫**从落地起就是空转的**。它 `cd` 进 `upstream_src` 跑
    `git apply --check ../server-build.gradle.patch`；`git apply` 在仓库内把补丁路径
    解释成**相对仓库根**，`gradle/...` / `server/...` 全部落在 cwd 之外，git 打印 7 行
    `Skipped patch` 然后 exit 0 —— 把 upstream_src 改坏它照样绿。

### 复现（实测）
零上下文补丁的盲区分两种形态，`-` 删除行那种其实**挡得住**（`git apply` 即使带
`--unidiff-zero` 也校验 `-` 行内容），真正无声的是**纯插入 hunk**：

```
# 拷一份 pristine upstream_src 到仓库外临时目录，模拟上游在 JGroupFilter 前面加了 3 行
$ git -C /tmp/mut apply --check --unidiff-zero old-zerocontext.patch
exit=0                                     # ← 盲区：漂移了但 --check 说没事
$ git -C /tmp/mut apply --unidiff-zero old-zerocontext.patch
$ sed -n '65,74p' .../model/DataBody.kt
data class JGroupFilter(
    val name: String?,
    val stateString: String? = null,        # ← 盲插到了错误位置
    val type: String?,
    val stateBoolean: Boolean?,
    val stateInt: Int?,
)
```
Kotlin data class 的字段顺序是**位置语义**（主构造器实参顺序、`componentN` 解构），
编译照过、行为已错。

根因 B 的复现更直接：
```
$ cd third_party/m_extension_server/upstream_src
$ git apply --check --verbose ../server-build.gradle.patch
Skipped patch 'gradle/libs.versions.toml'.
Skipped patch 'server/build.gradle.kts'.
... （7 行全部 Skipped）
exit=0
```

### 修复
把零上下文补丁换成带默认 3 行上下文的补丁，应用处一律不带 `--unidiff-zero`；
守卫改从**仓库根** + `--directory=` 调用，并加反空转断言。

- **[x] ① 已修复** — `third_party/m_extension_server/server-build.gradle.patch`
  用 `git diff`（默认 3 行上下文）重新生成；`tool/mihon/build_desktop_runtime.sh` /
  `.ps1` 去掉 `--unidiff-zero`；`third_party/m_extension_server/UPSTREAM` 记下
  「必须带上下文、重生成不许用 `-U0`」。
  **等价性证据**：新旧补丁应用到同一棵 pristine upstream_src 上（同一 `core.autocrlf`
  设置），435 个文件逐 sha256 比对 **BYTE-IDENTICAL**；补丁作用不变，只变得更严。
  （附带发现：旧补丁两条 `index` 后像哈希 `adc2815` / `b0e4c9e` 是错的，实际产出是
  `6b07a8a` / `89c2d7a` —— 旧补丁生成后被手改过。新补丁的 index 行是真的。）
- **[x] ② 已加自动化测试** — `hibiki/test/build/mihon_vendored_server_guard_test.dart`
  （18 个用例，本条新增/改造 4 条）：
  1. `server-build.gradle.patch 仍能干净地打在 vendored 树上` —— 改成仓库根 +
     `--directory=` + `--verbose`，并断言日志里**没有** `Skipped patch`、
     `Checking patch` 条数等于补丁里的文件数（反空转，修根因 B）。
  2. `server-build.gradle.patch 必须带上下文（零上下文=漂移无声）` —— 扫 hunk 头，
     禁止 `@@ -N +M @@` / `,0` 形态，并要求真的存在 ` ` 上下文行。
  3. `<脚本> 应用补丁时不带 --unidiff-zero` —— 两份构建脚本各一条（注释走
     `maskHashComments` 掩码，解释性注释里写 `--unidiff-zero` 不会假红）。
  4. 原自解析守卫扩成 `删除行与上下文行都对得上 vendored 树的实际内容` —— `-` 行
     和 ` ` 上下文行都核到 upstream_src 实际行号上（`git apply` 允许 offset 重定位，
     所以「行号仍对齐」这件事需要单独守）。
- **备注**：变异实测四轮，每轮改完跑守卫、跑完用反向文本替换还原（未提交文件禁用
  `git checkout --`），`upstream_src` 435 文件 sha256 快照比对确认零字节改动：
  - M1 改坏 upstream_src 被补丁触及的上下文行（`JGroupFilter.stateInt` → `stateIntValue`）：
    **修前** `git apply --check --unidiff-zero` exit 0（无声）；**修后**
    `git apply --check` exit 1（`patch does not apply`），守卫 2 条红。
  - M2 把 `--unidiff-zero` 加回 `build_desktop_runtime.sh` 代码：只有 sh 那条守卫红，
    ps1 那条保持绿（证明是逐脚本判定、且注释掩码没把解释吃成假红）。
  - M3 换回零上下文补丁：3 条守卫红。
  - M4 把守卫改回旧的（空转的）调用形态：反空转断言红，报「这条守卫在空转」。
  另：`git apply` 在**非仓库**目录下（构建脚本的真实场景）不做前缀过滤，路径按 cwd
  解释，所以构建脚本本身没有根因 B；只有守卫踩到了。
- **未做**：CI 侧没跑。M-Extension-Server 的真实 gradle 构建（`:server:test`
  `:server:shadowJar`，macOS/Windows job）本机没跑，需要 CI 实证；本机做到的是离线
  复现「vendored → 补丁 → overlay」整条流水线并逐文件核对产物。
