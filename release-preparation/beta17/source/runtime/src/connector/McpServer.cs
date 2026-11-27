using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

// Smart Connector: one compiled program for the MCP server that Claude Desktop, Claude Code and Codex start to work
// with Revit and AutoCAD on this computer, and for the Smart Connector windows. The MCP server replaces the PowerShell
// bridges (src\autodesk\autodesk-bridge.ps1, src\revit\revit-bridge.ps1, src\autocad\autocad-bridge.ps1) with the same
// tools, answers and messages; the windows replace installer\SmartConnectorApp.ps1, SetupWizard.ps1 and
// ConnectorActions.ps1; the work behind their buttons is the install engine (engine) and, for Skills Sync, the PowerShell scripts.
//   SmartConnector.exe mcp                       MCP over stdio (one JSON-RPC message per line, UTF-8)
//   SmartConnector.exe --version                 print the connector version
//   SmartConnector.exe app [--section <name>]    the Smart Connector app (Overview, Autodesk, AI, Skills, Components,
//                                                Updates, Settings, Diagnostics or Help)
//   SmartConnector.exe setup                     the setup window
//   SmartConnector.exe action --action <name>    SkillsSync, CheckUpdates or Status, with its progress window
//   SmartConnector.exe settings                  the update-check setting
//   SmartConnector.exe signin-check              the once-a-day update reminder Windows starts at sign-in (SignInCheck.cs)
//   SmartConnector.exe engine --action <name>    the install engine (setup, repair, update, checks), see EngineCore.cs
// --smoke-test builds the windows without showing them or running anything, and exits 0.
// Built as a Windows (GUI) program so no console window flashes; Claude and Codex still talk to `mcp` over the
// pipes they pass in. C# 5 only: built with the .NET Framework compiler that ships with Windows
// (release-preparation\beta17\setup\build-connector-exe.ps1). Nothing is compiled on the PCs.
namespace SmartConnector
{
    public static class Program
    {
        [STAThread]
        public static int Main(string[] args)
        {
            // Files an update renamed aside while they were in use (this program's own earlier copy) go now. Best effort.
            EngineCleanup.DeleteLeftovers();
            // Claude Code, Codex and Node.js installed since Windows started are not on the inherited PATH.
            CommandPath.Refresh();
            // The first start of this version after an update reconnects the AI apps with this version's code (EngineClients.cs).
            AiAppsState.StartIfDue(args);
            // The update reminder at Windows sign-in, when update checks are on and an update from 1.2.3 did not add it.
            SignInCheck.EnsureRegistered(args);
            if (args.Length == 1 && args[0] == "mcp") return McpServer.Run();
            // `mcp --product autocad` (or revit) offers only that product's tools: fewer tool descriptions for the AI to carry in every session.
            if (args.Length == 3 && args[0] == "mcp" && args[1] == "--product" && (args[2] == "autocad" || args[2] == "revit")) { McpServer.Product = args[2]; return McpServer.Run(); }
            if (args.Length == 1 && args[0] == "--version") { AttachConsole(); Console.WriteLine(Paths.Version); return 0; }
            { int skillsCode; if (SkillsCommands.TryRun(args, out skillsCode)) return skillsCode; }
            string command = args.Length > 0 ? args[0] : "";
            if (command == "engine") return InstallEngine.RunCommand(args.Skip(1).ToArray());
            if (command == "signin-check") return SignInCheck.Run(args.Skip(1).ToArray());
            if (command == "app" || command == "setup" || command == "action" || command == "settings") return WindowCommands.Run(command, args.Skip(1).ToArray());
            AttachConsole();
            Console.Error.WriteLine("Smart Connector " + Paths.Version + ". Claude and Codex start it as: SmartConnector.exe mcp. The app opens with: SmartConnector.exe app");
            return 2;
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        private static extern bool AttachConsole(int processId);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        private static extern IntPtr GetStdHandle(int handle);

        // A Windows program has no console. When started from a console without redirected output (typing
        // SmartConnector.exe --version), write to that console; redirected output (pipes, files) is used as it is.
        internal static void AttachConsole()
        {
            try { if (GetStdHandle(-11) == IntPtr.Zero) AttachConsole(-1); }
            catch (Exception) { }
        }
    }

