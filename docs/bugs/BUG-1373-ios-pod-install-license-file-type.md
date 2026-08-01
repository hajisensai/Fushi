## BUG-1373 · iOS pod install 断在 license 校验：LICENSE.GPLv3 扩展名不被 CocoaPods 接受
- **报告**：2026-08-02（用户：TODO-2582，看板报「iOS 构建在 develop 上就是红的」）
- **真实性**：✅ 真 bug（develop 自身红，非某 PR 引入）。根因
  `third_party/ffmpeg_kit_flutter/ios/ffmpeg_kit_flutter.podspec:18`（修前）：
  `s.license = { :file => '../LICENSE.GPLv3' }`。
  cocoapods-core `lib/cocoapods-core/specification/linter.rb:351` 的
  `Specification::Linter#_validate_license` 按**扩展名**判定许可文件类型：
  `if file && Pathname.new(file).extname !~ /^(\.(txt|md|markdown|))?$/i` →
  `results.add_error('license', 'Invalid file type')`。
  白名单只有「无扩展名 / `.txt` / `.md` / `.markdown`」，`.GPLv3` 不在其中，于是
  `pod install` 在**校验阶段**就断，多平台 workflow 的 ios job 约 2.5 分钟即红在
  "Build iOS (debug, no codesign)"：
  ```
  [!] The `ffmpeg_kit_flutter` pod failed to validate due to 1 error:
      - ERROR | license: Invalid file type
  Error running pod install
  ```
  `third_party/ffmpeg_kit_flutter/LICENSE.GPLv3` 文件本身一直存在（35147 字节 GPLv3
  正文）——**不是路径缺失，是文件名类型不被认**。
  引入自 `31cb5e9c3` / `73f80792e`（BUG-122 Phase2 自编 ffmpeg-kit iOS podspec +
  BUG-1339 移动端 H.264）那批改动，随 `--enable-gpl --enable-x264` 把许可指向 GPLv3
  一并落地；因为只有 macOS runner 上的 `pod install` 会跑这条校验，本地 Windows/Linux
  的 analyze 与单测一直是绿的，缺口没被任何门禁挡住。
  排除「某 PR 引入」的两条独立证据：① 以 merge-base 为基准，PR#685 改动仅 3 文件，
  `third_party/ffmpeg_kit_flutter` 与基线逐字节一致；② develop 自身 run `30713467878`
  的 ios job 同为 failure。
- **[x] ① 已修复** — `git mv third_party/ffmpeg_kit_flutter/LICENSE.GPLv3
  third_party/ffmpeg_kit_flutter/LICENSE-GPLv3.txt`（`.txt` 在 CocoaPods 白名单内），
  podspec 同步改为
  `s.license = { :type => 'GPL-3.0', :file => '../LICENSE-GPLv3.txt' }`
  （顺带补上显式 `:type`，让许可结论机器可读，并消掉 linter 的 "Missing license type."
  警告）。
  🔴 **许可结论未变，仍是 GPLv3**：本仓自编 ffmpeg-kit 启用 `--enable-gpl --enable-x264`，
  产物有效许可就是 GPLv3（Hibiki 自身即 GPL-3.0，两者一致）。这次只动文件名让
  CocoaPods 认得，**没有也不得降回 LGPLv3**。
  包根另有一份上游原件 `LICENSE`（LGPLv3），供 `macos/ffmpeg_kit_flutter.podspec` 使用
  ——macOS 走 cocoapods 上游**非 GPL** 预编译包，指向 LGPLv3 是对的，两个文件不合并。
  这也解释了为什么只有 iOS 红：macOS podspec 指的 `../LICENSE` 无扩展名，本来就过校验。
  vendored 包的改动已记进 `third_party/ffmpeg_kit_flutter/patches/README.md` 新增的
  「本仓对上游 podspec 的改动（同步上游时必须重放）」一节，避免下次同步上游丢失。
- **[x] ② 已加自动化测试** — `hibiki/test/tools/ffmpeg_kit_podspec_license_guard_test.dart`
  （源码扫描守卫，3 个用例，Windows/Linux 都能跑，把只在 macOS runner 才暴露的错误前移）：
  1. 扫 `third_party/` 下全部 7 个 podspec 的 `:file =>`，**照抄** cocoapods-core 那条
     正则判扩展名；
  2. 断言被指向的许可文件真实存在（防「改名过了校验但忘了 `git mv`」）；
  3. 钉住 iOS 侧许可结论仍是 GPL-3.0（`:type` + 文件名含 GPLv3 + 正文抬头是
     `GNU GENERAL PUBLIC LICENSE`），堵死「为了过校验顺手改回 LGPLv3」这条合规倒退路。
     注：抬头只看首行——GPLv3 正文第 13 节附近本来就会提到 "GNU Lesser General Public
     License"，全文搜 LESSER 会假阳。
  变异实测（两轮，均按反向替换还原，未用 `git checkout --`）：
  - 把 `:file` 改回 `'../LICENSE.GPLv3'` → `FLUTTER TEST VERDICT: FAILED`，退出码 1，
    3/3 用例红；
  - 把 `:type` 改成 `'LGPL-3.0'` → `FLUTTER TEST VERDICT: FAILED`，退出码 1，第 3 条红。
  还原后 `FLUTTER TEST VERDICT: PASSED - 3 tests ran, all tests passed`（退出码 0）。
- **备注**：本机是 Windows，跑不了 `pod install`，**本地无法端到端验证**——真正的验证由
  PR 的 ios job 兜底（`pod lib lint` 与实际 `pod install` 的校验路径不完全相同，别拿 lint
  当证据）。修前修后的判据是 cocoapods-core 上游源码那条正则，已从
  `raw.githubusercontent.com/CocoaPods/Core/master/lib/cocoapods-core/specification/linter.rb`
  实取复核，不是凭记忆。
  ⚠️ 本条**不含**「ffmpeg_kit_flutter 停在 6.0.3、上游 arthenica/ffmpeg-kit 已归档」这个
  独立的供应链议题（TODO-2577，等用户拍板），本次刻意没动版本号。
