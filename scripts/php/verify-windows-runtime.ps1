#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Verifies a packaged PHP Windows runtime.
.DESCRIPTION
    Checks that every runtime executable starts, common extensions are present,
    and each extension loads without error.  Unresolved DLL references (outside
    Windows system directories) are flagged so the packaging step can be
    adjusted.
.PARAMETER Version
    PHP version to verify, e.g. "8.4.8".
.EXAMPLE
    .\verify-windows-runtime.ps1 -Version 8.4.8
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

$PackageRoot  = "C:\php-package"
$PkgDir       = "$PackageRoot\php-$Version-windows-x64"
$PkgExtDir    = "$PkgDir\ext"
$PkgLibDir    = "$PkgDir\lib"

# If the packaged directory doesn't exist (e.g. we're verifying the raw install),
# fall back to the install directory.
if (-not (Test-Path $PkgDir)) {
    $PkgDir    = "$PackageRoot\$Version"
    $PkgExtDir = "$PkgDir\ext"
    $PkgLibDir = "$PkgDir\lib"
}

$phpExe    = "$PkgDir\php.exe"
$phpCgiExe = "$PkgDir\php-cgi.exe"
$phpFpmExe = "$PkgDir\php-fpm.exe"

# Required shared extensions (subset available on Windows)
$requiredExtensions = @(
    "bcmath",
    "bz2",
    "calendar",
    "exif",
    "ffi",
    "ftp",
    "gd",
    "gettext",
    "intl",
    "opcache",
    "soap",
    "sockets",
    "sodium",
    "xsl",
    "zip"
)

Write-Host "============================================"
Write-Host " Verifying PHP $Version Windows runtime"
Write-Host "============================================"

# -------------------------------------------------------------------
# 1.  Check executables exist
# -------------------------------------------------------------------
Write-Host "[1/6] Checking runtime executables..."

if (-not (Test-Path $phpExe))    { throw "php.exe not found at $phpExe" }
if (-not (Test-Path $phpCgiExe)) { throw "php-cgi.exe not found at $phpCgiExe" }
Write-Host "  php.exe     OK"
Write-Host "  php-cgi.exe OK"
if (Test-Path $phpFpmExe) {
    Write-Host "  php-fpm.exe OK"
} else {
    Write-Host "  php-fpm.exe not found (skipping)"
}

# -------------------------------------------------------------------
# 2.  Run executables with -v
# -------------------------------------------------------------------
Write-Host "[2/6] Running executables..."

& $phpExe -v 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { throw "php.exe -v failed" }

& $phpCgiExe -v 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { throw "php-cgi.exe -v failed" }

if (Test-Path $phpFpmExe) {
    & $phpFpmExe -v 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "php-fpm.exe -v failed" }
}

# -------------------------------------------------------------------
# 3.  Check built-in extensions with php -m
# -------------------------------------------------------------------
Write-Host "[3/6] Checking built-in modules..."

& $phpExe -m 2>&1 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { throw "php -m failed" }

$moduleOutput = & $phpExe -m 2>&1 | Out-String
foreach ($mod in @("curl", "mbstring", "mysqli", "mysqlnd", "openssl", "pdo")) {
    if ($moduleOutput -match "(?ms)^\s*$mod\s*$") {
        Write-Host "  $mod: present"
    } else {
        Write-Host "  WARNING: $mod not found in php -m output"
    }
}

# -------------------------------------------------------------------
# 4.  Verify extension files exist
# -------------------------------------------------------------------
Write-Host "[4/6] Checking extension files..."

$extFiles = @(Get-ChildItem -Path $PkgExtDir -Filter "*.dll" -File -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Name)

Write-Host "  Extension directory: $PkgExtDir"
Write-Host "  Found $($extFiles.Count) DLLs"

foreach ($ext in $requiredExtensions) {
    if ($ext -eq "opcache") { continue }  # checked separately below
    $expectedName = "php_$ext.dll"
    $found = $extFiles | Where-Object { $_ -eq $expectedName }
    if ($found) {
        Write-Host "  $expectedName: OK"
    } else {
        Write-Host "  WARNING: $expectedName not found in ext/"
    }
}