    // The window commands and their options (--name value, --flag).
    internal static class WindowCommands
    {
        internal static int Run(string command, string[] args)
        {
            Dictionary<string, string> options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < args.Length; i++)
            {
                if (!args[i].StartsWith("--")) continue;
                bool hasValue = i + 1 < args.Length && !args[i + 1].StartsWith("--");
                options[args[i].Substring(2)] = hasValue ? args[++i] : "";
            }
            bool smokeTest = options.ContainsKey("smoke-test");
            string value;
            try
            {
                // Hidden helpers for the tests: the status snapshot and action outcomes as JSON, and the icon check.
                if (command == "app" && options.ContainsKey("print-snapshot"))
                {
                    double now = options.TryGetValue("now", out value) && value.Length > 0 ? Double.Parse(value, System.Globalization.CultureInfo.InvariantCulture) : ConnectorStatus.Today;
                    Program.AttachConsole(); Console.WriteLine(ConnectorStatus.Describe(now));
                    return 0;
                }
                if (command == "action" && options.TryGetValue("outcome", out value))
                {
                    string errorText, exitCode;
                    options.TryGetValue("error", out errorText); options.TryGetValue("exit-code", out exitCode);
                    Console.WriteLine(ConnectorActions.Describe(value, new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)).ReadToEnd(), errorText ?? "", exitCode != null && exitCode.Length > 0 ? Int32.Parse(exitCode) : 0));
                    return 0;
                }
                if (command == "app" && options.ContainsKey("check-icons")) return CheckIcons();

                System.Windows.Forms.Application.EnableVisualStyles();
                int code;
                if (command == "app") code = SmartConnectorApp.Run(options.TryGetValue("section", out value) ? value : "Overview", smokeTest);
                else if (command == "setup") code = SetupCommand.Run(smokeTest);
                else if (command == "action") code = ActionWindow.Run(options.TryGetValue("action", out value) ? value : "Status", smokeTest);
                else code = SettingsWindow.Run(smokeTest);
                if (smokeTest && code == 0) Console.WriteLine("SMOKE_OK");
                return code;
            }
            catch (Exception exception)
            {
                if (smokeTest) { Console.Error.WriteLine(exception); return 1; }
                System.Windows.Forms.MessageBox.Show(exception.Message, Brand.Name, System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
                return 1;
            }
        }

        // Every icon renders through WPF, plain and as a tile, at 100 % and 150 % (as tests\test-design-system.ps1
        // checks for Brand.ps1). Prints one line per problem; exit code 1 when any icon drew nothing.
        private static int CheckIcons()
        {
            int problems = 0;
            foreach (string name in Brand.IconNames)
                foreach (double scale in new[] { 1.0, 1.5 })
                {
                    System.Drawing.Bitmap plain = Brand.IconImage(name, 24, null, 0, false, scale);
                    System.Drawing.Bitmap tile = Brand.IconImage(name, 32, null, 0, true, scale);
                    if (plain.Width != Brand.Round(24 * scale) || Ink(plain) <= 8) { problems++; Console.WriteLine("Icon " + name + " drew nothing at " + scale); }
                    if (Ink(tile) <= tile.Width * tile.Height * 0.6) { problems++; Console.WriteLine("Tile " + name + " is not filled at " + scale); }
                }
            if (Brand.IconError.Length > 0) Console.WriteLine("WPF: " + Brand.IconError);
            Console.WriteLine(problems == 0 ? "ICONS_OK " + Brand.IconNames.Length : "ICONS_FAILED " + problems);
            return problems == 0 ? 0 : 1;
        }

