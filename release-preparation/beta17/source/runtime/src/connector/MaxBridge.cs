using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

// 3ds Max tools. The bridge inside 3ds Max (src\3dsmax\SmartConnector3dsMax.bundle, Python) registers each running
// session in %LOCALAPPDATA%\BIM-CAD-MCP\runtime\max-sessions\<session>.json with its pipe name and a random token, and
// answers on a local named pipe that only the signed-in Windows user can open and that refuses remote clients.
// Before a request is sent, the pipe's server process must be the registered 3ds Max process (GetNamedPipeServerProcessId),
// so another program that takes the pipe name never receives the token or the code. Nothing here uses the network.
namespace SmartConnector
{
    internal static class MaxBridge
    {
        internal const string Product = "3dsmax";
        private static List<Dictionary<string, object>> _tools;

        internal static string SessionsFolder { get { return Path.Combine(Paths.LocalAppData, "BIM-CAD-MCP", "runtime", "max-sessions"); } }

        internal static List<Dictionary<string, object>> Tools
        {
            get
            {
                if (_tools != null) return _tools;
                Func<string, Dictionary<string, object>> text = description => Json.Object("type", "string", "minLength", 1, "description", description);
                Func<Dictionary<string, object>> session = () => text("3ds Max session ID from max_list_sessions. Optional with one 3ds Max window open.");
                Func<Dictionary<string, object>> handles = () => Json.Object("type", "array", "items", Json.Object("type", "string"), "maxItems", 40, "description", "Object handles from max_list_objects.");
                Func<Dictionary<string, object>> names = () => Json.Object("type", "array", "items", Json.Object("type", "string"), "maxItems", 40, "description", "Exact object names (every object with that name).");
                Func<Dictionary<string, object>> folder = () => text("Existing absolute local folder for the file. Default: %LOCALAPPDATA%\\BIM-CAD-MCP\\exports\\3dsmax. Files are never overwritten. A cloud-synced project folder uploads the file.");
                Func<Dictionary<string, object>> flag = () => Json.Object("type", "boolean");
                _tools = new List<Dictionary<string, object>>
                {
                    Schema.Tool("max_list_sessions", "List running 3ds Max sessions that have the Smart Connector bridge: session ID, 3ds Max version, open scene, busy state. Call this first when more than one 3ds Max window is open.", Json.Object(), new string[0], true),
                    Schema.Tool("max_scene_info", "Read the open 3ds Max scene: file, save state, system units and the millimetres per unit, object and geometry counts, selection count, layers. Call before other 3ds Max tools.", Json.Object("session_id", session()), new string[0], true),
                    Schema.Tool("max_list_objects", "List scene objects: handle, name, class, layer, parent, hidden state, world bounding box in mm, material name. Geometry only and visible only by default; 100 per call (limit up to 500), continue from next_offset.",
                        Json.Object("session_id", session(), "layer", text("Only objects on this layer."), "name_contains", text("Only names containing this text (case-insensitive)."),
                            "selected_only", flag(), "include_hidden", flag(), "geometry_only", flag(),
                            "offset", Json.Object("type", "integer", "minimum", 0), "limit", Json.Object("type", "integer", "minimum", 1, "maximum", 500)), new string[0], true),
                    Schema.Tool("max_get_object", "Read one object: transform (mm, degrees), bounding box in mm, vertex and face counts, modifiers, material (class, colour, texture file names), wire colour, user properties. Give handle, or a unique name.",
                        Json.Object("session_id", session(), "handle", text("Object handle from max_list_objects."), "name", text("Exact object name; must be unique.")), new string[0], true),
                    Schema.Tool("max_section", "Cut the scene's geometry with a plane and return the section outlines as 2D polylines in mm: plan cuts (axis z at a height), vertical cuts (axis x or y), or any plane (point and normal, in mm). Points are [u, v] on the plane; for axis z they are world X and Y, for x and y the second value is the height. Each object keeps its own polylines. output_dxf also writes an R12 DXF (one layer per object) for AutoCAD. Targets: handles, names, selected_only, or else every visible geometry object. Does not change the scene.",
                        Json.Object("session_id", session(), "handles", handles(), "names", names(), "selected_only", flag(),
                            "axis", Json.Object("type", "string", "enum", new object[] { "x", "y", "z" }), "offset_mm", Json.Object("type", "number", "description", "Plane position along axis, world mm."),
                            "point", Json.Object("type", "array", "description", "A point on the plane, world mm."), "normal", Json.Object("type", "array", "description", "Plane normal."),
                            "tolerance_mm", Json.Object("type", "number", "minimum", 0, "maximum", 50, "description", "Simplification tolerance; default 0.5. 0 keeps every mesh point."),
                            "max_faces", Json.Object("type", "integer", "minimum", 1, "maximum", 2000000), "max_points", Json.Object("type", "integer", "minimum", 100, "maximum", 200000),
                            "output_dxf", flag(), "output_folder", folder(), "timeout_seconds", Json.Object("type", "integer", "minimum", 1, "maximum", 300)), new string[0], true),
                    Schema.Tool("max_capture_viewport", "Save the active 3ds Max viewport as a PNG on this computer and return its path. Does not change the scene.",
                        Json.Object("session_id", session(), "output_folder", folder()), new string[0], true),
                    Schema.Tool("max_export", "Export objects to a new OBJ, FBX or DWG file on this computer (never overwrites). Targets: handles, names, selected_only, or else every visible object. The selection is restored afterwards; the scene is not changed.",
                        Json.Object("session_id", session(), "handles", handles(), "names", names(), "selected_only", flag(),
                            "format", Json.Object("type", "string", "enum", new object[] { "obj", "fbx", "dwg" }), "output_folder", folder(),
                            "timeout_seconds", Json.Object("type", "integer", "minimum", 1, "maximum", 300)), new[] { "format" }, false),
                    Schema.Tool("execute_max_python", "Run controlled Python (pymxs) in 3ds Max for work the other tools do not cover. Variables: rt (pymxs.runtime), pymxs, params (parsed parameters_json), mm_per_unit; set result to a JSON-friendly value. execution_mode read for inspection (allow_model_changes=false; a scene change is reported); write runs inside one undo block (allow_model_changes=true). Pass expected_scene from max_scene_info. Never saves unless the code does. Not a sandbox: it runs with the user's Windows permissions, so send only code you have read.",
                        Json.Object("session_id", session(), "expected_scene", text("scene from max_scene_info (full path, or untitled)."),
                            "execution_mode", Json.Object("type", "string", "enum", new object[] { "read", "write" }), "allow_model_changes", flag(),
                            "code", Json.Object("type", "string", "minLength", 1, "maxLength", 100000), "parameters_json", Json.Object("type", "string", "maxLength", 1000000),
                            "timeout_seconds", Json.Object("type", "integer", "minimum", 1, "maximum", 300)),
                        new[] { "expected_scene", "execution_mode", "allow_model_changes", "code" }, false),
                };
                return _tools;
            }
        }

