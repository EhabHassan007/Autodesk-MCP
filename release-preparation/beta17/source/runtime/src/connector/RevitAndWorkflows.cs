using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace SmartConnector
{
    // Revit tools. Each request goes to the Smart Connector add-in inside Revit over a local named pipe:
    // one line "operation<TAB>base64(field)<TAB>..." answered by "OK<TAB>base64(json)" or "ERR<TAB>base64(message)".
    internal static class RevitBridge
    {
        internal const string Version = "2024";

        // What execute_csharp promises. The PowerShell fallback bridge carries the same text.
        internal const string ExecuteDescription = "Execute controlled Revit 2024 C# against the active document. Use read for inspection, transaction for writes inside one automatic transaction, and manual only for workflows that must manage their own transactions or family documents. Read document_info first. Code must return a string. transaction mode requires allow_model_changes=true. manual with allow_model_changes=false is a probe: family documents may be created, saved to a temporary path and closed, but every project change is rolled back and reported as [probe_changed_project], and saving or synchronizing any non-family document is cancelled; loading a family into the project needs manual with allow_model_changes=true. Does not save or synchronize unless the supplied manual code explicitly does so. " +
            "RUNNER: your code is the body of Run(UIApplication application, Document document, string parametersJson); those three are the only variables (no doc, no uidoc: use application.ActiveUIDocument). Language level is C# 5: no ?. , no string interpolation, no nameof, no expression-bodied members, no out var. Namespaces already imported: System, System.Collections.Generic, System.Globalization, System.IO, System.Linq, System.Text, Autodesk.Revit.DB, Autodesk.Revit.UI; use full names for any other. " +
            "ERRORS come typed as [compile_error], [runtime_error], [commit_failed], [probe_changed_project], [document_changed] or [busy]: a typed error is a problem in the code or in Revit, not a lost connection. A runtime error names the script line (mcp_code.cs line N, counted from the first line of your code) and the API method that threw, followed by any Revit failure messages with element ids. " +
            "TIME: the call waits wait_seconds (default 60). If Revit is still working it returns completed=false and a job_id: do NOT run the code again, follow it with get_job (where get_job is not offered, call connection_status and read the model back). background=true returns the job_id at once; a background request that Revit has not started within 5 minutes is cancelled and never runs. If Revit never started the request it returns [busy] and nothing ran. " +
            "dry_run=true (transaction mode only) runs the code, rolls back every change to the active document and returns change counts. It does not undo files the code writes or changes to other open documents (those come back as other_documents_changed); in a workshared model Revit may keep elements checked out until the next synchronise. " +
            "Keep writes small: about 40 creations per call, regenerate once per call, never delete and recreate everything in one transaction. A long script can report progress with McpProgress.Report(done, total, note).";
        private static List<Dictionary<string, object>> _tools;

        internal static List<Dictionary<string, object>> Tools
        {
            get
            {
                if (_tools != null) return _tools;
                Func<Dictionary<string, object>> str = () => Json.Object("type", "string", "minLength", 1);
                Func<Dictionary<string, object>> session = () => Json.Object("type", "string", "minLength", 1, "description", "Revit session ID returned by list_sessions. Optional only when one Revit session is running.");
                _tools = new List<Dictionary<string, object>>
                {
                    Schema.Tool("list_sessions", "List running Revit sessions, their unique session IDs, active documents, and connection state. Call this first when more than one Revit window is open.", Json.Object(), new string[0], true),
                    Schema.Tool("connection_status", "Read Autodesk MCP Connector add-in status, session and pipe identity, active document, request count, and the last connection or error.", Json.Object("session_id", session()), new string[0], true),
                    Schema.Tool("document_info", "Read active Revit document identity and state. Call before writes.", Json.Object("session_id", session()), new string[0], true),
                    Schema.Tool("list_levels", "Read levels in the active Revit document. Elevations are returned in Revit internal units.", Json.Object("session_id", session()), new string[0], true),
                    Schema.Tool("list_selected", "Read the elements currently selected in Revit.", Json.Object("session_id", session()), new string[0], true),
                    Schema.Tool("get_element", "Read an element and up to 200 parameters by integer element id.", Json.Object("session_id", session(), "element_id", str()), new[] { "element_id" }, true),
                    Schema.Tool("set_parameter", "Set one writable element parameter in a Revit transaction. Numeric values use Revit internal units. Does not save or synchronize.",
                        Json.Object("session_id", session(), "expected_document", str(), "element_id", str(), "parameter", str(), "value", Json.Object("type", "string")),
                        new[] { "expected_document", "element_id", "parameter", "value" }, false),
                    Schema.Tool("execute_csharp", ExecuteDescription,
                        Json.Object("session_id", session(), "expected_document", str(),
                            "execution_mode", Json.Object("type", "string", "enum", new object[] { "read", "transaction", "manual" }),
                            "allow_model_changes", Json.Object("type", "boolean"),
                            "code", Json.Object("type", "string", "minLength", 1, "maxLength", 100000),
                            "parameters_json", Json.Object("type", "string"),
                            "transaction_name", str(),
                            "dry_run", Json.Object("type", "boolean"),
                            "background", Json.Object("type", "boolean"),
                            "wait_seconds", Json.Object("type", "integer", "minimum", 1, "maximum", 110)),
                        new[] { "expected_document", "execution_mode", "allow_model_changes", "code", "parameters_json", "transaction_name" }, false),
                    Schema.Tool("get_job", "Follow a Revit request that outlived its call: state (queued, running, completed, failed, cancelled), elapsed time, progress when the script reported it, and the result or error once it finished. Without job_id it lists the recent jobs. cancel=true drops a job Revit has not started; a running job cannot be stopped. Answers even while Revit is busy. Jobs are kept for 60 minutes and are lost when Revit closes.",
                        Json.Object("session_id", session(), "job_id", str(), "cancel", Json.Object("type", "boolean")), new string[0], true),
                    Schema.Tool("revision_cloud_info", "Read the revisions (id, number, issued), the types in the Revision Cloud Tags category with likely_tag (a model family placed in that category by mistake is not a tag; when likely_tag_types is 0 no real cloud tag family is loaded, so ask whether to use text notes or load one), and for each view_id given whether it is a dependent view and which primary view holds its annotations.",
                        Json.Object("session_id", session(), "view_ids", Json.Object("type", "array", "items", Json.Object("type", "string"), "description", "View ids to resolve to their primary view.")), new string[0], true),
                    Schema.Tool("create_revision_clouds", "Create revision clouds in one PLAN view: one rectangle per item from a box in model-space millimetres (x_min_mm, y_min_mm, x_max_mm, y_max_mm), each with an optional Comments value and an optional text note beside it. One transaction, at most 40 items per call: send more in further calls. A dependent view is resolved to its primary view, because annotations belong there. The revision must not be issued. Call revision_cloud_info first. dry_run=true creates, counts and rolls back. Does not save or synchronize; verify with a separate read.",
                        Json.Object("session_id", session(), "expected_document", str(), "revision_id", str(), "view_id", str(),
                            "items", Json.Object("type", "array", "minItems", 1, "maxItems", 40, "items", Json.Object("type", "object"), "description", "Objects with x_min_mm, y_min_mm, x_max_mm, y_max_mm and optional comment and note."),
                            "note_type_id", str(),
                            "note_side", Json.Object("type", "string", "enum", new object[] { "right", "left" }),
                            "gap_mm", Json.Object("type", "number", "minimum", 0),
                            "dry_run", Json.Object("type", "boolean")),
                        new[] { "expected_document", "revision_id", "view_id", "items" }, false)
                };
                return _tools;
            }
        }

        private static string LegacyPipe { get { return "BimCadMcp.Revit." + Version; } }

        internal static object Pipe(string pipeName, string operation, string[] fields, int connectTimeout)
        {
            using (NamedPipeClientStream client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut))
            {
                client.Connect(connectTimeout);
                using (StreamWriter writer = new StreamWriter(client, new UTF8Encoding(false), 4096, true))
                using (StreamReader reader = new StreamReader(client, Encoding.UTF8, false, 4096, true))
                {
                    writer.AutoFlush = true;
                    List<string> parts = new List<string> { operation };
                    parts.AddRange(fields.Select(field => Convert.ToBase64String(Encoding.UTF8.GetBytes(field ?? ""))));
                    writer.WriteLine(String.Join("\t", parts));
                    string line = reader.ReadLine();
                    if (String.IsNullOrWhiteSpace(line)) throw new ToolException("Revit add-in returned an empty response.");
                    string[] answer = line.Split(new[] { '\t' }, 2);
                    if (answer.Length != 2) throw new ToolException("Revit add-in returned an invalid response.");
                    string payload = Encoding.UTF8.GetString(Convert.FromBase64String(answer[1]));
                    if (answer[0] == "ERR") throw new RevitAddInException(payload);
                    if (answer[0] != "OK") throw new ToolException("Revit add-in returned an unknown response.");
                    return Json.Serializer.DeserializeObject(payload);
                }
            }
        }

        // The add-in answered, and the answer is an error: a typed message such as "[compile_error] ...". It is the add-in's
        // own message and must reach the AI client as it is, not as a lost connection.
        private sealed class RevitAddInException : ToolException
        {
            internal RevitAddInException(string message)
                : base(Regex.IsMatch(message ?? "", @"^\[[a-z_]+\] ") ? message : "[revit_error] " + message) { }
        }

        private sealed class Session
        {
            internal string Id, PipeName, StartedUtc;
            internal int ProcessId;
        }

        private static List<Session> RegisteredSessions()
        {
            List<Session> sessions = new List<Session>();
            if (!Directory.Exists(Paths.RevitSessions)) return sessions;
            foreach (string file in Directory.GetFiles(Paths.RevitSessions, "*.json"))
            {
                try
                {
                    object record = Json.Serializer.DeserializeObject(File.ReadAllText(file));
                    if (Json.GetString(record, "revit_version") != Version) continue;
                    int processId = Convert.ToInt32(Json.Get(record, "pid"), CultureInfo.InvariantCulture);
                    using (Process.GetProcessById(processId)) { }
                    string id = Json.GetString(record, "session_id"), pipe = Json.GetString(record, "pipe_name");
                    if (String.IsNullOrWhiteSpace(id) || String.IsNullOrWhiteSpace(pipe)) continue;
                    sessions.Add(new Session { Id = id, PipeName = pipe, ProcessId = processId, StartedUtc = Json.GetString(record, "started_utc") });
                }
                catch (Exception) { }
            }
            return sessions.OrderBy(s => s.ProcessId).ToList();
        }

        private static Dictionary<string, object> SessionEntry(string id, object processId, object status, string error)
        {
            return Json.Object("session_id", id, "process_id", processId, "revit_version", Version,
                "document_id", Json.GetString(status, "document_id"), "online", status != null,
                "recent_client", true.Equals(Json.Get(status, "recent_client")),
                "busy", true.Equals(Json.Get(status, "busy")), "busy_state", Json.GetString(status, "busy_state"),
                "last_operation", Json.GetString(status, "last_operation"),
                "last_error", status != null ? Json.GetString(status, "last_error") : error);
        }

        // statuses receives each online session's own status answer by session id, so a caller need not ask again.
        private static List<Dictionary<string, object>> Sessions(Dictionary<string, object> statuses)
        {
            List<Dictionary<string, object>> results = new List<Dictionary<string, object>>();
            foreach (Session session in RegisteredSessions())
            {
                try
                {
                    object status = Pipe(session.PipeName, "connection_status", new string[0], 500);
                    statuses[session.Id] = status;
                    results.Add(SessionEntry(session.Id, session.ProcessId, status, ""));
                }
                catch (Exception exception) { results.Add(SessionEntry(session.Id, session.ProcessId, null, exception.Message)); }
            }
            if (results.Count == 0)
            {
                try
                {
                    object status = Pipe(LegacyPipe, "connection_status", new string[0], 250);
                    statuses["legacy-" + Version] = status;
                    results.Add(SessionEntry("legacy-" + Version, "", status, ""));
                }
                catch (Exception) { }
            }
            return results;
        }

        private static string ResolvePipe(string sessionId)
        {
            List<Session> sessions = RegisteredSessions();
            if (!String.IsNullOrWhiteSpace(sessionId))
            {
                if (sessionId == "legacy-" + Version) return LegacyPipe;
                List<Session> match = sessions.Where(s => s.Id == sessionId).ToList();
                if (match.Count != 1) throw new ToolException("Revit session was not found: " + sessionId + ". Call list_sessions again.");
                return match[0].PipeName;
            }
            if (sessions.Count == 1) return sessions[0].PipeName;
            if (sessions.Count > 1)
                throw new ToolException("More than one Revit session is running (" + String.Join(", ", sessions.Select(s => s.Id)) + "). Call list_sessions and pass session_id.");
            return LegacyPipe;
        }

        private static object Call(string operation, string[] fields, string sessionId)
        {
            string pipe = ResolvePipe(sessionId);
            try { return Pipe(pipe, operation, fields, 1500); }
            catch (RevitAddInException) { throw; }
            catch (Exception exception) { throw new ToolException("Revit " + Version + " MCP session is not available. Start Revit or call list_sessions. " + exception.Message); }
        }

        private static bool RevitRunning()
        {
            Process[] processes = Process.GetProcessesByName("Revit");
            foreach (Process process in processes) process.Dispose();
            return processes.Length > 0;
        }

        private static string BusyText(object status)
        {
            return Json.GetString(status, "busy_reason") + " Wait, then call connection_status again; do not send the last request again, and use get_job for a request that is still running.";
        }

        // Read-only Revit part of the combined connection_status. Never throws; reports why Revit is unavailable, and whether it is busy.
        internal static Dictionary<string, object> ConnectionStatus(object arguments)
        {
            IDictionary<string, object> values = Schema.Check(Tools, "connection_status", arguments, true);
            string sessionId = Json.GetString(values, "session_id");
            bool running = RevitRunning();
            if (!String.IsNullOrWhiteSpace(sessionId))
            {
                try
                {
                    object status = Pipe(ResolvePipe(sessionId), "connection_status", new string[0], 1000);
                    bool busy = true.Equals(Json.Get(status, "busy"));
                    return Json.Object("available", true, "running", true, "revit_version", Version, "busy", busy, "busy_state", Json.GetString(status, "busy_state"), "status", status,
                        "summary", "Revit " + Version + " session " + sessionId + (busy ? " is connected but busy: " + BusyText(status) : " is connected."));
                }
                catch (Exception exception)
                {
                    return Json.Object("available", false, "running", running, "revit_version", Version, "summary", "Revit " + Version + " session " + sessionId + " is not available: " + exception.Message);
                }
            }
            Dictionary<string, object> statuses = new Dictionary<string, object>();
            List<Dictionary<string, object>> sessions = Sessions(statuses);
            List<Dictionary<string, object>> online = sessions.Where(s => true.Equals(s["online"])).ToList();
            Dictionary<string, object> result = Json.Object("available", online.Count > 0, "running", running || online.Count > 0, "revit_version", Version, "sessions", sessions);
            object only = null;
            if (online.Count == 1)
            {
                statuses.TryGetValue((string)online[0]["session_id"], out only);
                result["status"] = only;
            }
            bool onlyBusy = only != null && true.Equals(Json.Get(only, "busy"));
            if (online.Count > 0) { result["busy"] = online.Any(s => true.Equals(s["busy"])); if (onlyBusy) result["busy_state"] = Json.GetString(only, "busy_state"); }
            result["summary"] = online.Count == 1 ? "Revit " + Version + " is connected (session " + online[0]["session_id"] + ")" + (onlyBusy ? " but busy: " + BusyText(only) : ".")
                : online.Count > 1 ? "Revit " + Version + " is connected with " + online.Count + " sessions; pass session_id to choose one." + (online.Any(s => true.Equals(s["busy"])) ? " At least one is busy." : "")
                : sessions.Count > 0 || running ? "Revit is running, but the Revit " + Version + " add-in is not answering; it may still be loading, or it is an older add-in that cannot report a busy state. Wait and ask again."
                : "Revit is not running.";
            return result;
        }

        // The extra field of execute_csharp, only when an option is set: "dry_run=true;background=true;wait_seconds=N".
        private static string RunOptionsText(IDictionary<string, object> a)
        {
            List<string> options = new List<string>();
            if (a.ContainsKey("dry_run") && (bool)a["dry_run"]) options.Add("dry_run=true");
            if (a.ContainsKey("background") && (bool)a["background"]) options.Add("background=true");
            if (a.ContainsKey("wait_seconds")) options.Add("wait_seconds=" + Convert.ToInt32(a["wait_seconds"], CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture));
            return String.Join(";", options.ToArray());
        }

        private static string[] Strings(object value)
        {
            object[] items = value as object[];
            if (items == null)
            {
                ArrayList list = value as ArrayList;
                if (list != null) items = list.ToArray();
            }
            return items == null ? new string[0] : items.Select(item => Convert.ToString(item, CultureInfo.InvariantCulture)).ToArray();
        }

        private static string ElementIdText(string value, string name)
        {
            if (!Regex.IsMatch(value ?? "", @"^-?\d{1,18}$")) throw new ToolException(name + " must be an integer element id.");
            return value;
        }

        private static double Number(IDictionary<string, object> item, string key, int index)
        {
            double number;
            if (!item.ContainsKey(key) || !Schema.TryNumber(item[key], out number)) throw new ToolException("items[" + index + "] needs a number for " + key + ".");
            return number;
        }

        // One cloud as the add-in reads it: "xmin;ymin;xmax;ymax;base64(comment);base64(note)", millimetres.
        private static string CloudField(object entry, int index)
        {
            IDictionary<string, object> item = (IDictionary<string, object>)entry;
            foreach (string key in item.Keys)
                if (key != "x_min_mm" && key != "y_min_mm" && key != "x_max_mm" && key != "y_max_mm" && key != "comment" && key != "note") throw new ToolException("items[" + index + "] has an unknown field: " + key);
            double xMin = Number(item, "x_min_mm", index), yMin = Number(item, "y_min_mm", index), xMax = Number(item, "x_max_mm", index), yMax = Number(item, "y_max_mm", index);
            if (xMax <= xMin || yMax <= yMin) throw new ToolException("items[" + index + "] needs x_max_mm > x_min_mm and y_max_mm > y_min_mm.");
            Func<string, string> text = key =>
            {
                if (!item.ContainsKey(key)) return "";
                string value = item[key] as string;
                if (value == null) throw new ToolException("items[" + index + "]." + key + " must be a string.");
                if (value.Contains("\n") || value.Contains("\r") || value.Length > 500) throw new ToolException("items[" + index + "]." + key + " must be one line of at most 500 characters.");
                return Convert.ToBase64String(Encoding.UTF8.GetBytes(value));
            };
            Func<double, string> n = v => v.ToString("R", CultureInfo.InvariantCulture);
            return String.Join(";", new[] { n(xMin), n(yMin), n(xMax), n(yMax), text("comment"), text("note") });
        }

        internal static object Invoke(string name, object arguments)
        {
            IDictionary<string, object> a = Schema.Check(Tools, name, arguments, true);
            string sessionId = Json.GetString(a, "session_id");
            switch (name)
            {
                case "list_sessions": return Json.Object("sessions", Sessions(new Dictionary<string, object>()));
                case "get_element": return Call("get_element", new[] { Json.GetString(a, "element_id") }, sessionId);
                case "set_parameter":
                    return Call("set_parameter", new[] { Json.GetString(a, "expected_document"), Json.GetString(a, "element_id"), Json.GetString(a, "parameter"), Json.GetString(a, "value") }, sessionId);
                case "execute_csharp":
                {
                    if (a.ContainsKey("dry_run") && (bool)a["dry_run"] && !String.Equals(Json.GetString(a, "execution_mode"), "transaction", StringComparison.OrdinalIgnoreCase))
                        throw new ToolException("dry_run needs execution_mode transaction: only the automatic transaction can be rolled back.");
                    // allow_model_changes is sent as "True"/"False", as the add-in has always received it. The seventh field (options) only when one is set.
                    List<string> fields = new List<string> { Json.GetString(a, "expected_document"), Json.GetString(a, "execution_mode"),
                        ((bool)a["allow_model_changes"]) ? "True" : "False", Json.GetString(a, "code"), Json.GetString(a, "parameters_json"), Json.GetString(a, "transaction_name") };
                    string options = RunOptionsText(a);
                    if (options.Length > 0) fields.Add(options);
                    return Call("execute_csharp", fields.ToArray(), sessionId);
                }
                case "get_job":
                    return Call("get_job", new[] { Json.GetString(a, "job_id"), a.ContainsKey("cancel") && (bool)a["cancel"] ? "True" : "False" }, sessionId);
                case "revision_cloud_info":
                    return Call("revision_cloud_info", Strings(a.ContainsKey("view_ids") ? a["view_ids"] : null).Select(id => ElementIdText(id, "view_ids")).ToArray(), sessionId);
                case "create_revision_clouds":
                {
                    object[] entries = a["items"] as object[];
                    if (entries == null) { ArrayList list = a["items"] as ArrayList; entries = list == null ? new object[0] : list.ToArray(); }
                    List<string> fields = new List<string> { Json.GetString(a, "expected_document"), ElementIdText(Json.GetString(a, "revision_id"), "revision_id"), ElementIdText(Json.GetString(a, "view_id"), "view_id") };
                    List<string> options = new List<string>();
                    if (a.ContainsKey("note_type_id")) options.Add("note_type_id=" + ElementIdText(Json.GetString(a, "note_type_id"), "note_type_id"));
                    if (a.ContainsKey("note_side")) options.Add("note_side=" + Json.GetString(a, "note_side").ToLowerInvariant());
                    if (a.ContainsKey("gap_mm")) options.Add("gap_mm=" + Convert.ToDouble(a["gap_mm"], CultureInfo.InvariantCulture).ToString("R", CultureInfo.InvariantCulture));
                    if (a.ContainsKey("dry_run") && (bool)a["dry_run"]) options.Add("dry_run=true");
                    fields.Add(String.Join(";", options.ToArray()));
                    for (int i = 0; i < entries.Length; i++)
                    {
                        if (!(entries[i] is IDictionary<string, object>)) throw new ToolException("items[" + i + "] must be an object.");
                        fields.Add(CloudField(entries[i], i));
                    }
                    return Call("create_revision_clouds", fields.ToArray(), sessionId);
                }
                default: return Call(name, new string[0], sessionId);
            }
        }
    }

    // Shared workflow guidance: the skills shipped with the connector (in category folders) and the approved cache
    // downloaded by Skills Sync. The approved cache wins: it follows the latest approval.
    internal static class Workflows
    {
        private static readonly string[] Categories = { "revit", "autocad", "3ds-max", "other-software", "linkedin-marketing", "branding-ci", "general", "uncategorized" };
        private static readonly string[] TextExtensions = { ".md", ".txt", ".json", ".yaml", ".yml", ".toml", ".py", ".ps1", ".js", ".ts", ".sh", ".csv", ".xml" };

        internal sealed class Skill
        {
            internal string Name, Category, Path;
        }

        // The "category:" line in the SKILL.md frontmatter; empty when the skill does not declare one.
        private static string CategoryOf(string skillPath)
        {
            try
            {
                string[] lines = File.ReadLines(System.IO.Path.Combine(skillPath, "SKILL.md")).Take(40).ToArray();
                if (lines.Length == 0 || !Regex.IsMatch(lines[0].TrimStart('﻿'), @"^---\s*$")) return "";
                for (int i = 1; i < lines.Length && !Regex.IsMatch(lines[i], @"^---\s*$"); i++)
                {
                    Match match = Regex.Match(lines[i], @"^category:\s*([a-z0-9-]+)\s*$");
                    if (match.Success) return match.Groups[1].Value;
                }
            }
            catch (Exception) { }
            return "";
        }

        private static IEnumerable<DirectoryInfo> Folders(string root)
        {
            return new DirectoryInfo(root).GetDirectories().Where(d => !d.Name.StartsWith(".")).OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase);
        }

        internal static List<Skill> SkillsIn(string root)
        {
            List<Skill> skills = new List<Skill>();
            if (!Directory.Exists(root)) return skills;
            foreach (DirectoryInfo folder in Folders(root))
            {
                if (File.Exists(System.IO.Path.Combine(folder.FullName, "SKILL.md")))
                    skills.Add(new Skill { Name = folder.Name, Category = CategoryOf(folder.FullName), Path = folder.FullName });
                else if (Categories.Contains(folder.Name))
                    foreach (DirectoryInfo skill in Folders(folder.FullName))
                        if (File.Exists(System.IO.Path.Combine(skill.FullName, "SKILL.md")))
                            skills.Add(new Skill { Name = skill.Name, Category = folder.Name, Path = skill.FullName });
            }
            return skills;
        }

        private static Dictionary<string, Skill> All()
        {
            Dictionary<string, Skill> skills = new Dictionary<string, Skill>();
            foreach (Skill skill in SkillsIn(Paths.ShippedSkills)) skills[skill.Name] = skill;
            foreach (Skill skill in SkillsIn(System.IO.Path.Combine(Paths.SkillState, "approved-skills")))
            {
                string category = skill.Category.Length > 0 ? skill.Category : skills.ContainsKey(skill.Name) ? skills[skill.Name].Category : "";
                skills[skill.Name] = new Skill { Name = skill.Name, Category = category, Path = skill.Path };
            }
            return skills;
        }

        private static bool IsLink(string path)
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }

        // The "description:" line of the SKILL.md frontmatter, cut to one short line; empty when there is none.
        internal static string DescriptionOf(string skillPath)
        {
            try
            {
                string[] lines = File.ReadLines(System.IO.Path.Combine(skillPath, "SKILL.md")).Take(40).ToArray();
                if (lines.Length == 0 || !Regex.IsMatch(lines[0].TrimStart('\uFEFF'), @"^---\s*$")) return "";
                for (int i = 1; i < lines.Length && !Regex.IsMatch(lines[i], @"^---\s*$"); i++)
                {
                    Match match = Regex.Match(lines[i], @"^description:\s*(.+?)\s*$");
                    if (!match.Success) continue;
                    string text = match.Groups[1].Value.Trim('"', '\'');
                    if (text.Length <= 110) return text;
                    int cut = text.LastIndexOf(' ', 110);
                    return text.Substring(0, cut > 60 ? cut : 110).TrimEnd(' ', ',', ';', '.') + "...";
                }
            }
            catch (Exception) { }
            return "";
        }

        // product: "" lists everything; "autocad" or "revit" lists that product's workflows only (the generic skill-finder and the
        // library or team administration skills are not drawing or model workflows). One short line each, so the list stays small.
        internal static List<Dictionary<string, object>> ListAll(string product)
        {
            product = (product ?? "").Trim().ToLowerInvariant();
            if (product.Length > 0 && product != "autocad" && product != "revit" && product != "all") throw new ToolException("product must be autocad, revit or all.");
            if (product == "all") product = "";
            return All().Values.Where(s => !IsLink(s.Path) && (product.Length == 0 || s.Category == product))
                .OrderBy(s => s.Category.Length > 0 ? s.Category : "zz", StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase)
                .Select(s => Json.Object("name", s.Name, "category", s.Category.Length > 0 ? s.Category : "uncategorized", "description", DescriptionOf(s.Path)))
                .ToList();
        }

        internal static List<Dictionary<string, object>> ListAll() { return ListAll(""); }

        internal static Dictionary<string, object> Read(string name, string file)
        {
            if (!Regex.IsMatch(name ?? "", "^[a-z0-9]+(?:-[a-z0-9]+)*$")) throw new ToolException("Invalid skill name.");
            if (String.IsNullOrWhiteSpace(file)) file = "SKILL.md";
            string[] parts = file.Split('\\', '/');
            if (System.IO.Path.IsPathRooted(file) || file.Contains(":") || parts.Any(p => p == "" || p == "." || p == ".."))
                throw new ToolException("Use a relative file path within the selected skill.");
            Dictionary<string, Skill> skills = All();
            if (!skills.ContainsKey(name)) throw new ToolException("Skill file was not found.");
            string path = skills[name].Path;
            if (IsLink(path)) throw new ToolException("Linked skill paths cannot be read.");
            foreach (string part in parts)
            {
                path = System.IO.Path.Combine(path, part);
                if (!File.Exists(path) && !Directory.Exists(path)) throw new ToolException("Skill file was not found.");
                if (IsLink(path)) throw new ToolException("Linked skill paths cannot be read.");
            }
            if (!File.Exists(path)) throw new ToolException("Skill file was not found.");
            FileInfo info = new FileInfo(path);
            if (info.Length > 256 * 1024 || !TextExtensions.Contains(info.Extension.ToLowerInvariant())) throw new ToolException("Only small skill text files can be read.");
            return Json.Object("name", name, "file", file, "content", File.ReadAllText(path, Encoding.UTF8));
        }
    }
}
