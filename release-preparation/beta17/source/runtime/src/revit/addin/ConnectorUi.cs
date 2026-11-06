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

// Smart Connector ribbon and dialogs. C# 5 only: the add-in is compiled on each PC with
// the .NET Framework compiler that ships with Windows.
namespace BimCadMcp.Revit
{
    internal static class Brand
    {
        internal const string Name = "Smart Connector";
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
            throw new DirectoryNotFoundException("The Smart Connector installation folder could not be found. Run the installer again.");
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
            catch (Exception exception) { Debug.WriteLine("Smart Connector agent start failed: " + exception.Message); }
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
        // The icon family: SVG path data on a 24-unit grid, the same strings as installer\Brand.ps1
        // ($script:BrandIconPaths). tests\test-design-system.ps1 checks that they stay identical.
        internal static readonly System.Collections.Generic.Dictionary<string, string> Paths = new System.Collections.Generic.Dictionary<string, string>
        {
            { "connector", "M17 7c-1.2-1.6-3-2.5-5-2.5-2.6 0-4.5 1.5-4.5 3.5 0 4.6 9 2.4 9 7.3 0 2-1.9 3.7-4.5 3.7-2 0-3.8-.9-5-2.5" },
            { "sync", "M4.5 10a7.5 7.5 0 0 1 13.4-3.6L19.5 8M19.5 4v4h-4M19.5 14a7.5 7.5 0 0 1-13.4 3.6L4.5 16M4.5 20v-4h4" },
            { "skills", "M4.5 6.5l1.5 1.5 2.5-3M4.5 12.5l1.5 1.5 2.5-3M4.5 18.5l1.5 1.5 2.5-3M11 7h9M11 13h9M11 19h9" },
            { "status", "M9 3v4M15 3v4M7 7h10v3.5a5 5 0 0 1-10 0zM12 15.5V21" },
            { "updates", "M12 4v11M7.5 10.5L12 15l4.5-4.5M5 20h14" },
            { "settings", "M4 7h9M17 7h3M4 12h3M11 12h9M4 17h11M19 17h1M15 5v4M9 10v4M17 15v4" },
            { "diagnostics", "M3 12h4l2-5 4 10 2-5h6" },
            { "help", "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9.6 9.4a2.5 2.5 0 1 1 3.4 2.4c-.6.3-1 .8-1 1.5v.6M12 17v.01" }
        };

        private static Media.Brush Gradient()
        {
            Media.LinearGradientBrush brush = new Media.LinearGradientBrush(
                Media.Color.FromRgb(32, 201, 171), Media.Color.FromRgb(47, 128, 237), 45);
            brush.Freeze();
            return brush;
        }

        // Every ribbon button: the navy tile with the teal-to-blue glyph from the icon family, drawn as vectors
        // so Revit scales it for 16 px and 32 px buttons and any display scaling.
        internal static Media.ImageSource Tile(string name, bool small)
        {
            Media.DrawingGroup group = new Media.DrawingGroup();
            using (Media.DrawingContext context = group.Open())
            {
                context.DrawRoundedRectangle(new Media.SolidColorBrush(Media.Color.FromRgb(22, 36, 61)), null, new System.Windows.Rect(0, 0, 32, 32), 7, 7);
                Media.Pen pen = new Media.Pen(Gradient(), small ? 3.0 : 2.3);
                pen.StartLineCap = Media.PenLineCap.Round; pen.EndLineCap = Media.PenLineCap.Round; pen.LineJoin = Media.PenLineJoin.Round;
                context.PushTransform(new Media.TranslateTransform(4, 4));
                context.DrawGeometry(null, pen, Media.Geometry.Parse(Paths[name]));
                context.Pop();
            }
            group.Freeze();
            Media.DrawingImage image = new Media.DrawingImage(group);
            image.Freeze();
            return image;
        }