        // ---------- sessions ----------

        private sealed class Session
        {
            internal string Id, PipeName, Token, Version, StartedUtc;
            internal int ProcessId;
        }

        private static List<Session> RegisteredSessions()
        {
            List<Session> sessions = new List<Session>();
            if (!Directory.Exists(SessionsFolder)) return sessions;
            foreach (string file in Directory.GetFiles(SessionsFolder, "*.json"))
            {
                try
                {
                    object record = Json.Serializer.DeserializeObject(File.ReadAllText(file));
                    int processId = Convert.ToInt32(Json.Get(record, "pid"), CultureInfo.InvariantCulture);
                    string pipe = Json.GetString(record, "pipe_name"), token = Json.GetString(record, "token"), id = Json.GetString(record, "session_id");
                    if (!Regex.IsMatch(pipe, @"^SmartConnector\.Max\.\d{4}\.\d+$") || !Regex.IsMatch(token, "^[0-9a-f]{64}$") || id.Length == 0) continue;
                    // A file left by a 3ds Max that has closed (or whose process ID now belongs to another program) is ignored.
                    using (Process process = Process.GetProcessById(processId))
                        if (!String.Equals(process.ProcessName, "3dsmax", StringComparison.OrdinalIgnoreCase)) continue;
                    sessions.Add(new Session { Id = id, PipeName = pipe, Token = token, ProcessId = processId,
                        Version = Json.GetString(record, "max_version"), StartedUtc = Json.GetString(record, "started_utc") });
                }
                catch (Exception) { }
            }
            return sessions.OrderBy(s => s.ProcessId).ToList();
        }

