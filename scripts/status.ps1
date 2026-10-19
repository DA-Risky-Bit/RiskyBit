$ErrorActionPreference = 'Stop'

function Die([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("Error: $Message")
    exit $Code
}

# Run a native command, capture stdout as lines, fail on non-zero exit
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $out = & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "command failed (exit $LASTEXITCODE): $Exe $($Arguments -join ' ')"
    }
    return $out
}

try {
    # --- preflight checks ---
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Die 'required command not found: docker'
    }

    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        Die "the 'docker compose' plugin is not available. Install Docker Compose v2."
    }

    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Die 'cannot connect to the Docker daemon. Is it running, and do you have permission to use it?'
    }

    & docker compose config -q *> $null
    if ($LASTEXITCODE -ne 0) {
        Die "no valid compose project found in '$(Get-Location)'. Run this from the project directory (check the compose file and any required env vars)."
    }

    # --- running containers ---
    $ids = @(Invoke-Native docker @('compose', 'ps', '-q') | Where-Object { $_ })
    if ($ids.Count -eq 0) {
        Write-Output 'No running containers'
        exit 0
    }

    # --- stats: Name \t CPU \t MemUsage \t Mem% ---
    $statsLines = Invoke-Native docker (@(
        'stats', '--no-stream',
        '--format', '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
    ) + $ids)

    $stats = @{}
    foreach ($line in $statsLines) {
        if (-not $line) { continue }
        $f = $line -split "`t"
        $stats[$f[0]] = @{ Cpu = $f[1]; Mem = $f[2]; MemP = $f[3] }
    }

    # --- compose ps: Name \t Service \t State \t published ports ---
    $psLines = Invoke-Native docker @(
        'compose', 'ps', '-a',
        '--format',
        '{{.Name}}\t{{.Service}}\t{{.State}}\t{{range .Publishers}}{{if .PublishedPort}}{{.PublishedPort}} {{end}}{{end}}'
    )

    $rows = foreach ($line in $psLines) {
        if (-not $line) { continue }
        $f = $line -split "`t"
        $name    = $f[0]
        $service = $f[1]
        $state   = $f[2]
        $portStr = if ($f.Count -gt 3) { $f[3] } else { '' }

        # de-duplicate ports, preserving order
        $ports = @($portStr -split '\s+' | Where-Object { $_ } | Select-Object -Unique)
        $sortKey = if ($ports.Count -gt 0) { [int]$ports[0] } else { 99999 }

        $s = $stats[$name]
        [pscustomobject]@{
            SortKey = $sortKey
            SERVICE = $service
            STATE   = $state
            PORTS   = if ($ports.Count -gt 0) { $ports -join ',' } else { '-' }
            CPU     = if ($s) { $s.Cpu }  else { '-' }
            MEM     = if ($s) { $s.Mem }  else { '-' }
            'MEM%'  = if ($s) { $s.MemP } else { '-' }
        }
    }

    $rows |
        Sort-Object SortKey |
        Format-Table SERVICE, STATE, PORTS, CPU, MEM, 'MEM%' -AutoSize |
        Out-String -Width 4096 |
        ForEach-Object { $_.TrimEnd() } |
        Write-Output

    exit 0
}
catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    exit 1
}
