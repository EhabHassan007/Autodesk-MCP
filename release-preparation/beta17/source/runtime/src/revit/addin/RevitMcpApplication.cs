using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;

namespace BimCadMcp.Revit
{
    public sealed class Application : IExternalApplication
    {
        private static PipeHost _host;

        public Result OnStartup(UIControlledApplication application)
        {
            RequestHandler handler = new RequestHandler();
            ExternalEvent externalEvent = ExternalEvent.Create(handler);
            _host = new PipeHost(application.ControlledApplication.VersionNumber, handler, externalEvent);
            _host.Start();
            ConnectionState.MarkServerStarted(application.ControlledApplication.VersionNumber, _host.SessionId, _host.PipeName);
            SessionRegistry.Register(_host.SessionId, application.ControlledApplication.VersionNumber, _host.PipeName);
            RibbonUi.Create(application);
            // Once a day: ask about a new Smart Connector version, and remind about Skills Sync after a week.
            OpenCheck.Start(application);
            return Result.Succeeded;
        }

        public Result OnShutdown(UIControlledApplication application)
        {
            if (_host != null)
            {
                SessionRegistry.Unregister(_host.SessionId);
                _host.Dispose();
                _host = null;
            }
            ConnectionState.MarkServerStopped();
            return Result.Succeeded;
        }
    }

    internal sealed class RequestContext
    {
        internal readonly string Operation;
        internal readonly string[] Arguments;
        // The job this request belongs to; null for the internal status probe.
        internal readonly Job Job;
        internal readonly ManualResetEventSlim Completed = new ManualResetEventSlim(false);
        internal string ResultJson;
        // Set by the pipe thread when it stops waiting for a probe that Revit has not started.
        internal volatile bool Abandoned;

        internal RequestContext(string operation, string[] arguments, Job job)
        {
            Operation = operation;
            Arguments = arguments;
            Job = job;
        }
    }

    internal sealed class RequestHandler : IExternalEventHandler
    {
        private readonly ConcurrentQueue<RequestContext> _queue = new ConcurrentQueue<RequestContext>();

        internal void Enqueue(RequestContext request)
        {
            _queue.Enqueue(request);
        }

        public void Execute(UIApplication application)
        {
            RequestContext request;
            while (_queue.TryDequeue(out request))
            {
                try
                {
                    if (request.Job == null)
                    {
                        // Status probe: only answers that Revit's thread is free, and which document is active.
                        if (!request.Abandoned) request.ResultJson = RevitOperations.Execute(application, request.Operation, request.Arguments);
                    }
                    else if (Jobs.Start(request.Job))
                    {
                        string result = "";
                        string error = "";
                        try
                        {
                            result = RevitOperations.Execute(application, request.Operation, request.Arguments);
                        }
                        catch (Exception exception)
                        {
                            error = Errors.Format(exception);
                        }
                        Jobs.Finish(request.Job, result, error);
                        if (error.Length == 0) ConnectionState.MarkRequestSucceeded(request.Operation);
                        else ConnectionState.MarkRequestFailed(request.Operation, error);
                    }
                }
                catch (Exception exception)
                {
                    ConnectionState.MarkRequestFailed(request.Operation, Errors.Format(exception));
                }
                finally
                {
                    request.Completed.Set();
                }
            }
        }

        public string GetName()
        {
            return "Smart Connector request handler";
        }
    }

    internal sealed class PipeHost : IDisposable
    {
        private readonly string _pipeName;
        private readonly string _sessionId;
        private readonly RequestHandler _handler;
        private readonly ExternalEvent _externalEvent;
        private Thread _thread;
        private volatile bool _stopping;

        internal PipeHost(string version, RequestHandler handler, ExternalEvent externalEvent)
        {
            int processId = Process.GetCurrentProcess().Id;
            _sessionId = version + "-" + processId.ToString(CultureInfo.InvariantCulture);
            _pipeName = "BimCadMcp.Revit." + version + "." + processId.ToString(CultureInfo.InvariantCulture);
            _handler = handler;
            _externalEvent = externalEvent;
        }

        internal string SessionId
        {
            get { return _sessionId; }
        }

        internal string PipeName
        {
            get { return _pipeName; }
        }

        internal void Start()
        {
            _thread = new Thread(ListenLoop);
            _thread.Name = "Smart Connector Revit pipe";
            _thread.IsBackground = true;
            _thread.Start();
        }

