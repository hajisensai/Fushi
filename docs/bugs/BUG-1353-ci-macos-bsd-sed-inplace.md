## BUG-1353 · CI macos/ios 作业固定红：TMDB key 注入用了 GNU-only 的裸 sed -i
- **报告**：2026-08-02（用户：巡检看板 TODO-2553「develop CI 全红」的伴生发现）
- **真实性**：✅ 真 bug（功能坏——CI 步骤本身跑不通，与 BUG-1352 无关，是另一条独立根因）。
  根因 `.github/workflows/build-multiplatform.yml:511`（macos job）和 `:675`（ios job）
  步骤「Provide gitignored TMDB API key stub」里的
  `sed -i "s|^const String kBuiltinTmdbApiKey = '';|...|" "$dst"`。

  BSD/macOS 的 sed 与 GNU sed 在 `-i` 上语义不同：**BSD 的 `-i` 必须带备份后缀**，
  写成 `sed -i "脚本" 文件` 时它把紧跟的脚本吃成后缀、再把文件名当成脚本执行，于是
  固定报 `sed: 1: "hibiki/lib/src/media/vi ...": extra characters at the end of h
  command` 并以 1 退出（`shell: bash -e` → 整个 job 红）。
  证据：run 30708854995（`Build and Test`，ios + macos 两个 job 同一步骤同一行报错）、
  run 30706194279（`Build Desktop and Apple Release Artifacts`，macos + ios 同样；
  publish job 的 `No files matched hibiki-*-windows-setup.exe` 是级联，不是独立根因）。

  引入于 `4e09b4f36`（2026-08-01，`feat(scraper): 多源聚合匹配 + 内置 TMDB key`）
  ——**早于** PR#663，与 BUG-1352 的 `Build Release APK` 红是两回事：`Build Release
  APK` 在 `42e69614e` / `5d578885b` 还是 success，而 `Build and Test` 当天 20 个
  run 无一 success。别把三个 workflow 的红当成同一处失败。
- **[x] ① 已修复** — 六处 TMDB 注入统一改成 GNU/BSD 通用的、后缀紧贴的
  `sed -i.bak "..." "$dst"` + `rm -f "$dst.bak"`：
  `.github/workflows/build-multiplatform.yml` 五处（android/linux/macos/ios/windows）
  与 `.github/workflows/main.yml` 一处。ubuntu 侧本来就不坏，一并统一是为了消除
  「从 ubuntu 作业复制粘贴出裸 -i 到新 macos 作业」这个复发源——同一条命令只留一种写法。
  未动 `main.yml` / `release.yml` 里那些 gradle 代理/aliyun 清理的 `sed -i`：它们全在
  ubuntu-only 的 job 里，GNU sed 下合法，没有为统一而 churn 高危 release.yml 的理由。
- **[x] ② 已加自动化测试** — `hibiki/test/build/workflow_sed_inplace_portability_guard_test.dart`：
  ① 按 `jobs:` 切块 + 读 `runs-on`，凡可能落到 macOS runner 的 job（含无法静态判定的
  `${{ matrix.* }}` 表达式，从严）禁止裸 `sed -i`（正则要求 `-i` 后紧跟空白或行尾，
  `-i.bak` 不匹配）；② 所有 workflow 里的 TMDB 注入行必须含 `sed -i.bak `，且注入点
  数量 > 0（防注入方式改版后守卫静默失效）。
  变异实测：把六处改回裸 `sed -i` → `build-multiplatform.yml: macOS 作业不得用裸
  sed -i` 与 `TMDB key 注入步骤…` 两条真红；`main.yml: macOS 作业…` 正确地**不**红
  （该 job 是 ubuntu-only），证明 runner 作用域没写成假阳。反向替换还原后复绿。
- **备注**：`Build and Test` / `Build Desktop and Apple` 这两个 workflow **还有一条
  未修的独立根因**——windows job 的「Bundle and verify pinned Mihon desktop runtime」
  跑 `tool/mihon/build_desktop_runtime.ps1:12` 的
  `git clone https://github.com/miru-project/M-Extension-Server.git`，该仓库现已
  **404**（`gh api repos/miru-project/M-Extension-Server` → Not Found），git 转去交互
  取凭据 → `could not read Username for 'https://github.com'` → exit 128。上游仓库消失
  属外部依赖失效，需产品决策（换镜像 / vendor 到 `third_party/` / 暂时把该步骤设为
  非阻塞），不在本次修复范围。另 android job 的 `appSmoke` 集成测试失败需模拟器产物
  才能定位，同样另开条目。
