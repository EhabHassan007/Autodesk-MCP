using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

// The setup-time scripts for the skill library, as compiled code: scripts\sync-codex-skills.ps1 (install the library for
// Codex and Claude), scripts\configure-connector-tasks.ps1, scripts\retire-background-tasks.ps1 and
// scripts\Initialize-SkillService.ps1.
namespace SmartConnector
{
    // Skills of the connector installed for Codex and Claude: flat, one folder per skill, whatever the category folders say.
    internal static class CodexSync
    {
        private sealed class RepositorySkill { internal string Name, FullName; }

        private static List<RepositorySkill> RepositorySkills(string skillsSource, SkillSink sink)
        {
            if (!Directory.Exists(skillsSource)) throw new InvalidOperationException("Skill library was not found: " + skillsSource);
            // Category folders in the library; each skill is still installed flat under its own name.
            List<SkillFolder> found = SkillLibrary.SkillFolders(skillsSource);
            string root = Path.GetFullPath(skillsSource).TrimEnd('\\', '/');
            Func<SkillFolder, bool> flat = s => String.Equals(Path.GetFullPath(Path.GetDirectoryName(Path.GetFullPath(s.Path))).TrimEnd('\\', '/'), root, StringComparison.OrdinalIgnoreCase);
            HashSet<string> categorised = new HashSet<string>(found.Where(s => !flat(s)).Select(s => s.Name), StringComparer.OrdinalIgnoreCase);
            // A flat copy left beside the category folders by an older version is ignored when the same skill is categorised.
            List<SkillFolder> stale = found.Where(s => flat(s) && categorised.Contains(s.Name)).ToList();
            if (stale.Count > 0) sink.Warn("Ignoring " + stale.Count + " older flat skill copies that are now in category folders.");
            return found.Where(s => !stale.Contains(s)).Select(s => new RepositorySkill { Name = s.Name, FullName = s.Path })
                .OrderBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        }

        private static List<RepositorySkill> TestRepositorySkills(string skillsSource, SkillSink sink)
        {
            List<RepositorySkill> skills = RepositorySkills(skillsSource, sink);
            if (skills.Count == 0) throw new InvalidOperationException("The repository skill library is empty.");
            string[] duplicates = skills.GroupBy(s => s.Name, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1).Select(g => g.Key).ToArray();
            if (duplicates.Length > 0) throw new InvalidOperationException("Skill names must be unique across categories: " + String.Join(", ", duplicates));
            foreach (RepositorySkill skill in skills)
            {
                if (!Regex.IsMatch(skill.Name, "^[a-z0-9]+(?:-[a-z0-9]+)*$")) throw new InvalidOperationException("Invalid skill folder name: " + skill.Name);
                string manifestPath = Path.Combine(skill.FullName, "SKILL.md");
                if (!File.Exists(manifestPath)) throw new InvalidOperationException("Missing SKILL.md: " + skill.FullName);
                string manifest = SkillFiles.ReadText(manifestPath);
                if (!manifest.StartsWith("---", StringComparison.Ordinal) || !Regex.IsMatch(manifest, @"^name:\s*\S.+$", RegexOptions.Multiline | RegexOptions.IgnoreCase))
                    throw new InvalidOperationException("Missing YAML name in " + manifestPath);
                if (!Regex.IsMatch(manifest, @"^description:\s*\S.+$", RegexOptions.Multiline | RegexOptions.IgnoreCase))
                    throw new InvalidOperationException("Missing YAML description in " + manifestPath);
            }
            return skills;
        }

        private static void InstallRepositorySkills(string skillsSource, string destination, SkillSink sink)
        {
            List<RepositorySkill> skills = TestRepositorySkills(skillsSource, sink);
            Directory.CreateDirectory(destination);
            foreach (RepositorySkill skill in skills)
            {
                string target = Path.Combine(destination, skill.Name);
                if (Directory.Exists(target)) SkillFiles.DeleteFolder(target);
                SkillFiles.CopyFolder(skill.FullName, target);
                sink.Out("Installed skill: " + skill.Name);
            }
            sink.Out("Skill library installed at: " + destination);
        }

