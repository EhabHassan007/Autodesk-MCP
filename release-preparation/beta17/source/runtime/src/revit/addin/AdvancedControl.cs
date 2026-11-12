using System;
using System.CodeDom.Compiler;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using Microsoft.CSharp;
using Autodesk.Revit.Attributes;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;
using System.Windows;
using System.Windows.Media;

namespace BimCadMcp.Revit
{
    internal sealed class ConnectionSnapshot
    {
        internal bool ServerRunning;
        internal string SessionId;
        internal int ProcessId;
        internal string RevitVersion;
        internal string PipeName;
        internal DateTime StartedUtc;
        internal DateTime LastClientUtc;
        internal DateTime LastRequestUtc;
        internal long RequestCount;
        internal string LastOperation;
        internal string LastError;
        internal string DocumentId;
    }

    internal static class ConnectionState
    {
        private static readonly object Gate = new object();
        private static readonly ConnectionSnapshot State = new ConnectionSnapshot();

        internal static void MarkServerStarted(string revitVersion, string sessionId, string pipeName)
        {
            lock (Gate)
            {
                State.ServerRunning = true;
                State.SessionId = sessionId ?? String.Empty;
                State.ProcessId = Process.GetCurrentProcess().Id;
                State.RevitVersion = revitVersion ?? String.Empty;
                State.PipeName = pipeName ?? String.Empty;
                State.StartedUtc = DateTime.UtcNow;
                State.LastError = String.Empty;
            }
        }

        // The active document as last seen on Revit's thread, so a status answer can still name it while Revit is busy.
        internal static void SetDocumentId(string documentId)
        {
            lock (Gate) State.DocumentId = documentId ?? String.Empty;
        }

        internal static void MarkServerStopped()
        {
            lock (Gate) State.ServerRunning = false;
        }

        internal static void MarkClientConnected()
        {
            lock (Gate) State.LastClientUtc = DateTime.UtcNow;
        }

        internal static void MarkRequestSucceeded(string operation)
        {
            lock (Gate)
            {
                State.LastRequestUtc = DateTime.UtcNow;
                State.RequestCount++;
                State.LastOperation = operation ?? String.Empty;
                State.LastError = String.Empty;
            }
        }

        internal static void MarkRequestFailed(string operation, string error)
        {
            lock (Gate)
            {
                State.LastRequestUtc = DateTime.UtcNow;
                State.RequestCount++;
                State.LastOperation = operation ?? String.Empty;
                State.LastError = error ?? String.Empty;
            }
        }

        internal static ConnectionSnapshot Read()
        {
            lock (Gate)
            {
                return new ConnectionSnapshot
                {
                    ServerRunning = State.ServerRunning,
                    SessionId = State.SessionId,
                    ProcessId = State.ProcessId,
                    RevitVersion = State.RevitVersion,
                    PipeName = State.PipeName,
                    StartedUtc = State.StartedUtc,
                    LastClientUtc = State.LastClientUtc,
                    LastRequestUtc = State.LastRequestUtc,
                    RequestCount = State.RequestCount,
                    LastOperation = State.LastOperation,
                    LastError = State.LastError,
                    DocumentId = State.DocumentId ?? String.Empty
                };
            }
        }
    }

