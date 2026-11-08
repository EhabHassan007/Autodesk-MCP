using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

// Smart Connector setup window: Welcome (with the terms), System check, Choose apps, AI connections, Install (live
// steps) and Finish, with a step rail on the left. The C# port of installer\SetupWizard.ps1, TeamJoinDialog.ps1 and
// the -Install path of Support\Install-Autodesk-MCP-Connector.ps1. The installing itself is still
// install engine (SmartConnector.exe engine, or installer\Setup-BimCad.ps1 when the program is not installed), started
// with the same arguments; its [PHASE]/[RESULT] lines drive the step list.
//   SmartConnector.exe setup [--smoke-test]
namespace SmartConnector
{
    // Shared by the setup window and (in PowerShell) BIM-CAD-Setup.ps1.
    internal static class TeamJoin
    {
        internal const string Notice = "Your name, email, PC name, Windows user, IP address and which connector skills/tools you use are reported to the administrator.";

        internal static bool ValidName(string name)
        {
            string value = (name ?? "").Trim();
            // Quotes and backslashes are refused because the values are passed on to Setup-BimCad.ps1 as
            // command-line arguments; < and > because the service rejects them.
            return value.Length >= 1 && value.Length <= 80 && !Regex.IsMatch(value, "[\"\\\\<>\r\n\t]");
        }

        internal static bool ValidEmail(string email)
        {
            string value = (email ?? "").Trim();
            return value.Length <= 254 && Regex.IsMatch(value, "^[^@\\s\"]+@[^@\\s\"]+\\.[^@\\s\"]+$");
        }

        // The team skill service the dashboard reads; the same address the TEAM build writes into team-join.json.
        internal const string ServiceUrl = "https://autodesk-skill-service.autodesk-skills-ehabhassan007.workers.dev";

        // Offered on every PC that has not joined yet. The join code comes from a TEAM build's installer\team-join.json
        // or, in the normal setup, is typed by the person (the administrator hands it out); no secret is in the setup file.
        internal static bool Required(string payloadInstaller)
        {
            return !File.Exists(Path.Combine(Paths.LocalAppData, "AutodeskMcpSkillCollection", "service.json"));
        }

        internal static bool Bundled(string payloadInstaller)
        {
            return File.Exists(Path.Combine(payloadInstaller, "team-join.json"));
        }

        // The service checks the code; this only refuses what cannot be one (the service's codes are 32+ characters).
        internal static bool ValidCode(string code)
        {
            string value = (code ?? "").Trim();
            return value.Length >= 32 && value.Length <= 256 && !Regex.IsMatch(value, "\\s");
        }

