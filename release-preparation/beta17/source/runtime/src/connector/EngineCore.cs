using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

// The install engine: installer\Setup-BimCad.ps1 compiled into SmartConnector.exe, so setup, repair and update run no
// PowerShell. It prints the same lines the script did, because the windows read them:
//   [HH:mm:ss] <step text>          what is happening
//   [PHASE] <step>                  an install step started
//   [RESULT] <step>=ok|skipped|failed <detail>
//   [UPDATE_AVAILABLE] / [UP_TO_DATE] / [UPDATE_STATUS_UNKNOWN] / [UPDATE_INSTALLED] / [UPDATE_DEFERRED]
//   [ENROLLMENT_*]                  the team step
// and the same exit codes: 0, or 1 with the reason on stderr.
//   SmartConnector.exe engine --action <Status|Install|Update|Test|Collect|TeamStatus|CheckUpdate|EnableNotifications|
//       DisableNotifications|ConnectGitHub|UninstallAutoCadPanel> [--product All|AutoCAD|Revit] [--repository-path <folder>]
//       [--skip-repository-update] [--install-git-if-missing] [--install-claude-desktop-if-missing]
//       [--enrollment-path <file>] [--join-name <name>] [--join-email <email>] [--terms-version <version>]
//       [--ai-clients ClaudeDesktop,ClaudeCode,Codex] [--skills On|Off] [--auto-updates On|Off]
//       [--release-manifest-url <url>] [--repository-url <url>]
// The work is split over Engine*.cs: EngineCore (steps, choices, state), EngineUpdate (public release, in-place
// replacement), EngineClients (Codex, Claude Code, Claude Desktop), EngineAutodesk (AutoCAD panel, Revit add-in,
// checks), EngineTeam (enrollment), EngineBackground (earlier scheduled tasks).
namespace SmartConnector
{
    internal sealed class EngineException : Exception
    {
        internal EngineException(string message) : base(message) { }
    }

    internal sealed class EngineOptions
    {
        internal static readonly string[] Actions = { "Status", "Install", "Update", "Test", "Collect", "TeamStatus", "CheckUpdate", "EnableNotifications", "DisableNotifications", "ConnectGitHub", "UninstallAutoCadPanel" };
        internal static readonly string[] Products = { "All", "AutoCAD", "Revit" };
        internal static readonly string[] AllAiClients = { "ClaudeDesktop", "ClaudeCode", "Codex" };

        internal string Action = "Status", Product = "All";
        internal string RepositoryUrl = "https://github.com/EhabHassan007/Autodesk-MCP.git";
        internal string ReleaseManifestUrl = "https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/latest/download/latest.json";
        internal string RepositoryPath = Path.Combine(Paths.LocalAppData, "BIM-CAD-MCP");
        internal bool ProductGiven, SkipRepositoryUpdate, InstallGitIfMissing, InstallClaudeDesktopIfMissing;
        // Typed in the team join dialog, or given by the administrator's enrollment file.
        internal string EnrollmentPath = "", JoinName = "", JoinEmail = "", TermsVersion = "";
        // Choices from the setup window. Empty means: the choices saved by the last setup, else everything.
        internal string AiClients = "", Skills = "", AutoUpdates = "";
        // For the tests only: pretend these AutoCAD releases are installed (HKLM cannot be faked), and keep the trusted
        // paths in a throwaway registry tree under HKCU instead of Software\Autodesk\AutoCAD.
        internal string[] TestAutoCadReleases;
        internal string AutoCadRegistryRoot = @"Software\Autodesk\AutoCAD";

        private static readonly string[] ValueOptions = { "action", "product", "repository-url", "release-manifest-url", "repository-path", "enrollment-path", "join-name", "join-email", "terms-version", "ai-clients", "skills", "auto-updates", "test-autocad-releases", "autocad-registry-root" };
        private static readonly string[] FlagOptions = { "skip-repository-update", "install-git-if-missing", "install-claude-desktop-if-missing", "library-only" };