    internal static class SessionRegistry
    {
        private static string DirectoryPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "BIM-CAD-MCP", "runtime", "revit-sessions");
            }
        }

        internal static void Register(string sessionId, string revitVersion, string pipeName)
        {
            try
            {
                Directory.CreateDirectory(DirectoryPath);
                int processId = Process.GetCurrentProcess().Id;
                string payload = "{" +
                    Json.Property("session_id", sessionId) + "," +
                    Json.Property("pid", processId.ToString(CultureInfo.InvariantCulture)) + "," +
                    Json.Property("revit_version", revitVersion) + "," +
                    Json.Property("pipe_name", pipeName) + "," +
                    Json.Property("started_utc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)) +
                    "}";
                string path = Path.Combine(DirectoryPath, sessionId + ".json");
                string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                File.WriteAllText(temporary, payload, new UTF8Encoding(false));
                if (File.Exists(path)) File.Delete(path);
                File.Move(temporary, path);
            }
            catch (Exception exception)
            {
                System.Diagnostics.Debug.WriteLine("Smart Connector session registration error: " + exception);
            }
        }

        internal static void Unregister(string sessionId)
        {
            try
            {
                string path = Path.Combine(DirectoryPath, sessionId + ".json");
                if (File.Exists(path)) File.Delete(path);
            }
            catch (Exception exception)
            {
                System.Diagnostics.Debug.WriteLine("Smart Connector session cleanup error: " + exception);
            }
        }
    }

    [Transaction(TransactionMode.Manual)]
    [Regeneration(RegenerationOption.Manual)]
    public sealed class ConnectionStatusCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData commandData, ref string message, ElementSet elements)
        {
            ConnectionSnapshot snapshot = ConnectionState.Read();
            DateTime now = DateTime.UtcNow;
            bool recent = snapshot.LastClientUtc != DateTime.MinValue && now - snapshot.LastClientUtc <= TimeSpan.FromMinutes(2);
            UIDocument uiDocument = commandData.Application.ActiveUIDocument;
            string documentName = uiDocument == null ? "No project open" : uiDocument.Document.Title;
            TaskDialog dialog = new TaskDialog(Brand.Name);
            dialog.MainInstruction = snapshot.ServerRunning
                ? (recent ? "An AI client recently connected" : "Local MCP server is ready")
                : "MCP server is stopped";
            dialog.MainContent =
                "Status: " + (snapshot.ServerRunning ? "Running" : "Stopped") + "\n" +
                "Revit: " + snapshot.RevitVersion + "\n" +
                "Session: " + snapshot.SessionId + "\n" +
                "Document: " + documentName + "\n" +
                "Pipe: " + snapshot.PipeName + "\n" +
                "Transport: Local named pipe on this computer only\n" +
                "Requests served: " + snapshot.RequestCount.ToString(CultureInfo.InvariantCulture) + "\n" +
                "Last operation: " + EmptyAsDash(snapshot.LastOperation) + "\n" +
                "Last client connection: " + FormatUtc(snapshot.LastClientUtc) + "\n" +
                "Last error: " + EmptyAsDash(snapshot.LastError) + "\n\n" +
                "Claude Desktop, Claude Code and Codex on this computer connect through Smart Connector.";
            dialog.CommonButtons = TaskDialogCommonButtons.Close;
            dialog.Show();
            return Result.Succeeded;
        }

        private static string FormatUtc(DateTime value)
        {
            if (value == DateTime.MinValue) return "None";
            return value.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        }

        private static string EmptyAsDash(string value)
        {
            return String.IsNullOrWhiteSpace(value) ? "None" : value;
        }
    }

    internal static class AdvancedControl
    {
        // Answered on the pipe thread. documentId is null when Revit's thread did not answer (busy): the last known one is used.
        internal static string ConnectionStatus(string documentId, string busyState, string busyReason, List<Job> activeJobs)
        {
            ConnectionSnapshot state = ConnectionState.Read();
            bool stale = documentId == null;
            string shownDocument = stale ? state.DocumentId : documentId;
            bool recent = state.LastClientUtc != DateTime.MinValue && DateTime.UtcNow - state.LastClientUtc <= TimeSpan.FromMinutes(2);
            return "{" +
                Json.Property("server_running", state.ServerRunning) + "," +
                Json.Property("recent_client", recent) + "," +
                Json.Property("session_id", state.SessionId) + "," +
                Json.Property("process_id", state.ProcessId.ToString(CultureInfo.InvariantCulture)) + "," +
                Json.Property("revit_version", state.RevitVersion) + "," +
                Json.Property("pipe_name", state.PipeName) + "," +
                Json.Property("document_id", shownDocument) + "," +
                Json.Property("document_id_stale", stale) + "," +
                Json.Property("busy", busyState != "idle") + "," +
                Json.Property("busy_state", busyState) + "," +
                Json.Property("busy_reason", busyReason) + "," +
                "\"active_jobs\":[" + String.Join(",", activeJobs.Select(j => Jobs.ToJson(j, false)).ToArray()) + "]," +
                Json.Property("request_count", state.RequestCount.ToString(CultureInfo.InvariantCulture)) + "," +
                Json.Property("last_operation", state.LastOperation) + "," +
                Json.Property("last_error", state.LastError) +
                "}";
        }

        // Said in the compile errors and in the execute_csharp tool description.
        private const string RunnerContract = "Runner contract: the code is the body of Run(UIApplication application, Document document, string parametersJson) and must return a string; those three are the only variables (there is no doc, uidoc or commandData). " +
            "Language level is C# 5: no ?. , no $\"\" interpolation, no nameof, no expression-bodied members, no out var, no pattern matching. " +
            "Namespaces already imported: System, System.Collections.Generic, System.Globalization, System.IO, System.Linq, System.Text, Autodesk.Revit.DB, Autodesk.Revit.UI; any other namespace needs its full name.";

        internal static string ExecuteCSharp(
            UIApplication application,
            Document document,
            string expectedDocument,
            string executionMode,
            string allowModelChanges,
            string code,
            string parametersJson,
            string transactionName,
            string optionsText)
        {
            if (!String.Equals(RevitOperations.DocumentId(document), expectedDocument, StringComparison.OrdinalIgnoreCase))
                throw new McpException("document_changed", "Active Revit document changed. Read document_info again.");
            if (document.IsReadOnly) throw new McpException("document_read_only", "The active Revit document is read-only.");
            if (String.IsNullOrWhiteSpace(code)) throw new McpException("invalid_request", "C# code is required.");
            if (code.Length > 100000) throw new McpException("invalid_request", "C# code exceeds the 100,000 character limit.");

            string mode = (executionMode ?? String.Empty).Trim().ToLowerInvariant();
            if (mode != "read" && mode != "transaction" && mode != "manual")
                throw new McpException("invalid_request", "execution_mode must be read, transaction, or manual.");
            bool allowChanges;
            if (!Boolean.TryParse(allowModelChanges, out allowChanges))
                throw new McpException("invalid_request", "allow_model_changes must be true or false.");
            if ((mode == "transaction" || mode == "manual") && !allowChanges)
                throw new McpException("invalid_request", "Model-changing execution requires allow_model_changes=true.");
            if (mode == "read" && allowChanges)
                throw new McpException("invalid_request", "Read execution requires allow_model_changes=false.");
            RunOptions options = RunOptions.Parse(optionsText, 60);
            if (options.DryRun && mode != "transaction")
                throw new McpException("invalid_request", "dry_run needs execution_mode transaction: only the automatic transaction can be rolled back.");
            if (String.IsNullOrWhiteSpace(transactionName)) transactionName = "Execute controlled C#";

            ProgressSlot.Install();
            string source =
                "using System;\n" +
                "using System.Collections.Generic;\n" +
                "using System.Globalization;\n" +
                "using System.IO;\n" +
                "using System.Linq;\n" +
                "using System.Text;\n" +
                "using Autodesk.Revit.DB;\n" +
                "using Autodesk.Revit.UI;\n" +
                "public static class McpProgress {\n" +
                "  public static void Report(int done, int total, string note) {\n" +
                "    Action<int, int, string> report = AppDomain.CurrentDomain.GetData(\"BimCadMcp.Progress\") as Action<int, int, string>;\n" +
                "    if (report != null) report(done, total, note);\n" +
                "  }\n" +
                "  public static void Report(int done, int total) { Report(done, total, \"\"); }\n" +
                "}\n" +
                "public static class BimCadMcpDynamicEntry {\n" +
                "  public static string Run(UIApplication application, Document document, string parametersJson) {\n" +
                "#line 1 \"mcp_code.cs\"\n" + code + "\n#line default\n" +
                "  }\n" +
                "}\n";

            CompilerParameters compilerParameters = new CompilerParameters();
            compilerParameters.GenerateExecutable = false;
            compilerParameters.GenerateInMemory = true;
            compilerParameters.IncludeDebugInformation = false;
            compilerParameters.TreatWarningsAsErrors = false;
            compilerParameters.CompilerOptions = "/optimize";

            HashSet<string> references = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            AddReference(references, compilerParameters, typeof(Object).Assembly.Location);
            AddReference(references, compilerParameters, typeof(Enumerable).Assembly.Location);
            AddReference(references, compilerParameters, typeof(Uri).Assembly.Location);
            AddReference(references, compilerParameters, typeof(CSharpCodeProvider).Assembly.Location);
            AddReference(references, compilerParameters, typeof(Document).Assembly.Location);
            AddReference(references, compilerParameters, typeof(UIApplication).Assembly.Location);

            CompilerResults results;
            using (CSharpCodeProvider provider = new CSharpCodeProvider(new Dictionary<string, string> { { "CompilerVersion", "v4.0" } }))
            {
                results = provider.CompileAssemblyFromSource(compilerParameters, source);
            }
            if (results.Errors.HasErrors) throw new McpException("compile_error", CompileMessage(results, code));

            Type entry = results.CompiledAssembly.GetType("BimCadMcpDynamicEntry", true);
            MethodInfo run = entry.GetMethod("Run", BindingFlags.Public | BindingFlags.Static);
            if (run == null) throw new McpException("compile_error", "Compiled C# entry point was not found.");

            string resultText;
            string changesJson = "";
            if (mode == "transaction")
            {
                resultText = Changes.Run(document, "Smart Connector: " + transactionName, options.DryRun, delegate { return Invoke(run, application, document, parametersJson); }, out changesJson);
            }
            else
            {
                resultText = Invoke(run, application, document, parametersJson);
            }

            return "{" +
                Json.Property("document_id", RevitOperations.DocumentId(document)) + "," +
                Json.Property("execution_mode", mode) + "," +
                (options.DryRun ? Json.Property("dry_run", true) + "," + Json.Property("rolled_back", true) + ",\"changes\":" + changesJson + "," : "") +
                Json.Property("result", resultText ?? String.Empty) +
                "}";
        }

        // The compiler errors with the user's own line numbers, and a hint for the mistakes this runner has seen most.
        private static string CompileMessage(CompilerResults results, string code)
        {
            StringBuilder errors = new StringBuilder("C# compilation failed (your code did not run and nothing was changed):");
            bool unknownName = false;
            foreach (CompilerError error in results.Errors)
            {
                if (error.IsWarning) continue;
                errors.Append("\nLine ").Append(error.Line.ToString(CultureInfo.InvariantCulture)).Append(": ").Append(error.ErrorText);
                if (error.ErrorNumber == "CS0103") unknownName = true;
            }
            if (unknownName) errors.Append("\nHint: the Revit document variable is called document (not doc); there is no uidoc, so use application.ActiveUIDocument.");
            if (code.Contains("?.") || code.Contains("?[")) errors.Append("\nHint: ?. and ?[ are not available at this language level; test for null explicitly.");
            if (code.Contains("$\"")) errors.Append("\nHint: $\"...\" string interpolation is not available; use String.Format or concatenation.");
            if (code.Contains("nameof(")) errors.Append("\nHint: nameof is not available; use a string.");
            errors.Append("\n").Append(RunnerContract);
            return errors.ToString();
        }

        private static string Invoke(MethodInfo run, UIApplication application, Document document, string parametersJson)
        {
            try
            {
                object result = run.Invoke(null, new object[] { application, document, parametersJson ?? String.Empty });
                return result == null ? String.Empty : Convert.ToString(result, CultureInfo.InvariantCulture);
            }
            catch (TargetInvocationException exception)
            {
                Exception inner = exception.InnerException ?? exception;
                throw new McpException("runtime_error", "C# execution failed (the code compiled and ran, then threw): " + inner.GetType().Name + ": " + inner.Message, inner);
            }
        }

        private static void AddReference(HashSet<string> known, CompilerParameters parameters, string path)
        {
            if (String.IsNullOrWhiteSpace(path) || !File.Exists(path) || !known.Add(path)) return;
            parameters.ReferencedAssemblies.Add(path);
        }
    }
}
