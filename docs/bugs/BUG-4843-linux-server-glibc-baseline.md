## BUG-4843 · Linux 服务端 CI 包原生库要 GLIBC_2.43，超出 README 声明的 glibc ≥ 2.35
- **报告**：2026-11-18（用户：PVE 上给无头 fushi_server 建 BT 专用 VM，Debian 13 云镜像上 `serve` 起不来，只得改用 Ubuntu 26.04）
- **真实性**：✅ 真 bug。`build-multiplatform.yml` 定时构建 run 43748443816 的 `fushi_server-linux-x64` 产物实测（`objdump -T`，在 Ubuntu 26.04 VM 上跑本次新增的检查脚本）：
  `lib/libfushi_compute.so` 要 GLIBC_2.43（`acosf` / `asinf` / `atan2f` 等 libm 新版本符号），`lib/libfushi_torrent_ffi.so` 与 `lib/libfushidicts_ffi.so` 要 GLIBC_2.38（`__isoc23_strtol` 等）；
  其余 ELF ≤ 2.34。`packages/fushi_server/README.md:41` 却写 glibc ≥ 2.35（Debian 12 / Ubuntu 22.04）。Debian 13（glibc 2.41）上 `serve` 抛
  `FushiComputeUnavailableError`（`libm.so.6: version GLIBC_2.43 not found`）。
  根因：`.github/workflows/build-multiplatform.yml` 的 `linux-server` job 与给它预存原生件的 `.github/workflows/native-cache-warm.yml` `linux` job 跑在
  `ubuntu-latest`，GitHub 已把它换到 Ubuntu 26.04（glibc 2.43）；bundle 里除 glibc 外全是静态链 / 随包的，构建机 glibc 即产物下限。
  正式发布包 `release-server.yml` 已钉 ubuntu-22.04，但只对 `libfushidicts_ffi.so` 一个文件核 glibc，其余 ELF 无人看守。
- **[x] ① 已修复** — 两个 job 钉 `ubuntu-22.04`（gcc-14 走 ubuntu-toolchain-r/test PPA，与 release-server 同法；持久库名字吃 ImageOS，两边一起换）；新增
  `.github/scripts/check_glibc_baseline.sh`（唯一基线数字 `GLIBC_BASELINE=2.35`，并核 README 写的是同一个数），在 build-multiplatform 上传前、release-server 冒烟前对整个 bundle 的每个 ELF 判红；release-server 原先只核 fushidicts 的内联检查删掉。
- **[x] ② 已加自动化测试** — `fushi/test/build/linux_server_glibc_baseline_guard_test.dart`（README 基线 == 脚本基线；三个 job 的 runner glibc ≤ 基线、不许 `ubuntu-latest`；检查在 bundle 装齐后、上传 / 冒烟前）；`multiplatform_pr_gating_guard_test.dart` 补脚本路径的 PR 路由。脚本本身在装着坏产物的 Ubuntu 26.04 VM 上实测三条判红路径（超基线 3 个 ELF / README 不一致 / 空目录）均 exit 1。
- **备注**：ubuntu-22.04 托管镜像退役时这里会显式失败（守卫只认已知 glibc 的钉版镜像），届时改用老发行版容器或 zig cc 指定 glibc 版本，不要退回 `ubuntu-latest`。
