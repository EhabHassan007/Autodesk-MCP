using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Microsoft.Win32;

// What the Smart Connector app shows: a snapshot of this PC built only from files, the registry and the process
// list, so the app opens instantly. No network, no external commands, no secrets read. The C# port of
// installer\ConnectorStatus.ps1; every check is guarded and a missing item reads as not installed.
namespace SmartConnector
{
    // Folders from the environment, read the way the PowerShell scripts read $env:APPDATA, $HOME and $env:ProgramFiles.
    internal static class Env
    {
        internal static string Get(string name, Environment.SpecialFolder fallback)
        {
            string value = Environment.GetEnvironmentVariable(name);
            return String.IsNullOrWhiteSpace(value) ? Environment.GetFolderPath(fallback) : value;
        }
        internal static string AppData { get { return Get("APPDATA", Environment.SpecialFolder.ApplicationData); } }
        internal static string Home { get { return Get("USERPROFILE", Environment.SpecialFolder.UserProfile); } }
        // Set only by the engine's hidden --program-files option (tests); otherwise the environment is used.
        internal static string ProgramFilesOverride;
        internal static string ProgramFiles { get { return String.IsNullOrEmpty(ProgramFilesOverride) ? Get("ProgramFiles", Environment.SpecialFolder.ProgramFiles) : ProgramFilesOverride; } }
        internal static string Windows { get { return Get("SystemRoot", Environment.SpecialFolder.Windows); } }
        internal static string Variable(string name) { return Environment.GetEnvironmentVariable(name) ?? ""; }
    }

