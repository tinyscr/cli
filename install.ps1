<#
.SYNOPSIS
  Installs the tinyscr cli tools by compiling them from source on this machine.

.DESCRIPTION
  Downloads the tool sources from the repository, compiles the selected tools
  with the C# compiler that ships with Windows, and installs the resulting
  executables into a tinyscripts.CLI folder in the current directory.

  Nothing is installed system wide. The compiler is part of Windows, so no
  runtime, no package manager and no Visual Studio are required.

  Running the script again rebuilds only the tools whose sources changed.

.PARAMETER InstallDir
  Where to create the tinyscripts.CLI folder. Defaults to the current directory.

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
$FolderName = 'tinyscripts.CLI'

function Write-Step($Message) { Write-Host $Message }
function Write-Info($Message) { Write-Host $Message -ForegroundColor DarkGray }
function Write-Good($Message) { Write-Host $Message -ForegroundColor Green }
function Write-Bad($Message) { Write-Host $Message -ForegroundColor Red }

# Status is written to one line that is rewritten in place, so a long install
# shows the current tool instead of scrolling a line per tool.
function Write-Status($Message) {
    $pad = $script:StatusWidth - $Message.Length
    if ($pad -lt 0) { $pad = 0 }
    [Console]::Write("`r" + $Message + (' ' * $pad))
    $script:StatusWidth = $Message.Length
}

function Clear-Status() {
    if ($script:StatusWidth -gt 0) {
        [Console]::Write("`r" + (' ' * $script:StatusWidth) + "`r")
        $script:StatusWidth = 0
    }
}

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
    Write-Host 'Enter the numbers to install, one after another.'
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
    if (-not (Test-Path -LiteralPath $sourceConf)) { return 0 }

    $added = 0
    foreach ($file in (Get-ChildItem -LiteralPath $sourceConf -Recurse -File)) {
        $relative = $file.FullName.Substring($sourceConf.Length).TrimStart('\', '/')
        $target = Join-Path $ConfDir $relative
        if (Test-Path -LiteralPath $target) { continue }

        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $added++
    }
    return $added
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
        $RootDir = Join-Path $InstallDir $FolderName
        $BinDir = Join-Path $RootDir 'bin'
        $ConfDir = Join-Path $RootDir 'conf'
        $StateDir = Join-Path $RootDir '.state'

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

        Write-Step ''

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
                Write-Status ($tool.Name + ' is up to date.')
                $skipped++
                continue
            }

            Write-Status ('Building ' + $tool.Name + '...')
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
                Clear-Status
                Write-Bad ('Failed to build ' + $tool.Name + ':')
                $output | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor Red }
                $failed++
                continue
            }
            if ($output) {
                Clear-Status
                $output | ForEach-Object { Write-Info ('  ' + $_) }
            }

            Set-Content -LiteralPath $marker -Value $sourceHash -NoNewline
            $built++
        }

        Clear-Status

        Write-Status 'Adding config files...'
        $configCount = Install-ConfigFiles $SourceRoot $ConfDir
        Clear-Status
        if ($configCount -gt 0) {
            Write-Info ('  added ' + $configCount + ' config file(s)')
        }

        Write-Step ''
        Write-Step ('Installed {0}, up to date {1}, failed {2}.' -f $built, $skipped, $failed)
        Write-Step ('Executables: {0}' -f $BinDir)
        Write-Step ''
        Write-Step 'Add it to your PATH:'
        Write-Host ('  $bin = "{0}"' -f $BinDir)
        Write-Host "  `$user = [Environment]::GetEnvironmentVariable('PATH', 'User')"
        Write-Host '  $entries = @($user -split '';'' | Where-Object { $_ })'
        Write-Host '  if ($entries -notcontains $bin) {'
        Write-Host '      [Environment]::SetEnvironmentVariable(''PATH'', (($entries + $bin) -join '';''), ''User'')'
        Write-Host '  }'
        Write-Step ''
        Write-Info 'Open a new terminal afterwards so the change takes effect.'

        if ($failed -gt 0) { return 1 }
        return 0
    }
    catch {
        Clear-Status
        Write-Bad $_.Exception.Message
        return 1
    }
    finally {
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$script:StatusWidth = 0
$status = Invoke-Install

# Exiting is only safe when the script was started as a file. When it is piped
# into iex, exiting would close the user's terminal.
if ($status -ne 0 -and $PSCommandPath) {
    exit $status
}
