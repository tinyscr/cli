## unified CLI tools

Portable command line tools in one folder. One `bin/` for PATH, one `conf/` for config files, one `build.bat` to compile everything.

Each tool is fully independent. Removing one .exe and its config file leaves the rest working. Copy the folder anywhere, add its `bin/` to PATH, and every tool runs.

---

## Installing

```
iwr https://raw.githubusercontent.com/tinyscr/cli/main/install.ps1 | iex
```

The installer downloads the sources, compiles the tools you pick on your own machine, and drops everything into a `tinyscripts.CLI` folder next to where you ran it. Existing config files are never overwritten.

Enter `0` to install everything, or the tool numbers one after another. See [docs/install.md](docs/install.md) for the details.

Run the same command again whenever a tool changes. Only the tools whose sources changed are recompiled.

### Requirements

- Windows 10 or later.
- PowerShell 5.1, which ships with Windows.
- The C# compiler that ships with Windows, at `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`.

Nothing else. No Visual Studio, no NuGet, no dotnet CLI, no runtime to install.

### PATH setup

```
setx PATH "%PATH%;<folder>\tinyscripts.CLI\bin"
```

One entry covers all tools. Restart your terminal after setting.

---

## Tools

#### [delcache](docs/delcache.md)

- **Source:** `src/delcache.cs`
- **Dependencies:** none
- **Description:** Finds and deletes cache/temp directories by recursively scanning a root path against a config file.

#### [catsort](docs/catsort.md)

- **Source:** `src/catsort.cs`
- **Dependencies:** none
- **Description:** Sorts files into category folders by extension, verifying each copy via SHA256 before deleting the original.

#### [dirdiff](docs/dirdiff.md)

- **Source:** `src/dirdiff/` (program.cs, scanner.cs, diff.cs, logcfg.cs)
- **Dependencies:** `System.Windows.Forms` (native folder pickers)
- **Description:** Compares two directories by filename, size, and SHA256, and prints a detailed report.

#### [reindex](docs/reindex.md)

- **Source:** `src/reindex.cs`
- **Dependencies:** none
- **Description:** Renames files to sequential numbers, preserving extensions, with rollback support.

#### [mmu](docs/mmu.md) (**m**ini **m**usic **u**til)

- **Source:** `src/mmu/mmu.cs`, `download.cs`
- **Dependencies:** external yt-dlp (required) + ffmpeg (recommended)
- **Description:** Downloads audio from YouTube/YT Music interactively.

#### [nodup](docs/nodup.md)

- **Source:** `src/nodup.cs`
- **Dependencies:** none
- **Description:** Finds byte-identical files at the top level of a directory (exact size + SHA256), keeps the copy with the oldest timestamp evidence, and moves the rest into `nodup_bin/` with a manifest. `--perm` deletes permanently instead.

---

### Building

```
build.bat
```

Uses Windows' built-in C# compiler (`csc.exe`). None of the tools need Visual Studio, NuGet, the dotnet CLI, or an install step.

#### Prerequisites

- .NET Framework 4.0+ (ships with Windows 8+; available for Windows 7).
- `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` - part of the .NET Framework SDK component of Windows.
- `System.Windows.Forms.dll` - referenced only by `dirdiff`, ships with .NET Framework.

#### Build output

`src/` holds all C# sources, `build.bat` compiles them into `bin/` binaries, and `conf/` holds the config files each tool reads at runtime. Copy the folder, point PATH at `bin/`, and everything works.

#### Adding a new tool

1. Write your .cs file in `src/`.
2. Add a compile line to `build.bat` (same pattern as the existing tools).
3. If the tool needs a config file, add it to `conf/` and reference it from code as `../conf/<filename>`.
4. Run `build.bat` - the .exe lands in `bin/` automatically.

The installer picks up new tools on its own. It reads whatever is in `src/`, so no separate registration step is needed.

---

### Compatibility

All tools compile and run on 64-bit Windows (Windows 7+). On 32-bit Windows, change the `csc.exe` path in `build.bat` to the non-64 `C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe`.

The installer needs PowerShell 5.1 and therefore Windows 10 or later. The tools themselves run on Windows 7 as well.