    // A program started from the Start menu, Revit, AutoCAD or the setup .exe inherits the PATH Windows had when the
    // session began, so a tool installed since (Claude Code, Codex, Node.js for their npm launchers) is not found and
    // shows as "Not installed". Add the current user and machine PATH from the registry and the folders those
    // installers use, after the inherited entries, so they keep their order. Children of this program inherit it.
    internal static class CommandPath
    {
        internal static void Refresh()
        {
            try
            {
                List<string> parts = new List<string>();
                HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                Action<string> add = delegate(string list)
                {
                    foreach (string raw in (list ?? "").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        string entry = raw.Trim().Trim('"');
                        if (entry.Length == 0) continue;
                        if (seen.Add(entry.TrimEnd('\\'))) parts.Add(entry);
                    }
                };
                add(Environment.GetEnvironmentVariable("PATH"));
                add(ReadPath(Registry.CurrentUser, "Environment"));
                add(ReadPath(Registry.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"));
                string[] known =
                {
                    Path.Combine(Env.Home, ".local", "bin"),                                   // Claude Code native installer
                    Path.Combine(Env.AppData, "npm"),                                          // npm install -g (claude, codex)
                    Path.Combine(Paths.LocalAppData, "Microsoft", "WinGet", "Links"),          // winget
                    Path.Combine(Paths.LocalAppData, "Microsoft", "WindowsApps"),              // Store apps
                    Path.Combine(Paths.LocalAppData, "pnpm"), Path.Combine(Env.Home, ".bun", "bin"), Path.Combine(Env.Home, "scoop", "shims"),
                    Path.Combine(Env.ProgramFiles, "nodejs")
                };
                foreach (string folder in known) if (Directory.Exists(folder)) add(folder);
                Environment.SetEnvironmentVariable("PATH", String.Join(";", parts.ToArray()));
            }
            catch (Exception) { }
        }

        private static string ReadPath(RegistryKey hive, string subKey)
        {
            try { using (RegistryKey key = hive.OpenSubKey(subKey)) { return key == null ? "" : Convert.ToString(key.GetValue("Path", "")); } }
            catch (Exception) { return ""; }
        }
    }

    // PowerShell's reading of ConvertFrom-Json values: property names match without regard to case, and [bool],
    // [int], [string] and -ne $false convert as PowerShell does.
    internal static class PsJson
    {
        internal static object Read(string path)
        {
            try { return File.Exists(path) ? Json.Serializer.DeserializeObject(File.ReadAllText(path)) : null; }
            catch (Exception) { return null; }
        }

        internal static object Value(object source, string name)
        {
            IDictionary<string, object> dictionary = source as IDictionary<string, object>;
            if (dictionary == null) return null;
            object value;
            if (dictionary.TryGetValue(name, out value)) return value;
            foreach (KeyValuePair<string, object> pair in dictionary)
                if (String.Equals(pair.Key, name, StringComparison.OrdinalIgnoreCase)) return pair.Value;
            return null;
        }

        internal static bool Has(object source, string name)
        {
            IDictionary<string, object> dictionary = source as IDictionary<string, object>;
            return dictionary != null && dictionary.Keys.Any(key => String.Equals(key, name, StringComparison.OrdinalIgnoreCase));
        }

        internal static string Text(object value)
        {
            if (value == null) return "";
            if (value is bool) return (bool)value ? "True" : "False";
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        internal static bool Truthy(object value)
        {
            if (value == null) return false;
            if (value is bool) return (bool)value;
            string text = value as string;
            if (text != null) return text.Length > 0;
            if (value is IConvertible && !(value is char)) { try { return Convert.ToDouble(value, CultureInfo.InvariantCulture) != 0; } catch (Exception) { } }
            return true;
        }

        internal static int Int(object value)
        {
            if (value == null) return 0;
            try
            {
                if (value is bool) return (bool)value ? 1 : 0;
                double number = Convert.ToDouble(value, CultureInfo.InvariantCulture);
                return (int)Math.Round(number, MidpointRounding.ToEven);
            }
            catch (Exception) { return 0; }
        }

        // ($value -ne $false): PowerShell converts $false to the left-hand type before comparing.
        internal static bool NotFalse(object value)
        {
            if (value == null) return true;
            if (value is bool) return (bool)value;
            string text = value as string;
            if (text != null) return !String.Equals(text, "False", StringComparison.OrdinalIgnoreCase);
            try { return Convert.ToDouble(value, CultureInfo.InvariantCulture) != 0; }
            catch (Exception) { return true; }
        }
    }

    internal sealed class Client
    {
        internal bool Installed, Connected;
    }

    internal sealed class Snapshot
    {
        internal string Version = "";
        internal bool Installed, RevitInstalled, RevitRunning, RevitAddin, AutoCadInstalled, AutoCadRunning, AutoCadPanel;
        internal string[] AutoCadReleases = new string[0];
        internal Client ClaudeDesktop = new Client(), ClaudeCode = new Client(), Codex = new Client();
        internal bool TeamJoined, AutoUpdates, SyncReminder;
        internal string AvailableVersion = "", LastChecked = "", LastSync = "", LastSyncStatus = "", LastSyncReason = "";
        internal int SyncSubmitted, SyncUpdated;
        internal double LastSyncDay = -1;
    }

    internal sealed class Headline
    {
        internal string Kind, Title, Text;
        internal Headline(string kind, string title, string text) { Kind = kind; Title = title; Text = text; }
    }

    internal sealed class InstalledSkill
    {
        internal string Name, Category, CategoryTitle;
    }

    internal static class ConnectorStatus
    {
        internal static string Install { get { return Paths.Root; } }
        internal static string ConnectorState { get { return Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector"); } }
        internal static string SkillState { get { return Path.Combine(Paths.LocalAppData, "AutodeskMcpSkillCollection"); } }
        internal static string RevitManifest { get { return Path.Combine(Env.AppData, "Autodesk", "Revit", "Addins", "2024", "AutodeskMcpConnector.addin"); } }
        internal static string AutoCadBundle { get { return Path.Combine(Env.AppData, "Autodesk", "ApplicationPlugins", "SmartAutodeskConnector.bundle", "PackageContents.xml"); } }

        // Skill categories, as scripts\SkillLibrary.ps1 names them.
        internal static readonly string[][] SkillCategories =
        {
            new[] { "revit", "Revit" }, new[] { "autocad", "AutoCAD" }, new[] { "3ds-max", "3ds Max" }, new[] { "other-software", "Other software" },
            new[] { "linkedin-marketing", "LinkedIn and marketing" }, new[] { "branding-ci", "Personal branding and corporate identity" },
            new[] { "general", "General and office" }, new[] { "uncategorized", "Not yet categorised" }
        };

        internal static bool ProcessRunning(string name)
        {
            try
            {
                Process[] processes = Process.GetProcessesByName(name);
                foreach (Process process in processes) process.Dispose();
                return processes.Length > 0;
            }
            catch (Exception) { return false; }
        }

        // HKLM\SOFTWARE in the 64-bit view, as 64-bit PowerShell sees it.
        internal static RegistryKey OpenMachineKey(string path)
        {
            RegistryKey machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, Environment.Is64BitOperatingSystem ? RegistryView.Registry64 : RegistryView.Default);
            return machine.OpenSubKey(path);
        }

        internal static string[] AutoCadReleasesInstalled()
        {
            try
            {
                using (RegistryKey key = OpenMachineKey(@"SOFTWARE\Autodesk\AutoCAD"))
                    return key == null ? new string[0] : key.GetSubKeyNames().OrderBy(name => name, StringComparer.OrdinalIgnoreCase).ToArray();
            }
            catch (Exception) { return new string[0]; }
        }

        private static string[] ClaudePackages()
        {
            try
            {
                string packages = Path.Combine(Paths.LocalAppData, "Packages");
                return Directory.Exists(packages) ? Directory.GetDirectories(packages, "*Claude*") : new string[0];
            }
            catch (Exception) { return new string[0]; }
        }

        // True when a Claude Desktop config (roaming or Microsoft Store copy) lists the Smart Connector entry.
        internal static bool ClaudeDesktopConnected()
        {
            List<string> paths = new List<string> { Path.Combine(Env.AppData, "Claude", "claude_desktop_config.json") };
            foreach (string package in ClaudePackages()) paths.Add(Path.Combine(package, "LocalCache", "Roaming", "Claude", "claude_desktop_config.json"));
            foreach (string path in paths)
            {
                object servers = PsJson.Value(PsJson.Read(path), "mcpServers");
                if (servers != null && PsJson.Has(servers, "Smart Connector")) return true;
            }
            return false;
        }

        internal static bool ClaudeDesktopInstalled()
        {
            return Directory.Exists(Path.Combine(Paths.LocalAppData, "AnthropicClaude")) || Directory.Exists(Path.Combine(Env.AppData, "Claude")) || ClaudePackages().Length > 0;
        }

        internal static bool ClaudeCodeConnected()
        {
            object servers = PsJson.Value(PsJson.Read(Path.Combine(Env.Home, ".claude.json")), "mcpServers");
            return servers != null && PsJson.Has(servers, "autodesk");
        }

        internal static bool CodexConnected()
        {
            string codexHome = Env.Variable("CODEX_HOME");
            if (codexHome.Length == 0) codexHome = Path.Combine(Env.Home, ".codex");
            string config = Path.Combine(codexHome, "config.toml");
            try { return File.Exists(config) && File.ReadAllLines(config).Any(line => Regex.IsMatch(line, @"^\s*\[mcp_servers\.autodesk\]", RegexOptions.IgnoreCase)); }
            catch (Exception) { return false; }
        }

        // Get-Command for a program on PATH: the PATHEXT extensions and PowerShell scripts.
        internal static bool CommandOnPath(string name)
        {
            string[] extensions = (Env.Variable("PATHEXT").Length > 0 ? Env.Variable("PATHEXT") : ".COM;.EXE;.BAT;.CMD").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries).Concat(new[] { ".ps1" }).ToArray();
            foreach (string folder in Env.Variable("PATH").Split(new[] { Path.PathSeparator }, StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    string directory = folder.Trim().Trim('"');
                    if (directory.Length == 0) continue;
                    foreach (string extension in extensions) if (File.Exists(Path.Combine(directory, name + extension))) return true;
                }
                catch (Exception) { }
            }
            return false;
        }

        // Every installed workflow skill (shipped library and approved downloads), each once, by category.
        internal static List<InstalledSkill> InstalledWorkflowSkills()
        {
            // Keyed without regard to case, like the PowerShell hashtable it replaces.
            Dictionary<string, Workflows.Skill> skills = new Dictionary<string, Workflows.Skill>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (Workflows.Skill skill in Workflows.SkillsIn(Path.Combine(Install, ".agents", "skills"))) skills[skill.Name] = skill;
                foreach (Workflows.Skill skill in Workflows.SkillsIn(Path.Combine(SkillState, "approved-skills")))
                {
                    string category = skill.Category.Length > 0 ? skill.Category : skills.ContainsKey(skill.Name) ? skills[skill.Name].Category : "uncategorized";
                    skills[skill.Name] = new Workflows.Skill { Name = skill.Name, Category = category, Path = skill.Path };
                }
            }
            catch (Exception) { }
            return skills.Values.Select(skill =>
            {
                string category = skill.Category.Length > 0 ? skill.Category : "uncategorized";
                string[] known = SkillCategories.FirstOrDefault(pair => pair[0] == category);
                return new InstalledSkill { Name = skill.Name, Category = category, CategoryTitle = known != null ? known[1] : "Not yet categorised" };
            }).OrderBy(skill => skill.Category, StringComparer.CurrentCultureIgnoreCase).ThenBy(skill => skill.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        }

        // Day stamps shared with the Revit add-in and the AutoCAD panel: days since 1970-01-01 UTC, as text.
        //   AutodeskMcpConnector\open-check.txt         last update check made when an app opened
        //   AutodeskMcpSkillCollection\last-sync.txt     last successful Skills Sync
        //   AutodeskMcpSkillCollection\sync-reminder.txt last weekly Skills Sync reminder shown
        internal static double Today { get { return (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalDays; } }
        internal static string OpenCheckPath { get { return Path.Combine(ConnectorState, "open-check.txt"); } }

        internal static double ReadDay(string path)
        {
            try
            {
                double value;
                if (File.Exists(path) && Double.TryParse(File.ReadAllText(path).Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out value)) return value;
            }
            catch (Exception) { }
            return -1.0;
        }

        internal static void WriteDay(string path)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, Today.ToString("0.000", CultureInfo.InvariantCulture));
            }
            catch (Exception) { }
        }

        // Same rules as the Revit add-in (OpenCheck) and SmartConnectorStartup.lsp.
        internal static bool UpdateCheckDue(Snapshot snapshot, double now)
        {
            double last = ReadDay(OpenCheckPath);
            return snapshot.AutoUpdates && (last < 0 || now - last >= 0.8);
        }

        // Team PCs with the reminder on, whose last successful Skills Sync is more than a week old (or never ran).
        internal static bool SyncReminderDue(Snapshot snapshot, double now)
        {
            return snapshot.TeamJoined && snapshot.SyncReminder && (snapshot.LastSyncDay < 0 || now - snapshot.LastSyncDay >= 7);
        }

        internal static Snapshot Take()
        {
            string versionPath = Path.Combine(Install, "VERSION");
            object update = PsJson.Read(Path.Combine(ConnectorState, "update-state.json"));
            object sync = PsJson.Read(Path.Combine(SkillState, "last-result.json"));
            object skillSettings = PsJson.Read(Path.Combine(SkillState, "settings.json"));
            Snapshot s = new Snapshot();
            try { s.Version = File.Exists(versionPath) ? File.ReadAllText(versionPath).Trim() : ""; } catch (Exception) { }
            // The compiled program (a release install carries no scripts) or, for a copy from the repository, the setup script.
            s.Installed = File.Exists(Path.Combine(Install, "bin", "SmartConnector.exe")) || File.Exists(Path.Combine(Install, "installer", "Setup-BimCad.ps1"));
            s.RevitInstalled = File.Exists(Path.Combine(Env.ProgramFiles, "Autodesk", "Revit 2024", "RevitAPI.dll"));
            s.RevitRunning = ProcessRunning("Revit");
            s.RevitAddin = File.Exists(RevitManifest);
            s.AutoCadReleases = AutoCadReleasesInstalled();
            s.AutoCadInstalled = s.AutoCadReleases.Length > 0;
            s.AutoCadRunning = ProcessRunning("acad");
            s.AutoCadPanel = File.Exists(AutoCadBundle);
            s.ClaudeDesktop = new Client { Installed = ClaudeDesktopInstalled(), Connected = ClaudeDesktopConnected() };
            s.ClaudeCode = new Client { Installed = CommandOnPath("claude"), Connected = ClaudeCodeConnected() };
            s.Codex = new Client { Installed = CommandOnPath("codex"), Connected = CodexConnected() };
            s.TeamJoined = File.Exists(Path.Combine(SkillState, "service.json"));
            s.AutoUpdates = !PsJson.Truthy(PsJson.Value(update, "notifications_user_disabled"));
            s.AvailableVersion = PsJson.Text(PsJson.Value(update, "available_version"));
            s.LastChecked = PsJson.Text(PsJson.Value(update, "last_checked_utc"));
            s.LastSync = PsJson.Text(PsJson.Value(sync, "completed_at"));
            s.LastSyncStatus = PsJson.Text(PsJson.Truthy(PsJson.Value(sync, "sync_status")) ? PsJson.Value(sync, "sync_status") : PsJson.Value(sync, "status"));
            s.LastSyncReason = PsJson.Text(PsJson.Value(sync, "sync_reason"));
            s.SyncSubmitted = PsJson.Int(PsJson.Value(sync, "sync_submitted"));
            s.SyncUpdated = PsJson.Int(PsJson.Value(sync, "sync_updated")) + PsJson.Int(PsJson.Value(sync, "sync_added"));
            s.LastSyncDay = ReadDay(Path.Combine(SkillState, "last-sync.txt"));
            s.SyncReminder = PsJson.NotFalse(PsJson.Value(skillSettings, "enabled"));
            return s;
        }

        // One line for the top of the Overview, plus its badge kind.
        internal static Headline HeadlineOf(Snapshot s)
        {
            bool ai = s.ClaudeDesktop.Connected || s.ClaudeCode.Connected || s.Codex.Connected;
            bool cad = s.RevitAddin || s.AutoCadPanel;
            if (!s.Installed) return new Headline("Bad", "Smart Connector is not installed", "Run the Smart Connector setup to install it.");
            if (!ai) return new Headline("Warn", "No AI app is connected", "Connect Claude or Codex: open Components and choose Repair.");
            if (!cad) return new Headline("Warn", "No Autodesk program is set up", "Install Revit 2024 or AutoCAD, then choose Repair in Components.");
            if (String.Equals(s.LastSyncStatus, "failed", StringComparison.OrdinalIgnoreCase))
                return new Headline("Warn", "Working, but Skills Sync needs attention", s.LastSyncReason.Length > 0 ? s.LastSyncReason : "The last Skills Sync did not finish. Open Diagnostics for the log.");
            List<string> apps = new List<string>(); if (s.RevitAddin) apps.Add("Revit"); if (s.AutoCadPanel) apps.Add("AutoCAD");
            List<string> clients = new List<string>(); if (s.ClaudeDesktop.Connected || s.ClaudeCode.Connected) clients.Add("Claude"); if (s.Codex.Connected) clients.Add("Codex");
            return new Headline("Good", "Everything is set up", String.Join(" and ", clients) + " can work with " + String.Join(" and ", apps) + ".");
        }

        // For app --print-snapshot: the snapshot, headline and reminder rules as JSON, so tests can compare them
        // with ConnectorStatus.ps1 for the same state files.
        internal static string Describe(double now)
        {
            Snapshot s = Take();
            Headline h = HeadlineOf(s);
            Func<Client, object> client = c => Json.Object("Installed", c.Installed, "Connected", c.Connected);
            return Json.Ascii(Json.Object(
                "Version", s.Version, "Installed", s.Installed, "RevitInstalled", s.RevitInstalled, "RevitAddin", s.RevitAddin,
                "AutoCadInstalled", s.AutoCadInstalled, "AutoCadReleases", s.AutoCadReleases, "AutoCadPanel", s.AutoCadPanel,
                "ClaudeDesktop", client(s.ClaudeDesktop), "ClaudeCode", client(s.ClaudeCode), "Codex", client(s.Codex),
                "TeamJoined", s.TeamJoined, "AutoUpdates", s.AutoUpdates, "AvailableVersion", s.AvailableVersion, "LastChecked", s.LastChecked,
                "LastSync", s.LastSync, "LastSyncStatus", s.LastSyncStatus, "LastSyncReason", s.LastSyncReason,
                "SyncSubmitted", s.SyncSubmitted, "SyncUpdated", s.SyncUpdated, "LastSyncDay", s.LastSyncDay, "SyncReminder", s.SyncReminder,
                "Headline", Json.Object("Kind", h.Kind, "Title", h.Title, "Text", h.Text),
                "UpdateCheckDue", UpdateCheckDue(s, now), "SyncReminderDue", SyncReminderDue(s, now),
                "Skills", InstalledWorkflowSkills().Select(k => (object)Json.Object("Name", k.Name, "Category", k.Category)).ToArray()));
        }
    }

    // Settings.ps1 Get-ConnectorSettingsState: the update-check switch and version information.
    internal sealed class SettingsState
    {
        internal bool AutoUpdate;
        internal string Installed = "", Available = "", LastChecked = "";

        internal static SettingsState Read()
        {
            object state = PsJson.Read(Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector", "update-state.json"));
            // No state yet, or a value never chosen by the person, both mean the default: on.
            bool userOff = state != null && PsJson.Has(state, "notifications_user_disabled") && PsJson.Truthy(PsJson.Value(state, "notifications_user_disabled"));
            return new SettingsState
            {
                AutoUpdate = !userOff,
                Installed = PsJson.Text(PsJson.Value(state, "installed_version")),
                Available = PsJson.Text(PsJson.Value(state, "available_version")),
                LastChecked = PsJson.Truthy(PsJson.Value(state, "last_checked_utc")) ? PsJson.Text(PsJson.Value(state, "last_checked_utc")) : ""
            };
        }
    }
}
