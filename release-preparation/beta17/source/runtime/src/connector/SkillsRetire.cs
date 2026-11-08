using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

// scripts\retire-background-tasks.ps1 as compiled code. Like that script, this is the one place that names the scheduled
// tasks, the notification-area agent and the remote gateway of earlier versions, because it exists to remove them;
// tests\test-lean-core.ps1 therefore leaves this file out when it checks that nothing schedules or serves anything.
namespace SmartConnector
{
    // Removes what earlier versions set up in the background. Smart Connector runs nothing in the background. Earlier
    // versions set up, per Windows user: scheduled tasks (the connector agent, usage reporting, weekly Skills Sync and update
    // alerts), the connector agent itself (a hidden notification-area PowerShell process) and the optional Claude remote
    // gateway (a local HTTP gateway plus a Cloudflare tunnel, started from the Startup folder, with its credentials stored
    // under AutodeskMcpConnector\remote). Safe to run any number of times; each part fails on its own.
    internal static class RetireTasks
    {
        // Our scripts, as they appear in the actions of tasks created by earlier versions.
        private static readonly string[] RetiredScripts = { "connector-agent.ps1", "send-usage.ps1", "weekly-skill-collection.ps1", "autodesk-mcp-update-notifier.ps1" };
        private static readonly string[] RetiredTaskPrefixes = { "Smart Autodesk Connector Agent - ", "Autodesk MCP Usage Report - ", "Autodesk MCP Weekly Skills - ", "Autodesk MCP Connector Update Alerts" };
        // Files of the agent and the remote gateway left in the install folder by earlier versions.
        private static readonly string[] RetiredFiles = { @"scripts\connector-agent.ps1", @"scripts\autodesk-mcp-update-notifier.ps1", "REMOTE-CLAUDE.md",
            @"src\autodesk\autodesk-http-gateway.ps1", @"src\autodesk\Initialize-AutodeskMcpRemote.ps1", @"src\autodesk\Start-AutodeskMcpRemote.ps1",
            @"src\autodesk\Stop-AutodeskMcpRemote.ps1", @"src\autodesk\Get-AutodeskMcpRemoteConnection.ps1" };

        internal sealed class Options
        {
            internal bool StopAgent;
            internal string StateRoot, ConnectorState, StartupFolder, InstallRoot;
        }

