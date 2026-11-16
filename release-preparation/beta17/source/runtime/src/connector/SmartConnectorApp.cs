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

// Smart Connector app: one window for the connector's status and everything it can do. The C# port of
// installer\SmartConnectorApp.ps1. Sections: Overview, Autodesk apps, AI connections, Workflow skills, Components,
// Updates, Settings, Diagnostics, Help. Opened from the Revit and AutoCAD buttons, the Start menu and the end of setup.
// Every action runs the existing setup, Skills Sync or update scripts. When it opens it checks for updates (at most
// once a day) and shows the weekly Skills Sync reminder; nothing of Smart Connector runs after it closes.
//   SmartConnector.exe app [--section Skills] [--smoke-test]
namespace SmartConnector
{
    internal sealed class SmartConnectorApp
    {
        internal static readonly string[][] Sections =
        {
            new[] { "Overview", "Overview", "overview" },
            new[] { "Autodesk", "Autodesk apps", "revit" },
            new[] { "AI", "AI connections", "assistant" },
            new[] { "Skills", "Workflow skills", "skills" },
            new[] { "Components", "Components", "components" },
            new[] { "Updates", "Updates", "updates" },
            new[] { "Settings", "Settings", "settings" },
            new[] { "Diagnostics", "Diagnostics and logs", "diagnostics" },
            new[] { "Help", "Help", "help" }
        };

        // Shared with SmartConnectorApp.ps1, so a PowerShell launcher and this program never both open a window.
        internal const string MutexName = @"Local\SmartConnector.App";
        internal static string RequestPath { get { return Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector", "app-section.txt"); } }

        private static readonly string[][] Logs =
        {
            new[] { "Setup log", @"AutodeskMcpConnector\setup.log" },
            new[] { "Skills Sync log", @"AutodeskMcpSkillCollection\weekly.log" },
            new[] { "Usage upload log", @"AutodeskMcpSkillCollection\usage-upload.log" }
        };

        private string _section;
        private Snapshot _snapshot;
        private Form _form;
        private Panel _content;
        private TextBox _repairBox;
        private readonly List<Button> _navButtons = new List<Button>();
        private readonly List<string> _repairLines = new List<string>();
        private Process _repair, _check;
        private Task<string> _repairOut, _repairErr;
        private string _pending;
        private int _ticks;

        // ---------- entry ----------

        internal static int Run(string section, bool smokeTest)
        {
            if (!Sections.Any(s => s[0] == section)) section = "Overview";
            // The setup .exe only installs files, so setup itself never starts PowerShell. On the first open the setup
            // window runs instead (choose apps, team details); it opens this app again when it finishes.
            string setupPending = Path.Combine(Paths.Root, "setup", "setup-pending.txt");
            if (!smokeTest && File.Exists(setupPending))
                return SetupCommand.Run(false);

            // One window per user: a second start asks the running window to show the requested section.
            using (System.Threading.Mutex mutex = new System.Threading.Mutex(false, MutexName))
            {
                bool owned = false;
                if (!smokeTest)
                {
                    try { owned = mutex.WaitOne(0); }
                    catch (System.Threading.AbandonedMutexException) { owned = true; }
                    if (!owned)
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(RequestPath));
                        File.WriteAllText(RequestPath, section + "\r\n", Encoding.ASCII);
                        return 0;
                    }
                }
                try { return new SmartConnectorApp().Show(section, smokeTest); }
                finally { if (owned) mutex.ReleaseMutex(); }
            }
        }

        // ---------- actions (the install engine of this program, or the existing script) ----------

        // 1.2.0 > 1.2.0-beta.3 > 1.1.9; an unreadable version compares as equal.
        internal static int CompareVersion(string left, string right)
        {
            Regex pattern = new Regex(@"^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$");
            Match a = pattern.Match((left ?? "").Trim().TrimStart('v')), b = pattern.Match((right ?? "").Trim().TrimStart('v'));
            if (!a.Success || !b.Success) return 0;
            for (int i = 1; i <= 3; i++)
            {
                long d = Int64.Parse(a.Groups[i].Value) - Int64.Parse(b.Groups[i].Value);
                if (d != 0) return Math.Sign(d);
            }
            string pa = a.Groups[4].Value, pb = b.Groups[4].Value;
            if (String.Equals(pa, pb, StringComparison.OrdinalIgnoreCase)) return 0;
            if (pa.Length == 0) return 1;
            if (pb.Length == 0) return -1;
            return Math.Sign(String.CompareOrdinal(pa, pb));
        }

        // Start-AppScript: an installer script, hidden.
        private static string AppScriptLine(string script, string arguments)
        {
            return "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " + Launch.Quote(Launch.InstallerScript(script)) + " " + arguments;
        }

