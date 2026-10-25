using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

class Program
{
    static bool _dryRun;
    static bool _perm;
    static int _moved;
    static int _deleted;
    static int _failed;
    static long _actionedBytes;
    static string _exeDir;
    static readonly StringBuilder Report = new StringBuilder();
    static readonly HashSet<string> _claimed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

    const string BinName = "nodup_bin";
    const string ManifestName = "_nodup_manifest.txt";
    const string ManifestBanner = "/----- nodup manifest file -----/";
    const int ChunkSize = 1024 * 1024;
    const int LogKeep = 10;

    // Timestamps before 1970 are treated as "unset" - some filesystems report
    // 1601-01-01 for missing values, which would otherwise win every group.
    static readonly DateTime TsFloor = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    class Entry
    {
        public string Path;
        public string Name;
        public long Size;
        public string Hash;
        public DateTime Created;
        public DateTime Modified;
        public DateTime Accessed;
        public DateTime Score;      // oldest of the three, sentinel-guarded
        public string ScoreFrom;    // which timestamp supplied the score
        public string Dest;         // planned bin path when moving
    }

    static int Main(string[] args)
    {
        _exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);

        string targetDir = null;
        foreach (string a in args)
        {
            if (a == "--dry-run") _dryRun = true;
            else if (a == "--perm") _perm = true;
            else if (a.StartsWith("-"))
            {
                Console.Error.WriteLine("Unknown option: " + a);
                Console.Error.WriteLine("Usage: nodup [--dry-run] [--perm] [DIR]");
                return 2;
            }
            else if (targetDir == null) targetDir = a;
            else
            {
                Console.Error.WriteLine("Too many arguments.");
                Console.Error.WriteLine("Usage: nodup [--dry-run] [--perm] [DIR]");
                return 2;
            }
        }

        if (targetDir == null) targetDir = ".";
        string full = Path.GetFullPath(targetDir);
        if (!Directory.Exists(full))
        {
            Console.Error.WriteLine("Directory not found: " + full);
            return 2;
        }