        // The logo itself (grip S on the tile), for Open Smart Connector.
        internal static Media.ImageSource Logo()
        {
            Media.DrawingGroup group = new Media.DrawingGroup();
            using (Media.DrawingContext context = group.Open())
            {
                context.DrawRoundedRectangle(new Media.SolidColorBrush(Media.Color.FromRgb(22, 36, 61)), null, new System.Windows.Rect(0, 0, 64, 64), 14, 14);
                Media.Pen pen = new Media.Pen(new Media.SolidColorBrush(Media.Color.FromRgb(32, 201, 171)), 7);
                context.DrawGeometry(null, pen, Media.Geometry.Parse("M42 21A10 10 0 1 0 32 31A10 10 0 1 1 22 41"));
                Media.SolidColorBrush grip = new Media.SolidColorBrush(Media.Color.FromRgb(47, 128, 237));
                context.DrawRectangle(grip, null, new System.Windows.Rect(37.5, 16.5, 9, 9));
                context.DrawRectangle(grip, null, new System.Windows.Rect(17.5, 36.5, 9, 9));
            }
            group.Freeze();
            Media.DrawingImage image = new Media.DrawingImage(group);
            image.Freeze();
            return image;
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
                using (Drawing.SolidBrush navy = new Drawing.SolidBrush(Drawing.Color.FromArgb(22, 36, 61)))
                using (Drawing.SolidBrush teal = new Drawing.SolidBrush(Brand.Teal))
                using (Drawing.SolidBrush blue = new Drawing.SolidBrush(Brand.Blue))
                using (Drawing.Pen pen = new Drawing.Pen(teal, size <= 24 ? 34f : size <= 32 ? 28f : 22.5f))
                using (Drawing.Drawing2D.GraphicsPath s = new Drawing.Drawing2D.GraphicsPath())
                {
                    tile.AddArc(8, 8, 104, 104, 180, 90); tile.AddArc(144, 8, 104, 104, 270, 90);
                    tile.AddArc(144, 144, 104, 104, 0, 90); tile.AddArc(8, 144, 104, 104, 90, 90); tile.CloseFigure();
                    g.FillPath(navy, tile);
                    // Grip S, as in assets\New-BrandAssets.ps1: one teal line, blue grip squares at its ends.
                    s.AddArc(90.5f, 49.25f, 75, 75, 0, -270); s.AddArc(90.5f, 124.25f, 75, 75, 270, 270);
                    g.DrawPath(pen, s);
                    g.FillRectangle(blue, 148.5f, 69.75f, 34, 34);
                    g.FillRectangle(blue, 73.5f, 144.75f, 34, 34);
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

                string assemblyPath = Assembly.GetExecutingAssembly().Location;

                // Connector: open the app, check the connection. Large buttons for the two daily actions.
                RibbonPanel connector = Panel(application, "Connector");
                connector.AddItem(Button(assemblyPath, "BimCadMcpOpenConnector", "Open\nConnector", typeof(OpenConnectorCommand),
                    "Open the Smart Connector app: status of Revit, AutoCAD, Claude and Codex, skills, updates and settings.", Icons.Logo(), Icons.Logo()));
                connector.AddItem(Button(assemblyPath, "BimCadMcpConnectionStatus", "Connection\nStatus", typeof(ConnectionStatusCommand),
                    "See whether Codex or Claude is connected to this Revit session.", Icons.Tile("status", false), Icons.Tile("status", true)));

                // Skills: send and receive team skills, browse what is installed.
                RibbonPanel skills = Panel(application, "Skills");
                skills.AddItem(Button(assemblyPath, "BimCadMcpSkillsSync", "Skills\nSync", typeof(SkillsSyncCommand),
                    "Send your saved skills for review and download the latest approved Revit and General skills.", Icons.Tile("sync", false), Icons.Tile("sync", true)));
                skills.AddItem(Button(assemblyPath, "BimCadMcpBrowseSkills", "Browse\nSkills", typeof(BrowseSkillsCommand),
                    "See the workflow skills installed for Claude and Codex, by category.", Icons.Tile("skills", false), Icons.Tile("skills", true)));

                // Support: small stacked buttons.
                RibbonPanel support = Panel(application, "Support");
                support.AddStackedItems(
                    Button(assemblyPath, "BimCadMcpCheckUpdates", "Check updates", typeof(CheckUpdatesCommand),
                        "Check for a new version of Smart Connector. Updates install by themselves when Revit and AutoCAD are closed.", Icons.Tile("updates", false), Icons.Tile("updates", true)),
                    Button(assemblyPath, "BimCadMcpSettings", "Settings", typeof(SettingsCommand),
                        "Automatic updates and other Smart Connector settings.", Icons.Tile("settings", false), Icons.Tile("settings", true)));
                support.AddStackedItems(
                    Button(assemblyPath, "BimCadMcpDiagnostics", "Diagnostics", typeof(DiagnosticsCommand),
                        "Logs and checks to send to your administrator when something does not work.", Icons.Tile("diagnostics", false), Icons.Tile("diagnostics", true)),
                    Button(assemblyPath, "BimCadMcpHelp", "Help", typeof(HelpCommand),
                        "How to use Smart Connector with Revit, AutoCAD, Claude and Codex.", Icons.Tile("help", false), Icons.Tile("help", true)));
            }
            catch (Exception exception)
            {
                Debug.WriteLine("Smart Connector ribbon error: " + exception);
            }
        }

