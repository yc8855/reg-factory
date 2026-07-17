param(
    [string]$Root = $PSScriptRoot,
    [switch]$SkipPull
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = [System.IO.Path]::GetFullPath($Root)
$Port = if ($env:REG_FACTORY_PORT) { [int]$env:REG_FACTORY_PORT } else { 8799 }
$StatusUrl = "http://127.0.0.1:$Port/api/status"
$VenvPython = Join-Path $Root ".venv\Scripts\python.exe"

function Get-PanelStatus {
    try {
        return Invoke-RestMethod -Uri $StatusUrl -TimeoutSec 5
    } catch {
        return $null
    }
}

function Assert-NoRunningTasks {
    $status = Get-PanelStatus
    if ($null -ne $status -and [int]$status.running -gt 0) {
        throw "The WebUI has $($status.running) running task(s). Stop them before updating."
    }
}

function Update-Repository {
    if (Test-Path (Join-Path $Root ".git")) {
        & git -C $Root pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw "git pull --ff-only failed" }
        return
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("reg-factory-update-" + [guid]::NewGuid())
    $zipPath = Join-Path $tempRoot "main.zip"
    $extractPath = Join-Path $tempRoot "extract"
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
    try {
        Invoke-WebRequest -Uri "https://github.com/tiantianGPU/reg-factory/archive/refs/heads/main.zip" -OutFile $zipPath
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
        $source = Join-Path $extractPath "reg-factory-main"
        if (-not (Test-Path $source)) { throw "GitHub archive layout is invalid" }
        Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $Root -Recurse -Force
    } finally {
        if (Test-Path $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Get-ExpectedVersion {
    if (-not (Test-Path (Join-Path $Root ".git"))) { return "archive" }
    $version = (& git -C $Root rev-parse --short=12 HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)) {
        throw "Unable to read the updated Git version"
    }
    return $version
}

function Stop-Panel {
    $status = Get-PanelStatus
    $panelPid = 0
    if ($null -ne $status -and $null -ne $status.PSObject.Properties["pid"]) {
        $panelPid = [int]$status.pid
    }
    if ($panelPid -le 0) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $listener) { return }
        $panelPid = [int]$listener.OwningProcess
    }

    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $panelPid"
    if ($null -eq $process) { return }
    $expectedPython = [System.IO.Path]::GetFullPath($VenvPython)
    $chain = @()
    $current = $process
    for ($i = 0; $i -lt 8 -and $null -ne $current; $i++) {
        $chain += $current
        if ([int]$current.ParentProcessId -le 0) { break }
        $current = Get-CimInstance Win32_Process -Filter "ProcessId = $($current.ParentProcessId)" -ErrorAction SilentlyContinue
    }

    $owner = $null
    $otherRoot = $null
    foreach ($candidate in $chain) {
        if (-not $candidate.ExecutablePath) { continue }
        $candidatePath = [System.IO.Path]::GetFullPath($candidate.ExecutablePath)
        if ($candidatePath -eq $expectedPython) {
            $owner = $candidate
            break
        }
        if ($candidatePath -match "(?i)\\\.venv\\Scripts\\python(?:w)?\.exe$") {
            $venvDir = Split-Path (Split-Path $candidatePath -Parent) -Parent
            $otherRoot = Split-Path $venvDir -Parent
        }
    }

    if ($process.CommandLine -notmatch "uvicorn\s+webui\.server:app") {
        throw "Port $Port is not a reg-factory WebUI; refusing to stop PID $panelPid."
    }
    if ($null -eq $owner) {
        if ($otherRoot) {
            throw "Port $Port belongs to another reg-factory installation: $otherRoot. Set REG_FACTORY_DIR to that path or stop it first."
        }
        throw "Port $Port is not owned by the reg-factory installation at $Root; refusing to stop PID $panelPid."
    }

    # A Windows venv launcher may own a base-Python child that holds the port.
    # Stop the matching launcher tree, or its dedicated start.bat console when present.
    $stopPid = [int]$owner.ProcessId
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($owner.ParentProcessId)" -ErrorAction SilentlyContinue
    if ($null -ne $parent -and $parent.Name -eq "cmd.exe" -and
        $parent.CommandLine -match "start\.bat") {
        $stopPid = [int]$parent.ProcessId
    }

    Write-Host "Stopping old WebUI (PID $panelPid) ..." -ForegroundColor Yellow
    & taskkill.exe /PID $stopPid /T /F | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        if ($null -eq (Get-Process -Id $panelPid -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "Old WebUI process did not stop"
}

function Start-Panel {
    $starter = Join-Path $Root "start.bat"
    if (-not (Test-Path $starter)) { throw "start.bat not found in $Root" }
    $command = 'call "' + $starter + '"'
    Start-Process -FilePath "cmd.exe" -ArgumentList @("/k", $command) -WorkingDirectory $Root
}

function Wait-ForUpdatedPanel([string]$ExpectedVersion) {
    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 1
        $status = Get-PanelStatus
        if ($null -ne $status -and
            $null -ne $status.PSObject.Properties["version"] -and
            $status.version -eq $ExpectedVersion) {
            return $status
        }
    }
    throw "Updated WebUI did not become healthy at $StatusUrl"
}

Write-Host "Updating reg-factory in $Root" -ForegroundColor Cyan
Assert-NoRunningTasks
if (-not $SkipPull) { Update-Repository }

# Check again in case somebody started a task while files were updating.
Assert-NoRunningTasks
$expectedVersion = Get-ExpectedVersion
Stop-Panel

$env:REG_FACTORY_NONINTERACTIVE = "1"
$installer = Join-Path $Root "install.bat"
& cmd.exe /d /c ('call "' + $installer + '"')
if ($LASTEXITCODE -ne 0) { throw "Dependency update failed" }

Start-Panel
$status = Wait-ForUpdatedPanel $expectedVersion

Write-Host "Updated successfully: $($status.version)" -ForegroundColor Green
Write-Host "Panel: http://127.0.0.1:$Port/"
