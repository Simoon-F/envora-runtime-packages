#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Packages a pre-built PHP Windows installation into a release .zip archive.
.DESCRIPTION
    Copies runtime executables, extension DLLs, and third-party dependency DLLs
    into a self-contained layout.  Unresolved DLL references are reported so the
    caller can decide whether to add more libraries to the bundle.

    The output archive is written to C:\php-package alongside a .sha256
    checksum file.
.PARAMETER Version
    PHP version being packaged, e.g. "8.4.8".
.PARAMETER Arch
    Target architecture, e.g. "x64".
.EXAMPLE
    .\package-windows-runtime.ps1 -Version 8.4.8 -Arch x64
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$Arch
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -------------------------------------------------------------------
# Paths
# -------------------------------------------------------------------
$RepoRoot     = "$PSScriptRoot\..\.."
$PackageRoot  = "C:\php-package"
$InstallDir   = "$PackageRoot\$Version"
$DepsDir      = "C:\php-build-tmp\php-$Version\deps"
$OutputZip    = "$PackageRoot\php-$Version-windows-$Arch.zip"
$OutputSha    = "$OutputZip.sha256"

# Package layout (flat, matching PHP's Windows convention)
$PkgDir        = "$PackageRoot\php-$Version-windows-$Arch"
$PkgExtDir     = "$PkgDir\ext"
$PkgLibDir     = "$PkgDir\lib"
$PkgConfDir    = "$PkgDir\conf.d"
$PkgVarRunDir  = "$PkgDir\var\run"
$PkgVarLogDir  = "$PkgDir\var\log"

Write-Host "============================================"
Write-Host " Packaging PHP $Version for Windows $Arch"
Write-Host "============================================"

# -------------------------------------------------------------------
# Create package layout
# -------------------------------------------------------------------
Remove-Item -Recurse -Force $PkgDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $PkgDir, $PkgExtDir, $PkgLibDir, $PkgConfDir,
                                            $PkgVarRunDir, $PkgVarLogDir | Out-Null

# -------------------------------------------------------------------
# 1.  Copy runtime executables
# -------------------------------------------------------------------
Write-Host "[1/5] Copying runtime executables..."

$runtimeExes = @()
foreach ($name in @("php.exe", "php-cgi.exe", "php-fpm.exe")) {
    $src = "$InstallDir\$name"
    if (Test-Path $src) {
        Copy-Item $src $PkgDir
        $runtimeExes += "$PkgDir\$name"
        Write-Host "  Copied $name"
    } else {
        Write-Host "  WARNING: $name not found at $src"
    }
}

if ($runtimeExes.Count -eq 0) {
    throw "No PHP runtime executables found in $InstallDir"
}

# -------------------------------------------------------------------
# 2.  Copy extension DLLs
# -------------------------------------------------------------------
Write-Host "[2/5] Copying extension DLLs..."

$extSrcDir = "$InstallDir\ext"
if (Test-Path $extSrcDir) {
    $extDlls = Get-ChildItem -Path $extSrcDir -Filter "*.dll" -File
    foreach ($dll in $extDlls) {
        Copy-Item $dll.FullName $PkgExtDir
    }
    Write-Host "  Copied $($extDlls.Count) extension DLLs"
} else {
    Write-Host "  WARNING: Extension directory not found at $extSrcDir"
}

# Also look for extensions in other possible locations
$altExtDirs = @(
    "$InstallDir\lib\php\extensions"
)
foreach ($altDir in $altExtDirs) {
    if ((Test-Path $altDir) -and (Get-ChildItem -Path $altDir -Filter "*.dll" -File)) {
        $altDlls = Get-ChildItem -Path $altDir -Filter "*.dll" -File -Recurse
        foreach ($dll in $altDlls) {
            Copy-Item $dll.FullName $PkgExtDir
        }
        Write-Host "  Copied $($altDlls.Count) additional DLLs from $altDir"
    }
}

# -------------------------------------------------------------------
# 3.  Bundle third-party dependency DLLs
# -------------------------------------------------------------------
Write-Host "[3/5] Bundling dependency DLLs..."

# System DLLs we should never bundle — these come from Windows or the
# MSVC redistributable.
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

function Test-IsSystemDll {
    param([string]$DllName)
    foreach ($pattern in $systemDllPatterns) {
        if ($DllName -match $pattern) { return $true }
    }
    return $false
}