        private static int Ink(System.Drawing.Bitmap bitmap)
        {
            int count = 0;
            for (int x = 0; x < bitmap.Width; x++) for (int y = 0; y < bitmap.Height; y++) if (bitmap.GetPixel(x, y).A > 40) count++;
            return count;
        }
    }

    // Folders of the installed connector. The program lives in <install root>\bin.
    internal static class Paths
    {
        // %LOCALAPPDATA% first, as the PowerShell bridges and setup scripts use it (on a normal PC it is the same folder).
        internal static string LocalAppData
        {
            get
            {
                string variable = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                return String.IsNullOrWhiteSpace(variable) ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) : variable;
            }
        }
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

        // JSON with every non-ASCII character escaped, for output whose code page is not known (the windows' test helpers).
        internal static string Ascii(object value)
        {
            StringBuilder text = new StringBuilder();
            foreach (char c in Serializer.Serialize(value))
            {
                if (c < 128) text.Append(c);
                else text.Append("\\u").Append(((int)c).ToString("x4"));
            }
            return text.ToString();
        }
    }

    // A tool error that is reported to the AI client as the tool's text, as the PowerShell bridges did.
    internal class ToolException : Exception
    {
        internal ToolException(string message) : base(message) { }
    }

    internal static class McpServer
    {
        private static readonly string[] Protocols = { "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28" };
        private const string Instructions = "Before any Revit work call get_revit_rules and follow every rule it returns; the Revit model tools refuse to run until it has been called. Use list_skill_workflows and read_skill_workflow to load relevant shared guidance before CAD/BIM tasks; no separate skill upload is required to read this guidance. Authenticated Autodesk connector for Codex and Claude with AutoCAD, Revit and 3ds Max tools. Model-changing calls are serialized across AI clients. For AutoCAD, read drawing_info before edits and save only when explicitly requested. For Revit, read document_info before writes, pass expected_document, and verify every write with a separate read. With several Revit windows open, a call without session_id goes to the window whose active document is expected_document, otherwise to the Revit window used last; its answer names that session in routed_session_id. Call list_sessions and say which model you are working on when the user may mean another window. Revit errors are typed: [compile_error] and [runtime_error] are problems in the submitted code, not a lost connection. After a timeout or an answer with completed=false never run the request again: call connection_status (it says whether Revit is busy) and get_job with wait_seconds, which waits on the connector and answers the moment the job finishes; never sleep or pause in a shell between get_job calls. For 3ds Max, call max_scene_info first: lengths are returned in millimetres whatever the scene units; max_section cuts plan and section outlines from the model; pass expected_scene to execute_max_python and save only when the user asks.";
        private const string CombinedStatus = "Check whether the Smart Connector can reach AutoCAD, Revit and 3ds Max. Reports AutoCAD (running full AutoCAD over COM, version, active drawing), Revit (add-in sessions, active document, last error) and 3ds Max (bridge sessions, open scene) separately. Succeeds when either product is reachable; a product that is closed is reported, not an error. Optional session_id selects a Revit session.";

        // Every Revit model tool needs the Revit rules to have been read in this session, and again after two hours.
        private static DateTime _revitRulesReadAt = DateTime.MinValue;
        private static readonly TimeSpan RevitRulesFresh = TimeSpan.FromHours(2);
        internal const string RevitRulesFirst = "Call get_revit_rules first and follow every rule it returns, then repeat this call. The Revit rules are read once per session and again after two hours.";

        private static List<Dictionary<string, object>> _tools;
        private static readonly Dictionary<string, bool> ReadOnly = new Dictionary<string, bool>();
        private static readonly HashSet<string> AutoCadNames = new HashSet<string>();
        // Offline DWG tools (LibreDWG, DwgOffline.cs): they work on closed .dwg files and need neither AutoCAD nor Revit.
        private static readonly HashSet<string> DwgNames = new HashSet<string>();
        private static readonly HashSet<string> RevitNames = new HashSet<string>();
        // 3ds Max tools (MaxBridge.cs): a local bridge inside 3ds Max, reached over an owner-only named pipe.
        private static readonly HashSet<string> MaxNames = new HashSet<string>();

        // "" = both products; "autocad" or "revit" = only that product's tools (plus connection_status and the skill tools).
        internal static string Product = "";

        internal static List<Dictionary<string, object>> Tools
        {
            get
            {
                if (_tools != null) return _tools;
                List<Dictionary<string, object>> tools = new List<Dictionary<string, object>>();
                if (Product != "revit") foreach (Dictionary<string, object> tool in AutoCadBridge.Tools) { tools.Add(tool); AutoCadNames.Add((string)tool["name"]); }
                if (Product != "revit") foreach (Dictionary<string, object> tool in DwgOffline.Tools) { tools.Add(tool); DwgNames.Add((string)tool["name"]); }
                if (Product == "" || Product == MaxBridge.Product) foreach (Dictionary<string, object> tool in MaxBridge.Tools) { tools.Add(tool); MaxNames.Add((string)tool["name"]); }
                foreach (Dictionary<string, object> source in RevitBridge.Tools)
                {
                    if (Product == "autocad" && (string)source["name"] != "connection_status") continue;
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
                    "description", "List shared workflow guidance available through this connector: name, category and a one-line description. Pass product (autocad, revit or 3dsmax) to list only that product's workflows. Read the relevant workflow before a task.",
                    "inputSchema", Json.Object("type", "object", "properties", Json.Object("product", Json.Object("type", "string", "enum", new object[] { "autocad", "revit", "3dsmax", "all" }, "description", "Only this product's workflows")), "required", new object[0], "additionalProperties", false),
                    "annotations", Json.Object("readOnlyHint", true)));
                tools.Add(Json.Object("name", "read_skill_workflow",
                    "description", "Read a shared Autodesk workflow or its supporting text file. This returns guidance and does not execute code or modify a model.",
                    "inputSchema", Json.Object("type", "object",
                        "properties", Json.Object(
                            "name", Json.Object("type", "string", "description", "Skill folder name from list_skill_workflows"),
                            "file", Json.Object("type", "string", "description", "Relative text file within the skill; defaults to SKILL.md")),
                        "required", new object[] { "name" }),
                    "annotations", Json.Object("readOnlyHint", true)));
                tools.Add(Json.Object("name", "get_revit_rules",
                    "description", "Get the team's Revit rules: decisions, lessons and rejected approaches, by category. Call this FIRST before any Revit work and follow every rule returned; the Revit model tools refuse to run until it has been called in the session. Returns guidance only and does not touch a model.",
                    "inputSchema", Json.Object("type", "object", "properties", Json.Object()),
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
                if (name == "list_skill_workflows") data = Json.Object("skills", Workflows.ListAll(Json.GetString(arguments, "product")));
                else if (name == "read_skill_workflow") data = Workflows.Read(Json.GetString(arguments, "name"), Json.GetString(arguments, "file"));
                else if (name == "get_revit_rules") { data = RevitRules.Get(); _revitRulesReadAt = DateTime.UtcNow; }
                else if (name == "connection_status") data = ConnectionStatus(arguments);
                else if (DwgNames.Contains(name)) data = DwgOffline.Invoke(name, arguments);
                else if (AutoCadNames.Contains(name)) data = WithWriteLock(name, delegate { return AutoCadBridge.Invoke(name, arguments); });
                else if (MaxNames.Contains(name)) data = WithWriteLock(name, delegate { return MaxBridge.Invoke(name, arguments); });
                else if (RevitNames.Contains(name))
                {
                    if (name != "list_sessions" && name != "get_job" && DateTime.UtcNow - _revitRulesReadAt > RevitRulesFresh) throw new ToolException(RevitRulesFirst);
                    data = WithWriteLock(name, delegate { return RevitBridge.Invoke(name, arguments); });
                }
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
                Failures.Worked(name);
                return result;
            }
            catch (Exception exception)
            {
                Exception shown = exception is System.Reflection.TargetInvocationException && exception.InnerException != null ? exception.InnerException : exception;
                // Reported to the administrator, cleaned of drawing and model content (ConnectorFailures.cs).
                Failures.Failed(name, name == "connection_status" ? "connector" : AutoCadNames.Contains(name ?? "") ? "autocad" : RevitNames.Contains(name ?? "") ? "revit" : MaxNames.Contains(name ?? "") ? MaxBridge.Product : "connector", shown.Message);
                return Json.Object("content", new object[] { Json.Object("type", "text", "text", shown.Message) }, "isError", true);
            }
        }

        // Read-only status for both products. Succeeds when either is reachable; otherwise the error message carries
        // both product summaries so the client can tell the user what to start.
        private static object ConnectionStatus(object arguments)
        {
            Dictionary<string, object> autoCad = AutoCadBridge.ConnectionStatus();
            Dictionary<string, object> revit = RevitBridge.ConnectionStatus(arguments);
            Dictionary<string, object> max = Product == "" || Product == MaxBridge.Product ? MaxBridge.ConnectionStatus() : Json.Object("available", false, "summary", "not included in this connection.");
            string summary = "AutoCAD: " + Json.GetString(autoCad, "summary") + " Revit: " + Json.GetString(revit, "summary") + " 3ds Max: " + Json.GetString(max, "summary");
            if (!(true.Equals(autoCad["available"]) || true.Equals(revit["available"]) || true.Equals(max["available"])))
                throw new ToolException("Smart Connector is running, but neither AutoCAD nor Revit is reachable, and no 3ds Max bridge answers. " + summary);
            // Which program is answering: the compiled connector, not the PowerShell fallback (which lacks apply_plan, execute_autocad and generate_detail).
            return Json.Object("connected", true, "summary", summary, "bridge", Json.Object("kind", "exe", "version", Paths.Version, "tools", Tools.Count), "autocad", autoCad, "revit", revit, "max", max);
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

    // The team's Revit rules (revit-rules/rules.json in the shipped or approved skill library), returned by get_revit_rules.
    internal static class RevitRules
    {
        internal static Dictionary<string, object> Get()
        {
            string text;
            try { text = Json.GetString(Workflows.Read("revit-rules", "rules.json"), "content"); }
            catch (ToolException) { throw new ToolException("The Revit rules are not installed (revit-rules/rules.json). Reinstall the connector or run Skills Sync, then call get_revit_rules again."); }
            object parsed;
            try { parsed = Json.Serializer.DeserializeObject(text.TrimStart('\uFEFF')); }
            catch (Exception) { throw new ToolException("The Revit rules file (revit-rules/rules.json) is not valid JSON. Run Skills Sync or reinstall, then call get_revit_rules again."); }
            List<Dictionary<string, object>> rules = new List<Dictionary<string, object>>();
            object listed = Json.Get(parsed, "rules");
            IEnumerable items = listed as IEnumerable;
            if (items != null && !(listed is string))
            {
                foreach (object item in items)
                {
                    if (!(item is IDictionary<string, object>)) continue;
                    rules.Add(Json.Object(
                        "id", Json.GetString(item, "id"),
                        "title", Json.GetString(item, "title"),
                        "category", Json.GetString(item, "category"),
                        "decided_on", Json.GetString(item, "decided_on"),
                        "instruction", Json.GetString(item, "instruction")));
                }
            }
            List<object> ordered = rules.OrderBy(r => (string)r["category"], StringComparer.CurrentCultureIgnoreCase).Cast<object>().ToList();
            return Json.Object(
                "must_follow", "These rules apply to every Revit task. Follow every rule. If a rule conflicts with a skill or the request, say so and ask; never use a rejected approach. Report any rule you cannot follow.",
                "count", ordered.Count,
                "updated", Json.GetString(parsed, "updated"),
                "rules", ordered,
                "to_add_a_rule", "Only when the user asks after a finished task: read skill revit-rules (read_skill_workflow) for how to draft and save a rule.");
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
                    Dictionary<string, object> itemRule = rule.ContainsKey("items") ? rule["items"] as Dictionary<string, object> : null;
                    if (itemRule != null && Json.GetString(itemRule, "type") == "object")
                    {
                        // A list of objects (for example the steps of apply_plan); each step is checked by its own tool.
                        if (items == null) throw new ToolException("Invalid array: " + pair.Key);
                        if (rule.ContainsKey("minItems") && items.Length < Convert.ToInt32(rule["minItems"])) throw new ToolException("Too few entries: " + pair.Key);
                        if (rule.ContainsKey("maxItems") && items.Length > Convert.ToInt32(rule["maxItems"])) throw new ToolException("Too many entries: " + pair.Key);
                        foreach (object item in items) if (!(item is IDictionary<string, object>)) throw new ToolException("Every entry of " + pair.Key + " must be an object.");
                    }
                    else if (itemRule != null && Json.GetString(itemRule, "type") == "string")
                    {
                        // A list of names (for example the properties list_entities should read).
                        if (items == null) throw new ToolException("Invalid array: " + pair.Key);
                        if (items.Length > 40) throw new ToolException("Too many entries: " + pair.Key);
                        foreach (object item in items) if (!(item is string)) throw new ToolException("Every entry of " + pair.Key + " must be a string.");
                    }
                    else
                    {
                        if (items == null || items.Length != 3) throw new ToolException("A point must have three coordinates.");
                        foreach (object item in items) { double coordinate; if (!TryNumber(item, out coordinate)) throw new ToolException("Coordinates must be finite numbers."); }
                    }
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
