## BUG-4736 · fsrs 依赖从钉 git rev 切到 crates.io 7.0.0；升级 rev 后旧参数组被当成不认识的版本、自动优化永久停掉
- **报告**：2026-11-16（维护者应用内反馈 oMN0BHvPdm：「fsrs7 切换到最新版」）
- **真实性**：✅ 真问题。
  - 依赖：`native/fushi_fsrs/Cargo.toml:31` 写着「FSRS-7 还没发版」，钉 fsrs-rs 主干 git rev `0a5737406a0c`（Cargo.lock 版本号仍是 6.6.2），
    `native/fushi_ios_umbrella/Cargo.lock` 同钉；fsrs-rs 已于 2026-11-10 在 crates.io 发 7.0.0（该 rev 之后还合进 #477 / #479 / #481 等修复）。
  - 换版本会触发的连带缺陷：`packages/fushi_engine/lib/srs/srs_optimization_scheduler.dart:214` 用 `setRev == engine.fsrsRev` 判
    「本机认识这个参数组的 algorithmRev」。原生库只报一个 rev，换 fsrs-rs 版本后所有已优化过的牌组（参数组 rev = 旧 rev）都被当成
    「更新版本产出、本机不认识」，自动优化与「立即优化」都永久跳过。设计稿铁律 F 的本意只是不为**更新**版本产出的参数组跑优化。
- **[x] ① 已修复** — `Cargo.toml` 改 `fsrs = "=7.0.0"`（crates.io），刷新 fushi_fsrs 与 fushi_ios_umbrella 两份 Cargo.lock；
  `FSRS_RS_REV` 改成 7.0.0 包 `.cargo_vcs_info.json` 记的发布提交 `c114a02f…`，新增 `SUPERSEDED_FSRS_RS_REVS`（只增不删），
  `version` 响应带 `knownFsrsRevs`；`FsrsEngine.isKnownFsrsRev` 由原生库的清单回答，调度器改用它判「认识」。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_optimization_scheduler_test.dart`（旧 rev 参数组升级后照常优化并写回新 rev〔修复前红〕；
  更新版本产出的参数组仍不优化）、`packages/fushi_srs/test/ffi_fsrs_engine_test.dart`（真原生库认识自身与发版前的 rev）、
  `native/fushi_fsrs/src/lib.rs` `tests::version_lists_current_and_superseded_fsrs_revs`；对拍 `sync2::fsrs_det::tests::matches_fsrs_crate_within_ulps`
  对 7.0.0 重跑通过（`cargo test --profile quick --lib` 1006 passed）。
- **备注**：7.0.0 相对旧 rev 的推理差异只有 #479（FSRS-6 `stability_short_term_scalar` 的 Hard 下限，旧 rev 的 `next_state_scalar`
  当天分支本来就是 `>= 2`，fsrs_det 也是），只改了 fsrs-rs 的模拟器路径，不改排程数值；#477 / #481 等改的是参数优化（训练）过程，优化出的参数可能与旧 rev 略有不同。iOS 伞形库产物需 CI 重新出。
