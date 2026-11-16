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
using Autodesk.Revit.DB.Events;
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
            if (mode == "transaction" && !allowChanges)
                throw new McpException("invalid_request", "Model-changing execution requires allow_model_changes=true. To work only in family documents, use manual with allow_model_changes=false.");
            // manual with allow_model_changes=false is a probe: the code may create, edit, save and close family documents,
            // but every change to the project document is rolled back and reported (see RunProbe).
            bool probe = mode == "manual" && !allowChanges;
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

            // Debug information lets a runtime error name the script line (the #line directive maps it to mcp_code.cs). The script
            // is compiled into a private temporary folder and loaded from bytes together with its PDB: CodeDom's GenerateInMemory
            // loads the DLL without the PDB, so stack frames would carry no line numbers. Loading bytes locks no file, and the
            // folder is deleted afterwards.
            string buildFolder = Path.Combine(Path.GetTempPath(), "BimCadMcp-csharp-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(buildFolder);
            string assemblyPath = Path.Combine(buildFolder, "mcp_code.dll");
            CompilerParameters compilerParameters = new CompilerParameters();
            compilerParameters.GenerateExecutable = false;
            compilerParameters.GenerateInMemory = false;
            compilerParameters.OutputAssembly = assemblyPath;
            compilerParameters.TempFiles = new TempFileCollection(buildFolder, false);
            compilerParameters.IncludeDebugInformation = true;
            compilerParameters.TreatWarningsAsErrors = false;

            HashSet<string> references = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            AddReference(references, compilerParameters, typeof(Object).Assembly.Location);
            AddReference(references, compilerParameters, typeof(Enumerable).Assembly.Location);
            AddReference(references, compilerParameters, typeof(Uri).Assembly.Location);
            AddReference(references, compilerParameters, typeof(CSharpCodeProvider).Assembly.Location);
            AddReference(references, compilerParameters, typeof(Document).Assembly.Location);
            AddReference(references, compilerParameters, typeof(UIApplication).Assembly.Location);

            Assembly compiled;
            try
            {
                CompilerResults results;
                using (CSharpCodeProvider provider = new CSharpCodeProvider(new Dictionary<string, string> { { "CompilerVersion", "v4.0" } }))
                {
                    results = provider.CompileAssemblyFromSource(compilerParameters, source);
                }
                if (results.Errors.HasErrors) throw new McpException("compile_error", CompileMessage(results, code));
                string symbolsPath = Path.ChangeExtension(assemblyPath, ".pdb");
                byte[] symbols = File.Exists(symbolsPath) ? File.ReadAllBytes(symbolsPath) : null;
                compiled = Assembly.Load(File.ReadAllBytes(assemblyPath), symbols);
            }
            finally
            {
                try { Directory.Delete(buildFolder, true); } catch (Exception) { }
            }

            Type entry = compiled.GetType("BimCadMcpDynamicEntry", true);
            MethodInfo run = entry.GetMethod("Run", BindingFlags.Public | BindingFlags.Static);
            if (run == null) throw new McpException("compile_error", "Compiled C# entry point was not found.");

            string resultText;
            string changesJson = "";
            using (RevitFailureLog failures = new RevitFailureLog(application.Application))
            {
                try
                {
                    if (mode == "transaction")
                    {
                        resultText = Changes.Run(document, "Smart Connector: " + transactionName, options.DryRun, delegate { return Invoke(run, application, document, parametersJson); }, out changesJson);
                    }
                    else if (probe)
                    {
                        resultText = RunProbe(run, application, document, parametersJson, transactionName);
                    }
                    else
                    {
                        resultText = Invoke(run, application, document, parametersJson);
                    }
                }
                catch (McpException exception)
                {
                    // Revit's own failure messages (with element ids) explain errors such as "Document regeneration failed".
                    string reported = failures.Describe();
                    if (reported.Length == 0) throw;
                    throw new McpException(exception.Kind, exception.Message + reported, exception.InnerException ?? exception);
                }
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

        // manual with allow_model_changes=false. The code runs inside a project transaction group that is always rolled back,
        // so nothing it commits to the project survives. Family documents are separate documents: the code may create, edit,
        // save and close them. Any other document is guarded: saving or synchronizing a project or other non-family document is
        // cancelled during the run, and a change to one is reported, because the caller declared a run without model changes and
        // only the active project's changes can be rolled back here. The script's own error always comes first.
        private static string RunProbe(MethodInfo run, UIApplication application, Document document, string parametersJson, string transactionName)
        {
            Autodesk.Revit.ApplicationServices.Application app = application.Application;
            List<string> projectTransactions = new List<string>();
            List<string> otherChanges = new List<string>();
            List<string> blockedSaves = new List<string>();
            EventHandler<DocumentChangedEventArgs> watch = (sender, args) =>
            {
                try
                {
                    Document changed = args.GetDocument();
                    if (changed == null) return;
                    if (changed.Equals(document)) projectTransactions.AddRange(args.GetTransactionNames());
                    else if (!changed.IsFamilyDocument) otherChanges.Add(changed.Title + " (" + String.Join(", ", args.GetTransactionNames().ToArray()) + ")");
                }
                catch (Exception) { }
            };
            EventHandler<DocumentSavingEventArgs> guardSave = (sender, args) => GuardSave(args.Document, args, "save", blockedSaves);
            EventHandler<DocumentSavingAsEventArgs> guardSaveAs = (sender, args) => GuardSave(args.Document, args, "save as", blockedSaves);
            EventHandler<DocumentSynchronizingWithCentralEventArgs> guardSync = (sender, args) => GuardSave(args.Document, args, "synchronize", blockedSaves);

            string resultText = null;
            Exception scriptError = null;
            string rollbackProblem = null;
            TransactionGroup group = new TransactionGroup(document, "Smart Connector probe: " + transactionName);
            try
            {
                group.Start();
                app.DocumentChanged += watch;
                app.DocumentSaving += guardSave;
                app.DocumentSavingAs += guardSaveAs;
                app.DocumentSynchronizingWithCentral += guardSync;
                try
                {
                    resultText = Invoke(run, application, document, parametersJson);
                }
                catch (Exception exception)
                {
                    scriptError = exception;
                }
                finally
                {
                    app.DocumentChanged -= watch;
                    app.DocumentSaving -= guardSave;
                    app.DocumentSavingAs -= guardSaveAs;
                    app.DocumentSynchronizingWithCentral -= guardSync;
                }

                // A project transaction the code started and never committed or disposed blocks the rollback. The rollback is
                // attempted on its own, so a failure here is added to the script's error instead of replacing it.
                if (document.IsModifiable)
                    rollbackProblem = "The code left a project transaction open, so the probe could not be rolled back. Check the model and undo any change from this run before doing anything else.";
                else
                {
                    try { if (group.GetStatus() == TransactionStatus.Started) group.RollBack(); }
                    catch (Exception exception)
                    {
                        rollbackProblem = "The probe could not be rolled back: " + exception.Message + " Check the model and undo any change from this run before doing anything else.";
                    }
                }
            }
            finally
            {
                try { group.Dispose(); } catch (Exception) { }
            }

            StringBuilder report = new StringBuilder();
            if (rollbackProblem != null) report.Append(' ').Append(rollbackProblem);
            else if (projectTransactions.Count > 0)
                report.Append(" The code changed the project document (").Append(String.Join(", ", projectTransactions.Distinct().ToArray()))
                    .Append(") while allow_model_changes=false. All project changes were rolled back. Family documents the code saved or closed are not affected. ")
                    .Append("Rerun with allow_model_changes=true if the project change is intended (for example loading a family).");
            if (otherChanges.Count > 0)
                report.Append(" The code changed other non-family documents, which a probe does not allow and cannot roll back: ")
                    .Append(String.Join("; ", otherChanges.Distinct().ToArray())).Append(". These changes are unsaved; close those documents without saving.");
            if (blockedSaves.Count > 0)
                report.Append(" Cancelled during the probe: ").Append(String.Join("; ", blockedSaves.Distinct().ToArray())).Append('.');

            if (scriptError != null)
            {
                if (report.Length == 0) throw scriptError;
                McpException typed = scriptError as McpException;
                throw new McpException(typed == null ? "runtime_error" : typed.Kind, scriptError.Message + "\n" + report.ToString().Trim(), scriptError.InnerException ?? scriptError);
            }
            if (rollbackProblem != null) throw new McpException("rollback_failed", report.ToString().Trim());
            if (report.Length > 0) throw new McpException("probe_changed_project", report.ToString().Trim());
            return resultText;
        }

        // Only family documents may be saved during a probe; saving, save-as or synchronizing anything else is cancelled.
        private static void GuardSave(Document target, RevitAPIPreDocEventArgs args, string action, List<string> cancelled)
        {
            try
            {
                if (target == null || target.IsFamilyDocument) return;
                if (args.Cancellable) args.Cancel();
                cancelled.Add(action + " of " + target.Title);
            }
            catch (Exception) { }
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
                throw new McpException("runtime_error", "C# execution failed (the code compiled and ran, then threw)" + ScriptLocation(inner) + ": " + inner.GetType().Name + ": " + inner.Message, inner);
            }
        }

        // " at mcp_code.cs line 12, in FamilyManager.AssociateElementParameterToFamilyParameter": the user's line and the
        // API method it called when the exception was thrown. Empty when the stack has no line information.
        internal static string ScriptLocation(Exception error)
        {
            try
            {
                StackFrame[] frames = new StackTrace(error, true).GetFrames() ?? new StackFrame[0];
                for (int i = 0; i < frames.Length; i++)
                {
                    string file = frames[i].GetFileName();
                    if (file == null || !file.EndsWith("mcp_code.cs", StringComparison.OrdinalIgnoreCase) || frames[i].GetFileLineNumber() <= 0) continue;
                    StringBuilder text = new StringBuilder(" at mcp_code.cs line ").Append(frames[i].GetFileLineNumber().ToString(CultureInfo.InvariantCulture));
                    MethodBase called = i > 0 ? frames[i - 1].GetMethod() : null;
                    if (called != null && called.DeclaringType != null)
                        text.Append(", in ").Append(called.DeclaringType.Name).Append('.').Append(called.Name);
                    return text.ToString();
                }
            }
            catch (Exception) { }
            return String.Empty;
        }

        private static void AddReference(HashSet<string> known, CompilerParameters parameters, string path)
        {
            if (String.IsNullOrWhiteSpace(path) || !File.Exists(path) || !known.Add(path)) return;
            parameters.ReferencedAssemblies.Add(path);
        }
    }

    // Collects the Revit failure messages (warnings and errors) posted in any document while a script runs, so an error such as
    // "Document regeneration failed" comes back with what Revit reported and the element ids involved. Observes only.
    internal sealed class RevitFailureLog : IDisposable
    {
        private const int Limit = 20;
        private readonly Autodesk.Revit.ApplicationServices.Application _application;
        private readonly List<string> _messages = new List<string>();

        internal RevitFailureLog(Autodesk.Revit.ApplicationServices.Application application)
        {
            _application = application;
            _application.FailuresProcessing += OnFailuresProcessing;
        }

        private void OnFailuresProcessing(object sender, FailuresProcessingEventArgs args)
        {
            try
            {
                FailuresAccessor accessor = args.GetFailuresAccessor();
                Document failing = accessor.GetDocument();
                foreach (FailureMessageAccessor message in accessor.GetFailureMessages())
                {
                    if (_messages.Count >= Limit) return;
                    string ids = String.Join(", ", message.GetFailingElementIds().Select(id => id.Value.ToString(CultureInfo.InvariantCulture)).ToArray());
                    _messages.Add(message.GetSeverity().ToString() + " in " + (failing == null ? "?" : failing.Title) + ": " +
                        message.GetDescriptionText() + (ids.Length > 0 ? " (elements " + ids + ")" : ""));
                }
            }
            catch (Exception) { }
        }

        internal string Describe()
        {
            return _messages.Count == 0 ? String.Empty : "\nRevit failure messages during the run:\n- " + String.Join("\n- ", _messages.ToArray());
        }

        public void Dispose()
        {
            _application.FailuresProcessing -= OnFailuresProcessing;
        }
    }
}