        string driveRoot = Path.GetPathRoot(full);
        if (driveRoot != null &&
            string.Equals(full.TrimEnd('\\', '/'), driveRoot.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("Refusing to scan a drive root: " + full);
            return 2;
        }

        string binDir = Path.Combine(full, BinName);
        if (!_perm && File.Exists(binDir))
        {
            Console.Error.WriteLine("A file named " + BinName + " already exists here: " + binDir);
            return 2;
        }

        if (_dryRun)
            Console.WriteLine();
        if (_dryRun)
            Console.WriteLine("[Dry run]");
        Line("Scanning files in " + full + " (top level)");
        Line("");

        // Discovery: top-level files only, no recursion.
        var entries = new List<Entry>();
        int skippedEmpty = 0;
        int skippedLinks = 0;
        foreach (string path in Directory.GetFiles(full))
        {
            string name = Path.GetFileName(path);
            FileAttributes attrs;
            long size;
            try
            {
                attrs = File.GetAttributes(path);
                size = new FileInfo(path).Length;
            }
            catch (Exception ex)
            {
                Fail("  SKIP unreadable  " + name + "  (" + ex.Message + ")");
                continue;
            }

            if ((attrs & FileAttributes.ReparsePoint) != 0)
            {
                skippedLinks++;
                continue;
            }
            if (size == 0)
            {
                skippedEmpty++;
                continue;
            }
            entries.Add(new Entry { Path = path, Name = name, Size = size });
        }

        // Group by exact size first; only same-size files get hashed.
        var bySize = new Dictionary<long, List<Entry>>();
        foreach (Entry e in entries)
        {
            List<Entry> list;
            if (!bySize.TryGetValue(e.Size, out list))
            {
                list = new List<Entry>();
                bySize.Add(e.Size, list);
            }
            list.Add(e);
        }

        var toHash = new List<Entry>();
        foreach (KeyValuePair<long, List<Entry>> kv in bySize)
            if (kv.Value.Count > 1)
                toHash.AddRange(kv.Value);
        toHash.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));

        if (toHash.Count > 0)
        {
            bool progress = toHash.Count > 20;
            int done = 0;
            foreach (Entry e in toHash)
            {
                e.Hash = HashFile(e.Path);
                if (e.Hash == null)
                    Fail("  SKIP unreadable  " + e.Name + "  (could not hash)");
                done++;
                if (progress)
                {
                    Console.Write("\r  Hashing " + done + " / " + toHash.Count + "  ");
                    Console.Out.Flush();
                }
            }
            if (progress)
                Console.WriteLine();
        }

        var groups = new List<List<Entry>>();
        foreach (KeyValuePair<long, List<Entry>> kv in bySize)
        {
            if (kv.Value.Count < 2)
                continue;

            var byHash = new Dictionary<string, List<Entry>>(StringComparer.Ordinal);
            foreach (Entry e in kv.Value)
            {
                if (e.Hash == null)
                    continue;
                List<Entry> list;
                if (!byHash.TryGetValue(e.Hash, out list))
                {
                    list = new List<Entry>();
                    byHash.Add(e.Hash, list);
                }
                list.Add(e);
            }
            foreach (KeyValuePair<string, List<Entry>> hkv in byHash)
                if (hkv.Value.Count > 1)
                    groups.Add(hkv.Value);
        }

        foreach (List<Entry> g in groups)
        {
            foreach (Entry e in g)
                LoadTimes(e);
            g.Sort(CompareEntries);
        }
        groups.Sort((a, b) => string.CompareOrdinal(a[0].Name, b[0].Name));

        if (groups.Count == 0)
        {
            Line("No duplicate files found." + SkipNote(skippedEmpty, skippedLinks));
            Line("");
            WriteRunLog();
            return _failed > 0 ? 1 : 0;
        }

        int redundant = 0;
        long redundantBytes = 0;
        foreach (List<Entry> g in groups)
        {
            for (int i = 1; i < g.Count; i++)
            {
                redundant++;
                redundantBytes += g[i].Size;
            }
        }

        Line("Found " + groups.Count + " " + (groups.Count == 1 ? "group" : "groups")
            + ": " + redundant + " " + (redundant == 1 ? "duplicate" : "duplicates")
            + ", " + FormatSize(redundantBytes));
        Line("");

        WriteGroups(groups, binDir);

        if (!_dryRun && _perm)
        {
            Console.Write("Delete " + redundant + " " + (redundant == 1 ? "file" : "files")
                + " permanently? [y/N] ");
            string input = Console.ReadLine();
            if (string.IsNullOrEmpty(input) ||
                (input.Trim().ToLower() != "y" && input.Trim().ToLower() != "yes"))
            {
                Console.WriteLine("Cancelled.");
                return 0;
            }
        }

        if (_dryRun)
        {
            if (_perm)
                Line("  " + redundant + " " + (redundant == 1 ? "duplicate" : "duplicates")
                    + " (" + FormatSize(redundantBytes) + ") would be deleted permanently.");
            else
                Line("  " + redundant + " " + (redundant == 1 ? "duplicate" : "duplicates")
                    + " (" + FormatSize(redundantBytes) + ") would be moved to " + BinName + "\\.");
        }
        else
        {
            Execute(groups, binDir);
            Line("");
            if (_perm)
                Line("  Done.  " + _deleted + " deleted (" + FormatSize(_actionedBytes)
                    + " freed), " + _failed + " failed.");
            else
                Line("  Done.  " + _moved + " moved to " + BinName + "\\ ("
                    + FormatSize(_actionedBytes) + "), " + _failed + " failed.");
        }

        WriteRunLog();
        return _failed > 0 ? 1 : 0;
    }

    static void WriteGroups(List<List<Entry>> groups, string binDir)
    {
        string verb = _perm ? (_dryRun ? "would delete" : "delete") : (_dryRun ? "would move" : "move");
        int gi = 0;
        foreach (List<Entry> g in groups)
        {
            gi++;
            int width = 0;
            foreach (Entry e in g)
                if (e.Name.Length > width) width = e.Name.Length;

            Line("  [" + gi + "]  " + FormatSize(g[0].Size) + "  | SHA: " + g[0].Hash);
            Line("");
            Line("       " + "keep".PadRight(12) + "  " + g[0].Name.PadRight(width) + "  |  " + Stamp(g[0]));
            for (int i = 1; i < g.Count; i++)
            {
                Entry e = g[i];
                string tail = "";
                if (!_perm)
                {
                    if (e.Dest == null)
                        e.Dest = PlanDest(binDir, e.Name);
                    string stored = Path.GetFileName(e.Dest);
                    tail = "  ->  " + BinName + "\\" + (stored == e.Name ? "" : stored);
                }
                Line("       " + verb.PadRight(12) + "  " + e.Name.PadRight(width) + "  |  " + Stamp(e) + tail);
            }
            Line("");
        }
    }

    static void Execute(List<List<Entry>> groups, string binDir)
    {
        int entryNo = _perm ? 0 : CountEntries(Path.Combine(binDir, ManifestName));

        foreach (List<Entry> g in groups)
        {
            Entry keeper = g[0];
            string keeperHash = HashFile(keeper.Path);
            if (keeperHash != keeper.Hash)
            {
                Fail("  SKIP group  " + keeper.Name + "  (keeper changed since scan)");
                continue;
            }

            var moved = new List<Entry>();
            for (int i = 1; i < g.Count; i++)
            {
                Entry v = g[i];
                string victimHash = HashFile(v.Path);
                if (victimHash != v.Hash)
                {
                    Fail("  SKIP  " + v.Name + "  (changed since scan)");
                    continue;
                }

                if (_perm)
                {
                    try
                    {
                        File.Delete(v.Path);
                        _deleted++;
                        _actionedBytes += v.Size;
                    }
                    catch (Exception ex)
                    {
                        Fail("  FAIL delete  " + v.Name + "  (" + ex.Message + ")");
                    }
                }
                else
                {
                    try
                    {
                        if (!Directory.Exists(binDir))
                            Directory.CreateDirectory(binDir);
                        if (v.Dest == null || File.Exists(v.Dest))
                            v.Dest = PlanDest(binDir, v.Name);
                        File.Move(v.Path, v.Dest);
                        moved.Add(v);
                        _moved++;
                        _actionedBytes += v.Size;
                    }
                    catch (Exception ex)
                    {
                        Fail("  FAIL move  " + v.Name + "  (" + ex.Message + ")");
                    }
                }
            }

            if (!_perm && moved.Count > 0)
            {
                entryNo++;
                AppendManifestEntry(entryNo, keeper, moved, binDir);
            }
        }
    }

    static string PlanDest(string binDir, string name)
    {
        string cand = Path.Combine(binDir, name);
        if (!File.Exists(cand) && !_claimed.Contains(cand))
        {
            _claimed.Add(cand);
            return cand;
        }

        string baseName = Path.GetFileNameWithoutExtension(name);
        string ext = Path.GetExtension(name);
        int n = 2;
        do
        {
            cand = Path.Combine(binDir, baseName + " (" + n + ")" + ext);
            n++;
        } while (File.Exists(cand) || _claimed.Contains(cand));
        _claimed.Add(cand);
        return cand;
    }

    static void AppendManifestEntry(int n, Entry keeper, List<Entry> moved, string binDir)
    {
        try
        {
            string mf = Path.Combine(binDir, ManifestName);
            var sb = new StringBuilder();
            if (!File.Exists(mf))
            {
                sb.AppendLine(ManifestBanner);
                sb.AppendLine("Directory: " + Path.GetDirectoryName(binDir));
                sb.AppendLine();
            }
            else
            {
                EnsureBanner(mf);
            }
            sb.AppendLine("[" + n + "] " + keeper.Hash + " | " + FormatSize(keeper.Size));
            sb.AppendLine("    Timestamp: " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.AppendLine("    Kept file: " + keeper.Name);
            foreach (Entry v in moved)
            {
                string stored = Path.GetFileName(v.Dest);
                sb.AppendLine("    Deleted: " + v.Name + (stored == v.Name ? "" : "  [stored as: " + stored + "]"));
            }
            sb.AppendLine();
            File.AppendAllText(mf, sb.ToString());
        }
        catch (Exception ex)
        {
            Fail("  FAIL manifest  " + keeper.Name + "  (" + ex.Message + ")");
        }
    }

    static int CountEntries(string mf)
    {
        int n = 0;
        try
        {
            if (File.Exists(mf))
                foreach (string line in File.ReadAllLines(mf))
                    if (line.StartsWith("["))
                        n++;
        }
        catch
        {
        }
        return n;
    }

    static void EnsureBanner(string mf)
    {
        try
        {
            string text = File.ReadAllText(mf);
            if (!text.StartsWith(ManifestBanner))
                File.WriteAllText(mf, ManifestBanner + Environment.NewLine + text);
        }
        catch
        {
        }
    }

    static void LoadTimes(Entry e)
    {
        try
        {
            e.Created = File.GetCreationTimeUtc(e.Path);
            e.Modified = File.GetLastWriteTimeUtc(e.Path);
            e.Accessed = File.GetLastAccessTimeUtc(e.Path);
        }
        catch
        {
            e.Created = e.Modified = e.Accessed = DateTime.MinValue;
        }

        DateTime best = DateTime.MaxValue;
        string from = null;
        if (e.Created >= TsFloor && e.Created < best) { best = e.Created; from = "created"; }
        if (e.Modified >= TsFloor && e.Modified < best) { best = e.Modified; from = "modified"; }
        if (e.Accessed >= TsFloor && e.Accessed < best) { best = e.Accessed; from = "accessed"; }
        if (from == null) { best = e.Created; from = "created"; }
        e.Score = best;
        e.ScoreFrom = from;
    }

    static int CompareEntries(Entry a, Entry b)
    {
        int c = a.Score.CompareTo(b.Score);
        if (c != 0) return c;
        c = a.Created.CompareTo(b.Created);
        if (c != 0) return c;
        c = a.Modified.CompareTo(b.Modified);
        if (c != 0) return c;
        c = a.Name.Length.CompareTo(b.Name.Length);
        if (c != 0) return c;
        return string.CompareOrdinal(a.Name, b.Name);
    }

    static string Stamp(Entry e)
    {
        if (e.Score < TsFloor)
            return "no valid timestamp";
        return e.Score.ToLocalTime().ToString("yyyy-MM-dd HH:mm") + "  (" + e.ScoreFrom + ")";
    }

    static string SkipNote(int empty, int links)
    {
        if (empty == 0 && links == 0)
            return "";
        var parts = new List<string>();
        if (empty > 0) parts.Add(empty + " empty");
        if (links > 0) parts.Add(links + " symlink");
        return "  (skipped: " + string.Join(", ", parts.ToArray()) + ")";
    }

    static string FormatSize(long bytes)
    {
        if (bytes >= 1024L * 1024 * 1024) return (bytes / 1073741824.0).ToString("0.0") + " GB";
        if (bytes >= 1024L * 1024) return (bytes / 1048576.0).ToString("0.0") + " MB";
        if (bytes >= 1024) return (bytes / 1024.0).ToString("0.0") + " KB";
        return bytes + " B";
    }

    static string HashFile(string path)
    {
        try
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, ChunkSize))
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "").ToLower();
        }
        catch
        {
            return null;
        }
    }

    static void WriteRunLog()
    {
        if (_dryRun)
            return;
        try
        {
            string dir = Path.GetFullPath(Path.Combine(_exeDir, "..", "logs", "nodup"));
            string runDir = Path.Combine(dir, DateTime.Now.ToString("yyyyMMdd-HHmmss"));
            Directory.CreateDirectory(runDir);
            File.WriteAllText(Path.Combine(runDir, "summary.log"), Report.ToString());

            string[] dirs = Directory.GetDirectories(dir);
            if (dirs.Length > LogKeep)
            {
                Array.Sort(dirs, StringComparer.Ordinal);
                for (int i = 0; i < dirs.Length - LogKeep; i++)
                    Directory.Delete(dirs[i], true);
            }
        }
        catch
        {
        }
    }

    static void Line(string s)
    {
        Console.WriteLine(s);
        Report.AppendLine(s);
        Console.Out.Flush();
    }

    static void Fail(string s)
    {
        Console.Error.WriteLine(s);
        Report.AppendLine(s);
        _failed++;
    }
}
