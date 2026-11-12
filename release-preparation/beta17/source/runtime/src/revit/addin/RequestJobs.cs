using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using Autodesk.Revit.DB;

namespace BimCadMcp.Revit
{
    // An error with a type, so the AI client can tell a mistake in its own code (compile_error, runtime_error) from a
    // Revit state (busy, timeout, document_changed) or a lost connection. The pipe sends it as "[kind] message".
    internal sealed class McpException : InvalidOperationException
    {
        internal readonly string Kind;

        internal McpException(string kind, string message)
            : base(message)
        {
            Kind = kind;
        }

        internal McpException(string kind, string message, Exception inner)
            : base(message, inner)
        {
            Kind = kind;
        }
    }

    // A failure that already carries its "[kind] message" text (a failed job being reported to its caller).
    internal sealed class McpFailure : Exception
    {
        internal McpFailure(string text)
            : base(text)
        {
        }
    }

    internal static class Errors
    {
        internal static string Format(Exception exception)
        {
            if (exception is McpFailure) return exception.Message;
            McpException typed = exception as McpException;
            return "[" + (typed == null ? "revit_error" : typed.Kind) + "] " + exception.Message;
        }
    }

    // Progress a long script can report, so get_job shows how far it is: McpProgress.Report(done, total, "level 3 of 20").
    // McpProgress is declared in the generated script wrapper and reaches Jobs.ReportProgress through this AppDomain slot,
    // so the compiled script needs no reference to this assembly.
    internal static class ProgressSlot
    {
        internal const string Name = "BimCadMcp.Progress";

        internal static void Install()
        {
            AppDomain.CurrentDomain.SetData(Name, new Action<int, int, string>(Jobs.ReportProgress));
        }
    }

    // One request to Revit. States: queued (waiting for Revit to be idle), running, completed, failed, cancelled.
    // Every change of state happens inside lock (job).
    internal sealed class Job
    {
        internal readonly string Id;
        internal readonly string Operation;
        internal readonly DateTime CreatedUtc = DateTime.UtcNow;
        internal DateTime StartedUtc;
        internal DateTime FinishedUtc;
        internal string State = "queued";
        internal string ResultJson = "";
        internal string Error = "";
        internal int Done;
        internal int Total;
        internal string Note = "";

        internal Job(string id, string operation)
        {
            Id = id;
            Operation = operation;
        }

        internal bool Finished
        {
            get { return State == "completed" || State == "failed" || State == "cancelled"; }
        }
    }

    // The requests the add-in has accepted. A request that outlives the caller's wait keeps its result here, so a
    // timeout no longer loses the work Revit goes on to finish. Jobs are kept for an hour and are lost when Revit closes.
    internal static class Jobs
    {
        private static readonly object Gate = new object();
        private static readonly Dictionary<string, Job> All = new Dictionary<string, Job>();
        private static Job _current;
        private const int KeepMinutes = 60;
        private const int MaxJobs = 40;

        internal static Job Create(string operation)
        {
            Job job = new Job(Guid.NewGuid().ToString("N").Substring(0, 8), operation);
            lock (Gate)
            {
                Prune();
                All[job.Id] = job;
            }
            return job;
        }

        // Called on the Revit thread. False when the caller gave up or cancelled before Revit got to it.
        internal static bool Start(Job job)
        {
            lock (job)
            {
                if (job.State != "queued") return false;
                job.State = "running";
                job.StartedUtc = DateTime.UtcNow;
            }
            lock (Gate) _current = job;
            return true;
        }

        internal static void Finish(Job job, string resultJson, string error)
        {
            lock (job)
            {
                job.State = String.IsNullOrEmpty(error) ? "completed" : "failed";
                job.ResultJson = resultJson ?? "";
                job.Error = error ?? "";
                job.FinishedUtc = DateTime.UtcNow;
            }
            lock (Gate)
            {
                if (Object.ReferenceEquals(_current, job)) _current = null;
            }
        }

        internal static void ReportProgress(int done, int total, string note)
        {
            Job job;
            lock (Gate) job = _current;
            if (job == null) return;
            lock (job)
            {
                job.Done = done;
                job.Total = total;
                job.Note = note ?? "";
            }
        }

        internal static void Remove(Job job)
        {
            lock (Gate) All.Remove(job.Id);
        }

        internal static Job Find(string id)
        {
            Job job;
            lock (Gate) All.TryGetValue(id ?? "", out job);
            return job;
        }

        internal static List<Job> Active()
        {
            lock (Gate)
            {
                List<Job> active = new List<Job>();
                foreach (Job job in All.Values)
                {
                    lock (job)
                    {
                        if (!job.Finished) active.Add(job);
                    }
                }
                return active.OrderBy(j => j.CreatedUtc).ToList();
            }
        }

        internal static List<Job> Recent()
        {
            lock (Gate) return All.Values.OrderByDescending(j => j.CreatedUtc).ToList();
        }

