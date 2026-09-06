# Single entry point for the galgame_hook source-of-truth guards.
#
# Why this file exists instead of an inline multi-line `run:` block:
# GitHub Actions `shell: pwsh` steps only honour the exit code of the LAST
# command in the block. Every earlier native command that fails is silently
# swallowed and the step still reports success. The now-deleted voice-hook-helper.yml's
# "Verify engine support manifest" step listed seven commands that way, so six
# of the seven guards were decorative -- proven in practice: the generated
# include/luna_hook_profiles.inc drifted away from config/luna_hook_profiles.tsv
# at the subtree import (commit bc094b89b) and `generate_luna_profiles.py
# --check` has returned 1 ever since, while run 30217258807 still reported that
# step as green.
#
# Invoke-Checked below makes swallowing structurally impossible: every guard's
# exit code is asserted, so a red guard is always a red job.
#
# Deliberately ASCII-only and pwsh/PowerShell-5.1 safe: it is executed by
# ubuntu-latest pwsh (PR gate) and by hand.
# All guards are pure verification -- no writes, no network, no publishing.

$ErrorActionPreference = 'Stop'

$hookRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
  )
  Write-Host "==> $FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

# `python` is the launcher name on the GitHub runners for both OSes once
# actions/setup-python has run; fall back to python3 for bare local shells.
$python = 'python'
if (-not (Get-Command $python -ErrorAction SilentlyContinue)) {
  $python = 'python3'
}

Push-Location $hookRoot
try {
  # Generated artefacts must match their single source of truth.
  Invoke-Checked $python 'tools/generate_engine_support.py' '--check'
  Invoke-Checked $python 'tools/generate_luna_profiles.py' '--check'

  # Vendored LunaHook/LunaHost DLLs must match VERSION.json byte for byte.
  # Read-only: -Update is NOT passed, so nothing is copied or rewritten.
  #
  # The $LASTEXITCODE reset + assert is not redundant. `& script.ps1` returns to
  # THIS scope, so if sync_lunahook.ps1 ever reports failure via `exit 1` instead
  # of `throw`, execution would simply continue here, the Python guards below
  # would reset $LASTEXITCODE to 0, and the DLL integrity check would silently
  # stop counting -- the exact failure mode this whole file exists to prevent.
  # Today it only throws, and $ErrorActionPreference='Stop' catches that; this
  # keeps the guard correct if that ever changes.
  $global:LASTEXITCODE = 0
  & (Join-Path $PSScriptRoot 'sync_lunahook.ps1')
  if ($LASTEXITCODE -ne 0) {
    throw "sync_lunahook.ps1 failed with exit code $LASTEXITCODE"
  }

  # Manifest schema, adapter layout, KiriKiri lookup invariants, evidence contract
  # and workflow guards.
  Invoke-Checked $python 'tests/engine_support_manifest_test.py'
  Invoke-Checked $python 'tests/adapter_structure_test.py'
  Invoke-Checked $python 'tests/adapter_report_guard_test.py'
  Invoke-Checked $python 'tests/kirikiri_lookup_source_guard_test.py'
  Invoke-Checked $python 'tests/lookup_presenter_wiring_guard_test.py'
  Invoke-Checked $python 'tests/renpy_lookup_source_guard_test.py'
  Invoke-Checked $python 'tests/evidence_contract_test.py'
  Invoke-Checked $python 'tests/galhook_workflow_test.py'
  # CloseHandle detour 及其可达的 Forget* 不得阻塞：MinHook Freeze（含 LunaHook32 那份）
  # 挂起全部线程后仍会调 CloseHandle，锁在这里等于等一个被自己挂起的线程（BUG-2046）。
  Invoke-Checked $python 'tests/close_handle_detour_lockfree_guard_test.py'
  # overlay 窗口类的 GDI 资源：建一次、交一次。DestroyLookupHoverHighlight 只销毁窗口、
  # 从不 UnregisterClass ⇒ 类常驻 ⇒ 每次重建窗口再 CreateSolidBrush 都无人接管，
  # overlay 线程每 Stop→Start 一轮漏一个 brush，而本 DLL 常驻在游戏进程里（BUG-2090）。
  Invoke-Checked $python 'tests/overlay_gdi_ownership_guard_test.py'
  # dinput/dinput8 的每一个 DirectInput*Create* 工厂入口都必须钩上。漏一个是静默的：
  # 设备照常建出来、左键照样穿到游戏里推进对话，而 required 仍按「模块已加载」点亮。
  # 实测漏掉过 DirectInputCreateEx（A/W 在 dinput.dll 内部只是它的包装，游戏直接
  # GetProcAddress 就绕过），フタマタ恋愛 上 ready 的 DirectInput 两位始终不亮。
  # 必须覆盖的集合从系统 DLL 导出表推导，不靠手写名单（BUG-2154）。
  Invoke-Checked $python 'tests/direct_input_factory_coverage_guard_test.py'
  # 每个原生测试都必须在任何 include 之前 `#undef NDEBUG`，否则 CI 的
  # `--config Release` 会把裸 assert 整条编译掉，测试恒绿。这条守卫本身
  # 必须登记在此：它曾经写好却没接进来，于是 generic_input_shield_test.cpp
  # 的 47 条断言在 develop 上一直空跑（BUG-2025）。清单不再靠人记——
  # galhook_workflow_test.py 会枚举 tests/*_test.py 核对本清单无遗漏。
  Invoke-Checked $python 'tests/assert_liveness_guard_test.py'
}
finally {
  Pop-Location
}

Write-Host 'All galgame_hook source-of-truth guards passed.'
