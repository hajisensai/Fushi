# tool/mihon/verify_*.ps1 的共享片段。
#
# 存在理由：两个 verify 脚本起临时 m-extension-server 前都要「拿一个空闲回环
# 端口 + 生一个一次性 bearer token」，这段是逐字节相同的惯用法。SonarCloud CPD
# 在 PR#1157 上把它判成 100% duplicated（两文件各 4 行）。这种重复本来就该消掉，
# 而不是往 sonar.cpd.exclusions 里塞一条排除——排除只给 vendored 上游代码用。
#
# 用法：在 Set-StrictMode 之后 `. (Join-Path $PSScriptRoot "_verify_common.ps1")`。

# 向系统要一个空闲回环端口后立刻释放，把端口号交给随后起的 java 进程。
# （经典 TOCTOU 窗口；本地/CI 验证脚本可接受，与抽函数前行为逐字节一致。）
function Get-MihonFreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

# 一次性 bearer token：32 字节 CSPRNG → base64（去掉尾部 padding）。
function New-MihonAuthToken {
    $tokenBytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
    return [Convert]::ToBase64String($tokenBytes).TrimEnd("=")
}
