using System;
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
                    Schema.Tool("execute_csharp", "Execute controlled Revit 2024 C# against the active document. Use read for inspection, transaction for writes inside one automatic transaction, and manual only for workflows that must manage their own transactions or family documents. Read document_info first. Code must return a string. Model changes require allow_model_changes=true. Does not save or synchronize unless the supplied manual code explicitly does so.",
                        Json.Object("session_id", session(), "expected_document", str(),
                            "execution_mode", Json.Object("type", "string", "enum", new object[] { "read", "transaction", "manual" }),
                            "allow_model_changes", Json.Object("type", "boolean"),
                            "code", Json.Object("type", "string", "minLength", 1, "maxLength", 100000),
                            "parameters_json", Json.Object("type", "string"),
                            "transaction_name", str()),
                        new[] { "expected_document", "execution_mode", "allow_model_changes", "code", "parameters_json", "transaction_name" }, false)
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
                    if (answer[0] == "ERR") throw new ToolException(payload);
                    if (answer[0] != "OK") throw new ToolException("Revit add-in returned an unknown response.");
                    return Json.Serializer.DeserializeObject(payload);
                }
            }
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
                "last_operation", Json.GetString(status, "last_operation"),
                "last_error", status != null ? Json.GetString(status, "last_error") : error);
        }

        private static List<Dictionary<string, object>> Sessions()
        {
            List<Dictionary<string, object>> results = new List<Dictionary<string, object>>();
            foreach (Session session in RegisteredSessions())
            {
                try { results.Add(SessionEntry(session.Id, session.ProcessId, Pipe(session.PipeName, "connection_status", new string[0], 500), "")); }
                catch (Exception exception) { results.Add(SessionEntry(session.Id, session.ProcessId, null, exception.Message)); }
            }
            if (results.Count == 0)
            {
                try { results.Add(SessionEntry("legacy-" + Version, "", Pipe(LegacyPipe, "connection_status", new string[0], 250), "")); }
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
            catch (Exception exception) { throw new ToolException("Revit " + Version + " MCP session is not available. Start Revit or call list_sessions. " + exception.Message); }
        }

        private static bool RevitRunning()
        {
            Process[] processes = Process.GetProcessesByName("Revit");
            foreach (Process process in processes) process.Dispose();
            return processes.Length > 0;
        }

        // Read-only Revit part of the combined connection_status. Never throws; reports why Revit is unavailable.
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
                    return Json.Object("available", true, "running", true, "revit_version", Version, "status", status, "summary", "Revit " + Version + " session " + sessionId + " is connected.");
                }
                catch (Exception exception)
                {
                    return Json.Object("available", false, "running", running, "revit_version", Version, "summary", "Revit " + Version + " session " + sessionId + " is not available: " + exception.Message);
                }
            }
            List<Dictionary<string, object>> sessions = Sessions();
            List<Dictionary<string, object>> online = sessions.Where(s => true.Equals(s["online"])).ToList();
            Dictionary<string, object> result = Json.Object("available", online.Count > 0, "running", running || online.Count > 0, "revit_version", Version, "sessions", sessions);
            if (online.Count == 1)
            {
                try { result["status"] = Pipe(ResolvePipe((string)online[0]["session_id"]), "connection_status", new string[0], 500); } catch (Exception) { }
            }
            result["summary"] = online.Count == 1 ? "Revit " + Version + " is connected (session " + online[0]["session_id"] + ")."
                : online.Count > 1 ? "Revit " + Version + " is connected with " + online.Count + " sessions; pass session_id to choose one."
                : sessions.Count > 0 || running ? "Revit is running, but the Revit " + Version + " add-in is not answering; it may still be loading or busy."
                : "Revit is not running.";
            return result;
        }

        internal static object Invoke(string name, object arguments)
        {
            IDictionary<string, object> a = Schema.Check(Tools, name, arguments, true);
            string sessionId = Json.GetString(a, "session_id");
            switch (name)
            {
                case "list_sessions": return Json.Object("sessions", Sessions());
                case "get_element": return Call("get_element", new[] { Json.GetString(a, "element_id") }, sessionId);
                case "set_parameter":
                    return Call("set_parameter", new[] { Json.GetString(a, "expected_document"), Json.GetString(a, "element_id"), Json.GetString(a, "parameter"), Json.GetString(a, "value") }, sessionId);
                case "execute_csharp":
                    // allow_model_changes is sent as "True"/"False", as the add-in has always received it.
                    return Call("execute_csharp", new[] { Json.GetString(a, "expected_document"), Json.GetString(a, "execution_mode"),
                        ((bool)a["allow_model_changes"]) ? "True" : "False", Json.GetString(a, "code"), Json.GetString(a, "parameters_json"), Json.GetString(a, "transaction_name") }, sessionId);
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

        internal static List<Dictionary<string, object>> ListAll()
        {
            return All().Values.Where(s => !IsLink(s.Path))
                .OrderBy(s => s.Category.Length > 0 ? s.Category : "zz", StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase)
                .Select(s => Json.Object("name", s.Name, "category", s.Category.Length > 0 ? s.Category : "uncategorized", "file", "SKILL.md"))
                .ToList();
        }

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
