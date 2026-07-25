## BUG-1076 · galgame helper 自动更新绑死游戏启动时刻且 6s 硬超时弱网永远静默放弃
- **报告**：2026-07-25（用户：helper 一直是旧版；直连 GitHub 时好时坏的网络下从未见它更新过，也没有任何提示）
- **真实性**：✅ 真 bug。根因链（`hibiki/lib/src/mining/galgame_helper_installer.dart`，修复前版本）：
  1. **更新时机错**：自动更新只挂在 `ensureInjector()`（用户点「启动游戏」那一刻，`_maybeAutoUpdate` 旧 :266）。因为它抢占的是启动关键路径，才被迫加"自残式"上限。
  2. **6s 硬超时**：`client.connectionTimeout = 6s`（旧 :278）+ `_fetchSha256(...).timeout(6s)`（旧 :283）——6 个候选（直连 + 5 镜像）共享 6s 总预算；直连 GitHub 时好时坏的网络下直连自己就能吃掉 6s，弱网必然轮次超时 → `remoteSha = null` → `galgameHelperNeedsUpdate` 返回 false → **每次都静默放弃，helper 永远停在旧版**。
  3. **全程无感知**：整条链 best-effort 静默（设计如此），用户无从得知更新被放弃。
  4. 次生缺陷：`_extractZip` 就地覆盖安装目录；`hibiki_voice_hook.dll` 被进程映射时覆盖写会失败在半途，留下混版本残局（实测该 DLL 在 app 运行期间可被锁定、无法覆盖但可改名）。
- **[x] ① 已修复** — 根因修复：更新时机从「点启动游戏」挪到 **app 启动后台静默更新**（`GalgameHelperInstaller.updateInstalledHelpersInBackground()`，`main.dart` 桌面启动块 Windows 分支挂载）。后台不抢任何交互路径，因此侧车探测放宽到 30s 连接超时 + 90s 总预算，逐镜像轮询有充分时间；游戏启动路径在安装完整时**不再碰网络**（删除 `_maybeAutoUpdate` 与 6s 上限）。解压改为「staging 全量解压校验 → rename 换旧入新 → 失败整体回滚」（`galgameHelperSwapInstall`），被映射 DLL 改名合法，彻底消除半覆盖混版本；残留 `*.stale*` 下轮启动清扫。后台更新与启动路径经 `_extractionGate` 串行化，互不竞态。提交：见本分支。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/galgame_helper_swap_install_test.dart`（真实临时目录：换入/子目录保留/回滚/stale 清扫）+ `hibiki/test/mining/galgame_helper_background_update_guard_test.dart`（静态守卫，最强可落地层——`ensureInjector` 首行 Windows 早退使 CI 进不了真实路径：锁死"安装完整的启动路径零网络"、"后台路径零 UI"、"main.dart 挂载后台更新"、"6s 自残超时不得回归"）。
- **备注**：更新语义与浏览器一致——本次启动下载、静默换入（未被占用时立即生效，被占用的文件下轮启动换入）。首次安装/残缺修复仍走原有带确认框/进度框的交互路径，行为不变。
