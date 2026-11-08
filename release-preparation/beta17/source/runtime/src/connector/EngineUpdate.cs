using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

// The public release channel and the files of the install folder: version rules, latest.json, download and SHA-256
// check, and the replacement of the installed files IN PLACE.
//
// The PowerShell script moved the whole install folder aside and put the new one in its place. That cannot work now:
// a running SmartConnector.exe (the window running the update, and every MCP server Claude or Codex started) holds
// files in the folder open. So an update stages the new files, stops the OTHER SmartConnector.exe processes of this
// install, and replaces the files one by one. A file that is in use is renamed aside to <name>.old (Windows allows
// renaming a running program) and the new file is written under its name. Everything renamed aside is put back if
// the replacement fails midway; after success the .old files are deleted, and any that are still locked are deleted
// the next time any SmartConnector.exe command starts (EngineCleanup).
namespace SmartConnector
{
    internal sealed class ConnectorVersion
    {
        internal string Normalized, Major, Minor, Patch, PreRelease;
    }

    internal sealed class PublicRelease
    {
        internal string Version, DownloadUrl, Sha256;
    }

    internal static class EngineNet
    {
        // Only for the tests: lets the release channel and the team service be a local address (a file or a loopback
        // web server). The real channel is always HTTPS.
        private const string TestSwitch = "SMARTCONNECTOR_TEST_ALLOW_LOCAL_URLS";

        private static bool LocalTestUrl(Uri uri)
        {
            if (Environment.GetEnvironmentVariable(TestSwitch) != "1") return false;
            if (uri.Scheme == Uri.UriSchemeFile) return true;
            return uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback;
        }

        internal static bool IsSecure(Uri uri) { return uri.Scheme == Uri.UriSchemeHttps || LocalTestUrl(uri); }

        internal static void PrepareTls()
        {
            // TLS 1.2 (3072) for Windows PowerShell 5.1 era machines that default to older protocols.
            try { ServicePointManager.SecurityProtocol = ServicePointManager.SecurityProtocol | (SecurityProtocolType)3072; }
            catch (Exception) { }
        }

        private static WebRequest Open(Uri uri)
        {
            PrepareTls();
            WebRequest request = WebRequest.Create(uri);
            HttpWebRequest http = request as HttpWebRequest;
            if (http != null) http.UserAgent = "SmartConnector/" + Paths.Version;
            return request;
        }

        internal static byte[] Download(Uri uri)
        {
            using (WebResponse response = Open(uri).GetResponse())
            using (Stream stream = response.GetResponseStream())
            using (MemoryStream memory = new MemoryStream())
            {
                stream.CopyTo(memory);
                return memory.ToArray();
            }
        }

        internal static void DownloadFile(Uri uri, string path)
        {
            using (WebResponse response = Open(uri).GetResponse())
            using (Stream stream = response.GetResponseStream())
            using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
                stream.CopyTo(file);
        }
    }

    internal sealed partial class InstallEngine
    {
        private static readonly string[] PreservedFolders = { "skill-review", "team-candidates", "team-collection", "backups" };

        // ---------- versions ----------

        internal static ConnectorVersion ParseVersion(string version)
        {
            string normalized = (version ?? "").Trim().TrimStart('﻿');
            if (normalized.StartsWith("v", StringComparison.OrdinalIgnoreCase)) normalized = normalized.Substring(1);
            Match match = Regex.Match(normalized, "^(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)(?:-(?<prerelease>[A-Za-z0-9.-]+))?$");
            if (!match.Success) throw new EngineException("Invalid connector version: " + version);
            return new ConnectorVersion
            {
                Normalized = normalized, Major = match.Groups["major"].Value, Minor = match.Groups["minor"].Value,
                Patch = match.Groups["patch"].Value, PreRelease = match.Groups["prerelease"].Value
            };
        }

