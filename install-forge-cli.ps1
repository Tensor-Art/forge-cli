# 通过已校验 HTTPS 分包安装 Windows CLI，不需要管理员权限、npm 或 GitHub 登录。
[CmdletBinding()]
param(
    [string] $ManifestUrl,
    [string] $InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'tensor-forge'),
    [string] $BinDir,
    [string] $Runtime = 'auto',
    [switch] $SkipAuthCheck,
    [string] $SkillsDir,
    [string] $Environment = 'tensor'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:InstallExitCode = 7
$script:InstallMessage = $null
$script:TaskDirectory = $null
$script:LockStream = $null
$script:LockFile = $null
$script:Stages = @()
$script:PendingPointer = $null
$utf8 = [Text.UTF8Encoding]::new($false)

# 仅显示已审核的安装阶段消息，避免把下载重定向或底层凭据信息写入终端。
function Stop-Install([int] $Code, [string] $Message) {
    $script:InstallExitCode = $Code
    $script:InstallMessage = $Message
    throw [InvalidOperationException]::new($Message)
}

# 清单字段必须具备明确类型，缺失字段不能被 PowerShell 隐式转换后继续安装。
function Get-TextField($Object, [string] $Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) {
        Stop-Install 2 'A required distribution string field is missing or invalid.'
    }
    return $property.Value
}

# 用户提供的分发 URL 不允许查询串或身份；对象存储重定向仅放宽查询串。
function Get-DistributionUri([string] $Value, [bool] $AllowQuery = $false) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri) -or $uri.Scheme -ne 'https' -or
        -not $uri.Host -or $uri.UserInfo -or $uri.Fragment -or (-not $AllowQuery -and $uri.Query) -or $Value -match '\s') {
        Stop-Install 2 'Distribution URLs must use HTTPS and omit credentials, query strings, fragments, and whitespace.'
    }
    return $uri
}

# 每一跳均限制 HTTPS，逐块计数限制体积；失败不反射带签名的远端地址。
function Save-DistributionFile([string] $Url, [string] $Destination, [long] $Maximum) {
    $uri = Get-DistributionUri $Url
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(300)
    $deadline = [Threading.CancellationTokenSource]::new(300000)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Forge-CLI-installer')
    try {
        for ($redirect = 0; $redirect -le 8; $redirect++) {
            $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
            try {
                $status = [int] $response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    if ($redirect -eq 8 -or $null -eq $response.Headers.Location) { Stop-Install 6 'The distribution redirect limit was exceeded.' }
                    $uri = Get-DistributionUri ([Uri]::new($uri, $response.Headers.Location).AbsoluteUri) $true
                    continue
                }
                if (-not $response.IsSuccessStatusCode -or $response.Content.Headers.ContentLength -gt $Maximum) { Stop-Install 6 'A distribution download failed or exceeded its size limit.' }
                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buffer = [byte[]]::new(65536)
                    [long] $total = 0
                    while (($count = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
                        $total += $count
                        if ($total -gt $Maximum) { Stop-Install 6 'A distribution download exceeded its size limit.' }
                        $outputStream.Write($buffer, 0, $count)
                    }
                } finally { $inputStream.Dispose(); $outputStream.Dispose() }
                return
            } finally { $response.Dispose() }
        }
    } catch {
        if ($script:InstallExitCode -eq 2 -or $script:InstallExitCode -eq 6) { throw }
        Stop-Install 6 'A distribution download failed; the current installation was not changed.'
    } finally { $deadline.Dispose(); $client.Dispose(); $handler.Dispose() }
}

# 缓存和归档使用同一 SHA256 口径；任何不匹配都在选择新版本前失败。
function Get-Sha256([string] $Filename) {
    return (Get-FileHash -LiteralPath $Filename -Algorithm SHA256).Hash.ToLowerInvariant()
}

# 写出的配置使用无 BOM UTF-8，供 Node 与 Windows PowerShell 共享读取。
function Write-Utf8([string] $Filename, [string] $Content) {
    [IO.File]::WriteAllText($Filename, $Content, $script:utf8)
}

