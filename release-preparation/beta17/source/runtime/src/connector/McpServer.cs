using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

// Smart Connector MCP server: one compiled program that Claude Desktop, Claude Code and Codex start to work with
// Revit and AutoCAD on this computer. It replaces the PowerShell bridges (src\autodesk\autodesk-bridge.ps1,
// src\revit\revit-bridge.ps1, src\autocad\autocad-bridge.ps1) with the same tools, answers and messages.
//   SmartConnector.exe mcp         MCP over stdio (one JSON-RPC message per line, UTF-8)
//   SmartConnector.exe --version   print the connector version
// C# 5 only: built with the .NET Framework compiler that ships with Windows (release-preparation\beta17\setup\
// build-connector-exe.ps1). Nothing is compiled on the PCs.
namespace SmartConnector
{
    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            if (args.Length == 1 && args[0] == "mcp") return McpServer.Run();
            if (args.Length == 1 && args[0] == "--version") { Console.WriteLine(Paths.Version); return 0; }
            Console.Error.WriteLine("Smart Connector " + Paths.Version + ". Claude and Codex start it as: SmartConnector.exe mcp");
            return 2;
        }
    }

    // Folders of the installed connector. The program lives in <install root>\bin.
    internal static class Paths
    {
        internal static string LocalAppData { get { return Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); } }
        internal static string Root { get { return Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..")); } }
        internal static string ShippedSkills { get { return Path.Combine(Root, ".agents", "skills"); } }
        internal static string SkillState { get { return Path.Combine(LocalAppData, "AutodeskMcpSkillCollection"); } }
        internal static string RevitSessions { get { return Path.Combine(LocalAppData, "BIM-CAD-MCP", "runtime", "revit-sessions"); } }

        internal static string Version
        {
            get
            {
                try
                {
                    string path = Path.Combine(Root, "VERSION");
                    if (File.Exists(path)) return File.ReadAllText(path).Trim();
                }
                catch (Exception) { }
                return "development";
            }
        }
    }

    // Small helpers for the JSON shapes the serializer reads and writes.
    internal static class Json
    {
        internal static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 200 };

        internal static Dictionary<string, object> Object(params object[] pairs)
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            for (int i = 0; i + 1 < pairs.Length; i += 2) result[(string)pairs[i]] = pairs[i + 1];
            return result;
        }

        internal static object Get(object value, string key)
        {
            IDictionary<string, object> dictionary = value as IDictionary<string, object>;
            object result;
            return dictionary != null && dictionary.TryGetValue(key, out result) ? result : null;
        }

        internal static string GetString(object value, string key)
        {
            object result = Get(value, key);
            return result == null ? "" : Convert.ToString(result, System.Globalization.CultureInfo.InvariantCulture);
        }

        internal static bool Has(object value, string key)
        {
            IDictionary<string, object> dictionary = value as IDictionary<string, object>;
            return dictionary != null && dictionary.ContainsKey(key);
        }
    }

    // A tool error that is reported to the AI client as the tool's text, as the PowerShell bridges did.
    internal sealed class ToolException : Exception
    {
        internal ToolException(string message) : base(message) { }
    }

    internal static class McpServer
    {
        private static readonly string[] Protocols = { "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28" };
        private const string Instructions = "Use list_skill_workflows and read_skill_workflow to load relevant shared guidance before CAD/BIM tasks; no separate skill upload is required to read this guidance. Authenticated Autodesk connector for Codex and Claude with AutoCAD and Revit tools. Model-changing calls are serialized across AI clients. For AutoCAD, read drawing_info before edits and save only when explicitly requested. For Revit, call list_sessions when multiple sessions may be open, read document_info before writes, pass expected_document, and verify every write with a separate read.";
        private const string CombinedStatus = "Check whether the Smart Connector can reach AutoCAD and Revit. Reports AutoCAD (running full AutoCAD over COM, version, active drawing) and Revit (add-in sessions, active document, last error) separately. Succeeds when either product is reachable; a product that is closed is reported, not an error. Optional session_id selects a Revit session.";

        private static List<Dictionary<string, object>> _tools;
        private static readonly Dictionary<string, bool> ReadOnly = new Dictionary<string, bool>();
        private static readonly HashSet<string> AutoCadNames = new HashSet<string>();
        private static readonly HashSet<string> RevitNames = new HashSet<string>();

        internal static List<Dictionary<string, object>> Tools
        {
            get
            {
                if (_tools != null) return _tools;
                List<Dictionary<string, object>> tools = new List<Dictionary<string, object>>();
                foreach (Dictionary<string, object> tool in AutoCadBridge.Tools) { tools.Add(tool); AutoCadNames.Add((string)tool["name"]); }
                foreach (Dictionary<string, object> source in RevitBridge.Tools)
                {
                    Dictionary<string, object> tool = source;
                    if ((string)source["name"] == "connection_status")
                    {
                        // connection_status is answered here for both products, so it is described for both.
                        tool = new Dictionary<string, object>(source);
                        tool["description"] = CombinedStatus;
                    }
                    tools.Add(tool); RevitNames.Add((string)tool["name"]);
                }
                tools.Add(Json.Object("name", "list_skill_workflows",
                    "description", "List shared workflow guidance available through this connector, each with its category (revit, autocad, 3ds-max, other-software, linkedin-marketing, branding-ci, general). Read the relevant workflow before a task.",
                    "inputSchema", Json.Object("type", "object", "properties", Json.Object()),
                    "annotations", Json.Object("readOnlyHint", true)));
                tools.Add(Json.Object("name", "read_skill_workflow",
                    "description", "Read a shared Autodesk workflow or its supporting text file. This returns guidance and does not execute code or modify a model.",
                    "inputSchema", Json.Object("type", "object",
                        "properties", Json.Object(
                            "name", Json.Object("type", "string", "description", "Skill folder name from list_skill_workflows"),
                            "file", Json.Object("type", "string", "description", "Relative text file within the skill; defaults to SKILL.md")),
                        "required", new object[] { "name" }),
                    "annotations", Json.Object("readOnlyHint", true)));
                foreach (Dictionary<string, object> tool in tools)
                {
                    object hint = Json.Get(tool["annotations"], "readOnlyHint");
                    ReadOnly[(string)tool["name"]] = hint is bool && (bool)hint;
                }
                _tools = tools;
                return _tools;
            }
        }

        internal static int Run()
        {
            UTF8Encoding utf8 = new UTF8Encoding(false);
            TextReader input = new StreamReader(Console.OpenStandardInput(), utf8);
            StreamWriter output = new StreamWriter(Console.OpenStandardOutput(), utf8);
            output.AutoFlush = true;
            output.NewLine = "\n";
            string line;
            while ((line = input.ReadLine()) != null)
            {
                if (String.IsNullOrWhiteSpace(line)) continue;
                object request;
                try { request = Json.Serializer.DeserializeObject(line); }
                catch (Exception)
                {
                    output.WriteLine("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}");
                    continue;
                }
                Dictionary<string, object> response = Handle(request);
                if (response != null) output.WriteLine(Json.Serializer.Serialize(response));
            }
            return 0;
        }

        internal static Dictionary<string, object> Handle(object request)
        {
            // Notifications (no id) get no answer.
            if (Json.Get(request, "id") == null) return null;
            Dictionary<string, object> response = Json.Object("jsonrpc", "2.0", "id", Json.Get(request, "id"));
            object parameters = Json.Get(request, "params");
            switch (Json.GetString(request, "method"))
            {
                case "initialize":
                    string requested = Json.GetString(parameters, "protocolVersion");
                    response["result"] = Json.Object(
                        "protocolVersion", Protocols.Contains(requested) ? requested : "2024-11-05",
                        "capabilities", Json.Object("tools", Json.Object()),
                        "serverInfo", Json.Object("name", "Smart Connector", "version", Paths.Version),
                        "instructions", Instructions);
                    break;
                case "ping":
                    response["result"] = Json.Object();
                    break;
                case "tools/list":
                    response["result"] = Json.Object("tools", Tools);
                    break;
                case "tools/call":
                    response["result"] = CallTool(Json.GetString(parameters, "name"), Json.Get(parameters, "arguments"));
                    break;
                default:
                    response["error"] = Json.Object("code", -32601, "message", "Method not found");
                    break;
            }
            return response;
        }

        private static Dictionary<string, object> CallTool(string name, object arguments)
        {
            List<Dictionary<string, object>> tools = Tools;
            try
            {
                object data;
                if (name == "list_skill_workflows") data = Json.Object("skills", Workflows.ListAll());
                else if (name == "read_skill_workflow") data = Workflows.Read(Json.GetString(arguments, "name"), Json.GetString(arguments, "file"));
                else if (name == "connection_status") data = ConnectionStatus(arguments);
                else if (AutoCadNames.Contains(name)) data = WithWriteLock(name, delegate { return AutoCadBridge.Invoke(name, arguments); });
                else if (RevitNames.Contains(name)) data = WithWriteLock(name, delegate { return RevitBridge.Invoke(name, arguments); });
                else throw new ToolException("Unknown Autodesk MCP tool: " + name);
                Dictionary<string, object> result = Json.Object(
                    "content", new object[] { Json.Object("type", "text", "text", Json.Serializer.Serialize(data)) },
                    "isError", false);
                // Opening a skill's SKILL.md counts as using that skill; supporting files are not counted.
                if (name == "read_skill_workflow")
                {
                    string file = Json.GetString(arguments, "file");
                    if (String.IsNullOrWhiteSpace(file) || file == "SKILL.md") Usage.Record("skill", Json.GetString(arguments, "name"));
                }
                else if (name != "list_skill_workflows") Usage.Record("tool", name);
                return result;
            }
            catch (Exception exception)
            {
                Exception shown = exception is System.Reflection.TargetInvocationException && exception.InnerException != null ? exception.InnerException : exception;
                return Json.Object("content", new object[] { Json.Object("type", "text", "text", shown.Message) }, "isError", true);
            }
        }

        // Read-only status for both products. Succeeds when either is reachable; otherwise the error message carries
        // both product summaries so the client can tell the user what to start.
        private static object ConnectionStatus(object arguments)
        {
            Dictionary<string, object> autoCad = AutoCadBridge.ConnectionStatus();
            Dictionary<string, object> revit = RevitBridge.ConnectionStatus(arguments);
            string summary = "AutoCAD: " + Json.GetString(autoCad, "summary") + " Revit: " + Json.GetString(revit, "summary");
            if (!(true.Equals(autoCad["available"]) || true.Equals(revit["available"])))
                throw new ToolException("Smart Connector is running, but neither AutoCAD nor Revit is reachable. " + summary);
            return Json.Object("connected", true, "summary", summary, "autocad", autoCad, "revit", revit);
        }

        // Model-changing calls are serialized across every Codex and Claude window (and the PowerShell bridges).
        private static object WithWriteLock(string name, Func<object> operation)
        {
            bool readOnly;
            if (ReadOnly.TryGetValue(name, out readOnly) && readOnly) return operation();
            using (Mutex mutex = new Mutex(false, @"Local\AutodeskMcpConnector.ModelWrite"))
            {
                bool acquired;
                try { acquired = mutex.WaitOne(TimeSpan.FromMinutes(2)); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new ToolException("Another Codex or Claude session is modifying an Autodesk model. Wait for it to finish and retry.");
                try { return operation(); }
                finally { mutex.ReleaseMutex(); }
            }
        }
    }

    // Which skill or tool was used, by name only (never arguments or results), for the administrator's usage report.
    // Only computers joined to the team skill service record. Failures never affect the tool call.
    internal static class Usage
    {
        internal static void Record(string kind, string name)
        {
            try
            {
                if (!System.Text.RegularExpressions.Regex.IsMatch(name ?? "", "^[A-Za-z0-9_.:-]{1,100}$")) return;
                if (!File.Exists(Path.Combine(Paths.SkillState, "service.json"))) return;
                string line = Json.Serializer.Serialize(Json.Object("kind", kind, "name", name, "day", DateTime.Now.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture))) + "\n";
                string path = Path.Combine(Paths.SkillState, "usage.jsonl");
                // Several Codex/Claude windows can append at once; retry briefly if the file is busy.
                for (int attempt = 0; attempt < 3; attempt++)
                {
                    try { File.AppendAllText(path, line, new UTF8Encoding(false)); return; }
                    catch (IOException) { Thread.Sleep(50); }
                }
            }
            catch (Exception) { }
        }
    }

    // Tool definitions and argument checks shared by the AutoCAD and Revit tools (the inputSchema of each tool).
    internal static class Schema
    {
        internal static Dictionary<string, object> Tool(string name, string description, Dictionary<string, object> properties, string[] required, bool readOnly)
        {
            return Json.Object(
                "name", name,
                "description", description,
                "inputSchema", Json.Object("type", "object", "properties", properties, "required", required.Cast<object>().ToArray(), "additionalProperties", false),
                "annotations", Json.Object("readOnlyHint", readOnly, "openWorldHint", false, "destructiveHint", !readOnly, "idempotentHint", readOnly));
        }

        // revitStyle: the Revit bridge's messages (Empty argument, Invalid value) and case-insensitive choices.
        internal static IDictionary<string, object> Check(IEnumerable<Dictionary<string, object>> tools, string name, object arguments, bool revitStyle)
        {
            Dictionary<string, object> tool = tools.FirstOrDefault(t => (string)t["name"] == name);
            if (tool == null) throw new ToolException("Unknown tool: " + name);
            IDictionary<string, object> values = arguments as IDictionary<string, object>;
            if (values == null)
            {
                if (arguments != null) throw new ToolException("Arguments must be an object.");
                values = new Dictionary<string, object>();
            }
            Dictionary<string, object> schema = (Dictionary<string, object>)tool["inputSchema"];
            Dictionary<string, object> properties = (Dictionary<string, object>)schema["properties"];
            foreach (object key in (object[])schema["required"])
                if (!values.ContainsKey((string)key)) throw new ToolException("Missing argument: " + key);
            foreach (KeyValuePair<string, object> pair in values)
            {
                if (!properties.ContainsKey(pair.Key)) throw new ToolException("Unknown argument: " + pair.Key);
                if (pair.Value == null) throw new ToolException("Null argument: " + pair.Key);
                Dictionary<string, object> rule = (Dictionary<string, object>)properties[pair.Key];
                string type = Json.GetString(rule, "type");
                object value = pair.Value;
                if (type == "string")
                {
                    string text = value as string;
                    if (text == null) throw new ToolException("Invalid string: " + pair.Key);
                    if (rule.ContainsKey("minLength") && String.IsNullOrWhiteSpace(text)) throw new ToolException((revitStyle ? "Empty argument: " : "Invalid string: ") + pair.Key);
                    if (rule.ContainsKey("maxLength") && text.Length > Convert.ToInt32(rule["maxLength"])) throw new ToolException("Argument is too long: " + pair.Key);
                }
                else if (type == "boolean")
                {
                    if (!(value is bool)) throw new ToolException("Invalid boolean: " + pair.Key);
                }
                else if (type == "number" || type == "integer")
                {
                    double number;
                    if (!TryNumber(value, out number)) throw new ToolException("Invalid number: " + pair.Key);
                    if (type == "integer" && Math.Truncate(number) != number) throw new ToolException("Expected integer.");
                    if ((rule.ContainsKey("minimum") && number < Convert.ToDouble(rule["minimum"])) ||
                        (rule.ContainsKey("maximum") && number > Convert.ToDouble(rule["maximum"])) ||
                        (rule.ContainsKey("exclusiveMinimum") && number <= Convert.ToDouble(rule["exclusiveMinimum"])))
                        throw new ToolException("Number out of range: " + pair.Key);
                }
                else if (type == "array")
                {
                    object[] items = value as object[];
                    if (items == null) { ArrayList list = value as ArrayList; if (list != null) items = list.ToArray(); }
                    if (items == null || items.Length != 3) throw new ToolException("A point must have three coordinates.");
                    foreach (object item in items) { double coordinate; if (!TryNumber(item, out coordinate)) throw new ToolException("Coordinates must be finite numbers."); }
                }
                if (rule.ContainsKey("enum"))
                {
                    StringComparison comparison = revitStyle ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
                    string text = Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
                    if (!((object[])rule["enum"]).Any(choice => String.Equals((string)choice, text, comparison)))
                        throw new ToolException((revitStyle ? "Invalid value: " : "Invalid choice: ") + pair.Key);
                }
            }
            return values;
        }

        internal static bool TryNumber(object value, out double number)
        {
            number = 0;
            if (value == null || value is bool || value is string || !(value is IConvertible)) return false;
            try { number = Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture); }
            catch (Exception) { return false; }
            return !Double.IsNaN(number) && !Double.IsInfinity(number);
        }

        internal static double[] Point(object value)
        {
            object[] items = value as object[];
            if (items == null) items = ((ArrayList)value).ToArray();
            return items.Select(item => Convert.ToDouble(item, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
        }
    }
}
