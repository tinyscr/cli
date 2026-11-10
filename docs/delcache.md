## Clean cache directories

- **Source:** `src/delcache.cs`
- **Dependencies:** none
- **Description:** Finds and deletes cache/temp directories (`__pycache__`, `node_modules`, etc.) recursively, matching directory names against a config file.

---

### Usage

```
delcache [path]
```

- **path** - root directory to search (default: current directory)

> [!WARNING]
> A typo or malicious entry in the config can cause data loss. Always read the found list before typing `y`.

---

### How it works

#### Discovery

Reads target directory names from `conf/.cdirs`, one per line. `#` starts a comment, empty lines are ignored. Each entry is a search pattern, so `node_modules` matches that name and `*.tmp` matches any name ending in `.tmp`.

For each target it calls `Directory.EnumerateDirectories(root, target, SearchOption.AllDirectories)` to find every matching subdirectory at any depth.

The search descends into junctions and symlinks, so a directory reachable through a link is found and listed twice if it also exists on its own. A matched directory that is itself a link is skipped and reported as `SKIP (symlink/junction)`, and it is never deleted.

#### Confirmation

Prints the full path of every match, then prompts `[y/N]`. Only `y` or `yes` proceeds, everything else cancels.

#### Deletion

Iterates the list and deletes each directory with `Directory.Delete(path, true)`. Reports the success count and prints failures to stderr.

#### Error handling

- A directory that cannot be read during the search is reported once and the scan continues.
- Directories that fail to delete are logged to stderr with the reason; remaining deletions continue.
- If the root path does not exist, prints an error and exits.

---

### Design decisions

- **Always prompt:** cache directories are usually safe to delete, but a typo in `.cdirs` or a wrong root path deletes the wrong data. Forcing Y/N on every run means you see exactly what will be deleted.
- **Config file:** adding or removing targets does not require recompilation. The config file is editable with any text editor.
- **Patterns over plain names:** `Directory.EnumerateDirectories` takes a search pattern, so the config accepts `*.tmp` and `node_mod*` as well as exact names. A single entry can cover a whole family of directories.

---

### Source tree

```
cli/
├── src/
│   └── delcache.cs         ← single-file source
├── bin/
│   └── delcache.exe        ← compiled binary
├── conf/
│   └── .cdirs              ← target directory names
└── docs/
    └── delcache.md
```

---

### Known limitations

- No exclusions - you cannot skip specific paths within a single run.
- No parallel deletion - directories are removed sequentially.
- Follows symlinks - `SearchOption.AllDirectories` traverses junctions and symlinks.
