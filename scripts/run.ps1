#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$script:step = "starting up"

trap {
    [Console]::Error.WriteLine("Error: run failed while $($script:step): $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
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

# Runs a native command and returns its stdout lines; throws on non-zero exit
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $out = & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($Arguments -join ' ')' failed (exit $LASTEXITCODE)"
    }
    return $out
}

# Decrypts a gpg file with the host key; returns stdout only (stderr discarded)
function Get-Secret {
    param([string]$KeyFile, [string]$File)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & gpg --batch --decrypt --passphrase-file $KeyFile $File 2>$null
    }
    finally { $ErrorActionPreference = $prev }
    if ($null -eq $out) { return '' }
    return (@($out) -join "`n").TrimEnd("`r", "`n")
}

[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ACCEPT = 'application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

# HEAD request that returns status/digest/auth header instead of throwing on 401
function Invoke-Head {
    param([string]$Url, [hashtable]$Headers)
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -Headers $Headers -UseBasicParsing -ErrorAction Stop
        return [pscustomobject]@{
            Status = [int]$r.StatusCode
            Digest = @($r.Headers['Docker-Content-Digest'])[0]
            Auth   = $null
        }
    }
    catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return $null }
        $auth = $null
        try { $auth = ($resp.Headers.GetValues('WWW-Authenticate') -join ', ') } catch {}
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Digest = $null; Auth = $auth }
    }
}

function Get-RemoteDigest {
    param([string]$Image)

    $ref = ($Image -split '@')[0]
    $tag = 'latest'

    $lastPart = $ref.Substring($ref.LastIndexOf('/') + 1)
    if ($lastPart.Contains(':')) {
        $tag = $ref.Substring($ref.LastIndexOf(':') + 1)
        $ref = $ref.Substring(0, $ref.LastIndexOf(':'))
    }

    $first = ($ref -split '/')[0]
    if ($ref.Contains('/') -and ($first.Contains('.') -or $first.Contains(':') -or $first -eq 'localhost')) {
        $registry = $first
        $repo = $ref.Substring($first.Length + 1)
    }
    else {
        $registry = 'registry-1.docker.io'
        $repo = $ref
        if (-not $repo.Contains('/')) { $repo = "library/$repo" }
    }

    $url = "https://$registry/v2/$repo/manifests/$tag"
    $head = Invoke-Head $url @{ Accept = $ACCEPT }
    if ($null -eq $head) { return $null }

    if ($head.Status -eq 401 -and $head.Auth) {
        $realm   = [regex]::Match($head.Auth, 'realm="([^"]*)"').Groups[1].Value
        $service = [regex]::Match($head.Auth, 'service="([^"]*)"').Groups[1].Value
        $token   = (Invoke-RestMethod -Uri "${realm}?service=${service}&scope=repository:${repo}:pull").token
        $head = Invoke-Head $url @{ Accept = $ACCEPT; Authorization = "Bearer $token" }
        if ($null -eq $head) { return $null }
    }

    return $head.Digest
}

# ---- Messages ----
$errSubmodules = @"

Submodules are missing or out of sync.

Please run '.\riskybit.ps1 setup' to setup the project.
"@

$errImagesMissing = @"

Docker images are missing.

Please run '.\riskybit.ps1 setup' to setup the project or manually build via Docker Compose.
"@

$errImagesOutdated = @"

Docker images are not up to date.

Please run '.\riskybit.ps1 setup' to update the project's git and Docker images.
"@

# ---- Parse arguments ----
$dev = $false
foreach ($a in $args) {
    if ($a -ceq '--dev') { $dev = $true }
    else { Die "unknown option: $a (supported: --dev)" 2 }
}

# ---- Paths ----
$dataDir     = Join-Path $env:ProgramData 'riskybit'
$envFile     = Join-Path $dataDir 'docker-app.env'
$dbPassFile  = Join-Path $dataDir 'docker-password.gpg'
$adminFile   = Join-Path $dataDir 'admin-password.gpg'
$keyFile     = Join-Path $dataDir 'host.key'

