#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

trap {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())")
    if ($env:MANAGE_ELEVATED -eq '1') { Read-Host "Press Enter to close" | Out-Null }
    exit 1
}

$ScriptDir  = $PSScriptRoot
$scriptName = Split-Path -Leaf $PSCommandPath

$usage = @"

Usage: .\$scriptName <command> [OPTIONS]

Manage the project's Docker Compose stack.

Commands:
  setup     First-time setup: pulls the latest git commits and the Docker
            images, creates the encryption key, and asks for the admin email
            and passwords (stored encrypted).
  run       Checks that the images are present and up to date, then starts
            all containers in the background. Refuses to start if they are
            missing or outdated.
  down      Stops all containers. They are not deleted; use 'run' to start
            them again.
  status    Shows each service's state, ports, CPU and memory usage.
  remove    PERMANENTLY deletes the project: stops the containers, deletes
            their volumes and the project folder, and removes the encryption
            key. Asks for confirmation first. This cannot be undone.

Options:
      --dev     Developer mode:
                  setup   also init/update git submodules, and build the
                          images locally instead of pulling them
                  run     also verifies that the git submodules are in sync
                  others  no effect
  -h, --help    Show this help

Examples:
  .\$scriptName setup          First-time install
  .\$scriptName setup --dev    First-time install for development
  .\$scriptName run            Start the project
  .\$scriptName status         See what is running
  .\$scriptName down           Stop the project

Notes:
  - Needs administrator privileges; if you are not elevated, the script
    asks for elevation (UAC prompt).
  - Run it from the project directory.

"@

# ---- Parse arguments ----
$dev = $false
$positional = @()
foreach ($a in $args) {
    if ($a -ceq '--dev') {
        $dev = $true
    }
    elseif ($a -ceq '-h' -or $a -ceq '--help') {
        Write-Output $usage
        exit 0
    }
    elseif ($a.StartsWith('-')) {
        [Console]::Error.WriteLine("Error: unknown option: $a")
        [Console]::Error.WriteLine($usage)
        exit 1
    }
    else {
        $positional += $a
    }
}

# ---- Admin check / self-elevate ----
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "This script requires administrator privileges. Prompting for elevation..."

    # Re-run with the same PowerShell host (powershell.exe or pwsh.exe), same args, same folder.
    $hostExe = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    $argList += $args | ForEach-Object { "`"$_`"" }

    # The elevated window is separate and closes on exit, so keep it open at the end.
    $cmd = "`$env:MANAGE_ELEVATED='1'; & $hostExe " + ($argList -join ' ') + "; `$c=`$LASTEXITCODE; Read-Host 'Press Enter to close' | Out-Null; exit `$c"
    $p = Start-Process -FilePath $hostExe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) `
        -WorkingDirectory $env:SystemRoot `
        -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
}

# ---- Validate command ----
if ($positional.Count -eq 0) {
    [Console]::Error.WriteLine("Error: no command given.")
    [Console]::Error.WriteLine($usage)
    exit 1
}

if ($positional.Count -gt 1) {
    [Console]::Error.WriteLine("Error: too many arguments (expected one command, got $($positional.Count)): $($positional -join ' ')")
    [Console]::Error.WriteLine($usage)
    exit 1
}

$command = $positional[0]

if ($command -cnotin @('setup', 'run', 'down', 'status', 'remove')) {
    [Console]::Error.WriteLine("Error: unknown command: $command")
    [Console]::Error.WriteLine($usage)
    exit 1
}

$target = Join-Path $ScriptDir "scripts\$command.ps1"
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    [Console]::Error.WriteLine("Error: script not found: $target")
    exit 1
}

# ---- Dispatch ----
$extra = @()
if ($dev) { $extra += '--dev' }

$global:LASTEXITCODE = 0
& $target @extra
exit $LASTEXITCODE
