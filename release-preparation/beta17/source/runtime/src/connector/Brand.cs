using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Windows.Forms;
using Media = System.Windows.Media;

// Shared look for every Smart Connector window: the C# port of installer\Brand.ps1 (design system 1.0). Colour
// tokens, header, buttons, labels, the step rail, badges, cards and the vector icon family. Positions are in 96-DPI
// units, exactly as in Brand.ps1, so the compiled windows and the PowerShell windows look the same.
namespace SmartConnector
{
    internal static class Brand
    {
        internal const string Name = "Smart Connector";

        internal static readonly Color Header = Color.FromArgb(22, 36, 61);      // deep navy, matches the logo tile
        internal static readonly Color HeaderText = Color.White;
        internal static readonly Color HeaderSub = Color.FromArgb(160, 180, 210);
        internal static readonly Color Accent = Color.FromArgb(47, 128, 237);    // blue end of the logo gradient
        internal static readonly Color AccentDark = Color.FromArgb(30, 100, 200);
        internal static readonly Color Teal = Color.FromArgb(32, 201, 171);
        internal static readonly Color Body = Color.White;
        internal static readonly Color Text = Color.FromArgb(29, 35, 41);
        internal static readonly Color Muted = Color.FromArgb(95, 107, 119);
        internal static readonly Color Line = Color.FromArgb(227, 231, 236);
        internal static readonly Color Good = Color.FromArgb(31, 122, 61);
        internal static readonly Color Bad = Color.FromArgb(180, 35, 24);
        internal static readonly Color Canvas = Color.FromArgb(245, 247, 250);
        internal static readonly Color Navy950 = Color.FromArgb(11, 20, 38);
        internal static readonly Color RailText = Color.FromArgb(184, 198, 219);
        internal static readonly Color RailMuted = Color.FromArgb(142, 162, 192);
        internal static readonly Color RailLine = Color.FromArgb(74, 93, 125);
        internal static readonly Color Border = Color.FromArgb(201, 209, 219);
        internal static readonly Color Warn = Color.FromArgb(154, 78, 5);
        internal static readonly Color Link = Color.FromArgb(30, 100, 200);

        // $script:BrandColors[$Kind] for the kinds an outcome carries (Good, Bad, Accent and the other token names).
        internal static Color ColorOf(string kind)
        {
            switch (kind)
            {
                case "Good": return Good;
                case "Bad": return Bad;
                case "Accent": return Accent;
                case "Warn": return Warn;
                case "Muted": return Muted;
                case "Link": return Link;
                default: return Text;
            }
        }

        // Status badge colours: background and text. Every status also carries a word, never colour alone.
        internal static readonly Dictionary<string, Color[]> Status = new Dictionary<string, Color[]>
        {
            { "Good", new[] { Color.FromArgb(230, 244, 234), Color.FromArgb(31, 122, 61) } },
            { "Info", new[] { Color.FromArgb(232, 241, 253), Color.FromArgb(30, 100, 200) } },
            { "Warn", new[] { Color.FromArgb(253, 241, 227), Color.FromArgb(154, 78, 5) } },
            { "Bad", new[] { Color.FromArgb(252, 232, 230), Color.FromArgb(180, 35, 24) } },
            { "Off", new[] { Color.FromArgb(238, 241, 244), Color.FromArgb(74, 85, 97) } }
        };

