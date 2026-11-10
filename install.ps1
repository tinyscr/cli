<#
.SYNOPSIS
  Installs the tinyscr cli tools by compiling them from source on this machine.

.DESCRIPTION
  Downloads the tool sources from the repository, compiles the selected tools
  with the C# compiler that ships with Windows, and installs the resulting
  executables into the install directory.

  Nothing is installed system wide. The compiler is part of Windows, so no
  runtime, no package manager and no Visual Studio are required.

  Running the script again rebuilds only the tools whose sources changed.

.PARAMETER InstallDir
  Where to install. Defaults to the current directory.

.PARAMETER SourceDir
  Compile from a local checkout instead of downloading. Used for testing.

.PARAMETER All
  Install every tool without asking.

.PARAMETER Force
  Recompile even when the sources have not changed.

.EXAMPLE
  iwr https://raw.githubusercontent.com/tinyscr/cli/main/install.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [string]$SourceDir = '',
    [switch]$All,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$RepoArchive = 'https://github.com/tinyscr/cli/archive/refs/heads/main.zip'

function Write-Step($Message) { Write-Host $Message }
function Write-Info($Message) { Write-Host $Message -ForegroundColor DarkGray }
function Write-Good($Message) { Write-Host $Message -ForegroundColor Green }
function Write-Bad($Message) { Write-Host $Message -ForegroundColor Red }

function Find-Csc {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-ToolFiles($Tool) {
    if ($Tool.IsDir) {
        return @(Get-ChildItem -LiteralPath $Tool.Path -Filter '*.cs' -Recurse -File | Sort-Object FullName)
    }
    return @(Get-Item -LiteralPath $Tool.Path)
}

function Get-SourceHash($Tool, $Root) {
    $builder = New-Object System.Text.StringBuilder
    foreach ($file in (Get-ToolFiles $Tool)) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
        # Line endings are normalised because a git checkout and the repository
        # archive disagree on them, and the compiler does not care.
        $content = [System.IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
        $fileHash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($content))).Replace('-', '')
        [void]$builder.Append($relative).Append('|').Append($fileHash).Append("`n")
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
}

function Select-Tools($Tools) {
    if ($All) { return $Tools }

    Write-Step ''
    Write-Step 'Available tools:'
    for ($i = 0; $i -lt $Tools.Count; $i++) {
        Write-Host ('  {0}. {1}' -f ($i + 1), $Tools[$i].Name)
    }
    Write-Step ''
    Write-Host 'Enter the numbers to install, one after another (24 installs 2 and 4).'
    Write-Host 'Enter 0 to install everything.'
    Write-Step ''

    $answer = Read-Host 'Selection'
    if ([string]::IsNullOrWhiteSpace($answer)) { return @() }

    $answer = $answer.Trim()
    if ($answer -eq '0') { return $Tools }

    $indexes = @()
    foreach ($part in ($answer -split '[\s,]+')) {
        if ($part -eq '') { continue }
        if ($part -eq '0') { return $Tools }
        if ($part -notmatch '^\d+$') {
            Write-Bad "Not a number: $part"
            return @()
        }
        foreach ($digit in $part.ToCharArray()) {
            $indexes += [int]::Parse([string]$digit)
        }
    }

    $selected = @()
    foreach ($index in ($indexes | Sort-Object -Unique)) {
        if ($index -lt 1 -or $index -gt $Tools.Count) {
            Write-Bad "No such tool: $index"
            return @()
        }
        $selected += $Tools[$index - 1]
    }
    return $selected
}