        // Several clients can be connected at once. A status or job question is answered on the pipe thread, so it gets
        // an answer even while Revit's own thread is busy with a long request; only real work waits for Revit.
        private const int MaxPipeInstances = 8;

        private void ListenLoop()
        {
            while (!_stopping)
            {
                NamedPipeServerStream pipe = null;
                try
                {
                    PipeSecurity security = new PipeSecurity();
                    SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
                    security.AddAccessRule(new PipeAccessRule(
                        user,
                        PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance,
                        AccessControlType.Allow));
                    pipe = new NamedPipeServerStream(
                        _pipeName, PipeDirection.InOut, MaxPipeInstances, PipeTransmissionMode.Byte, PipeOptions.None,
                        4096, 4096, security);
                    pipe.WaitForConnection();
                    if (_stopping)
                    {
                        pipe.Dispose();
                        return;
                    }
                    ConnectionState.MarkClientConnected();
                    NamedPipeServerStream accepted = pipe;
                    pipe = null;
                    ThreadPool.QueueUserWorkItem(delegate { Serve(accepted); });
                }
                catch (Exception exception)
                {
                    if (pipe != null)
                    {
                        try { pipe.Dispose(); }
                        catch (Exception) { }
                    }
                    if (!_stopping)
                    {
                        System.Diagnostics.Debug.WriteLine("Smart Connector pipe error: " + exception);
                        Thread.Sleep(250);
                    }
                }
            }
        }