        // The icon family: SVG path data on a 24-unit grid, the same strings as installer\Brand.ps1 ($script:BrandIconPaths),
        // the Revit add-in and assets\icon-family.json. tests\test-smart-connector-ui.ps1 checks that they stay identical.
        internal static readonly string[] IconNames = { "connector", "assistant", "claude", "codex", "skills", "sync", "revit", "autocad", "markup", "clear", "status", "updates", "settings", "diagnostics", "help", "overview", "components", "monitor", "globe", "check", "warning", "error", "info", "minus", "team", "folder" };
        internal static readonly Dictionary<string, string> IconPaths = new Dictionary<string, string>
        {
            { "connector", "M17 7c-1.2-1.6-3-2.5-5-2.5-2.6 0-4.5 1.5-4.5 3.5 0 4.6 9 2.4 9 7.3 0 2-1.9 3.7-4.5 3.7-2 0-3.8-.9-5-2.5" },
            { "assistant", "M12 3.5l1.9 4.6 4.6 1.9-4.6 1.9L12 16.5l-1.9-4.6L5.5 10l4.6-1.9zM18.5 15.5v4M16.5 17.5h4" },
            { "claude", "M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-8.5L6 19.5V16H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zM12 8v5M9.9 9.3l4.2 2.4M14.1 9.3l-4.2 2.4" },
            { "codex", "M4.5 5h15a1.5 1.5 0 0 1 1.5 1.5v11a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5v-11A1.5 1.5 0 0 1 4.5 5zM7 10l3 2.5L7 15M12.5 15H17" },
            { "skills", "M4.5 6.5l1.5 1.5 2.5-3M4.5 12.5l1.5 1.5 2.5-3M4.5 18.5l1.5 1.5 2.5-3M11 7h9M11 13h9M11 19h9" },
            { "sync", "M4.5 10a7.5 7.5 0 0 1 13.4-3.6L19.5 8M19.5 4v4h-4M19.5 14a7.5 7.5 0 0 1-13.4 3.6L4.5 16M4.5 20v-4h4" },
            { "revit", "M12 3l8 4.5v9L12 21l-8-4.5v-9zM4 7.5l8 4.5 8-4.5M12 12v9" },
            { "autocad", "M4 20V5l15 15zM8 16h3.5L8 12.5z" },
            { "markup", "M4 17c2.5-6 5.5 2 8.5-3.5S16.5 7 19.5 6" },
            { "clear", "M4 11c2-4.5 4.5 1.5 7-2.5S14 5 16 4.5M14 14l6 6M20 14l-6 6" },
            { "status", "M9 3v4M15 3v4M7 7h10v3.5a5 5 0 0 1-10 0zM12 15.5V21" },
            { "updates", "M12 4v11M7.5 10.5L12 15l4.5-4.5M5 20h14" },
            { "settings", "M4 7h9M17 7h3M4 12h3M11 12h9M4 17h11M19 17h1M15 5v4M9 10v4M17 15v4" },
            { "diagnostics", "M3 12h4l2-5 4 10 2-5h6" },
            { "help", "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9.6 9.4a2.5 2.5 0 1 1 3.4 2.4c-.6.3-1 .8-1 1.5v.6M12 17v.01" },
            { "overview", "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z" },
            { "components", "M4 7l8-4 8 4-8 4zM4 12l8 4 8-4M4 17l8 4 8-4" },
            { "monitor", "M4 5h16v11H4zM9 20h6M12 16v4" },
            { "globe", "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.5 3.5 5.5 3.5 9s-1 6.5-3.5 9c-2.5-2.5-3.5-5.5-3.5-9s1-6.5 3.5-9z" },
            { "check", "M5 12.5l4.5 4.5L19 7.5" },
            { "warning", "M12 4l9 16H3zM12 10v4M12 17.5v.5" },
            { "error", "M6 6l12 12M18 6L6 18" },
            { "info", "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v6M12 7.5v.5" },
            { "minus", "M6 12h12" },
            { "team", "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20c.8-3.5 3.3-5.5 6.5-5.5s5.7 2 6.5 5.5M16 4.3a3.5 3.5 0 0 1 0 6.4M18 14.8c1.8.6 3 2.4 3.5 5.2" },
            { "folder", "M3 6.5A1.5 1.5 0 0 1 4.5 5h4l2 2.5h9A1.5 1.5 0 0 1 21 9v9.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5z" }
        };

        private static readonly Dictionary<string, Bitmap> IconCache = new Dictionary<string, Bitmap>();

        // The first WPF rendering error, if any; icons then show blank instead of stopping the window (app --check-icons reports it).
        internal static string IconError = "";

        internal static string AssetPath(string name)
        {
            // Layout: <root>\bin\SmartConnector.exe and <root>\assets\<name>.
            string path = Path.Combine(Paths.Root, "assets", name);
            return File.Exists(path) ? path : null;
        }

        internal static Image Logo(int size)
        {
            string path = AssetPath("logo-" + size + ".png");
            if (path == null) return null;
            // Load through memory so the file is never kept open (updates replace the install folder).
            return Image.FromStream(new MemoryStream(File.ReadAllBytes(path)));
        }