        // 1.2.0 > 1.2.0-beta.10 > 1.2.0-beta.9 > 1.1.9. Returns -1, 0 or 1.
        internal static int CompareVersions(string left, string right)
        {
            ConnectorVersion a = ParseVersion(left), b = ParseVersion(right);
            int comparison = EngineText.CompareDigits(a.Major, b.Major);
            if (comparison != 0) return comparison;
            comparison = EngineText.CompareDigits(a.Minor, b.Minor);
            if (comparison != 0) return comparison;
            comparison = EngineText.CompareDigits(a.Patch, b.Patch);
            if (comparison != 0) return comparison;
            if (a.PreRelease.Length == 0 && b.PreRelease.Length == 0) return 0;
            if (a.PreRelease.Length == 0) return 1;
            if (b.PreRelease.Length == 0) return -1;
            string[] leftParts = a.PreRelease.Split('.'), rightParts = b.PreRelease.Split('.');
            int count = Math.Max(leftParts.Length, rightParts.Length);
            for (int index = 0; index < count; index++)
            {
                if (index >= leftParts.Length) return -1;
                if (index >= rightParts.Length) return 1;
                string l = leftParts[index], r = rightParts[index];
                bool leftNumeric = EngineText.IsDigits(l), rightNumeric = EngineText.IsDigits(r);
                if (leftNumeric && rightNumeric) comparison = EngineText.CompareDigits(l, r);
                else if (leftNumeric) comparison = -1;
                else if (rightNumeric) comparison = 1;
                else comparison = Math.Sign(String.CompareOrdinal(l, r));
                if (comparison != 0) return comparison;
            }
            return 0;
        }

        // ---------- latest.json ----------

        private PublicRelease GetPublicReleaseManifest()
        {
            Step("Checking the Smart Connector release channel...");
            Uri manifestUri;
            if (!Uri.TryCreate(_o.ReleaseManifestUrl, UriKind.Absolute, out manifestUri)) throw new EngineException("The release manifest address is invalid: " + _o.ReleaseManifestUrl);
            if (!EngineNet.IsSecure(manifestUri)) throw new EngineException("The release manifest must use HTTPS.");

            object manifest;
            try
            {
                string content = Encoding.UTF8.GetString(EngineNet.Download(manifestUri)).TrimStart('﻿');
                manifest = OJson.Parse(content);
            }
            catch (Exception exception) { throw new EngineException("Could not read the public release channel. " + exception.Message); }

            OMap map = manifest as OMap;
            if (map == null) throw new EngineException("The public release manifest contains an invalid version.");
            string version;
            try { version = ParseVersion(PsJson.Text(map.Get("version"))).Normalized; }
            catch (EngineException) { throw new EngineException("The public release manifest contains an invalid version."); }
            string downloadUrl = (map.Get("download_url") == null ? "" : PsJson.Text(map.Get("download_url"))).Trim();
            string sha256 = (map.Get("sha256") == null ? "" : PsJson.Text(map.Get("sha256"))).Trim().ToUpperInvariant();
            if (!Regex.IsMatch(sha256, "^[0-9A-F]{64}$")) throw new EngineException("The public release manifest contains an invalid SHA-256 checksum.");
            Uri downloadUri;
            if (!Uri.TryCreate(downloadUrl, UriKind.Absolute, out downloadUri)) throw new EngineException("The public release manifest contains an invalid download address.");
            if (!EngineNet.IsSecure(downloadUri)) throw new EngineException("The public release download must use HTTPS.");
            return new PublicRelease { Version = version, DownloadUrl = downloadUri.AbsoluteUri, Sha256 = sha256 };
        }

        private void TestApprovedUpdate()
        {
            PublicRelease release = GetPublicReleaseManifest();
            OMap state = ReadUpdateState();
            string installedVersion = GetInstalledVersion();
            state.Set("repository", _o.RepositoryUrl);
            state.Set("release_manifest", _o.ReleaseManifestUrl);
            state.Set("installed_version", installedVersion);
            state.Set("last_checked_utc", Now);
            // The Smart Connector app reads this to say "version X is ready" without going online again.
            bool newer = !String.IsNullOrWhiteSpace(installedVersion) && CompareVersions(release.Version, installedVersion) > 0;
            state.Set("available_version", newer ? release.Version : "");
            WriteUpdateState(state);

            if (String.IsNullOrWhiteSpace(installedVersion))
            {
                Say("[UPDATE_STATUS_UNKNOWN] Press Install / Repair to complete this installation.");
                return;
            }
            int comparison = CompareVersions(release.Version, installedVersion);
            if (comparison > 0) Say("[UPDATE_AVAILABLE] Version " + release.Version + " is available.");
            else if (comparison < 0) Say("[UP_TO_DATE] Installed version " + installedVersion + " is newer than public version " + release.Version + "; no downgrade will be performed.");
            else Say("[UP_TO_DATE] Smart Connector " + installedVersion + " and approved skills are up to date.");
        }