function Get-DllDependencies {
    param([string]$FilePath)
    $deps = @()
    $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
    if (-not $dumpbin) { return $deps }

    $output = & dumpbin /dependents $FilePath 2>$null | Out-String
    $inDeps = $false
    foreach ($line in ($output -split "`r`n")) {
        if ($line -match '^\s*Image has the following dependencies') {
            $inDeps = $true
            continue
        }
        if ($inDeps) {
            if ($line -match '^\s*$') { break }
            if ($line -match '^\s*([^\s].+\.dll)') {
                $deps += $Matches[1].Trim().ToLower()
            }
        }
    }
    return $deps
}

# Collect all files that might need dependency resolution
$scanFiles = @($runtimeExes)
$scanFiles += Get-ChildItem -Path $PkgExtDir -Filter "*.dll" -File | Select-Object -ExpandProperty FullName

# Build a set of DLL names we've already bundled
$bundledDlls = @{}
foreach ($file in $scanFiles) {
    $bundledDlls[(Split-Path $file -Leaf).ToLower()] = $true
}

# Iteratively resolve and copy non-system dependencies
$maxPasses = 10
for ($pass = 0; $pass -lt $maxPasses; $pass++) {
    $foundNew = $false
    $currentFiles = @($runtimeExes)
    $currentFiles += Get-ChildItem -Path $PkgExtDir -Filter "*.dll" -File | Select-Object -ExpandProperty FullName
    $currentFiles += Get-ChildItem -Path $PkgLibDir  -Filter "*.dll" -File | Select-Object -ExpandProperty FullName

    foreach ($file in $currentFiles) {
        $needed = Get-DllDependencies $file
        foreach ($dep in $needed) {
            if (Test-IsSystemDll $dep) { continue }
            if ($bundledDlls.ContainsKey($dep)) { continue }

            # Search for this DLL in the deps directory and install directory
            $found = $null
            $searchDirs = @(
                $DepsDir,
                $InstallDir,
                "C:\php-build-tmp\php-$Version"
            )
            foreach ($dir in $searchDirs) {
                if (-not (Test-Path $dir)) { continue }
                $candidate = Get-ChildItem -Path $dir -Recurse -Filter $dep -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($candidate) {
                    $found = $candidate.FullName
                    break
                }
            }

            if ($found) {
                Copy-Item $found $PkgLibDir
                $bundledDlls[$dep] = $true
                $foundNew = $true
                Write-Host "  Bundled $dep"
            } else {
                Write-Host "  WARNING: Could not locate $dep"
            }
        }
    }

    if (-not $foundNew) { break }
}

# -------------------------------------------------------------------
# 4.  Copy php.ini template
# -------------------------------------------------------------------
Write-Host "[4/5] Copying configuration..."

$windowsIni = "$RepoRoot\assets\php.ini.default.windows"
$fallbackIni = "$RepoRoot\assets\php.ini.default"

if (Test-Path $windowsIni) {
    Copy-Item $windowsIni "$PkgDir\php.ini"
} elseif (Test-Path $fallbackIni) {
    Copy-Item $fallbackIni "$PkgDir\php.ini"
}

# Also ship the stock ini files if present
foreach ($ini in @("php.ini-development", "php.ini-production")) {
    $src = "$InstallDir\$ini"
    if (Test-Path $src) {
        Copy-Item $src $PkgDir
    }
}

# -------------------------------------------------------------------
# 5.  Create zip archive and checksum
# -------------------------------------------------------------------
Write-Host "[5/5] Creating archive..."

# Ensure we're in the parent directory so the archive has a clean root folder
Push-Location $PackageRoot
try {
    $zipName = "php-$Version-windows-$Arch.zip"
    if (Test-Path $zipName) { Remove-Item $zipName }

    Compress-Archive -Path "php-$Version-windows-$Arch" -DestinationPath $zipName

    $hash = (Get-FileHash -Path $zipName -Algorithm SHA256).Hash.ToLower()
    "$hash  $zipName" | Out-File -FilePath "$zipName.sha256" -Encoding ascii

    $zipSize = [math]::Round((Get-Item $zipName).Length / 1MB, 2)
    Write-Host ""
    Write-Host "Archive:  $OutputZip ($zipSize MB)"
    Write-Host "SHA256:   $hash"
} finally {
    Pop-Location
}
