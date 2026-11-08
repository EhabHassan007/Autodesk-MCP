using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

// The skill library rules of scripts\SkillLibrary.ps1 and the hashing and safety checks of
// scripts\submit-team-knowledge.ps1 and scripts\collect-skills-for-review.ps1, as compiled code.
namespace SmartConnector
{
    internal sealed class SkillFolder
    {
        internal string Name = "", Category = "", Path = "";
    }

    // Skill library layout. The approved library keeps skills in category folders: <root>\<category>\<skill-name>\SKILL.md.
    // Older libraries and the per-PC installs (Codex, Claude, the approved cache) are flat: <root>\<skill-name>\SKILL.md.
    // Both are read, so either layout works.
    internal static class SkillLibrary
    {
        internal static readonly string[] Categories = { "revit", "autocad", "3ds-max", "other-software", "linkedin-marketing", "branding-ci", "general", "uncategorized" };

        // Which approved skills a Skills Sync downloads: the button in Revit or AutoCAD takes only that software's
        // skills. The weekly run takes the Autodesk products installed on this PC, plus General. Skills already
        // installed from other categories are kept, never removed.
        private static readonly string[][] ProductCategories = { new[] { "Revit", "revit" }, new[] { "AutoCAD", "autocad" }, new[] { "3dsMax", "3ds-max" } };

        internal static bool IsCategory(string name)
        {
            return Categories.Any(c => String.Equals(c, name, StringComparison.OrdinalIgnoreCase));
        }

        private static string CategoryOfProduct(string product)
        {
            foreach (string[] pair in ProductCategories)
                if (String.Equals(pair[0], product, StringComparison.OrdinalIgnoreCase)) return pair[1];
            return null;
        }

        // Get-InstalledAutodeskProducts: Revit when RevitAPI.dll is in a "Revit 20*" folder under Autodesk in Program
        // Files, AutoCAD and 3dsMax when their registry key under machineRoot has any sub key.
        internal static List<string> InstalledProducts(string programFiles, string machineRoot)
        {
            List<string> products = new List<string>();
            if (HasRevit(programFiles)) products.Add("Revit");
            if (HasKey(machineRoot, "AutoCAD")) products.Add("AutoCAD");
            if (HasKey(machineRoot, "3dsMax")) products.Add("3dsMax");
            return products;
        }

        private static bool HasRevit(string programFiles)
        {
            try
            {
                string autodesk = System.IO.Path.Combine(programFiles, "Autodesk");
                if (!Directory.Exists(autodesk)) return false;
                foreach (string folder in Directory.GetDirectories(autodesk, "Revit 20*"))
                    if (File.Exists(System.IO.Path.Combine(folder, "RevitAPI.dll"))) return true;
            }
            catch (Exception) { }
            return false;
        }

        // machineRoot as PowerShell writes it: HKLM:\SOFTWARE\Autodesk (or HKCU:\...).
        private static bool HasKey(string machineRoot, string name)
        {
            try
            {
                Match match = Regex.Match(machineRoot, @"^(HKLM|HKCU|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER):?\\(.*)$", RegexOptions.IgnoreCase);
                if (!match.Success) return false;
                bool machine = match.Groups[1].Value.StartsWith("HKLM", StringComparison.OrdinalIgnoreCase) || match.Groups[1].Value.StartsWith("HKEY_LOCAL", StringComparison.OrdinalIgnoreCase);
                string path = match.Groups[2].Value.TrimEnd('\\') + "\\" + name;
                using (RegistryKey key = (machine ? Registry.LocalMachine : Registry.CurrentUser).OpenSubKey(path))
                    return key != null && key.SubKeyCount > 0;
            }
            catch (Exception) { return false; }
        }

        internal static List<string> InstalledProducts()
        {
            return InstalledProducts(Env.ProgramFiles, @"HKLM:\SOFTWARE\Autodesk");
        }

        // Get-SyncCategories: the button's product, or the installed products' categories plus general.
        internal static List<string> SyncCategories(string product, IEnumerable<string> installedProducts)
        {
            List<string> categories = new List<string>();
            if (!String.IsNullOrEmpty(product))
            {
                string category = CategoryOfProduct(product);
                if (category == null) throw new InvalidOperationException("Unknown product for Skills Sync: " + product);
                categories.Add(category);
                return categories;
            }
            foreach (string installed in installedProducts)
            {
                string category = CategoryOfProduct(installed);
                if (category != null && !categories.Contains(category)) categories.Add(category);
            }
            if (!categories.Contains("general")) categories.Add("general");
            return categories;
        }