        private void Invoke(string name)
        {
            switch (name)
            {
                // The action windows are part of this program; each opens as its own window, as before.
                case "SkillsSync": Launch.Program("action --action SkillsSync"); break;
                case "CheckUpdates": Launch.Program("action --action CheckUpdates"); break;
                case "TestConnection": Launch.Program("action --action Status"); break;
                case "UpdateNow":
                    // The update window waits for Revit and AutoCAD to close, installs, and shows the result. It replaces
                    // the installed files, including this program's own exe, so the app closes once it has started it.
                    Launch.UpdateWindow();
                    _form.Close();
                    break;
                case "OpenSkillsFolder":
                    string folder = Path.Combine(Paths.LocalAppData, "AutodeskMcpSkillCollection", "approved-skills");
                    if (!Directory.Exists(folder)) folder = Path.Combine(Paths.Root, ".agents", "skills");
                    Launch.Open("explorer.exe", folder);
                    break;
                case "PrivateSkills":
                    string list = Path.Combine(Paths.LocalAppData, "AutodeskMcpSkillCollection", "excluded-skills.txt");
                    if (!File.Exists(list))
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(list));
                        File.WriteAllLines(list, new[] { "# Skills listed here stay on this PC: Skills Sync never sends them for review.", "# One skill folder name per line." }, new UTF8Encoding(true));
                    }
                    Launch.Open("notepad.exe", list);
                    break;
                case "OpenLogFolder": Launch.Open("explorer.exe", Path.Combine(Paths.LocalAppData, "AutodeskMcpConnector")); break;
                case "CopyDiagnostics":
                    Clipboard.SetText(DiagnosticsText());
                    MessageBox.Show(_form, "The diagnostics summary is copied. Paste it into an email or chat to your administrator. It contains no passwords or tokens.", "Smart Connector", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    break;
                case "Repair": StartRepair(); break;
            }
        }