        // Called with Gate held.
        private static void Prune()
        {
            List<Job> old = new List<Job>();
            foreach (Job job in All.Values)
            {
                lock (job)
                {
                    if (job.Finished && DateTime.UtcNow - job.FinishedUtc > TimeSpan.FromMinutes(KeepMinutes)) old.Add(job);
                }
            }
            foreach (Job job in old) All.Remove(job.Id);
            if (All.Count < MaxJobs) return;
            List<Job> finished = new List<Job>();
            foreach (Job job in All.Values)
            {
                lock (job)
                {
                    if (job.Finished) finished.Add(job);
                }
            }
            foreach (Job job in finished.OrderBy(j => j.FinishedUtc).Take(All.Count - MaxJobs + 1)) All.Remove(job.Id);
        }

        internal static string ElapsedText(Job job)
        {
            DateTime end;
            lock (job) end = job.Finished ? job.FinishedUtc : DateTime.UtcNow;
            return Math.Max(0, (end - job.CreatedUtc).TotalSeconds).ToString("0.0", CultureInfo.InvariantCulture);
        }

        // The job as JSON. With includeResult, a finished job carries its result or error.
        internal static string ToJson(Job job, bool includeResult)
        {
            lock (job)
            {
                StringBuilder text = new StringBuilder("{");
                text.Append(Json.Property("job_id", job.Id)).Append(',');
                text.Append(Json.Property("operation", job.Operation)).Append(',');
                text.Append(Json.Property("state", job.State)).Append(',');
                text.Append(Json.Property("completed", job.State == "completed")).Append(',');
                text.Append(Json.NumberProperty("elapsed_seconds", Math.Round(Math.Max(0, ((job.Finished ? job.FinishedUtc : DateTime.UtcNow) - job.CreatedUtc).TotalSeconds), 1)));
                if (job.State == "running") text.Append(',').Append(Json.NumberProperty("running_seconds", Math.Round(Math.Max(0, (DateTime.UtcNow - job.StartedUtc).TotalSeconds), 1)));
                if (job.Total > 0)
                {
                    text.Append(",\"progress\":{").Append(Json.NumberProperty("done", job.Done)).Append(',')
                        .Append(Json.NumberProperty("total", job.Total)).Append(',')
                        .Append(Json.NumberProperty("remaining", Math.Max(0, job.Total - job.Done))).Append(',')
                        .Append(Json.Property("note", job.Note)).Append('}');
                }
                if (job.State == "queued")
                    text.Append(',').Append(Json.Property("message", "Revit has not started this request: it is busy with its own work (regenerating graphics, another command or a dialog). It will run when Revit is idle. Do not send it again. Call get_job to follow it, or get_job with cancel=true to drop it."));
                else if (job.State == "running")
                    text.Append(',').Append(Json.Property("message", "Revit is still working on this request. Do not run it again. Call get_job with this job_id until completed is true."));
                if (includeResult && job.State == "completed") text.Append(",\"result\":").Append(String.IsNullOrEmpty(job.ResultJson) ? "null" : job.ResultJson);
                if (job.State == "failed") text.Append(',').Append(Json.Property("error", job.Error));
                if (job.State == "cancelled") text.Append(',').Append(Json.Property("message", "The request was cancelled before Revit started it. Nothing was changed."));
                text.Append('}');
                return text.ToString();
            }
        }
    }

    // The options of a request, sent as one extra field "key=value;key=value" after the usual arguments.
    internal sealed class RunOptions
    {
        internal bool DryRun;
        internal bool Background;
        internal int WaitSeconds;

        internal static RunOptions Parse(string text, int defaultWaitSeconds)
        {
            RunOptions options = new RunOptions();
            options.WaitSeconds = defaultWaitSeconds;
            foreach (string pair in (text ?? "").Split(';'))
            {
                string[] parts = pair.Split(new char[] { '=' }, 2);
                if (parts.Length != 2) continue;
                string key = parts[0].Trim().ToLowerInvariant();
                string value = parts[1].Trim();
                if (key == "dry_run") options.DryRun = String.Equals(value, "true", StringComparison.OrdinalIgnoreCase);
                else if (key == "background") options.Background = String.Equals(value, "true", StringComparison.OrdinalIgnoreCase);
                else if (key == "wait_seconds")
                {
                    int seconds;
                    if (Int32.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out seconds)) options.WaitSeconds = Math.Max(1, Math.Min(110, seconds));
                }
            }
            return options;
        }