        internal static Icon AppIcon()
        {
            string path = AssetPath("logo.ico");
            if (path == null) return SystemIcons.Application;
            return new Icon(new MemoryStream(File.ReadAllBytes(path)));
        }

        internal static Font Font(float size, FontStyle style = FontStyle.Regular, string family = "Segoe UI")
        {
            return new Font(family, size, style);
        }

        internal static Font Semibold(float size) { return new Font("Segoe UI Semibold", size, FontStyle.Bold); }

        internal static Form NewForm(string title = Name, int width = 640, int height = 460)
        {
            Form form = new Form();
            form.Text = title;
            form.ClientSize = new Size(width, height);
            form.StartPosition = FormStartPosition.CenterScreen;
            form.FormBorderStyle = FormBorderStyle.FixedSingle;
            form.MaximizeBox = false;
            form.BackColor = Body;
            form.ForeColor = Text;
            form.Font = Font(10);
            form.Icon = AppIcon();
            form.AutoScaleMode = AutoScaleMode.Dpi;
            return form;
        }

        internal static Panel AddHeader(Control parent, string title = Name, string subtitle = "", int height = 88)
        {
            Panel header = new Panel();
            header.Dock = DockStyle.Top;
            header.Height = height;
            header.BackColor = Header;
            PictureBox logo = new PictureBox();
            logo.Image = Logo(64);
            logo.SizeMode = PictureBoxSizeMode.Zoom;
            logo.Size = new Size(52, 52);
            logo.Location = new Point(22, Round((height - 52) / 2.0));
            header.Controls.Add(logo);
            Label titleLabel = new Label();
            titleLabel.Text = title;
            titleLabel.Font = Semibold(15);
            titleLabel.ForeColor = HeaderText;
            titleLabel.AutoSize = true;
            titleLabel.Location = new Point(88, subtitle.Length > 0 ? 18 : Round((height - 28) / 2.0));
            header.Controls.Add(titleLabel);
            if (subtitle.Length > 0)
            {
                Label sub = new Label();
                sub.Text = subtitle;
                sub.ForeColor = HeaderSub;
                sub.AutoSize = true;
                sub.Location = new Point(90, 50);
                header.Controls.Add(sub);
            }
            parent.Controls.Add(header);
            // Thin teal line under the header, echoing the logo gradient.
            Panel rule = new Panel();
            rule.Dock = DockStyle.Top; rule.Height = 3; rule.BackColor = Teal;
            parent.Controls.Add(rule);
            rule.BringToFront(); header.SendToBack();
            return header;
        }

        internal static Button NewButton(string text, bool primary = false, int width = 120)
        {
            Button button = new Button();
            button.Text = text;
            button.Size = new Size(width, 36);
            button.FlatStyle = FlatStyle.Flat;
            button.Cursor = Cursors.Hand;
            if (primary)
            {
                button.BackColor = Accent;
                button.ForeColor = Color.White;
                button.FlatAppearance.BorderColor = Accent;
                button.FlatAppearance.MouseOverBackColor = AccentDark;
                button.Font = Semibold(10);
            }
            else
            {
                button.BackColor = Color.White;
                button.ForeColor = Text;
                button.FlatAppearance.BorderColor = Line;
                button.FlatAppearance.MouseOverBackColor = Color.FromArgb(243, 246, 250);
            }
            return button;
        }

        internal static Label NewLabel(string text, int x, int y, int width = 0, float size = 10, bool muted = false, bool bold = false)
        {
            Label label = new Label();
            label.Text = text;
            label.Location = new Point(x, y);
            label.Font = bold ? Semibold(size) : Font(size);
            label.ForeColor = muted ? Muted : Text;
            if (width > 0) label.MaximumSize = new Size(width, 0);
            label.AutoSize = true;
            return label;
        }

