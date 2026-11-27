using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

// Error reports for the administrator. When a connector tool fails, what failed goes to the team skill service right
// away, so the owner sees every error and can plan a correction: the tool, the product, the error code ("[compile_error]"
// or "error"), a cleaned message of at most two lines, the connector version, and later whether the same tool then
// worked in that session ("recovered"). Never the tool's arguments, drawings, models, file names, paths or chat text.
// Only computers joined to the team skill service record. A report never changes or delays the tool's own answer.
namespace SmartConnector
{
    internal static class Failures
    {
        internal const int MessageMax = 240;
        // A burst of failures in a few seconds goes in one request; after a failed upload the next try waits.
        private static readonly TimeSpan SendDelay = TimeSpan.FromSeconds(5), RetryAfterFailure = TimeSpan.FromMinutes(5);
        private static readonly object Gate = new object();
        // Tools that failed in this MCP session and have not worked since: tool -> its last failure.
        private static readonly Dictionary<string, Dictionary<string, object>> Open = new Dictionary<string, Dictionary<string, object>>(StringComparer.Ordinal);
        private static bool _sending;
        private static DateTime _retryAt = DateTime.MinValue;

        // A tool call failed. Expected guard answers (the Revit rules not read yet) are not errors and are not reported.
        internal static void Failed(string tool, string product, string message)
        {
            try
            {
                if (message == McpServer.RevitRulesFirst) return;
                Dictionary<string, object> entry = Describe(tool, product, message, "failed");
                lock (Gate) Open[(string)entry["tool"]] = entry;
                if (Append(entry)) SendSoon();
            }
            catch (Exception) { }
        }

        // A tool call worked. When the same tool failed earlier in this session, that failure is reported as recovered.
        internal static void Worked(string tool)
        {
            try
            {
                Dictionary<string, object> last;
                lock (Gate)
                {
                    if (tool == null || !Open.TryGetValue(tool, out last)) return;
                    Open.Remove(tool);
                }
                Dictionary<string, object> entry = new Dictionary<string, object>(last);
                entry["outcome"] = "recovered";
                entry["day"] = Today;
                Append(entry);
            }
            catch (Exception) { }
        }

        private static string Today { get { return DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture); } }

        internal static Dictionary<string, object> Describe(string tool, string product, string message, string outcome)
        {
            string text = (message ?? "").Trim();
            string code = "error";
            Match typed = Regex.Match(text, @"^\[([a-z_]{1,40})\]\s*");
            if (typed.Success) { code = typed.Groups[1].Value; text = text.Substring(typed.Length); }
            return Json.Object(
                "tool", Regex.IsMatch(tool ?? "", "^[A-Za-z0-9_.:-]{1,100}$") ? tool : "unknown",
                "product", product == "revit" || product == "autocad" || product == MaxBridge.Product ? product : "connector",
                "code", code,
                "message", Clean(text, Environment.UserName, Environment.MachineName),
                "outcome", outcome,
                "day", Today);
        }

