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
  Invoke-Checked $python 'tests/kirikiri_lookup_source_guard_test.py'
  Invoke-Checked $python 'tests/lookup_presenter_wiring_guard_test.py'
  Invoke-Checked $python 'tests/renpy_lookup_source_guard_test.py'
  Invoke-Checked $python 'tests/evidence_contract_test.py'
  Invoke-Checked $python 'tests/galhook_workflow_test.py'
}
finally {
  Pop-Location
}

Write-Host 'All galgame_hook source-of-truth guards passed.'