        // A task is ours when its name is one we used, or when it runs one of our scripts from our folders.
        internal static bool IsRetiredTask(string taskName, IEnumerable<string> actionArguments)
        {
            foreach (string prefix in RetiredTaskPrefixes)
                if (taskName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return true;
            foreach (string arguments in actionArguments)
            {
                if (String.IsNullOrEmpty(arguments)) continue;
                if (!Regex.IsMatch(arguments, "AutodeskMcpSkillCollection|BIM-CAD-MCP", RegexOptions.IgnoreCase)) continue;
                foreach (string name in RetiredScripts)
                    if (arguments.IndexOf(name, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            }
            return false;
        }

        private sealed class TaskInfo
        {
            internal string Name = "", Folder = "";
            internal List<string> Arguments = new List<string>();
            internal dynamic FolderObject;
        }

        // The Task Scheduler's own COM interface, so no scheduling command is run. Absent or refused: no tasks.
        private static List<TaskInfo> ListTasks()
        {
            List<TaskInfo> tasks = new List<TaskInfo>();
            try
            {
                Type type = Type.GetTypeFromProgID("Schedule.Service");
                if (type == null) return tasks;
                dynamic service = Activator.CreateInstance(type);
                service.Connect();
                Collect(service.GetFolder("\\"), tasks);
            }
            catch (Exception) { }
            return tasks;
        }

        private static void Collect(dynamic folder, List<TaskInfo> tasks)
        {
            try
            {
                // 1 = TASK_ENUM_HIDDEN: hidden tasks are listed too.
                foreach (object entry in (IEnumerable)folder.GetTasks(1))
                {
                    try
                    {
                        dynamic task = entry;
                        TaskInfo info = new TaskInfo();
                        info.Name = (string)task.Name; info.Folder = (string)folder.Path; info.FolderObject = folder;
                        try
                        {
                            foreach (object actionEntry in (IEnumerable)task.Definition.Actions)
                            {
                                dynamic action = actionEntry;
                                // Type 0 is an executable action; the others have no arguments.
                                info.Arguments.Add((int)action.Type == 0 ? ((string)action.Arguments ?? "") : "");
                            }
                        }
                        catch (Exception) { }
                        tasks.Add(info);
                    }
                    catch (Exception) { }
                }
            }
            catch (Exception) { }
            try
            {
                foreach (object child in (IEnumerable)folder.GetFolders(0)) Collect((dynamic)child, tasks);
            }
            catch (Exception) { }
        }

        internal static List<string> RemoveRetiredTasks(SkillSink sink)
        {
            List<string> removed = new List<string>();
            foreach (TaskInfo task in ListTasks())
            {
                if (!IsRetiredTask(task.Name, task.Arguments)) continue;
                try
                {
                    task.FolderObject.DeleteTask(task.Name, 0);
                    removed.Add(task.Name);
                }
                catch (Exception exception) { sink.Warn("Scheduled task '" + task.Name + "' could not be removed: " + exception.Message); }
            }
            return removed;
        }

        // send-usage.ps1 -Action Unregister: the usage task that earlier versions scheduled for this Windows user.
        internal static void UnregisterUsageTask()
        {
            string name = "Autodesk MCP Usage Report - " + System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
            foreach (TaskInfo task in ListTasks())
                if (String.Equals(task.Name, name, StringComparison.OrdinalIgnoreCase)) task.FolderObject.DeleteTask(task.Name, 0);
        }

        private static int StopRetiredAgent()
        {
            int stopped = 0;
            try
            {
                using (System.Management.ManagementObjectSearcher searcher = new System.Management.ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name = 'powershell.exe'"))
                    foreach (System.Management.ManagementBaseObject process in searcher.Get())
                    {
                        int id = Convert.ToInt32(process["ProcessId"], CultureInfo.InvariantCulture);
                        if (id == Process.GetCurrentProcess().Id || !Regex.IsMatch(Convert.ToString(process["CommandLine"], CultureInfo.InvariantCulture) ?? "", @"connector-agent\.ps1")) continue;
                        try { using (Process target = Process.GetProcessById(id)) { target.Kill(); stopped++; } }
                        catch (Exception) { }
                    }
            }
            catch (Exception) { }
            return stopped;
        }

        // Stops the remote gateway and tunnel this user started (matched by recorded process id and start time, so an
        // unrelated process that reused the id is left alone) and deletes the stored remote credentials.
        private static bool RemoveRemoteGateway(Options o)
        {
            string remoteRoot = Path.Combine(o.ConnectorState, "remote");
            bool found = false;
            string runtime = Path.Combine(remoteRoot, "runtime.json");
            if (File.Exists(runtime))
            {
                found = true;
                try
                {
                    object state = SkillFiles.ReadJson(runtime);
                    foreach (object entry in new[] { PsJson.Value(state, "gateway"), PsJson.Value(state, "tunnel") })
                    {
                        if (entry == null || PsJson.Value(entry, "pid") == null) continue;
                        try
                        {
                            using (Process process = Process.GetProcessById(PsJson.Int(PsJson.Value(entry, "pid"))))
                            {
                                DateTime recorded = DateTime.Parse(PsJson.Text(PsJson.Value(entry, "started_at")), CultureInfo.CurrentCulture).ToUniversalTime();
                                if (Regex.IsMatch(process.ProcessName, "^(powershell|cloudflared)", RegexOptions.IgnoreCase) && Math.Abs((process.StartTime.ToUniversalTime() - recorded).TotalSeconds) <= 2)
                                    process.Kill();
                            }
                        }
                        catch (Exception) { }
                    }
                }
                catch (Exception) { }
            }
            string startup = Path.Combine(o.StartupFolder, "Autodesk MCP Remote Connector.cmd");
            if (File.Exists(startup)) { found = true; File.Delete(startup); }
            if (Directory.Exists(remoteRoot)) { found = true; SkillFiles.DeleteFolder(remoteRoot); }
            return found;
        }

        private static int RemoveRetiredFiles(Options o)
        {
            int removed = 0;
            if (String.IsNullOrEmpty(o.InstallRoot) || !File.Exists(Path.Combine(o.InstallRoot, "installer", "Setup-BimCad.ps1"))) return removed;
            foreach (string relative in RetiredFiles)
            {
                string path = Path.Combine(o.InstallRoot, relative.Replace('\\', Path.DirectorySeparatorChar));
                try { if (File.Exists(path)) { File.Delete(path); removed++; } }
                catch (Exception) { }
            }
            return removed;
        }

        // Invoke-RetireBackgroundTasks: what was removed, one line each.
        internal static List<string> Run(Options o, SkillSink sink)
        {
            List<string> report = new List<string>();
            try
            {
                List<string> tasks = RemoveRetiredTasks(sink);
                if (tasks.Count > 0) report.Add("Removed scheduled tasks from an earlier version: " + String.Join(", ", tasks.ToArray()));
            }
            catch (Exception exception) { sink.Warn("Scheduled tasks could not be checked: " + exception.Message); }
            // The agent restarts itself from this copy after an update; without it, it simply exits.
            foreach (string name in new[] { "connector-agent.ps1", "autodesk-mcp-update-notifier.ps1" })
            {
                string copy = Path.Combine(o.StateRoot, "scripts", name);
                try { if (File.Exists(copy)) { File.Delete(copy); report.Add("Removed " + name + " from the skills folder."); } }
                catch (Exception) { }
            }
            try { string flag = Path.Combine(o.ConnectorState, "update-requested.flag"); if (File.Exists(flag)) File.Delete(flag); }
            catch (Exception) { }
            if (o.StopAgent)
            {
                try { if (StopRetiredAgent() > 0) report.Add("Stopped the connector agent from an earlier version."); }
                catch (Exception) { }
            }
            try { if (RemoveRemoteGateway(o)) report.Add("Removed Claude remote access (local gateway, tunnel start-up and stored credentials)."); }
            catch (Exception exception) { sink.Warn("Claude remote access could not be fully removed: " + exception.Message); }
            try { int count = RemoveRetiredFiles(o); if (count > 0) report.Add("Removed " + count + " file(s) of the agent and remote access from the install folder."); }
            catch (Exception) { }
            if (report.Count == 0) report.Add("Nothing runs in the background.");
            return report;
        }
    }
}
