## Installing the tools

- **Source:** `install.ps1`
- **Requirements:** Windows 10+, PowerShell 5.1, and the C# compiler that ships with Windows
- **Description:** Downloads the tool sources, compiles the tools you pick on your own machine, and installs them into a `tinyscripts.CLI` folder.

---

### Usage

```powershell
iwr https://raw.githubusercontent.com/tinyscr/cli/main/install.ps1 | iex
```

The installer downloads the sources from the repository, lists the tools it found, and asks which ones to build. The list below is an example run:

```
Available tools:
  1. catsort
  2. delcache
  3. dirdiff
  4. mmu
  5. nodup
  6. reindex

Enter the numbers to install, one after another.
Enter 0 to install everything.

Selection: 24
```

- `0` installs every tool.
- `24` installs tools 2 and 4.
- `2,4` and `2 4` work the same way.
- Entering nothing installs nothing.

Everything lands in a `tinyscripts.CLI` folder in the directory you ran the installer from:

```
tinyscripts.CLI/
├── bin/        the compiled executables
├── conf/       the config files
└── .state/     per tool source hashes
```

The installer prints the commands to add the `bin` folder to your PATH. Run them, then open a new terminal.

Those commands read the user PATH and write it back through .NET. Do not replace them with `setx PATH "%PATH%;..."`: `setx` writes to the user PATH while `%PATH%` expands to the merged user and system PATH, so every system entry gets copied into your user PATH and shadows the system one. `setx` also truncates the value to 1024 characters and warns when it does.

---

### How it works

#### Source download

The installer fetches the repository archive and unpacks it into a temporary folder. Only the `src/` and `conf/` folders are used. The temporary folder is deleted when the installer finishes.

#### Tool discovery

Every `.cs` file and every folder containing `.cs` files inside `src/` becomes an available tool, named after the file or folder. Adding a tool to the repository makes it available in the installer with no registration step.

#### Compilation

Each tool is compiled with the C# compiler that ships with Windows, found at `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` (or the 32-bit path). No Visual Studio, NuGet, or dotnet CLI is involved.

The current tool is shown on one line that is rewritten in place, so a long install stays readable.

A tool that fails to compile is reported and skipped. The remaining tools still install.

#### Updates

Each tool's sources are hashed and the hash is stored in `.state/<tool>.hash`. Running the installer again compares the stored hash with the current sources and rebuilds only the tools that changed. Tools whose sources are unchanged are left alone.

A bugfix in one tool does not force a rebuild of the others.

#### Config files

Config files are copied into `conf/` only when they are not already there, so your edits are never overwritten. Delete a file to get the current version back on the next run.

The tools read their config from `../conf/` relative to the executable, which is why `bin/` and `conf/` sit next to each other inside the folder.

---

### Options

Running the script as a file gives you a few switches:

```powershell
.\install.ps1 -All            # install every tool without asking
.\install.ps1 -Force          # recompile everything, even unchanged tools
.\install.ps1 -InstallDir C:\Tools
.\install.ps1 -SourceDir .\checkout   # compile from a local checkout
```

| option | effect |
|---|---|
| `-All` | install every tool without prompting |
| `-Force` | recompile even when the sources have not changed |
| `-InstallDir` | put the `tinyscripts.CLI` folder somewhere other than the current directory |
| `-SourceDir` | compile from a local checkout instead of downloading |

---

### Notes

- **Execution policy.** The one-liner pipes the script into `iex`, so it runs even when the policy blocks running script files. If you download the script and run it as a file, you may need `Set-ExecutionPolicy -Scope Process Bypass` or to run it with `powershell -ExecutionPolicy Bypass -File .\install.ps1`.
- **Nothing is installed system wide.** The tools go into the `tinyscripts.CLI` folder, and PATH is left for you to set.
- **Only the compiler is needed.** It is part of Windows, so there is no runtime or dependency to install first.