# 解压前完整检查根目录、Windows 文件名、重复项、链接及膨胀大小，拒绝越界写入。
function Expand-VerifiedZip([string] $Archive, [string] $Hash, [string] $Root, [string] $Destination, [long] $Maximum) {
    if ((Get-Sha256 $Archive) -ne $Hash) { Stop-Install 7 'The archive SHA256 does not match; the current installation was not changed.' }
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [long] $total = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if (-not $name -or $name.Contains('\') -or $name.StartsWith('/') -or $name -match '[\x00-\x1f]' -or
                -not ($name -eq "$Root/" -or $name.StartsWith("$Root/", [StringComparison]::Ordinal))) { Stop-Install 7 'The ZIP archive has an invalid root or unsafe path.' }
            $parts = $name.TrimEnd('/').Split('/')
            foreach ($part in $parts) {
                if (-not $part -or $part -in @('.', '..') -or $part -match '[:<>"|?*]' -or $part -match '[. ]$' -or
                    $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { Stop-Install 7 'The ZIP archive contains an unsafe Windows filename.' }
            }
            if (-not $seen.Add($name.TrimEnd('/'))) { Stop-Install 7 'The ZIP archive contains duplicate or case-colliding paths.' }
            $attributes = [uint32] ([long] $entry.ExternalAttributes -band 0xffffffffL)
            $type = ($attributes -shr 16) -band 0xf000
            if ($type -notin @(0, 0x8000, 0x4000) -or ($attributes -band 0x400) -ne 0) { Stop-Install 7 'The ZIP archive must contain regular files and directories only.' }
            $total += $entry.Length
            if ($total -gt $Maximum) { Stop-Install 7 'The ZIP archive exceeds its uncompressed size limit.' }
        }
        foreach ($entry in $zip.Entries) {
            $target = Join-Path $Destination $entry.FullName.Replace('/', [IO.Path]::DirectorySeparatorChar)
            if ($entry.FullName.EndsWith('/')) { [void] [IO.Directory]::CreateDirectory($target); continue }
            [void] [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $inputStream = $entry.Open()
            $outputStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream) }
            finally { $inputStream.Dispose(); $outputStream.Dispose() }
        }
    } finally { $zip.Dispose() }
}

