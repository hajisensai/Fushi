## BUG-4659 · CI flatpak-baseapp 未命中缓存时 flatpak-builder 报 state dir 与 target dir 不在同一文件系统
- **报告**：2026-11-15（PR #3400 审查意见：flatpak-baseapp 既有红单独跟踪）
- **真实性**：✅ 真 bug，develop 上同样红（release-desktop run 43654446353；PR #3400 的 run 43667097783 job 132668797602 同一报错）。日志：`The state dir (/src/build/flatpak-state) is not on the same filesystem as the target dir (/tmp/tmp.gKxlW8UjIV)`。根因：`tool/linux/flatpak/flatpak_build.sh:64`（`cmd_baseapp`）与 `:82`（`cmd_app`）用裸 `mktemp -d` 把工作目录 / `--force-clean "$work/build"` 目标目录建在容器的 `/tmp`（overlay fs），而 `release-desktop.yml` 的 flatpak-baseapp job 传的 `FLATPAK_STATE_DIR=/src/build/flatpak-state` 在 bind mount 的 `/src` 上；flatpak-builder 要在 state dir 与 build dir 之间硬链接，跨文件系统直接拒绝。BaseApp 平时走 native artifact store 缓存命中、不进这一步，所以只在缓存键变化后暴露。后果：flatpak-baseapp 红 → `linux` job（`needs: flatpak-baseapp`）被跳过，CI 拿不到 Linux x64 release 构建证据。
- **[ ] ① 未修复** — 不在 PR #3400（Flutter 3.50 升级）范围内，单独修：工作目录应与 `STATE_DIR` 同一文件系统（例如 `mktemp -d -p "$(dirname "$STATE_DIR")"`）。
- **[ ] ② 未加自动化测试** — 修复时补源码守卫：`flatpak_build.sh` 的工作目录不得落在与 `STATE_DIR` 不同的根下。
- **备注**：