        private void SetSyncReminder(bool on)
        {
            int code;
            if (File.Exists(Launch.InstalledProgram)) code = Launch.HiddenWait(Launch.InstalledProgram, "skills sync --action " + (on ? "Enable" : "Disable"));
            else code = Launch.HiddenWait(Launch.PowerShell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Launch.Quote(Launch.ConnectorScript("weekly-skill-collection.ps1")) + " -Action " + (on ? "Enable" : "Disable"));
            if (code != 0) MessageBox.Show(_form, "The setting could not be saved. Try again, or open Diagnostics.", "Smart Connector", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        // When the app opens: look for an update in the background (at most once a day, unless switched off).
        private void StartOpenCheck()
        {
            Snapshot s = ConnectorStatus.Take();
            if (!ConnectorStatus.UpdateCheckDue(s, ConnectorStatus.Today)) return;
            ConnectorStatus.WriteDay(ConnectorStatus.OpenCheckPath);
            try { _check = Launch.CoreHidden(Launch.InstallerScript("Setup-BimCad.ps1"), new[] { "-Action", "CheckUpdate", "-RepositoryPath", Paths.Root }); }
            catch (Exception) { }
        }

        private void SetAutoUpdates(bool on)
        {
            int code = Launch.CoreWait(Launch.InstallerScript("Setup-BimCad.ps1"), new[] { "-Action", on ? "EnableNotifications" : "DisableNotifications", "-RepositoryPath", Paths.Root });
            if (code != 0) MessageBox.Show(_form, "The setting could not be saved. Try again, or open Diagnostics.", "Smart Connector", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        private static string YesNo(bool value) { return value ? "yes" : "no"; }

        internal static string DiagnosticsText()
        {
            Snapshot s = ConnectorStatus.Take();
            return String.Join("\r\n", new[]
            {
                "Smart Connector " + s.Version + " diagnostics, " + DateTime.Now.ToString("yyyy-MM-dd HH:mm"),
                "Computer: " + Env.Variable("COMPUTERNAME") + "   Windows user: " + Env.Variable("USERNAME"),
                "Revit 2024 installed: " + YesNo(s.RevitInstalled) + "   add-in: " + YesNo(s.RevitAddin) + "   running: " + YesNo(s.RevitRunning),
                "AutoCAD releases: " + (s.AutoCadReleases.Length > 0 ? String.Join(", ", s.AutoCadReleases) : "none") + "   panel: " + YesNo(s.AutoCadPanel) + "   running: " + YesNo(s.AutoCadRunning),
                "Claude Desktop installed: " + YesNo(s.ClaudeDesktop.Installed) + "   connected: " + YesNo(s.ClaudeDesktop.Connected),
                "Claude Code installed: " + YesNo(s.ClaudeCode.Installed) + "   connected: " + YesNo(s.ClaudeCode.Connected),
                "Codex installed: " + YesNo(s.Codex.Installed) + "   connected: " + YesNo(s.Codex.Connected),
                "Team skill service joined: " + YesNo(s.TeamJoined) + "   update checks: " + YesNo(s.AutoUpdates) + "   weekly sync reminder: " + YesNo(s.SyncReminder),
                "Update ready: " + (s.AvailableVersion.Length > 0 ? s.AvailableVersion : "none") + "   last checked: " + s.LastChecked,
                "Last Skills Sync: " + s.LastSync + "   result: " + s.LastSyncStatus + "   " + s.LastSyncReason
            });
        }

        // Repair: setup again with the same choices, its output shown in the Components section.
        private void StartRepair()
        {
            if (_repair != null) return;
            _repair = Launch.CoreRedirected(Launch.InstallerScript("Setup-BimCad.ps1"), new[] { "-Action", "Install", "-RepositoryPath", Paths.Root }, null);
            _repairOut = _repair.StandardOutput.ReadLineAsync();
            _repairErr = _repair.StandardError.ReadLineAsync();
            _repairLines.Clear(); _repairLines.Add("Repair started...");
            RequestSection("Components");
        }

        private void UpdateRepair()
        {
            if (_repair == null) return;
            for (int pass = 0; pass < 2; pass++)
            {
                bool output = pass == 0;
                Task<string> task = output ? _repairOut : _repairErr;
                while (task != null && task.IsCompleted)
                {
                    string line = task.Result;
                    if (line == null) { task = null; break; }
                    if (!Regex.IsMatch(line, @"^\[(PHASE|RESULT)\]", RegexOptions.IgnoreCase)) _repairLines.Add(line);
                    task = (output ? _repair.StandardOutput : _repair.StandardError).ReadLineAsync();
                }
                if (output) _repairOut = task; else _repairErr = task;
            }
            if (_repair.HasExited && _repairOut == null && _repairErr == null)
            {
                _repairLines.Add(_repair.ExitCode == 0 ? "Repair finished. Restart Revit, AutoCAD, Claude and Codex." : "Repair finished with problems. Open the setup log in Diagnostics.");
                _repair.Dispose(); _repair = null;
            }
            if (_section == "Components" && _repairBox != null)
            {
                _repairBox.Lines = _repairLines.ToArray();
                _repairBox.SelectionStart = _repairBox.TextLength; _repairBox.ScrollToCaret();
            }
        }

        // Section changes requested from inside the content run after the click finishes: rebuilding the section
        // disposes the very control whose click handler is still running.
        private void RequestSection(string name)
        {
            _pending = name;
            _form.BeginInvoke((MethodInvoker)delegate { if (_pending != null) { string next = _pending; _pending = null; ShowSection(next); } });
        }

        private static string FormatWhen(string value, bool utc = false)
        {
            try { DateTime when = DateTime.Parse(value); if (utc) when = when.ToLocalTime(); return when.ToString("g"); }
            catch (Exception) { return value; }
        }

        // ---------- layout helpers (positions in 96-DPI units; the form scales them) ----------

        private static Label AddText(Control parent, string text, int x, int y, int width = 0, float size = 10, bool bold = false, bool muted = false, Color? color = null)
        {
            Label label = Brand.NewLabel(text, x, y, width, size, muted, bold);
            if (color.HasValue) label.ForeColor = color.Value;
            label.BackColor = Color.Transparent;
            parent.Controls.Add(label);
            return label;
        }

        private Button AddActionButton(Control parent, string text, string action, int x, int y, bool primary = false, int width = 0)
        {
            if (width <= 0) using (Font font = Brand.Font(10)) width = Math.Max(96, TextRenderer.MeasureText(text, font).Width + 32);
            Button button = Brand.NewButton(text, primary, width);
            button.Height = 32; button.Location = new Point(x, y); button.Tag = action;
            button.Click += delegate { Invoke(action); };
            parent.Controls.Add(button);
            return button;
        }

        private void AddSectionLink(Control parent, string text, string target, int x, int y)
        {
            LinkLabel link = new LinkLabel();
            link.Text = text; link.AutoSize = true; link.Location = new Point(x, y);
            link.LinkColor = Brand.Link; link.ActiveLinkColor = Brand.Header; link.BackColor = Color.Transparent; link.Tag = target;
            link.LinkClicked += delegate { RequestSection(target); };
            parent.Controls.Add(link);
        }

        private static void AddBadge(Control parent, string text, string kind, int x, int y, bool alignRight = false)
        {
            Badge badge = new Badge(text, kind);
            badge.Location = new Point(alignRight ? x - Brand.Round(badge.Width / Brand.Scale()) : x, y);
            parent.Controls.Add(badge);
        }

        // A row inside a card: icon, title and detail, a status badge on the right, optionally a button.
        private void AddStatusRow(Control card, int y, string icon, string title, string detail, string status, string kind, string buttonText = "", string action = "")
        {
            card.Controls.Add(Brand.IconBox(icon, 22, 18, y + 14));
            AddText(card, title, 54, y + 8, 0, 10, true);
            AddText(card, detail, 54, y + 30, 470, 9, false, true);
            int right = 812;
            if (buttonText.Length > 0) { AddActionButton(card, buttonText, action, 704, y + 12, false, 92); right = 692; }
            AddBadge(card, status, kind, right, y + 16, true);
            if (y > 0)
            {
                Panel line = new Panel(); line.BackColor = Brand.Line; line.Height = 1; line.Width = 800;
                line.Location = new Point(16, y); card.Controls.Add(line);
            }
        }

        private void AddHeading(string title, string text)
        {
            AddText(_content, title, 32, 24, 0, 16, true);
            if (text.Length > 0) AddText(_content, text, 33, 58, 780, 10, false, true);
        }

        private static string[] ClientStatus(Client client)
        {
            if (client.Connected) return new[] { "Connected", "Good" };
            if (client.Installed) return new[] { "Not connected", "Warn" };
            return new[] { "Not installed", "Off" };
        }

        private Card AddCard(int x, int y, int width, int height)
        {
            Card card = new Card(x, y, width, height); _content.Controls.Add(card);
            return card;
        }

        // ---------- sections ----------

        private void ShowOverview(Snapshot s)
        {
            Headline headline = ConnectorStatus.HeadlineOf(s);
            Card hero = AddCard(32, 24, 832, 92);
            string icon = headline.Kind == "Good" ? "check" : headline.Kind == "Bad" ? "error" : "warning";
            hero.Controls.Add(Brand.IconBox(icon, 28, 22, 30, Brand.Status[headline.Kind][1]));
            AddText(hero, headline.Title, 66, 20, 0, 13, true);
            AddText(hero, headline.Text, 67, 50, 480, 10, false, true);
            AddActionButton(hero, "Check for updates", "CheckUpdates", 548, 30, false, 140);
            AddActionButton(hero, "Skills Sync", "SkillsSync", 698, 30, true, 116);
            // Reminders: a new version is ready, or the weekly Skills Sync is due.
            string[] reminder = null;
            if (s.AvailableVersion.Length > 0 && CompareVersion(s.AvailableVersion, s.Version) > 0)
                reminder = new[] { "updates", "Smart Connector " + s.AvailableVersion + " is ready to install.", "Update now", "UpdateNow" };
            else if (ConnectorStatus.SyncReminderDue(s, ConnectorStatus.Today))
            {
                string days = s.LastSyncDay < 0 ? "Skills have not been synced on this computer yet." : "Your last Skills Sync was " + (int)Math.Floor(ConnectorStatus.Today - s.LastSyncDay) + " days ago.";
                reminder = new[] { "sync", days + " Sync to send your saved skills for review and get newly approved ones.", "Sync now", "SkillsSync" };
            }
            int top = 136;
            if (reminder != null)
            {
                Card strip = AddCard(32, 128, 832, 52);
                strip.Controls.Add(Brand.IconBox(reminder[0], 18, 16, 17));
                AddText(strip, reminder[1], 48, 16, 620);
                AddActionButton(strip, reminder[2], reminder[3], 698, 9, true, 116);
                top = 196;
            }

            string[] revit = s.RevitAddin ? new[] { "Ready", "Good" } : s.RevitInstalled ? new[] { "Add-in missing", "Warn" } : new[] { "Not installed", "Off" };
            string[] autoCad = s.AutoCadPanel ? new[] { "Ready", "Good" } : s.AutoCadInstalled ? new[] { "Panel missing", "Warn" } : new[] { "Not installed", "Off" };
            string[] claude = s.ClaudeDesktop.Connected || s.ClaudeCode.Connected ? new[] { "Connected", "Good" } : s.ClaudeDesktop.Installed || s.ClaudeCode.Installed ? new[] { "Not connected", "Warn" } : new[] { "Not installed", "Off" };
            string[] updates = s.AvailableVersion.Length > 0 && s.AvailableVersion != s.Version ? new[] { s.AvailableVersion + " ready", "Info" } : new[] { "Up to date", "Good" };
            object[][] cards =
            {
                new object[] { "Revit 2024", "revit", revit, (s.RevitRunning ? "Revit is open." : "Revit is closed.") + "\n" + (s.RevitAddin ? "Smart Connector tab installed." : "No add-in for this user."), "Autodesk" },
                new object[] { "AutoCAD", "autocad", autoCad, (s.AutoCadRunning ? "AutoCAD is open." : "AutoCAD is closed.") + "\nAdd-ins panel with AI Markup.", "Autodesk" },
                new object[] { "Claude", "claude", claude, "Claude Desktop: " + ClientStatus(s.ClaudeDesktop)[0].ToLower() + "\nClaude Code: " + ClientStatus(s.ClaudeCode)[0].ToLower(), "AI" },
                new object[] { "Codex", "codex", ClientStatus(s.Codex), (s.Codex.Installed ? "Codex uses the connector tools." : "Install Codex, then choose Repair.") + "\n ", "AI" },
                new object[] { "Workflow skills", "skills", new[] { ConnectorStatus.InstalledWorkflowSkills().Count + " installed", "Good" },
                    (s.LastSync.Length > 0 ? "Last sync " + FormatWhen(s.LastSync) : "Not synced yet.") + "\n" + (s.TeamJoined ? "Joined to the team skill service." : "Not joined to the team."), "Skills" },
                new object[] { "Updates", "updates", updates, "Version " + s.Version + "\n" + (s.AutoUpdates ? "Checked when Revit, AutoCAD or this app opens." : "Update checks are off."), "Updates" }
            };
            for (int i = 0; i < cards.Length; i++)
            {
                object[] spec = cards[i];
                string[] status = (string[])spec[2];
                Card card = AddCard(32 + (i % 3) * 284, top + (i / 3) * 168, 264, 152);
                card.Controls.Add(Brand.IconBox((string)spec[1], 22, 16, 18));
                AddText(card, (string)spec[0], 48, 18, 0, 10, true);
                AddBadge(card, status[0], status[1], 16, 52);
                AddText(card, (string)spec[3], 16, 86, 236, 9, false, true);
                AddSectionLink(card, "Details", (string)spec[4], 16, 124);
            }
        }

        private void ShowAutodesk(Snapshot s)
        {
            AddHeading("Autodesk apps", "Smart Connector adds a tab to Revit and a panel to AutoCAD. Claude and Codex then work with the open model or drawing.");
            Card card = AddCard(32, 96, 832, 152);
            AddStatusRow(card, 0, "revit", "Revit 2024",
                !s.RevitInstalled ? "Not installed on this computer." : s.RevitAddin ? "Smart Connector tab installed" + (s.RevitRunning ? "; Revit is open." : ".") : "Installed, but the add-in is missing. Choose Repair in Components.",
                s.RevitAddin ? "Ready" : s.RevitInstalled ? "Add-in missing" : "Not installed", s.RevitAddin ? "Good" : s.RevitInstalled ? "Warn" : "Off");
            AddStatusRow(card, 76, "autocad", s.AutoCadReleases.Length > 0 ? "AutoCAD (" + String.Join(", ", s.AutoCadReleases) + ")" : "AutoCAD",
                !s.AutoCadInstalled ? "Not installed on this computer." : s.AutoCadPanel ? "Add-ins panel with AI Markup, Skills Sync and settings" + (s.AutoCadRunning ? "; AutoCAD is open." : ".") : "Installed, but the panel is missing. Choose Repair in Components.",
                s.AutoCadPanel ? "Ready" : s.AutoCadInstalled ? "Panel missing" : "Not installed", s.AutoCadPanel ? "Good" : s.AutoCadInstalled ? "Warn" : "Off");
            AddText(_content, "Revit 2025 and later are not supported yet. A program opened after setup needs a restart to show the connector.", 33, 264, 780, 9, false, true);
            AddActionButton(_content, "Test connection", "TestConnection", 32, 296, true, 140);
        }

        private void ShowAI(Snapshot s)
        {
            AddHeading("AI connections", "Setup adds Smart Connector to each AI app's own settings for this Windows user. Your other connectors are kept.");
            Card card = AddCard(32, 96, 832, 228);
            object[][] rows =
            {
                new object[] { "claude", "Claude Desktop", s.ClaudeDesktop, "Listed as \"Smart Connector\" in its connectors." },
                new object[] { "claude", "Claude Code", s.ClaudeCode, "User-level MCP server named autodesk." },
                new object[] { "codex", "Codex", s.Codex, "MCP server named autodesk in config.toml." }
            };
            for (int i = 0; i < rows.Length; i++)
            {
                Client client = (Client)rows[i][2];
                string[] status = ClientStatus(client);
                string detail = client.Connected ? (string)rows[i][3] : client.Installed ? "Installed but not connected. Choose Repair." : "Not installed. It connects when you install it and choose Repair.";
                AddStatusRow(card, i * 76, (string)rows[i][0], (string)rows[i][1], detail, status[0], status[1]);
            }
            AddText(_content, "After connecting, restart Claude and Codex so they load the connector.", 33, 340, 780, 9, false, true);
            AddActionButton(_content, "Test connection", "TestConnection", 32, 372, true, 140);
            AddActionButton(_content, "Repair connections", "Repair", 182, 372, false, 160);
        }

        private void ShowSkills(Snapshot s)
        {
            List<InstalledSkill> skills = ConnectorStatus.InstalledWorkflowSkills();
            AddHeading("Workflow skills", skills.Count + " approved skills are installed for Claude and Codex. Skills Sync sends your saved skills for review and downloads newly approved ones.");
            AddActionButton(_content, "Skills Sync", "SkillsSync", 32, 96, true, 116);
            AddActionButton(_content, "Open skills folder", "OpenSkillsFolder", 158, 96, false, 150);
            AddActionButton(_content, "Private skills", "PrivateSkills", 318, 96, false, 120);
            bool good = String.Equals(s.LastSyncStatus, "ok", StringComparison.OrdinalIgnoreCase) || String.Equals(s.LastSyncStatus, "completed", StringComparison.OrdinalIgnoreCase);
            string last = s.LastSync.Length > 0
                ? "Last sync " + FormatWhen(s.LastSync) + (good ? ": " + s.SyncSubmitted + " sent for review, " + s.SyncUpdated + " downloaded." : s.LastSyncReason.Length > 0 ? ": " + s.LastSyncReason : ".")
                : "Skills have not been synced on this computer yet.";
            AddText(_content, last, 33, 138, 780, 9, false, true);
            ListView list = new ListView();
            list.View = View.Details; list.FullRowSelect = true; list.HeaderStyle = ColumnHeaderStyle.Nonclickable; list.BorderStyle = BorderStyle.FixedSingle;
            list.Location = new Point(32, 166); list.Size = new Size(832, 400);
            list.Columns.Add("Skill", 520); list.Columns.Add("Category", 280);
            Dictionary<string, ListViewGroup> groups = new Dictionary<string, ListViewGroup>(StringComparer.OrdinalIgnoreCase);
            foreach (InstalledSkill skill in skills)
            {
                if (!groups.ContainsKey(skill.Category)) groups[skill.Category] = list.Groups.Add(skill.Category, skill.CategoryTitle);
                ListViewItem item = new ListViewItem(skill.Name, groups[skill.Category]);
                item.SubItems.Add(skill.CategoryTitle); list.Items.Add(item);
            }
            _content.Controls.Add(list);
        }

        private void ShowComponents(Snapshot s)
        {
            AddHeading("Components", "Everything Smart Connector installed for this Windows user. Repair runs setup again with your choices.");
            Card card = AddCard(32, 96, 832, 380);
            string[][] rows =
            {
                new[] { "connector", "Smart Connector", "Version " + s.Version, s.Installed ? "Installed" : "Missing", s.Installed ? "Good" : "Bad" },
                new[] { "revit", "Revit 2024 add-in", "Smart Connector tab in Revit", s.RevitAddin ? "Installed" : s.RevitInstalled ? "Missing" : "Not needed", s.RevitAddin ? "Good" : s.RevitInstalled ? "Warn" : "Off" },
                new[] { "autocad", "AutoCAD panel", "Add-ins tab buttons and AI Markup", s.AutoCadPanel ? "Installed" : s.AutoCadInstalled ? "Missing" : "Not needed", s.AutoCadPanel ? "Good" : s.AutoCadInstalled ? "Warn" : "Off" },
                new[] { "team", "Team skill service", "Shares your saved skills for review", s.TeamJoined ? "Joined" : "Not joined", s.TeamJoined ? "Good" : "Off" },
                new[] { "updates", "Update checks", "When Revit, AutoCAD or this app opens. Nothing runs in the background.", s.AutoUpdates ? "On" : "Off", s.AutoUpdates ? "Good" : "Off" }
            };
            for (int i = 0; i < rows.Length; i++) AddStatusRow(card, i * 76, rows[i][0], rows[i][1], rows[i][2], rows[i][3], rows[i][4]);
            AddActionButton(_content, _repair != null ? "Repairing..." : "Repair", "Repair", 32, 492, true, 116);
            _repairBox = new TextBox();
            _repairBox.Multiline = true; _repairBox.ReadOnly = true; _repairBox.ScrollBars = ScrollBars.Vertical;
            _repairBox.Font = Brand.Font(8.5f, FontStyle.Regular, "Consolas"); _repairBox.BackColor = Brand.Canvas;
            _repairBox.Location = new Point(32, 534); _repairBox.Size = new Size(832, 110);
            _repairBox.Visible = _repairLines.Count > 0;
            _repairBox.Lines = _repairLines.ToArray();
            _content.Controls.Add(_repairBox);
        }

        private void ShowUpdates(Snapshot s)
        {
            AddHeading("Updates", "Smart Connector looks for a new version once a day, when you open Revit, AutoCAD or this app, and asks before installing. Updates install when Revit and AutoCAD are closed.");
            Card card = AddCard(32, 96, 832, 152);
            bool ready = s.AvailableVersion.Length > 0 && CompareVersion(s.AvailableVersion, s.Version) > 0;
            AddStatusRow(card, 0, "connector", "Installed version " + s.Version, s.LastChecked.Length > 0 ? "Last checked " + FormatWhen(s.LastChecked, true) : "Not checked yet.", ready ? s.AvailableVersion + " ready" : "Up to date", ready ? "Info" : "Good");
            AddStatusRow(card, 76, "updates", "Update checks", s.AutoUpdates ? "On: you are asked when a new version is ready." : "Off: use Check for updates.", s.AutoUpdates ? "On" : "Off", s.AutoUpdates ? "Good" : "Off");
            AddActionButton(_content, "Check for updates", "CheckUpdates", 32, 264, false, 140);
            if (ready) AddActionButton(_content, "Update now", "UpdateNow", 182, 264, true, 116);
        }

        private void ShowSettings(Snapshot s)
        {
            AddHeading("Settings", "Changes apply to this Windows user.");
            CheckBox auto = new CheckBox();
            auto.Text = "Check for updates when Revit, AutoCAD or Smart Connector opens (recommended)"; auto.AutoSize = true; auto.Checked = s.AutoUpdates;
            auto.Font = Brand.Semibold(10.5f); auto.Location = new Point(32, 100);
            auto.Click += delegate { auto.Enabled = false; SetAutoUpdates(auto.Checked); RequestSection("Settings"); };
            _content.Controls.Add(auto);
            AddText(_content, "At most once a day. You are asked before anything is installed, and it installs when Revit and AutoCAD are closed. When this is off, use Check for updates.", 52, 130, 760, 9, false, true);
            CheckBox remind = new CheckBox();
            remind.Text = "Remind me weekly to sync my skills"; remind.AutoSize = true; remind.Checked = s.SyncReminder; remind.Enabled = s.TeamJoined;
            remind.Font = Brand.Semibold(10.5f); remind.Location = new Point(32, 166);
            remind.Click += delegate { remind.Enabled = false; SetSyncReminder(remind.Checked); RequestSection("Settings"); };
            _content.Controls.Add(remind);
            AddText(_content, s.TeamJoined ? "When your last Skills Sync is more than a week old, Revit, AutoCAD and this app remind you once a day." : "Available once this computer has joined the team skill service.", 52, 196, 760, 9, false, true);
            AddText(_content, "Private skills", 32, 242, 0, 10, true);
            AddText(_content, "Skills on this list stay on your computer: Skills Sync never sends them for review.", 32, 266, 760, 9, false, true);
            AddActionButton(_content, "Edit private skills", "PrivateSkills", 32, 294, false, 150);
            AddText(_content, "Team skill service", 32, 350, 0, 10, true);
            AddText(_content, s.TeamJoined ? "This computer has joined. Your administrator sees its name, your name and email, and which skills and tools are used (names and counts only). Usage counts are sent only when you run Skills Sync." : "Not joined. Ask your administrator for the team setup file to join.", 32, 374, 760, 9, false, true);
        }

        private void ShowDiagnostics(Snapshot s)
        {
            AddHeading("Diagnostics and logs", "When something does not work, copy the summary and send it to your administrator with the log they ask for.");
            AddActionButton(_content, "Copy diagnostics summary", "CopyDiagnostics", 32, 96, true, 200);
            AddActionButton(_content, "Open log folder", "OpenLogFolder", 242, 96, false, 140);
            TextBox summary = new TextBox();
            summary.Multiline = true; summary.ReadOnly = true; summary.ScrollBars = ScrollBars.Vertical; summary.BackColor = Brand.Canvas;
            summary.Font = Brand.Font(9, FontStyle.Regular, "Consolas"); summary.Location = new Point(32, 142); summary.Size = new Size(832, 200);
            summary.Text = DiagnosticsText();
            _content.Controls.Add(summary);
            int y = 362;
            foreach (string[] log in Logs)
            {
                string path = Path.Combine(Paths.LocalAppData, log[1]);
                if (File.Exists(path) || Directory.Exists(path))
                {
                    LinkLabel link = new LinkLabel();
                    link.Text = log[0]; link.AutoSize = true; link.Location = new Point(32, y); link.LinkColor = Brand.Link; link.Tag = path;
                    link.LinkClicked += delegate { Launch.Open("notepad.exe", path); };
                    _content.Controls.Add(link);
                }
                else AddText(_content, log[0] + " (not created yet)", 32, y, 0, 10, false, true);
                y += 28;
            }
        }

        private void ShowHelp(Snapshot s)
        {
            AddHeading("Help", "Smart Connector " + s.Version + " connects Claude and Codex to Revit and AutoCAD on this computer.");
            string[][] topics =
            {
                new[] { "In Revit", "Open a model, then ask Claude or Codex to work with it. The Smart Connector tab has Connect, Status, Skills Sync and a More menu for updates, settings and help." },
                new[] { "In AutoCAD", "Open a drawing and use the Add-ins tab. AI Markup lets you sketch on the drawing and type a task; paste the copied request into Claude. Clear Markup removes it." },
                new[] { "Workflow skills", "Approved team workflows are installed for Claude and Codex. Save your own skills as usual; Skills Sync sends them to your administrator for review." },
                new[] { "Updates", "Once a day, opening Revit, AutoCAD or this app looks for a new version and asks you. Choose Update now, save your work and close Revit and AutoCAD; the update window installs it." },
                new[] { "Something is wrong", "Open Diagnostics, copy the summary and send it to your administrator. Repair in Components fixes most connection problems." }
            };
            int y = 100;
            foreach (string[] topic in topics)
            {
                AddText(_content, topic[0], 32, y, 0, 10, true);
                Label text = AddText(_content, topic[1], 32, y + 24, 800, 10, false, true);
                y += 34 + Brand.Round(text.PreferredHeight / Brand.Scale()) + 14;
            }
        }

        // ---------- window ----------

        private void ShowSection(string name)
        {
            if (!Sections.Any(s => s[0] == name)) name = "Overview";
            _section = name;
            _snapshot = ConnectorStatus.Take();
            foreach (Button button in _navButtons)
            {
                bool on = (string)button.Tag == name;
                button.BackColor = on ? Color.FromArgb(36, 55, 90) : Brand.Header;
                button.ForeColor = on ? Color.White : Brand.RailText;
                button.Font = on ? Brand.Semibold(10) : Brand.Font(10);
            }
            _content.SuspendLayout();
            Control[] old = _content.Controls.Cast<Control>().ToArray(); _content.Controls.Clear(); foreach (Control control in old) control.Dispose();
            _repairBox = null;
            switch (name)
            {
                case "Overview": ShowOverview(_snapshot); break;
                case "Autodesk": ShowAutodesk(_snapshot); break;
                case "AI": ShowAI(_snapshot); break;
                case "Skills": ShowSkills(_snapshot); break;
                case "Components": ShowComponents(_snapshot); break;
                case "Updates": ShowUpdates(_snapshot); break;
                case "Settings": ShowSettings(_snapshot); break;
                case "Diagnostics": ShowDiagnostics(_snapshot); break;
                case "Help": ShowHelp(_snapshot); break;
            }
            _content.ResumeLayout();
            _form.Text = "Smart Connector - " + Sections.First(s => s[0] == name)[1];
        }

        private int Show(string section, bool smokeTest)
        {
            _section = section;
            _form = Brand.NewForm(Brand.Name, 1120, 720);
            _form.Text = "Smart Connector";
            _form.FormBorderStyle = FormBorderStyle.Sizable; _form.MaximizeBox = true;
            _form.MinimumSize = new Size(980, 640);
            _form.BackColor = Brand.Canvas;

            _content = new Panel();
            _content.Dock = DockStyle.Fill; _content.AutoScroll = true; _content.BackColor = Brand.Canvas;
            _form.Controls.Add(_content);

            Panel nav = new Panel();
            nav.Dock = DockStyle.Left; nav.Width = 224; nav.BackColor = Brand.Header;
            _form.Controls.Add(nav);
            PictureBox brand = new PictureBox();
            brand.Image = Brand.Logo(64); brand.SizeMode = PictureBoxSizeMode.Zoom; brand.Size = new Size(36, 36); brand.Location = new Point(18, 18);
            nav.Controls.Add(brand);
            Label title = Brand.NewLabel("Smart Connector", 62, 26, 0, 11, false, true); title.ForeColor = Color.White; nav.Controls.Add(title);
            int y = 76;
            foreach (string[] spec in Sections)
            {
                Button button = new Button();
                button.Text = "   " + spec[1]; button.Tag = spec[0];
                button.FlatStyle = FlatStyle.Flat; button.FlatAppearance.BorderSize = 0;
                button.FlatAppearance.MouseOverBackColor = Color.FromArgb(30, 46, 76);
                button.TextAlign = ContentAlignment.MiddleLeft; button.ImageAlign = ContentAlignment.MiddleLeft; button.TextImageRelation = TextImageRelation.ImageBeforeText;
                button.Image = Brand.IconImage(spec[2], 18, Color.FromArgb(200, 212, 230));
                button.Padding = new Padding(12, 0, 0, 0);
                button.Size = new Size(208, 40); button.Location = new Point(8, y);
                button.Cursor = Cursors.Hand;
                string key = spec[0];
                button.Click += delegate { ShowSection(key); };
                nav.Controls.Add(button); _navButtons.Add(button);
                y += 42;
            }
            string versionPath = Path.Combine(Paths.Root, "VERSION");
            Label footer = Brand.NewLabel("Version " + (File.Exists(versionPath) ? File.ReadAllText(versionPath).Trim() : "") + "\n" + Env.Variable("COMPUTERNAME"), 18, 612, 0, 8.5f);
            footer.ForeColor = Brand.RailMuted; footer.Anchor = AnchorStyles.Bottom | AnchorStyles.Left; nav.Controls.Add(footer);

            if (smokeTest)
            {
                foreach (string[] spec in Sections) ShowSection(spec[0]);
                _form.Dispose();
                return 0;
            }

            // Timer: Repair output, requests from a second start, and a light refresh of the Overview.
            Timer timer = new Timer();
            timer.Interval = 500;
            timer.Tick += delegate
            {
                try
                {
                    UpdateRepair();
                    // The update check started on opening has finished: show its result.
                    if (_check != null && _check.HasExited)
                    {
                        _check.Dispose(); _check = null;
                        if (_section == "Overview" || _section == "Updates") ShowSection(_section);
                    }
                    if (File.Exists(RequestPath))
                    {
                        string requested = File.ReadAllText(RequestPath).Trim();
                        File.Delete(RequestPath);
                        if (_form.WindowState == FormWindowState.Minimized) _form.WindowState = FormWindowState.Normal;
                        _form.Activate(); ShowSection(requested);
                    }
                    _ticks++;
                    if (_section == "Overview" && _ticks % 60 == 0) ShowSection("Overview");
                }
                catch (Exception) { }
            };
            _form.Shown += delegate { _form.Activate(); timer.Start(); try { StartOpenCheck(); } catch (Exception) { } };
            ShowSection(section);
            _form.ShowDialog();
            timer.Stop(); _form.Dispose();
            return 0;
        }
    }
}
