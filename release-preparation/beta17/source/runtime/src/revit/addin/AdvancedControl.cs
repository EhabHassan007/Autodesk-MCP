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
                    LastError = State.LastError
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
        internal static string ConnectionStatus(UIApplication application)
        {
            ConnectionSnapshot state = ConnectionState.Read();
            UIDocument uiDocument = application.ActiveUIDocument;
            string documentId = uiDocument == null ? String.Empty : RevitOperations.DocumentId(uiDocument.Document);
            bool recent = state.LastClientUtc != DateTime.MinValue && DateTime.UtcNow - state.LastClientUtc <= TimeSpan.FromMinutes(2);
            return "{" +
                Json.Property("server_running", state.ServerRunning) + "," +
                Json.Property("recent_client", recent) + "," +
                Json.Property("session_id", state.SessionId) + "," +
                Json.Property("process_id", state.ProcessId.ToString(CultureInfo.InvariantCulture)) + "," +
                Json.Property("revit_version", state.RevitVersion) + "," +
                Json.Property("pipe_name", state.PipeName) + "," +
                Json.Property("document_id", documentId) + "," +
                Json.Property("request_count", state.RequestCount.ToString(CultureInfo.InvariantCulture)) + "," +
                Json.Property("last_operation", state.LastOperation) + "," +
                Json.Property("last_error", state.LastError) +
                "}";
        }

        internal static string ExecuteCSharp(
            UIApplication application,
            Document document,
            string expectedDocument,
            string executionMode,
            string allowModelChanges,
            string code,
            string parametersJson,
            string transactionName)
        {
            if (!String.Equals(RevitOperations.DocumentId(document), expectedDocument, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Active Revit document changed. Read document_info again.");
            if (document.IsReadOnly) throw new InvalidOperationException("The active Revit document is read-only.");
            if (String.IsNullOrWhiteSpace(code)) throw new InvalidOperationException("C# code is required.");
            if (code.Length > 100000) throw new InvalidOperationException("C# code exceeds the 100,000 character limit.");

            string mode = (executionMode ?? String.Empty).Trim().ToLowerInvariant();
            if (mode != "read" && mode != "transaction" && mode != "manual")
                throw new InvalidOperationException("execution_mode must be read, transaction, or manual.");
            bool allowChanges;
            if (!Boolean.TryParse(allowModelChanges, out allowChanges))
                throw new InvalidOperationException("allow_model_changes must be true or false.");
            if (mode == "transaction" && !allowChanges)
                throw new InvalidOperationException("Model-changing execution requires allow_model_changes=true. To work only in family documents, use manual with allow_model_changes=false.");
            // manual with allow_model_changes=false is a probe: the code may create, edit, save and close family documents,
            // but every change to the project document is rolled back and reported (see RunProbe).
            bool probe = mode == "manual" && !allowChanges;
            if (mode == "read" && allowChanges)
                throw new InvalidOperationException("Read execution requires allow_model_changes=false.");
            if (String.IsNullOrWhiteSpace(transactionName)) transactionName = "Execute controlled C#";

            string source =
                "using System;\n" +
                "using System.Collections.Generic;\n" +
                "using System.Globalization;\n" +
                "using System.IO;\n" +
                "using System.Linq;\n" +
                "using System.Text;\n" +
                "using Autodesk.Revit.DB;\n" +
                "using Autodesk.Revit.UI;\n" +
                "public static class BimCadMcpDynamicEntry {\n" +
                "  public static string Run(UIApplication application, Document document, string parametersJson) {\n" +
                "#line 1 \"mcp_code.cs\"\n" + code + "\n#line default\n" +
                "  }\n" +
                "}\n";

            CompilerParameters compilerParameters = new CompilerParameters();
            compilerParameters.GenerateExecutable = false;
            compilerParameters.GenerateInMemory = true;
            // Debug information lets a runtime error name the script line (the #line directive maps it to mcp_code.cs).
            compilerParameters.IncludeDebugInformation = true;
            compilerParameters.TreatWarningsAsErrors = false;

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
            if (results.Errors.HasErrors)
            {
                StringBuilder errors = new StringBuilder("C# compilation failed:");
                foreach (CompilerError error in results.Errors)
                {
                    if (error.IsWarning) continue;
                    errors.Append("\nLine ").Append(error.Line.ToString(CultureInfo.InvariantCulture)).Append(": ").Append(error.ErrorText);
                }
                errors.Append("\nPredefined variables: document (Document), application (UIApplication), parametersJson (string). The code must return a string.");
                throw new InvalidOperationException(errors.ToString());
            }

            Type entry = results.CompiledAssembly.GetType("BimCadMcpDynamicEntry", true);
            MethodInfo run = entry.GetMethod("Run", BindingFlags.Public | BindingFlags.Static);
            if (run == null) throw new InvalidOperationException("Compiled C# entry point was not found.");

            string resultText;
            using (RevitFailureLog failures = new RevitFailureLog(application.Application))
            {
                if (mode == "transaction")
                {
                    using (Transaction transaction = new Transaction(document, "Smart Connector: " + transactionName))
                    {
                        transaction.Start();
                        try
                        {
                            resultText = Invoke(run, application, document, parametersJson, failures);
                            TransactionStatus status = transaction.Commit();
                            if (status != TransactionStatus.Committed)
                                throw new InvalidOperationException("Revit did not commit the transaction. Status: " + status.ToString() + failures.Describe());
                        }
                        catch
                        {
                            if (transaction.GetStatus() == TransactionStatus.Started) transaction.RollBack();
                            throw;
                        }
                    }
                }
                else if (probe)
                {
                    resultText = RunProbe(run, application, document, parametersJson, transactionName, failures);
                }
                else
                {
                    resultText = Invoke(run, application, document, parametersJson, failures);
                }
            }

            return "{" +
                Json.Property("document_id", RevitOperations.DocumentId(document)) + "," +
                Json.Property("execution_mode", mode) + "," +
                Json.Property("result", resultText ?? String.Empty) +
                "}";
        }

        // manual with allow_model_changes=false. The code runs inside a project transaction group that is always rolled back,
        // so nothing it commits to the project survives. Family documents it opens are separate documents and are not affected.
        // A project change is reported as an error, because the caller declared a run without model changes.
        private static string RunProbe(MethodInfo run, UIApplication application, Document document, string parametersJson, string transactionName, RevitFailureLog failures)
        {
            List<string> projectTransactions = new List<string>();
            EventHandler<DocumentChangedEventArgs> watch = (sender, args) =>
            {
                Document changed = args.GetDocument();
                if (changed != null && changed.Equals(document)) projectTransactions.AddRange(args.GetTransactionNames());
            };
            string resultText;
            using (TransactionGroup group = new TransactionGroup(document, "Smart Connector probe: " + transactionName))
            {
                group.Start();
                application.Application.DocumentChanged += watch;
                try
                {
                    resultText = Invoke(run, application, document, parametersJson, failures);
                }
                finally
                {
                    application.Application.DocumentChanged -= watch;
                    if (group.GetStatus() == TransactionStatus.Started) group.RollBack();
                }
            }
            if (projectTransactions.Count > 0)
                throw new InvalidOperationException("The code changed the project document (" +
                    String.Join(", ", projectTransactions.Distinct().ToArray()) + ") while allow_model_changes=false. All project changes were rolled back. " +
                    "Family documents the code saved or closed are not affected. Rerun with allow_model_changes=true if the project change is intended (for example loading a family).");
            return resultText;
        }

        private static string Invoke(MethodInfo run, UIApplication application, Document document, string parametersJson, RevitFailureLog failures)
        {
            try
            {
                object result = run.Invoke(null, new object[] { application, document, parametersJson ?? String.Empty });
                return result == null ? String.Empty : Convert.ToString(result, CultureInfo.InvariantCulture);
            }
            catch (TargetInvocationException exception)
            {
                Exception inner = exception.InnerException ?? exception;
                throw new InvalidOperationException(DescribeRuntimeError(inner) + failures.Describe(), inner);
            }
        }

        // "C# execution failed at mcp_code.cs line 12, in FamilyManager.AssociateElementParameterToFamilyParameter
        // (Autodesk.Revit.Exceptions.InvalidOperationException): Document regeneration failed."
        internal static string DescribeRuntimeError(Exception error)
        {
            StringBuilder text = new StringBuilder("C# execution failed");
            try
            {
                StackFrame[] frames = new StackTrace(error, true).GetFrames() ?? new StackFrame[0];
                for (int i = 0; i < frames.Length; i++)
                {
                    string file = frames[i].GetFileName();
                    if (file == null || !file.EndsWith("mcp_code.cs", StringComparison.OrdinalIgnoreCase) || frames[i].GetFileLineNumber() <= 0) continue;
                    text.Append(" at mcp_code.cs line ").Append(frames[i].GetFileLineNumber().ToString(CultureInfo.InvariantCulture));
                    MethodBase called = i > 0 ? frames[i - 1].GetMethod() : null;
                    if (called != null && called.DeclaringType != null)
                        text.Append(", in ").Append(called.DeclaringType.Name).Append('.').Append(called.Name);
                    break;
                }
            }
            catch (Exception) { }
            text.Append(" (").Append(error.GetType().FullName).Append("): ").Append(error.Message);
            return text.ToString();
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