        private static RibbonPanel Panel(UIControlledApplication application, string name)
        {
            RibbonPanel panel = application.GetRibbonPanels(TabName).FirstOrDefault(item => item.Name == name);
            return panel ?? application.CreateRibbonPanel(TabName, name);
        }

        private static PushButtonData Button(string assemblyPath, string name, string text, Type command, string tip, Media.ImageSource large, Media.ImageSource small)
        {
            PushButtonData data = new PushButtonData(name, text, assemblyPath, command.FullName);
            data.ToolTip = tip;
            data.LargeImage = large;
            data.Image = small;
            return data;
        }
    }

    // Ribbon buttons that open the Smart Connector app at one of its sections.
    internal static class ConnectorApp
    {
        internal static Result Open(string section)
        {
            try
            {
                string root = Connector.FindRoot();
                Connector.StartHidden(Path.Combine(root, "installer", "SmartConnectorApp.ps1"),
                    "-Section " + section + " -RepositoryPath " + Connector.Quote(root));
                return Result.Succeeded;
            }
            catch (Exception exception)
            {
                TaskDialog.Show(Brand.Name, exception.Message);
                return Result.Failed;
            }
        }
    }

    [Transaction(TransactionMode.Manual)]
    [Regeneration(RegenerationOption.Manual)]
    public sealed class OpenConnectorCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData commandData, ref string message, ElementSet elements) { return ConnectorApp.Open("Overview"); }
    }

    [Transaction(TransactionMode.Manual)]
    [Regeneration(RegenerationOption.Manual)]
    public sealed class BrowseSkillsCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData commandData, ref string message, ElementSet elements) { return ConnectorApp.Open("Skills"); }
    }

    [Transaction(TransactionMode.Manual)]
    [Regeneration(RegenerationOption.Manual)]
    public sealed class DiagnosticsCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData commandData, ref string message, ElementSet elements) { return ConnectorApp.Open("Diagnostics"); }
    }

    [Transaction(TransactionMode.Manual)]
    [Regeneration(RegenerationOption.Manual)]
    public sealed class HelpCommand : IExternalCommand
    {
        public Result Execute(ExternalCommandData commandData, ref string message, ElementSet elements) { return ConnectorApp.Open("Help"); }
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
                    window.Run("Checking for updates…", "Looking for a newer approved version of Smart Connector.",
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
                window.ShowResult("You're up to date", "Smart Connector " + installed + " is the latest approved version.", Brand.Good);
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
                    // From Revit, only approved Revit skills are downloaded; your saved skills of any kind are still sent.
                    window.Run("Syncing skills…", "Sending your saved skills for review and downloading the latest approved Revit skills.",
                        runner, "-Action Sync -Product Revit -StateRoot " + Connector.Quote(Connector.StateRoot),
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
                    "Downloaded:  " + added + " new and " + updated + " updated approved Revit skill" + (added + updated == 1 ? "" : "s") + "\n" +
                    (kept > 0 ? "Kept your local edits:  " + kept + " skill" + (kept == 1 ? "" : "s") + "\n" : "") +
                    "Approved Revit skills available:  " + number("sync_approved_total") +
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
                return ConnectorApp.Open("Settings");
            }
            catch (Exception exception)
            {
                TaskDialog.Show(Brand.Name, exception.Message);
                return Result.Failed;
            }
        }
    }
}
