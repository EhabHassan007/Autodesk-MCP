using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

// Smart Connector actions behind the app's and the AutoCAD panel's buttons: the C# port of installer\ConnectorActions.ps1.
// One hidden PowerShell step (Skills Sync, the update check or the status check, all still PowerShell) runs while a
// branded window shows progress, then the window shows the result.
//   SmartConnector.exe action --action SkillsSync|CheckUpdates|Status
// The update window (ConnectorActions.ps1 -Action InstallUpdate) stays PowerShell: it replaces the install folder,
// which a running bin\SmartConnector.exe would hold open (and Setup-BimCad stops every SmartConnector.exe there).
namespace SmartConnector
{
    // Starting the installed scripts and programs. Every launch uses a known installed path and runs from
    // %LOCALAPPDATA%, so no child holds the install folder open.
    internal static class Launch
    {
        internal static string PowerShell { get { return Path.Combine(Env.Windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"); } }
        internal static string Self { get { return System.Reflection.Assembly.GetExecutingAssembly().Location; } }
        internal static string StateRoot { get { return Path.Combine(Paths.LocalAppData, "AutodeskMcpSkillCollection"); } }
        internal static string UpdateState { get { return Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector", "update-state.json"); } }

        // The scripts quote paths as '"{0}"', without escaping; install paths never contain quotes.
        internal static string Quote(string value) { return "\"" + value + "\""; }

        // Scripts copied to the state folder keep working while an update replaces the install folder.
        internal static string ConnectorScript(string name)
        {
            string stateCopy = Path.Combine(StateRoot, "scripts", name);
            if (File.Exists(stateCopy)) return stateCopy;
            return Path.Combine(Paths.Root, "scripts", name);
        }

        internal static string InstallerScript(string name) { return Path.Combine(Paths.Root, "installer", name); }

        // The compiled program of this install (<install root>\bin\SmartConnector.exe). Skills Sync runs as its `skills`
        // command; a copy taken from the repository has no program, and the PowerShell scripts do the same work there.
        internal static string InstalledProgram { get { return Path.Combine(Paths.Root, "bin", "SmartConnector.exe"); } }

        // Start-Process ... -WindowStyle Hidden: no console window.
        internal static Process Hidden(string file, string arguments)
        {
            ProcessStartInfo info = new ProcessStartInfo(file, arguments);
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.WorkingDirectory = Paths.LocalAppData;
            return Process.Start(info);
        }

        // Start-Process ... -WindowStyle Hidden -Wait -PassThru: the exit code.
        internal static int HiddenWait(string file, string arguments)
        {
            using (Process process = Hidden(file, arguments))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }

        // A hidden step whose output is read: stdout in the given encoding, stderr as the child console writes it.
        internal static Process Redirected(string file, string arguments, Encoding output)
        {
            ProcessStartInfo info = new ProcessStartInfo(file, arguments);
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.RedirectStandardOutput = true; info.RedirectStandardError = true;
            info.StandardOutputEncoding = output ?? ConsoleEncoding;
            info.StandardErrorEncoding = ConsoleEncoding;
            info.WorkingDirectory = Paths.LocalAppData;
            return Process.Start(info);
        }

        [DllImport("kernel32.dll")]
        private static extern uint GetOEMCP();

        // A hidden PowerShell writes redirected output in its console's OEM code page. The PowerShell windows read it
        // with their own console's encoding; this program has no console, so it names that code page itself.
        internal static Encoding ConsoleEncoding
        {
            get
            {
                try { return Encoding.GetEncoding((int)GetOEMCP()); }
                catch (Exception) { return Encoding.GetEncoding(System.Globalization.CultureInfo.CurrentCulture.TextInfo.OEMCodePage); }
            }
        }

        // Start-HiddenScript in ConnectorActions.ps1.
        internal static void HiddenScript(string script, string arguments)
        {
            Hidden(PowerShell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " + Quote(script) + " " + arguments).Dispose();
        }

        // The update window (ConnectorActions.ps1 -Action InstallUpdate) waits until Revit and AutoCAD are closed, then installs and shows the result.
        internal static void UpdateWindow()
        {
            HiddenScript(InstallerScript("ConnectorActions.ps1"), "-Action InstallUpdate -RepositoryPath " + Quote(Paths.Root));
        }

        // Another window of this program, as its own process (the PowerShell windows start each other the same way).
        internal static void Program(string arguments)
        {
            ProcessStartInfo info = new ProcessStartInfo(Self, arguments);
            info.UseShellExecute = false;
            info.WorkingDirectory = Paths.LocalAppData;
            Process.Start(info).Dispose();
        }

        // explorer.exe or notepad.exe from the Windows folder, with one quoted path.
        internal static void Open(string program, string path)
        {
            string file = program == "notepad.exe" ? Path.Combine(Env.Windows, "System32", program) : Path.Combine(Env.Windows, program);
            ProcessStartInfo info = new ProcessStartInfo(file, Quote(path));
            info.UseShellExecute = false;
            Process.Start(info).Dispose();
        }
    }

    internal sealed class Outcome
    {
        internal string State = "", Kind = "", Title = "", Body = "";
        internal bool UserOff;
        internal Outcome(string kind, string title, string body) { Kind = kind; Title = title; Body = body; }
    }

    internal static class ConnectorActions
    {
        // Result shown after Skills Sync; Kind is Good, Bad or Accent (the brand colour names).
        internal static Outcome SkillsSync(string output, string resultPath = null)
        {
            if ((output ?? "").IndexOf("A collection run is already active.", StringComparison.OrdinalIgnoreCase) >= 0)
                return new Outcome("Accent", "Skills Sync is already running", "A sync started earlier is still working in the background. Its result shows under Workflow skills in Smart Connector.");
            object result = PsJson.Read(resultPath ?? Path.Combine(Launch.StateRoot, "last-result.json"));
            string status = PsJson.Text(PsJson.Value(result, "sync_status"));
            string reason = PsJson.Text(PsJson.Value(result, "sync_reason"));
            bool ok = String.Equals(status, "ok", StringComparison.OrdinalIgnoreCase);
            if (ok || String.Equals(status, "partial", StringComparison.OrdinalIgnoreCase))
            {
                Func<string, int> n = key => PsJson.Int(PsJson.Value(result, key));
                Func<int, string> plural = count => count == 1 ? "" : "s";
                int submitted = n("sync_submitted"), added = n("sync_added"), updated = n("sync_updated"), preserved = n("sync_preserved");
                string body = "Sent for review:  " + submitted + " saved skill" + plural(submitted) + "\n" +
                    "Downloaded:  " + added + " new and " + updated + " updated approved AutoCAD skill" + plural(added + updated) + "\n" +
                    (preserved > 0 ? "Kept your local edits:  " + preserved + " skill" + plural(preserved) + "\n" : "") +
                    "Approved AutoCAD skills available:  " + n("sync_approved_total") +
                    (!ok ? "\n\n" + reason : "\n\nRestart Codex or Claude to see new skills.");
                return new Outcome(ok ? "Good" : "Bad", ok ? "Skills are in sync" : "Skills downloaded, but not sent", body);
            }
            return new Outcome("Bad", "Skills Sync didn't finish", String.IsNullOrWhiteSpace(reason) ? "Check the internet connection and try again. Details are in the weekly skill log." : reason);
        }

        // State is Available, Current or Unknown; drives which buttons Check Updates offers.
        internal static Outcome CheckUpdates(string output, string statePath = null)
        {
            object state = PsJson.Read(statePath ?? Launch.UpdateState);
            string installed = PsJson.Text(PsJson.Value(state, "installed_version"));
            string available = PsJson.Text(PsJson.Value(state, "available_version"));
            bool userOff = PsJson.Truthy(PsJson.Value(state, "notifications_user_disabled"));
            output = output ?? "";
            Outcome outcome;
            if (output.Contains("[UPDATE_AVAILABLE]"))
            {
                outcome = new Outcome("Accent", "Version " + available + " is ready",
                    "You have version " + installed + ". The update installs when AutoCAD and Revit are closed and takes about a minute. Update now opens the update window: save your work and close them, and it installs straight after.");
                outcome.State = "Available";
            }
            else if (output.Contains("[UP_TO_DATE]"))
            {
                outcome = new Outcome("Good", "You're up to date", "Smart Connector " + installed + " is the latest approved version.");
                outcome.State = "Current";
            }
            else
            {
                outcome = new Outcome("Bad", "Couldn't check right now", "The update service could not be reached. Check the internet connection and try again later. Your connector keeps working.");
                outcome.State = "Unknown";
            }
            outcome.UserOff = userOff;
            return outcome;
        }

        // Turns Setup-BimCad -Action Status output into one line per check.
        internal static Outcome ConnectionStatus(string output)
        {
            output = output ?? "";
            List<string> lines = new List<string>();
            foreach (string line in Regex.Split(output, "\r?\n"))
            {
                // Only the installer's own timestamped findings; the raw `codex mcp get` output it echoes is left out.
                Match match = Regex.Match(line, @"^\[\d{2}:\d{2}:\d{2}\]\s*(.+)$", RegexOptions.IgnoreCase);
                if (!match.Success) continue;
                string text = match.Groups[1].Value.Trim();
                if (text.StartsWith("Revit", StringComparison.OrdinalIgnoreCase) || text.StartsWith("Smart Connector - ", StringComparison.OrdinalIgnoreCase)) continue;   // the installer's own heading
                bool good = Regex.IsMatch(text, "passed|has the Smart Connector registration|installation detected|is running at", RegexOptions.IgnoreCase);
                lines.Add((good ? "\u2713" : "\u2022") + "  " + text);
            }
            string body = String.Join("\n", lines);
            if (Regex.IsMatch(output, "Live AutoCAD connection passed", RegexOptions.IgnoreCase)) return new Outcome("Good", "AutoCAD is connected", body);
            if (Regex.IsMatch(output, "AutoCAD is running, but no drawing is open", RegexOptions.IgnoreCase)) return new Outcome("Accent", "Open a drawing to connect", body);
            return new Outcome("Bad", "AutoCAD is not reachable yet", body);
        }

        // For action --outcome <name>: the outcome of the tool output on stdin, as JSON (compared with ConnectorActions.ps1 by the tests).
        internal static string Describe(string name, string output)
        {
            Outcome o = name == "SkillsSync" ? SkillsSync(output) : name == "CheckUpdates" ? CheckUpdates(output) : ConnectionStatus(output);
            return Json.Ascii(Json.Object("State", o.State, "Kind", o.Kind, "Title", o.Title, "Body", o.Body, "UserOff", o.UserOff));
        }
    }

    // The branded progress-and-result window of one action (Show-ConnectorAction).
    internal sealed class ActionWindow
    {
        internal static readonly string[] Names = { "SkillsSync", "CheckUpdates", "Status" };

        private readonly string _name;
        private readonly Form _form;
        private readonly Label _title, _body;
        private readonly ProgressBar _progress = new ProgressBar();
        private readonly CheckBox _option = new CheckBox();
        private readonly FlowLayoutPanel _buttons = new FlowLayoutPanel();
        private readonly Timer _timer = new Timer();
        private Process _process;
        private Task<string> _output;
        private DateTime _started = DateTime.UtcNow;
        private int _backgroundAfter;
        private bool _userOff;

        internal ActionWindow(string name)
        {
            _name = name;
            string caption = name == "SkillsSync" ? "Skills Sync" : name == "CheckUpdates" ? "Check Updates" : "Connection Status";
            int height = name == "Status" ? 460 : 330;
            _form = Brand.NewForm(Brand.Name, 520, height);
            Brand.AddHeader(_form, caption, Brand.Name, 76);
            _title = Brand.NewLabel("", 26, 100, 470, 12, false, true);
            _body = Brand.NewLabel("", 26, 134, 470);
            // Drawing names can contain '&' ("Location & Details.dwg"); show it rather than treat it as a shortcut key.
            _title.UseMnemonic = false; _body.UseMnemonic = false;
            _progress.Style = ProgressBarStyle.Marquee; _progress.MarqueeAnimationSpeed = 30;
            _progress.Bounds = new Rectangle(26, height - 100, 468, 8);
            _option.AutoSize = true; _option.Location = new Point(26, height - 92); _option.Visible = false;
            _buttons.FlowDirection = FlowDirection.RightToLeft;
            _buttons.Bounds = new Rectangle(0, height - 56, 508, 50);
            // Bottom-anchored, so they follow when the window grows to fit a long result.
            foreach (Control control in new Control[] { _progress, _option, _buttons }) control.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
            _form.Controls.AddRange(new Control[] { _title, _body, _progress, _option, _buttons });
            _timer.Interval = 250;
            _timer.Tick += delegate { Tick(); };
            _form.Shown += delegate { Start(); };
        }

        internal void ShowResult(Outcome outcome)
        {
            _title.Text = outcome.Title; _title.ForeColor = Brand.ColorOf(outcome.Kind); _body.Text = outcome.Body; _progress.Visible = false;
            // Grow (never shrink) so the result and the buttons below it stay visible; measured in scaled pixels.
            int needed = _body.Bottom + 12 + (_form.ClientSize.Height - _progress.Top);
            int limit = (int)(Screen.FromControl(_form).WorkingArea.Height * 0.9);
            if (needed > _form.ClientSize.Height) _form.ClientSize = new Size(_form.ClientSize.Width, Math.Min(needed, limit));
        }

        internal void AddButton(string text, bool primary, Action onClick)
        {
            Button button = Brand.NewButton(text, primary);
            button.Margin = new Padding(0, 4, 14, 4);
            button.Click += delegate { onClick(); };
            _buttons.Controls.Add(button);
            if (primary) _form.AcceptButton = button;
        }

        private void Run(string heading, string text, string script, string arguments)
        {
            _title.Text = heading; _body.Text = text;
            _process = Launch.Redirected(Launch.PowerShell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Launch.Quote(script) + " " + arguments, null);
            _output = _process.StandardOutput.ReadToEndAsync();
            // Read so the step never blocks on a full error pipe; the windows show only the output.
            _process.StandardError.ReadToEndAsync();
            _started = DateTime.UtcNow;
            _timer.Start();
        }

        // The same step as Run, started as the installed program: its output is UTF-8.
        private void RunProgram(string heading, string text, string program, string arguments)
        {
            _title.Text = heading; _body.Text = text;
            _process = Launch.Redirected(program, arguments, new UTF8Encoding(false));
            _output = _process.StandardOutput.ReadToEndAsync();
            _process.StandardError.ReadToEndAsync();
            _started = DateTime.UtcNow;
            _timer.Start();
        }

        private void Start()
        {
            try
            {
                switch (_name)
                {
                    case "SkillsSync":
                        // After 15 s the window can be closed; the step continues and its result shows in the Smart Connector app.
                        _backgroundAfter = 15;
                        // From AutoCAD, only approved AutoCAD skills are downloaded; saved skills of any kind are still sent.
                        if (File.Exists(Launch.InstalledProgram))
                            RunProgram("Syncing skills...", "Sending your saved skills for review and downloading the latest approved AutoCAD skills.",
                                Launch.InstalledProgram, "skills sync --action Sync --product AutoCAD --state-root " + Launch.Quote(Launch.StateRoot));
                        else
                            Run("Syncing skills...", "Sending your saved skills for review and downloading the latest approved AutoCAD skills.",
                                Launch.ConnectorScript("weekly-skill-collection.ps1"), "-Action Sync -Product AutoCAD -StateRoot " + Launch.Quote(Launch.StateRoot));
                        break;
                    case "CheckUpdates":
                        Run("Checking for updates...", "Looking for a newer approved version of Smart Connector.",
                            Launch.InstallerScript("Setup-BimCad.ps1"), "-Action CheckUpdate -RepositoryPath " + Launch.Quote(Paths.Root));
                        break;
                    case "Status":
                        Run("Checking the connection...", "Looking for AutoCAD, Codex and Claude.",
                            Launch.InstallerScript("Setup-BimCad.ps1"), "-Action Status -Product AutoCAD -RepositoryPath " + Launch.Quote(Paths.Root));
                        break;
                }
            }
            catch (Exception exception)
            {
                ShowResult(new Outcome("Bad", "Something went wrong", exception.Message));
                AddButton("Close", true, _form.Close);
            }
        }

        private void Tick()
        {
            if (_process == null) return;
            if (!_process.HasExited || !_output.IsCompleted)
            {
                if (_backgroundAfter > 0 && (DateTime.UtcNow - _started).TotalSeconds >= _backgroundAfter)
                {
                    // Leave the step running; only this window stops watching it.
                    _timer.Stop();
                    ShowResult(new Outcome("Accent", "Syncing in the background", "Skills Sync is still working. You can close this window and keep working; the result shows under Workflow skills in Smart Connector."));
                    AddButton("Close", true, _form.Close);
                }
                return;
            }
            _timer.Stop();
            _progress.Visible = false;
            string output = _output.Result;
            _process.Dispose(); _process = null;
            Finish(output);
        }

        internal void Finish(string output)
        {
            switch (_name)
            {
                case "SkillsSync":
                    ShowResult(ConnectorActions.SkillsSync(output)); AddButton("Close", true, _form.Close);
                    break;
                case "CheckUpdates":
                    Outcome outcome = ConnectorActions.CheckUpdates(output);
                    ShowResult(outcome);
                    if (outcome.State == "Available")
                    {
                        AddButton("Later", false, _form.Close);
                        AddButton("Update now", true, delegate { Launch.UpdateWindow(); _form.Close(); });
                    }
                    else if (outcome.State == "Current")
                    {
                        _option.Text = "Check for updates when Revit or AutoCAD opens (recommended)";
                        _userOff = outcome.UserOff;
                        _option.Checked = !_userOff; _option.Visible = true;
                        AddButton("Close", true, delegate
                        {
                            if (_option.Checked == _userOff)
                                Launch.HiddenScript(Launch.InstallerScript("Setup-BimCad.ps1"), (_option.Checked ? "-Action EnableNotifications" : "-Action DisableNotifications") + " -RepositoryPath " + Launch.Quote(Paths.Root));
                            _form.Close();
                        });
                    }
                    else AddButton("Close", true, _form.Close);
                    break;
                default:
                    ShowResult(ConnectorActions.ConnectionStatus(output)); AddButton("Close", true, _form.Close);
                    break;
            }
        }

        internal void ShowDialog()
        {
            _form.TopMost = true;
            _form.ShowDialog();
            _timer.Stop();
            // A step still running (Skills Sync in the background) keeps writing to this process's pipes; wait for it
            // here, hidden, so it is never cut off when the window closes.
            if (_process != null && !_process.HasExited) _process.WaitForExit();
            _form.Dispose();
        }

        internal static int Run(string name, bool smokeTest)
        {
            if (smokeTest)
            {
                // Build each window and show each kind of result, without running anything.
                foreach (string each in Names)
                {
                    ActionWindow window = new ActionWindow(each);
                    window.Finish("");
                    window.ShowResult(new Outcome("Accent", "Syncing in the background", "Skills Sync is still working."));
                    window._form.Dispose();
                }
                return 0;
            }
            if (!Names.Contains(name)) { MessageBox.Show("Unknown Smart Connector action: " + name, Brand.Name); return 2; }
            new ActionWindow(name).ShowDialog();
            return 0;
        }
    }

    // Smart Connector settings (installer\Settings.ps1): one switch for update checks, plus version information.
    //   SmartConnector.exe settings
    internal static class SettingsWindow
    {
        internal static int Run(bool smokeTest)
        {
            SettingsState current = SettingsState.Read();
            Form form = Brand.NewForm(Brand.Name, 480, 300);
            form.Text = "Smart Connector settings";
            Brand.AddHeader(form, "Settings", "Smart Connector", 76);

            CheckBox auto = new CheckBox();
            auto.Text = "Check for updates when Revit or AutoCAD opens (recommended)";
            auto.Font = Brand.Semibold(10.5f);
            auto.AutoSize = true; auto.Location = new Point(26, 100);
            auto.Checked = current.AutoUpdate;
            form.Controls.Add(auto);
            form.Controls.Add(Brand.NewLabel("Once a day, opening Revit, AutoCAD or Smart Connector looks for a new version and asks before installing it. When this is off, use Check Updates in Revit or AutoCAD.", 46, 128, 400, 9, true));

            string when = "";
            if (current.LastChecked.Length > 0) { try { when = DateTime.Parse(current.LastChecked).ToLocalTime().ToString("g"); } catch (Exception) { } }
            string info = "Installed version: " + (current.Installed.Length > 0 ? current.Installed : "unknown");
            if (current.Available.Length > 0) info += "    Update ready: " + current.Available;
            if (when.Length > 0) info += "\r\nLast checked: " + when;
            form.Controls.Add(Brand.NewLabel(info, 26, 196, 420, 9));

            Button save = Brand.NewButton("Save", true, 110); save.Location = new Point(226, 248);
            Button close = Brand.NewButton("Cancel", false, 110); close.Location = new Point(346, 248);
            close.DialogResult = DialogResult.Cancel;
            form.Controls.AddRange(new Control[] { save, close }); form.AcceptButton = save; form.CancelButton = close;
            save.Click += delegate
            {
                if (auto.Checked != current.AutoUpdate)
                {
                    string action = auto.Checked ? "EnableNotifications" : "DisableNotifications";
                    int code = Launch.HiddenWait(Launch.PowerShell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Launch.Quote(Launch.InstallerScript("Setup-BimCad.ps1")) + " -Action " + action + " -RepositoryPath " + Launch.Quote(Paths.Root));
                    if (code != 0)
                    {
                        MessageBox.Show(form, "The setting could not be saved. Try again, or contact your administrator.", "Smart Connector", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                }
                form.DialogResult = DialogResult.OK; form.Close();
            };
            if (smokeTest) { form.Dispose(); return 0; }
            form.TopMost = true;
            form.ShowDialog();
            form.Dispose();
            return 0;
        }
    }
}
