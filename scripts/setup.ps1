$ErrorActionPreference = 'Stop'
$script:step = "starting up"

trap {
    [Console]::Error.WriteLine("Error: setup failed while $($script:step): $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))")
    exit 1
}

# openssl builds from Git for Windows (MSYS) rewrite args like "/CN=..." into paths; turn that off.
$env:MSYS2_ARG_CONV_EXCL = '*'
$env:MSYS_NO_PATHCONV = '1'

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

# Runs a native command with all output discarded; throws (with the output) on non-zero exit
function Invoke-Quiet {
    param([string]$Exe, [string[]]$Arguments)
    $r = Test-Native { & $Exe @Arguments }.GetNewClosure()
    if (-not $r.Ok) {
        throw "'$Exe $($Arguments -join ' ')' failed: $($r.Output)"
    }
}

# Runs a native command with live output; throws on non-zero exit
function Invoke-Live {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "'$Exe $($Arguments -join ' ')' failed (exit $LASTEXITCODE)"
    }
}

function Write-TextLF {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
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

# 32 random bytes as 64 hex chars (same as `openssl rand -hex 32`)
function New-Secret {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
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

# Restrict a file or directory to Administrators and SYSTEM
function Protect-File {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        & icacls $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' *> $null
    }
    else {
        & icacls $Path /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' *> $null
    }
    if ($LASTEXITCODE -ne 0) { throw "could not restrict permissions on $Path" }
}

# Encrypts text with gpg (symmetric AES256) using the host key as passphrase.
# The text is written to gpg's stdin as raw UTF-8 bytes (no BOM, no CRLF added).
function Protect-Secret {
    param([string]$Text, [string]$KeyFile, [string]$OutFile)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'gpg'
    $psi.Arguments = "--batch --pinentry-mode loopback --symmetric --cipher-algo AES256 --passphrase-file `"$KeyFile`" -o `"$OutFile`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.Close()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { throw "gpg failed to encrypt $OutFile (exit $($proc.ExitCode))" }
    }
    finally { $proc.Dispose() }
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
$dataDir     = Join-Path $env:ProgramData 'riskybit'
$envFile     = Join-Path $dataDir 'docker-app.env'
$secretsFile = Join-Path $dataDir 'riskybit-secrets.gpg'
$keyFile     = Join-Path $dataDir 'host.key'
$caDir       = Join-Path $dataDir 'ca'     # outside the repo and outside the Traefik mount
$certDir     = Join-Path (Get-Location).Path 'config\traefik\certs'
$certDays    = 825

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
foreach ($cmd in 'git', 'openssl', 'gpg') {
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
if (Test-Path -LiteralPath $secretsFile) {
    Die "$secretsFile already exists and gpg will not overwrite it. Remove it (or run the remove command) and re-run setup."
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

# ---- Database ----
$script:step = "database setup"
Write-Host "`n--- Database Setup ---"
$dbPass = Read-PasswordOrGenerate "Database Password (press Enter to auto-generate)"
if (-not $dbPass) { Die "database password is empty (password generation failed)." }

# ---- Domain ----
$script:step = "domain setup"
Write-Host "--- Domain Setup ---"
$domain = Read-Host "Domain to run on [riskybit.at]"
if ([string]::IsNullOrWhiteSpace($domain)) { $domain = 'riskybit.at' }
$domain = $domain.Trim().ToLowerInvariant()
if ($domain -cnotmatch '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$') {
    Die "'$domain' is not a valid domain (use e.g. riskybit.at, without https:// or subdomains)."
}
Write-Host "--> Using domain: $domain (admin.$domain, chat.$domain, app.$domain, api.$domain)"

# ---- TLS certificates ----
$script:step = "TLS certificates"
Write-Host "`n--- TLS Certificates ---"
Write-Host "  1) Generate a private CA and a certificate for $domain (default)"
Write-Host "  2) Use my own certificate (e.g. from an enterprise CA)"
$certMode = Read-Host "Choice [1]"
if ([string]::IsNullOrWhiteSpace($certMode)) { $certMode = '1' }
$certMode = $certMode.Trim()
if ($certMode -ne '1' -and $certMode -ne '2') { Die "invalid choice: $certMode (use 1 or 2)" }
New-Item -ItemType Directory -Path $certDir -Force | Out-Null

if ($certMode -eq '1') {
    # ---- Generate CA (reused if it already exists, so clients keep trusting it) ----
    New-Item -ItemType Directory -Path $caDir -Force | Out-Null
    Protect-File $caDir
    $caKey = Join-Path $caDir 'ca.key'
    $caPem = Join-Path $caDir 'ca.pem'

    $caKeyOk = (Test-Path -LiteralPath $caKey) -and ((Get-Item -LiteralPath $caKey).Length -gt 0)
    $caPemOk = (Test-Path -LiteralPath $caPem) -and ((Get-Item -LiteralPath $caPem).Length -gt 0)
    if ($caKeyOk -and $caPemOk) {
        Write-Host "--> Reusing existing CA in $caDir."
    }
    else {
        Invoke-Quiet openssl @('genrsa', '-out', $caKey, '4096')
        Protect-File $caKey
        # nameConstraints: even if this CA key leaks, it can't be used for other domains.
        Invoke-Quiet openssl @('req', '-x509', '-new', '-sha256', '-key', $caKey, '-days', '3650',
            '-subj', '/CN=RiskyBit Private CA',
            '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0',
            '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
            '-addext', "nameConstraints=critical,permitted;DNS:$domain",
            '-out', $caPem)
        Write-Host "--> Generated new CA (valid 10 years)."
    }

    # ---- Generate server certificate signed by the CA ----
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $extCnf = @"
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
subjectAltName=DNS:$domain,DNS:*.$domain

"@
        $extFile   = Join-Path $tmp 'ext.cnf'
        $srvKey    = Join-Path $tmp 'server.key'
        $srvCsr    = Join-Path $tmp 'server.csr'
        $srvPem    = Join-Path $tmp 'server.pem'
        Write-TextLF $extFile ($extCnf -replace "`r`n", "`n")

        Invoke-Quiet openssl @('genrsa', '-out', $srvKey, '2048')
        Invoke-Quiet openssl @('req', '-new', '-key', $srvKey, '-subj', "/CN=$domain", '-out', $srvCsr)
        Invoke-Quiet openssl @('x509', '-req', '-sha256', '-days', "$certDays", '-in', $srvCsr,
            '-CA', $caPem, '-CAkey', $caKey, '-CAcreateserial',
            '-extfile', $extFile, '-out', $srvPem)

        # full chain: server cert + CA
        $chain = ([IO.File]::ReadAllText($srvPem).TrimEnd() + "`n" + [IO.File]::ReadAllText($caPem).TrimEnd() + "`n") -replace "`r`n", "`n"
        Write-TextLF (Join-Path $certDir 'cert.pem') $chain
        Copy-Item -LiteralPath $srvKey -Destination (Join-Path $certDir 'key.pem') -Force
        Protect-File (Join-Path $certDir 'key.pem')
        Copy-Item -LiteralPath $caPem -Destination (Join-Path $certDir 'ca.pem') -Force   # public CA, to hand to clients
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host "--> Certificate for $domain and *.$domain generated (valid $certDays days)."
    Write-Host "--> Install $(Join-Path $certDir 'ca.pem') as a trusted root on every client that should trust this site."
}
else {
    # ---- Bring your own ----
    $byoCert  = (Read-Host "Path to certificate PEM (leaf, or full chain)").Trim().Trim('"')
    $byoKey   = (Read-Host "Path to private key PEM (must not be passphrase-protected)").Trim().Trim('"')
    $byoChain = (Read-Host "Path to intermediate chain PEM (optional, Enter to skip)").Trim().Trim('"')

    if (-not (Test-Path -LiteralPath $byoCert  -PathType Leaf)) { Die "cannot read certificate: '$byoCert'" }
    if (-not (Test-Path -LiteralPath $byoKey   -PathType Leaf)) { Die "cannot read private key: '$byoKey'" }
    if ($byoChain -and -not (Test-Path -LiteralPath $byoChain -PathType Leaf)) { Die "cannot read chain file: '$byoChain'" }

    if (-not (Test-Native { openssl x509 -in $byoCert -noout }).Ok) {
        Die "'$byoCert' is not a valid PEM certificate (DER/PFX files must be converted first)."
    }
    if (-not (Test-Native { openssl pkey -in $byoKey -passin pass: -noout }).Ok) {
        Die "'$byoKey' is not a valid PEM key, or it is passphrase-protected (Traefik needs it unencrypted)."
    }
    $certPub = (Test-Native { openssl x509 -in $byoCert -noout -pubkey }).Output.Trim()
    $keyPub  = (Test-Native { openssl pkey -in $byoKey -passin pass: -pubout }).Output.Trim()
    if ($certPub -ne $keyPub) { Die "the private key does not match the certificate." }
    if (-not (Test-Native { openssl x509 -in $byoCert -noout -checkend 0 }).Ok) {
        Die "the certificate has already expired."
    }

    $missing = @()
    foreach ($h in @($domain, "admin.$domain", "chat.$domain", "app.$domain", "api.$domain")) {
        $r = Test-Native { openssl x509 -in $byoCert -noout -checkhost $h }.GetNewClosure()
        if ($r.Output -notmatch 'does match') { $missing += $h }
    }
    if ($missing.Count -gt 0) {
        [Console]::Error.WriteLine("Warning: The certificate does not cover: $($missing -join ' ')")
        $ans = Read-Host "Continue anyway? [y/N]"
        if ($ans -notmatch '^[Yy]$') { Die "aborted: certificate does not cover all hostnames." }
    }

    $chain = [IO.File]::ReadAllText($byoCert).TrimEnd() + "`n"
    if ($byoChain) { $chain += [IO.File]::ReadAllText($byoChain).TrimEnd() + "`n" }
    Write-TextLF (Join-Path $certDir 'cert.pem') ($chain -replace "`r`n", "`n")
    Copy-Item -LiteralPath $byoKey -Destination (Join-Path $certDir 'key.pem') -Force
    Protect-File (Join-Path $certDir 'key.pem')

    $endDate = ((Test-Native { openssl x509 -in $byoCert -noout -enddate }).Output -split '=', 2)[1]
    Write-Host "--> Using your certificate (expires: $endDate)."
}

# ---- Secrets ----
$script:step = "storing secrets"
Write-Host "`n--- Secrets ---"
$jwtSecret      = New-Secret
$csrfSecret     = New-Secret
$internalSecret = New-Secret

$secretsText = "ADMIN_PASSWORD=$adminPass`nDB_PASS=$dbPass`nJWT_SECRET=$jwtSecret`nCSRF_SECRET=$csrfSecret`nINTERNAL_SECRET=$internalSecret`n"
Protect-Secret -Text $secretsText -KeyFile $keyFile -OutFile $secretsFile
$secretsText = $null
Write-Host "--> Stored all secrets in $secretsFile."

# ---- Env file ----
$script:step = "writing $envFile"
Write-TextLF $envFile "ADMIN_EMAIL=$adminEmail`nDOMAIN=$domain`n"
Protect-File $envFile

# ---- Git ----
$script:step = "pulling Github commits"
Write-Host "Pulling last Github commits..."
Invoke-Native git @('fetch') | Out-Null
Invoke-Native git @('pull')  | Out-Null

if ($dev) {
    $script:step = "updating git submodules"
    Write-Host "Pulling git submodules..."
    Invoke-Native git @('submodule', 'update', '--init', '--recursive', '--remote') | Out-Null
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
$env:ADMIN_EMAIL     = $adminEmail
$env:ADMIN_PASSWORD  = $adminPass
$env:DOMAIN          = $domain
$env:DB_PASS         = $dbPass
$env:JWT_SECRET      = $jwtSecret
$env:CSRF_SECRET     = $csrfSecret
$env:INTERNAL_SECRET = $internalSecret
try {
    if ($dev) {
        Invoke-Live docker @('compose', 'build')
        Invoke-Live docker @('compose', 'pull', 'traefik', 'db', 'ollama')
    }
    else {
        Invoke-Live docker @('compose', 'pull')
    }
}
finally {
    foreach ($v in 'ADMIN_EMAIL', 'ADMIN_PASSWORD', 'DOMAIN', 'DB_PASS', 'JWT_SECRET', 'CSRF_SECRET', 'INTERNAL_SECRET') {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
    $adminPass = $dbPass = $jwtSecret = $csrfSecret = $internalSecret = $null
}

Write-Host "`nProject finished setup."
exit 0
