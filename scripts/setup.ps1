$ErrorActionPreference = 'Stop'
$script:step = "starting up"

trap {
    [Console]::Error.WriteLine("Error: setup failed while $($script:step): $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
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

function Read-NonEmpty {
    param([string]$Prompt)
    $v = Read-Host $Prompt
    while ([string]::IsNullOrWhiteSpace($v)) {
        Write-Host "Warning: value cannot be empty."
        $v = Read-Host $Prompt
    }
    return $v.Trim()
}

function New-RandomPassword {
    param([int]$Length = 24)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] 1
    $sb  = New-Object Text.StringBuilder
    try {
        while ($sb.Length -lt $Length) {
            $rng.GetBytes($buf)
            if ($buf[0] -lt 248) {   # 248 = 62*4, avoids modulo bias
                [void]$sb.Append($chars[$buf[0] % 62])
            }
        }
    }
    finally { $rng.Dispose() }
    return $sb.ToString()
}

function Read-PasswordOrGenerate {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    if ([string]::IsNullOrEmpty($plain)) {
        $plain = New-RandomPassword
        Write-Host "--> Auto-generated password: $plain"
    }
    return $plain
}

# Restrict a file to Administrators and SYSTEM
function Protect-File {
    param([string]$Path)
    & icacls $Path /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' *> $null
    if ($LASTEXITCODE -ne 0) { throw "could not restrict permissions on $Path" }
}

# Encrypts a secret with gpg (symmetric AES256) using the host key as passphrase
function Protect-Secret {
    param([string]$Secret, [string]$KeyFile, [string]$OutFile)
    $prevEnc = $OutputEncoding
    $OutputEncoding = New-Object Text.UTF8Encoding($false)
    try {
        $Secret | & gpg --batch --pinentry-mode loopback --symmetric --cipher-algo AES256 `
                        --passphrase-file $KeyFile -o $OutFile
        if ($LASTEXITCODE -ne 0) { throw "gpg failed to encrypt $OutFile (exit $LASTEXITCODE)" }
    }
    finally { $OutputEncoding = $prevEnc }
    Protect-File $OutFile
}

# ---- Messages ----
$errDockerNotFound = @"

Docker is not installed, please install Docker Desktop.

DockerDoc: https://docs.docker.com/desktop/setup/install/windows-install/
"@

$errDockerNotRunning = @"

Docker is installed but the daemon is not running (or not reachable).

Start Docker Desktop, wait until it says it is running, and try again.

DockerDoc: https://docs.docker.com/desktop/
"@

$errDockerPermission = @"

Docker is running, but you don't have permission to access it.

Add your user to the 'docker-users' group (Computer Management > Local Users and Groups), then sign out and back in.

DockerDoc: https://docs.docker.com/desktop/setup/install/windows-install/
"@

# ---- Parse arguments ----
$dev = $false
foreach ($a in $args) {
    if ($a -ceq '--dev') { $dev = $true }
    else { Die "unknown option: $a (supported: --dev)" 2 }
}

# ---- Admin check ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
               IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Die "this script must be run as administrator (it writes to $env:ProgramData). Run it via the main script or from an elevated PowerShell."
}

# ---- Paths ----
$dataDir    = Join-Path $env:ProgramData 'riskybit'
$envFile    = Join-Path $dataDir 'docker-app.env'
$dbPassFile = Join-Path $dataDir 'docker-password.gpg'
$adminFile  = Join-Path $dataDir 'admin-password.gpg'
$keyFile    = Join-Path $dataDir 'host.key'

# ---- Docker ----
$script:step = "checking Docker"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine($errDockerNotFound)
    exit 1
}
$info = Test-Native { docker info }
if (-not $info.Ok) {
    if ($info.Output -match 'permission denied|access is denied') {
        [Console]::Error.WriteLine($errDockerPermission)
    }
    else {
        [Console]::Error.WriteLine($errDockerNotRunning)
    }
    exit 1
}

# ---- Pre-flight checks ----
$script:step = "running pre-flight checks"
foreach ($cmd in 'git', 'gpg') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Die "required command not found: $cmd"
    }
}
if (-not (Test-Native { docker compose version }).Ok) {
    Die "the 'docker compose' plugin is not available. Install Docker Compose v2."
}
if (-not (Test-Native { git rev-parse --is-inside-work-tree }).Ok) {
    Die "'$((Get-Location).Path)' is not inside a git repository. Run setup from the project directory."
}
if ([Console]::IsInputRedirected) {
    Die "an interactive terminal is required (setup prompts for admin credentials)."
}
foreach ($f in $adminFile, $dbPassFile) {
    if (Test-Path -LiteralPath $f) {
        Die "$f already exists and gpg will not overwrite it. Remove it (or run the remove command) and re-run setup."
    }
}

# ---- Git ----
$script:step = "pulling Github commits"
Write-Host "Pulling last Github commits..."
Invoke-Native git @('fetch') | Out-Null
Invoke-Native git @('pull')  | Out-Null

if ($dev) {
    $script:step = "updating git submodules"
    Write-Host "Pulling git submodules..."
    Invoke-Native git @('submodule', 'update', '--init', '--recursive') | Out-Null
}

# ---- Config files: CRLF -> LF (text files only) ----
$script:step = "preparing config files"
if (-not (Test-Path -LiteralPath 'config' -PathType Container)) {
    Die "config directory not found in '$((Get-Location).Path)'."
}
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
$script:step = "getting docker images"
Write-Host "Getting docker images..."
if ($dev) { 
    Invoke-Live docker @('compose', 'build') 
    Invoke-Live docker @('compose', 'pull', 'traefik', 'db', 'ollama')
}
else { 
    Invoke-Live docker @('compose', 'pull') 
}

# ---- Header ----
$width = 80
try { if ($Host.UI.RawUI.WindowSize.Width -gt 0) { $width = $Host.UI.RawUI.WindowSize.Width } } catch {}
$label     = ' Setup '
$fill      = [int][Math]::Floor(($width - $label.Length) / 2)
$padLeft   = '=' * [Math]::Max($fill, 0)
$padRight  = '=' * [Math]::Max($width - $label.Length - $fill - 1, 0)   # -1 avoids wrapping
Write-Output "$padLeft$label$padRight"

# ---- Host key ----
$script:step = "creating the host key"
if (-not (Test-Path -LiteralPath $dataDir -PathType Container)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}
if ((Test-Path -LiteralPath $keyFile) -and (Get-Item -LiteralPath $keyFile).Length -eq 0) {
    [Console]::Error.WriteLine("Warning: removing empty host key file $keyFile from a previous failed run.")
    Remove-Item -LiteralPath $keyFile -Force
}
if (-not (Test-Path -LiteralPath $keyFile -PathType Leaf)) {
    $keyBytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($keyBytes) } finally { $rng.Dispose() }
    [IO.File]::WriteAllText($keyFile, ([Convert]::ToBase64String($keyBytes) + "`n"), [Text.Encoding]::ASCII)
    Protect-File $keyFile
}

# ---- Admin user ----
$script:step = "admin user setup"
Write-Host "--- Admin User Setup ---"
$adminEmail = Read-NonEmpty "Admin Email Address"
$adminPass  = Read-PasswordOrGenerate "Admin Password (press Enter to auto-generate)"
if (-not $adminPass) { Die "admin password is empty (password generation failed)." }
Protect-Secret -Secret $adminPass -KeyFile $keyFile -OutFile $adminFile
$adminPass = $null

# ---- Database ----
$script:step = "database setup"
Write-Host "`n--- Database Setup ---"
$dbPass = Read-PasswordOrGenerate "Database Password (press Enter to auto-generate)"
if (-not $dbPass) { Die "database password is empty (password generation failed)." }
Protect-Secret -Secret $dbPass -KeyFile $keyFile -OutFile $dbPassFile
$dbPass = $null

# ---- Env file ----
$script:step = "writing $envFile"
[IO.File]::WriteAllText($envFile, "ADMIN_EMAIL=$adminEmail`n", (New-Object Text.UTF8Encoding($false)))
Protect-File $envFile

Write-Host "`nProject finished setup."
exit 0