        // git -C <repository> ...: the output is shown, a failure stops with the command named.
        private static string[] Git(string repositoryRoot, SkillSink sink, params string[] arguments)
        {
            string git = SkillProcess.Find("git");
            if (git == null) throw new InvalidOperationException("The term 'git' is not recognized as the name of a cmdlet, function, script file, or operable program.");
            ProcessResult result = SkillProcess.Run(git, new[] { "-C", repositoryRoot }.Concat(arguments).ToArray(), null, null, null);
            string[] lines = result.StdOut.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries);
            // What git prints is shown, except the status listing, which is read here.
            if (arguments[0] != "status")
            {
                foreach (string line in lines) sink.Out(line);
                foreach (string line in result.StdErr.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)) SkillConsole.Err(line);
            }
            if (result.ExitCode != 0) throw new InvalidOperationException("Git failed: git " + String.Join(" ", arguments));
            return lines;
        }

        internal static int Run(string action, string message, string destination, string repositoryRoot, SkillSink sink)
        {
            bool configureTasks = String.IsNullOrWhiteSpace(destination);
            string skillsSource = Path.Combine(repositoryRoot, ".agents", "skills");
            if (configureTasks)
            {
                string codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
                destination = Path.Combine(String.IsNullOrWhiteSpace(codexHome) ? Path.Combine(Env.Home, ".codex") : codexHome, "skills");
            }
            if (action == "Install")
            {
                InstallRepositorySkills(skillsSource, destination, sink);
                // Beta 15's updater executes the freshly downloaded script before client registration. This bootstraps the
                // integrated settings even when the parent installer is older.
                if (configureTasks) ConnectorTasks.Run(repositoryRoot, sink);
                return 0;
            }
            if (action == "Update")
            {
                Git(repositoryRoot, sink, "pull", "--ff-only", "origin", "main");
                InstallRepositorySkills(skillsSource, destination, sink);
                return 0;
            }
            TestRepositorySkills(skillsSource, sink);
            string[] outside = Git(repositoryRoot, sink, "status", "--porcelain", "--untracked-files=all").Where(line =>
            {
                string path = line.Length > 3 ? line.Substring(3).Replace('\\', '/') : "";
                return path.Length > 0 && !path.StartsWith(".agents/skills/", StringComparison.Ordinal);
            }).ToArray();
            if (outside.Length > 0)
                throw new InvalidOperationException("Publishing stopped because files outside .agents/skills have changes. Commit, discard, or temporarily move those changes first.\n" + String.Join(Environment.NewLine, outside));
            Git(repositoryRoot, sink, "add", "--", ".agents/skills");
            string gitProgram = SkillProcess.Find("git");
            bool hasStagedSkillChanges = SkillProcess.Run(gitProgram, new[] { "-C", repositoryRoot, "diff", "--cached", "--quiet", "--", ".agents/skills" }, null, null, null).ExitCode != 0;
            if (hasStagedSkillChanges) Git(repositoryRoot, sink, "commit", "-m", message, "--", ".agents/skills");
            else sink.Out("No local skill changes to commit.");
            Git(repositoryRoot, sink, "pull", "--rebase", "origin", "main");
            Git(repositoryRoot, sink, "push", "origin", "HEAD:main");
            InstallRepositorySkills(skillsSource, destination, sink);
            return 0;
        }
    }

    // Runs at Install / Repair and when an earlier version installs this one as an update. Smart Connector registers nothing in
    // the background: update checks and the weekly Skills Sync reminder happen when Revit, AutoCAD or Smart Connector opens.
    // This removes what earlier versions set up, refreshes the Skills Sync helper scripts and keeps the person's choices.
    internal static class ConnectorTasks
    {
        private static readonly string[] Helpers = { "SkillLibrary.ps1", "weekly-skill-collection.ps1", "collect-skills-for-review.ps1", "submit-team-knowledge.ps1",
            "central-skill-sync.ps1", "Initialize-SkillService.ps1", "send-usage.ps1" };

        // Turning update checks on is still Setup-BimCad.ps1 -Action EnableNotifications; it moves to the compiled
        // installer engine together with the rest of the install steps.
        private static void EnableUpdateChecks(string repositoryRoot, SkillSink sink)
        {
            string powershell = Path.Combine(Env.Windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            string script = Path.Combine(repositoryRoot, "installer", "Setup-BimCad.ps1");
            ProcessResult result = SkillProcess.Run(powershell, new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Action", "EnableNotifications", "-RepositoryPath", repositoryRoot }, null, null, null);
            foreach (string line in result.Lines) sink.Out(line);
            if (result.ExitCode != 0) throw new InvalidOperationException("Settings could not be saved (exit " + result.ExitCode + "). Open Settings to retry.");
        }

        internal static void Run(string repositoryRoot, SkillSink sink)
        {
            string stateRoot = Path.Combine(Paths.LocalAppData, "AutodeskMcpSkillCollection");
            // Scheduled tasks, the notification-area agent and Claude remote access from earlier versions. The agent is not
            // stopped here: when an earlier version updates to this one, its agent is the process running this update.
            try
            {
                RetireTasks.Options retire = new RetireTasks.Options();
                retire.StateRoot = stateRoot;
                retire.ConnectorState = Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector");
                retire.StartupFolder = Path.Combine(Env.AppData, "Microsoft", "Windows", "Start Menu", "Programs", "Startup");
                retire.InstallRoot = repositoryRoot;
                foreach (string line in RetireTasks.Run(retire, sink)) sink.Out(line);
            }
            catch (Exception exception) { sink.Warn("Earlier background tasks could not be removed: " + exception.Message); }
            try
            {
                string settingsPath = Path.Combine(stateRoot, "settings.json");
                string installedScripts = Path.Combine(stateRoot, "scripts");
                Directory.CreateDirectory(installedScripts);
                // Each file is copied on its own: one file in use must not leave the rest out of date or missing. The
                // PowerShell helpers are the fallback where the compiled program is not installed.
                List<string> notCopied = new List<string>();
                foreach (string name in Helpers)
                {
                    string from = Path.Combine(repositoryRoot, "scripts", name);
                    if (!File.Exists(from)) continue;
                    try { File.Copy(from, Path.Combine(installedScripts, name), true); }
                    catch (Exception) { notCopied.Add(name); }
                }
                if (notCopied.Count > 0) sink.Warn("Skill helpers not refreshed (in use): " + String.Join(", ", notCopied.ToArray()) + ". They are refreshed on the next setup or restored by Skills Sync.");
                // Skills Sync settings (folders and the weekly reminder), keeping what the person chose before.
                object saved = File.Exists(settingsPath) ? SkillFiles.ReadJson(settingsPath) : null;
                WeeklyOptions options = new WeeklyOptions();
                options.Action = "Configure"; options.RepositoryRoot = repositoryRoot; options.StateRoot = stateRoot;
                if (saved != null)
                {
                    IEnumerable roots = PsJson.Value(saved, "additional_skill_roots") as IEnumerable;
                    if (roots != null && !(roots is string)) options.AdditionalSkillRoots = roots.Cast<object>().Where(r => r != null).Select(r => Convert.ToString(r, CultureInfo.InvariantCulture)).ToArray();
                    object enabled = PsJson.Value(saved, "enabled");
                    if (enabled is bool && !(bool)enabled) options.Reminder = "Off";
                }
                if (WeeklyRunner.Run(options, sink) != 0) throw new InvalidOperationException("Skills Sync settings could not be saved.");
            }
            catch (Exception exception) { sink.Warn("Skills Sync setup needs attention: " + exception.Message); }
            try
            {
                string updateState = Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector", "update-state.json");
                object saved = File.Exists(updateState) ? SkillFiles.ReadJson(updateState) : null;
                // Only the person's own choice in Settings keeps update checks off.
                if (saved != null && PsJson.Has(saved, "notifications_user_disabled") && PsJson.Truthy(PsJson.Value(saved, "notifications_user_disabled")))
                    sink.Out("Update checks remain off in Settings.");
                else EnableUpdateChecks(repositoryRoot, sink);
            }
            catch (Exception exception) { sink.Warn("Update checks need attention: " + exception.Message); }
        }
    }

    // Initialize-SkillService.ps1: the administrator's enrollment file (service address, device id, device token) becomes
    // service.json with the token encrypted for this Windows user. No GitHub sign-in is needed.
    internal static class SkillServiceEnrollment
    {
        internal static void Run(string configPath, SkillSink sink)
        {
            object data = SkillFiles.ReadJson(configPath);
            Uri uri = SkillService.ParseAddress(PsJson.Value(data, "service_url"), "The skill service must use an HTTPS URL without embedded credentials.");
            string token = PsJson.Text(PsJson.Value(data, "device_token"));
            if (!Regex.IsMatch(token, "^[A-Za-z0-9_-]{40,100}$")) throw new InvalidOperationException("Invalid device enrollment token.");
            string root = Path.Combine(Paths.LocalAppData, "AutodeskMcpSkillCollection");
            Directory.CreateDirectory(root);
            string encrypted = SkillSecrets.Protect(token);
            Dictionary<string, object> config = Json.Object("service_url", uri.AbsoluteUri.TrimEnd('/'), "device_id", PsJson.Text(PsJson.Value(data, "device_id")), "protected_token", encrypted);
            File.WriteAllText(Path.Combine(root, "service.json"), PsJsonText.Pretty(config), SkillFiles.Utf8Bom);
            sink.Out("Central skill sharing is configured for this Windows user. No GitHub sign-in is needed.");
        }
    }
}
