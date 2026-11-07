using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

// Skills Sync as compiled code: scripts\central-skill-sync.ps1 (collect what is saved on this PC, send it for review,
// download the approved library), scripts\weekly-skill-collection.ps1 (the runner behind the Skills Sync button, its
// settings, log and result file) and scripts\send-usage.ps1 (the usage counts for the administrator's dashboard).
namespace SmartConnector
{
    internal sealed class LibrarySummary
    {
        internal int Total, Added, Updated, Preserved, Current;
    }

    internal sealed class CentralOptions
    {
        internal string RepositoryRoot, StateRoot;
        internal string[] AdditionalSkillRoots = new string[0], Categories = new string[0];
        internal bool Preview;
    }

    internal static class CentralSync
    {
        private static IEnumerable<object> Items(object value)
        {
            System.Collections.IEnumerable list = value as System.Collections.IEnumerable;
            if (list == null || value is string || value is IDictionary<string, object>) return new object[0];
            return list.Cast<object>();
        }

        // Test-RemoteSkillFiles: what the service sends is checked as strictly as a local candidate.
        internal static void CheckRemoteSkill(object skill)
        {
            string name = PsJson.Text(PsJson.Value(skill, "name"));
            if (!Regex.IsMatch(name, "^[a-z0-9]+(?:-[a-z0-9]+)*$")) throw new InvalidOperationException("Invalid approved skill name.");
            IDictionary<string, object> files = PsJson.Value(skill, "files") as IDictionary<string, object>;
            if (files == null || !files.Keys.Any(k => String.Equals(k, "SKILL.md", StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("Approved skill has no SKILL.md.");
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (KeyValuePair<string, object> file in files)
            {
                string[] parts = file.Key.Split('/');
                if (Regex.IsMatch(file.Key, @"[\\:]") || parts.Any(p => p.Length == 0 || p == "." || p == ".." || p.StartsWith(".", StringComparison.Ordinal)) || seen.Contains(file.Key.ToLowerInvariant()))
                    throw new InvalidOperationException("Invalid approved file path.");
                seen.Add(file.Key.ToLowerInvariant());
                if (!SkillSafety.TextExtensions.Contains(Path.GetExtension(file.Key).ToLowerInvariant())) throw new InvalidOperationException("Unsupported approved file type.");
                string text = file.Value as string;
                if (text == null || Encoding.UTF8.GetByteCount(text) > 256 * 1024 || text.IndexOf('\0') >= 0) throw new InvalidOperationException("Invalid approved file content.");
            }
        }

        // Set-ApprovedSkillDirectory: the new folder is copied beside the old one and swapped in, so a failure never
        // leaves a half-written skill.
        private static void ReplaceFolder(string source, string destination)
        {
            string stage = destination + ".download-" + Guid.NewGuid().ToString("N");
            string backup = destination + ".previous-" + Guid.NewGuid().ToString("N");
            bool moved = false;
            try
            {
                SkillFiles.CopyFolder(source, stage);
                if (Directory.Exists(destination)) { Directory.Move(destination, backup); moved = true; }
                try { Directory.Move(stage, destination); }
                catch (Exception)
                {
                    if (moved) Directory.Move(backup, destination);
                    throw;
                }
                if (moved) SkillFiles.DeleteFolder(backup);
            }
            finally { if (Directory.Exists(stage)) SkillFiles.DeleteFolder(stage); }
        }

        private static bool AnyLink(string path)
        {
            if (SkillFiles.IsLink(path)) return true;
            return Directory.Exists(path) && Directory.GetFileSystemEntries(path, "*", SearchOption.AllDirectories).Any(SkillFiles.IsLink);
        }

        // Install-ApprovedLibrary: the downloaded skills go to the approved cache (always current) and to each client's
        // skill folder (Codex, Claude), unless that copy was edited here or is a link. Which copies this program installed
        // is recorded by hash in managed-skill-hashes.json.
        internal static LibrarySummary InstallApprovedLibrary(object library, string state, string repository, string[] clientRoots, string[] categories, SkillSink sink)
        {
            string cache = Path.Combine(state, "approved-skills");
            string ledgerPath = Path.Combine(state, "managed-skill-hashes.json");
            Dictionary<string, string> managed = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (File.Exists(ledgerPath)) managed = SkillFiles.ReadStringMap(ledgerPath);
            if (Directory.Exists(cache) && SkillFiles.IsLink(cache)) throw new InvalidOperationException("Linked cache directory refused.");
            Directory.CreateDirectory(cache);
            // Per-skill outcome for the Skills Sync summary: added, updated, preserved (local edits kept) or current.
            Dictionary<string, string> outcome = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            // Installed copies of the shipped library, which may be in category folders, by skill name.
            Dictionary<string, string> baselines = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, string> shippedCategories = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (SkillFolder shipped in SkillLibrary.SkillFolders(Path.Combine(repository, ".agents", "skills")))
            {
                baselines[shipped.Name] = shipped.Path;
                shippedCategories[shipped.Name] = shipped.Category;
            }
            List<object> selected = Items(PsJson.Value(library, "skills")).ToList();
            if (categories.Length > 0)
            {
                // Only the requested categories are downloaded; skills of other categories are left exactly as they are.
                selected = selected.Where(skill =>
                {
                    string declared = PsJson.Text(PsJson.Value(skill, "category"));
                    string shippedCategory;
                    string category = declared.Length > 0 ? declared
                        : shippedCategories.TryGetValue(PsJson.Text(PsJson.Value(skill, "name")), out shippedCategory) && shippedCategory.Length > 0 ? shippedCategory : "uncategorized";
                    return categories.Contains(category, StringComparer.OrdinalIgnoreCase);
                }).ToList();
            }
            foreach (object skill in selected)
            {
                string name = PsJson.Text(PsJson.Value(skill, "name"));
                outcome[name] = "current";
                CheckRemoteSkill(skill);
                string temp = Path.Combine(state, "download-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(temp);
                try
                {
                    foreach (KeyValuePair<string, object> file in (IDictionary<string, object>)PsJson.Value(skill, "files"))
                    {
                        string path = Path.Combine(temp, file.Key.Replace('/', Path.DirectorySeparatorChar));
                        Directory.CreateDirectory(Path.GetDirectoryName(path));
                        File.WriteAllText(path, (string)file.Value, SkillFiles.Utf8);
                    }
                    string hash = SkillHash.OfFolder(temp, false);
                    // The service-managed MCP cache always follows approved main; local authoring folders are protected below.
                    string target = Path.Combine(cache, name);
                    if (Directory.Exists(target) && SkillFiles.IsLink(target)) throw new InvalidOperationException("Linked cache path refused.");
                    ReplaceFolder(temp, target);
                    foreach (string clientRoot in clientRoots)
                    {
                        if (Directory.Exists(clientRoot) && SkillFiles.IsLink(clientRoot)) { sink.Warn("Skipped linked client skill root."); continue; }
                        Directory.CreateDirectory(clientRoot);
                        string destination = Path.Combine(clientRoot, name);
                        string key = destination;
                        bool replace = true;
                        bool existed = Directory.Exists(destination);
                        string current = "";
                        if (existed)
                        {
                            // Avoid replacing personal edits or following local links.
                            if (AnyLink(destination)) replace = false;
                            else
                            {
                                current = SkillHash.OfFolder(destination, false);
                                string baselineHash = baselines.ContainsKey(name) ? SkillHash.OfFolder(baselines[name], false) : "";
                                string managedHash;
                                replace = String.Equals(current, hash, StringComparison.OrdinalIgnoreCase) || String.Equals(current, baselineHash, StringComparison.OrdinalIgnoreCase)
                                    || (managed.TryGetValue(key, out managedHash) && String.Equals(managedHash, current, StringComparison.OrdinalIgnoreCase));
                            }
                        }
                        if (replace)
                        {
                            ReplaceFolder(temp, destination);
                            managed[key] = hash;
                            if (!existed) { if (outcome[name] == "current") outcome[name] = "added"; }
                            else if (!String.Equals(current, hash, StringComparison.OrdinalIgnoreCase) && outcome[name] != "preserved") outcome[name] = "updated";
                        }
                        else { sink.Warn("Preserved locally edited skill: " + name); outcome[name] = "preserved"; }
                    }
                }
                finally { if (Directory.Exists(temp)) SkillFiles.DeleteFolder(temp); }
            }
            string tempLedger = ledgerPath + ".tmp";
            Dictionary<string, object> ledger = new Dictionary<string, object>();
            foreach (KeyValuePair<string, string> pair in managed) ledger[pair.Key] = pair.Value;
            File.WriteAllText(tempLedger, PsJsonText.Pretty(ledger), SkillFiles.Utf8Bom);
            SkillFiles.MoveOver(tempLedger, ledgerPath);
            LibrarySummary summary = new LibrarySummary();
            summary.Total = outcome.Count;
            summary.Added = outcome.Values.Count(v => v == "added");
            summary.Updated = outcome.Values.Count(v => v == "updated");
            summary.Preserved = outcome.Values.Count(v => v == "preserved");
            summary.Current = outcome.Values.Count(v => v == "current");
            return summary;
        }

        // One machine-readable summary line for the Skills Sync windows in Revit and AutoCAD.
        private static void WriteSyncResult(SkillSink sink, Dictionary<string, object> result)
        {
            sink.Out("[SYNC_RESULT] " + PsJsonText.Compact(result));
        }

        private sealed class Variant
        {
            internal string Key;
            internal Dictionary<string, string> Files;
            internal List<string> Sources = new List<string>();
        }

        // Returns the process exit code (0); a problem throws with the message the window shows.
        internal static int Run(CentralOptions options, SkillSink sink)
        {
            string repositoryRoot = options.RepositoryRoot, stateRoot = options.StateRoot;
            Directory.CreateDirectory(stateRoot);
            string reviewRoot = Path.Combine(stateRoot, "central-review-" + Guid.NewGuid().ToString("N"));
            string exclusionList = Path.Combine(stateRoot, "excluded-skills.txt");
            CollectorOptions collect = new CollectorOptions();
            collect.RepositoryRoot = repositoryRoot; collect.OutputRoot = reviewRoot;
            collect.AdditionalSkillRoots = new[] { Path.Combine(repositoryRoot, "team-candidates") }.Concat(options.AdditionalSkillRoots).ToArray();
            collect.ExclusionListPath = exclusionList;
            SkillCollector.Run(collect, sink);
            // The collector matches folder names; also match the SKILL.md name in case a folder was renamed.
            HashSet<string> excluded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (File.Exists(exclusionList))
                foreach (string line in SkillFiles.ReadLines(exclusionList))
                {
                    string trimmed = line.Trim();
                    if (trimmed.Length > 0 && !trimmed.StartsWith("#", StringComparison.Ordinal)) excluded.Add(trimmed);
                }
            DirectoryInfo review = new DirectoryInfo(reviewRoot).GetDirectories().First();
            // Approved text already on this PC: the shipped library and the downloaded cache. Local copies of approved
            // skills can hold mojibake from an earlier download; once repaired they match and are not sent again.
            Dictionary<string, List<string>> approvedText = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
            foreach (string root in new[] { Path.Combine(repositoryRoot, ".agents", "skills"), Path.Combine(stateRoot, "approved-skills") })
                foreach (SkillFolder approved in SkillLibrary.SkillFolders(root))
                {
                    if (!approvedText.ContainsKey(approved.Name)) approvedText[approved.Name] = new List<string>();
                    approvedText[approved.Name].Add(SkillText.Key(SkillText.Read(approved.Path)));
                }
            // Exact copies of an approved version this PC installed earlier are not personal edits, so they are not sent.
            HashSet<string> installedApproved = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string ledgerFile = Path.Combine(stateRoot, "managed-skill-hashes.json");
            if (File.Exists(ledgerFile)) foreach (string value in SkillFiles.ReadStringMap(ledgerFile).Values) installedApproved.Add(value);
            Dictionary<string, string> candidateSources = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string sourcesFile = Path.Combine(review.FullName, "sources.json");
            if (File.Exists(sourcesFile)) candidateSources = SkillFiles.ReadStringMap(sourcesFile);
            List<string> variantNames = new List<string>();
            Dictionary<string, List<Variant>> variants = new Dictionary<string, List<Variant>>(StringComparer.Ordinal);
            foreach (DirectoryInfo folder in new DirectoryInfo(Path.Combine(review.FullName, "candidates")).GetDirectories())
            {
                string name;
                try { name = SkillSafety.NameOf(folder.FullName); SkillSafety.CheckCandidate(folder.FullName); }
                catch (Exception) { sink.Warn("Skipped flagged skill: " + folder.Name); continue; }
                if (excluded.Contains(name)) { SkillFiles.DeleteFolder(folder.FullName); continue; }
                if (installedApproved.Contains(SkillHash.OfFolder(folder.FullName, false))) continue;
                Dictionary<string, string> files = SkillText.Read(folder.FullName);
                string hash = SkillText.Key(files);
                List<string> known;
                if (approvedText.TryGetValue(name, out known) && known.Contains(hash, StringComparer.Ordinal)) continue;
                if (!variants.ContainsKey(name)) { variants[name] = new List<Variant>(); variantNames.Add(name); }
                Variant variant = variants[name].FirstOrDefault(v => v.Key == hash);
                if (variant == null) { variant = new Variant { Key = hash, Files = files }; variants[name].Add(variant); }
                string source;
                if (!candidateSources.TryGetValue(folder.Name, out source)) source = "another skill folder";
                if (!variant.Sources.Contains(source)) variant.Sources.Add(source);
            }
            // Two different saved copies of one skill: the service cannot tell which is meant, so only that skill waits.
            List<Dictionary<string, object>> skills = new List<Dictionary<string, object>>();
            List<string> names = new List<string>();
            List<string> conflicts = new List<string>();
            foreach (string name in variantNames)
            {
                if (variants[name].Count > 1)
                {
                    List<string> where = new List<string>();
                    foreach (Variant variant in variants[name]) foreach (string source in variant.Sources) if (!where.Contains(source)) where.Add(source);
                    conflicts.Add(name + " (" + String.Join(", ", where.ToArray()) + ")");
                    sink.Warn("Different saved copies of one skill; not sent: " + name);
                    continue;
                }
                names.Add(name);
                Dictionary<string, object> files = new Dictionary<string, object>();
                foreach (KeyValuePair<string, string> file in variants[name][0].Files) files[file.Key] = file.Value;
                skills.Add(Json.Object("name", name, "files", files));
            }
            string conflictNote = conflicts.Count > 0
                ? "Not sent, because this PC has two different copies of: " + String.Join("; ", conflicts.ToArray()) + ". Keep the copy you want, delete the other, then run Skills Sync again."
                : "";
            if (options.Preview)
            {
                sink.Out(PsJsonText.Pretty(Json.Object("status", "preview", "skills", names.Cast<object>().ToArray(), "conflicts", conflicts.Cast<object>().ToArray(), "review", review.FullName)));
                return 0;
            }
            string configPath = Path.Combine(stateRoot, "service.json");
            if (!File.Exists(configPath))
            {
                WriteSyncResult(sink, Json.Object("status", "not_enrolled", "candidates", skills.Count,
                    "reason", "This computer has not joined the team skill service yet. Run the team installer, or ask your administrator."));
                throw new InvalidOperationException("Central sharing is waiting for administrator enrollment. No team GitHub sign-in is required.");
            }
            string token;
            SkillService service = SkillService.Read(stateRoot, out token);
            string version = SkillService.ConnectorVersion(repositoryRoot);
            Dictionary<string, string> headers = new Dictionary<string, string>();
            headers["Authorization"] = "Bearer " + token;
            headers["X-Connector-Version"] = version;
            token = null;
            string agent = "Autodesk-MCP-Connector/" + version;
            try
            {
                string baseAddress = service.Base;
                string submissionFailure = null;
                Dictionary<string, object> summary = Json.Object("status", "ok", "candidates", skills.Count, "withheld", conflicts.Count, "submitted", 0,
                    "submission", "none", "pull_request", "", "categories", options.Categories.Cast<object>().ToArray());
                try
                {
                    if (skills.Count > 0)
                    {
                        byte[] body = SkillFiles.Utf8.GetBytes(PsJsonText.Compact(Json.Object("skills", skills.Cast<object>().ToArray())));
                        if (body.Length > 2 * 1024 * 1024) throw new InvalidOperationException("Skill batch exceeds 2 MB. An administrator must split the review batch.");
                        object result = SkillHttp.Request("POST", baseAddress + "/v1/submissions", headers, agent, "application/json; charset=utf-8", body, 120);
                        sink.Out(PsJsonText.Pretty(result));
                        summary["submission"] = PsJson.Text(PsJson.Value(result, "status"));
                        summary["pull_request"] = PsJson.Text(PsJson.Value(result, "pull_request"));
                        if (PsJson.Text(PsJson.Value(result, "status")).Equals("submitted_for_approval", StringComparison.OrdinalIgnoreCase)) summary["submitted"] = skills.Count;
                    }
                    else sink.Out("No new local skill candidates.");
                }
                catch (Exception exception)
                {
                    submissionFailure = exception.Message; summary["submission"] = "failed";
                    sink.Warn("Submission was not completed; approved skill downloads will still be attempted.");
                }
                object approved;
                LibrarySummary library;
                try
                {
                    approved = SkillHttp.Request("GET", baseAddress + "/v1/library", headers, agent, null, null, 120);
                    string codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
                    string codexRoot = !String.IsNullOrEmpty(codexHome) ? Path.Combine(codexHome, "skills") : Path.Combine(Env.Home, ".codex", "skills");
                    library = InstallApprovedLibrary(approved, stateRoot, repositoryRoot, new[] { codexRoot, Path.Combine(Env.Home, ".claude", "skills") }, options.Categories, sink);
                }
                catch (Exception)
                {
                    summary["status"] = "failed";
                    summary["reason"] = "Approved skills could not be downloaded. Check the internet connection and try again.";
                    WriteSyncResult(sink, summary);
                    throw;
                }
                summary["approved_total"] = library.Total; summary["added"] = library.Added; summary["updated"] = library.Updated;
                summary["preserved"] = library.Preserved; summary["commit"] = PsJson.Text(PsJson.Value(approved, "commit"));
                sink.Out("Approved skill library synchronized. Commit: " + PsJson.Text(PsJson.Value(approved, "commit")));
                if (submissionFailure != null)
                {
                    summary["status"] = "partial";
                    summary["reason"] = ("Approved skills were downloaded, but your saved skills could not be sent for review: " + submissionFailure + " " + conflictNote).Trim();
                }
                else if (conflictNote.Length > 0) { summary["status"] = "partial"; summary["reason"] = conflictNote; }
                WriteSyncResult(sink, summary);
                if (submissionFailure != null) throw new InvalidOperationException("Approved skills downloaded, but submission needs attention: " + submissionFailure);
                return 0;
            }
            finally { headers["Authorization"] = null; }
        }
    }

    // The usage counts the connector recorded (skill and tool names, never arguments) go to the team skill service for
    // the administrator's dashboard. Unsent counts are kept and retried. Runs only as part of Skills Sync, which the
    // person starts; nothing is scheduled.
    internal static class UsageSender
    {
        private sealed class Event { internal string Kind, Name, Day; internal long Count; }

        private static string UsagePath(string state) { return Path.Combine(state, "usage.jsonl"); }
        private static string PendingPath(string state) { return Path.Combine(state, "usage-pending.jsonl"); }

        internal static void WriteLog(string state, string message)
        {
            try
            {
                string path = Path.Combine(state, "usage-upload.log");
                File.AppendAllText(path, "[" + SkillFiles.Stamp + "] " + message + "\r\n", SkillFiles.Utf8);
                string[] lines = SkillFiles.ReadLines(path);
                if (lines.Length > 200) File.WriteAllLines(path, lines.Skip(lines.Length - 200).ToArray(), SkillFiles.Utf8Bom);
            }
            catch (Exception) { }
        }

        // Aggregates by kind/name/day. Lines from the connector have no count (one use each). The service accepts the
        // last 60 days only; older or malformed lines are dropped.
        private static List<Event> ReadLines(IEnumerable<string> paths)
        {
            List<string> order = new List<string>();
            Dictionary<string, Event> totals = new Dictionary<string, Event>(StringComparer.OrdinalIgnoreCase);
            string oldest = DateTime.Now.AddDays(-55).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            foreach (string path in paths)
            {
                if (!File.Exists(path)) continue;
                foreach (string line in SkillFiles.ReadLines(path))
                {
                    if (String.IsNullOrWhiteSpace(line)) continue;
                    object entry;
                    try { entry = Json.Serializer.DeserializeObject(line); }
                    catch (Exception) { continue; }
                    string kind = PsJson.Text(PsJson.Value(entry, "kind")), name = PsJson.Text(PsJson.Value(entry, "name")), day = PsJson.Text(PsJson.Value(entry, "day"));
                    if (!(kind.Equals("skill", StringComparison.OrdinalIgnoreCase) || kind.Equals("tool", StringComparison.OrdinalIgnoreCase))
                        || !Regex.IsMatch(name, "^[A-Za-z0-9_.:-]{1,100}$") || !Regex.IsMatch(day, @"^\d{4}-\d{2}-\d{2}$") || String.CompareOrdinal(day, oldest) < 0) continue;
                    long count = 1;
                    if (PsJson.Has(entry, "count"))
                    {
                        double number;
                        object raw = PsJson.Value(entry, "count");
                        if (raw == null || !Double.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out number)) continue;
                        count = (long)Math.Round(number, MidpointRounding.ToEven);
                    }
                    if (count < 1) continue;
                    string key = kind + "|" + name + "|" + day;
                    Event total;
                    if (!totals.TryGetValue(key, out total))
                    {
                        total = new Event { Kind = kind, Name = name, Day = day };
                        totals[key] = total; order.Add(key);
                    }
                    total.Count = Math.Min(10000, total.Count + count);
                }
            }
            return order.Select(key => totals[key]).ToList();
        }

        private static object ToObject(Event e)
        {
            return Json.Object("kind", e.Kind, "name", e.Name, "day", e.Day, "count", (int)e.Count);
        }

        private static void SavePending(string state, List<Event> events)
        {
            string pending = PendingPath(state);
            if (events.Count == 0)
            {
                if (File.Exists(pending)) File.Delete(pending);
                return;
            }
            string temp = pending + ".tmp";
            File.WriteAllLines(temp, events.Select(e => PsJsonText.Compact(ToObject(e))).ToArray(), SkillFiles.Utf8);
            SkillFiles.MoveOver(temp, pending);
        }

        // Send-Usage: returns the text the script printed. A failed upload throws; what was not accepted stays pending.
        internal static string Send(string state)
        {
            if (!File.Exists(Path.Combine(state, "service.json"))) return "This PC is not enrolled; usage is not reported.";
            // Move the live file aside first so new uses keep appending to a fresh usage.jsonl.
            string taking = null;
            if (File.Exists(UsagePath(state)))
            {
                taking = Path.Combine(state, "usage-taking-" + Guid.NewGuid().ToString("N") + ".jsonl");
                try { File.Move(UsagePath(state), taking); }
                catch (Exception) { taking = null; }
            }
            string[] leftovers = Directory.GetFiles(state, "usage-taking-*.jsonl");
            List<string> sources = new List<string> { PendingPath(state) };
            sources.AddRange(leftovers);
            List<Event> events = ReadLines(sources);
            SavePending(state, events);
            foreach (string file in leftovers) File.Delete(file);
            if (events.Count == 0) return "No new usage to report.";

            string token;
            SkillService service = SkillService.Read(state, out token);
            string version = "unknown";
            string settings = Path.Combine(state, "settings.json");
            if (File.Exists(settings))
            {
                string root = PsJson.Text(PsJson.Value(SkillFiles.ReadJson(settings), "repository_root"));
                if (root.Length > 0) version = SkillService.ConnectorVersion(root);
            }
            Dictionary<string, string> headers = new Dictionary<string, string>();
            headers["Authorization"] = "Bearer " + token;
            headers["X-Connector-Version"] = version;
            token = null;
            int sent = 0;
            try
            {
                while (events.Count > 0)
                {
                    List<Event> batch = events.Take(500).ToList();
                    byte[] body = SkillFiles.Utf8.GetBytes(PsJsonText.Compact(Json.Object("events", batch.Select(ToObject).ToArray())));
                    SkillHttp.Request("POST", service.Base + "/v1/usage", headers, "Autodesk-MCP-Connector/" + version, "application/json; charset=utf-8", body, 60);
                    sent += batch.Count;
                    // Shrink the pending file after each accepted batch, so a later failure never resends it.
                    events = events.Skip(batch.Count).ToList();
                    SavePending(state, events);
                }
            }
            finally { headers["Authorization"] = null; }
            return "Reported " + sent + " usage record(s).";
        }

        // send-usage.ps1 -Action Run: the exit code. Output goes to the sink; a failure is logged and counted.
        internal static int Run(string state, SkillSink sink, bool quiet)
        {
            try
            {
                Directory.CreateDirectory(state);
                string result = Send(state);
                WriteLog(state, result);
                if (!quiet) sink.Out(result);
                return 0;
            }
            catch (Exception exception)
            {
                int status = SkillHttp.StatusOf(exception);
                string message = "Usage report failed" + (status > 0 ? " (HTTP " + status + ")" : "") + "; unsent counts are kept for the next run.";
                WriteLog(state, message);
                if (!quiet) SkillConsole.Err(message);
                return 1;
            }
        }
    }

    internal sealed class WeeklyOptions
    {
        internal string Action = "Status", Product = "", RepositoryRoot, StateRoot, Reminder = "";
        internal string[] AdditionalSkillRoots = new string[0];
    }

    // The Skills Sync button and its settings. Sync uploads and downloads now; Configure saves the settings and the weekly
    // reminder; Enable and Disable switch only the reminder. Nothing is scheduled: the reminder appears when Revit, AutoCAD
    // or Smart Connector opens and the last successful sync is more than a week old.
    internal static class WeeklyRunner
    {
        private static void WriteSettings(WeeklyOptions o, bool reminderOn)
        {
            Directory.CreateDirectory(o.StateRoot);
            Dictionary<string, object> settings = Json.Object("repository_root", o.RepositoryRoot, "repository_url", "https://github.com/EhabHassan007/Autodesk-MCP.git",
                "reviewer", "EhabHassan007", "additional_skill_roots", o.AdditionalSkillRoots.Cast<object>().ToArray(), "enabled", reminderOn);
            File.WriteAllText(Path.Combine(o.StateRoot, "settings.json"), PsJsonText.Pretty(settings), SkillFiles.Utf8);
        }

        // Days since 1970-01-01 (UTC) of the last successful sync; the Revit add-in and the AutoCAD panel read it too.
        private static void WriteLastSyncDay(string state, DateTime when)
        {
            double days = (when.ToUniversalTime() - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalDays;
            File.WriteAllText(Path.Combine(state, "last-sync.txt"), days.ToString("0.000", CultureInfo.InvariantCulture), SkillFiles.Utf8);
        }

        private static string[] RootsOf(object value)
        {
            System.Collections.IEnumerable list = value as System.Collections.IEnumerable;
            if (list == null || value is string) return value is string ? new[] { (string)value } : new string[0];
            return list.Cast<object>().Where(v => v != null).Select(v => Convert.ToString(v, CultureInfo.InvariantCulture)).ToArray();
        }

        // weekly-skill-collection.ps1: returns the exit code.
        internal static int Run(WeeklyOptions o, SkillSink sink)
        {
            string settingsPath = Path.Combine(o.StateRoot, "settings.json");
            string logPath = Path.Combine(o.StateRoot, "weekly.log");
            string resultPath = Path.Combine(o.StateRoot, "last-result.json");
            string lastSyncPath = Path.Combine(o.StateRoot, "last-sync.txt");
            object saved = null;
            if (File.Exists(settingsPath)) { try { saved = SkillFiles.ReadJson(settingsPath); } catch (Exception) { } }
            string action = o.Action;
            if (action == "Configure" || action == "Enable" || action == "Disable")
            {
                if (action == "Configure" && !Directory.Exists(Path.Combine(o.RepositoryRoot, ".agents", "skills"))) throw new InvalidOperationException("Install Smart Connector before setting up Skills Sync.");
                if (action != "Configure" && saved != null)
                {
                    string root = PsJson.Text(PsJson.Value(saved, "repository_root"));
                    if (root.Length > 0) o.RepositoryRoot = root;
                    if (o.AdditionalSkillRoots.Length == 0) o.AdditionalSkillRoots = RootsOf(PsJson.Value(saved, "additional_skill_roots"));
                }
                bool on = action == "Enable" ? true : action == "Disable" ? false
                    : o.Reminder.Length > 0 ? o.Reminder == "On" : saved != null ? PsJson.NotFalse(PsJson.Value(saved, "enabled")) : true;
                WriteSettings(o, on);
                // A PC updated from an earlier version keeps its last sync date, so it is not reminded straight away.
                if (!File.Exists(lastSyncPath) && File.Exists(resultPath))
                {
                    try
                    {
                        object last = SkillFiles.ReadJson(resultPath);
                        string status = PsJson.Text(PsJson.Value(last, "sync_status")), completed = PsJson.Text(PsJson.Value(last, "completed_at"));
                        if ((status.Equals("ok", StringComparison.OrdinalIgnoreCase) || status.Equals("partial", StringComparison.OrdinalIgnoreCase)) && completed.Length > 0)
                            WriteLastSyncDay(o.StateRoot, DateTime.Parse(completed, CultureInfo.CurrentCulture));
                    }
                    catch (Exception) { }
                }
                sink.Out(on ? "Skills Sync reminder is on: you are reminded when your last sync is more than a week old." : "Skills Sync reminder is off. Use Skills Sync whenever you like.");
                return 0;
            }
            if (action == "Status")
            {
                if (File.Exists(resultPath)) sink.Out(SkillFiles.ReadText(resultPath));
                else sink.Out("No Skills Sync has completed yet.");
                sink.Out("Log: " + logPath);
                return 0;
            }
            Directory.CreateDirectory(o.StateRoot);
            FileStream gate = null;
            int exitCode = 0;
            try
            {
                try { gate = new FileStream(Path.Combine(o.StateRoot, "run.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
                catch (IOException) { sink.Out("A collection run is already active."); return 0; }
                if (File.Exists(settingsPath))
                {
                    object config = SkillFiles.ReadJson(settingsPath);
                    o.RepositoryRoot = PsJson.Text(PsJson.Value(config, "repository_root"));
                    o.AdditionalSkillRoots = RootsOf(PsJson.Value(config, "additional_skill_roots"));
                }
                if (!Directory.Exists(Path.Combine(o.RepositoryRoot, ".agents", "skills"))) throw new InvalidOperationException("The installed connector skill library is missing.");
                // The PowerShell runner restored a missing helper script from the installed connector here. The compiled
                // program has no helper scripts to lose.
                // Usage is reported first and independently, so a failed skill submission never holds it back.
                if (action == "Run" || action == "Sync")
                {
                    try { UsageSender.Run(o.StateRoot, sink, true); } catch (Exception) { }
                }
                List<string> categories = SkillLibrary.SyncCategories(o.Product, SkillLibrary.InstalledProducts());
                // Collect lines as they arrive so the summary survives even when the sync then fails.
                List<string> output = new List<string>();
                output.Add("Downloading approved skills in: " + String.Join(", ", categories.ToArray()));
                string failure = null;
                try
                {
                    CentralOptions central = new CentralOptions();
                    central.RepositoryRoot = o.RepositoryRoot; central.StateRoot = o.StateRoot; central.AdditionalSkillRoots = o.AdditionalSkillRoots;
                    central.Categories = categories.ToArray(); central.Preview = action == "Preview";
                    CentralSync.Run(central, new SkillSink(output));
                }
                catch (Exception exception) { failure = exception.Message; }
                List<string> all = new List<string>(output);
                if (failure != null) all.Add("FAILED: " + failure);
                string text = String.Join(Environment.NewLine, all.ToArray());
                File.AppendAllText(logPath, "[" + SkillFiles.Stamp + "] " + action + "\r\n" + text + "\r\n", SkillFiles.Utf8);
                Dictionary<string, object> result = Json.Object("completed_at", SkillFiles.Stamp, "action", action, "product", o.Product,
                    "status", failure != null ? "failed" : "completed", "details", text);
                string summaryLine = output.LastOrDefault(l => l.StartsWith("[SYNC_RESULT] ", StringComparison.Ordinal));
                if (summaryLine != null)
                {
                    IDictionary<string, object> summary = Json.Serializer.DeserializeObject(summaryLine.Substring(14)) as IDictionary<string, object>;
                    if (summary != null) foreach (KeyValuePair<string, object> property in summary) result["sync_" + property.Key] = property.Value;
                }
                // The Skills Sync window shows sync_reason; without it, it can only guess at the internet connection.
                if (failure != null && !Truthy(result, "sync_reason")) { result["sync_status"] = "failed"; result["sync_reason"] = "Skills Sync stopped: " + failure; }
                File.WriteAllText(resultPath, PsJsonText.Pretty(result), SkillFiles.Utf8);
                string syncStatus = result.ContainsKey("sync_status") ? PsJson.Text(result["sync_status"]) : "";
                if ((action == "Run" || action == "Sync") && failure == null && (syncStatus.Equals("ok", StringComparison.OrdinalIgnoreCase) || syncStatus.Equals("partial", StringComparison.OrdinalIgnoreCase)))
                    WriteLastSyncDay(o.StateRoot, DateTime.UtcNow);
                sink.Out(text);
                if (failure != null) exitCode = 1;
            }
            catch (Exception exception)
            {
                string message = exception.Message;
                try
                {
                    File.AppendAllText(logPath, "[" + SkillFiles.Stamp + "] FAILED: " + message + "\r\n", SkillFiles.Utf8);
                    File.WriteAllText(resultPath, PsJsonText.Pretty(Json.Object("completed_at", SkillFiles.Stamp, "action", action, "status", "failed", "details", message,
                        "sync_status", "failed", "sync_reason", "Skills Sync stopped: " + message)), SkillFiles.Utf8);
                }
                catch (Exception) { }
                SkillConsole.Err(message);
                exitCode = 1;
            }
            finally
            {
                try
                {
                    if (File.Exists(logPath))
                    {
                        string[] lines = SkillFiles.ReadLines(logPath);
                        if (lines.Length > 1000) File.WriteAllLines(logPath, lines.Skip(lines.Length - 1000).ToArray(), SkillFiles.Utf8Bom);
                    }
                }
                catch (Exception) { }
                if (gate != null) gate.Dispose();
            }
            return exitCode;
        }

        private static bool Truthy(Dictionary<string, object> result, string key)
        {
            object value;
            return result.TryGetValue(key, out value) && PsJson.Truthy(value);
        }
    }
}
