using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using Autodesk.Revit.Attributes;
using Autodesk.Revit.DB;
using Autodesk.Revit.UI;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;
using Media = System.Windows.Media;

// Smart Autodesk Connector ribbon and dialogs. C# 5 only: the add-in is compiled on each PC with
// the .NET Framework compiler that ships with Windows.
namespace BimCadMcp.Revit
{
    internal static class Brand
    {
        internal const string Name = "Smart Autodesk Connector";
        internal static readonly Drawing.Color Header = Drawing.Color.FromArgb(22, 36, 61);
        internal static readonly Drawing.Color Teal = Drawing.Color.FromArgb(32, 201, 171);
        internal static readonly Drawing.Color Blue = Drawing.Color.FromArgb(47, 128, 237);
        internal static readonly Drawing.Color Text = Drawing.Color.FromArgb(29, 35, 41);
        internal static readonly Drawing.Color Muted = Drawing.Color.FromArgb(95, 107, 119);
        internal static readonly Drawing.Color Good = Drawing.Color.FromArgb(31, 122, 61);
        internal static readonly Drawing.Color Bad = Drawing.Color.FromArgb(180, 35, 24);
    }

    // Locates the installed connector and its per-user state files.
    internal static class Connector
    {
        internal static string LocalAppData { get { return Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData); } }
        internal static string StateRoot { get { return Path.Combine(LocalAppData, "AutodeskMcpSkillCollection"); } }
        internal static string ConnectorState { get { return Path.Combine(LocalAppData, "AutodeskMcpConnector"); } }
        internal static string UpdateStatePath { get { return Path.Combine(ConnectorState, "update-state.json"); } }
        internal static string UpdateRequestPath { get { return Path.Combine(ConnectorState, "update-requested.flag"); } }

        internal static string FindRoot()
        {
            string directory = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            for (int index = 0; index < 8 && !String.IsNullOrWhiteSpace(directory); index++)
            {
                if (File.Exists(Path.Combine(directory, "installer", "Setup-BimCad.ps1"))) return directory;
                DirectoryInfo parent = Directory.GetParent(directory);
                directory = parent == null ? null : parent.FullName;
            }
            string defaultRoot = Path.Combine(LocalAppData, "BIM-CAD-MCP");
            if (File.Exists(Path.Combine(defaultRoot, "installer", "Setup-BimCad.ps1"))) return defaultRoot;
            throw new DirectoryNotFoundException("The Smart Autodesk Connector installation folder could not be found. Run the installer again.");
        }

        // Scripts copied to the state folder keep working while an update replaces the install folder.
        internal static string Script(string name)
        {
            string stateCopy = Path.Combine(StateRoot, "scripts", name);
            if (File.Exists(stateCopy)) return stateCopy;
            return Path.Combine(FindRoot(), "scripts", name);
        }