        // ---------- where the files come from ----------

        private void AssertSafeRepositoryPath()
        {
            string fullPath = EngineText.Trimmed(_o.RepositoryPath);
            string driveRoot = EngineText.Trimmed(Path.GetPathRoot(fullPath));
            if (String.Equals(fullPath, driveRoot, StringComparison.OrdinalIgnoreCase) || String.Equals(fullPath, EngineText.Trimmed(Env.Home), StringComparison.OrdinalIgnoreCase))
                throw new EngineException("The installation folder is not safe to replace: " + fullPath);
        }

        // The top-level entries of a package that the install copies to the permanent folder.
        private static readonly string[] PackageEntries = { "installer", "scripts", "src", "assets", "bin", ".agents", "README.md", "SKILL-SUBMISSIONS.md", "VERSION", "TESTING.md" };

        // Returns the install folder to work with. Install: a downloaded package is copied to the permanent folder (the
        // setup .exe already put the files there). Update: the public release is downloaded when it is newer.
        private string GetRepository()
        {
            // A downloaded package already contains everything needed for installation. Copy it to a permanent location
            // without requiring private GitHub access. The package is the folder this program runs from.
            string packageRoot = Paths.Root;
            if (_o.Action == "Install" && !_o.SkipRepositoryUpdate && Directory.Exists(Path.Combine(packageRoot, ".agents", "skills")))
            {
                string source = EngineText.Trimmed(packageRoot), destination = EngineText.Trimmed(_o.RepositoryPath);
                if (!String.Equals(source, destination, StringComparison.OrdinalIgnoreCase))
                {
                    if (source.StartsWith(destination + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                        destination.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                        throw new EngineException("The installation folder cannot be inside or contain the downloaded package.");
                    Step("Installing the downloaded package to a permanent local folder...");
                    Directory.CreateDirectory(destination);
                    StopSmartConnectorServers();
                    // The shipped skill library is replaced, not merged: an older install keeps skills flat, and merging
                    // would leave every skill twice next to the new category folders. Approved team skills live elsewhere.
                    ReplaceFiles(source, destination, PackageEntries, false, new[] { Path.Combine(".agents", "skills") });
                    // The team join code stays in the downloaded installer only, even when joining was skipped.
                    string copiedJoin = Path.Combine(destination, "installer", "team-join.json");
                    if (File.Exists(copiedJoin)) File.Delete(copiedJoin);
                }
                SetInstalledRelease(File.ReadAllText(Path.Combine(destination, "VERSION")).Trim());
                return destination;
            }
            string manifest = Path.Combine(_o.RepositoryPath, ".agents", "skills");
            if (_o.SkipRepositoryUpdate)
            {
                if (!Directory.Exists(manifest)) throw new EngineException("No valid BIM-CAD MCP repository exists at " + _o.RepositoryPath + ".");
                return Path.GetFullPath(_o.RepositoryPath);
            }
            if (_o.Action == "Install" && Directory.Exists(manifest))
            {
                SetInstalledRelease(GetInstalledVersion());
                return Path.GetFullPath(_o.RepositoryPath);
            }

            _updateDownloaded = false;
            PublicRelease release = GetPublicReleaseManifest();
            if (_o.Action == "Update")
            {
                string installedVersion = GetInstalledVersion();
                if (!String.IsNullOrWhiteSpace(installedVersion))
                {
                    int comparison = CompareVersions(release.Version, installedVersion);
                    if (comparison <= 0)
                    {
                        if (comparison < 0) Step("Installed version " + installedVersion + " is newer than public version " + release.Version + "; the update was skipped to prevent a downgrade.");
                        else Step("Smart Connector " + installedVersion + " is already up to date.");
                        if (!Directory.Exists(_o.RepositoryPath)) throw new EngineException("Cannot find path '" + _o.RepositoryPath + "' because it does not exist.");
                        return Path.GetFullPath(_o.RepositoryPath);
                    }
                }
            }
            string installedRoot = InstallPublicRelease(release);
            _updateDownloaded = true;
            return installedRoot;
        }

        // ---------- the public release ----------

        private static string FirstPayloadFolder(string start)
        {
            // The folder that holds the skill library, searched top-down.
            Queue<string> queue = new Queue<string>();
            queue.Enqueue(start);
            while (queue.Count > 0)
            {
                string folder = queue.Dequeue();
                foreach (string child in Directory.GetDirectories(folder).OrderBy(n => n, StringComparer.OrdinalIgnoreCase))
                {
                    if (Directory.Exists(Path.Combine(child, ".agents", "skills"))) return child;
                    queue.Enqueue(child);
                }
            }
            return null;
        }

        // Unpacks a ZIP, refusing any entry that would land outside the folder.
        internal static void ExtractZip(string zipPath, string destination)
        {
            string root = EngineText.Trimmed(destination) + Path.DirectorySeparatorChar;
            using (ZipArchive archive = ZipFile.OpenRead(zipPath))
            {
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string target = Path.GetFullPath(Path.Combine(destination, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
                    if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new EngineException("The download contains an unsafe path: " + entry.FullName);
                    if (entry.FullName.EndsWith("/") || entry.FullName.EndsWith("\\")) { Directory.CreateDirectory(target); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    using (Stream input = entry.Open())
                    using (FileStream output = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                        input.CopyTo(output);
                }
            }
        }

        private static string Sha256Hex(string path)
        {
            using (FileStream stream = File.OpenRead(path))
            using (SHA256 algorithm = SHA256.Create())
                return EngineText.Hex(algorithm.ComputeHash(stream), true);
        }

        private string InstallPublicRelease(PublicRelease release)
        {
            AssertSafeRepositoryPath();
            string temporaryRoot = Path.Combine(Path.GetTempPath(), "autodesk-mcp-release-" + Guid.NewGuid().ToString("N"));
            string releaseArchive = Path.Combine(temporaryRoot, "release.zip");
            string outerRoot = Path.Combine(temporaryRoot, "outer"), payloadRoot = Path.Combine(temporaryRoot, "payload");
            Directory.CreateDirectory(outerRoot); Directory.CreateDirectory(payloadRoot);
            try
            {
                Step("Downloading approved public release " + release.Version + "...");
                EngineNet.DownloadFile(new Uri(release.DownloadUrl), releaseArchive);
                if (!File.Exists(releaseArchive) || new FileInfo(releaseArchive).Length == 0) throw new EngineException("The public release download is empty.");

                string actualHash = Sha256Hex(releaseArchive);
                if (!String.Equals(actualHash, release.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new EngineException("Release checksum verification failed. Expected " + release.Sha256 + ", received " + actualHash + ".");
                Step("Release checksum verification passed.");

                ExtractZip(releaseArchive, outerRoot);
                string payloadArchive = new DirectoryInfo(outerRoot).GetFiles("Autodesk-MCP-Payload.zip", SearchOption.AllDirectories).Select(f => f.FullName).FirstOrDefault();
                if (payloadArchive == null) throw new EngineException("The public release does not contain Autodesk-MCP-Payload.zip.");
                ExtractZip(payloadArchive, payloadRoot);
                string downloadedRoot = FirstPayloadFolder(payloadRoot);
                if (downloadedRoot == null) throw new EngineException("The public release payload does not contain the approved skill library.");
                string payloadVersion = File.ReadAllText(Path.Combine(downloadedRoot, "VERSION")).Trim();
                if (!String.Equals(payloadVersion, release.Version, StringComparison.OrdinalIgnoreCase))
                    throw new EngineException("Release version verification failed. Manifest says " + release.Version + ", payload says " + payloadVersion + ".");

                Directory.CreateDirectory(Path.GetDirectoryName(EngineText.Trimmed(_o.RepositoryPath)));
                Directory.CreateDirectory(_o.RepositoryPath);
                StopSmartConnectorServers();
                // The preserved folders (skill-review, team-candidates, team-collection, backups) are never touched: only
                // the files of the release are replaced, so there is nothing to move aside and back.
                ReplaceFiles(downloadedRoot, _o.RepositoryPath, null, true, null);

                OMap source = new OMap();
                source.Set("release_manifest", _o.ReleaseManifestUrl);
                source.Set("version", release.Version);
                source.Set("sha256", release.Sha256);
                source.Set("downloaded_utc", Now);
                source.Set("method", "public-release");
                File.WriteAllText(Path.Combine(_o.RepositoryPath, ".bim-cad-source.json"), OJson.Write(source) + "\r\n", EngineText.Utf8Bom);

                SetInstalledRelease(release.Version, release.Sha256);
                return Path.GetFullPath(_o.RepositoryPath);
            }
            finally
            {
                try { if (Directory.Exists(temporaryRoot)) Directory.Delete(temporaryRoot, true); } catch (Exception) { }
            }
        }

        // ---------- stopping the programs that hold the install folder ----------

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessBasicInformation
        {
            internal IntPtr ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, InheritedFromUniqueProcessId;
        }

        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(IntPtr process, int informationClass, ref ProcessBasicInformation information, int length, out int returned);

        private static int ParentOf(Process process)
        {
            try
            {
                ProcessBasicInformation information = new ProcessBasicInformation();
                int returned;
                if (NtQueryInformationProcess(process.Handle, 0, ref information, Marshal.SizeOf(typeof(ProcessBasicInformation)), out returned) != 0) return -1;
                return (int)information.InheritedFromUniqueProcessId.ToInt64();
            }
            catch (Exception) { return -1; }
        }

        // This program and the programs that started it (the update window runs this as its child) must stay.
        private static HashSet<int> SelfAndAncestors()
        {
            HashSet<int> keep = new HashSet<int>();
            Process current = Process.GetCurrentProcess();
            keep.Add(current.Id);
            int id = current.Id;
            for (int depth = 0; depth < 8; depth++)
            {
                int parent;
                try { using (Process process = Process.GetProcessById(id)) parent = ParentOf(process); }
                catch (Exception) { break; }
                if (parent <= 0 || keep.Contains(parent)) break;
                keep.Add(parent);
                id = parent;
            }
            return keep;
        }

        // A running SmartConnector.exe holds its files. Before the install folder is changed, stop the OTHER
        // SmartConnector.exe processes whose program is inside this install (the MCP servers the AI apps started); the AI
        // apps start them again when they next open. This process, and the ones that started it, keep running: their own
        // exe is renamed aside by ReplaceFiles instead.
        private void StopSmartConnectorServers()
        {
            string folder = EngineText.Trimmed(_o.RepositoryPath) + Path.DirectorySeparatorChar;
            HashSet<int> keep = SelfAndAncestors();
            Process[] processes;
            try { processes = Process.GetProcessesByName("SmartConnector"); }
            catch (Exception) { return; }
            foreach (Process process in processes)
            {
                try
                {
                    if (keep.Contains(process.Id)) continue;
                    string path = null;
                    try { path = process.MainModule.FileName; } catch (Exception) { }
                    if (path != null && path.StartsWith(folder, StringComparison.OrdinalIgnoreCase))
                    {
                        process.Kill();
                        process.WaitForExit(5000);
                    }
                }
                catch (Exception exception) { Step("Could not stop Smart Connector process " + process.Id + ": " + exception.Message); }
                finally { process.Dispose(); }
            }
        }

        // ---------- replacing files in place ----------

        private sealed class Change
        {
            internal string Target, Aside;     // Aside is set when the old file was renamed aside
            internal bool Created;             // the new file was written at Target
        }

        private static bool SameContent(string a, string b)
        {
            try
            {
                FileInfo x = new FileInfo(a), y = new FileInfo(b);
                if (x.Length != y.Length) return false;
                using (FileStream s = new FileStream(a, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (FileStream t = new FileStream(b, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    byte[] left = new byte[65536], right = new byte[65536];
                    while (true)
                    {
                        int count = s.Read(left, 0, left.Length);
                        int other = 0;
                        while (other < count) { int got = t.Read(right, other, count - other); if (got <= 0) return false; other += got; }
                        if (count == 0) return true;
                        for (int i = 0; i < count; i++) if (left[i] != right[i]) return false;
                    }
                }
            }
            catch (Exception) { return false; }
        }

        // Moves a file out of the way under <name>.old (an older leftover of that name is removed first when it can be).
        private static string MoveAside(string path)
        {
            string aside = path + ".old";
            for (int attempt = 2; File.Exists(aside); attempt++)
            {
                try { File.Delete(aside); }
                catch (Exception) { aside = path + ".old" + attempt; }
            }
            File.Move(path, aside);
            return aside;
        }

        // Puts the files of sourceRoot into destRoot, file by file.
        //  entries   which top-level entries of sourceRoot to copy (null: all)
        //  prune     also remove files of the same entries that the new files no longer have (an update); folders
        //            the person's data lives in (and the Revit add-in builds) are never pruned
        //  replace   folders (relative to destRoot) emptied first, so the new library replaces the old one
        // Every file that is replaced or removed is renamed aside first, so a file that is locked (a running program) is
        // still replaceable and everything can be put back when something fails.
        private void ReplaceFiles(string sourceRoot, string destRoot, string[] entries, bool prune, string[] replace)
        {
            List<Change> changes = new List<Change>();
            List<string> sourceTopLevel = new List<string>();
            try
            {
                Dictionary<string, string> sourceFiles = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (string file in Directory.GetFiles(sourceRoot, "*", SearchOption.AllDirectories))
                {
                    string relative = file.Substring(EngineText.Trimmed(sourceRoot).Length).TrimStart('\\', '/');
                    string top = relative.Split('\\', '/')[0];
                    if (entries != null && !entries.Contains(top, StringComparer.OrdinalIgnoreCase)) continue;
                    sourceFiles[relative] = file;
                }

                // Folders whose old content goes first (the shipped skill library).
                if (replace != null)
                    foreach (string folder in replace)
                    {
                        string target = Path.Combine(destRoot, folder);
                        if (!Directory.Exists(target)) continue;
                        foreach (string file in Directory.GetFiles(target, "*", SearchOption.AllDirectories))
                        {
                            string relative = file.Substring(EngineText.Trimmed(destRoot).Length).TrimStart('\\', '/');
                            if (!sourceFiles.ContainsKey(relative)) RemoveFile(file, changes);
                        }
                    }

                foreach (KeyValuePair<string, string> pair in sourceFiles.OrderBy(k => k.Key, StringComparer.OrdinalIgnoreCase))
                {
                    string target = Path.Combine(destRoot, pair.Key);
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    Change change = new Change { Target = target };
                    if (File.Exists(target))
                    {
                        // An identical file stays where it is: nothing to lock, nothing to put back.
                        if (SameContent(pair.Value, target)) continue;
                        change.Aside = MoveAside(target);
                        changes.Add(change);
                    }
                    else changes.Add(change);
                    change.Created = true;
                    File.Copy(pair.Value, target, false);
                }

                if (prune)
                {
                    HashSet<string> topLevel = new HashSet<string>(sourceFiles.Keys.Select(k => k.Split('\\', '/')[0]), StringComparer.OrdinalIgnoreCase);
                    sourceTopLevel.AddRange(topLevel);
                    foreach (string top in topLevel)
                    {
                        string folder = Path.Combine(destRoot, top);
                        if (!Directory.Exists(folder)) continue;
                        foreach (string file in Directory.GetFiles(folder, "*", SearchOption.AllDirectories))
                        {
                            string relative = file.Substring(EngineText.Trimmed(destRoot).Length).TrimStart('\\', '/');
                            if (sourceFiles.ContainsKey(relative) || IsKeptDuringPrune(relative) || Regex.IsMatch(relative, @"\.old\d*$", RegexOptions.IgnoreCase)) continue;
                            RemoveFile(file, changes);
                        }
                    }
                }
            }
            catch (Exception)
            {
                // Put back what was renamed aside, newest change first, and remove what was written.
                for (int i = changes.Count - 1; i >= 0; i--)
                {
                    Change change = changes[i];
                    try
                    {
                        if (change.Created && File.Exists(change.Target)) File.Delete(change.Target);
                        if (change.Aside != null && File.Exists(change.Aside)) File.Move(change.Aside, change.Target);
                    }
                    catch (Exception) { }
                }
                throw;
            }
            // Success: the renamed files are no longer needed. One that is still in use is deleted at the next start.
            List<string> leftovers = new List<string>();
            foreach (Change change in changes)
            {
                if (change.Aside == null) continue;
                try { File.Delete(change.Aside); }
                catch (Exception) { leftovers.Add(change.Aside); }
            }
            EngineCleanup.Remember(leftovers);
            // Folders that held only files the new version no longer has (a skill that was dropped) go too.
            foreach (string folder in (replace ?? new string[0]).Concat(sourceTopLevel))
                RemoveEmptyFolders(Path.Combine(destRoot, folder));
        }

        // Deletes the empty folders below (and including) a folder, deepest first. Never a folder with anything in it.
        private static void RemoveEmptyFolders(string folder)
        {
            if (!Directory.Exists(folder)) return;
            try
            {
                foreach (string child in Directory.GetDirectories(folder)) RemoveEmptyFolders(child);
                if (Directory.GetFileSystemEntries(folder).Length == 0) Directory.Delete(folder);
            }
            catch (Exception) { }
        }

        private static void RemoveFile(string file, List<Change> changes)
        {
            Change change = new Change { Target = file };
            change.Aside = MoveAside(file);
            changes.Add(change);
        }

        // Inside a folder the release replaces, these are kept: the Revit add-in builds (made on this PC after the files
        // arrive) and anything under a preserved folder.
        private static bool IsKeptDuringPrune(string relative)
        {
            string normalized = relative.Replace('\\', '/');
            if (normalized.StartsWith("src/revit/bin/", StringComparison.OrdinalIgnoreCase)) return true;
            foreach (string folder in PreservedFolders) if (normalized.StartsWith(folder + "/", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
    }

    // The files that were renamed aside while they were in use (a running SmartConnector.exe) are deleted by the next
    // SmartConnector.exe command that starts, whichever it is. Best effort: one that is still in use waits for the next start.
    internal static class EngineCleanup
    {
        private static string ListPath { get { return Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector", "old-files.txt"); } }

        internal static void Remember(List<string> files)
        {
            if (files.Count == 0) return;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(ListPath));
                File.AppendAllLines(ListPath, files, EngineText.Utf8);
            }
            catch (Exception) { }
        }

        internal static void DeleteLeftovers()
        {
            try
            {
                List<string> remaining = new List<string>();
                if (File.Exists(ListPath))
                {
                    foreach (string line in File.ReadAllLines(ListPath, EngineText.Utf8).Distinct(StringComparer.OrdinalIgnoreCase))
                    {
                        string path = line.Trim();
                        if (path.Length == 0 || !File.Exists(path)) continue;
                        try { File.Delete(path); }
                        catch (Exception) { remaining.Add(path); }
                    }
                    if (remaining.Count == 0) File.Delete(ListPath);
                    else File.WriteAllLines(ListPath, remaining, EngineText.Utf8);
                }
                // The program's own folder: a leftover that was never recorded.
                string bin = AppDomain.CurrentDomain.BaseDirectory;
                foreach (string old in Directory.GetFiles(bin, "*.old*"))
                {
                    if (!Regex.IsMatch(Path.GetFileName(old), @"\.old\d*$", RegexOptions.IgnoreCase)) continue;
                    try { File.Delete(old); } catch (Exception) { }
                }
            }
            catch (Exception) { }
        }
    }
}
