## Sort files into category folders

- **Source:** `src/catsort.cs`
- **Dependencies:** none
- **Description:** Sorts files into category folders by extension. Copies each matched file, verifies the copy via SHA256, then deletes the original. Unmatched files are left untouched.

---

### Usage

```
catsort [directory] [--dry-run] [--conf=PATH]
```

| Arg | Default | Description |
|---|---|---|
| `directory` | current dir | Directory to scan and sort |
| `--dry-run` / `-n` | off | Preview only, no copies or deletes |
| `--conf=PATH` | `../conf/.cats` | Use a different category map |

---

### How it works

#### Matching

Scans the target directory for files (non-recursive). For each file, matches its extension against every category in the config file.

#### Sorting

Creates the category subfolder if it does not exist, copies the file into it, computes SHA256 of both original and copy. If they match, deletes the original.

A file that already exists in the target category folder is skipped and the original is left in place.

#### Report

Prints the moved count, the verified count, and the failure count.

---

### Design decisions

- **Copy-then-delete (not move):** moving preserves the file but does not verify the destination is readable. Copy-verify-delete ensures the file landed intact before removing the source.
- **SHA256 verification:** catches silent corruption from disk errors or copy failures. The hash is computed on both sides and compared byte-by-byte.
- **Non-recursive by design:** sorting is typically a one-time cleanup for a flat download folder. Recursive sorting would also move files within already-sorted subfolders, creating confusion.
- **Config over hardcoded map:** `--conf=PATH` points at any category file, so a different extension map needs no recompilation.

---

### Source tree

```
cli/
├── src/
│   └── catsort.cs         ← single-file source
├── bin/
│   └── catsort.exe        ← compiled binary
├── conf/
│   └── .cats              ← category-to-extension map
└── docs/
    └── catsort.md
```

---

### Known limitations

- No recursion - subdirectories are not scanned.
- Overwrite prevention - if a file with the same name already exists in the target category folder, it is skipped with a notice and the original is left in place.
