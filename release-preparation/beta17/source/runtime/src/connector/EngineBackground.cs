using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

// Smart Connector runs nothing in the background. This removes what earlier versions set up, per Windows user: the
// scheduled tasks (connector agent, usage reporting, weekly Skills Sync, update alerts), the agent itself (a hidden
// notification-area PowerShell process), the optional Claude remote gateway with its tunnel and stored credentials, and
// the files of those in the install folder. The C# port of scripts\retire-background-tasks.ps1 and of
// Remove-BackgroundTasks / Remove-LegacyUpdateTask in Setup-BimCad.ps1. It only ever removes; it creates no task.
// Scheduled tasks are read and removed through the Task Scheduler COM interface (the same one Get-ScheduledTask uses).
// Safe to run any number of times; each part fails on its own.
namespace SmartConnector
{
    internal sealed partial class InstallEngine
    {
        // Our scripts, as they appear in the actions of tasks created by earlier versions.
        private static readonly string[] RetiredScripts = { "connector-agent.ps1", "send-usage.ps1", "weekly-skill-collection.ps1", "autodesk-mcp-update-notifier.ps1" };
        private static readonly string[] RetiredTaskPrefixes = { "Smart Autodesk Connector Agent - ", "Autodesk MCP Usage Report - ", "Autodesk MCP Weekly Skills - ", "Autodesk MCP Connector Update Alerts" };

        // Files of the agent and the remote gateway left in the install folder by earlier versions.
        private static readonly string[] RetiredFiles =
        {
            @"scripts\connector-agent.ps1", @"scripts\autodesk-mcp-update-notifier.ps1", "REMOTE-CLAUDE.md",
            @"src\autodesk\autodesk-http-gateway.ps1", @"src\autodesk\Initialize-AutodeskMcpRemote.ps1", @"src\autodesk\Start-AutodeskMcpRemote.ps1",
            @"src\autodesk\Stop-AutodeskMcpRemote.ps1", @"src\autodesk\Get-AutodeskMcpRemoteConnection.ps1"
        };

