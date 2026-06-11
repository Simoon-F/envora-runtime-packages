#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds PHP for Windows using MSVC and the PHP SDK binary tools.
.DESCRIPTION
    Downloads PHP source, fetches pre-built Windows deps via the PHP SDK,
    configures with MSVC, and compiles PHP with common extensions.

    The finished build is installed to C:\php-package\<version> so the
    companion packaging script can bundle it into a release archive.
.PARAMETER Version
    PHP version to build, e.g. "8.4.8".
.EXAMPLE
    .\build-php-windows.ps1 -Version 8.4.8
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -------------------------------------------------------------------
# Paths
# -------------------------------------------------------------------
$WorkDir        = "C:\php-build-tmp"
$SdkDir         = "$WorkDir\php-sdk-binary-tools"
$BuildDir       = "$WorkDir\php-$Version"
$SourceDir      = "$BuildDir\php-src"
$DepsDir        = "$BuildDir\deps"
$InstallDir     = "C:\php-package\$Version"

# Derive the deps series name from the PHP version (e.g. "8.4.8" -> "PHP-8.4")
$VersionParts   = $Version -split '\.'
$DepsBranch     = "PHP-$($VersionParts[0]).$($VersionParts[1])"

Write-Host "============================================"
Write-Host " Building PHP $Version for Windows (x64)"
Write-Host "============================================"

# -------------------------------------------------------------------
# Clean & create directories
# -------------------------------------------------------------------
Remove-Item -Recurse -Force $WorkDir      -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force C:\php-package -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $WorkDir, $InstallDir | Out-Null

# -------------------------------------------------------------------
# 1.  Clone PHP SDK binary tools
# -------------------------------------------------------------------
Write-Host "[1/6] Cloning PHP SDK binary tools..."
git clone --depth 1 https://github.com/php/php-sdk-binary-tools.git $SdkDir 2>&1 | Out-Null
if (-not (Test-Path "$SdkDir\bin\phpsdk_deps")) {
    throw "PHP SDK binary tools clone appears incomplete — missing bin/phpsdk_deps"
}

# -------------------------------------------------------------------
# 2.  Install Python dependencies for the SDK scripts
# -------------------------------------------------------------------
Write-Host "[2/6] Installing Python dependencies..."
pip install requests --quiet 2>&1 | Out-Null

# -------------------------------------------------------------------
# 3.  Download PHP source
# -------------------------------------------------------------------
Write-Host "[3/6] Downloading PHP $Version source..."
$PhpUrl     = "https://www.php.net/distributions/php-$Version.tar.gz"
$PhpArchive = "$WorkDir\php-$Version.tar.gz"

Invoke-WebRequest -Uri $PhpUrl -OutFile $PhpArchive
tar -xzf $PhpArchive -C $BuildDir
Rename-Item "$BuildDir\php-$Version" $SourceDir

# -------------------------------------------------------------------
# 4.  Download pre-built Windows library dependencies
# -------------------------------------------------------------------
Write-Host "[4/6] Downloading dependencies (series: $DepsBranch)..."
New-Item -ItemType Directory -Force -Path $DepsDir | Out-Null

python "$SdkDir\bin\phpsdk_deps" --update --branch $DepsBranch --deps $DepsDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Primary deps series failed — falling back to 'master'..."
    python "$SdkDir\bin\phpsdk_deps" --update --branch master --deps $DepsDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download PHP library dependencies"
    }
}

# -------------------------------------------------------------------
# 5.  Locate Visual Studio and enter the MSVC developer shell
# -------------------------------------------------------------------
Write-Host "[5/6] Setting up MSVC environment..."

$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vsWhere)) {
    $vsWhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
}
$vsPath = & $vsWhere -latest -products * -property installationPath
if (-not $vsPath) {
    throw "Visual Studio installation not found via vswhere"
}
Write-Host "  Visual Studio: $vsPath"

$devShellDll = "$vsPath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
if (Test-Path $devShellDll) {
    Import-Module $devShellDll
    Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=amd64"
} else {
    Write-Host "  DevShell module not found — sourcing vcvars64.bat instead..."
    $vcvarsBat = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path $vcvarsBat)) {
        throw "Neither DevShell module nor vcvars64.bat found"
    }
    # Capture environment changes from the batch file into this PowerShell session
    $batOutput = & cmd /c "`"$vcvarsBat`" > nul 2>&1 && set"
    foreach ($line in $batOutput) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

# -------------------------------------------------------------------
# 5b. Ensure build tools (bison, re2c) are on PATH
# -------------------------------------------------------------------
$env:PATH = "$SdkDir\bin;$env:PATH"

# Walk the deps directory for any bin/ folders and add them
$depsBinDirs = @(Get-ChildItem -Path $DepsDir -Recurse -Directory -Filter "bin" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName)
foreach ($dir in $depsBinDirs) {
    $env:PATH = "$dir;$env:PATH"
}

# If bison or re2c are still missing, install via Chocolatey as a fallback
if (-not (Get-Command bison -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing bison via Chocolatey..."
    choco install -y winflexbison3 --no-progress --limit-output 2>&1 | Out-Null
    # Refresh PATH after choco
    $env:PATH = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("PATH", "User")
}
if (-not (Get-Command re2c -ErrorAction SilentlyContinue)) {
    Write-Host "  Installing re2c via Chocolatey..."
    choco install -y re2c --no-progress --limit-output 2>&1 | Out-Null
    $env:PATH = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("PATH", "User")
}

Write-Host "  bison:  $(Get-Command bison  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)"
Write-Host "  re2c:   $(Get-Command re2c   -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)"
Write-Host "  cl.exe: $(Get-Command cl.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)"

# -------------------------------------------------------------------
# 6.  Build PHP
# -------------------------------------------------------------------
Write-Host "[6/6] Building PHP..."
Push-Location $SourceDir

try {
    Write-Host "  -> buildconf"
    .\buildconf
    if ($LASTEXITCODE -ne 0) { throw "buildconf failed" }

    Write-Host "  -> configure"
    $configureArgs = @(
        "--prefix=$InstallDir",
        "--with-config-file-path=$InstallDir",
        "--with-config-file-scan-dir=$InstallDir\conf.d",
        "--with-openssl",
        "--with-curl",
        "--enable-mbstring",
        "--enable-bcmath=shared",
        "--enable-calendar=shared",
        "--enable-exif=shared",
        "--enable-ftp=shared",
        "--enable-gd=shared",
        "--with-jpeg",
        "--with-freetype",
        "--enable-intl=shared",
        "--enable-soap=shared",
        "--enable-sockets=shared",
        "--with-sodium=shared",
        "--with-xsl=shared",
        "--with-zip=shared",
        "--enable-fpm",
        "--with-pdo-mysql=mysqlnd",
        "--with-mysqli=mysqlnd",
        "--with-libxml",
        "--enable-opcache=shared",
        "--with-bz2=shared",
        "--with-ffi=shared",
        "--with-gettext=shared"
    )
    .\configure @configureArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "--- configure.js.log (tail) ---"
        Get-Content "$SourceDir\configure.js.log" -ErrorAction SilentlyContinue |
            Select-Object -Last 60 | Write-Host
        throw "configure failed"
    }

    Write-Host "  -> nmake"
    nmake
    if ($LASTEXITCODE -ne 0) { throw "nmake failed" }

    Write-Host "  -> nmake install"
    nmake install
    if ($LASTEXITCODE -ne 0) { throw "nmake install failed" }

    Write-Host ""
    Write-Host "Build complete — PHP $Version installed to $InstallDir"
} finally {
    Pop-Location
}