        private static Session Resolve(string sessionId)
        {
            List<Session> sessions = RegisteredSessions();
            if (!String.IsNullOrWhiteSpace(sessionId))
            {
                Session match = sessions.FirstOrDefault(s => s.Id == sessionId);
                if (match == null) throw new ToolException("3ds Max session was not found: " + sessionId + ". Call max_list_sessions again.");
                return match;
            }
            if (sessions.Count == 1) return sessions[0];
            if (sessions.Count == 0)
                throw new ToolException("[max_unavailable] No 3ds Max session with the Smart Connector bridge is running. Open 3ds Max 2023-2027 after installing the connector (the bridge starts with 3ds Max), then retry.");
            throw new ToolException("More than one 3ds Max window is open: " + String.Join(", ", sessions.Select(s => s.Id)) + ". Call max_list_sessions and pass session_id.");
        }

        // ---------- pipe ----------

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint serverProcessId);

        private static object Call(Session session, string operation, Dictionary<string, object> arguments, int connectTimeout, int answerTimeout)
        {
            // Anonymous: the bridge needs no identity from us and cannot impersonate this process.
            using (NamedPipeClientStream client = new NamedPipeClientStream(".", session.PipeName, PipeDirection.InOut, PipeOptions.None, TokenImpersonationLevel.Anonymous))
            {
                try { client.Connect(connectTimeout); }
                catch (TimeoutException) { throw new ToolException("[max_unavailable] 3ds Max session " + session.Id + " did not answer. Its bridge may have stopped; restart 3ds Max."); }
                uint serverProcess;
                if (!GetNamedPipeServerProcessId(client.SafePipeHandle.DangerousGetHandle(), out serverProcess) || serverProcess != (uint)session.ProcessId)
                    throw new ToolException("[unauthorized] The pipe for 3ds Max session " + session.Id + " is not owned by that 3ds Max process. Nothing was sent.");
                string request = operation + "\t" + session.Token + "\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(Json.Serializer.Serialize(arguments))) + "\n";
                string answer = null;
                Exception failure = null;
                Thread exchange = new Thread(delegate ()
                {
                    try
                    {
                        byte[] bytes = Encoding.UTF8.GetBytes(request);
                        client.Write(bytes, 0, bytes.Length);
                        client.Flush();
                        using (StreamReader reader = new StreamReader(client, new UTF8Encoding(false), false, 65536, true)) answer = reader.ReadLine();
                    }
                    catch (Exception exception) { failure = exception; }
                });
                exchange.IsBackground = true;
                exchange.Start();
                if (!exchange.Join(answerTimeout))
                    throw new ToolException("[max_busy] 3ds Max did not answer in time. Call max_list_sessions (it reports whether 3ds Max is busy) before retrying.");
                if (failure != null) throw new ToolException("[max_unavailable] The 3ds Max bridge closed the connection: " + failure.Message);
                if (String.IsNullOrWhiteSpace(answer)) throw new ToolException("[max_unavailable] The 3ds Max bridge returned an empty answer.");
                string[] parts = answer.Split(new[] { '\t' }, 2);
                if (parts.Length != 2) throw new ToolException("The 3ds Max bridge returned an invalid answer.");
                string payload = Encoding.UTF8.GetString(Convert.FromBase64String(parts[1]));
                if (parts[0] == "ERR") throw new ToolException(Regex.IsMatch(payload, @"^\[[a-z_]+\] ") ? payload : "[max_error] " + payload);
                if (parts[0] != "OK") throw new ToolException("The 3ds Max bridge returned an unknown answer.");
                return Json.Serializer.DeserializeObject(payload);
            }
        }

        private static object Status(Session session, int connectTimeout)
        {
            return Call(session, "status", new Dictionary<string, object>(), connectTimeout, 3000);
        }

        // ---------- tools ----------