        internal static string Value(string text, string key)
        {
            foreach (string pair in (text ?? "").Split(';'))
            {
                string[] parts = pair.Split(new char[] { '=' }, 2);
                if (parts.Length == 2 && String.Equals(parts[0].Trim(), key, StringComparison.OrdinalIgnoreCase)) return parts[1].Trim();
            }
            return "";
        }
    }

    // Counts what a transaction added, modified and deleted, from Revit's DocumentChanged event.
    internal sealed class ChangeCounter
    {
        private readonly Document _document;
        private bool _listening;
        internal int Events;
        internal int Added;
        internal int Modified;
        internal int Deleted;
        internal readonly Dictionary<string, int> AddedByCategory = new Dictionary<string, int>();
        internal readonly Dictionary<string, int> ModifiedByCategory = new Dictionary<string, int>();

        internal ChangeCounter(Document document)
        {
            _document = document;
            _document.Application.DocumentChanged += OnChanged;
            _listening = true;
        }

        internal void Stop()
        {
            if (!_listening) return;
            _listening = false;
            _document.Application.DocumentChanged -= OnChanged;
        }

        private void OnChanged(object sender, Autodesk.Revit.DB.Events.DocumentChangedEventArgs e)
        {
            Document changed = e.GetDocument();
            if (changed == null || !Object.ReferenceEquals(changed, _document)) return;
            Events++;
            foreach (ElementId id in e.GetAddedElementIds())
            {
                Added++;
                Count(AddedByCategory, id);
            }
            foreach (ElementId id in e.GetModifiedElementIds())
            {
                Modified++;
                Count(ModifiedByCategory, id);
            }
            Deleted += e.GetDeletedElementIds().Count;
        }

        private void Count(Dictionary<string, int> counts, ElementId id)
        {
            string name = "(no category)";
            try
            {
                Element element = _document.GetElement(id);
                if (element != null && element.Category != null) name = element.Category.Name;
            }
            catch (Exception) { }
            int current;
            counts.TryGetValue(name, out current);
            counts[name] = current + 1;
        }

        private static string CountsJson(Dictionary<string, int> counts)
        {
            return "{" + String.Join(",", counts.OrderByDescending(p => p.Value).Select(p => Json.NumberProperty(p.Key, p.Value)).ToArray()) + "}";
        }

        internal string ToJson()
        {
            if (Events == 0)
                return "{" + Json.NumberProperty("events_observed", 0) + "," + Json.Property("note", "Revit raised no change events, so the changes could not be counted. The transaction was still rolled back.") + "}";
            return "{" + Json.NumberProperty("events_observed", Events) + "," +
                Json.NumberProperty("added", Added) + "," +
                Json.NumberProperty("modified", Modified) + "," +
                Json.NumberProperty("deleted", Deleted) + "," +
                "\"added_by_category\":" + CountsJson(AddedByCategory) + "," +
                "\"modified_by_category\":" + CountsJson(ModifiedByCategory) + "}";
        }
    }

    internal static class Changes
    {
        // Runs action in one transaction. A dry run happens inside a transaction group that is rolled back afterwards, and
        // changesJson then holds the counts; otherwise the transaction is committed and changesJson is empty.
        // In a workshared model Revit can keep elements checked out after a dry run; they are released at the next synchronise.
        internal static string Run(Document document, string name, bool dryRun, Func<string> action, out string changesJson)
        {
            changesJson = "";
            if (!dryRun)
            {
                using (Transaction transaction = new Transaction(document, name))
                {
                    transaction.Start();
                    try
                    {
                        string result = action();
                        TransactionStatus status = transaction.Commit();
                        if (status != TransactionStatus.Committed)
                            throw new McpException("commit_failed", "Revit did not commit the transaction. Status: " + status.ToString() + ". Nothing was changed.");
                        return result;
                    }
                    catch
                    {
                        if (transaction.GetStatus() == TransactionStatus.Started) transaction.RollBack();
                        throw;
                    }
                }
            }

            string text;
            using (TransactionGroup group = new TransactionGroup(document, "Dry run: " + name))
            {
                ChangeCounter counter = new ChangeCounter(document);
                try
                {
                    group.Start();
                    using (Transaction transaction = new Transaction(document, name))
                    {
                        transaction.Start();
                        try
                        {
                            text = action();
                            TransactionStatus status = transaction.Commit();
                            if (status != TransactionStatus.Committed)
                                throw new McpException("commit_failed", "Revit did not commit the transaction in the dry run. Status: " + status.ToString() + ".");
                        }
                        catch
                        {
                            if (transaction.GetStatus() == TransactionStatus.Started) transaction.RollBack();
                            throw;
                        }
                    }
                    counter.Stop();
                }
                catch
                {
                    counter.Stop();
                    RollBackGroup(group);
                    throw;
                }
                RollBackGroup(group);
                changesJson = counter.ToJson();
                return text;
            }
        }

        private static void RollBackGroup(TransactionGroup group)
        {
            try
            {
                if (group.GetStatus() == TransactionStatus.Started) group.RollBack();
            }
            catch (Exception exception)
            {
                throw new McpException("rollback_failed", "The dry run could not be rolled back: " + exception.Message + " Check the model before doing anything else.", exception);
            }
        }
    }
}
