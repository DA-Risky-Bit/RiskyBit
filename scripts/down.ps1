$ErrorActionPreference = 'Stop'
$script:step = "starting up"

function Die {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine("Error: $Message")
    exit $Code
}

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($Arguments -join ' ')' failed (exit $LASTEXITCODE)"
    }
}

function Test-Native {
    param([scriptblock]$Cmd)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try     { $out = & $Cmd 2>&1 | Out-String }
    finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = $out.Trim() }
}

try {
    foreach ($a in $args) {
        if ($a -cne '--dev') { Die "unknown option: $a (supported: --dev)" 2 }
    }

    $script:step = "running pre-flight checks"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Die "docker is not installed."
    }
    if (-not (Test-Native { docker compose version }).Ok) {
        Die "the 'docker compose' plugin is not available. Install Docker Compose v2."
    }
    if (-not (Test-Native { docker info }).Ok) {
        Die "cannot connect to the Docker daemon. Is Docker Desktop running?"
    }
    $cfg = Test-Native { docker compose config -q }
    if (-not $cfg.Ok) {
        Die "docker compose could not read the project in '$((Get-Location).Path)'. Run this from the project directory.`n$($cfg.Output)"
    }

    $script:step = "stopping containers"
    Write-Host "Stopping all Containers..."
    Invoke-Native docker @('compose', 'stop')
}
catch {
    [Console]::Error.WriteLine(
        "Error: down failed while $script:step at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)")
    exit 1
}