function Install-ConfigFiles($SourceRoot, $ConfDir) {
    $sourceConf = Join-Path $SourceRoot 'conf'
    if (-not (Test-Path -LiteralPath $sourceConf)) { return }

    foreach ($file in (Get-ChildItem -LiteralPath $sourceConf -Recurse -File)) {
        $relative = $file.FullName.Substring($sourceConf.Length).TrimStart('\', '/')
        $target = Join-Path $ConfDir $relative
        if (Test-Path -LiteralPath $target) {
            Write-Info "  config kept   $relative"
            continue
        }
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $target
        Write-Good "  config added  $relative"
    }
}

function Invoke-Install {
    $tempDir = $null
    try {
        $csc = Find-Csc
        if (-not $csc) {
            Write-Bad 'The C# compiler was not found.'
            Write-Bad 'It ships with Windows 10 and later, under Microsoft.NET\Framework64\v4.0.30319.'
            return 1
        }

        if (-not $InstallDir) { $InstallDir = (Get-Location).Path }
        $InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
        $BinDir = Join-Path $InstallDir 'bin'
        $ConfDir = Join-Path $InstallDir 'conf'
        $StateDir = Join-Path $InstallDir '.state'

        if ($SourceDir) {
            $SourceRoot = [System.IO.Path]::GetFullPath($SourceDir)
            Write-Info "Using local sources: $SourceRoot"
        }
        else {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('tinyscr-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
            $archive = Join-Path $tempDir 'repo.zip'
            Write-Step 'Downloading sources...'
            try {
                (New-Object System.Net.WebClient).DownloadFile($RepoArchive, $archive)
            }
            catch {
                Write-Bad "Could not download the sources: $($_.Exception.Message)"
                return 1
            }
            $extractDir = Join-Path $tempDir 'src'
            Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force
            $SourceRoot = (Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1).FullName
        }

        $srcDir = Join-Path $SourceRoot 'src'
        if (-not (Test-Path -LiteralPath $srcDir)) {
            Write-Bad "No src directory found in $SourceRoot"
            return 1
        }

        $tools = @()
        foreach ($entry in (Get-ChildItem -LiteralPath $srcDir | Sort-Object Name)) {
            if ($entry.PSIsContainer) {
                if (Get-ChildItem -LiteralPath $entry.FullName -Filter '*.cs' -Recurse -File) {
                    $tools += [pscustomobject]@{ Name = $entry.Name; Path = $entry.FullName; IsDir = $true }
                }
            }
            elseif ($entry.Extension -eq '.cs') {
                $tools += [pscustomobject]@{ Name = $entry.BaseName; Path = $entry.FullName; IsDir = $false }
            }
        }
        if ($tools.Count -eq 0) {
            Write-Bad 'No tools found in the sources.'
            return 1
        }

        $selected = Select-Tools $tools
        if ($selected.Count -eq 0) {
            Write-Step 'Nothing selected.'
            return 0
        }

        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
        New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

        $built = 0
        $skipped = 0
        $failed = 0

        foreach ($tool in $selected) {
            $exe = Join-Path $BinDir ($tool.Name + '.exe')
            $marker = Join-Path $StateDir ($tool.Name + '.hash')
            $sourceHash = Get-SourceHash $tool $SourceRoot

            $installedHash = $null
            if (Test-Path -LiteralPath $marker) {
                $installedHash = (Get-Content -LiteralPath $marker -Raw).Trim()
            }

            if (-not $Force -and $installedHash -and $installedHash -eq $sourceHash -and (Test-Path -LiteralPath $exe)) {
                Write-Info ('  up to date   {0}' -f $tool.Name)
                $skipped++
                continue
            }

            Write-Step ('Building {0}...' -f $tool.Name)
            $sources = @(Get-ToolFiles $tool | ForEach-Object { $_.FullName })
            $arguments = @(
                '/nologo',
                '/optimize+',
                '/target:exe',
                '/define:WINDOWS',
                '/reference:System.Windows.Forms.dll',
                ('/out:' + $exe)
            ) + $sources

            $output = & $csc @arguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Bad ('Failed to build {0}:' -f $tool.Name)
                $output | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor Red }
                $failed++
                continue
            }
            if ($output) { $output | ForEach-Object { Write-Info ('  ' + $_) } }

            Set-Content -LiteralPath $marker -Value $sourceHash -NoNewline
            Write-Good ('  installed    {0}' -f $tool.Name)
            $built++
        }

        Install-ConfigFiles $SourceRoot $ConfDir

        Write-Step ''
        Write-Step ('Installed {0}, up to date {1}, failed {2}.' -f $built, $skipped, $failed)
        Write-Step ('Executables: {0}' -f $BinDir)
        Write-Step 'Add it to your PATH:'
        Write-Host ('  setx PATH "%PATH%;{0}"' -f $BinDir)
        Write-Info 'Open a new terminal afterwards so the change takes effect.'

        if ($failed -gt 0) { return 1 }
        return 0
    }
    catch {
        Write-Bad $_.Exception.Message
        return 1
    }
    finally {
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$status = Invoke-Install

# Exiting is only safe when the script was started as a file. When it is piped
# into iex, exiting would close the user's terminal.
if ($status -ne 0 -and $PSCommandPath) {
    exit $status
}
