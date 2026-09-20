param(
    [string]$Domain = "example.com",
    [switch]$v
)

chcp 65001 | Out-Null

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Exe = Join-Path $PSScriptRoot "dnscrypt-proxy.exe"
$BaseConfig = Join-Path $PSScriptRoot "dnscrypt-proxy.toml"
$TempDir = Join-Path $env:TEMP "dnscrypt-test"

function Get-FreePort {
    param([int]$StartPort = 53000)

    for ($Port = $StartPort; $Port -le 59999; $Port++) {
        $Udp = $null
        $Tcp = $null
        try {
            $Udp = [System.Net.Sockets.UdpClient]::new([System.Net.IPAddress]::Loopback, $Port)
            $Tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
            $Tcp.Start()
            return $Port
        }
        catch {}
        finally {
            if ($Tcp) { $Tcp.Stop() }
            if ($Udp) { $Udp.Close(); $Udp.Dispose() }
        }
    }
    throw "Не удалось найти свободный TCP/UDP-порт"
}

if (-not (Test-Path $Exe)) {
    Write-Host "Не найден dnscrypt-proxy.exe: $Exe" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $BaseConfig)) {
    Write-Host "Не найден конфиг: $BaseConfig" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

$BaseText = Get-Content -Raw -Encoding UTF8 $BaseConfig

$Resolvers = & $Exe -config $BaseConfig -list 2>$null |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -match '^[a-zA-Z0-9][a-zA-Z0-9._-]*$' } |
    Sort-Object -Unique

if (-not $Resolvers) {
    $Resolvers = @("scaleway-fr", "google", "yandex", "cloudflare")
}

$BadResolvers = [System.Collections.Generic.List[string]]::new()
$Total = @($Resolvers).Count
$Index = 0

foreach ($Resolver in $Resolvers) {
    $Index++
    Write-Progress -Activity "Проверка резолверов" `
        -Status "$Index / $Total : $Resolver" `
        -PercentComplete (($Index / $Total) * 100)

    $Process = $null
    $ConfigPath = $null

    try {
        $Port = Get-FreePort

        $Lines = $BaseText -split "`r?`n"
        $foundServer = $false
        $foundCache = $false

        for ($i = 0; $i -lt $Lines.Count; $i++) {
            $Line = $Lines[$i]

            if ($Line -match '^\s*#?\s*server_names\s*=') {
                $Lines[$i] = "server_names = ['$Resolver']"
                $foundServer = $true
            }
            elseif ($Line -match '^\s*#?\s*cache\s*=') {
                $Lines[$i] = "cache = false"
                $foundCache = $true
            }
        }

        if (-not $foundServer) { $Lines += "server_names = ['$Resolver']" }
        if (-not $foundCache)  { $Lines += "cache = false" }

        $ConfigPath = Join-Path $TempDir ("dnscrypt-" + ($Resolver -replace '[^\w.-]', '_') + ".toml")

        [System.IO.File]::WriteAllText(
            $ConfigPath,
            ($Lines -join "`r`n"),
            [System.Text.UTF8Encoding]::new($false)
        )

        & $Exe -check -config $ConfigPath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if ($v) { Write-Host ("{0,-25} check failed" -f $Resolver) -ForegroundColor DarkYellow }
            [void]$BadResolvers.Add($Resolver)
            continue
        }

        $Process = Start-Process `
            -FilePath $Exe `
            -ArgumentList @("-config", $ConfigPath) `
            -WorkingDirectory $PSScriptRoot `
            -PassThru `
            -WindowStyle Hidden

        Start-Sleep -Milliseconds 2000

        if ($Process.HasExited) {
            if ($v) { Write-Host ("{0,-25} process exited" -f $Resolver) -ForegroundColor DarkYellow }
            [void]$BadResolvers.Add($Resolver)
            continue
        }

        $Sw = [System.Diagnostics.Stopwatch]::StartNew()
        $Output = & nslookup.exe `
            "-type=A" `
            "-timeout=3" `
            "-retry=1" `
            "-port=$Port" `
            $Domain `
            "127.0.0.1" 2>&1 |
            Out-String
        $Sw.Stop()

        $Addresses = [regex]::Matches($Output, '\b(?:\d{1,3}\.){3}\d{1,3}\b') |
            ForEach-Object { $_.Value } |
            Where-Object { $_ -ne "127.0.0.1" } |
            Sort-Object -Unique

        $Bad = ($Addresses.Count -eq 0) -or ($Addresses -contains "0.0.0.0")

        if ($v) {
            $Ips = if ($Addresses.Count -gt 0) { $Addresses -join ", " } else { "-" }
            $Ms = [int]$Sw.Elapsed.TotalMilliseconds
            $Color = if ($Bad) { "DarkYellow" } else { "Green" }
            Write-Host ("{0,-25} {1,-15} {2,5} ms   {3}" -f $Resolver, $Ips, $Ms, ($(if ($Bad) { "BAD" } else { "OK" }))) -ForegroundColor $Color
        }

        if ($Bad) {
            [void]$BadResolvers.Add($Resolver)
        }
    }
    catch {
        if (-not $BadResolvers.Contains($Resolver)) {
            [void]$BadResolvers.Add($Resolver)
        }
        if ($v) {
            Write-Host ("{0,-25} exception: {1}" -f $Resolver, $_.Exception.Message) -ForegroundColor DarkYellow
        }
    }
    finally {
        if ($Process -and -not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
        if ($Process) {
            $Process | Wait-Process -ErrorAction SilentlyContinue
        }
        if ($ConfigPath -and (Test-Path $ConfigPath)) {
            Remove-Item -Path $ConfigPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Progress -Activity "Проверка резолверов" -Completed

Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Проблемные резолверы:"

if ($BadResolvers.Count -gt 0) {
    Write-Host ("['" + ($BadResolvers -join "', '") + "']")
}
else {
    Write-Host "[]"
}