        internal static string PowerShell
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"); }
        }

        internal static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }

        // Small JSON reader for flat files written by ConvertTo-Json; avoids an extra assembly reference.
        internal static string ReadJsonValue(string path, string key)
        {
            try
            {
                if (!File.Exists(path)) return "";
                string text = File.ReadAllText(path);
                Match match = Regex.Match(text, "\"" + Regex.Escape(key) + "\"\\s*:\\s*(\"(?<s>(?:[^\"\\\\]|\\\\.)*)\"|(?<v>-?\\d+(?:\\.\\d+)?|true|false|null))");
                if (!match.Success) return "";
                if (match.Groups["s"].Success) return Regex.Unescape(match.Groups["s"].Value);
                return match.Groups["v"].Value == "null" ? "" : match.Groups["v"].Value;
            }
            catch (Exception) { return ""; }
        }

        internal static void StartHidden(string script, string arguments)
        {
            ProcessStartInfo info = new ProcessStartInfo(PowerShell,
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " + Quote(script) + " " + arguments);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WorkingDirectory = LocalAppData;
            Process.Start(info);
        }

        // The agent is single-instance; starting it when it already runs is harmless.
        internal static void EnsureAgentRunning()
        {
            try
            {
                string agent = Script("connector-agent.ps1");
                if (!File.Exists(agent)) return;
                StartHidden(agent, "-Action Run -StateRoot " + Quote(StateRoot) + " -InstallRoot " + Quote(FindRoot()));
            }
            catch (Exception exception) { Debug.WriteLine("Smart Autodesk Connector agent start failed: " + exception.Message); }
        }
    }

    // Runs one hidden PowerShell step while a branded dialog shows progress, then shows the result.
    internal sealed class TaskWindow : Forms.Form
    {
        private readonly Forms.Label _title = new Forms.Label();
        private readonly Forms.Label _body = new Forms.Label();
        private readonly Forms.ProgressBar _progress = new Forms.ProgressBar();
        private readonly Forms.FlowLayoutPanel _buttons = new Forms.FlowLayoutPanel();
        private readonly Forms.Timer _timer = new Forms.Timer();
        private Process _process;
        private System.Threading.Tasks.Task<string> _output;
        private Action<string, int> _onFinished;
        private DateTime _started;
        private int _backgroundAfterSeconds;
        private string _backgroundTitle, _backgroundBody;
        internal readonly Forms.CheckBox Option = new Forms.CheckBox();

        // After this long the window says the step continues in the background and can be closed;
        // the step keeps running and the connector agent shows a notice when it finishes.
        internal void ContinueInBackgroundAfter(int seconds, string title, string body)
        {
            _backgroundAfterSeconds = seconds; _backgroundTitle = title; _backgroundBody = body;
        }

        internal TaskWindow(string caption)
        {
            Text = Brand.Name;
            FormBorderStyle = Forms.FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
            StartPosition = Forms.FormStartPosition.CenterParent;
            ClientSize = new Drawing.Size(500, 300);
            BackColor = Drawing.Color.White;
            Font = new Drawing.Font("Segoe UI", 10f);

            Forms.Panel header = new Forms.Panel();
            header.Dock = Forms.DockStyle.Top; header.Height = 64; header.BackColor = Brand.Header;
            Forms.PictureBox logo = new Forms.PictureBox();
            logo.Image = Icons.LogoBitmap(40); logo.SizeMode = Forms.PictureBoxSizeMode.Zoom;
            logo.Bounds = new Drawing.Rectangle(18, 12, 40, 40);
            Forms.Label name = new Forms.Label();
            name.Text = caption; name.ForeColor = Drawing.Color.White; name.AutoSize = true;
            name.Font = new Drawing.Font("Segoe UI Semibold", 13f, Drawing.FontStyle.Bold);
            name.Location = new Drawing.Point(70, 19);
            header.Controls.Add(logo); header.Controls.Add(name);
            Forms.Panel rule = new Forms.Panel();
            rule.Dock = Forms.DockStyle.Top; rule.Height = 3; rule.BackColor = Brand.Teal;

            _title.Font = new Drawing.Font("Segoe UI Semibold", 12f, Drawing.FontStyle.Bold);
            _title.ForeColor = Brand.Text; _title.AutoSize = true; _title.MaximumSize = new Drawing.Size(450, 0);
            _title.Location = new Drawing.Point(24, 88);
            _body.ForeColor = Brand.Text; _body.AutoSize = true; _body.MaximumSize = new Drawing.Size(450, 0);
            _body.Location = new Drawing.Point(24, 122);
            _progress.Style = Forms.ProgressBarStyle.Marquee; _progress.MarqueeAnimationSpeed = 30;
            _progress.Bounds = new Drawing.Rectangle(24, 200, 450, 8);
            Option.AutoSize = true; Option.Location = new Drawing.Point(24, 212); Option.Visible = false;
            _buttons.FlowDirection = Forms.FlowDirection.RightToLeft;
            _buttons.Bounds = new Drawing.Rectangle(0, 246, 488, 44);

            Controls.Add(_buttons); Controls.Add(Option); Controls.Add(_progress); Controls.Add(_body); Controls.Add(_title);
            Controls.Add(rule); Controls.Add(header);
            _timer.Interval = 250;
            _timer.Tick += delegate { Poll(); };
        }

        internal void Run(string title, string body, string script, string arguments, Action<string, int> onFinished)
        {
            _title.Text = title; _body.Text = body; _onFinished = onFinished;
            ProcessStartInfo info = new ProcessStartInfo(Connector.PowerShell,
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Connector.Quote(script) + " " + arguments);
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.RedirectStandardOutput = true; info.RedirectStandardError = true;
            info.WorkingDirectory = Connector.LocalAppData;
            _process = Process.Start(info);
            _output = _process.StandardOutput.ReadToEndAsync();
            _process.StandardError.ReadToEndAsync();
            _started = DateTime.UtcNow;
            _timer.Start();
        }

        private void Poll()
        {
            if (_process == null) return;
            if (!_process.HasExited || !_output.IsCompleted)
            {
                if (_backgroundAfterSeconds > 0 && (DateTime.UtcNow - _started).TotalSeconds >= _backgroundAfterSeconds)
                {
                    // Leave the process running; only this window stops watching it.
                    _timer.Stop();
                    _progress.Visible = false;
                    ShowResult(_backgroundTitle, _backgroundBody, Brand.Blue);
                    AddButton("Close", true, delegate { Close(); });
                }
                return;
            }
            _timer.Stop();
            _progress.Visible = false;
            int exitCode = _process.ExitCode;
            _process.Dispose(); _process = null;
            if (_onFinished != null) _onFinished(_output.Result, exitCode);
        }

        internal void ShowResult(string title, string body, Drawing.Color color)
        {
            _title.Text = title; _title.ForeColor = color; _body.Text = body; _progress.Visible = false;
        }

        internal void AddButton(string text, bool primary, Action onClick)
        {
            Forms.Button button = new Forms.Button();
            button.Text = text; button.AutoSize = true; button.MinimumSize = new Drawing.Size(110, 34);
            button.FlatStyle = Forms.FlatStyle.Flat; button.Margin = new Forms.Padding(0, 4, 12, 4);
            if (primary)
            {
                button.BackColor = Brand.Blue; button.ForeColor = Drawing.Color.White;
                button.FlatAppearance.BorderColor = Brand.Blue;
                button.Font = new Drawing.Font("Segoe UI Semibold", 10f, Drawing.FontStyle.Bold);
                AcceptButton = button;
            }
            else button.FlatAppearance.BorderColor = Drawing.Color.FromArgb(227, 231, 236);
            button.Click += delegate { onClick(); };
            _buttons.Controls.Add(button);
        }

        protected override void OnFormClosing(Forms.FormClosingEventArgs e)
        {
            // Let a running step finish in the background; its result is still saved to the log.
            _timer.Stop();
            base.OnFormClosing(e);
        }
    }

    internal static class Icons
    {
        private static Media.Brush Gradient()
        {
            Media.LinearGradientBrush brush = new Media.LinearGradientBrush(
                Media.Color.FromRgb(32, 201, 171), Media.Color.FromRgb(47, 128, 237), 45);
            brush.Freeze();
            return brush;
        }

        // Every button: the navy tile from the logo with a teal-to-blue glyph on top.
        private static Media.ImageSource Tile(Action<Media.DrawingContext, Media.Pen> glyph)
        {
            Media.DrawingGroup group = new Media.DrawingGroup();
            using (Media.DrawingContext context = group.Open())
            {
                context.DrawRoundedRectangle(new Media.SolidColorBrush(Media.Color.FromRgb(22, 36, 61)), null, new System.Windows.Rect(0, 0, 32, 32), 7, 7);
                Media.Pen pen = new Media.Pen(Gradient(), 2.8);
                pen.StartLineCap = Media.PenLineCap.Round; pen.EndLineCap = Media.PenLineCap.Round; pen.LineJoin = Media.PenLineJoin.Round;
                glyph(context, pen);
            }
            group.Freeze();
            Media.DrawingImage image = new Media.DrawingImage(group);
            image.Freeze();
            return image;
        }

        internal static Media.ImageSource Connection()
        {
            return Tile(delegate(Media.DrawingContext c, Media.Pen p)
            {
                // The logo's "S" connector with its two nodes.
                Media.StreamGeometry s = new Media.StreamGeometry();
                using (Media.StreamGeometryContext g = s.Open())
                {
                    g.BeginFigure(new System.Windows.Point(21.5, 9), false, false);
                    g.ArcTo(new System.Windows.Point(16, 16), new System.Windows.Size(6, 4.5), 0, true, Media.SweepDirection.Counterclockwise, true, false);
                    g.ArcTo(new System.Windows.Point(10.5, 23), new System.Windows.Size(6, 4.5), 0, true, Media.SweepDirection.Clockwise, true, false);
                }
                s.Freeze();
                c.DrawGeometry(null, p, s);
                c.DrawEllipse(new Media.SolidColorBrush(Media.Color.FromRgb(32, 201, 171)), null, new System.Windows.Point(22.5, 9), 3, 3);
                c.DrawEllipse(new Media.SolidColorBrush(Media.Color.FromRgb(47, 128, 237)), null, new System.Windows.Point(9.5, 23), 3, 3);
            });
        }

        internal static Media.ImageSource Update()
        {
            return Tile(delegate(Media.DrawingContext c, Media.Pen p)
            {
                c.DrawLine(p, new System.Windows.Point(16, 7.5), new System.Windows.Point(16, 19));
                c.DrawLine(p, new System.Windows.Point(11, 14.5), new System.Windows.Point(16, 19.5));
                c.DrawLine(p, new System.Windows.Point(21, 14.5), new System.Windows.Point(16, 19.5));
                c.DrawLine(p, new System.Windows.Point(9.5, 24.5), new System.Windows.Point(22.5, 24.5));
            });
        }

        internal static Media.ImageSource Sync()
        {
            return Tile(delegate(Media.DrawingContext c, Media.Pen p)
            {
                // Two arcs with arrow heads: upload saved skills, download approved ones.
                Media.StreamGeometry s = new Media.StreamGeometry();
                using (Media.StreamGeometryContext g = s.Open())
                {
                    g.BeginFigure(new System.Windows.Point(8.5, 14), false, false);
                    g.ArcTo(new System.Windows.Point(22.5, 11), new System.Windows.Size(7.5, 7.5), 0, false, Media.SweepDirection.Clockwise, true, false);
                    g.BeginFigure(new System.Windows.Point(23.5, 18), false, false);
                    g.ArcTo(new System.Windows.Point(9.5, 21), new System.Windows.Size(7.5, 7.5), 0, false, Media.SweepDirection.Clockwise, true, false);
                }
                s.Freeze();
                c.DrawGeometry(null, p, s);
                c.DrawLine(p, new System.Windows.Point(22.5, 11), new System.Windows.Point(23, 6.5));
                c.DrawLine(p, new System.Windows.Point(22.5, 11), new System.Windows.Point(18, 10.5));
                c.DrawLine(p, new System.Windows.Point(9.5, 21), new System.Windows.Point(9, 25.5));
                c.DrawLine(p, new System.Windows.Point(9.5, 21), new System.Windows.Point(14, 21.5));
            });
        }

        internal static Media.ImageSource Settings()
        {
            return Tile(delegate(Media.DrawingContext c, Media.Pen p)
            {
                // Slider-style settings mark: three lines with knobs.
                Media.Brush knob = new Media.SolidColorBrush(Media.Color.FromRgb(255, 255, 255));
                c.DrawLine(p, new System.Windows.Point(8, 10), new System.Windows.Point(24, 10));
                c.DrawLine(p, new System.Windows.Point(8, 16), new System.Windows.Point(24, 16));
                c.DrawLine(p, new System.Windows.Point(8, 22), new System.Windows.Point(24, 22));
                c.DrawEllipse(knob, null, new System.Windows.Point(19, 10), 2.6, 2.6);
                c.DrawEllipse(knob, null, new System.Windows.Point(12, 16), 2.6, 2.6);
                c.DrawEllipse(knob, null, new System.Windows.Point(17, 22), 2.6, 2.6);
            });
        }

        // The logo as a bitmap for WinForms dialogs, drawn with the same shapes as the ribbon icon.
        internal static Drawing.Bitmap LogoBitmap(int size)
        {
            Drawing.Bitmap bitmap = new Drawing.Bitmap(size, size);
            using (Drawing.Graphics g = Drawing.Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
                float k = size / 256f;
                g.ScaleTransform(k, k);
                using (Drawing.Drawing2D.GraphicsPath tile = new Drawing.Drawing2D.GraphicsPath())
                using (Drawing.SolidBrush navy = new Drawing.SolidBrush(Drawing.Color.FromArgb(28, 45, 76)))
                using (Drawing.Drawing2D.LinearGradientBrush gradient = new Drawing.Drawing2D.LinearGradientBrush(new Drawing.PointF(70, 60), new Drawing.PointF(186, 200), Brand.Teal, Brand.Blue))
                using (Drawing.Pen pen = new Drawing.Pen(gradient, 26f))
                using (Drawing.Drawing2D.GraphicsPath s = new Drawing.Drawing2D.GraphicsPath())
                {
                    tile.AddArc(8, 8, 104, 104, 180, 90); tile.AddArc(144, 8, 104, 104, 270, 90);
                    tile.AddArc(144, 144, 104, 104, 0, 90); tile.AddArc(8, 144, 104, 104, 90, 90); tile.CloseFigure();
                    g.FillPath(navy, tile);
                    pen.StartCap = Drawing.Drawing2D.LineCap.Round; pen.EndCap = Drawing.Drawing2D.LineCap.Round;
                    s.AddArc(76, 52, 104, 76, 330, -240); s.AddArc(76, 128, 104, 76, 270, 240);
                    g.DrawPath(pen, s);
                    using (Drawing.SolidBrush teal = new Drawing.SolidBrush(Brand.Teal)) g.FillEllipse(teal, 151, 49, 44, 44);
                    using (Drawing.SolidBrush blue = new Drawing.SolidBrush(Brand.Blue)) g.FillEllipse(blue, 61, 163, 44, 44);
                }
            }
            return bitmap;
        }
    }

    internal static class RibbonUi
    {
        internal const string TabName = Brand.Name;

        internal static void Create(UIControlledApplication application)
        {
            try
            {
                try { application.CreateRibbonTab(TabName); }
                catch (Autodesk.Revit.Exceptions.ArgumentException) { }

                RibbonPanel panel = application.GetRibbonPanels(TabName).FirstOrDefault(item => item.Name == "Connector");
                if (panel == null) panel = application.CreateRibbonPanel(TabName, "Connector");
                string assemblyPath = Assembly.GetExecutingAssembly().Location;

                Add(panel, assemblyPath, "BimCadMcpConnectionStatus", "Connection\nStatus", typeof(ConnectionStatusCommand),
                    "See whether Codex or Claude is connected to this Revit session.", Icons.Connection());
                Add(panel, assemblyPath, "BimCadMcpCheckUpdates", "Check\nUpdates", typeof(CheckUpdatesCommand),
                    "Check for a new version of Smart Autodesk Connector. Updates install by themselves when Revit and AutoCAD are closed.", Icons.Update());
                Add(panel, assemblyPath, "BimCadMcpSkillsSync", "Skills\nSync", typeof(SkillsSyncCommand),
                    "Send your saved skills for review and download the latest approved team skills.", Icons.Sync());
                Add(panel, assemblyPath, "BimCadMcpSettings", "Settings", typeof(SettingsCommand),
                    "Turn automatic updates on or off.", Icons.Settings());
            }
            catch (Exception exception)
            {
                Debug.WriteLine("Smart Autodesk Connector ribbon error: " + exception);
            }
        }

        private static void Add(RibbonPanel panel, string assemblyPath, string name, string text, Type command, string tip, Media.ImageSource icon)
        {
            PushButtonData data = new PushButtonData(name, text, assemblyPath, command.FullName);
            data.ToolTip = tip;
            data.LargeImage = icon;
            data.Image = icon;
            panel.AddItem(data);
        }
    }

    internal static class Owner
    {
        internal static Forms.IWin32Window Of(ExternalCommandData data)
        {
            return new WindowHandle(data.Application.MainWindowHandle);
        }

        private sealed class WindowHandle : Forms.IWin32Window
        {
            private readonly IntPtr _handle;
            internal WindowHandle(IntPtr handle) { _handle = handle; }
            public IntPtr Handle { get { return _handle; } }
        }
    }

    [Transaction(TransactionMode.Manual)]
    [Regeneration(RegenerationOption.Manual)]
    public sealed class CheckUpdatesCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData commandData, ref string message, ElementSet elements)
        {
            try
            {
                string root = Connector.FindRoot();
                using (TaskWindow window = new TaskWindow("Check Updates"))
                {
                    window.Run("Checking for updates…", "Looking for a newer approved version of Smart Autodesk Connector.",
                        Path.Combine(root, "installer", "Setup-BimCad.ps1"), "-Action CheckUpdate -RepositoryPath " + Connector.Quote(root),
                        delegate(string output, int code) { ShowOutcome(window, output, root); });
                    window.ShowDialog(Owner.Of(commandData));
                }
                return Result.Succeeded;
            }
            catch (Exception exception)
            {
                TaskDialog.Show(Brand.Name, exception.Message);
                return Result.Failed;
            }
        }

        private static void ShowOutcome(TaskWindow window, string output, string root)
        {
            string installed = Connector.ReadJsonValue(Connector.UpdateStatePath, "installed_version");
            string available = Connector.ReadJsonValue(Connector.UpdateStatePath, "available_version");
            bool userOff = Connector.ReadJsonValue(Connector.UpdateStatePath, "notifications_user_disabled") == "true";
            if (output.Contains("[UPDATE_AVAILABLE]"))
            {
                window.ShowResult("Version " + available + " is ready",
                    "You have version " + installed + ". The update installs by itself as soon as Revit and AutoCAD are closed, " +
                    "and takes about a minute. Choose Update now to install it the next time you close them, even if automatic updates are off.",
                    Brand.Blue);
                window.AddButton("Later", false, delegate { window.Close(); });
                window.AddButton("Update now", true, delegate
                {
                    Directory.CreateDirectory(Connector.ConnectorState);
                    File.WriteAllText(Connector.UpdateRequestPath, DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
                    Connector.EnsureAgentRunning();
                    window.ShowResult("Update scheduled", "Save your work and close Revit (and AutoCAD if it is open). " +
                        "The update then installs by itself and you will see a notice when it is done.", Brand.Good);
                });
            }
            else if (output.Contains("[UP_TO_DATE]"))
            {
                window.ShowResult("You're up to date", "Smart Autodesk Connector " + installed + " is the latest approved version.", Brand.Good);
                window.Option.Text = "Install updates automatically (recommended)";
                window.Option.Checked = !userOff;
                window.Option.Visible = true;
                window.AddButton("Close", true, delegate
                {
                    if (window.Option.Checked == userOff)
                        Connector.StartHidden(Path.Combine(root, "installer", "Setup-BimCad.ps1"),
                            (window.Option.Checked ? "-Action EnableNotifications" : "-Action DisableNotifications") + " -RepositoryPath " + Connector.Quote(root));
                    window.Close();
                });
            }
            else
            {
                window.ShowResult("Couldn't check right now",
                    "The update service could not be reached. Check the internet connection and try again later. Your connector keeps working.", Brand.Bad);
                window.AddButton("Close", true, delegate { window.Close(); });
            }
        }
    }

    [Transaction(TransactionMode.Manual)]
    [Regeneration(RegenerationOption.Manual)]
    public sealed class SkillsSyncCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData commandData, ref string message, ElementSet elements)
        {
            try
            {
                string runner = Connector.Script("weekly-skill-collection.ps1");
                using (TaskWindow window = new TaskWindow("Skills Sync"))
                {
                    Connector.EnsureAgentRunning();   // the agent announces the result if this window is closed first
                    window.ContinueInBackgroundAfter(15, "Syncing in the background",
                        "Skills Sync is still working. You can close this window and keep working; " +
                        "a Windows notification shows the result when it is done.");
                    window.Run("Syncing skills…", "Sending your saved skills for review and downloading the latest approved team skills.",
                        runner, "-Action Sync -StateRoot " + Connector.Quote(Connector.StateRoot),
                        delegate(string output, int code) { ShowOutcome(window, output); });
                    window.ShowDialog(Owner.Of(commandData));
                }
                return Result.Succeeded;
            }
            catch (Exception exception)
            {
                TaskDialog.Show(Brand.Name, exception.Message);
                return Result.Failed;
            }
        }

        private static void ShowOutcome(TaskWindow window, string output)
        {
            if (output.Contains("A collection run is already active."))
            {
                window.ShowResult("Skills Sync is already running",
                    "A sync started earlier is still working in the background. You will get a Windows notification when it is done.", Brand.Blue);
                window.AddButton("Close", true, delegate { window.Close(); });
                return;
            }
            string result = Path.Combine(Connector.StateRoot, "last-result.json");
            string status = Connector.ReadJsonValue(result, "sync_status");
            string reason = Connector.ReadJsonValue(result, "sync_reason");
            Func<string, int> number = delegate(string key)
            {
                int value; return Int32.TryParse(Connector.ReadJsonValue(result, key), out value) ? value : 0;
            };
            if (status == "ok" || status == "partial")
            {
                int submitted = number("sync_submitted"), added = number("sync_added"), updated = number("sync_updated"), kept = number("sync_preserved");
                string body =
                    "Sent for review:  " + submitted + " saved skill" + (submitted == 1 ? "" : "s") + "\n" +
                    "Downloaded:  " + added + " new and " + updated + " updated approved skill" + (added + updated == 1 ? "" : "s") + "\n" +
                    (kept > 0 ? "Kept your local edits:  " + kept + " skill" + (kept == 1 ? "" : "s") + "\n" : "") +
                    "Approved team skills available:  " + number("sync_approved_total") +
                    (status == "partial" ? "\n\n" + reason : "\n\nRestart Codex or Claude to see new skills.");
                window.ShowResult(status == "ok" ? "Skills are in sync" : "Skills downloaded, but not sent", body, status == "ok" ? Brand.Good : Brand.Bad);
            }
            else
            {
                window.ShowResult("Skills Sync didn't finish",
                    String.IsNullOrWhiteSpace(reason) ? "Check the internet connection and try again. Details are in the weekly skill log." : reason, Brand.Bad);
            }
            window.AddButton("Close", true, delegate { window.Close(); });
        }
    }

    [Transaction(TransactionMode.Manual)]
    [Regeneration(RegenerationOption.Manual)]
    public sealed class SettingsCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData commandData, ref string message, ElementSet elements)
        {
            try
            {
                string root = Connector.FindRoot();
                Connector.StartHidden(Path.Combine(root, "installer", "Settings.ps1"), "-RepositoryPath " + Connector.Quote(root));
                return Result.Succeeded;
            }
            catch (Exception exception)
            {
                TaskDialog.Show(Brand.Name, exception.Message);
                return Result.Failed;
            }
        }
    }
}
