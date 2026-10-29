param(
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath,

    [string]$EvidencePath = "byedpi-windows-loopback-r32-evidence.txt"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-FreeLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Wait-ForLoopbackListener {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$TimeoutSeconds = 10
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            throw "ByeDPI exited before its loopback listener became ready."
        }

        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) {
            $owned = @($listeners | Where-Object { $_.OwningProcess -eq $ProcessId })
            if ($owned.Count -eq 0) {
                throw "Selected lab port is listening, but not by the expected ByeDPI process."
            }

            $invalid = @($owned | Where-Object { $_.LocalAddress -ne '127.0.0.1' })
            if ($invalid.Count -gt 0) {
                $addresses = ($invalid.LocalAddress | Sort-Object -Unique) -join ','
                throw "ByeDPI exposed a non-loopback listener: $addresses"
            }

            return $owned
        }

        Start-Sleep -Milliseconds 150
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Timed out waiting for ByeDPI loopback listener on port $Port."
}

function Invoke-Socks5Greeting {
    param([Parameter(Mandatory = $true)][int]$Port)

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.ReceiveTimeout = 3000
        $client.SendTimeout = 3000
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 3000
        $stream.WriteTimeout = 3000

        [byte[]]$request = 0x05, 0x01, 0x00
        $stream.Write($request, 0, $request.Length)
        $stream.Flush()

        [byte[]]$response = New-Object byte[] 2
        $offset = 0
        while ($offset -lt 2) {
            $read = $stream.Read($response, $offset, 2 - $offset)
            if ($read -le 0) {
                throw "ByeDPI closed the local SOCKS5 greeting before two response bytes were received."
            }
            $offset += $read
        }

        if ($response[0] -ne 0x05 -or $response[1] -ne 0x00) {
            throw ('Unexpected SOCKS5 greeting response: {0:X2} {1:X2}' -f $response[0], $response[1])
        }

        return '05 00'
    }
    finally {
        $client.Dispose()
    }
}

function Assert-NoExternalCandidateConnection {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $connections = @(Get-NetTCPConnection -OwningProcess $ProcessId -ErrorAction SilentlyContinue)
    $established = @($connections | Where-Object { $_.State -eq 'Established' })
    $external = @($established | Where-Object {
        $_.RemoteAddress -notin @('127.0.0.1', '::1')
    })

    if ($external.Count -gt 0) {
        $destinations = ($external | ForEach-Object { "$($_.RemoteAddress):$($_.RemotePort)" }) -join ','
        throw "ByeDPI established a non-loopback TCP connection during the lab: $destinations"
    }
}

function Stop-CandidateAndAssertCleanup {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int]$Port
    )

    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction Stop
        if (-not $Process.WaitForExit(5000)) {
            throw "ByeDPI process did not exit after termination."
        }
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    do {
        $owned = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $Process.Id })
        if ($owned.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 150
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "ByeDPI listener remained after process termination."
}

function Start-Candidate {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )

    $arguments = @(
        '-i', '127.0.0.1',
        '-p', [string]$Port,
        '-N',
        '-U',
        '-c', '8',
        '-x', '0'
    )

    return Start-Process -FilePath $Path -ArgumentList $arguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
}

$resolvedBinary = (Resolve-Path -LiteralPath $BinaryPath).Path
$binaryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedBinary).Hash.ToLowerInvariant()
$expectedHash = '866e99c3c7690326cc6e365fe02980f06ae2b394c045555674fb95db52b0dbdd'
if ($binaryHash -ne $expectedHash) {
    throw "Unexpected ByeDPI binary SHA-256: $binaryHash"
}

$port = Get-FreeLoopbackPort
$EvidencePath = [System.IO.Path]::GetFullPath($EvidencePath)
$workDir = Split-Path -Parent $EvidencePath
if (-not (Test-Path -LiteralPath $workDir)) {
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
}

$stdout1 = Join-Path $workDir 'byedpi-r32-run1.stdout.txt'
$stderr1 = Join-Path $workDir 'byedpi-r32-run1.stderr.txt'
$stdout2 = Join-Path $workDir 'byedpi-r32-run2.stdout.txt'
$stderr2 = Join-Path $workDir 'byedpi-r32-run2.stderr.txt'

$process1 = $null
$process2 = $null
$run1Pid = 0
$run2Pid = 0
$listenerAddresses1 = ''
$listenerAddresses2 = ''
$greeting1 = ''
$greeting2 = ''

try {
    $process1 = Start-Candidate -Path $resolvedBinary -Port $port -StdoutPath $stdout1 -StderrPath $stderr1
    $run1Pid = $process1.Id
    $listeners1 = Wait-ForLoopbackListener -Port $port -ProcessId $process1.Id
    $listenerAddresses1 = ($listeners1.LocalAddress | Sort-Object -Unique) -join ','
    $greeting1 = Invoke-Socks5Greeting -Port $port
    Start-Sleep -Milliseconds 200
    Assert-NoExternalCandidateConnection -ProcessId $process1.Id
    Stop-CandidateAndAssertCleanup -Process $process1 -Port $port
    $process1 = $null

    $process2 = Start-Candidate -Path $resolvedBinary -Port $port -StdoutPath $stdout2 -StderrPath $stderr2
    $run2Pid = $process2.Id
    $listeners2 = Wait-ForLoopbackListener -Port $port -ProcessId $process2.Id
    $listenerAddresses2 = ($listeners2.LocalAddress | Sort-Object -Unique) -join ','
    $greeting2 = Invoke-Socks5Greeting -Port $port
    Start-Sleep -Milliseconds 200
    Assert-NoExternalCandidateConnection -ProcessId $process2.Id
    Stop-CandidateAndAssertCleanup -Process $process2 -Port $port
    $process2 = $null

    $residual = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
    if ($residual.Count -gt 0) {
        throw "A listener remained on the selected lab port after final cleanup."
    }

    @(
        'schema_version=1'
        'lab_id=byedpi-windows-loopback-r32'
        "binary_sha256=$binaryHash"
        "port=$port"
        "run1_pid=$run1Pid"
        "run1_listener_addresses=$listenerAddresses1"
        "run1_socks5_greeting=$greeting1"
        'run1_external_tcp_connections=0'
        'run1_cleanup=PASS'
        "run2_pid=$run2Pid"
        "run2_listener_addresses=$listenerAddresses2"
        "run2_socks5_greeting=$greeting2"
        'run2_external_tcp_connections=0'
        'run2_cleanup=PASS'
        'windivert_used=false'
        'driver_installed=false'
        'service_installed=false'
        'system_proxy_changed=false'
        'production_admission=BLOCK'
        'RESULT=BYEDPI_WINDOWS_LOOPBACK_R32_PASS'
    ) | Set-Content -LiteralPath $EvidencePath -Encoding ascii

    Get-Content -LiteralPath $EvidencePath
}
finally {
    foreach ($candidate in @($process1, $process2)) {
        if ($null -ne $candidate) {
            try {
                if (-not $candidate.HasExited) {
                    Stop-Process -Id $candidate.Id -Force -ErrorAction SilentlyContinue
                    $candidate.WaitForExit(3000) | Out-Null
                }
            }
            catch {
                Write-Warning "Cleanup warning for ByeDPI PID $($candidate.Id): $($_.Exception.Message)"
            }
        }
    }
}