        internal static object Invoke(string name, object arguments)
        {
            IDictionary<string, object> a = Schema.Check(Tools, name, arguments, false);
            if (name == "max_list_sessions") return Json.Object("sessions", ListSessions());
            // Argument checks first, so a wrong call is answered the same way whether or not 3ds Max is open.
            if (name == "max_get_object" && (Json.GetString(a, "handle").Length > 0) == (Json.GetString(a, "name").Length > 0))
                throw new ToolException("Give either handle or name.");
            if (name == "max_section" && !a.ContainsKey("axis") && !(a.ContainsKey("point") && a.ContainsKey("normal")))
                throw new ToolException("Give axis with offset_mm, or point and normal.");
            if (name == "execute_max_python" && Json.GetString(a, "execution_mode") == "read" && (bool)a["allow_model_changes"])
                throw new ToolException("execution_mode read needs allow_model_changes=false.");
            if (name == "execute_max_python" && Json.GetString(a, "execution_mode") == "write" && !(bool)a["allow_model_changes"])
                throw new ToolException("execution_mode write needs allow_model_changes=true.");
            Session session = Resolve(Json.GetString(a, "session_id"));
            Dictionary<string, object> forward = a.Where(p => p.Key != "session_id").ToDictionary(p => p.Key, p => p.Value);
            int timeout = forward.ContainsKey("timeout_seconds") ? Convert.ToInt32(forward["timeout_seconds"], CultureInfo.InvariantCulture) : 120;
            int answerTimeout = (timeout + 15) * 1000;
            switch (name)
            {
                case "max_scene_info": return Call(session, "scene_info", forward, 2000, answerTimeout);
                case "max_list_objects": return Call(session, "list_objects", forward, 2000, answerTimeout);
                case "max_get_object":
                {
                    string handle = Json.GetString(a, "handle"), objectName = Json.GetString(a, "name");
                    Dictionary<string, object> target = handle.Length > 0 ? Json.Object("handles", new object[] { handle }) : Json.Object("names", new object[] { objectName });
                    return Call(session, "get_object", target, 2000, answerTimeout);
                }
                case "max_section":
                    return Call(session, "section", forward, 2000, answerTimeout);
                case "max_capture_viewport": return Call(session, "capture_viewport", forward, 2000, answerTimeout);
                case "max_export": return Call(session, "export", forward, 2000, answerTimeout);
                case "execute_max_python":
                    return Call(session, "execute_python", forward, 2000, answerTimeout);
            }
            throw new ToolException("Unknown 3ds Max tool: " + name);
        }

        private static List<object> ListSessions()
        {
            List<object> result = new List<object>();
            foreach (Session session in RegisteredSessions())
            {
                Dictionary<string, object> entry = Json.Object("session_id", session.Id, "process_id", session.ProcessId, "max_version", session.Version, "started_utc", session.StartedUtc);
                try
                {
                    object status = Status(session, 500);
                    entry["connected"] = true;
                    entry["scene"] = Json.GetString(status, "scene");
                    entry["saved"] = Json.Get(status, "saved");
                    entry["busy"] = Json.Get(status, "busy");
                    entry["bridge_version"] = Json.GetString(status, "bridge_version");
                }
                catch (Exception exception) { entry["connected"] = false; entry["error"] = exception.Message; }
                result.Add(entry);
            }
            return result;
        }

        internal static Dictionary<string, object> ConnectionStatus()
        {
            List<object> sessions;
            try { sessions = ListSessions(); }
            catch (Exception exception) { return Json.Object("available", false, "sessions", new object[0], "summary", "3ds Max status could not be read: " + exception.Message); }
            int connected = sessions.Count(s => true.Equals(Json.Get(s, "connected")));
            bool running = Process.GetProcessesByName("3dsmax").Length > 0;
            string summary;
            if (connected == 1) summary = "3ds Max " + Json.GetString(sessions.First(s => true.Equals(Json.Get(s, "connected"))), "max_version") + " is connected; scene: " +
                Path.GetFileName(Json.GetString(sessions.First(s => true.Equals(Json.Get(s, "connected"))), "scene")) + ".";
            else if (connected > 1) summary = connected + " 3ds Max sessions are connected; pass session_id (max_list_sessions).";
            else if (running) summary = "3ds Max is running, but its Smart Connector bridge is not answering. Restart 3ds Max after installing the connector.";
            else summary = "3ds Max is not running.";
            return Json.Object("available", connected > 0, "running", running, "sessions", sessions, "summary", summary);
        }
    }
}
