#Requires -Version 5.1

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

# Paths
$dataDir     = Join-Path $env:ProgramData 'riskybit'
$envFile     = Join-Path $dataDir 'docker-app.env'
$secretsFile = Join-Path $dataDir 'riskybit-secrets.gpg'
$keyFile     = Join-Path $dataDir 'host.key'

try {
    $gpu = 2
    $serviceName = $null
    foreach ($a in $args) {
        if     ($a -ceq '--dev')   { }
        elseif ($a -ceq 'amd')     { $gpu = 0 }
        elseif ($a -ceq 'nvidia')  { $gpu = 1 }
        elseif ($a -ceq 'null')    { $gpu = 2 }
        elseif ($a.StartsWith('-')) { Die "unknown option: $a (supported: --dev, amd, nvidia, null)" 2 }
        else { $serviceName = $a }
    }

    $script:step = "checking setup configuration"
    foreach ($f in $envFile, $secretsFile, $keyFile) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
            Die "missing setup configuration ($f). Please run the setup command first."
        }
    }

    $script:step = "reading configuration"
    $appEnv = ConvertFrom-EnvText ([IO.File]::ReadAllText($envFile)) @('ADMIN_EMAIL', 'DOMAIN')
    foreach ($k in 'ADMIN_EMAIL', 'DOMAIN') {
        if (-not $appEnv[$k]) { Die "$k is missing in $envFile." }
    }

    $script:step = "decrypting secrets"
    $secretText = Get-Secret $keyFile $secretsFile
    if (-not $secretText) { Die "could not decrypt $secretsFile" }

    $secretKeys = @('ADMIN_PASSWORD', 'DB_PASS', 'JWT_SECRET', 'CSRF_SECRET', 'INTERNAL_SECRET')
    $secrets = ConvertFrom-EnvText $secretText $secretKeys
    $secretText = $null
    foreach ($k in $secretKeys) {
        if (-not $secrets[$k]) { Die "$k is missing or empty in decrypted secrets." }
    }

    # Temporarily export variables
    foreach ($k in $secretKeys) { Set-Item -Path "Env:$k" -Value $secrets[$k] }
    Set-Item -Path "Env:DOMAIN" -Value $appEnv['DOMAIN']
    Set-Item -Path "Env:ADMIN_EMAIL" -Value $appEnv['ADMIN_EMAIL']

    $composeFiles = @('./docker-compose.yaml')
    if ($gpu -eq 0) { $composeFiles += './compose.amd.yaml' }
    elseif ($gpu -eq 1) { $composeFiles += './compose.nvidia.yaml' }

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

    $script:step = "validating docker compose configuration"
    $configArgs = @('compose', '--env-file', $envFile)
    foreach ($f in $composeFiles) { $configArgs += @('-f', $f) }
    $configArgs += @('config', '-q')

    $cfg = Test-Native { docker @configArgs }
    if (-not $cfg.Ok) {
        Die "docker compose configuration check failed.`n$($cfg.Output)"
    }

    $script:step = "stopping containers"
    if ($serviceName) {
        Write-Host "Stopping container: $serviceName..."
    } else {
        Write-Host "Stopping all containers..."
    }

    $stopArgs = @('compose', '--env-file', $envFile)
    foreach ($f in $composeFiles) { $stopArgs += @('-f', $f) }
    $stopArgs += @('stop')
    if ($serviceName) {
        $stopArgs += $serviceName
    }

    Invoke-Native docker $stopArgs
}
catch {
    [Console]::Error.WriteLine(
        "Error: down failed while $script:step at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)")
    exit 1
}
finally {
    # Cleanup environment variables
    foreach ($k in $secretKeys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    Remove-Item "Env:DOMAIN" -ErrorAction SilentlyContinue
    Remove-Item "Env:ADMIN_EMAIL" -ErrorAction SilentlyContinue
}
