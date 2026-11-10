## Rename files sequentially

- **Source:** `src/reindex.cs`
- **Dependencies:** none
- **Description:** Reindexes all files in a directory to sequential numbers (01.jpg, 02.png, 03.pdf, etc.) or random names, preserving extensions, with rollback support. Handles collisions by renaming through temp GUIDs.

---

### Usage

```
reindex [directory] [--dry-run] [--rollback] [-rnd [LEN]]
```

| Arg | Default | Description |
|---|---|---|
| `directory` | current dir | Directory whose files to rename |
| `--dry-run` / `-n` | off | Preview only, no actual renames |
| `--rollback` / `-r` | off | Revert the most recent reindex in the target directory |
| `-rnd [LEN]` | off (numbering) | Random names instead of numbers; default 32 chars, `LEN` 1-255 |

Padding adjusts automatically: up to 99 files gives `01.ext`, 100-999 gives `001.ext`, and so on. `-rnd` skips padding, so every name is exactly `LEN` characters.

---

### How it works

#### Ignore list

Loads `conf/.indexignore`, a list of filenames to skip, one per line. `#` and `;` start a comment, empty lines are ignored, and matching is case-insensitive.

The shipped file lists `desktop.ini`, `thumbs.db`, `.ds_store`, and `folder.jpg`. If the file is missing, nothing is skipped.

#### Two-phase rename

Scans the directory for files (non-recursive), sorted alphabetically. Renames each file to a random GUID temp name, which avoids collisions with the final names, then renames each temp file to the sequential name. With `-rnd`, the final name is drawn from a crypto RNG instead, checked against the run's own set of names and redrawn on collision.

If a unique random name cannot be found after 100 attempts, the run fails and asks for a longer length.

#### Rollback

Every successful reindex writes a log to `logs/reindex/<timestamp>.txt` with the original directory and each original-to-final mapping. `--rollback` reads the most recent log and reverses the rename using the same two-phase GUID approach.

If any step fails mid-run, temp files are cleaned up and the originals are preserved.

---

### Design decisions

- **Two-phase rename (not rename-in-place):** if file `3.jpg` already exists and you want to rename `zzz.jpg` to `3.jpg`, a direct rename would overwrite. The two-phase approach (original to guid to final) avoids all collisions.
- **Alphabetical order:** provides a deterministic, reproducible sequence. Sorting by date or size would make the order depend on filesystem metadata.
- **Rollback via logs:** renaming is destructive, so `--rollback` gives a safety net without needing a VCS or file history. Random renames log the same mapping, so they revert identically.
- **Crypto RNG for `-rnd`:** `Random` seeds from the clock, so two runs in the same tick draw correlated sequences; `RandomNumberGenerator` has no such failure mode.
- **Ignore list in a config file:** files like `desktop.ini` and `thumbs.db` should not be touched. A config file keeps the list editable without recompilation.

---

### Source tree

```
cli/
├── src/
│   └── reindex.cs         ← single-file source
├── bin/
│   └── reindex.exe        ← compiled binary
├── conf/
│   └── .indexignore       ← skip list
├── logs/
│   └── reindex/           ← rollback logs (25 kept)
└── docs/
    └── reindex.md
```

---

### Known limitations

- No recursion - only files in the specified directory.
- Order is alphabetical by filename - not by any other property.
- Rollback only works if the log file still exists (25-log rotation).
- With no ignore file present, system files such as `desktop.ini` are renamed too.