# 原生进程参数直接编码为 Windows argv，不把路径和用户输入交给 cmd 求值。
function ConvertTo-NativeArgument([string] $Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $result = [Text.StringBuilder]::new('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') { [void] $result.Append(('\' * ($slashes * 2 + 1))); [void] $result.Append('"') }
        else { [void] $result.Append(('\' * $slashes)); [void] $result.Append($character) }
        $slashes = 0
    }
    [void] $result.Append(('\' * ($slashes * 2)))
    [void] $result.Append('"')
    return $result.ToString()
}

# 安装探针不访问凭据；固定超时避免 PATH 中不兼容程序无限挂住安装器。
function Test-NodeRuntime([string] $NodePath, [string] $Flavor, [string] $Candidate, [string] $CompatibilityHash) {
    if (-not [IO.File]::Exists($NodePath) -or -not [IO.Path]::IsPathRooted($NodePath)) { return $null }
    $arguments = @()
    if ($Flavor -eq 'pkg') { $arguments += 'PKG_DUMMY_ENTRYPOINT' }
    $arguments += @((Join-Path $Candidate 'lib/runtime-probe.cjs'), '--policy', (Join-Path $Candidate 'lib/runtime-policy.json'), '--keytar-root', (Join-Path $Candidate 'lib/node_modules/@github/keytar'))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $NodePath
    $start.Arguments = (($arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # Node 探针使用 UTF-8 JSON，解码必须独立于 Windows 用户的控制台代码页。
    $start.StandardOutputEncoding = $script:utf8
    $start.StandardErrorEncoding = $script:utf8
    if ($Flavor -eq 'pkg') { $start.EnvironmentVariables['PKG_EXECPATH'] = 'PKG_INVOKE_NODEJS' }
    else { $start.EnvironmentVariables.Remove('PKG_EXECPATH') }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { return $null }
        $output = $process.StandardOutput.ReadToEndAsync()
        $diagnostic = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); return $null }
        $text = $output.GetAwaiter().GetResult()
        [void] $diagnostic.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { return $null }
        $result = $text | ConvertFrom-Json
        if ($result.schemaVersion -ne 'forge.node-probe/v1' -or $result.ok -ne $true -or $result.nativeLoaded -ne $true -or
            $result.platform -ne 'win32' -or $result.arch -ne 'x64' -or $result.compatibilityHash -ne $CompatibilityHash -or
            -not [IO.Path]::IsPathRooted($result.nodePath) -or -not [IO.File]::Exists($result.nodePath) -or
            $result.nodeVersion -notmatch '^\d+\.\d+\.\d+$') { return $null }
        return $result
    } catch { return $null }
    finally { $process.Dispose() }
}

# 新文件与安装根相同卷，最终通过 File.Replace 原子替换当前版本指针。
function Set-CurrentPointer([string] $Temporary, [string] $Current) {
    # PowerShell 会把普通 $null 绑定成空字符串，必须显式传递 .NET 的 null 备份路径。
    if ([IO.File]::Exists($Current)) { [IO.File]::Replace($Temporary, $Current, [NullString]::Value) }
    else { [IO.File]::Move($Temporary, $Current) }
}

# 候选运行在独立 PowerShell 进程，准确捕获其原生 stdout/stderr，不依赖父 Shell 的管道包装。
function Invoke-CandidateCli([string] $Entry, [string[]] $Arguments, [string] $Label) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $commandArguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Entry) + $Arguments
    $start.Arguments = (($commandArguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $script:utf8
    $start.StandardErrorEncoding = $script:utf8
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { Stop-Install 7 'The candidate CLI could not start.' }
        $output = $process.StandardOutput.ReadToEndAsync()
        $diagnostic = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $text = $output.GetAwaiter().GetResult()
        Write-Utf8 (Join-Path $script:TaskDirectory ($Label + '.json')) $text
        Write-Utf8 (Join-Path $script:TaskDirectory ($Label + '.error')) ($diagnostic.GetAwaiter().GetResult())
        return [pscustomobject] @{ exitCode = $process.ExitCode; stdout = $text }
    } finally { $process.Dispose() }
}

try {
    if ($env:OS -ne 'Windows_NT') { Stop-Install 12 'This installer supports Windows x64 only.' }
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -ne 'AMD64') { Stop-Install 12 'This Windows architecture has no verified artifact.' }
    if ($Runtime -notin @('auto', 'system', 'managed')) { Stop-Install 2 'Runtime must be auto, system, or managed.' }
    if ($Environment -notin @('tensor', 'tusi', 'tensor-test')) { Stop-Install 2 'Environment must be tensor, tusi, or tensor-test.' }
    [void] (Get-DistributionUri $ManifestUrl)
    if (-not [IO.Path]::IsPathRooted($InstallRoot)) { Stop-Install 2 'InstallRoot must be an absolute user directory.' }
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    if (-not $BinDir) { $BinDir = Join-Path $InstallRoot 'bin' }
    if (-not [IO.Path]::IsPathRooted($BinDir) -or ($SkillsDir -and -not [IO.Path]::IsPathRooted($SkillsDir))) { Stop-Install 2 'BinDir and SkillsDir must be absolute directories.' }
    $BinDir = [IO.Path]::GetFullPath($BinDir)
    Add-Type -AssemblyName System.Net.Http
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $script:TaskDirectory = Join-Path ([IO.Path]::GetTempPath()) ('tensor-forge-install-' + [Guid]::NewGuid().ToString('N'))
    [void] [IO.Directory]::CreateDirectory($script:TaskDirectory)
    $manifestFile = Join-Path $script:TaskDirectory 'channel.json'
    Save-DistributionFile $ManifestUrl $manifestFile 1048576
    $manifest = [IO.File]::ReadAllText($manifestFile) | ConvertFrom-Json
    if ((Get-TextField $manifest 'schemaVersion') -ne 'forge.cli-distribution/v2') { Stop-Install 12 'Windows requires a forge.cli-distribution/v2 split distribution.' }
    $version = Get-TextField $manifest 'version'
    if ($version.Length -gt 128 -or $version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { Stop-Install 2 'The distribution version is invalid.' }
    if ($manifest.artifacts -isnot [Array] -or $manifest.artifacts.Count -gt 32) { Stop-Install 2 'Distribution artifacts must be a bounded array.' }
    $matches = @($manifest.artifacts | Where-Object { $_.platform -eq 'win32' -and $_.arch -eq 'x64' })
    if ($matches.Count -ne 1) { Stop-Install 12 'The manifest must contain exactly one Windows x64 artifact.' }
    $artifact = $matches[0]
    if ((Get-TextField $artifact 'format') -ne 'zip' -or (Get-TextField $artifact.runtime 'format') -ne 'zip') { Stop-Install 12 'Windows distributions require ZIP artifacts.' }
    $artifactUrl = Get-TextField $artifact 'url'
    $artifactHash = (Get-TextField $artifact 'sha256').ToLowerInvariant()
    $runtimeUrl = Get-TextField $artifact.runtime 'url'
    $runtimeHash = (Get-TextField $artifact.runtime 'sha256').ToLowerInvariant()
    $runtimeBinaryHash = (Get-TextField $artifact.runtime 'binarySha256').ToLowerInvariant()
    $runtimeVersion = Get-TextField $artifact.runtime 'nodeVersion'
    $runtimeFlavor = Get-TextField $artifact.runtime 'flavor'
    [void] (Get-DistributionUri $artifactUrl)
    [void] (Get-DistributionUri $runtimeUrl)
    if ($artifactHash -notmatch '^[a-f0-9]{64}$' -or $runtimeHash -notmatch '^[a-f0-9]{64}$' -or $runtimeBinaryHash -notmatch '^[a-f0-9]{64}$' -or
        $runtimeVersion -notmatch '^\d+\.\d+\.\d+$' -or $runtimeFlavor -notin @('node', 'pkg')) { Stop-Install 2 'A distribution SHA256 or Node runtime field is invalid.' }

    [void] [IO.Directory]::CreateDirectory($InstallRoot)
    [void] [IO.Directory]::CreateDirectory($BinDir)
    $currentFile = Join-Path $InstallRoot 'current.json'
    $quotedRoot = $InstallRoot.Replace("'", "''")
    $dispatcher = @'
# forge.cli-dispatcher/v1：只读取本安装根的原子指针，不使用符号链接或管理员权限。
$ErrorActionPreference = 'Stop'
try {
    $installRoot = '__INSTALL_ROOT__'
    $pointer = [IO.File]::ReadAllText((Join-Path $installRoot 'current.json')) | ConvertFrom-Json
    $candidate = [IO.Path]::GetFullPath($pointer.candidate)
    $prefix = [IO.Path]::GetFullPath((Join-Path $installRoot 'versions')) + [IO.Path]::DirectorySeparatorChar
    if ($pointer.schemaVersion -ne 'forge.current-install/v1' -or -not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid current pointer' }
    $entry = Join-Path $candidate 'bin/tensor-forge.ps1'
    if (-not [IO.File]::Exists($entry)) { throw 'Missing CLI launcher' }
} catch {
    [Console]::Error.WriteLine('Forge CLI installation is incomplete; rerun the installer.')
    exit 12
}
& $entry @args
exit $LASTEXITCODE
'@
    $dispatcher = $dispatcher.Replace('__INSTALL_ROOT__', $quotedRoot) + "`r`n"
    # 公开入口仅保留 .cmd，避免 PowerShell 优先匹配同名 .ps1 而触发执行策略或对象管道差异。
    $cmdDispatcher = "@echo off`r`nsetlocal DisableDelayedExpansion`r`n`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0tensor-forge-dispatch.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    $ps1Path = Join-Path $BinDir 'tensor-forge-dispatch.ps1'
    $cmdPath = Join-Path $BinDir 'tensor-forge.cmd'
    foreach ($pair in @(@($ps1Path, $dispatcher), @($cmdPath, $cmdDispatcher))) {
        if ([IO.File]::Exists($pair[0]) -and [IO.File]::ReadAllText($pair[0]) -ne $pair[1]) { Stop-Install 5 'The binary path belongs to another installation; choose a different BinDir.' }
        if ([IO.Directory]::Exists($pair[0])) { Stop-Install 5 'The binary path is occupied by a directory.' }
    }
    if ([IO.File]::Exists($currentFile)) {
        $current = [IO.File]::ReadAllText($currentFile) | ConvertFrom-Json
        if ($current.schemaVersion -ne 'forge.current-install/v1' -or -not [IO.Path]::GetFullPath($current.candidate).StartsWith((Join-Path $InstallRoot 'versions') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Stop-Install 5 'The current pointer is not a managed installation.' }
    }
    $script:LockFile = Join-Path $InstallRoot '.install.lock'
    try { $script:LockStream = [IO.File]::Open($script:LockFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch { $script:LockFile = $null; Stop-Install 5 'Another installer is active, or a previous installer lock needs review.' }
    foreach ($name in @('packages', 'runtimes', 'versions')) { [void] [IO.Directory]::CreateDirectory((Join-Path $InstallRoot $name)) }
    $packageDirectory = Join-Path $InstallRoot ('packages/' + $artifactHash)
    if ([IO.Directory]::Exists($packageDirectory)) {
        if (-not [IO.File]::Exists((Join-Path $packageDirectory '.archive-sha256')) -or [IO.File]::ReadAllText((Join-Path $packageDirectory '.archive-sha256')).Trim() -ne $artifactHash) { Stop-Install 5 'The existing CLI package cache is not a verified installation.' }
    } else {
        $archive = Join-Path $script:TaskDirectory 'cli.zip'
        Save-DistributionFile $artifactUrl $archive 134217728
        $stage = Join-Path $InstallRoot ('packages/.stage-' + [Guid]::NewGuid().ToString('N'))
        $script:Stages += $stage
        [void] [IO.Directory]::CreateDirectory($stage)
        Expand-VerifiedZip $archive $artifactHash 'tensor-forge' $stage 536870912
        Write-Utf8 (Join-Path $stage '.archive-sha256') ($artifactHash + "`n")
        [IO.Directory]::Move($stage, $packageDirectory)
    }
    foreach ($name in @('bin/tensor-forge.cmd', 'bin/tensor-forge.ps1', 'lib/main.js', 'lib/runtime-probe.cjs', 'lib/runtime-policy.json')) {
        if (-not [IO.File]::Exists((Join-Path $packageDirectory ('tensor-forge/' + $name)))) { Stop-Install 7 'The CLI archive is missing a launcher, entrypoint, or runtime policy.' }
    }
    $stage = Join-Path $InstallRoot ('versions/.stage-' + [Guid]::NewGuid().ToString('N'))
    $script:Stages += $stage
    [void] [IO.Directory]::CreateDirectory($stage)
    Copy-Item -LiteralPath (Join-Path $packageDirectory 'tensor-forge') -Destination $stage -Recurse
    $candidate = Join-Path $stage 'tensor-forge'
    $policy = [IO.File]::ReadAllText((Join-Path $candidate 'lib/runtime-policy.json')) | ConvertFrom-Json
    $compatibilityHash = Get-TextField $policy 'compatibilityHash'
    if ($policy.schemaVersion -ne 'forge.runtime-policy/v1' -or $policy.platform -ne 'win32' -or $policy.arch -ne 'x64' -or $compatibilityHash -notmatch '^[a-f0-9]{64}$') { Stop-Install 7 'The CLI runtime policy is invalid.' }
    $selected = $null
    $source = 'system'
    $flavor = 'node'
    $preferManaged = $false
    if ($Runtime -eq 'auto' -and [IO.File]::Exists($currentFile)) {
        try {
            $previous = [IO.File]::ReadAllText((Join-Path $current.candidate 'runtime-selection.json')) | ConvertFrom-Json
            if ($previous.schemaVersion -eq 'forge.runtime-selection/v1' -and $previous.platform -eq 'win32' -and $previous.arch -eq 'x64') {
                if ($previous.source -eq 'system' -and $previous.flavor -eq 'node') { $selected = Test-NodeRuntime $previous.nodePath 'node' $candidate $compatibilityHash }
                elseif ($previous.source -eq 'managed') { $preferManaged = $true }
            }
        } catch { $selected = $null }
    }
    if ($null -eq $selected -and $Runtime -ne 'managed' -and -not $preferManaged) {
        $command = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { $selected = Test-NodeRuntime $command.Source 'node' $candidate $compatibilityHash }
        if ($null -eq $selected -and $Runtime -eq 'system') { Stop-Install 12 'No compatible PATH Node passed the capability and native-module checks; no managed runtime was downloaded.' }
    }
    if ($null -eq $selected) {
        # 完整哈希保存在标记中；目录缩短仅为兼容 Windows 常见路径长度限制，碰撞时拒绝覆盖。
        $runtimeName = "$runtimeVersion-win32-x64-$($runtimeBinaryHash.Substring(0, 16))-$($runtimeHash.Substring(0, 16))"
        $runtimeDirectory = Join-Path $InstallRoot ('runtimes/' + $runtimeName)
        $nodePath = Join-Path $runtimeDirectory 'tensor-forge-runtime/bin/node.exe'
        if ([IO.Directory]::Exists($runtimeDirectory)) {
            if (-not [IO.File]::Exists((Join-Path $runtimeDirectory '.archive-sha256')) -or [IO.File]::ReadAllText((Join-Path $runtimeDirectory '.archive-sha256')).Trim() -ne $runtimeHash) { Stop-Install 7 'The managed runtime cache is incomplete or unverified.' }
        } else {
            $archive = Join-Path $script:TaskDirectory 'node.zip'
            Save-DistributionFile $runtimeUrl $archive 2147483648
            $runtimeStage = Join-Path $InstallRoot ('runtimes/.stage-' + [Guid]::NewGuid().ToString('N'))
            $script:Stages += $runtimeStage
            [void] [IO.Directory]::CreateDirectory($runtimeStage)
            Expand-VerifiedZip $archive $runtimeHash 'tensor-forge-runtime' $runtimeStage 2147483648
            if (-not [IO.File]::Exists((Join-Path $runtimeStage 'tensor-forge-runtime/bin/node.exe')) -or -not [IO.File]::Exists((Join-Path $runtimeStage 'tensor-forge-runtime/licenses/node-LICENSE'))) { Stop-Install 7 'The managed runtime archive is missing Node or its license.' }
            if ((Get-Sha256 (Join-Path $runtimeStage 'tensor-forge-runtime/bin/node.exe')) -ne $runtimeBinaryHash) { Stop-Install 7 'The managed Node binary SHA256 does not match.' }
            Write-Utf8 (Join-Path $runtimeStage '.archive-sha256') ($runtimeHash + "`n")
            [IO.Directory]::Move($runtimeStage, $runtimeDirectory)
        }
        if (-not [IO.File]::Exists($nodePath) -or (Get-Sha256 $nodePath) -ne $runtimeBinaryHash) { Stop-Install 7 'The cached managed Node binary SHA256 does not match.' }
        $selected = Test-NodeRuntime $nodePath $runtimeFlavor $candidate $compatibilityHash
        if ($null -eq $selected -or $selected.nodeVersion -ne $runtimeVersion) { Stop-Install 7 'The managed runtime failed capability, version, or native-module checks.' }
        $source = 'managed'
        $flavor = $runtimeFlavor
    }
    $selection = [ordered] @{ schemaVersion = 'forge.runtime-selection/v1'; source = $source; nodePath = $selected.nodePath; nodeVersion = $selected.nodeVersion; platform = 'win32'; arch = 'x64'; compatibilityHash = $selected.compatibilityHash; flavor = $flavor }
    Write-Utf8 (Join-Path $candidate 'runtime-selection.json') (($selection | ConvertTo-Json -Compress) + "`n")
    $selectionHash = Get-Sha256 (Join-Path $candidate 'runtime-selection.json')
    $versionDirectory = Join-Path $InstallRoot ("versions/$version-$($artifactHash.Substring(0, 16))-$($selectionHash.Substring(0, 16))")
    if ([IO.Directory]::Exists($versionDirectory)) {
        if (-not [IO.File]::Exists((Join-Path $versionDirectory '.archive-sha256')) -or [IO.File]::ReadAllText((Join-Path $versionDirectory '.archive-sha256')).Trim() -ne $artifactHash -or
            (Get-Sha256 (Join-Path $versionDirectory 'tensor-forge/runtime-selection.json')) -ne $selectionHash) { Stop-Install 5 'The existing candidate is not a verified managed installation.' }
    } else {
        Write-Utf8 (Join-Path $stage '.archive-sha256') ($artifactHash + "`n")
        [IO.Directory]::Move($stage, $versionDirectory)
    }
    $candidate = Join-Path $versionDirectory 'tensor-forge'
    $entry = Join-Path $candidate 'bin/tensor-forge.ps1'
    $versionOutput = Invoke-CandidateCli $entry @('--version') 'version'
    if ($versionOutput.exitCode -ne 0 -or $versionOutput.stdout.Trim() -ne $version) { Stop-Install 7 'The downloaded CLI version does not match the manifest or could not start.' }
    if ($SkillsDir) {
        $skillResult = Invoke-CandidateCli $entry @('skills', 'sync', '--target', $SkillsDir, '--output', 'json') 'skill'
        if ($skillResult.exitCode -ne 0) { Stop-Install 11 'Optional Skill sync failed; the previous selected CLI remains active.' }
    }
    if ($SkipAuthCheck) { [Console]::Error.WriteLine('Forge CLI installed; credential verification was explicitly skipped.') }
    else {
        # 现有凭据仅做可选验证，失败也不发起浏览器登录或改变凭据。
        $authResult = Invoke-CandidateCli $entry @('auth', 'status', '--verify', '--environment', $Environment, '--output', 'json') 'auth'
        if ($authResult.exitCode -ne 0) { [Console]::Error.WriteLine('Forge CLI installed without a verified credential; use auth login when ready.') }
    }
    if (-not [IO.File]::Exists($ps1Path)) { [IO.File]::WriteAllText($ps1Path, $dispatcher, [Text.UTF8Encoding]::new($true)) }
    if (-not [IO.File]::Exists($cmdPath)) { Write-Utf8 $cmdPath $cmdDispatcher }
    $pointer = [ordered] @{ schemaVersion = 'forge.current-install/v1'; candidate = $candidate; version = $version; packageSha256 = $artifactHash }
    $script:PendingPointer = Join-Path $InstallRoot ('.current-' + [Guid]::NewGuid().ToString('N') + '.json')
    Write-Utf8 $script:PendingPointer (($pointer | ConvertTo-Json -Compress) + "`n")
    Set-CurrentPointer $script:PendingPointer $currentFile
    $script:PendingPointer = $null
    [Console]::Error.WriteLine("Forge CLI is available now: $cmdPath --version")
    [Console]::Error.WriteLine("Add this directory to your user PATH if needed: $BinDir")
    [Console]::Out.WriteLine($cmdPath)
    $script:InstallExitCode = 0
} catch {
    if ($script:InstallMessage) { [Console]::Error.WriteLine('Forge CLI installer: ' + $script:InstallMessage) }
    else { [Console]::Error.WriteLine('Forge CLI installer: installation validation failed; the previous selected CLI remains active.') }
} finally {
    if ($null -ne $script:LockStream) { $script:LockStream.Dispose() }
    if ($script:LockFile) { Remove-Item -LiteralPath $script:LockFile -Force -ErrorAction SilentlyContinue }
    if ($script:PendingPointer) { Remove-Item -LiteralPath $script:PendingPointer -Force -ErrorAction SilentlyContinue }
    foreach ($stage in $script:Stages) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:TaskDirectory) { Remove-Item -LiteralPath $script:TaskDirectory -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $script:InstallExitCode