        private void Serve(NamedPipeServerStream pipe)
        {
            try
            {
                using (pipe)
                using (StreamReader reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, true))
                using (StreamWriter writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, true))
                {
                    writer.AutoFlush = true;
                    string line = reader.ReadLine();
                    if (String.IsNullOrWhiteSpace(line))
                    {
                        writer.WriteLine("ERR\t" + Protocol.Encode("[invalid_request] Empty request."));
                        return;
                    }
                    string[] fields = line.Split('\t');
                    string[] arguments;
                    try { arguments = fields.Skip(1).Select(Protocol.Decode).ToArray(); }
                    catch (FormatException)
                    {
                        writer.WriteLine("ERR\t" + Protocol.Encode("[invalid_request] The request arguments are not valid."));
                        return;
                    }
                    writer.WriteLine(Answer(fields[0], arguments));
                }
            }
            catch (Exception exception)
            {
                System.Diagnostics.Debug.WriteLine("Smart Connector pipe error: " + exception);
            }
        }

        private string Answer(string operation, string[] arguments)
        {
            try
            {
                string json;
                if (String.Equals(operation, "connection_status", StringComparison.OrdinalIgnoreCase)) json = StatusReply();
                else if (String.Equals(operation, "get_job", StringComparison.OrdinalIgnoreCase)) json = JobReply(arguments);
                else json = Dispatch(operation, arguments);
                return "OK\t" + Protocol.Encode(json);
            }
            catch (Exception exception)
            {
                return "ERR\t" + Protocol.Encode(Errors.Format(exception));
            }
        }

        // Sends a request to Revit's thread and waits for it. A request that outlives the wait is not lost: it stays a job
        // that get_job can follow, unless Revit never started it, in which case it is dropped so it cannot run late.
        private string Dispatch(string operation, string[] arguments)
        {
            bool isScript = String.Equals(operation, "execute_csharp", StringComparison.OrdinalIgnoreCase);
            RunOptions options = RunOptions.Parse(isScript && arguments.Length > 6 ? arguments[6] : "", isScript ? 60 : 30);
            Job job = Jobs.Create(operation);
            RequestContext request = new RequestContext(operation, arguments, job);
            _handler.Enqueue(request);
            _externalEvent.Raise();
            if (options.Background) return Jobs.ToJson(job, false);

            request.Completed.Wait(TimeSpan.FromSeconds(options.WaitSeconds));
            string state;
            lock (job)
            {
                state = job.State;
                if (state == "queued")
                {
                    job.State = "cancelled";
                    job.FinishedUtc = DateTime.UtcNow;
                }
            }
            if (state == "completed")
            {
                Jobs.Remove(job);
                return job.ResultJson;
            }
            if (state == "failed")
            {
                Jobs.Remove(job);
                throw new McpFailure(job.Error);
            }
            if (state == "queued")
            {
                Jobs.Remove(job);
                ConnectionState.MarkRequestFailed(operation, "Revit did not start the request within " + options.WaitSeconds.ToString(CultureInfo.InvariantCulture) + " seconds.");
                throw new McpException("busy", "Revit did not start the request within " + options.WaitSeconds.ToString(CultureInfo.InvariantCulture) +
                    " seconds: it is busy with its own work (regenerating graphics, another command or a dialog). Nothing was run and nothing was changed. Call connection_status; when it reports idle, send the request again.");
            }
            // Still running: the caller stops waiting, Revit goes on.
            return Jobs.ToJson(job, false);
        }

        private string StatusReply()
        {
            List<Job> active = Jobs.Active();
            Job running = active.FirstOrDefault(j => j.State == "running");
            string busyState = "idle";
            string reason = "";
            string documentId = null;
            if (running == null)
            {
                RequestContext probe = new RequestContext("probe", new string[0], null);
                _handler.Enqueue(probe);
                _externalEvent.Raise();
                if (probe.Completed.Wait(TimeSpan.FromMilliseconds(1500))) documentId = probe.ResultJson ?? "";
                else
                {
                    probe.Abandoned = true;
                    if (active.Count > 0)
                    {
                        busyState = "queued";
                        reason = "Revit has not started " + active.Count.ToString(CultureInfo.InvariantCulture) + " waiting request(s); the oldest has waited " + Jobs.ElapsedText(active[0]) +
                            " s. Revit is busy with its own work: regenerating graphics, another command or a dialog.";
                    }
                    else
                    {
                        busyState = "revit_busy";
                        reason = "Revit did not answer within 1.5 s. It is busy with its own work: regenerating graphics, another command or a dialog.";
                    }
                }
            }
            else
            {
                busyState = "executing";
                reason = "Revit is running " + running.Operation + " (job " + running.Id + ") and has been working on it for " + Jobs.ElapsedText(running) + " s";
                lock (running)
                {
                    if (running.Total > 0) reason += ", " + running.Done.ToString(CultureInfo.InvariantCulture) + " of " + running.Total.ToString(CultureInfo.InvariantCulture) + " done";
                }
                reason += ".";
            }
            if (documentId != null) ConnectionState.SetDocumentId(documentId);
            return AdvancedControl.ConnectionStatus(documentId, busyState, reason, active);
        }

        private static string JobReply(string[] arguments)
        {
            string id = arguments.Length > 0 ? arguments[0].Trim() : "";
            bool cancel = arguments.Length > 1 && String.Equals(arguments[1].Trim(), "true", StringComparison.OrdinalIgnoreCase);
            if (id.Length == 0)
            {
                List<string> items = Jobs.Recent().Select(j => Jobs.ToJson(j, false)).ToList();
                return "{\"jobs\":[" + String.Join(",", items.ToArray()) + "]}";
            }
            Job job = Jobs.Find(id);
            if (job == null)
                throw new McpException("job_not_found", "Job " + id + " was not found. Jobs are kept for 60 minutes and are lost when Revit closes. Read the model to see what happened.");
            if (cancel)
            {
                lock (job)
                {
                    if (job.State == "running")
                        throw new McpException("cannot_cancel", "Job " + id + " is already running in Revit; a running command cannot be interrupted safely. Wait for it and read the result with get_job.");
                    if (job.State == "queued")
                    {
                        job.State = "cancelled";
                        job.FinishedUtc = DateTime.UtcNow;
                    }
                }
            }
            return Jobs.ToJson(job, true);
        }

        public void Dispose()
        {
            _stopping = true;
            try
            {
                using (NamedPipeClientStream wake = new NamedPipeClientStream(".", _pipeName, PipeDirection.Out))
                {
                    wake.Connect(250);
                }
            }
            catch { }
            if (_thread != null) _thread.Join(1000);
        }
    }

    internal static class Protocol
    {
        internal static string Encode(string value)
        {
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? String.Empty));
        }

        internal static string Decode(string value)
        {
            return Encoding.UTF8.GetString(Convert.FromBase64String(value));
        }
    }

    internal static class RevitOperations
    {
        internal static string Execute(UIApplication application, string operation, string[] arguments)
        {
            // Internal probe from the pipe thread: is Revit's thread free, and which document is active.
            if (String.Equals(operation, "probe", StringComparison.OrdinalIgnoreCase))
            {
                UIDocument active = application.ActiveUIDocument;
                return active == null ? "" : DocumentId(active.Document);
            }

            UIDocument uiDocument = application.ActiveUIDocument;
            if (uiDocument == null) throw new McpException("no_document", "Open a Revit project first.");
            Document document = uiDocument.Document;

            switch (operation)
            {
                case "document_info":
                    return DocumentInfo(application, document);
                case "list_levels":
                    return ListLevels(document);
                case "list_selected":
                    return ListSelected(uiDocument);
                case "get_element":
                    RequireArguments(arguments, 1);
                    return GetElement(document, arguments[0]);
                case "set_parameter":
                    RequireArguments(arguments, 4);
                    return SetParameter(document, arguments[0], arguments[1], arguments[2], arguments[3]);
                case "execute_csharp":
                    // Six fields, and a seventh with the options (dry_run, background, wait_seconds) only when one is set.
                    if (arguments == null || arguments.Length < 6 || arguments.Length > 7) throw new McpException("invalid_request", "Invalid request arguments.");
                    return AdvancedControl.ExecuteCSharp(
                        application,
                        document,
                        arguments[0],
                        arguments[1],
                        arguments[2],
                        arguments[3],
                        arguments[4],
                        arguments[5],
                        arguments.Length > 6 ? arguments[6] : "");
                case "revision_cloud_info":
                    return RevisionClouds.Info(document, arguments);
                case "create_revision_clouds":
                    return RevisionClouds.Create(document, arguments);
                default:
                    throw new McpException("invalid_request", "Unknown operation: " + operation);
            }
        }

        internal static string DocumentId(Document document)
        {
            return String.IsNullOrWhiteSpace(document.PathName) ? document.Title : document.PathName;
        }

        private static string DocumentInfo(UIApplication application, Document document)
        {
            return "{" +
                Json.Property("title", document.Title) + "," +
                Json.Property("path", document.PathName) + "," +
                Json.Property("document_id", DocumentId(document)) + "," +
                Json.Property("revit_version", application.Application.VersionNumber) + "," +
                Json.Property("is_family_document", document.IsFamilyDocument) + "," +
                Json.Property("is_workshared", document.IsWorkshared) + "," +
                Json.Property("is_modified", document.IsModified) + "," +
                Json.Property("is_read_only", document.IsReadOnly) +
                "}";
        }

        private static string ListLevels(Document document)
        {
            List<string> levels = new FilteredElementCollector(document)
                .OfClass(typeof(Level))
                .Cast<Level>()
                .OrderBy(level => level.Elevation)
                .Select(level => "{" +
                    Json.Property("id", level.Id.Value.ToString(CultureInfo.InvariantCulture)) + "," +
                    Json.Property("name", level.Name) + "," +
                    Json.NumberProperty("elevation_internal", level.Elevation) +
                    "}")
                .ToList();
            return "{" + Json.Property("document_id", DocumentId(document)) + ",\"levels\":[" + String.Join(",", levels.ToArray()) + "]}";
        }

        private static string ListSelected(UIDocument uiDocument)
        {
            Document document = uiDocument.Document;
            List<string> items = new List<string>();
            foreach (ElementId id in uiDocument.Selection.GetElementIds())
            {
                Element element = document.GetElement(id);
                if (element != null) items.Add(ElementSummary(element));
            }
            return "{" + Json.Property("document_id", DocumentId(document)) + ",\"elements\":[" + String.Join(",", items.ToArray()) + "]}";
        }

        private static string GetElement(Document document, string elementId)
        {
            Element element = FindElement(document, elementId);
            List<string> parameters = new List<string>();
            int count = 0;
            foreach (Parameter parameter in element.Parameters)
            {
                if (count >= 200) break;
                string name = parameter.Definition == null ? String.Empty : parameter.Definition.Name;
                string value = ParameterValue(parameter);
                parameters.Add("{" +
                    Json.Property("name", name) + "," +
                    Json.Property("value", value) + "," +
                    Json.Property("storage", parameter.StorageType.ToString()) + "," +
                    Json.Property("read_only", parameter.IsReadOnly) +
                    "}");
                count++;
            }

            return "{" +
                Json.Property("document_id", DocumentId(document)) + "," +
                Json.Property("id", element.Id.Value.ToString(CultureInfo.InvariantCulture)) + "," +
                Json.Property("unique_id", element.UniqueId) + "," +
                Json.Property("name", SafeElementName(element)) + "," +
                Json.Property("category", element.Category == null ? String.Empty : element.Category.Name) + "," +
                "\"parameters\":[" + String.Join(",", parameters.ToArray()) + "]}";
        }

        private static string SetParameter(Document document, string expectedDocument, string elementId, string parameterName, string value)
        {
            if (!String.Equals(DocumentId(document), expectedDocument, StringComparison.OrdinalIgnoreCase))
                throw new McpException("document_changed", "Active Revit document changed. Read document_info again.");
            if (document.IsReadOnly) throw new McpException("document_read_only", "The active Revit document is read-only.");

            Element element = FindElement(document, elementId);
            Parameter parameter = element.LookupParameter(parameterName);
            if (parameter == null) throw new InvalidOperationException("Parameter was not found: " + parameterName);
            if (parameter.IsReadOnly) throw new InvalidOperationException("Parameter is read-only: " + parameterName);

            using (Transaction transaction = new Transaction(document, "Smart Connector: Set parameter"))
            {
                transaction.Start();
                bool changed;
                switch (parameter.StorageType)
                {
                    case StorageType.String:
                        changed = parameter.Set(value);
                        break;
                    case StorageType.Integer:
                        int integerValue;
                        if (!Int32.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out integerValue))
                            throw new InvalidOperationException("Integer parameter requires an integer value.");
                        changed = parameter.Set(integerValue);
                        break;
                    case StorageType.Double:
                        double doubleValue;
                        if (!Double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out doubleValue))
                            throw new InvalidOperationException("Double parameter requires a numeric value in Revit internal units.");
                        changed = parameter.Set(doubleValue);
                        break;
                    case StorageType.ElementId:
                        long targetId;
                        if (!Int64.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out targetId))
                            throw new InvalidOperationException("ElementId parameter requires an integer element id.");
                        changed = parameter.Set(new ElementId(targetId));
                        break;
                    default:
                        throw new InvalidOperationException("This parameter storage type is not supported.");
                }
                if (!changed) throw new InvalidOperationException("Revit rejected the parameter value.");
                transaction.Commit();
            }

            return "{" +
                Json.Property("document_id", DocumentId(document)) + "," +
                Json.Property("element_id", element.Id.Value.ToString(CultureInfo.InvariantCulture)) + "," +
                Json.Property("parameter", parameterName) + "," +
                Json.Property("value", ParameterValue(parameter)) +
                "}";
        }

        private static Element FindElement(Document document, string value)
        {
            long id;
            if (!Int64.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out id))
                throw new InvalidOperationException("Element id must be an integer.");
            Element element = document.GetElement(new ElementId(id));
            if (element == null) throw new InvalidOperationException("Element was not found: " + value);
            return element;
        }

        private static string ElementSummary(Element element)
        {
            return "{" +
                Json.Property("id", element.Id.Value.ToString(CultureInfo.InvariantCulture)) + "," +
                Json.Property("name", SafeElementName(element)) + "," +
                Json.Property("category", element.Category == null ? String.Empty : element.Category.Name) +
                "}";
        }

        private static string SafeElementName(Element element)
        {
            try { return element.Name ?? String.Empty; }
            catch { return String.Empty; }
        }

        private static string ParameterValue(Parameter parameter)
        {
            try
            {
                string formatted = parameter.AsValueString();
                if (!String.IsNullOrEmpty(formatted)) return formatted;
            }
            catch { }

            switch (parameter.StorageType)
            {
                case StorageType.String: return parameter.AsString() ?? String.Empty;
                case StorageType.Integer: return parameter.AsInteger().ToString(CultureInfo.InvariantCulture);
                case StorageType.Double: return parameter.AsDouble().ToString("R", CultureInfo.InvariantCulture);
                case StorageType.ElementId: return parameter.AsElementId().Value.ToString(CultureInfo.InvariantCulture);
                default: return String.Empty;
            }
        }

        private static void RequireArguments(string[] arguments, int count)
        {
            if (arguments == null || arguments.Length != count)
                throw new McpException("invalid_request", "Invalid request arguments.");
        }
    }

    internal static class Json
    {
        internal static string Property(string name, string value)
        {
            return Quote(name) + ":" + Quote(value);
        }

        internal static string Property(string name, bool value)
        {
            return Quote(name) + ":" + (value ? "true" : "false");
        }

        internal static string NumberProperty(string name, double value)
        {
            return Quote(name) + ":" + value.ToString("R", CultureInfo.InvariantCulture);
        }

        private static string Quote(string value)
        {
            if (value == null) return "null";
            StringBuilder builder = new StringBuilder(value.Length + 2);
            builder.Append('"');
            foreach (char character in value)
            {
                switch (character)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\f': builder.Append("\\f"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (character < 32) builder.Append("\\u" + ((int)character).ToString("x4"));
                        else builder.Append(character);
                        break;
                }
            }
            builder.Append('"');
            return builder.ToString();
        }
    }
}