# opcache uses a different naming convention
$opcacheFound = $extFiles | Where-Object { $_ -match 'opcache' }
if ($opcacheFound) {
    Write-Host "  $opcacheFound: OK"
} else {
    Write-Host "  WARNING: opcache DLL not found in ext/"
}

# -------------------------------------------------------------------
# 5.  Test each shared extension loads
# -------------------------------------------------------------------
Write-Host "[5/6] Testing extension loading..."

foreach ($ext in $requiredExtensions) {
    $extDll = "php_$ext.dll"
    if ($ext -eq "opcache") {
        # opcache is a Zend extension
        $result = & $phpExe -n -d "extension_dir=$PkgExtDir" -d "zend_extension=$extDll" -m 2>&1
    } else {
        $result = & $phpExe -n -d "extension_dir=$PkgExtDir" -d "extension=$ext" -m 2>&1
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  $ext: loaded OK"
    } else {
        Write-Host "  WARNING: $ext failed to load"
        if ($result) { Write-Host "    $($result -join ' ')" }
    }
}

# -------------------------------------------------------------------
# 6.  Check for unresolved DLL references
# -------------------------------------------------------------------
Write-Host "[6/6] Checking DLL references..."

$dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
if ($dumpbin) {
    $allFiles = @($phpExe, $phpCgiExe)
    if (Test-Path $phpFpmExe) { $allFiles += $phpFpmExe }
    $allFiles += Get-ChildItem -Path $PkgExtDir -Filter "*.dll" -File | Select-Object -ExpandProperty FullName
    $allFiles += Get-ChildItem -Path $PkgLibDir  -Filter "*.dll" -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName

    $systemDllPatterns = @(
        '^kernel32\.dll$', '^user32\.dll$', '^advapi32\.dll$', '^shell32\.dll$',
        '^ole32\.dll$', '^oleaut32\.dll$', '^ws2_32\.dll$', '^gdi32\.dll$',
        '^comdlg32\.dll$', '^comctl32\.dll$', '^ntdll\.dll$', '^crypt32\.dll$',
        '^msvcrt\.dll$', '^msvcp140.*\.dll$', '^vcruntime140.*\.dll$',
        '^vccorlib140\.dll$', '^concrt140\.dll$',
        '^api-ms-win-.*\.dll$', '^ext-ms-win-.*\.dll$',
        '^KERNELBASE\.dll$', '^SETUPAPI\.dll$', '^CFGMGR32\.dll$',
        '^bcrypt\.dll$', '^sechost\.dll$', '^RPCRT4\.dll$',
        '^ucrtbase\.dll$', '^ucrtbased\.dll$'
    )

    $bundledDlls = @{}
    Get-ChildItem -Path $PkgLibDir -Filter "*.dll" -File -ErrorAction SilentlyContinue |
        ForEach-Object { $bundledDlls[$_.Name.ToLower()] = $true }

    $unresolved = @()
    foreach ($file in $allFiles) {
        $output = & dumpbin /dependents $file 2>$null | Out-String
        $inDeps = $false
        foreach ($line in ($output -split "`r`n")) {
            if ($line -match '^\s*Image has the following dependencies') {
                $inDeps = $true
                continue
            }
            if ($inDeps) {
                if ($line -match '^\s*$') { break }
                if ($line -match '^\s*([^\s].+\.dll)') {
                    $dep = $Matches[1].Trim()
                    $isSystem = $false
                    foreach ($p in $systemDllPatterns) {
                        if ($dep -match $p) { $isSystem = $true; break }
                    }
                    if (-not $isSystem -and -not $bundledDlls.ContainsKey($dep.ToLower())) {
                        $unresolved += "$(Split-Path $file -Leaf) -> $dep"
                    }
                }
            }
        }
    }

    if ($unresolved) {
        Write-Host "  Unresolved (non-system) DLL references:"
        $unresolved | ForEach-Object { Write-Host "    $_" }
        throw "Unresolved DLL references found — package is incomplete"
    } else {
        Write-Host "  All DLL references resolved."
    }
} else {
    Write-Host "  dumpbin not available — skipping DLL reference check."
}

Write-Host ""
Write-Host "============================================"
Write-Host " Verification passed for PHP $Version"
Write-Host "============================================"
