$ErrorActionPreference = 'Stop'
$script:step = "starting up"

trap {
    [Console]::Error.WriteLine("Error: update failed while $($script:step): $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    exit 1
}

# ---- Helpers ----
function Die {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine("Error: $Message")
    exit $Code
}

# Runs a command, never throws. Returns Ok, Lines and Output (stdout+stderr merged).
function Test-Native {
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        $lines = @(& $Command 2>&1 | ForEach-Object { "$_" })
        $ok = ($LASTEXITCODE -eq 0)
    }
    catch {
        $lines = @($_.Exception.Message)
        $ok = $false
    }
    finally { $ErrorActionPreference = $prev }
    [pscustomobject]@{ Ok = $ok; Lines = $lines; Output = ($lines -join "`n") }
}

# Runs a native command quietly (stdout captured); throws on non-zero exit
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $out = & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($Arguments -join ' ')' failed (exit $LASTEXITCODE)"
    }
    return $out
}

# Runs a native command with live output; throws on non-zero exit
function Invoke-Live {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($Arguments -join ' ')' failed (exit $LASTEXITCODE)"
    }
}

# ---- Parse arguments ----
$dev = $false
$gpu = 2
foreach ($a in $args) {
    if     ($a -ceq '--dev')   { $dev = $true }
    elseif ($a -ceq 'amd')     { $gpu = 0 }
    elseif ($a -ceq 'nvidia')  { $gpu = 1 }
    elseif ($a -ceq 'null')    { $gpu = 2 }
    else { Die "unknown option: $a (supported: --dev, amd, nvidia)" 2 }
}

# ---- Admin check ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
               IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Die "this script must be run as administrator. Run it via the main script or from an elevated PowerShell."
}

# ---- Paths ----
$dataDir    = Join-Path $env:ProgramData 'riskybit'
$envFile    = Join-Path $dataDir 'docker-app.env'
$dbPassFile = Join-Path $dataDir 'docker-password.gpg'
$adminFile  = Join-Path $dataDir 'admin-password.gpg'
$keyFile    = Join-Path $dataDir 'host.key'

# ---- Pre-flight checks ----
$script:step = "running pre-flight checks"
foreach ($cmd in 'docker', 'git') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Die "required command not found: $cmd"
    }
}
if (-not (Test-Native { docker compose version }).Ok) {
    Die "the 'docker compose' plugin is not available. Install Docker Compose v2."
}
if (-not (Test-Native { docker info }).Ok) {
    Die "cannot connect to the Docker daemon. Is Docker Desktop running?"
}
if (-not (Test-Native { git rev-parse --is-inside-work-tree }).Ok) {
    Die "'$((Get-Location).Path)' is not inside a git repository. Run update from the project directory."
}
if (-not (Test-Path -LiteralPath 'config' -PathType Container)) {
    Die "config directory not found in '$((Get-Location).Path)'. Run this from the project directory."
}

# ---- Setup configuration ----
$script:step = "checking setup configuration"
foreach ($f in $envFile, $dbPassFile, $adminFile, $keyFile) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        Die "$f is missing. Please run the setup command first."
    }
}

# ---- Compose arguments ----
$composeArgs = @('compose', '-f', './docker-compose.yaml')
if ($gpu -eq 0)     { $composeArgs += @('-f', './compose.amd.yaml') }
elseif ($gpu -eq 1) { $composeArgs += @('-f', './compose.nvidia.yaml') }

# ---- Git ----
$script:step = "pulling Github commits"
Write-Host "Pulling last Github commits..."
Invoke-Native git @('fetch') | Out-Null
$pull = Test-Native { git pull --ff-only }
if (-not $pull.Ok) {
    Die "git pull failed (local changes or diverged branch?). Resolve it manually and re-run update.`n$($pull.Output)"
}

if ($dev) {
    $script:step = "updating git submodules"
    Write-Host "Updating git submodules..."
    Invoke-Native git @('submodule', 'sync', '--recursive') | Out-Null
    Invoke-Native git @('submodule', 'update', '--init', '--recursive') | Out-Null
}

# ---- Config files: CRLF -> LF (text files only) ----
$script:step = "preparing config files"
Write-Host "Preparing files for docker..."
foreach ($file in Get-ChildItem -LiteralPath 'config' -Recurse -File) {
    try {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -eq 0 -or [Array]::IndexOf($bytes, [byte]0) -ge 0) { continue }   # empty or binary

        $out = New-Object 'System.Collections.Generic.List[byte]' $bytes.Length
        $changed = $false
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 13 -and ($i + 1 -eq $bytes.Length -or $bytes[$i + 1] -eq 10)) {
                $changed = $true
                continue
            }
            $out.Add($bytes[$i])
        }
        if ($changed) { [IO.File]::WriteAllBytes($file.FullName, $out.ToArray()) }
    }
    catch {
        [Console]::Error.WriteLine("Warning: could not normalize line endings of $($file.FullName): $($_.Exception.Message)")
    }
}

# ---- Docker images ----
$script:step = "updating docker images"
Write-Host "Updating docker images..."
if ($dev) {
    Invoke-Live docker ($composeArgs + @('build'))
    Invoke-Live docker ($composeArgs + @('pull', 'traefik', 'db', 'ollama'))
}
else {
    Invoke-Live docker ($composeArgs + @('pull'))
}

# ---- Done ----
$script:step = "checking running containers"
$running = Test-Native { docker compose ps -q }
Write-Output ""
if ($running.Ok -and @($running.Lines | Where-Object { $_ }).Count -gt 0) {
    Write-Output "Update finished. Containers are still running the old images."
    Write-Output "Run '.\riskybit.ps1 run' to recreate them with the updated images."
}
else {
    Write-Output "Update finished. Run '.\riskybit.ps1 run' to start the project."
}

exit 0