        // Writes installer\team-join.json for the install engine's team step, which deletes it when the step ends.
        internal static void WriteJoinFile(string code)
        {
            string directory = Path.Combine(Paths.Root, "installer");
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, "team-join.json"),
                Json.Serializer.Serialize(Json.Object("service_url", ServiceUrl, "join_code", code.Trim())), new UTF8Encoding(false));
        }

        internal static void DeleteJoinFile()
        {
            try { string path = Path.Combine(Paths.Root, "installer", "team-join.json"); if (File.Exists(path)) File.Delete(path); }
            catch (Exception) { }
        }

        // Show-TeamJoinDialog: name and email, or null when skipped.
        internal static string[] ShowDialog(IWin32Window owner, bool smokeTest = false)
        {
            Form dialog = new Form();
            dialog.Text = "Join the team skill service";
            dialog.StartPosition = owner != null ? FormStartPosition.CenterParent : FormStartPosition.CenterScreen;
            dialog.TopMost = owner == null;
            dialog.ClientSize = new Size(560, 300);
            dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
            dialog.MaximizeBox = false;
            dialog.MinimizeBox = false;
            dialog.Font = new Font("Segoe UI", 10);

            Label nameLabel = new Label(); nameLabel.Text = "Your name"; nameLabel.AutoSize = true; nameLabel.Location = new Point(20, 20);
            dialog.Controls.Add(nameLabel);
            TextBox name = new TextBox(); name.Location = new Point(20, 46); name.Size = new Size(520, 28); name.MaxLength = 80;
            dialog.Controls.Add(name);
            Label emailLabel = new Label(); emailLabel.Text = "Email"; emailLabel.AutoSize = true; emailLabel.Location = new Point(20, 86);
            dialog.Controls.Add(emailLabel);
            TextBox email = new TextBox(); email.Location = new Point(20, 112); email.Size = new Size(520, 28); email.MaxLength = 254;
            dialog.Controls.Add(email);
            CheckBox consent = new CheckBox();
            consent.Text = "I understand. " + Notice;
            consent.Location = new Point(20, 156); consent.Size = new Size(520, 66);
            consent.CheckAlign = ContentAlignment.TopLeft; consent.TextAlign = ContentAlignment.TopLeft;
            dialog.Controls.Add(consent);
            Button ok = new Button(); ok.Text = "Install"; ok.Location = new Point(330, 246); ok.Size = new Size(100, 32);
            ok.DialogResult = DialogResult.OK; ok.Enabled = false;
            dialog.Controls.Add(ok);
            Button cancel = new Button(); cancel.Text = "Skip"; cancel.Location = new Point(440, 246); cancel.Size = new Size(100, 32);
            cancel.DialogResult = DialogResult.Cancel;
            dialog.Controls.Add(cancel);
            dialog.AcceptButton = ok; dialog.CancelButton = cancel;

            EventHandler validate = delegate { ok.Enabled = consent.Checked && ValidName(name.Text) && ValidEmail(email.Text); };
            name.TextChanged += validate; email.TextChanged += validate; consent.CheckedChanged += validate;
            try
            {
                if (smokeTest) return null;
                DialogResult answer = owner != null ? dialog.ShowDialog(owner) : dialog.ShowDialog();
                if (answer != DialogResult.OK || !ok.Enabled) return null;
                return new[] { name.Text.Trim(), email.Text.Trim() };
            }
            finally { dialog.Dispose(); }
        }
    }

    // What this computer has, for the System check and the defaults of Choose apps. Files, registry and
    // process list only, so the page opens at once.
    internal sealed class SystemCheck
    {
        internal bool Windows64, NetOk, Revit2024, RevitRunning, ClaudeDesktop, ClaudeCode, Codex, CodexCli, ChatGptDesktop;
        internal int[] RevitOther = new int[0];
        internal string[] AutoCad = new string[0];

        private static readonly Dictionary<string, string> AutoCadNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "R23.0", "2019" }, { "R23.1", "2020" }, { "R24.0", "2021" }, { "R24.1", "2022" }, { "R24.2", "2023" }, { "R24.3", "2024" }, { "R25.0", "2025" }, { "R25.1", "2026" }, { "R26.0", "2027" }
        };

        internal static SystemCheck Take()
        {
            List<int> years = new List<int>();
            try
            {
                string autodesk = Path.Combine(Env.ProgramFiles, "Autodesk");
                if (Directory.Exists(autodesk))
                    foreach (string folder in Directory.GetDirectories(autodesk, "Revit 20*"))
                    {
                        Match match = Regex.Match(folder, @"Revit (20\d\d)$", RegexOptions.IgnoreCase);
                        if (match.Success && File.Exists(Path.Combine(folder, "RevitAPI.dll"))) years.Add(Int32.Parse(match.Groups[1].Value));
                    }
            }
            catch (Exception) { }
            years = years.Distinct().OrderBy(year => year).ToList();
            int release = 0;
            try
            {
                using (RegistryKey key = ConnectorStatus.OpenMachineKey(@"SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"))
                    if (key != null) release = Convert.ToInt32(key.GetValue("Release", 0));
            }
            catch (Exception) { }
            return new SystemCheck
            {
                Windows64 = Environment.Is64BitOperatingSystem,
                NetOk = release >= 528040,
                Revit2024 = years.Contains(2024),
                RevitOther = years.Where(year => year != 2024).ToArray(),
                RevitRunning = ConnectorStatus.ProcessRunning("Revit"),
                AutoCad = ConnectorStatus.AutoCadReleasesInstalled().Select(name => AutoCadNames.ContainsKey(name) ? AutoCadNames[name] : name).ToArray(),
                ClaudeDesktop = ConnectorStatus.ClaudeDesktopInstalled(),
                ClaudeCode = ConnectorStatus.CommandOnPath("claude"),
                CodexCli = ConnectorStatus.CommandOnPath("codex"),
                ChatGptDesktop = ConnectorStatus.ChatGptDesktopInstalled(),
                Codex = ConnectorStatus.CommandOnPath("codex") || ConnectorStatus.ChatGptDesktopInstalled()
            };
        }
    }

    internal sealed class WizardResult
    {
        internal string Result = "cancelled";
        internal int? ExitCode;
        internal bool Joined;
        internal int Pages, Steps;
    }

    internal sealed class SetupWizard
    {
        private static readonly string[][] WizardSteps =
        {
            new[] { "files", "Install connector files" },
            new[] { "skills", "Install workflow skills for Codex and Claude" },
            new[] { "revit", "Revit 2024 add-in" },
            new[] { "autocad", "AutoCAD Add-ins panel" },
            new[] { "codex", "Connect Codex / ChatGPT Desktop" },
            new[] { "claude_desktop", "Connect Claude Desktop" },
            new[] { "claude_code", "Connect Claude Code" },
            new[] { "team", "Join the team skill service" },
            new[] { "updates", "Update checks" }
        };

        internal static string TermsVersion(string path)
        {
            foreach (string line in File.ReadLines(path).Take(5))
            {
                Match match = Regex.Match(line, @"^Version\s+(\S+)", RegexOptions.IgnoreCase);
                if (match.Success) return match.Groups[1].Value;
            }
            return "unversioned";
        }

        internal static void SaveTermsAcceptance(string version)
        {
            string directory = Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector");
            Directory.CreateDirectory(directory);
            string json = Json.Serializer.Serialize(Json.Object("terms_version", version, "accepted_utc", DateTime.UtcNow.ToString("o"), "windows_user", Env.Variable("USERNAME")));
            // Set-Content -Encoding UTF8 in Windows PowerShell writes a byte-order mark; kept for the same file.
            File.WriteAllText(Path.Combine(directory, "terms-accepted.json"), json + "\r\n", new UTF8Encoding(true));
        }

        // Reads one line of Setup-BimCad output. Explicit markers drive the step list:
        //   [PHASE] <step>              the step is now running
        //   [RESULT] <step>=<status> ...  ok | skipped | failed
        //   [ENROLLMENT_*] tags         map onto the team step
        internal static string[] ParseLine(string line)
        {
            Match m = Regex.Match(line, @"\[PHASE\]\s+([a-z_]+)", RegexOptions.IgnoreCase);
            if (m.Success) return new[] { m.Groups[1].Value, "running", "" };
            m = Regex.Match(line, @"\[RESULT\]\s+([a-z_]+)=(ok|skipped|failed)\s*(.*)$", RegexOptions.IgnoreCase);
            if (m.Success) return new[] { m.Groups[1].Value, m.Groups[2].Value, m.Groups[3].Value.Trim() };
            if (Regex.IsMatch(line, @"\[ENROLLMENT_(OK|UNCHANGED)\]", RegexOptions.IgnoreCase)) return new[] { "team", "ok", "" };
            m = Regex.Match(line, @"\[ENROLLMENT_FAILED\]\s*(.*)$", RegexOptions.IgnoreCase);
            if (m.Success) return new[] { "team", "failed", m.Groups[1].Value.Trim() };
            if (Regex.IsMatch(line, @"\[ENROLLMENT_(PENDING|MISSING)\]", RegexOptions.IgnoreCase)) return new[] { "team", "skipped", "Not joined" };
            return null;
        }

        // Windows command-line quoting for ProcessStartInfo.Arguments.
        internal static string CommandLine(IEnumerable<string> arguments)
        {
            return String.Join(" ", arguments.Select(argument =>
            {
                if (argument.Length == 0) return "\"\"";
                if (!Regex.IsMatch(argument, "[\\s\"]")) return argument;
                return "\"" + Regex.Replace(Regex.Replace(argument, "(\\\\*)\"", "$1$1\\\""), "(\\\\+)$", "$1$1") + "\"";
            }));
        }

        private readonly string _coreSetup, _logPath;
        private readonly string[] _coreArguments;
        private readonly bool _askDetails, _hasEnrollmentFile, _codeBundled;
        private readonly string _termsPath, _termsVersion, _installRoot;
        private readonly SystemCheck _check;

        private int _page;
        private string _result = "cancelled";
        private Process _process;
        private Task<string> _readOut, _readErr;
        private DateTime _exitedAt = DateTime.MinValue;
        private readonly Dictionary<string, string> _status = new Dictionary<string, string>();
        private readonly Dictionary<string, string> _details = new Dictionary<string, string>();
        private string[] _join;
        private int? _exitCode;
        private bool _openApp, _smoke, _activated;

        private Form _form;
        private StepRail _rail;
        private Button _back, _next, _cancel;
        private Label _hint, _revitNote, _problem, _nameLabel, _emailLabel, _codeLabel, _joinNote, _currentTask, _doneTitle, _doneSummary;
        private Panel _body, _reviewRows, _installing, _doneRows;
        private CheckBox _accept, _skillsBox, _updatesBox, _joinBox, _openAppBox;
        private TextBox _nameBox, _codeBox, _emailBox, _logBox;
        private LinkLabel _detailsLink;
        private ProgressBar _progress;
        private readonly Dictionary<string, Label> _stepLabels = new Dictionary<string, Label>();
        private readonly List<string> _stepOrder = new List<string>();
        private Group _aiGroup, _cadGroup;
        private Panel[] _pages;
        private readonly Timer _timer = new Timer();

        private sealed class Group
        {
            internal CheckBox All;
            internal List<CheckBox> Boxes = new List<CheckBox>();
        }

        private SetupWizard(string coreSetup, string[] coreArguments, string logPath, bool askDetails, bool hasEnrollmentFile)
        {
            _coreSetup = coreSetup; _coreArguments = coreArguments; _logPath = logPath;
            _askDetails = askDetails; _hasEnrollmentFile = hasEnrollmentFile;
            _codeBundled = TeamJoin.Bundled(Path.Combine(Paths.Root, "installer"));
            _termsPath = Path.Combine(Paths.Root, "installer", "TERMS.txt");
            _termsVersion = TermsVersion(_termsPath);
            _check = SystemCheck.Take();
            _installRoot = Path.Combine(Paths.LocalAppData, "BIM-CAD-MCP");
            for (int i = 0; i < coreArguments.Length - 1; i++) if (coreArguments[i] == "-RepositoryPath") _installRoot = coreArguments[i + 1];
        }

        private Panel NewPage()
        {
            Panel page = new Panel(); page.Dock = DockStyle.Fill; page.BackColor = Color.White; page.Visible = false;
            _body.Controls.Add(page);
            return page;
        }

        private static Label AddText(Control parent, string text, int x, int y, int width = 0, float size = 10, bool bold = false, bool muted = false)
        {
            Label label = Brand.NewLabel(text, x, y, width, size, muted, bold);
            parent.Controls.Add(label);
            return label;
        }

        private static void AddRow(Control parent, int y, string icon, string title, string detail, string status, string kind)
        {
            parent.Controls.Add(Brand.IconBox(icon, 20, 30, y + 6));
            AddText(parent, title, 62, y, 0, 10, true);
            AddText(parent, detail, 62, y + 20, 330, 9, false, true);
            Badge badge = new Badge(status, kind);
            badge.Location = new Point(520 - Brand.Round(badge.Width / Brand.Scale()), y + 6);
            parent.Controls.Add(badge);
        }

        private void Build(string version)
        {
            SystemCheck check = _check;
            _form = Brand.NewForm(Brand.Name, 760, 520);
            _form.Text = "Smart Connector Setup";
            _rail = new StepRail(new[] { "Welcome", "System check", "Choose apps", "AI connections", "Install", "Finish" }, version.Length > 0 ? "Version " + version : "");
            Panel footer = new Panel();
            footer.Dock = DockStyle.Bottom; footer.Height = 64; footer.BackColor = Color.FromArgb(248, 250, 252);
            _back = Brand.NewButton("Back", false, 96); _back.Location = new Point(198, 14);
            _next = Brand.NewButton("Next", true, 112); _next.Location = new Point(302, 14);
            _cancel = Brand.NewButton("Cancel", false, 96); _cancel.Location = new Point(422, 14);
            _hint = Brand.NewLabel("", 24, 24, 170, 9, true);
            footer.Controls.AddRange(new Control[] { _hint, _back, _next, _cancel });
            _body = new Panel();
            _body.Dock = DockStyle.Fill; _body.BackColor = Color.White;
            _form.Controls.Add(_body); _form.Controls.Add(footer); _form.Controls.Add(_rail);
            _body.BringToFront();

            // --- 0 Welcome
            Panel welcome = NewPage();
            AddText(welcome, "Welcome to Smart Connector", 28, 24, 0, 16, true);
            AddText(welcome, "Connect Claude and Codex to Revit and AutoCAD on this computer, and keep your team's workflow skills up to date.", 29, 62, 490, 10, false, true);
            string[][] features =
            {
                new[] { "revit", "Revit and AutoCAD", "Claude and Codex work with your open model or drawing." },
                new[] { "assistant", "Claude and Codex", "Connected for you. No settings files to edit." },
                new[] { "skills", "Team workflow skills", "Approved skills installed and kept in sync." },
                new[] { "updates", "Update checks", "Once a day, when Revit, AutoCAD or Smart Connector opens. You are asked before anything installs." }
            };
            for (int i = 0; i < 4; i++)
            {
                Card card = new Card(28 + (i % 2) * 254, 112 + (i / 2) * 80, 242, 70); welcome.Controls.Add(card);
                card.Controls.Add(Brand.IconBox(features[i][0], 20, 12, 12, Brand.Link));
                AddText(card, features[i][1], 42, 10, 0, 9.5f, true);
                AddText(card, features[i][2], 42, 30, 190, 8.5f, false, true);
            }
            _revitNote = AddText(welcome, "Revit is open. Save your work and close it before installing, so the Revit add-in can be updated. AutoCAD can stay open.", 29, 280, 490, 9);
            _revitNote.ForeColor = Brand.Warn;
            _accept = new CheckBox();
            _accept.Text = "I have read and accept the terms of use"; _accept.AutoSize = true; _accept.Location = new Point(28, 330);
            welcome.Controls.Add(_accept);
            LinkLabel readTerms = new LinkLabel();
            readTerms.Text = "Read the terms of use"; readTerms.AutoSize = true; readTerms.Location = new Point(46, 356); readTerms.LinkColor = Brand.Link;
            welcome.Controls.Add(readTerms);

            // --- 1 System check
            Panel system = NewPage();
            AddText(system, "System check", 28, 22, 0, 15, true);
            AddText(system, "Setup looked at this computer. Programs that are not installed are simply skipped.", 29, 56, 490, 9.5f, false, true);
            bool windowsReady = check.Windows64 && check.NetOk;
            string[][] rows =
            {
                new[] { "monitor", "Windows", windowsReady ? "64-bit with .NET Framework 4.8" : check.Windows64 ? "64-bit; .NET Framework 4.8 not found" : "Smart Connector needs 64-bit Windows", windowsReady ? "Ready" : "Check", windowsReady ? "Good" : "Warn" },
                new[] { "revit", "Revit 2024", check.Revit2024 ? "The Smart Connector tab will be added" : "Not installed", check.Revit2024 ? "Found" : "Not found", check.Revit2024 ? "Good" : "Off" },
                new[] { "autocad", "AutoCAD", check.AutoCad.Length > 0 ? "AutoCAD " + String.Join(", ", check.AutoCad) + ": buttons on the Add-ins tab" : "Not installed", check.AutoCad.Length > 0 ? "Found" : "Not found", check.AutoCad.Length > 0 ? "Good" : "Off" },
                new[] { "claude", "Claude Desktop", check.ClaudeDesktop ? "Installed for this Windows user" : "Not installed; setup can install it", check.ClaudeDesktop ? "Found" : "Not found", check.ClaudeDesktop ? "Good" : "Off" },
                new[] { "claude", "Claude Code", check.ClaudeCode ? "Command-line tool found" : "Not installed", check.ClaudeCode ? "Found" : "Not found", check.ClaudeCode ? "Good" : "Off" },
                new[] { "codex", "Codex / ChatGPT Desktop", check.CodexCli ? "Codex command-line tool found" : check.ChatGptDesktop ? "ChatGPT Desktop found: connected through its Codex settings" : "Not installed; connect it later with Repair", check.Codex ? "Found" : "Not found", check.Codex ? "Good" : "Off" }
            };
            for (int i = 0; i < rows.Length; i++) AddRow(system, 92 + i * 44, rows[i][0], rows[i][1], rows[i][2], rows[i][3], rows[i][4]);
            if (check.RevitOther.Length > 0)
            {
                Label other = AddText(system, "Revit " + String.Join(", ", check.RevitOther) + " found: not supported yet, so it is skipped.", 29, 362, 490, 9);
                other.ForeColor = Brand.Warn;
            }

            // --- 2 Choose apps
            Panel choose = NewPage();
            AddText(choose, "Choose what to connect", 28, 18, 0, 15, true);
            _aiGroup = MakeGroup(choose, "AI apps", 28, new[]
            {
                new object[] { "ClaudeDesktop", "Claude Desktop", true, check.ClaudeDesktop ? "Installed" : "Installed for you during setup" },
                new object[] { "ClaudeCode", "Claude Code", check.ClaudeCode, check.ClaudeCode ? "Installed" : "Not installed" },
                new object[] { "Codex", "Codex / ChatGPT Desktop", check.Codex, check.CodexCli ? "Installed" : check.ChatGptDesktop ? "ChatGPT Desktop" : "Not installed" }
            });
            _cadGroup = MakeGroup(choose, "Autodesk software", 284, new[]
            {
                new object[] { "Revit", "Revit 2024", check.Revit2024, check.Revit2024 ? "Smart Connector tab" : "Not installed" },
                new object[] { "AutoCAD", check.AutoCad.Length > 0 ? "AutoCAD " + check.AutoCad[check.AutoCad.Length - 1] : "AutoCAD", check.AutoCad.Length > 0, check.AutoCad.Length > 0 ? "Add-ins panel and AI Markup" : "Not installed" }
            });
            // Not optional: every PC gets the team workflow skills and the daily update check.
            AddText(choose, "Always included", 28, 218, 0, 9.5f, true);
            AddText(choose, "Team workflow skills, kept in sync, and the daily update check (you are asked before an update installs).", 29, 240, 500, 9, false, true);
            _skillsBox = new CheckBox(); _skillsBox.Checked = true; _skillsBox.Visible = false;
            _updatesBox = new CheckBox(); _updatesBox.Checked = true; _updatesBox.Visible = false;
            choose.Controls.AddRange(new Control[] { _skillsBox, _updatesBox });
            _joinBox = new CheckBox(); _joinBox.Text = "Join the team (your skills and usage appear on the team dashboard)"; _joinBox.Checked = true; _joinBox.AutoSize = true; _joinBox.Location = new Point(28, 268);
            _joinBox.Visible = _askDetails; choose.Controls.Add(_joinBox);
            // Name and email always; the team code only when this setup does not carry one (the normal setup file).
            int nameWidth = _codeBundled ? 240 : 160, emailLeft = _codeBundled ? 284 : 200, emailWidth = _codeBundled ? 248 : 170;
            _nameLabel = AddText(choose, "Your name", 28, 296, 0, 9, true);
            _nameBox = new TextBox(); _nameBox.Location = new Point(28, 316); _nameBox.Size = new Size(nameWidth, 26); _nameBox.MaxLength = 80;
            _emailLabel = AddText(choose, "Work email", emailLeft, 296, 0, 9, true);
            _emailBox = new TextBox(); _emailBox.Location = new Point(emailLeft, 316); _emailBox.Size = new Size(emailWidth, 26); _emailBox.MaxLength = 254;
            _codeLabel = AddText(choose, "Team code", 382, 296, 0, 9, true);
            _codeBox = new TextBox(); _codeBox.Location = new Point(382, 316); _codeBox.Size = new Size(150, 26); _codeBox.MaxLength = 256; _codeBox.UseSystemPasswordChar = true;
            choose.Controls.AddRange(new Control[] { _nameBox, _emailBox, _codeBox });
            _joinNote = AddText(choose, TeamJoin.Notice, 28, 346, 500, 8, false, true);
            _problem = AddText(choose, "", 28, 374, 500, 9); _problem.ForeColor = Brand.Bad;
            foreach (Group group in new[] { _aiGroup, _cadGroup })
            {
                Group g = group;
                g.All.Click += delegate { foreach (CheckBox b in g.Boxes) if (b.Enabled) b.Checked = g.All.Checked; ValidateChoices(); };
                foreach (CheckBox b in g.Boxes) b.CheckedChanged += delegate { ValidateChoices(); };
            }
            _joinBox.CheckedChanged += delegate { ValidateChoices(); };
            _nameBox.TextChanged += delegate { ValidateChoices(); };
            _emailBox.TextChanged += delegate { ValidateChoices(); };
            _codeBox.TextChanged += delegate { ValidateChoices(); };

            // --- 3 AI connections (review before installing)
            Panel review = NewPage();
            AddText(review, "Connect your AI apps", 28, 22, 0, 15, true);
            AddText(review, "Setup adds Smart Connector to each app's own settings for this Windows user. Your other connectors and settings are kept, and a backup is made first.", 29, 56, 490, 9.5f, false, true);
            _reviewRows = new Panel(); _reviewRows.Location = new Point(0, 100); _reviewRows.Size = new Size(552, 170); review.Controls.Add(_reviewRows);
            Label restartNote = AddText(review, "Restart Claude and Codex after setup so they load the connector. Claude may ask you once to allow its tools.", 29, 290, 490, 9);
            restartNote.ForeColor = Brand.Link;

            // --- 4 Installing
            _installing = NewPage();
            AddText(_installing, "Installing", 28, 22, 0, 15, true);
            _currentTask = AddText(_installing, "Starting...", 29, 56, 400, 9, false, true);
            _progress = new ProgressBar();
            _progress.Location = new Point(28, 80); _progress.Size = new Size(500, 8); _progress.Style = ProgressBarStyle.Continuous;
            _installing.Controls.Add(_progress);
            _detailsLink = new LinkLabel();
            _detailsLink.Text = "Show details"; _detailsLink.AutoSize = true; _detailsLink.LinkColor = Brand.Link;
            _installing.Controls.Add(_detailsLink);
            _logBox = new TextBox();
            _logBox.Multiline = true; _logBox.ScrollBars = ScrollBars.Vertical; _logBox.ReadOnly = true; _logBox.Visible = false;
            _logBox.Font = Brand.Font(8.5f, FontStyle.Regular, "Consolas");
            _logBox.Location = new Point(28, 100); _logBox.Size = new Size(500, 250);
            _installing.Controls.Add(_logBox); _logBox.BringToFront();

            // --- 5 Finish
            Panel finished = NewPage();
            _doneTitle = AddText(finished, "", 28, 22, 0, 15, true);
            _doneSummary = AddText(finished, "", 29, 58, 500, 9.5f, false, true);
            _doneRows = new Panel(); _doneRows.Location = new Point(0, 92); _doneRows.Size = new Size(552, 230); finished.Controls.Add(_doneRows);
            _openAppBox = new CheckBox();
            _openAppBox.Text = "Open Smart Connector when I click Finish"; _openAppBox.Checked = true; _openAppBox.AutoSize = true; _openAppBox.Location = new Point(28, 330);
            finished.Controls.Add(_openAppBox);
            LinkLabel openLog = new LinkLabel();
            openLog.Text = "Open the setup log"; openLog.AutoSize = true; openLog.LinkColor = Brand.Link; openLog.Location = new Point(28, 358);
            finished.Controls.Add(openLog);

            _pages = new[] { welcome, system, choose, review, _installing, finished };

            _timer.Interval = 150;
            _timer.Tick += delegate { Tick(); };
            _accept.CheckedChanged += delegate { if (_page == 0) _next.Enabled = _accept.Checked; };
            readTerms.LinkClicked += delegate { ShowTerms(); };
            _detailsLink.LinkClicked += delegate
            {
                _logBox.Visible = !_logBox.Visible; _detailsLink.Text = _logBox.Visible ? "Hide details" : "Show details"; _logBox.BringToFront(); _detailsLink.BringToFront();
            };
            openLog.LinkClicked += delegate { Launch.Open("notepad.exe", _logPath); };
            _back.Click += delegate { ShowPage(Math.Max(0, _page - 1)); };
            _cancel.Click += delegate { _form.Close(); };
            _next.Click += delegate
            {
                switch (_page)
                {
                    case 0: ShowPage(1); break;
                    case 1: ShowPage(2); break;
                    case 2: ShowPage(3); break;
                    case 3: StartInstall(); break;
                    case 5: _openApp = _openAppBox.Checked && _result == "ok"; _form.Close(); break;
                }
            };
            _form.FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (_page == 4) { e.Cancel = true; return; }   // never stop half way through an install
                if (_page < 4 && !_smoke)
                {
                    DialogResult answer = MessageBox.Show(_form, "Cancel setup? Nothing has been installed yet.", "Smart Connector Setup", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
                    if (answer != DialogResult.Yes) e.Cancel = true;
                }
            };
        }

        private Group MakeGroup(Panel choose, string title, int x, object[][] items)
        {
            Card box = new Card(x, 54, 248, 150); choose.Controls.Add(box);
            Group group = new Group();
            group.All = new CheckBox(); group.All.Text = title; group.All.Font = Brand.Semibold(9.5f);
            group.All.AutoSize = true; group.All.Location = new Point(12, 10); box.Controls.Add(group.All);
            int y = 40;
            foreach (object[] item in items)
            {
                bool enabled = (bool)item[2];
                CheckBox cb = new CheckBox(); cb.Text = (string)item[1]; cb.AutoSize = true; cb.Location = new Point(12, y);
                cb.Enabled = enabled; cb.Checked = enabled; cb.Tag = item[0]; box.Controls.Add(cb);
                Label note = Brand.NewLabel((string)item[3], 30, y + 20, 210, 8, true); box.Controls.Add(note);
                group.Boxes.Add(cb); y += 36;
            }
            return group;
        }

        private static List<string> Selected(Group group) { return group.Boxes.Where(b => b.Checked).Select(b => (string)b.Tag).ToList(); }

        private void ValidateChoices()
        {
            foreach (Group group in new[] { _aiGroup, _cadGroup })
            {
                List<CheckBox> live = group.Boxes.Where(b => b.Enabled).ToList();
                group.All.Enabled = live.Count > 0;
                group.All.Checked = live.Count > 0 && live.All(b => b.Checked);
            }
            bool joining = _askDetails && _joinBox.Checked;
            foreach (Control c in new Control[] { _nameLabel, _nameBox, _emailLabel, _emailBox, _joinNote }) c.Visible = joining;
            foreach (Control c in new Control[] { _codeLabel, _codeBox }) c.Visible = joining && !_codeBundled;
            string message = "";
            int ai = Selected(_aiGroup).Count, cad = Selected(_cadGroup).Count;
            if (ai == 0) message = "Choose at least one AI app.";
            else if (_cadGroup.Boxes.Any(b => b.Enabled) && cad == 0) message = "Choose at least one Autodesk program.";
            else if (joining && !(TeamJoin.ValidName(_nameBox.Text) && TeamJoin.ValidEmail(_emailBox.Text))) message = "Enter your name and work email to join the team, or untick Join the team.";
            else if (joining && !_codeBundled && !TeamJoin.ValidCode(_codeBox.Text)) message = "Enter the team code from your administrator, or untick Join the team.";
            _problem.Text = message;
            if (_page == 2) _next.Enabled = message.Length == 0;
            _hint.Text = ai + " AI app" + (ai == 1 ? "" : "s") + " - " + cad + " Autodesk program" + (cad == 1 ? "" : "s");
        }

        private void FillReview()
        {
            _reviewRows.Controls.Clear();
            List<string> chosen = Selected(_aiGroup);
            string[][] specs =
            {
                new[] { "ClaudeDesktop", "claude", "Claude Desktop", _check.ClaudeDesktop ? "Adds \"Smart Connector\" to its connectors; Claude restarts" : "Installs Claude Desktop, then adds Smart Connector" },
                new[] { "ClaudeCode", "claude", "Claude Code", "Adds a user-level MCP server named autodesk" },
                new[] { "Codex", "codex", "Codex", "Adds an MCP server named autodesk to config.toml" }
            };
            for (int i = 0; i < 3; i++)
            {
                bool on = chosen.Contains(specs[i][0]);
                AddRow(_reviewRows, i * 52, specs[i][1], specs[i][2], on ? specs[i][3] : "Not selected; left unchanged", on ? "Will connect" : "Skipped", on ? "Info" : "Off");
            }
        }

        private void BuildSteps(ICollection<string> hidden)
        {
            foreach (Label label in _stepLabels.Values.ToList()) { _installing.Controls.Remove(label); label.Dispose(); }
            _stepLabels.Clear(); _stepOrder.Clear(); _status.Clear();
            int y = 100;
            foreach (string[] step in WizardSteps)
            {
                if (hidden.Contains(step[0])) continue;
                Label row = Brand.NewLabel("\u25CB   " + step[1], 30, y, 500);
                row.ForeColor = Brand.Muted;
                _installing.Controls.Add(row); _stepLabels[step[0]] = row; _stepOrder.Add(step[0]); _status[step[0]] = "pending";
                y += 26;
            }
            _detailsLink.Location = new Point(30, y + 6);
        }

        private static string StepText(string id) { return WizardSteps.First(step => step[0] == id)[1]; }

        private void UpdateStep(string id, string status, string detail)
        {
            if (!_stepLabels.ContainsKey(id)) return;
            _status[id] = status;
            if (detail.Length > 0) _details[id] = detail;
            Label label = _stepLabels[id]; string text = StepText(id);
            switch (status)
            {
                case "running": label.Text = "\u25D0   " + text + "..."; label.ForeColor = Brand.Accent; _currentTask.Text = text + "..."; break;
                case "ok": label.Text = "\u2713   " + text; label.ForeColor = Brand.Good; break;
                case "skipped": label.Text = "\u2013   " + text + (detail.Length > 0 ? "  (" + detail + ")" : ""); label.ForeColor = Brand.Muted; break;
                case "failed": label.Text = "\u2717   " + text + (detail.Length > 0 ? "  (" + detail + ")" : ""); label.ForeColor = Brand.Bad; break;
            }
            int done = _status.Values.Count(s => s == "ok" || s == "skipped" || s == "failed");
            _progress.Value = Math.Min(100, Brand.Round(100.0 * done / Math.Max(1, _stepLabels.Count)));
        }

        private void ShowPage(int index)
        {
            _page = index;
            for (int i = 0; i < _pages.Length; i++) _pages[i].Visible = i == index;
            _rail.Current = index;
            _revitNote.Visible = ConnectorStatus.ProcessRunning("Revit");
            _back.Visible = index >= 1 && index <= 3;
            _cancel.Visible = index < 4;
            _next.Visible = index != 4;
            _hint.Text = "";
            switch (index)
            {
                case 0: _next.Text = "Next"; _next.Enabled = _accept.Checked; break;
                case 1: _next.Text = "Next"; _next.Enabled = _check.Windows64; break;
                case 2: _next.Text = "Next"; ValidateChoices(); break;
                case 3: _next.Text = "Install"; _next.Enabled = true; FillReview(); break;
                case 5: _next.Text = "Finish"; _next.Enabled = true; break;
            }
        }

        private void StartInstall()
        {
            SaveTermsAcceptance(_termsVersion);
            List<string> ai = Selected(_aiGroup), cad = Selected(_cadGroup);
            string product = cad.Count == 1 ? cad[0] : "All";
            List<string> arguments = new List<string>(_coreArguments)
            {
                "-TermsVersion", _termsVersion, "-AiClients", String.Join(",", ai), "-Product", product,
                "-Skills", _skillsBox.Checked ? "On" : "Off", "-AutoUpdates", _updatesBox.Checked ? "On" : "Off"
            };
            _join = _askDetails && _joinBox.Checked ? new[] { _nameBox.Text.Trim(), _emailBox.Text.Trim() } : null;
            if (_join != null) arguments.AddRange(new[] { "-JoinName", _join[0], "-JoinEmail", _join[1] });
            // The typed team code reaches the engine's team step the same way a TEAM build's code does; it is deleted
            // when that step ends, and again when setup ends in case the engine stopped before it.
            if (_join != null && !_codeBundled && !_smoke) { TeamJoin.WriteJoinFile(_codeBox.Text); }
            List<string> hidden = new List<string>();
            if (!(_hasEnrollmentFile || _join != null)) hidden.Add("team");
            if (product == "Revit") hidden.Add("autocad");
            if (product == "AutoCAD") hidden.Add("revit");
            BuildSteps(hidden);
            ShowPage(4);
            UpdateStep("files", "running", "");
            // The install engine of this program, or the script when the program is not installed.
            _process = Launch.CoreRedirected(_coreSetup, arguments, Encoding.UTF8);
            // Async line reads polled from the UI timer, as the PowerShell window does.
            _readOut = _process.StandardOutput.ReadLineAsync();
            _readErr = _process.StandardError.ReadLineAsync();
            _timer.Start();
        }

        private void HandleLine(string line)
        {
            if (line == null) return;
            try { File.AppendAllText(_logPath, line + "\r\n", new UTF8Encoding(false)); } catch (Exception) { }
            _logBox.AppendText(line + "\r\n");
            string[] parsed = ParseLine(line);
            if (parsed == null) return;
            if (parsed[1] == "running")
            {
                // Starting a phase means the previous running steps finished without a failure.
                foreach (string id in _status.Keys.ToList()) if (_status[id] == "running" && id != parsed[0]) UpdateStep(id, "ok", "");
            }
            UpdateStep(parsed[0], parsed[1], parsed[2]);
        }

        private void Tick()
        {
            for (int pass = 0; pass < 2; pass++)
            {
                bool output = pass == 0;
                Task<string> task = output ? _readOut : _readErr;
                while (task != null && task.IsCompleted)
                {
                    string line = task.Result;
                    if (line == null) { task = null; break; }
                    HandleLine(line);
                    task = (output ? _process.StandardOutput : _process.StandardError).ReadLineAsync();
                }
                if (output) _readOut = task; else _readErr = task;
            }
            if (_process.HasExited)
            {
                // A program the engine started can keep the output pipe open after the engine has ended; finish a few
                // seconds after the engine exits rather than wait for that program to close.
                if (_exitedAt == DateTime.MinValue) _exitedAt = DateTime.UtcNow;
                if ((_readOut == null && _readErr == null) || (DateTime.UtcNow - _exitedAt).TotalSeconds >= 3)
                {
                    _timer.Stop(); Finish(_process.ExitCode);
                }
            }
        }

        private void Finish(int code)
        {
            if (!_codeBundled && !_smoke) TeamJoin.DeleteJoinFile();
            foreach (string id in _status.Keys.ToList())
            {
                string s = _status[id];
                if (s == "running") UpdateStep(id, code == 0 ? "ok" : "failed", "");
                else if (s == "pending") UpdateStep(id, "skipped", "");
            }
            bool failed = _status.Values.Any(s => s == "failed");
            _exitCode = code;
            _result = code == 0 && !failed ? "ok" : "problems";
            _doneRows.Controls.Clear();
            Dictionary<string, string> icons = new Dictionary<string, string>
            {
                { "files", "connector" }, { "skills", "skills" }, { "revit", "revit" }, { "autocad", "autocad" }, { "codex", "codex" },
                { "claude_desktop", "claude" }, { "claude_code", "claude" }, { "team", "team" }, { "updates", "updates" }
            };
            int i = 0;
            foreach (string[] step in WizardSteps)
            {
                if (!_stepLabels.ContainsKey(step[0])) continue;
                string s = _status[step[0]];
                Card row = new Card(28 + (i % 2) * 254, (i / 2) * 44, 242, 38); _doneRows.Controls.Add(row);
                row.Controls.Add(Brand.IconBox(icons[step[0]], 16, 10, 11));
                string title = Regex.Replace(Regex.Replace(step[1], "^(Install|Connect) ", "", RegexOptions.IgnoreCase), "workflow skills for Codex and Claude", "Workflow skills", RegexOptions.IgnoreCase);
                row.Controls.Add(Brand.NewLabel(title.Substring(0, 1).ToUpperInvariant() + title.Substring(1), 32, 10, 0, 9));
                Label status = Brand.NewLabel(s == "ok" ? "Done" : s == "failed" ? "Failed" : "Skipped", 180, 10, 0, 9, false, true);
                status.ForeColor = s == "ok" ? Brand.Good : s == "failed" ? Brand.Bad : Brand.Muted;
                row.Controls.Add(status);
                i++;
            }
            if (_result == "ok")
            {
                _doneTitle.Text = "Smart Connector is ready"; _doneTitle.ForeColor = Brand.Good;
                _doneSummary.Text = "Restart Revit, AutoCAD, Claude and Codex so they load the connector.";
            }
            else
            {
                _doneTitle.Text = "Setup finished with problems"; _doneTitle.ForeColor = Brand.Bad;
                _doneSummary.Text = "Everything that could be installed was installed. Open the setup log, fix the failed item and run setup again, or contact your administrator.";
            }
            ShowPage(5);
        }

        private void ShowTerms()
        {
            Form dialog = Brand.NewForm(Brand.Name, 620, 460); dialog.Text = "Smart Connector terms of use";
            TextBox box = new TextBox(); box.Multiline = true; box.ReadOnly = true; box.ScrollBars = ScrollBars.Vertical; box.Dock = DockStyle.Fill;
            box.Font = Brand.Font(9.5f); box.BackColor = Color.White;
            box.Text = File.Exists(_termsPath) ? Regex.Replace(File.ReadAllText(_termsPath), "(?<!\r)\n", "\r\n") : "The terms of use file is missing from this installer.";
            dialog.Controls.Add(box); box.SelectionStart = 0;
            dialog.ShowDialog(_form); dialog.Dispose();
        }

        internal static WizardResult Show(string coreSetup, string[] coreArguments, string logPath, string version, bool askDetails, bool hasEnrollmentFile, bool smokeTest)
        {
            SetupWizard wizard = new SetupWizard(coreSetup, coreArguments, logPath, askDetails, hasEnrollmentFile);
            wizard.Build(version);
            Form form = wizard._form;
            if (smokeTest)
            {
                // Build and step through every page without installing anything.
                wizard._smoke = true;
                wizard._accept.Checked = true;
                foreach (int index in new[] { 0, 1, 2, 3 }) wizard.ShowPage(index);
                wizard.BuildSteps(new[] { "team" }); wizard.ShowPage(4);
                foreach (string id in wizard._stepOrder.ToList()) wizard.UpdateStep(id, "ok", "");
                wizard.Finish(0);
                form.Dispose();
                return new WizardResult { Result = wizard._result, Pages = wizard._pages.Length, Steps = wizard._stepLabels.Count };
            }

            // Windows may refuse focus to a window started from Explorer, leaving setup hidden behind it.
            // Stay on top until the person first switches to the window, then behave normally.
            form.TopMost = true;
            form.Shown += delegate { form.Activate(); };
            form.Activated += delegate { if (!wizard._activated) { wizard._activated = true; form.TopMost = false; } };

            wizard.ShowPage(0);
            form.ShowDialog();
            form.Dispose();
            if (wizard._openApp) OpenApp(wizard._installRoot);
            return new WizardResult { Result = wizard._result, ExitCode = wizard._exitCode, Joined = wizard._join != null };
        }

        // The installed app: this program when it is installed there, otherwise the PowerShell window.
        internal static void OpenApp(string installRoot)
        {
            string program = Path.Combine(installRoot, "bin", "SmartConnector.exe");
            string app = Path.Combine(installRoot, "installer", "SmartConnectorApp.ps1");
            if (File.Exists(program))
            {
                ProcessStartInfo info = new ProcessStartInfo(program, "app");
                info.UseShellExecute = false; info.WorkingDirectory = Paths.LocalAppData;
                Process.Start(info).Dispose();
            }
            else if (File.Exists(app))
                Launch.Hidden(Launch.PowerShell, "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " + Launch.Quote(app) + " -RepositoryPath " + Launch.Quote(installRoot)).Dispose();
        }
    }

    // SmartConnector.exe setup: what Install-Autodesk-MCP-Connector.ps1 -Install -PayloadFolder <install root> does,
    // for the installed connector this program belongs to. The setup .exe only installs files; the first open of
    // Smart Connector runs this, and Setup-BimCad.ps1 removes setup\setup-pending.txt when it has run to the end.
    internal static class SetupCommand
    {
        internal static int Run(bool smokeTest)
        {
            // Started from a 32-bit program, this 64-bit process can inherit the 32-bit Program Files paths;
            // use the real ones so Revit, AutoCAD and Git are found (also by Setup-BimCad.ps1, which inherits them).
            if (Environment.Is64BitProcess && Env.Variable("ProgramW6432").Length > 0) Environment.SetEnvironmentVariable("ProgramFiles", Env.Variable("ProgramW6432"));
            if (Environment.Is64BitProcess && Env.Variable("CommonProgramW6432").Length > 0) Environment.SetEnvironmentVariable("CommonProgramFiles", Env.Variable("CommonProgramW6432"));
            string logDirectory = Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector");
            string logPath = Path.Combine(logDirectory, "setup.log");
            string packageRoot = Paths.Root;
            try
            {
                string coreSetup = Path.Combine(packageRoot, "installer", "Setup-BimCad.ps1");
                // The program itself is the setup; the PowerShell scripts exist only in a copy taken from the repository.
                if (!Directory.Exists(Path.Combine(packageRoot, ".agents", "skills")) || !File.Exists(Path.Combine(packageRoot, "VERSION")))
                    throw new InvalidOperationException("The Smart Connector installation payload is invalid.");
                string payloadInstaller = Path.Combine(packageRoot, "installer");
                string version = File.ReadAllText(Path.Combine(packageRoot, "VERSION")).Trim();
                if (smokeTest)
                {
                    TeamJoin.ShowDialog(null, true);
                    foreach (bool ask in new[] { true, false })
                    {
                        WizardResult result = SetupWizard.Show(coreSetup, new[] { "-Action", "Install", "-RepositoryPath", Path.Combine(Path.GetTempPath(), "smart-connector-smoke") },
                            Path.Combine(Path.GetTempPath(), "smart-connector-smoke.log"), version, ask, false, true);
                        if (result.Result != "ok" || result.Pages != 6 || result.Steps < 7) throw new InvalidOperationException("The setup window did not step through its pages.");
                    }
                    return 0;
                }
                Directory.CreateDirectory(logDirectory);
                File.WriteAllText(logPath, String.Format("[{0}] Starting Smart Connector installation.\r\n", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")), new UTF8Encoding(true));
                List<string> coreArguments = new List<string> { "-Action", "Install", "-RepositoryPath", Path.Combine(Paths.LocalAppData, "BIM-CAD-MCP"), "-InstallClaudeDesktopIfMissing" };
                // Administrators deploy the enrollment file beside the setup .exe, which copies it into the install folder.
                string enrollmentFile = new[] { "enrollment.json", "skill-service-device.json" }.Select(name => Path.Combine(packageRoot, name)).FirstOrDefault(File.Exists);
                if (enrollmentFile != null) coreArguments.AddRange(new[] { "-EnrollmentPath", enrollmentFile });
                // The private TEAM build carries a join code; the administrator's enrollment file always wins.
                bool askDetails = enrollmentFile == null && TeamJoin.Required(payloadInstaller);
                WizardResult outcome = SetupWizard.Show(coreSetup, coreArguments.ToArray(), logPath, version, askDetails, enrollmentFile != null, false);
                if (outcome.Result == "cancelled")
                {
                    File.AppendAllText(logPath, String.Format("[{0}] Setup was cancelled before anything was installed.\r\n", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")), new UTF8Encoding(false));
                    return 0;
                }
                // No background work after setup. On a team PC that has never synced, Smart Connector offers Skills Sync
                // when it opens (the Finish page opens it).
                return outcome.Result == "ok" ? 0 : 1;
            }
            catch (Exception exception)
            {
                if (smokeTest) { Console.Error.WriteLine(exception); return 1; }
                try
                {
                    Directory.CreateDirectory(logDirectory);
                    File.AppendAllText(logPath, String.Format("[{0}] ERROR: {1}\r\n", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"), exception.Message), new UTF8Encoding(false));
                }
                catch (Exception) { }
                ShowMessage(String.Format("Setup could not finish.\r\n\r\n{0}\r\n\r\nLog: {1}", exception.Message, logPath));
                return 1;
            }
        }

        // A message box in front of other windows, even when nothing of setup is on screen yet.
        private static void ShowMessage(string message)
        {
            Form owner = new Form();
            owner.ShowInTaskbar = false; owner.TopMost = true; owner.StartPosition = FormStartPosition.CenterScreen;
            owner.Size = new Size(1, 1); owner.Opacity = 0;
            try
            {
                owner.Show(); owner.Activate();
                MessageBox.Show(owner, message, "Smart Connector", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally { owner.Close(); owner.Dispose(); }
        }
    }
}
