#!/usr/bin/env powershell

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

# Parses KEY=VALUE text into a hashtable. Never evaluates anything: only whitelisted
# keys are kept, values are taken literally (split on the first '='), and one pair
# of surrounding quotes is stripped. Blank lines and # comments are ignored.
function ConvertFrom-EnvText {
    param([string]$Text, [string[]]$AllowedKeys)
    $result = @{}
    foreach ($line in ($Text -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1)
        if ($key -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        if ($AllowedKeys -cnotcontains $key) { continue }
        if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $result[$key] = $val
    }
    return $result
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

Please run '.\riskybit.ps1 update' to update the project's git repository and Docker images.
"@

# ---- Parse arguments ----
$dev = $false
$gpu = 2
foreach ($a in $args) {
    if     ($a -ceq '--dev')   { $dev = $true }
    elseif ($a -ceq 'amd')     { $gpu = 0 }
    elseif ($a -ceq 'nvidia')  { $gpu = 1 }
    elseif ($a -ceq 'null')    { $gpu = 2 }
    else { Die "unknown option: $a (supported: --dev, amd, nvidia, null)" 2 }
}

# ---- Paths ----
$dataDir     = Join-Path $env:ProgramData 'riskybit'
$envFile     = Join-Path $dataDir 'docker-app.env'
$secretsFile = Join-Path $dataDir 'riskybit-secrets.gpg'
$keyFile     = Join-Path $dataDir 'host.key'

# ---- Setup configuration check paths early ----
foreach ($f in $envFile, $secretsFile, $keyFile) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        Die "missing setup configuration ($f). Please run the setup command first."
    }
}
foreach ($f in $envFile, $secretsFile, $keyFile) {
    try   { [IO.File]::OpenRead($f).Dispose() }
    catch { Die "cannot read $f (you need to run as administrator). Run the setup command if it is missing." }
}

# ---- Read env file early for validation ----
$script:step = "reading $envFile"
$appEnv = ConvertFrom-EnvText ([IO.File]::ReadAllText($envFile)) @('ADMIN_EMAIL', 'DOMAIN')
foreach ($k in 'ADMIN_EMAIL', 'DOMAIN') {
    if (-not $appEnv[$k]) { Die "$k is missing in $envFile. Re-run the setup command." }
}

# ---- Decrypt secrets early for validation ----
$script:step = "decrypting secrets (wrong or damaged host.key?)"
$secretText = Get-Secret $keyFile $secretsFile
if (-not $secretText) {
    Die "could not decrypt $secretsFile (wrong or damaged host.key?). Re-run the setup command."
}

$secretKeys = @('ADMIN_PASSWORD', 'DB_PASS', 'JWT_SECRET', 'CSRF_SECRET', 'INTERNAL_SECRET')
$secrets = ConvertFrom-EnvText $secretText $secretKeys
$secretText = $null
foreach ($k in $secretKeys) {
    if (-not $secrets[$k]) { Die "$k is missing or empty in the decrypted secrets. Re-run the setup command." }
}

# Temporarily export variables for docker compose config validation
foreach ($k in $secretKeys) { Set-Item -Path "Env:$k" -Value $secrets[$k] }
Set-Item -Path "Env:DOMAIN" -Value $appEnv['DOMAIN']
Set-Item -Path "Env:ADMIN_EMAIL" -Value $appEnv['ADMIN_EMAIL']

# Determine compose files early so validation includes overrides
$composeFiles = @('./docker-compose.yaml')
if ($gpu -eq 0) {
    $composeFiles += './compose.amd.yaml'
}
elseif ($gpu -eq 1) {
    $composeFiles += './compose.nvidia.yaml'
}

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

$script:step = "validating docker compose configuration"
$configArgs = @('compose', '--env-file', $envFile)
foreach ($f in $composeFiles) {
    $configArgs += @('-f', $f)
}
$configArgs += @('config', '-q')

$cfg = Test-Native { docker @configArgs }
if (-not $cfg.Ok) {
    Die "docker compose configuration check failed.`n$($cfg.Output)"
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

# ---- Start containers ----
$script:step = "starting containers"
$composeArgs = @('compose', '--env-file', $envFile)
foreach ($f in $composeFiles) {
    $composeArgs += @('-f', $f)
}
$composeArgs += @('up', '-d')

try {
    Invoke-Native docker $composeArgs | Out-Null
}
finally {
    # Clean up temporary environment variables
    foreach ($k in $secretKeys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    Remove-Item "Env:DOMAIN" -ErrorAction SilentlyContinue
    Remove-Item "Env:ADMIN_EMAIL" -ErrorAction SilentlyContinue
    $secrets = $null
}

$domain = $appEnv['DOMAIN']
Write-Output "Admin Frontend running via admin.$domain"
Write-Output "Chat Frontend running via chat.$domain"
Write-Output "App Frontend running via app.$domain"
Write-Output "API running via api.$domain"

exit 0