        // The first two lines of the message, with anything that can name a project, a person, a file or a model element
        // replaced by a placeholder. services\skill-sharing-cloudflare\src\failures.mjs applies the same rules again on
        // the service; keep the two in step (the service's tests\error-messages.json holds the shared examples).
        internal static string Clean(string message, string windowsUser, string pcName)
        {
            string[] lines = (message ?? "").Replace("\r", "").Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).Take(2).ToArray();
            string text = String.Join(" | ", lines);
            if (text.Length > 1000) text = text.Substring(0, 1000);
            text = Regex.Replace(text, @"https?://\S+", "<url>", RegexOptions.IgnoreCase);
            text = Regex.Replace(text, @"[\w.+-]+@[\w-]+(?:\.[\w-]+)+", "<email>");
            // A path runs over folder names with spaces up to its last separator, then to the end of the file name.
            text = Regex.Replace(text, @"\\\\(?:[^\\/\n""'<>|]*[\\/])*[^\s\\/""'<>|]*", "<path>");
            text = Regex.Replace(text, @"(?<![A-Za-z])[A-Za-z]:[\\/](?:[^\\/\n""'<>|]*[\\/])*[^\s\\/""'<>|]*", "<path>");
            text = Regex.Replace(text, @"""[^""\n]{0,300}""|“[^”\n]{0,300}”|‘[^’\n]{0,300}’|(?<![A-Za-z])'[^'\n]{0,300}'(?![A-Za-z])", "<text>");
            text = Regex.Replace(text, @"[^\s<>""'/\\|]+\.(?:dwg|dxf|dwt|rvt|rfa|rte|rft|ifc|nwc|nwd|max|fbx|obj|3ds|skp|pdf|xlsx?|docx?|csv|txt|json|png|jpe?g)\b", "<file>", RegexOptions.IgnoreCase);
            text = Regex.Replace(text, @"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b|\b[0-9a-fA-F]{16,}\b", "<id>");
            if (windowsUser != null && windowsUser.Trim().Length >= 3) text = Regex.Replace(text, Regex.Escape(windowsUser.Trim()), "<user>", RegexOptions.IgnoreCase);
            if (pcName != null && pcName.Trim().Length >= 3) text = Regex.Replace(text, Regex.Escape(pcName.Trim()), "<pc>", RegexOptions.IgnoreCase);
            // A value at the end of a sentence after a colon ("Layer not found: A-WALL.") is a name from the drawing or
            // model, unless it is a lowercase argument or tool name ("Missing argument: points").
            text = Regex.Replace(text, @"(?<=: )(?![a-z_][a-z0-9_]*(?:$|[.,;]))[^\s:<>,;]+?(?=$|[.,;](?:\s|$))", "<value>");
            text = Regex.Replace(text, @"(?<![A-Za-z0-9])\d+(?:[.,]\d+)*", "<n>");
            text = Regex.Replace(text, @"\s+", " ").Trim();
            return text.Length > MessageMax ? text.Substring(0, MessageMax).TrimEnd() + "..." : text;
        }

        // failures.jsonl in the skill state folder, one line per event. Only on computers joined to the service.
        private static bool Append(Dictionary<string, object> entry)
        {
            string state = Paths.SkillState;
            if (!File.Exists(Path.Combine(state, "service.json"))) return false;
            string line = Json.Serializer.Serialize(entry) + "\n";
            string path = FailureSender.LivePath(state);
            // Several Codex/Claude windows can append at once; retry briefly if the file is busy.
            for (int attempt = 0; attempt < 3; attempt++)
            {
                try { File.AppendAllText(path, line, new UTF8Encoding(false)); return true; }
                catch (IOException) { Thread.Sleep(50); }
            }
            return false;
        }

        // Sends what is waiting a few seconds after a failure, on a background thread. What cannot be sent now stays
        // waiting for the next failure or Skills Sync.
        private static void SendSoon()
        {
            lock (Gate)
            {
                if (_sending || DateTime.UtcNow < _retryAt) return;
                _sending = true;
            }
            Thread thread = new Thread(delegate ()
            {
                bool sent = false;
                try
                {
                    Thread.Sleep(SendDelay);
                    sent = FailureSender.Run(Paths.SkillState, null, true) == 0;
                }
                catch (Exception) { }
                finally
                {
                    lock (Gate)
                    {
                        _sending = false;
                        if (!sent) _retryAt = DateTime.UtcNow + RetryAfterFailure;
                    }
                }
            });
            thread.IsBackground = true;
            thread.Start();
        }
    }

    // Uploads the error reports to the team skill service (POST /v1/failures). Same pattern as UsageSender: the live file
    // is moved aside, merged with what is still waiting, counted per day, and the waiting file shrinks after each accepted
    // batch, so nothing is sent twice. Runs after a failure (above) and as part of Skills Sync.
    internal static class FailureSender
    {
        private sealed class Event { internal string Tool, Product, Code, Message, Outcome, Day; internal long Count; }
        internal const int MaxPending = 1000;

        internal static string LivePath(string state) { return Path.Combine(state, "failures.jsonl"); }
        private static string PendingPath(string state) { return Path.Combine(state, "failures-pending.jsonl"); }

        internal static void WriteLog(string state, string message)
        {
            try
            {
                string path = Path.Combine(state, "failure-upload.log");
                File.AppendAllText(path, "[" + SkillFiles.Stamp + "] " + message + "\r\n", SkillFiles.Utf8);
                string[] lines = SkillFiles.ReadLines(path);
                if (lines.Length > 200) File.WriteAllLines(path, lines.Skip(lines.Length - 200).ToArray(), SkillFiles.Utf8Bom);
            }
            catch (Exception) { }
        }

        // Counts per tool/product/code/message/outcome/day. The service accepts the last 30 days only; older or malformed
        // lines are dropped, and the newest MaxPending kinds are kept if a computer stays offline for long.
        private static List<Event> ReadLines(IEnumerable<string> paths)
        {
            List<string> order = new List<string>();
            Dictionary<string, Event> totals = new Dictionary<string, Event>(StringComparer.Ordinal);
            string oldest = DateTime.Now.AddDays(-28).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            foreach (string path in paths)
            {
                if (!File.Exists(path)) continue;
                foreach (string line in SkillFiles.ReadLines(path))
                {
                    if (String.IsNullOrWhiteSpace(line)) continue;
                    object entry;
                    try { entry = Json.Serializer.DeserializeObject(line); }
                    catch (Exception) { continue; }
                    Event e = new Event
                    {
                        Tool = PsJson.Text(PsJson.Value(entry, "tool")), Product = PsJson.Text(PsJson.Value(entry, "product")),
                        Code = PsJson.Text(PsJson.Value(entry, "code")), Message = PsJson.Text(PsJson.Value(entry, "message")),
                        Outcome = PsJson.Text(PsJson.Value(entry, "outcome")), Day = PsJson.Text(PsJson.Value(entry, "day")), Count = 1
                    };
                    if (!Regex.IsMatch(e.Tool, "^[A-Za-z0-9_.:-]{1,100}$") || !(e.Product == "revit" || e.Product == "autocad" || e.Product == "connector")
                        || !Regex.IsMatch(e.Code, "^[a-z_]{1,40}$") || e.Message.Length > Failures.MessageMax + 3 || !(e.Outcome == "failed" || e.Outcome == "recovered")
                        || !Regex.IsMatch(e.Day, @"^\d{4}-\d{2}-\d{2}$") || String.CompareOrdinal(e.Day, oldest) < 0) continue;
                    if (PsJson.Has(entry, "count"))
                    {
                        double number;
                        object raw = PsJson.Value(entry, "count");
                        if (raw == null || !Double.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out number)) continue;
                        e.Count = (long)Math.Round(number, MidpointRounding.ToEven);
                    }
                    if (e.Count < 1) continue;
                    string key = String.Join("\u0001", new[] { e.Tool, e.Product, e.Code, e.Message, e.Outcome, e.Day });
                    Event total;
                    if (!totals.TryGetValue(key, out total))
                    {
                        total = e; total.Count = 0;
                        totals[key] = total; order.Add(key);
                    }
                    total.Count = Math.Min(10000, total.Count + e.Count);
                }
            }
            List<Event> events = order.Select(key => totals[key]).ToList();
            return events.Count > MaxPending ? events.Skip(events.Count - MaxPending).ToList() : events;
        }

        private static object ToObject(Event e)
        {
            return Json.Object("tool", e.Tool, "product", e.Product, "code", e.Code, "message", e.Message, "outcome", e.Outcome, "day", e.Day, "count", (int)e.Count);
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

        // Returns what was done. A failed upload throws; what was not accepted stays waiting.
        internal static string Send(string state)
        {
            if (!File.Exists(Path.Combine(state, "service.json"))) return "This PC is not enrolled; errors are not reported.";
            // Move the live file aside first so new failures keep appending to a fresh failures.jsonl.
            if (File.Exists(LivePath(state)))
            {
                string taking = Path.Combine(state, "failures-taking-" + Guid.NewGuid().ToString("N") + ".jsonl");
                try { File.Move(LivePath(state), taking); }
                catch (Exception) { }
            }
            string[] leftovers = Directory.GetFiles(state, "failures-taking-*.jsonl");
            List<string> sources = new List<string> { PendingPath(state) };
            sources.AddRange(leftovers);
            List<Event> events = ReadLines(sources);
            SavePending(state, events);
            foreach (string file in leftovers) File.Delete(file);
            if (events.Count == 0) return "No new errors to report.";

            string token;
            SkillService service = SkillService.Read(state, out token);
            string version = Paths.Version;
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
                    List<Event> batch = events.Take(100).ToList();
                    byte[] body = SkillFiles.Utf8.GetBytes(PsJsonText.Compact(Json.Object("events", batch.Select(ToObject).ToArray())));
                    SkillHttp.Request("POST", service.Base + "/v1/failures", headers, "Autodesk-MCP-Connector/" + version, "application/json; charset=utf-8", body, 30);
                    sent += batch.Count;
                    events = events.Skip(batch.Count).ToList();
                    SavePending(state, events);
                }
            }
            finally { headers["Authorization"] = null; }
            return "Reported " + sent + " error record(s).";
        }

        // The exit code; output goes to the sink unless quiet (sink may be null when quiet). A failure is logged.
        internal static int Run(string state, SkillSink sink, bool quiet)
        {
            // One upload at a time across every connector process and Skills Sync on this computer.
            using (Mutex mutex = new Mutex(false, @"Local\SmartConnectorErrorReports"))
            {
                bool acquired = false;
                try
                {
                    try { acquired = mutex.WaitOne(TimeSpan.FromSeconds(30)); }
                    catch (AbandonedMutexException) { acquired = true; }
                    if (!acquired) return 1;
                    return RunLocked(state, sink, quiet);
                }
                finally { if (acquired) mutex.ReleaseMutex(); }
            }
        }

        private static int RunLocked(string state, SkillSink sink, bool quiet)
        {
            try
            {
                Directory.CreateDirectory(state);
                string result = Send(state);
                WriteLog(state, result);
                if (!quiet && sink != null) sink.Out(result);
                return 0;
            }
            catch (Exception exception)
            {
                int status = SkillHttp.StatusOf(exception);
                string message = "Error report failed" + (status > 0 ? " (HTTP " + status + ")" : "") + "; unsent reports are kept for the next try.";
                WriteLog(state, message);
                if (!quiet) SkillConsole.Err(message);
                return 1;
            }
        }
    }
}