        // The "category:" line in the SKILL.md frontmatter (the lines between the opening and closing "---");
        // empty when the skill does not declare one.
        internal static string CategoryOf(string skillPath)
        {
            string manifest = System.IO.Path.Combine(skillPath, "SKILL.md");
            if (!File.Exists(manifest)) return "";
            string[] lines = File.ReadAllLines(manifest).Take(40).ToArray();
            if (lines.Length == 0 || !Regex.IsMatch(lines[0].TrimStart('﻿'), @"^---\s*$", RegexOptions.IgnoreCase)) return "";
            for (int i = 1; i < lines.Length && !Regex.IsMatch(lines[i], @"^---\s*$", RegexOptions.IgnoreCase); i++)
            {
                Match match = Regex.Match(lines[i], @"^category:\s*([a-z0-9-]+)\s*$", RegexOptions.IgnoreCase);
                if (match.Success) return match.Groups[1].Value;
            }
            return "";
        }

        private static IEnumerable<DirectoryInfo> Folders(string path)
        {
            // Get-ChildItem -Directory -Force | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name
            return new DirectoryInfo(path).GetDirectories().Where(d => !d.Name.StartsWith(".", StringComparison.Ordinal))
                .OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase);
        }

        // Get-SkillFolders: one entry per skill: Name (the folder name, the skill's identity), Category, Path.
        internal static List<SkillFolder> SkillFolders(string root)
        {
            List<SkillFolder> skills = new List<SkillFolder>();
            if (!Directory.Exists(root)) return skills;
            foreach (DirectoryInfo folder in Folders(root))
            {
                if (File.Exists(System.IO.Path.Combine(folder.FullName, "SKILL.md")))
                    skills.Add(new SkillFolder { Name = folder.Name, Category = CategoryOf(folder.FullName), Path = folder.FullName });
                else if (IsCategory(folder.Name))
                {
                    foreach (DirectoryInfo skill in Folders(folder.FullName))
                        if (File.Exists(System.IO.Path.Combine(skill.FullName, "SKILL.md")))
                            skills.Add(new SkillFolder { Name = skill.Name, Category = folder.Name, Path = skill.FullName });
                }
            }
            return skills;
        }
    }

    // UTF-8 text that was once read as Latin-1 or Windows-1252, possibly more than once, so an em dash turns into three
    // or six accented characters. Each character in such a run stands for one byte of the original UTF-8.
    internal static class SkillText
    {
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);
        private static readonly Dictionary<char, int> MojibakeBytes = BuildBytes();
        private static readonly Regex MojibakeRun = new Regex(@"[\u0080-ÿ" + Regex.Escape(new String(MojibakeBytes.Keys.ToArray())) + "]{2,}");

        // The characters Windows-1252 shows for the bytes 0x80-0x9F (the euro sign, curly quotes, dashes...).
        private static Dictionary<char, int> BuildBytes()
        {
            Dictionary<char, int> map = new Dictionary<char, int>();
            Encoding windows1252 = Encoding.GetEncoding(1252);
            for (int value = 0x80; value <= 0x9F; value++)
            {
                char character = windows1252.GetString(new[] { (byte)value })[0];
                if ((int)character != value) map[character] = value;
            }
            return map;
        }

        private static int ByteOf(char character)
        {
            if ((int)character <= 0xFF) return (int)character;
            return MojibakeBytes[character];
        }

        // Decodes each complete, valid UTF-8 sequence in the run and keeps every other character as it was.
        private static string RepairRun(string run)
        {
            StringBuilder text = new StringBuilder();
            int i = 0;
            while (i < run.Length)
            {
                int lead = ByteOf(run[i]);
                int length = lead >= 0xC2 && lead <= 0xDF ? 2 : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xF0 && lead <= 0xF4 ? 4 : 0;
                if (length > 0 && i + length <= run.Length)
                {
                    byte[] bytes = new byte[length];
                    for (int k = 0; k < length; k++) bytes[k] = (byte)ByteOf(run[i + k]);
                    try
                    {
                        text.Append(StrictUtf8.GetString(bytes));
                        i += length;
                        continue;
                    }
                    catch (ArgumentException) { }
                }
                text.Append(run[i]);
                i++;
            }
            return text.ToString();
        }

        // Undoes up to three wrong decodings. Correct text, including Arabic and real dashes or quotes, is unchanged.
        internal static string Repair(string text)
        {
            for (int pass = 0; pass < 3; pass++)
            {
                string repaired = MojibakeRun.Replace(text, delegate(Match match) { return RepairRun(match.Value); });
                if (String.Equals(repaired, text, StringComparison.Ordinal)) break;
                text = repaired;
            }
            return text;
        }

        // The relative path of a file inside a folder, with forward slashes.
        internal static string Relative(string folder, string file)
        {
            string root = System.IO.Path.GetFullPath(folder).TrimEnd('\\', '/');
            return file.Substring(root.Length).TrimStart('\\', '/').Replace('\\', '/');
        }

        // A skill's text files by relative path, read as UTF-8 without a byte order mark and with mojibake repaired.
        internal static Dictionary<string, string> Read(string path)
        {
            Dictionary<string, string> files = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (string file in new DirectoryInfo(path).GetFiles("*", SearchOption.AllDirectories).Select(f => f.FullName))
                files[Relative(path, file)] = Repair(File.ReadAllText(file, Encoding.UTF8).TrimStart('﻿'));
            return files;
        }

        // Compares skills by repaired text, so a corrupted copy of an approved skill matches the approved one.
        internal static string Key(Dictionary<string, string> files)
        {
            return String.Join("\0\0", files.Keys.OrderBy(k => k, StringComparer.Ordinal).Select(k => k + "\0" + files[k]).ToArray());
        }
    }

    // SHA-256 of a skill folder: one "relative path <tab> file hash" row per file, in path order, hashed again as UTF-8.
    // The managed-skill-hashes.json ledger holds these values, so they match what the PowerShell scripts wrote.
    internal static class SkillHash
    {
        internal static string OfFile(string path)
        {
            using (Stream stream = File.OpenRead(path))
            using (SHA256 algorithm = SHA256.Create())
                return Hex(algorithm.ComputeHash(stream));
        }

        private static string Hex(byte[] bytes)
        {
            return BitConverter.ToString(bytes).Replace("-", "");
        }

        // Get-DirectoryHash. The collector's copy of the function leaves out __pycache__ and .git folders; the one in
        // submit-team-knowledge.ps1 (used for the ledgers and for installed folders) hashes everything.
        internal static string OfFolder(string path, bool skipCacheFolders)
        {
            List<FileInfo> files = new DirectoryInfo(path).GetFiles("*", SearchOption.AllDirectories).ToList();
            files.Sort((a, b) => StringComparer.CurrentCultureIgnoreCase.Compare(a.FullName, b.FullName));
            List<string> rows = new List<string>();
            foreach (FileInfo file in files)
            {
                string relative = SkillText.Relative(path, file.FullName);
                if (skipCacheFolders && Regex.IsMatch(relative, @"(^|/)(__pycache__|\.git)(/|$)", RegexOptions.IgnoreCase)) continue;
                rows.Add(relative + "\t" + OfFile(file.FullName));
            }
            using (SHA256 algorithm = SHA256.Create())
                return Hex(algorithm.ComputeHash(Encoding.UTF8.GetBytes(String.Join("\n", rows.ToArray()))));
        }
    }

    // The checks a saved skill must pass before it can leave this PC (Get-SkillName and Test-SafeCandidate).
    internal static class SkillSafety
    {
        internal static readonly string[] TextExtensions = { ".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".py", ".ps1", ".js", ".ts", ".sh", ".csv", ".xml" };
        private static readonly string[] BlockedExtensions = { ".rvt", ".rfa", ".rte", ".rft", ".dwg", ".dxf", ".dgn", ".nwc", ".nwd", ".ifc", ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".zip", ".7z", ".rar", ".exe", ".dll", ".msi", ".pfx", ".key", ".pem", ".png", ".jpg", ".jpeg", ".gif" };
        // Credentials and tokens, user paths, network shares, cloud model locations and e-mail addresses.
        private static readonly Regex Sensitive = new Regex(@"(?i)(api[_ -]?key|access[_ -]?token|client[_ -]?secret|password\s*[:=]|github_pat_|gh[pousr]_[a-z0-9_]+|begin (rsa|openssh|ec) private key|[a-z]:\\users\\|\\\\[^\\\s]+\\[^\\\s]+|autodesk docs://|bim 360://|acc://|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b)");
        // The collector counts a shorter list of patterns for REVIEW.md.
        private static readonly Regex SensitiveFlag = new Regex(@"(?i)(api[_ -]?key|access[_ -]?token|client[_ -]?secret|password\s*[:=]|begin (rsa|openssh|ec) private key|[a-z]:\\users\\)");

        // The skill's name from its SKILL.md ("name: some-skill").
        internal static string NameOf(string skillPath)
        {
            string manifest = Path.Combine(skillPath, "SKILL.md");
            if (!File.Exists(manifest)) throw new InvalidOperationException("Candidate has no SKILL.md: " + skillPath);
            Match match = Regex.Match(File.ReadAllText(manifest, Encoding.UTF8), @"^name:\s*([a-z0-9]+(?:-[a-z0-9]+)*)\s*$", RegexOptions.Multiline);
            if (!match.Success) throw new InvalidOperationException("Candidate has an invalid or missing skill name: " + manifest);
            return match.Groups[1].Value;
        }

        // Throws when a file of the skill is a link, a binary or project file, too large or holds anything sensitive.
        internal static void CheckCandidate(string skillPath)
        {
            Check(new DirectoryInfo(skillPath));
        }

        private static void Check(DirectoryInfo folder)
        {
            FileSystemInfo[] entries = folder.GetFileSystemInfos();
            Array.Sort(entries, (a, b) => String.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
            foreach (FileSystemInfo item in entries)
            {
                if ((item.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Links are not allowed in team candidates: " + item.FullName);
                DirectoryInfo directory = item as DirectoryInfo;
                if (directory != null) continue;
                FileInfo file = (FileInfo)item;
                string extension = file.Extension.ToLowerInvariant();
                if (!TextExtensions.Contains(extension)) throw new InvalidOperationException("Unsupported candidate file type: " + file.Name);
                if (file.Length > 256 * 1024) throw new InvalidOperationException("Candidate file exceeds 256 KB: " + file.FullName);
                if (BlockedExtensions.Contains(extension)) throw new InvalidOperationException("Binary or project file is not allowed in an automatic submission: " + file.FullName);
                if (AnyLineMatches(file.FullName, Sensitive)) throw new InvalidOperationException("Potential credential, personal path, client location, or email found: " + file.FullName);
            }
            foreach (FileSystemInfo item in entries)
            {
                DirectoryInfo directory = item as DirectoryInfo;
                if (directory != null) Check(directory);
            }
        }

        // Select-String matches line by line.
        private static bool AnyLineMatches(string path, Regex pattern)
        {
            foreach (string line in File.ReadAllLines(path, Encoding.UTF8))
                if (pattern.IsMatch(line)) return true;
            return false;
        }

        // How many files of the skill hold a sensitive-looking line (the collector's REVIEW.md column). Hidden files
        // and files over 1 MB are not looked at, as before.
        internal static int FlagCount(string path)
        {
            int count = 0;
            CountFlags(new DirectoryInfo(path), ref count);
            return count;
        }

        private static void CountFlags(DirectoryInfo folder, ref int count)
        {
            foreach (FileInfo file in folder.GetFiles())
            {
                if ((file.Attributes & FileAttributes.Hidden) != 0 || file.Length > 1024 * 1024) continue;
                try { if (AnyLineMatches(file.FullName, SensitiveFlag)) count++; }
                catch (Exception) { }
            }
            foreach (DirectoryInfo child in folder.GetDirectories())
                if ((child.Attributes & FileAttributes.Hidden) == 0) CountFlags(child, ref count);
        }

        // Test-SkillLinks: the folder, or anything inside it, is a link.
        internal static bool HasLinks(string path)
        {
            if (SkillFiles.IsLink(path)) return true;
            if (Directory.Exists(path))
                foreach (string child in Directory.GetFileSystemEntries(path))
                    if (HasLinks(child)) return true;
            return false;
        }

        // Assert-ChildPath: the target stays inside the parent folder.
        internal static void AssertChildPath(string parent, string child)
        {
            string parentFull = Path.GetFullPath(parent).TrimEnd('\\', '/') + Path.DirectorySeparatorChar;
            string childFull = Path.GetFullPath(child);
            if (!childFull.StartsWith(parentFull, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unsafe target path: " + childFull);
        }
    }
}