        // Keeps text from covering other text. Pages are laid out with fixed positions, but how tall a block of text is depends on
        // the font, the display scale and the language, so after a page is filled each visible control is checked against the
        // ones above it that share some width. When it would overlap, it and everything level with or below it move down. A card
        // grows to hold its own contents. Controls tagged "overlay" (the details log) are left where they are.
        internal static void ResolveOverlaps(Control container)
        {
            if (container == null) return;
            int gap = Round(4 * Scale()), padding = Round(10 * Scale());
            foreach (Control child in container.Controls)
            {
                if (!(child is Card) || !child.Visible) continue;
                ResolveOverlaps(child);
                int bottom = 0;
                foreach (Control inner in child.Controls) if (inner.Visible) bottom = Math.Max(bottom, inner.Bottom);
                if (bottom + padding > child.Height) child.Height = bottom + padding;
            }
            List<Control> items = new List<Control>();
            foreach (Control child in container.Controls)
                if (child.Visible && child.Dock == DockStyle.None && !String.Equals(child.Tag as string, "overlay", StringComparison.Ordinal)) items.Add(child);
            items = items.OrderBy(c => c.Top).ThenBy(c => c.Left).ToList();
            for (int i = 0; i < items.Count; i++)
            {
                Control current = items[i];
                int need = 0;
                for (int j = 0; j < i; j++)
                {
                    Control above = items[j];
                    if (above.Right <= current.Left + 1 || current.Right <= above.Left + 1) continue;   // side by side
                    if (above.Top >= current.Top) continue;                                             // the same row
                    need = Math.Max(need, above.Bottom + gap - current.Top);
                }
                if (need <= 0) continue;
                int line = current.Top;
                foreach (Control moved in items) if (moved.Top >= line) moved.Top += need;
            }
        }

        // PowerShell's [int] cast rounds half to even; the layout arithmetic of Brand.ps1 relies on it.
        internal static int Round(double value) { return (int)Math.Round(value, MidpointRounding.ToEven); }

        // Display scale of the primary screen (1.0 at 100 %); bitmaps are drawn at device pixels so they stay sharp.
        internal static double Scale()
        {
            try { using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) return g.DpiX / 96.0; }
            catch (Exception) { return 1.0; }
        }

        // One icon from the family, drawn with WPF (vector, any size) and returned as a System.Drawing bitmap.
        //   tile draws the navy tile with the teal-to-blue stroke used by the ribbons and the app's section headers.
        internal static Bitmap IconImage(string name, int size = 20, Color? color = null, double stroke = 0, bool tile = false, double scale = 0)
        {
            if (!IconPaths.ContainsKey(name)) throw new ArgumentException("Unknown icon: " + name);
            Color c = color ?? Color.FromArgb(22, 36, 61);
            if (scale <= 0) scale = Scale();
            string key = String.Format(System.Globalization.CultureInfo.InvariantCulture, "{0}|{1}|{2}|{3}|{4}|{5}", name, size, c.ToArgb(), stroke, tile, scale);
            Bitmap cached;
            if (IconCache.TryGetValue(key, out cached)) return cached;
            int px = Round(size * scale);
            Bitmap image;
            try { image = RenderIcon(IconPaths[name], px, size, c, stroke, tile); }
            catch (Exception exception)
            {
                if (IconError.Length == 0) IconError = exception.GetType().Name + ": " + exception.Message;
                image = new Bitmap(Math.Max(1, px), Math.Max(1, px));
            }
            IconCache[key] = image;
            return image;
        }