        private static string Choose(string parameter, string value, string[] allowed, bool allowEmpty)
        {
            if (allowEmpty && value.Length == 0) return "";
            foreach (string name in allowed) if (String.Equals(name, value, StringComparison.OrdinalIgnoreCase)) return name;
            throw new EngineException(String.Format("Cannot validate argument on parameter '{0}'. The argument \"{1}\" does not belong to the set \"{2}\" specified by the ValidateSet attribute. Supply an argument that is in the set and then try the command again.", parameter, value, String.Join(",", allowed)));
        }

        internal static EngineOptions Parse(string[] args)
        {
            EngineOptions options = new EngineOptions();
            for (int i = 0; i < args.Length; i++)
            {
                string token = args[i];
                if (!token.StartsWith("--")) throw new EngineException("Unexpected argument: " + token);
                string name = token.Substring(2), value = null;
                int equals = name.IndexOf('=');
                if (equals > 0) { value = name.Substring(equals + 1); name = name.Substring(0, equals); }
                name = name.ToLowerInvariant();
                if (FlagOptions.Contains(name))
                {
                    switch (name)
                    {
                        case "skip-repository-update": options.SkipRepositoryUpdate = true; break;
                        case "install-git-if-missing": options.InstallGitIfMissing = true; break;
                        case "install-claude-desktop-if-missing": options.InstallClaudeDesktopIfMissing = true; break;
                    }
                    continue;
                }
                if (!ValueOptions.Contains(name)) throw new EngineException("Unknown option: --" + name);
                if (value == null)
                {
                    if (i + 1 >= args.Length) throw new EngineException("Missing value for --" + name);
                    value = args[++i];
                }
                switch (name)
                {
                    case "action": options.Action = Choose("Action", value, Actions, false); break;
                    case "product": options.Product = Choose("Product", value, Products, false); options.ProductGiven = true; break;
                    case "repository-url": options.RepositoryUrl = value; break;
                    case "release-manifest-url": options.ReleaseManifestUrl = value; break;
                    case "repository-path": options.RepositoryPath = value; break;
                    case "enrollment-path": options.EnrollmentPath = value; break;
                    case "join-name": options.JoinName = value; break;
                    case "join-email": options.JoinEmail = value; break;
                    case "terms-version": options.TermsVersion = value; break;
                    case "ai-clients": options.AiClients = value; break;
                    case "skills": options.Skills = Choose("Skills", value, new[] { "On", "Off" }, true); break;
                    case "auto-updates": options.AutoUpdates = Choose("AutoUpdates", value, new[] { "On", "Off" }, true); break;
                    case "test-autocad-releases": options.TestAutoCadReleases = value.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries); break;
                    case "autocad-registry-root": options.AutoCadRegistryRoot = value; break;
                }
            }
            return options;
        }
    }

    internal sealed class InstallChoices
    {
        internal string[] AiClients = new string[0];
        internal string Product = "All";
        internal bool Skills = true;
    }

    internal sealed partial class InstallEngine
    {
        private readonly EngineOptions _o;
        private readonly TextWriter _out, _err;
        private string _currentInstallStep = "";
        private readonly List<string> _failedInstallSteps = new List<string>();
        private bool _updateDownloaded;

        private InstallEngine(EngineOptions options, TextWriter output, TextWriter error)
        {
            _o = options; _out = output; _err = error;
        }

        private static string UpdateStateDirectory { get { return Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector"); } }
        private static string UpdateStatePath { get { return Path.Combine(UpdateStateDirectory, "update-state.json"); } }
        private static string InstallChoicesPath { get { return Path.Combine(UpdateStateDirectory, "install-choices.json"); } }
        private const string UpdateTaskName = "Autodesk MCP Connector Update Alerts";

        // SmartConnector.exe engine ...
        internal static int RunCommand(string[] args)
        {
            Program.AttachConsole();
            StreamWriter output = new StreamWriter(Console.OpenStandardOutput(), EngineText.Utf8);
            output.AutoFlush = true;
            StreamWriter error = new StreamWriter(Console.OpenStandardError(), EngineText.Utf8);
            error.AutoFlush = true;
            try
            {
                EngineOptions options;
                try { options = EngineOptions.Parse(args); }
                catch (EngineException exception) { error.WriteLine(exception.Message); return 1; }
                return new InstallEngine(options, output, error).Run();
            }
            finally { output.Flush(); error.Flush(); }
        }

        // ---------- output the windows read ----------

        private static string Time { get { return DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture); } }

        // Write-Step
        private void Step(string message) { _out.WriteLine("[" + Time + "] " + message); }

        // Write-Output of a line with a time stamp (the update checks).
        private void Say(string message) { Step(message); }

        // Write-Warning, as a console writes it.
        private void Warning(string message) { _out.WriteLine("WARNING: " + message); }

        // Machine-readable progress for the setup window.
        private void Phase(string step)
        {
            _currentInstallStep = step;
            _out.WriteLine("[PHASE] " + step);
        }

        private void Result(string step, string status, string detail)
        {
            _out.WriteLine(("[RESULT] " + step + "=" + status + " " + detail).TrimEnd());
        }

        private void Result(string step, string status) { Result(step, status, ""); }

        // Runs one install step so that its failure is reported against the step that was running and the remaining
        // steps still run. Setup exits with an error at the end if any step failed.
        private void RunInstallStep(string step, Action body)
        {
            Phase(step);
            try { body(); }
            catch (Exception exception)
            {
                string failedStep = _currentInstallStep.Length > 0 ? _currentInstallStep : step;
                Step(failedStep + " failed: " + exception.Message);
                Result(failedStep, "failed", "see the setup log");
                _failedInstallSteps.Add(failedStep);
            }
        }

        // ---------- the actions ----------

        private int Run()
        {
            try
            {
                Step("Smart Connector - " + _o.Action);
                switch (_o.Action)
                {
                    case "Collect":
                        {
                            string root = GetRepository();
                            string collector = Path.Combine(root, "scripts", "collect-skills-for-review.ps1");
                            Step("Collecting local user skills for review without uploading them...");
                            InvokePowerShellScript(collector, "-RepositoryRoot", root);
                            return 0;
                        }
                    case "CheckUpdate":
                        RemoveBackgroundTasks(Paths.Root, false);
                        TestApprovedUpdate();
                        return 0;
                    case "EnableNotifications": EnableUpdateNotifications(); return 0;
                    case "DisableNotifications": DisableUpdateNotifications(); return 0;
                    case "ConnectGitHub":
                        GetPrivateRepositoryGit(_o.InstallGitIfMissing);
                        Step("GitHub connection is ready. Skill submissions use your GitHub identity automatically; no name or email commands are needed.");
                        return 0;
                    case "TeamStatus": TeamStatus(); return 0;
                    case "UninstallAutoCadPanel": UninstallAutoCadBundle(); return 0;
                    case "Status":
                    case "Test":
                        if (_o.Product == "All" || _o.Product == "AutoCAD") TestAutoCadSetup();
                        if (_o.Product == "All" || _o.Product == "Revit") TestRevitSetup();
                        TestAutodeskRegistration();
                        return 0;
                    case "Install": Install(); return 0;
                    case "Update": Update(); return 0;
                }
                return 0;
            }
            catch (Exception exception)
            {
                _err.WriteLine(exception.Message);
                return 1;
            }
        }

        private bool WantsProduct(string product) { return _o.Product == "All" || _o.Product == product; }

        private void TeamStatus()
        {
            string root;
            if (Directory.Exists(Path.Combine(_o.RepositoryPath, ".agents", "skills"))) root = Path.GetFullPath(_o.RepositoryPath);
            else root = GetRepository();
            string submitter = Path.Combine(root, "scripts", "submit-team-knowledge.ps1");
            if (!File.Exists(submitter)) throw new EngineException("Team submitter is missing: " + submitter);
            string git = FindCommand("git");
            if (git == null && _o.InstallGitIfMissing) git = InstallGitForWindows();
            if (git != null)
            {
                Step("Git is installed.");
                try
                {
                    GetPrivateRepositoryGit(false);
                    Step("Git authentication can access the private repository.");
                }
                catch (Exception exception) { Step(exception.Message); }
            }
            else Step("Git is required for automatic team collection.");
            Step("In Codex, ask: Use cad-team-knowledge-approval to enable my daily team knowledge collection.");
            Step("Codex will create the per-user daily automation only after that user asks for it.");
        }

        private void Install()
        {
            InstallChoices choices = GetInstallChoices(_o.AiClients, _o.Product, _o.ProductGiven, _o.Skills, InstallChoicesPath);
            _o.Product = choices.Product;
            Step(String.Format("Setting up: {0}; AI apps: {1}; team skills: {2}.",
                _o.Product == "All" ? "Revit and AutoCAD" : _o.Product,
                choices.AiClients.Length > 0 ? String.Join(", ", choices.AiClients) : "none",
                choices.Skills ? "yes" : "no"));
            Phase("files");
            string root = GetRepository();
            Result("files", "ok");
            try { SaveInstallChoices(choices, InstallChoicesPath); }
            catch (Exception exception) { Step("The setup choices could not be saved: " + exception.Message); }
            InstallStartMenuShortcut(root);
            // The connector files are required by every later step; each later step fails on its own.
            RunInstallStep("skills", delegate
            {
                if (!choices.Skills) { Step("Team workflow skills were not selected in setup."); Result("skills", "skipped", "not selected"); }
                else
                {
                    InstallSkills(root);
                    Result("skills", "ok");
                }
            });
            RunInstallStep("team", delegate
            {
                // An administrator's enrollment file wins; otherwise the setup window's details are used.
                try
                {
                    if (_o.JoinName.Length > 0 && _o.JoinEmail.Length > 0 && String.IsNullOrWhiteSpace(_o.EnrollmentPath)) RegisterSkillServiceDevice(root);
                    else ImportSkillServiceEnrollment(root, _o.EnrollmentPath, DefaultEnrollmentFolders());
                }
                finally
                {
                    // The setup .exe installs the TEAM join code with the other files; it never stays after setup.
                    string installedJoin = Path.Combine(root, "installer", "team-join.json");
                    if (File.Exists(installedJoin)) File.Delete(installedJoin);
                }
            });
            RunInstallStep("revit", delegate
            {
                if (WantsProduct("Revit") && TestRevit2024Installed())
                {
                    InstallRevitAddin(root);
                    Result("revit", "ok", "restart Revit to load it");
                }
                else if (WantsProduct("Revit"))
                {
                    Step("Revit 2024 was not detected, so its add-in was skipped.");
                    Result("revit", "skipped", "Revit 2024 is not installed");
                }
            });
            if (WantsProduct("AutoCAD")) RunInstallStep("autocad", delegate { InstallAutoCadBundleStep(root); });
            RunInstallStep("updates", delegate
            {
                RemoveBackgroundTasks(root, true);
                OMap updateState = ReadUpdateState();
                if (_o.AutoUpdates == "Off")
                {
                    DisableUpdateNotifications();
                    Result("updates", "skipped", "switched off in setup");
                }
                else if (_o.AutoUpdates == "On")
                {
                    EnableUpdateNotifications();
                    Result("updates", "ok");
                }
                else if (updateState.Has("notifications_user_disabled") && PsJson.Truthy(updateState.Get("notifications_user_disabled")))
                    Result("updates", "skipped", "switched off in Settings");
                else
                {
                    EnableUpdateNotifications();
                    Result("updates", "ok");
                }
            });
            RunInstallStep("codex", delegate { RegisterDetectedAiClients(root, choices.AiClients); });
            // Setup has run to the end: Smart Connector opens normally from now on (Repair is in Components).
            string pendingMarker = Path.Combine(root, "setup", "setup-pending.txt");
            if (File.Exists(pendingMarker)) File.Delete(pendingMarker);
            // Final checks only report; they never undo a completed step.
            _currentInstallStep = "";
            List<Action> checks = new List<Action>();
            if (WantsProduct("AutoCAD")) checks.Add(TestAutoCadSetup);
            if (WantsProduct("Revit")) checks.Add(TestRevitSetup);
            checks.Add(TestAutodeskRegistration);
            foreach (Action check in checks)
            {
                try { check(); }
                catch (Exception exception) { Step("Check needs attention: " + exception.Message); }
            }
            if (_failedInstallSteps.Count > 0)
                throw new EngineException("Setup finished, but these steps failed: " + String.Join(", ", _failedInstallSteps.Distinct()) + ". The other steps were completed; see the setup log.");
            Step("Setup complete. Restart Codex, Claude, and any running Revit session, then open AutoCAD or Revit.");
        }

        private void Update()
        {
            // Revit and AutoCAD keep connector files open; replacing files under them fails.
            string[] openApps = GetRunningAutodeskApps();
            if (openApps.Length > 0)
            {
                Say("[UPDATE_DEFERRED] " + String.Join(" and ", openApps) + " is open. Close it, and the update window installs the update.");
                return;
            }
            _updateDownloaded = false;
            InstallChoices choices = GetInstallChoices(_o.AiClients, _o.Product, _o.ProductGiven, _o.Skills, InstallChoicesPath);
            _o.Product = choices.Product;
            string root = GetRepository();
            ImportSkillServiceEnrollment(root, _o.EnrollmentPath, DefaultEnrollmentFolders());
            if (!_updateDownloaded)
            {
                Step("No newer release was installed. Existing client registrations were preserved. Use Install / Repair to repair connections.");
                return;
            }
            if (choices.Skills) InstallSkills(root);
            InstallStartMenuShortcut(root);
            if (WantsProduct("Revit") && TestRevit2024Installed()) InstallRevitAddin(root);
            else if (WantsProduct("Revit")) Step("Revit 2024 was not detected, so its add-in was skipped.");
            if (WantsProduct("AutoCAD")) InstallAutoCadBundleStep(root);
            RegisterDetectedAiClients(root, choices.AiClients);
            RemoveBackgroundTasks(root, true);
            string sourceFile = Path.Combine(root, ".bim-cad-source.json");
            string sha = "";
            if (File.Exists(sourceFile))
            {
                try { sha = PsJson.Text(PsJson.Value(Json.Serializer.DeserializeObject(File.ReadAllText(sourceFile)), "sha256")); }
                catch (Exception) { }
            }
            SetInstalledRelease(File.ReadAllText(Path.Combine(root, "VERSION")).Trim(), sha);
            Say("[UPDATE_INSTALLED] Smart Connector " + GetInstalledVersion() + " is installed.");
        }

        // Where an administrator's enrollment file is looked for besides --enrollment-path: beside the installer and in the
        // install root (the setup .exe copies it there).
        private static string[] DefaultEnrollmentFolders()
        {
            return new[] { Path.Combine(Paths.Root, "installer"), Paths.Root };
        }

        // ---------- install choices ----------

        // Which AI apps to connect, which Autodesk programs to set up and whether to install the team skills.
        // Values given on the command line (the setup window) win and are saved; Update and Repair reuse the saved
        // choices; with nothing saved, everything is set up as before.
        internal static InstallChoices GetInstallChoices(string aiClients, string product, bool productGiven, string skills, string path)
        {
            OMap saved = null;
            if (File.Exists(path)) { try { saved = OJson.ReadFile(path) as OMap; } catch (Exception) { saved = null; } }
            InstallChoices choices = new InstallChoices();
            if (!String.IsNullOrWhiteSpace(aiClients))
            {
                List<string> chosen = new List<string>();
                foreach (string name in Regex.Split(aiClients, "[,; ]+").Where(n => n.Length > 0))
                {
                    string match = EngineOptions.AllAiClients.FirstOrDefault(c => String.Equals(c, name, StringComparison.OrdinalIgnoreCase));
                    if (match == null) throw new EngineException("Unknown AI app: " + name + ". Use ClaudeDesktop, ClaudeCode or Codex.");
                    if (!chosen.Contains(match)) chosen.Add(match);
                }
                choices.AiClients = chosen.ToArray();
            }
            else if (saved != null && saved.Has("ai_clients"))
            {
                List<string> chosen = new List<string>();
                object value = saved.Get("ai_clients");
                IEnumerable<object> items = value is List<object> ? (IEnumerable<object>)(List<object>)value : value == null ? new object[0] : new[] { value };
                foreach (object item in items)
                {
                    string text = PsJson.Text(item);
                    if (EngineOptions.AllAiClients.Any(c => String.Equals(c, text, StringComparison.OrdinalIgnoreCase))) chosen.Add(text);
                }
                choices.AiClients = chosen.ToArray();
            }
            else choices.AiClients = (string[])EngineOptions.AllAiClients.Clone();

            string savedProduct = saved != null && saved.Has("product") ? PsJson.Text(saved.Get("product")) : "";
            if (productGiven) choices.Product = product;
            else if (EngineOptions.Products.Any(p => String.Equals(p, savedProduct, StringComparison.OrdinalIgnoreCase))) choices.Product = savedProduct;
            else choices.Product = "All";

            if (!String.IsNullOrEmpty(skills)) choices.Skills = skills == "On";
            else if (saved != null && saved.Has("skills")) choices.Skills = PsJson.Truthy(saved.Get("skills"));
            else choices.Skills = true;
            return choices;
        }

        internal static void SaveInstallChoices(InstallChoices choices, string path)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            OMap map = new OMap();
            map.Set("ai_clients", new List<object>(choices.AiClients.Cast<object>()));
            map.Set("product", choices.Product);
            map.Set("skills", choices.Skills);
            map.Set("saved_utc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
            File.WriteAllText(path, OJson.Write(map) + "\r\n", EngineText.Utf8Bom);
        }

        // ---------- update state ----------

        private OMap ReadUpdateState()
        {
            if (!File.Exists(UpdateStatePath))
            {
                OMap fresh = new OMap();
                fresh.Set("repository", _o.RepositoryUrl);
                fresh.Set("release_manifest", _o.ReleaseManifestUrl);
                fresh.Set("installed_version", "");
                fresh.Set("installed_sha256", "");
                fresh.Set("installed_commit", "");
                // Automatic updates are on by default; only an explicit choice in Settings turns them off.
                fresh.Set("notifications_enabled", true);
                fresh.Set("notifications_user_disabled", false);
                fresh.Set("last_checked_utc", "");
                return fresh;
            }
            try
            {
                OMap state = OJson.ReadFile(UpdateStatePath) as OMap;
                if (state == null) throw new FormatException();
                return state;
            }
            catch (Exception) { throw new EngineException("The connector update state is damaged: " + UpdateStatePath); }
        }

        private static void WriteUpdateState(OMap state)
        {
            Directory.CreateDirectory(UpdateStateDirectory);
            File.WriteAllText(UpdateStatePath, OJson.Write(state) + "\r\n", EngineText.Utf8Bom);
        }

        private static string Now { get { return DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture); } }

        private string GetInstalledVersion()
        {
            string versionPath = Path.Combine(_o.RepositoryPath, "VERSION");
            return File.Exists(versionPath) ? File.ReadAllText(versionPath).Trim() : "";
        }

        private void SetInstalledRelease(string version, string sha256)
        {
            OMap state = ReadUpdateState();
            state.Set("repository", _o.RepositoryUrl);
            state.Set("release_manifest", _o.ReleaseManifestUrl);
            state.Set("installed_version", version);
            state.Set("installed_sha256", sha256);
            state.Set("last_checked_utc", Now);
            WriteUpdateState(state);
        }

        private void SetInstalledRelease(string version) { SetInstalledRelease(version, ""); }

        // Update checks run when Revit, AutoCAD or the Smart Connector app opens (at most once a day); they read this
        // switch. Nothing here goes online.
        private void EnableUpdateNotifications()
        {
            OMap state = ReadUpdateState();
            state.Set("repository", _o.RepositoryUrl);
            state.Set("release_manifest", _o.ReleaseManifestUrl);
            state.Set("installed_version", GetInstalledVersion());
            state.Set("notifications_enabled", true);
            state.Set("notifications_user_disabled", false);
            WriteUpdateState(state);
            RemoveLegacyUpdateTask();
            Step("Update checks are on: Revit, AutoCAD and Smart Connector look for a new version once a day when they open, and ask before installing.");
        }

        private void DisableUpdateNotifications()
        {
            RemoveLegacyUpdateTask();
            OMap state = ReadUpdateState();
            state.Set("notifications_enabled", false);
            state.Set("notifications_user_disabled", true);
            WriteUpdateState(state);
            Step("Update checks are off. Use Check Updates to look for a new version.");
        }

        private static string[] GetRunningAutodeskApps()
        {
            List<string> apps = new List<string>();
            if (ConnectorStatus.ProcessRunning("acad")) apps.Add("AutoCAD");
            if (ConnectorStatus.ProcessRunning("Revit")) apps.Add("Revit");
            return apps.ToArray();
        }

        // ---------- commands ----------

        // Get-Command for a program, then the places the tools install themselves when PATH does not list them.
        internal static string FindCommand(string name)
        {
            string found = FindOnPath(name);
            if (found != null) return found;
            List<string> candidates = new List<string>();
            if (name == "git")
            {
                candidates.Add(Path.Combine(Env.ProgramFiles, "Git", "cmd", "git.exe"));
                candidates.Add(Path.Combine(Env.ProgramFiles, "Git", "cmd", "git.cmd"));
                candidates.Add(Path.Combine(Paths.LocalAppData, "Programs", "Git", "cmd", "git.exe"));
                candidates.Add(Path.Combine(Paths.LocalAppData, "Programs", "Git", "cmd", "git.cmd"));
                string x86 = Env.Variable("ProgramFiles(x86)");
                if (x86.Length > 0)
                {
                    candidates.Add(Path.Combine(x86, "Git", "cmd", "git.exe"));
                    candidates.Add(Path.Combine(x86, "Git", "cmd", "git.cmd"));
                }
            }
            else if (name == "codex")
            {
                candidates.Add(Path.Combine(Env.Home, ".local", "bin", "codex.exe"));
                candidates.Add(Path.Combine(Env.AppData, "npm", "codex.cmd"));
                string desktopBin = Path.Combine(Paths.LocalAppData, "OpenAI", "Codex", "bin");
                if (Directory.Exists(desktopBin))
                {
                    try
                    {
                        candidates.AddRange(new DirectoryInfo(desktopBin).GetFiles("codex.exe", SearchOption.AllDirectories).OrderByDescending(f => f.LastWriteTime).Select(f => f.FullName));
                    }
                    catch (Exception) { }
                }
            }
            else if (name == "claude")
            {
                candidates.Add(Path.Combine(Env.Home, ".local", "bin", "claude.exe"));
                candidates.Add(Path.Combine(Env.AppData, "npm", "claude.cmd"));
                candidates.Add(Path.Combine(Paths.LocalAppData, "Programs", "Claude Code", "claude.exe"));
            }
            foreach (string candidate in candidates) if (File.Exists(candidate)) return candidate;
            return null;
        }

        private static string FindOnPath(string name)
        {
            string pathExt = Env.Variable("PATHEXT");
            List<string> extensions = (pathExt.Length > 0 ? pathExt : ".COM;.EXE;.BAT;.CMD").Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries).ToList();
            // Programs without an extension are only runnable off Windows (the tests run there too).
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || Path.HasExtension(name)) extensions.Insert(0, "");
            foreach (string folder in Env.Variable("PATH").Split(new[] { Path.PathSeparator }, StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    string directory = folder.Trim().Trim('"');
                    if (directory.Length == 0) continue;
                    foreach (string extension in extensions)
                    {
                        string file = Path.Combine(directory, name + extension);
                        if (File.Exists(file)) return file;
                    }
                }
                catch (Exception) { }
            }
            return null;
        }

        private static string RequireCommand(string name)
        {
            string command = FindCommand(name);
            if (command == null) throw new EngineException(name + " is not installed or is not available in PATH.");
            return command;
        }

        private sealed class External
        {
            internal int ExitCode;
            internal List<string> Output = new List<string>();
        }

        // Invoke-External: runs a program, echoes what it prints (unless Quiet), and fails on a non-zero exit code
        // unless the caller reads the exit code itself.
        private External Invoke(string file, string[] arguments, bool allowFailure, bool quiet, IDictionary<string, string> environment)
        {
            ProcessStartInfo info = new ProcessStartInfo(file, SetupWizard.CommandLine(arguments));
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.RedirectStandardOutput = true; info.RedirectStandardError = true; info.RedirectStandardInput = true;
            info.StandardOutputEncoding = Encoding.UTF8; info.StandardErrorEncoding = Encoding.UTF8;
            // Not the install folder: no child may hold it open.
            info.WorkingDirectory = Paths.LocalAppData;
            if (environment != null) foreach (KeyValuePair<string, string> pair in environment) info.EnvironmentVariables[pair.Key] = pair.Value;
            External result = new External();
            object gate = new object();
            using (Process process = Process.Start(info))
            {
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (gate) result.Output.Add(e.Data); };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (gate) result.Output.Add(e.Data); };
                process.BeginOutputReadLine(); process.BeginErrorReadLine();
                try { process.StandardInput.Close(); } catch (Exception) { }
                process.WaitForExit();
                result.ExitCode = process.ExitCode;
            }
            if (!quiet) foreach (string line in result.Output) _out.WriteLine(line);
            if (!allowFailure && result.ExitCode != 0)
            {
                string details = String.Join("\r\n", result.Output);
                if (String.IsNullOrWhiteSpace(details)) details = "The command returned no diagnostic output.";
                string operation = String.Join(" ", arguments.Take(2));
                throw new EngineException(file + " [" + operation + "] failed with exit code " + result.ExitCode + ".\r\n" + details);
            }
            return result;
        }

        private External Invoke(string file, params string[] arguments) { return Invoke(file, arguments, false, false, null); }
        private External InvokeAllowFailure(string file, params string[] arguments) { return Invoke(file, arguments, true, false, null); }

        // powershell.exe -File <script> ...: the scripts that stay PowerShell (Skills Sync and the other skill scripts).
        private void InvokePowerShellScript(string script, params string[] arguments)
        {
            List<string> all = new List<string> { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script };
            all.AddRange(arguments);
            string shell = File.Exists(Launch.PowerShell) ? Launch.PowerShell : "powershell.exe";
            Invoke(shell, all.ToArray(), false, false, null);
        }

        private string InstallGitForWindows()
        {
            string git = FindCommand("git");
            if (git != null) return git;
            string winget = FindCommand("winget");
            if (winget == null)
                throw new EngineException("Git is required for optional team knowledge submission, and Windows Package Manager was not found. Install Git for Windows from https://git-scm.com/download/win, then reopen the connector.");
            Step("Installing Git for Windows for optional team knowledge submission...");
            External installed = Invoke(winget, new[] { "install", "--id", "Git.Git", "--exact", "--source", "winget", "--silent", "--accept-package-agreements", "--accept-source-agreements" }, true, false, null);
            git = FindCommand("git");
            if (git == null)
                throw new EngineException("Git installation did not finish. Install Git for Windows and reopen the connector.\r\n" + String.Join("\r\n", installed.Output));
            Step("Git for Windows is installed.");
            return git;
        }

        private string GetPrivateRepositoryGit(bool allowInstall)
        {
            string git = FindCommand("git");
            if (git == null && allowInstall) git = InstallGitForWindows();
            if (git == null) throw new EngineException("Git is required only for optional team knowledge submission. Allow the connector to install Git or install Git for Windows, then retry.");
            Step("Checking access to the private GitHub repository...");
            Step("If GitHub opens, sign in with an account that can access EhabHassan007/Autodesk-MCP.");
            Dictionary<string, string> environment = new Dictionary<string, string>
            {
                { "GCM_INTERACTIVE", "always" }, { "GCM_PROVIDER", "github" }, { "GCM_GITHUB_AUTHMODES", "browser,device" }
            };
            External access = Invoke(git, new[] { "ls-remote", _o.RepositoryUrl, "refs/heads/main" }, true, false, environment);
            if (access.ExitCode != 0)
                throw new EngineException("GitHub sign-in or private repository access failed. Sign in as an authorized account and retry.\r\n" + String.Join("\r\n", access.Output));
            bool found = access.Output.Any(line => Regex.IsMatch(line.Trim(), @"^[0-9a-fA-F]{40}\s+refs/heads/main$"));
            if (!found) throw new EngineException("GitHub authentication succeeded, but the approved main branch was not returned.");
            Step("Private GitHub repository access passed.");
            return git;
        }

        // Install-Skills: the skill scripts stay PowerShell (they belong to Skills Sync).
        private void InstallSkills(string root)
        {
            string syncScript = Path.Combine(root, "scripts", "sync-codex-skills.ps1");
            if (!File.Exists(syncScript)) throw new EngineException("Skill installer is missing: " + syncScript);
            Step("Installing all saved skills for Codex...");
            InvokePowerShellScript(syncScript, "-Action", "Install");
            string claudeSkills = Path.Combine(Env.Home, ".claude", "skills");
            Step("Installing the same saved skills for Claude Code...");
            InvokePowerShellScript(syncScript, "-Action", "Install", "-Destination", claudeSkills);
        }
    }
}
