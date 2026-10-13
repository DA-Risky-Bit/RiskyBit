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

$script:step = "locating the project directory"

$here   = (Get-Location).Path
$parent = Split-Path -Parent $here

if ([string]::IsNullOrWhiteSpace($parent)) {
    Die "could not resolve the project directory from '$here'."
}

Set-Location -LiteralPath $parent
$root = (Get-Location).Path

if ([string]::IsNullOrWhiteSpace($root)) {
    Die "Refusing to delete '$root'"
}

$full = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')

$protected = @(
    [IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    $env:USERPROFILE
    $env:SystemRoot
    $env:ProgramFiles
    ${env:ProgramFiles(x86)}
    $env:ProgramData
    $env:SystemDrive
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') }

if ($full -eq '' -or $protected -contains $full) {
    Die "Refusing to delete '$full'"
}

$script:step = "running safety checks"

$scriptName = Split-Path -Leaf $PSCommandPath
if (-not (Test-Path -LiteralPath (Join-Path $root "scripts\$scriptName") -PathType Leaf)) {
    Die "'$root' does not look like the project directory ('scripts\$scriptName' not found). Refusing to delete it."
}

$rootNorm = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + '\'

$homes = @($env:USERPROFILE)
$homes += Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
          Where-Object { -not $_.Special } |
          ForEach-Object { $_.LocalPath }

foreach ($h in ($homes | Where-Object { $_ } | Select-Object -Unique)) {
    $hNorm = [IO.Path]::GetFullPath($h).TrimEnd('\', '/') + '\'
    if ($hNorm.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) {
        Die "refusing to delete '$root': it is or contains the home directory '$h'."
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Die "docker is not installed, so the containers cannot be stopped. Nothing was removed."
}
if (-not (Test-Native { docker compose version }).Ok) {
    Die "the 'docker compose' plugin is not available. Nothing was removed."
}
if (-not (Test-Native { docker info }).Ok) {
    Die "cannot connect to the Docker daemon (is Docker Desktop running?). Nothing was removed."
}

Push-Location -LiteralPath $root
try     { $cfg = Test-Native { docker compose config -q } }
finally { Pop-Location }
if (-not $cfg.Ok) {
    Die "docker compose cannot read the project in '$root'. Nothing was removed.`n$($cfg.Output)"
}

$keyPath = Join-Path $env:ProgramData 'riskybit\host.key'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
               IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ((Test-Path -LiteralPath $keyPath) -and -not $isAdmin) {
    Die "removing '$keyPath' requires administrator rights. Re-run from an elevated PowerShell. Nothing was removed."
}

if ([Console]::IsInputRedirected) {
    Die "an interactive terminal is required for the confirmation prompt. Nothing was removed."
}

$script:step = "asking for confirmation"
$answer = Read-Host "Remove the whole project at $root from your computer? (y/N)"
if ($answer -notmatch '^[yY]$') {
    Write-Host "Aborted."
    exit 0
}

$script:step = "stopping containers and removing volumes (the project has NOT been deleted)"
Set-Location -LiteralPath $root
Invoke-Native docker @('compose', 'down', '--volumes', '--remove-orphans')

$script:step = "removing the encryption key"
if (Test-Path -LiteralPath $keyPath) {
    Remove-Item -LiteralPath $keyPath -Force
}
Write-Host "Removed encryption key"

$script:step = "deleting the project directory"
$driveRoot = [IO.Path]::GetPathRoot($root)
Set-Location -LiteralPath $driveRoot
[Environment]::CurrentDirectory = $driveRoot

Start-Process cmd.exe -WindowStyle Hidden -ArgumentList '/c', "ping -n 3 127.0.0.1 >nul & rd /s /q `"$root`""
Write-Host "The project folder at $root will be deleted in a few seconds."
exit 0