# ---- Pre-flight checks ----
$script:step = "running pre-flight checks"

foreach ($cmd in 'docker', 'gpg') {
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
$cfg = Test-Native { docker compose config -q }
if (-not $cfg.Ok) {
    Die "docker compose could not read the project in '$((Get-Location).Path)'. Run this from the project directory.`n$($cfg.Output)"
}

# ---- Git updates ----
$script:step = "fetching git updates"
$fetch = Test-Native { git fetch }
if (-not $fetch.Ok) {
    [Console]::Error.WriteLine("Warning: 'git fetch' failed; continuing with local git state.")
}

if ($dev) {
    $script:step = "checking git submodules"
    $sub = Test-Native { git submodule status --recursive }
    if (-not $sub.Ok) {
        Die "unable to read git submodule status (is '$((Get-Location).Path)' a git repository?)"
    }
    if (@($sub.Lines | Where-Object { $_ -match '^[-+U]' }).Count -gt 0) {
        Write-Output $errSubmodules
        exit 1
    }
    Write-Output "All submodules are up to date"
}

# ---- Missing images ----
$script:step = "checking for missing docker images"
$images = @(Invoke-Native docker @('compose', 'config', '--images') | Where-Object { $_ } | Sort-Object -Unique)

$missing = $false
foreach ($img in $images) {
    if (-not (Test-Native { docker image inspect $img }).Ok) {
        Write-Output "Missing: $img"
        $missing = $true
    }
}
if ($missing) {
    Write-Output $errImagesMissing
    exit 1
}

# ---- Outdated images ----
$script:step = "checking for image updates"
Write-Output "Checking for updates for images."

$outdated = $false
foreach ($img in $images) {
    $res = Test-Native { docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' $img }
    $localDigests = @()
    if ($res.Ok) {
        $localDigests = @($res.Lines | Where-Object { $_ } | ForEach-Object { ($_ -split '@')[-1] })
    }

    if ($localDigests.Count -eq 0) {
        Write-Output "Skipped (missing locally or built locally): $img"
        continue
    }

    try   { $remote = Get-RemoteDigest $img }
    catch { $remote = $null }

    if (-not $remote) {
        Write-Output "Could not query registry: $img"
    }
    elseif ($localDigests -contains $remote) {
        Write-Output "Up to date:  $img"
    }
    else {
        Write-Output "Outdated:    $img"
        $outdated = $true
    }
}
if ($outdated) {
    Write-Output $errImagesOutdated
    exit 1
}

# ---- Setup configuration ----
$script:step = "checking setup configuration"
foreach ($f in $envFile, $dbPassFile, $adminFile) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        Die "missing setup configuration ($f). Please run the setup command first."
    }
}
foreach ($f in $envFile, $dbPassFile, $adminFile, $keyFile) {
    try   { [IO.File]::OpenRead($f).Dispose() }
    catch { Die "cannot read $f (it is missing, or you need to run as administrator). Run the setup command if it is missing." }
}

# ---- Decrypt secrets ----
$script:step = "decrypting secrets (wrong or damaged host.key?)"
$dbPass    = Get-Secret $keyFile $dbPassFile
$adminPass = Get-Secret $keyFile $adminFile
if (-not $dbPass)    { Die "decrypted database password is empty. Re-run the setup command." }
if (-not $adminPass) { Die "decrypted admin password is empty. Re-run the setup command." }

# ---- Start containers ----
$script:step = "starting containers"
$env:DB_PASS    = $dbPass
$env:ADMIN_PASS = $adminPass
try {
    Invoke-Native docker @('compose', '--env-file', $envFile, 'up', '-d') | Out-Null
}
finally {
    Remove-Item Env:\DB_PASS    -ErrorAction SilentlyContinue
    Remove-Item Env:\ADMIN_PASS -ErrorAction SilentlyContinue
    $dbPass = $null
    $adminPass = $null
}

Write-Output "Admin Frontend running via admin.localhost"
Write-Output "Chat Frontend running via chat.localhost"
Write-Output "App Frontend running via app.localhost"

exit 0
