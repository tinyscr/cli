## Find and bin duplicate files

- **Source:** `src/nodup.cs`
- **Dependencies:** none
- **Description:** Scans the top level of a directory, groups files by exact size + SHA256, keeps the copy with the oldest timestamp evidence, and moves the rest into `nodup_bin/`. With `--perm` it deletes them permanently instead.

---

### Usage

```
nodup [--dry-run] [--perm] [DIR]
```

- **DIR** - directory to scan (default: current directory). Top level only - subfolders are never touched.
- **--dry-run** - print the full plan, change nothing. Creates no bin, writes no log.
- **--perm** - delete duplicates permanently instead of moving them to `nodup_bin/`. Prompts `[y/N]` before deleting.

Exit codes: `0` clean run (or nothing found), `1` anything was skipped or failed (unreadable file, changed mid-run, failed move/delete), `2` usage error (unknown option, missing directory, drive root refused).

> [!WARNING]
> `--perm` permanently deletes files. Always run `--dry-run --perm` first.

---

### How it works

#### Discovery

Enumerates the top level of DIR only (`Directory.GetFiles`, no recursion). Zero-byte files (all share the same hash and are usually placeholders like `.keep`) and reparse points (symlinks/junctions) are skipped.

#### Grouping

1. Files are grouped by exact size - no hashing yet.
2. Only same-size groups get a SHA256 stream hash (1 MB chunks).
3. Files sharing size + hash form a duplicate group.

A file that cannot be read or hashed is reported as skipped and makes the run exit `1` - an unreadable file could be hiding a duplicate, so silence would be a lie.

#### Keep rule

Within a group, the file with the **oldest evidence** survives: the minimum across its own Created, Modified, and Accessed timestamps. Ties fall back to Created, then Modified, then shorter filename, then name order.

Why this rule matches "which is the original" (measured on Windows, same-volume, NTFS):

| Mechanism | Created | Modified |
|---|---|---|
| Explorer paste / .NET / cmd / PowerShell copy | reset to now | preserved |
| robocopy (default) | preserved | preserved |
| same-volume rename/move | preserved | preserved |

Windows copies preserve Modified but stamp Created with the copy time - so `modified < created` is the normal copy signature, and Created marks when a file *arrived here*. Modified is content age: identical across copies, so it can only act as a tiebreak. Accessed joins the minimum as a third piece of evidence; Windows normally resets it alongside Created and updates it lazily, so it rarely decides. The Created tiebreak matters when the oldest timestamps tie - e.g. the same file downloaded twice, where both copies carry the same server Modified date but the first download holds the earlier Created. Timestamps before 1970 (some filesystems report `1601-01-01` for missing values) are ignored, and all comparisons are in UTC.

#### Bin

Default action: `File.Move` each duplicate into `nodup_bin/` next to the scanned files. Same-volume rename, so the move is atomic, instant, and preserves all timestamps. Name collisions get a ` (2)` suffix.

`nodup_bin/_nodup_manifest.txt` is both log and manifest: a banner line, a `Directory:` header, then one entry per duplicate group - full SHA256 and size, when it was processed, the kept file, and every duplicate moved out (a collided stored name is noted in brackets). Entries accumulate across runs, so the file doubles as a history; restoring a file means moving it from the bin back into the directory.

The bin is never scanned (top level only), so a rerun after a move is idempotent, and inspecting/emptying the bin is manual by design.

#### Commit verification

Nothing is moved or deleted from the scan alone: right before each action, the victim **and** its keeper are hashed again and compared against the scan hash. A file that changed mid-run is skipped and exits `1`.

#### Logging

Real runs write `logs/nodup/<timestamp>/summary.log` (the full report), keeping the last 10 run folders. Dry runs write nothing.

#### Error handling

- Unreadable files: skipped, reported, exit `1`.
- Read-only file under `--perm`: `File.Delete` fails, other deletions continue, exit `1`. (Moving still works - rename doesn't need write access.)
- Manifest write failure is reported, but the move has already happened - the bin still holds the file.
- A drive root is refused (`2`); a file named `nodup_bin` already present is refused (`2`).

---

### Design decisions

- **Move-to-bin over immediate delete:** the default path is reversible with no code: everything sits in `nodup_bin/` with a manifest. Permanent deletion is opt-in (`--perm`) and prompted.
- **Oldest evidence over a single timestamp:** merging all three timestamps into a minimum keeps the rule working when any one of them is unset, reset, or preserved by a sync tool; the tiebreak chain keeps it deterministic when everything ties.
- **Top level only:** recursive dedupe is a different, much riskier tool - `.git`, `node_modules`, and build trees are full of intentional copies. Scoping to one folder keeps the blast radius local.
- **Size before hash:** cheap filter first; only files that could be duplicates are hashed.
- **Double verification:** hashing at scan and again at commit means a file mutating during the run is never removed.
- **No config file:** the flags cover the whole surface, and the bin and log locations are fixed so the bin and its manifest always travel together.
- **Append-only manifest:** repeated runs accumulate rows; history is never rewritten.

---

### Source tree

```
cli/
├── src/
│   └── nodup.cs           ← single-file source
├── bin/
│   └── nodup.exe          ← compiled binary
├── logs/
│   └── nodup/             ← <timestamp>/summary.log (last 10 runs)
└── docs/
    └── nodup.md
```

---

### Known limitations

- No recursion - only the top level of DIR is scanned.
- Zero-byte files are skipped entirely.
- Hardlinks are not detected; two links to identical content count as duplicates and one link is moved (harmless - the content stays).
- Files inside `nodup_bin/` are never rescanned, even against each other.
- No restore command - recovery is manual via the manifest.
- Timestamps can be unreliable on network shares and some cloud-synced folders; if everything ties, the filename decides.
- NTFS tunneling can hand a freshly recreated same-name file the old Created time of a just-moved file (~15 s window) - harmless, but it can skew the next run's keep rule.