        // Kept apart so that a PC without WPF fails here, inside the try above, rather than when IconImage is compiled.
        [MethodImpl(MethodImplOptions.NoInlining)]
        private static Bitmap RenderIcon(string data, int px, int size, Color color, double stroke, bool tile)
        {
            Media.DrawingVisual visual = new Media.DrawingVisual();
            Media.DrawingContext dc = visual.RenderOpen();
            Media.Brush brush;
            double width;
            try
            {
                if (tile)
                {
                    // 32-unit tile, glyph inset by 4 units, as in the ribbons.
                    dc.PushTransform(new Media.ScaleTransform(px / 32.0, px / 32.0));
                    Media.SolidColorBrush navy = new Media.SolidColorBrush(Media.Color.FromRgb(22, 36, 61));
                    dc.DrawRoundedRectangle(navy, null, new System.Windows.Rect(0, 0, 32, 32), 7, 7);
                    brush = new Media.LinearGradientBrush(Media.Color.FromRgb(32, 201, 171), Media.Color.FromRgb(47, 128, 237), 45);
                    width = stroke > 0 ? stroke : size <= 16 ? 3.0 : 2.3;
                    dc.PushTransform(new Media.TranslateTransform(4, 4));
                }
                else
                {
                    dc.PushTransform(new Media.ScaleTransform(px / 24.0, px / 24.0));
                    brush = new Media.SolidColorBrush(Media.Color.FromArgb(color.A, color.R, color.G, color.B));
                    width = stroke > 0 ? stroke : size <= 16 ? 2.2 : 1.75;
                    dc.PushTransform(new Media.TranslateTransform(0, 0));
                }
                Media.Pen pen = new Media.Pen(brush, width);
                pen.StartLineCap = Media.PenLineCap.Round; pen.EndLineCap = Media.PenLineCap.Round; pen.LineJoin = Media.PenLineJoin.Round;
                dc.DrawGeometry(null, pen, Media.Geometry.Parse(data));
            }
            finally { dc.Close(); }
            System.Windows.Media.Imaging.RenderTargetBitmap target = new System.Windows.Media.Imaging.RenderTargetBitmap(px, px, 96, 96, Media.PixelFormats.Pbgra32);
            target.Render(visual);
            System.Windows.Media.Imaging.PngBitmapEncoder encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
            encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(target));
            // GDI+ reads the bitmap from this stream for its whole life, so the stream is never closed.
            MemoryStream stream = new MemoryStream();
            encoder.Save(stream); stream.Position = 0;
            return new Bitmap(stream);
        }

        // Text in pixel units, for drawing under a DPI ScaleTransform in Paint handlers.
        internal static Font PixelFont(float size = 13, FontStyle style = FontStyle.Regular, string family = "Segoe UI")
        {
            return new Font(family, size, style, GraphicsUnit.Pixel);
        }

        internal static GraphicsPath RoundPath(float x, float y, float width, float height, float radius)
        {
            GraphicsPath path = new GraphicsPath();
            float d = Math.Min(2 * radius, Math.Min(width, height));
            if (d <= 0) { path.AddRectangle(new RectangleF(x, y, width, height)); return path; }
            path.AddArc(x, y, d, d, 180, 90); path.AddArc(x + width - d, y, d, d, 270, 90);
            path.AddArc(x + width - d, y + height - d, d, d, 0, 90); path.AddArc(x, y + height - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        // Prepares a Paint handler's Graphics: anti-aliased, scaled so drawing uses 96-DPI logical units.
        internal static float EnterPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit; g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            float k = g.DpiX / 96f;
            g.ScaleTransform(k, k);
            return k;
        }

        // An icon as a PictureBox, sized in logical pixels.
        internal static PictureBox IconBox(string name, int size = 20, int x = 0, int y = 0, Color? color = null, bool tile = false)
        {
            PictureBox box = new PictureBox();
            box.Size = new Size(size, size); box.Location = new Point(x, y);
            box.SizeMode = PictureBoxSizeMode.Zoom; box.BackColor = Color.Transparent;
            box.Image = IconImage(name, size, color ?? Color.FromArgb(22, 36, 61), 0, tile);
            return box;
        }
    }

    // Navy step rail on the left of the setup wizard: logo, name, the steps with done/current/next markers.
    internal sealed class StepRail : Panel
    {
        internal readonly string[] Steps;
        internal readonly string Footer;
        private readonly Image _logo;
        private int _current;

        internal StepRail(string[] steps, string footer = "", int width = 208)
        {
            Steps = steps; Footer = footer;
            Dock = DockStyle.Left; Width = width; BackColor = Brand.Header;
            _logo = Brand.Logo(64);
            Paint += OnRailPaint;
        }

        internal int Current
        {
            get { return _current; }
            set { _current = value; Invalidate(); }
        }

        private void OnRailPaint(object sender, PaintEventArgs e)
        {
            float k = Brand.EnterPaint(e);
            Graphics g = e.Graphics;
            if (_logo != null) g.DrawImage(_logo, 20, 24, 36, 36);
            using (Font nameFont = Brand.PixelFont(13, FontStyle.Bold, "Segoe UI Semibold"))
                g.DrawString("Smart\nConnector", nameFont, Brushes.White, 64, 26);
            using (Font font = Brand.PixelFont(13))
            using (Font bold = Brand.PixelFont(13, FontStyle.Bold, "Segoe UI Semibold"))
            using (Font small = Brand.PixelFont(11, FontStyle.Bold, "Segoe UI Semibold"))
            {
                float y = 92;
                for (int i = 0; i < Steps.Length; i++)
                {
                    bool done = i < _current, now = i == _current;
                    RectangleF circle = new RectangleF(20, y, 22, 22);
                    if (done)
                    {
                        using (SolidBrush teal = new SolidBrush(Brand.Teal)) g.FillEllipse(teal, circle);
                        using (Pen pen = new Pen(Brand.Navy950, 2.2f))
                        {
                            pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                            g.DrawLines(pen, new[] { new PointF(26, y + 11.5f), new PointF(29.5f, y + 15), new PointF(36, y + 7.5f) });
                        }
                    }
                    else if (now) { using (SolidBrush accent = new SolidBrush(Brand.Accent)) g.FillEllipse(accent, circle); }
                    else { using (Pen ring = new Pen(Brand.RailLine, 2)) g.DrawEllipse(ring, 21, y + 1, 20, 20); }
                    if (!done)
                    {
                        using (StringFormat format = new StringFormat())
                        {
                            format.Alignment = StringAlignment.Center; format.LineAlignment = StringAlignment.Center;
                            g.DrawString((i + 1).ToString(System.Globalization.CultureInfo.InvariantCulture), small, Brushes.White, circle, format);
                        }
                    }
                    Color color = now ? Color.White : done ? Color.FromArgb(200, 212, 230) : Brand.RailMuted;
                    using (SolidBrush text = new SolidBrush(color)) g.DrawString(Steps[i], now ? bold : font, text, 52, y + 2);
                    y += 36;
                }
            }
            if (Footer.Length > 0)
            {
                using (Font footerFont = Brand.PixelFont(11))
                using (SolidBrush footerBrush = new SolidBrush(Color.FromArgb(169, 188, 216)))
                    g.DrawString(Footer, footerFont, footerBrush, 20, Height / k - 30);
            }
        }
    }

    // Status pill: an icon and a word on a tinted background. Kind is Good, Info, Warn, Bad or Off.
    internal sealed class Badge : Label
    {
        internal string BadgeText = "";
        internal string Kind = "Off";

        internal Badge(string text, string kind = "Off")
        {
            AutoSize = false; Height = 24;
            Set(text, kind);
            Paint += OnBadgePaint;
        }

        internal void Set(string text, string kind)
        {
            BadgeText = text; Kind = kind;
            int width;
            using (Font font = Brand.PixelFont(12, FontStyle.Bold, "Segoe UI Semibold")) width = TextRenderer.MeasureText(text, font).Width + 38;
            Width = Brand.Round(width * Brand.Scale()); AccessibleName = text;
            Invalidate();
        }

        private void OnBadgePaint(object sender, PaintEventArgs e)
        {
            Brand.EnterPaint(e);
            Graphics g = e.Graphics;
            Color[] colors = Brand.Status[Kind];
            g.Clear(Parent != null ? Parent.BackColor : BackColor);
            float w = (float)(Width * 96.0 / g.DpiX);
            using (GraphicsPath path = Brand.RoundPath(0, 0, w - 1, 23, 11.5f))
            using (SolidBrush fill = new SolidBrush(colors[0]))
                g.FillPath(fill, path);
            string icon;
            switch (Kind) { case "Good": icon = "check"; break; case "Info": icon = "updates"; break; case "Warn": icon = "warning"; break; case "Bad": icon = "error"; break; default: icon = "minus"; break; }
            g.DrawImage(Brand.IconImage(icon, 12, colors[1], 2.8), 9, 6, 12, 12);
            using (Font font = Brand.PixelFont(12, FontStyle.Bold, "Segoe UI Semibold"))
            using (SolidBrush text = new SolidBrush(colors[1]))
                g.DrawString(BadgeText, font, text, 25, 4);
        }
    }

    // White panel with a 1 px border and 8 px corners.
    internal sealed class Card : Panel
    {
        internal Card(int x = 0, int y = 0, int width = 300, int height = 120)
        {
            Location = new Point(x, y); Size = new Size(width, height);
            BackColor = Color.White;
            Paint += OnCardPaint;
        }

        private void OnCardPaint(object sender, PaintEventArgs e)
        {
            float k = Brand.EnterPaint(e);
            using (GraphicsPath path = Brand.RoundPath(0.5f, 0.5f, Width / k - 1.5f, Height / k - 1.5f, 8))
            using (Pen pen = new Pen(Brand.Line, 1))
                e.Graphics.DrawPath(pen, path);
        }
    }
}
