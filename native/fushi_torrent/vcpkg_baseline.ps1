# vcpkg.json 的 builtin-baseline 前置检查（build_windows_dll.ps1 / build_android_so.ps1 共用）。
#
# 为什么需要：vcpkg 读 baseline 走的是 `git show <baseline>:versions/baseline.json`，
# 对着 vcpkg 仓库的**本地** .git 读，取不到就硬失败，不会自己 fetch
# （vcpkg-tool registries.cpp 的 git_checkout_baseline；GitRegistry 才有 fetch 兜底）。
# 而各版本条目又来自**工作区**的 versions/ 目录，跟着 HEAD 走。两者合起来的充分条件
# 就是「baseline 是本地 HEAD 的祖先」——versions/ 是只增不删的版本数据库，祖先关系一
# 成立，baseline 引用到的每个条目就都在。
#
# 不做这个检查也能跑，只是 vcpkg 会吐
#   fatal: path 'versions/baseline.json' exists on disk, but not in '<sha>'
# 这种没人看得懂的报错（实测本机 vcpkg 停在 2026-07-17 时就是这样）。

function Assert-VcpkgBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$VcpkgRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $manifest = Get-Content -Path $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $baseline = $manifest.'builtin-baseline'
    if ([string]::IsNullOrWhiteSpace($baseline)) {
        throw "$ManifestPath 缺少 builtin-baseline"
    }

    # 对象不在本地就先取一次。CI 上 runner 镜像的 vcpkg 比 baseline 新，这步是空转；
    # 只有本机 vcpkg 落后（或镜像哪天改成浅克隆）才真的走网络。
    if ((git -C $VcpkgRoot cat-file -t $baseline 2>$null) -ne 'commit') {
        Write-Host "==> fetch vcpkg baseline $baseline"
        git -C $VcpkgRoot fetch --no-tags --quiet origin $baseline
        if ($LASTEXITCODE -ne 0) {
            throw "取不到 vcpkg baseline $baseline（$VcpkgRoot 无法 fetch）"
        }
    }

    git -C $VcpkgRoot merge-base --is-ancestor $baseline HEAD
    if ($LASTEXITCODE -ne 0) {
        $head = (git -C $VcpkgRoot rev-parse --short HEAD)
        throw @"
vcpkg 太旧：$VcpkgRoot 的 HEAD ($head) 不是 baseline $baseline 的后代。
baseline 引用的版本条目来自工作区 versions/ 目录，落后的 checkout 里没有它们，
vcpkg 会报 "path 'versions/baseline.json' exists on disk, but not in ..."。
修复：git -C "$VcpkgRoot" pull
"@
    }
}