        // A task is ours when its name is one we used, or when it runs one of our scripts from our folders.
        internal static bool IsRetiredTask(string taskName, IEnumerable<string> actionArguments)
        {
            foreach (string prefix in RetiredTaskPrefixes) if (taskName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return true;
            foreach (string arguments in actionArguments)
            {
                if (String.IsNullOrEmpty(arguments)) continue;
                if (!Regex.IsMatch(arguments, "AutodeskMcpSkillCollection|BIM-CAD-MCP", RegexOptions.IgnoreCase)) continue;
                foreach (string name in RetiredScripts) if (arguments.IndexOf(name, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            }
            return false;
        }

        // ---------- Task Scheduler ----------

        // Calls action for every task of the scheduler, in every folder. folder is the task's own folder.
        private static void ForEachScheduledTask(Action<dynamic, dynamic> action)
        {
            dynamic root;
            try
            {
                Type type = Type.GetTypeFromProgID("Schedule.Service");
                if (type == null) return;
                dynamic service = Activator.CreateInstance(type);
                service.Connect();
                root = service.GetFolder("\\");
            }
            catch (Exception)
            {
                // No Task Scheduler to read (the service is off, or this is not Windows): there is nothing of ours in it.
                return;
            }
            Walk(root, action);
        }

        private static void Walk(dynamic folder, Action<dynamic, dynamic> action)
        {
            // 1 = TASK_ENUM_HIDDEN: hidden tasks too, as Get-ScheduledTask lists them.
            dynamic tasks = folder.GetTasks(1);
            int count = Convert.ToInt32(tasks.Count);
            for (int i = 1; i <= count; i++) action(folder, tasks.Item(i));
            dynamic folders = folder.GetFolders(0);
            int folderCount = Convert.ToInt32(folders.Count);
            for (int i = 1; i <= folderCount; i++) Walk(folders.Item(i), action);
        }

        private static List<string> ActionArgumentsOf(dynamic task)
        {
            List<string> result = new List<string>();
            try
            {
                dynamic actions = task.Definition.Actions;
                int count = Convert.ToInt32(actions.Count);
                for (int i = 1; i <= count; i++)
                {
                    try { result.Add(Convert.ToString(actions.Item(i).Arguments)); } catch (Exception) { }
                }
            }
            catch (Exception) { }
            return result;
        }

        private List<string> RemoveRetiredTasks()
        {
            List<string> removed = new List<string>();
            ForEachScheduledTask(delegate(dynamic folder, dynamic task)
            {
                string name = Convert.ToString(task.Name);
                if (!IsRetiredTask(name, ActionArgumentsOf(task))) return;
                try
                {
                    folder.DeleteTask(name, 0);
                    removed.Add(name);
                }
                catch (Exception exception) { Warning("Scheduled task '" + name + "' could not be removed: " + exception.Message); }
            });
            return removed;
        }

        // Before the connector agent, a separate scheduled task installed updates at 9:00.
        private void RemoveLegacyUpdateTask()
        {
            ForEachScheduledTask(delegate(dynamic folder, dynamic task)
            {
                string name = Convert.ToString(task.Name);
                if (String.Equals(name, UpdateTaskName, StringComparison.OrdinalIgnoreCase)) folder.DeleteTask(name, 0);
            });
        }

        // ---------- the agent, the remote gateway, the files ----------

        // The agent was a hidden PowerShell process running connector-agent.ps1.
        private static int StopRetiredAgent()
        {
            int stopped = 0;
            using (System.Management.ManagementObjectSearcher searcher = new System.Management.ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'powershell.exe'"))
            {
                foreach (System.Management.ManagementBaseObject process in searcher.Get())
                {
                    int id = Convert.ToInt32(process["ProcessId"]);
                    if (id == System.Diagnostics.Process.GetCurrentProcess().Id || !Regex.IsMatch(Convert.ToString(process["CommandLine"]), @"connector-agent\.ps1", RegexOptions.IgnoreCase)) continue;
                    try
                    {
                        using (System.Diagnostics.Process target = System.Diagnostics.Process.GetProcessById(id)) target.Kill();
                        stopped++;
                    }
                    catch (Exception) { }
                }
            }
            return stopped;
        }

        // Stops the remote gateway and tunnel this user started (matched by recorded process id and start time, so an
        // unrelated process that reused the id is left alone) and deletes the stored remote credentials.
        private static bool RemoveRemoteGateway(string connectorState, string startupFolder)
        {
            string remoteRoot = Path.Combine(connectorState, "remote");
            bool found = false;
            string runtime = Path.Combine(remoteRoot, "runtime.json");
            if (File.Exists(runtime))
            {
                found = true;
                try
                {
                    object state = Json.Serializer.DeserializeObject(File.ReadAllText(runtime));
                    foreach (string key in new[] { "gateway", "tunnel" })
                    {
                        object entry = PsJson.Value(state, key);
                        if (entry == null || PsJson.Value(entry, "pid") == null) continue;
                        try
                        {
                            using (System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById(PsJson.Int(PsJson.Value(entry, "pid"))))
                            {
                                DateTime recorded = DateTime.Parse(PsJson.Text(PsJson.Value(entry, "started_at")), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal);
                                if (Regex.IsMatch(process.ProcessName, "^(powershell|cloudflared)", RegexOptions.IgnoreCase) && Math.Abs((process.StartTime.ToUniversalTime() - recorded).TotalSeconds) <= 2)
                                    process.Kill();
                            }
                        }
                        catch (Exception) { }
                    }
                }
                catch (Exception) { }
            }
            string startup = Path.Combine(startupFolder, "Autodesk MCP Remote Connector.cmd");
            if (File.Exists(startup)) { found = true; File.Delete(startup); }
            if (Directory.Exists(remoteRoot)) { found = true; Directory.Delete(remoteRoot, true); }
            return found;
        }

        private static int RemoveRetiredFiles(string installRoot)
        {
            int removed = 0;
            if (String.IsNullOrEmpty(installRoot) || !(File.Exists(Path.Combine(installRoot, "bin", "SmartConnector.exe")) || File.Exists(Path.Combine(installRoot, "installer", "Setup-BimCad.ps1")))) return removed;
            foreach (string relative in RetiredFiles)
            {
                string path = Path.Combine(installRoot, relative.Replace('\\', Path.DirectorySeparatorChar));
                try { if (File.Exists(path)) { File.Delete(path); removed++; } } catch (Exception) { }
            }
            return removed;
        }

        // Remove-BackgroundTasks: the report lines go to the log like any other step. stopAgent also stops a running
        // connector agent from an earlier version; it is left off when an earlier version's agent is the process installing
        // this update (it would be cut off mid-update; it exits by itself afterwards, because its restart copy is removed
        // here and nothing starts it again).
        private void RemoveBackgroundTasks(string root, bool stopAgent)
        {
            try
            {
                List<string> report = new List<string>();
                string stateRoot = SkillServiceState;
                string connectorState = UpdateStateDirectory;
                string startupFolder = Path.Combine(Env.AppData, "Microsoft", "Windows", "Start Menu", "Programs", "Startup");
                try
                {
                    List<string> tasks = RemoveRetiredTasks();
                    if (tasks.Count > 0) report.Add("Removed scheduled tasks from an earlier version: " + String.Join(", ", tasks));
                }
                catch (Exception exception) { Warning("Scheduled tasks could not be checked: " + exception.Message); }
                // The agent restarts itself from this copy after an update; without it, it simply exits.
                foreach (string name in new[] { "connector-agent.ps1", "autodesk-mcp-update-notifier.ps1" })
                {
                    string copy = Path.Combine(stateRoot, "scripts", name);
                    try { if (File.Exists(copy)) { File.Delete(copy); report.Add("Removed " + name + " from the skills folder."); } } catch (Exception) { }
                }
                try { string flag = Path.Combine(connectorState, "update-requested.flag"); if (File.Exists(flag)) File.Delete(flag); } catch (Exception) { }
                if (stopAgent)
                {
                    try { if (StopRetiredAgent() > 0) report.Add("Stopped the connector agent from an earlier version."); } catch (Exception) { }
                }
                try { if (RemoveRemoteGateway(connectorState, startupFolder)) report.Add("Removed Claude remote access (local gateway, tunnel start-up and stored credentials)."); }
                catch (Exception exception) { Warning("Claude remote access could not be fully removed: " + exception.Message); }
                try { int count = RemoveRetiredFiles(root); if (count > 0) report.Add("Removed " + count + " file(s) of the agent and remote access from the install folder."); } catch (Exception) { }
                if (report.Count == 0) report.Add("Nothing runs in the background.");
                foreach (string line in report) Step(line);
            }
            catch (Exception exception) { Step("Earlier background tasks could not all be removed: " + exception.Message); }
        }
    }
}
