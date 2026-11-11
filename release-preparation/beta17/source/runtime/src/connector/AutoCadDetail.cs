using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace SmartConnector
{
    // The result of generating a detail: the apply_plan steps, anything the author should look at, and a short summary.
    internal sealed class DetailResult
    {
        internal List<Dictionary<string, object>> Items = new List<Dictionary<string, object>>();
        internal List<string> Warnings = new List<string>();
        internal Dictionary<string, object> Summary = new Dictionary<string, object>();
        internal int Scale = 10;
        internal DetailAnnotation Place;
        internal List<Dictionary<string, object>> PaperItems = new List<Dictionary<string, object>>();   // annotation for the layout (annotation = paper)
        internal double HeightUnit = 10;        // model millimetres per millimetre of text height: the scale in model space, 1 in paper space
        internal string Annotation = "model";   // model, paper or none
        internal HashSet<object> Ann = new HashSet<object>();   // the plan items that are annotation (by reference), so placement never depends on a layer name
    }

    // One layer a detail can use: name and the settings it is created with when the drawing lacks it.
    internal sealed class LayerSpec
    {
        internal string Name, Linetype;
        internal int Color, Lineweight = -1;   // Lineweight in hundredths of a millimetre; -1 = leave the layer's default
        internal bool GeneratorOwn;            // not a layer from the office sheets: the generator's own
        internal LayerSpec(string name, int color, int lineweight) { Name = name; Color = color; Lineweight = lineweight; }
    }

    // What is known about the drawing a detail will be drawn into: its layers and blocks. null facts = not connected (a preview).
    internal sealed class DrawingFacts
    {
        internal HashSet<string> Layers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        internal HashSet<string> Blocks = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    }

    // The layers a detail uses for each role. generic: the generator's own set. ao: the layers of the office's counter sheets.
    internal sealed class DetailScheme
    {
        internal string Name = "generic";
        internal LayerSpec Cut, Outline, Thin, Hatch, Dim, Text, Light, Floor, Viewport, Level, Title;
        internal bool FixedSix = true;   // generic: the six layers are always created, in this order, as before
        internal Func<string, LayerSpec> CutByMaterial;
        internal Func<string, bool, LayerSpec> HatchByMaterial;
        internal LayerSpec CutFor(string material) { return CutByMaterial == null ? Cut : CutByMaterial(material); }
        internal LayerSpec HatchFor(string material, bool cut) { return HatchByMaterial == null ? Hatch : HatchByMaterial(material, cut); }
        internal static DetailScheme Generic()
        {
            return new DetailScheme
            {
                Cut = new LayerSpec("A-DETL-WIDE", 214, 50), Outline = new LayerSpec("A-DETL", 90, 25), Thin = new LayerSpec("A-DETL-THIN", 151, 13), Hatch = new LayerSpec("A-DETL-GENF", 92, 9),
                Dim = new LayerSpec("A-ANNO-DIMS", 211, 13), Text = new LayerSpec("G-ANNO-TEXT", 231, 13), Light = new LayerSpec("A-DETL-LITE", 2, 18),
                Viewport = new LayerSpec("G-ANNO-VPRT", 8, -1) { GeneratorOwn = true }
            }.WithFloor();
        }

        private DetailScheme WithFloor() { Floor = Cut; Level = Text; Title = Text; return this; }

        // The layers of the office's counter sheets, read from the reference DXFs: one section layer per material (colour and lineweight as there),
        // hatches on the material's own layer, finish hatches on AO_N_HATCH, lighting on AO-N_LIGHTING, leader labels on AO_DIMZ, dimensions on 0_AO_DIMZ.
        // A layer the sheets do not have for a material (stone, marble) is the generator's own and is reported as such.
        internal static DetailScheme Ao(string view)
        {
            LayerSpec mdf = new LayerSpec("AO-MDF_SECTION_PLAN", 34, 25), corian = new LayerSpec("AO-CORIAN C-TOP", 43, 20), steel = new LayerSpec("AO-STAINLESS STEEL", 42, 20),
                glass = new LayerSpec("AO-GLASS_SECTION_PLAN", 140, 25), stone = new LayerSpec("AO-STONE_SECTION_PLAN", 8, 25) { GeneratorOwn = true },
                outline = view == "plan" ? new LayerSpec("AO-COUNTER", 4, 5) : new LayerSpec("AO_ELEVATION 3", 8, -1), hatch = new LayerSpec("AO_N_HATCH", 8, -1);
            DetailScheme sc = new DetailScheme
            {
                Name = "ao", FixedSix = false, Cut = mdf, Outline = outline, Thin = new LayerSpec("AO_DIMZ", 1, -1), Hatch = hatch, Dim = new LayerSpec("0_AO_DIMZ", 1, 0),
                Text = new LayerSpec("AO_DRAWING TITLE BASE", 7, -1), Light = new LayerSpec("AO-N_LIGHTING", 51, -1), Floor = outline, Viewport = new LayerSpec("AO-MV", 8, -1),
                Level = new LayerSpec("AO-Z.Lvl", 181, -1), Title = new LayerSpec("0", 7, -1)
            };
            sc.CutByMaterial = m =>
            {
                switch (m)
                {
                    case "corian": return corian;
                    case "steel": return steel;
                    case "glass": return glass;
                    case "stone": case "marble": return stone;
                    case "outline": return outline;
                    default: return mdf;      // mdf, ply: joinery boards share the MDF section layer
                }
            };
            sc.HatchByMaterial = (m, cut) =>
            {
                if (!cut) return hatch;
                switch (m)
                {
                    case "corian": return corian;     // the sheets hatch section materials on the material's own layer
                    case "steel": return steel;
                    case "mdf": case "ply": return mdf;
                    default: return hatch;            // stone, marble, glass and finishes: AO_N_HATCH
                }
            };
            return sc;
        }
    }

    // Where the annotation goes. model: in model space at the detail scale (the original behaviour). paper: dimensions, notes, levels and titles
    // in a layout at true paper size, around a viewport at 1:scale whose view is centred on the detail. none: geometry only.
    internal sealed class DetailAnnotation
    {
        internal string Mode = "model";
        internal double[] PaperCentre;          // paper position the detail's centre is shown at (centre of the viewport)
        internal double[] ModelCentre;          // model point at that centre; null = the centre of the parts
        internal string LevelBlock, LeaderBlock, TitleBlock;   // block names to use instead of the office ones (level indicator, Multiple Leader Lab, DWG-VIEWTITLE)
        internal double LevelBlockScale = 0;     // 0 = the office level block's own scale (0.015984), 1 for any other block
        internal double NoteWidth = 45;          // paper millimetres a leader label wraps to
        internal string SheetProject, SheetNo, ViewNo;   // the view title block's TOP-TITLE, SHEET-NO and KY, when given
        internal string Scheme = "auto";        // auto, generic or ao: which layer set the detail uses
        internal DrawingFacts Facts;            // the drawing's layers and blocks, when known
    }

    // Detail Generator. A brief (a template name and a few parameters) becomes an apply_plan plan. No AutoCAD calls happen
    // here, so a plan can be built, checked and previewed anywhere, then dry-run and applied like any other plan.
    // Millimetres only. Every drawing it makes is a draft for a designer's review.
    internal static class AutoCadDetail
    {
        internal const string ReceptionCounterSection = "reception_counter_section";
        internal const string CustomSection = "custom_section";

        private const double CorianThickness = 12, StoneThickness = 20;
        private const int NoteGapDenominators = 5;   // notes closer than this many paper millimetres are reported

        // Layers, as in the office set, with this generator's own lineweights (hundredths of a millimetre).

        private static readonly string[] Allowed =
        {
            "section", "height", "depth", "board_thickness", "plinth_height", "plinth_setback", "floor_clearance", "top_material",
            "top_overhang_staff", "top_overhang_customer", "shelf_height", "raised_bar", "bar_rise", "bar_depth",
            "accessible_height", "knee_clearance_height", "knee_clearance_depth", "code_reference"
        };

        private sealed class Part
        {
            internal string Id, Material, Group;
            internal double X0, Y0, X1, Y1;          // the rectangle, or the bounding box of Pts
            internal List<double[]> Pts;             // a polygon part (custom_section); null for a rectangle
            internal List<double[]> Visible;         // elevation/plan: the visible pieces {x0,y0,x1,y1} of a part partly hidden by nearer parts; null when fully visible
            internal string HatchPattern;            // caller's hatch: pattern name, "none", or null for the view's default
            internal double HatchScale = 1, HatchAngle;
            internal List<double> Bulges;            // arc of the segment starting at each point of Pts (0 = straight); null = all straight
            private List<double[]> flat;
            // The outline as straight segments: arcs are flattened to within 0.2 mm for overlap, hidden-line and leader checks.
            internal List<double[]> Outline()
            {
                if (Pts == null) return new List<double[]> { new[] { X0, Y0 }, new[] { X1, Y0 }, new[] { X1, Y1 }, new[] { X0, Y1 } };
                if (Bulges == null) return Pts;
                return flat ?? (flat = Flatten(Pts, Bulges));
            }
        }

        private static double Num(IDictionary<string, object> p, string key, double def, double min, double max)
        {
            object v;
            if (!p.TryGetValue(key, out v)) return def;
            double d;
            if (!Schema.TryNumber(v, out d)) throw new ToolException("params." + key + " must be a number.");
            if (d < min || d > max)
                throw new ToolException("params." + key + " must be between " + min.ToString(CultureInfo.InvariantCulture) + " and " + max.ToString(CultureInfo.InvariantCulture) + " mm.");
            return d;
        }

        private static string Choice(IDictionary<string, object> p, string key, string def, params string[] choices)
        {
            object v;
            if (!p.TryGetValue(key, out v)) return def;
            string s = v as string;
            if (s == null || Array.IndexOf(choices, s) < 0) throw new ToolException("params." + key + " must be one of: " + String.Join(", ", choices) + ".");
            return s;
        }

        private static bool Flag(IDictionary<string, object> p, string key)
        {
            object v;
            if (!p.TryGetValue(key, out v)) return false;
            if (!(v is bool)) throw new ToolException("params." + key + " must be true or false.");
            return (bool)v;
        }

        private static string Level(double mm)
        {
            return "EL +" + (mm / 1000.0).ToString("0.00", CultureInfo.InvariantCulture);
        }

        private static string Mm(double v)
        {
            return v.ToString("0.##", CultureInfo.InvariantCulture);
        }


        // Draws the pieces every template shares: layers, floor line, part outlines and hatches, dimensions, levels, notes and text.
        // Coordinates are section coordinates (x from the staff face, y up from the floor); origin and detail scale are applied here.
        private sealed class Emitter
        {
            private readonly DetailResult r;
            private readonly double ox, oy, d, dimScale;
            private readonly int scale;
            private readonly string dimStyle, textStyle;
            internal readonly DetailScheme S;
            private readonly List<LayerSpec> used = new List<LayerSpec>();
            internal readonly List<double> NoteYs = new List<double>();
            private readonly string levelBlock, leaderBlock, titleBlock;   // office blocks to use (paper mode), or null
            private readonly bool paper;
            private readonly List<NoteSpec> notes = new List<NoteSpec>();

            private sealed class NoteSpec { internal double TargetX, TargetY, NoteX; internal string Text; }

            internal Emitter(DetailResult result, double originX, double originY, int detailScale, string dimensionStyle, string textStyleName, double dimensionScale, DetailScheme scheme)
            {
                r = result; ox = originX; oy = originY; scale = detailScale; d = detailScale; dimStyle = dimensionStyle; textStyle = textStyleName; dimScale = dimensionScale; S = scheme;
                DetailAnnotation place = result.Place ?? new DetailAnnotation();
                paper = place.Mode == "paper";
                levelBlock = BlockFor(place, place.LevelBlock, OfficeLevelBlock, result);
                leaderBlock = BlockFor(place, place.LeaderBlock, OfficeLeaderBlock, result);
                titleBlock = BlockFor(place, place.TitleBlock, OfficeTitleBlock, result);
            }

            private LayerSpec Use(LayerSpec spec)
            {
                if (spec.Name != "0" && !used.Any(u => u.Name == spec.Name)) used.Add(spec);   // layer 0 always exists and is never changed
                return spec;
            }

            private Dictionary<string, object> Ann(Dictionary<string, object> item)
            {
                r.Items.Add(item);
                r.Ann.Add(item);
                return item;
            }

            // Puts a layer step for every layer used at the front of the plan, in order of first use.
            internal void Finish()
            {
                List<Dictionary<string, object>> steps = new List<Dictionary<string, object>>();
                foreach (LayerSpec u in used)
                {
                    Dictionary<string, object> step = Json.Object("op", "layer", "name", u.Name, "color", u.Color);
                    if (u.Lineweight >= 0) step["lineweight"] = u.Lineweight;
                    if (u.Linetype != null) step["linetype"] = u.Linetype;
                    steps.Add(step);
                }
                r.Items.InsertRange(0, steps);
                r.Summary["layer_scheme"] = S.Name;
                string[] own = used.Where(u => u.GeneratorOwn).Select(u => u.Name).ToArray();
                if (own.Length > 0) r.Summary["generator_layers"] = own;
            }

            internal double TextH { get { return 2.5 * d; } }                         // notes and levels: the reference sheets use 2.5 mm leader text
            internal object[] P(double x, double y) { return new object[] { Math.Round(ox + x, 3), Math.Round(oy + y, 3) }; }

            internal void Layers()
            {
                if (!S.FixedSix) return;
                Use(S.Cut); Use(S.Outline); Use(S.Thin); Use(S.Hatch); Use(S.Dim); Use(S.Text);
            }

            internal void Floor(double fromX, double toX)
            {
                r.Items.Add(Json.Object("op", "line", "layer", Use(S.Floor).Name, "start", P(fromX, 0), "end", P(toX, 0)));
            }

            internal void Parts(List<Part> parts)
            {
                Parts(parts, true);
            }

            // cut: a section (heavy cut line, material hatch by default). Otherwise an elevation or plan (outline line, no hatch unless the part asks).
            internal void Parts(List<Part> parts, bool cut)
            {
                foreach (Part b in parts)
                {
                    if (b.Visible != null) { foreach (double[] g in b.Visible) Line(g[0], g[1], g[2], g[3], S.Outline); continue; }   // partly hidden: its visible lines only
                    List<double[]> drawn = b.Pts ?? b.Outline();
                    Dictionary<string, object> poly = Json.Object("op", "polyline", "id", b.Id, "layer", Use(cut ? S.CutFor(b.Material) : S.Outline).Name, "points", drawn.Select(q => (object)P(q[0], q[1])).ToArray(), "closed", true);
                    if (b.Bulges != null) poly["bulges"] = b.Bulges.Select(v => (object)Math.Round(v, 9)).ToArray();
                    r.Items.Add(poly);
                }
                foreach (Part b in parts)
                {
                    if (b.Visible != null) continue;                                                // no closed outline to hatch
                    string pattern; double factor; int color = 0;
                    if (b.HatchPattern == "none") continue;
                    if (b.HatchPattern != null) { pattern = b.HatchPattern; factor = pattern == "SOLID" ? 0 : b.HatchScale; }
                    else if (!cut) continue;
                    else switch (b.Material)
                    {
                        case "corian": pattern = "SOLID"; factor = 0; break;
                        case "stone": case "marble": pattern = "ANSI36"; factor = 0.5; break;
                        case "ply": pattern = "ANSI32"; factor = 0.3; break;
                        case "steel": pattern = "SOLID"; factor = 0; color = 8; break;
                        case "glass": case "outline": continue;                                   // outline only
                        default: pattern = "ANSI31"; factor = 0.6; break;
                    }
                    Dictionary<string, object> hatch = Json.Object("op", "hatch", "layer", Use(S.HatchFor(b.Material, cut)).Name, "pattern", pattern, "boundary", b.Id);
                    if (factor > 0) hatch["scale"] = Math.Round(factor * d, 3);
                    if (b.HatchPattern != null && b.HatchAngle != 0) hatch["angle"] = b.HatchAngle;
                    if (color > 0) hatch["color"] = color;
                    r.Items.Add(hatch);
                }
            }

            internal void Line(double x0, double y0, double x1, double y1, LayerSpec layer)
            {
                r.Items.Add(Json.Object("op", "line", "layer", Use(layer).Name, "start", P(x0, y0), "end", P(x1, y1)));
            }

            internal void Dim(double x0, double y0, double x1, double y1, double lx, double ly, double angle)
            {
                Dictionary<string, object> s = Json.Object("op", "dim_rotated", "layer", Use(S.Dim).Name, "from", P(x0, y0), "to", P(x1, y1), "location", P(lx, ly), "angle", angle);
                if (dimStyle != null) s["style"] = dimStyle;
                s["scale"] = dimScale > 0 ? dimScale : (double)scale;
                Ann(s);
            }

            internal void Text(double x, double y, string text, double height)
            {
                Dictionary<string, object> t = Json.Object("op", "text", "layer", Use(S.Text).Name, "point", P(x, y), "text", text, "height", height);
                if (textStyle != null) t["style"] = textStyle;
                Ann(t);
            }

            // A level marker: the office level block with the elevation and the description as its attributes (paper mode), else a drawn marker and text.
            internal void Level(double y, string elevation, string description, double markX)
            {
                if (levelBlock != null)
                {
                    DetailAnnotation place = r.Place;
                    double sc = place.LevelBlockScale > 0 ? place.LevelBlockScale : (String.Equals(levelBlock, OfficeLevelBlock, StringComparison.OrdinalIgnoreCase) ? OfficeLevelScale : 1);
                    Dictionary<string, object> attributes = Json.Object("@elevation", elevation);
                    if (!String.IsNullOrEmpty(description)) attributes["@description"] = description;
                    Ann(Json.Object("op", "insert", "layer", Use(S.Level).Name, "name", levelBlock, "point", P(markX, y), "scale", sc, "attributes", attributes));
                    return;
                }
                string label = String.IsNullOrEmpty(description) ? elevation : elevation + " " + description;
                string thin = Use(S.Thin).Name;
                Ann(Json.Object("op", "line", "layer", thin, "start", P(markX, y), "end", P(-30 * d, y)));
                Ann(Json.Object("op", "line", "layer", thin, "start", P(markX, y), "end", P(markX - 2 * d, y + 3 * d)));
                Ann(Json.Object("op", "line", "layer", thin, "start", P(markX - 2 * d, y + 3 * d), "end", P(markX + 2 * d, y + 3 * d)));
                Ann(Json.Object("op", "line", "layer", thin, "start", P(markX + 2 * d, y + 3 * d), "end", P(markX, y)));
                Text(markX + 4 * d, y + 1 * d, label, TextH);
            }

            // The view title: the office DWG-VIEWTITLE block (paper mode), else two lines of text.
            internal void Title(double x, double y, string title, int denominator)
            {
                if (titleBlock != null)
                {
                    DetailAnnotation place = r.Place;
                    Dictionary<string, object> attributes = Json.Object("BOTTOM-TITLE", title, "SCALE", "1:" + denominator.ToString(CultureInfo.InvariantCulture) + " M.");   // the sheets write the scale as 1:10 M.
                    if (!String.IsNullOrEmpty(place.SheetProject)) attributes["TOP-TITLE"] = place.SheetProject;
                    if (!String.IsNullOrEmpty(place.SheetNo)) attributes["SHEET-NO"] = place.SheetNo;
                    if (!String.IsNullOrEmpty(place.ViewNo)) attributes["KY"] = place.ViewNo;
                    Ann(Json.Object("op", "insert", "layer", Use(S.Title).Name, "name", titleBlock, "point", P(x, y), "scale", 1.0, "attributes", attributes));
                    return;
                }
                Text(x, y, title, 3.5 * d);
                Text(x, y - 6 * d, "SCALE 1:" + denominator.ToString(CultureInfo.InvariantCulture), 2.5 * d);
            }

            // A note. In paper mode a leader (the office label block, or a native leader), placed with the others in FlushNotes; in model space a line and text.
            internal void Note(double targetX, double y, string text, double noteX)
            {
                if (paper) { notes.Add(new NoteSpec { TargetX = targetX, TargetY = y, NoteX = noteX, Text = text }); NoteYs.Add(y); return; }
                Ann(Json.Object("op", "line", "layer", Use(S.Thin).Name, "start", P(targetX, y), "end", P(noteX - 2 * d, y)));
                Text(noteX, y - 1 * d, text, TextH);
                NoteYs.Add(y);
            }

            private static int Lines(string text, int perLine)
            {
                int lines = 1, length = 0;
                foreach (string word in text.Split(' '))
                {
                    if (length > 0 && length + 1 + word.Length > perLine) { lines++; length = word.Length; }
                    else length += (length > 0 ? 1 : 0) + word.Length;
                }
                return lines;
            }

            // Paper mode: the labels, top to bottom, each level with its target unless that would overlap the label above; a label is as tall as its
            // wrapped lines (about 4 mm a line at 2.5 mm text, about 1.64 mm a character). Then the leaders are emitted in the order the notes were given.
            internal void FlushNotes(DetailResult result)
            {
                if (!paper)
                {
                    CheckNoteGaps(result);
                    return;
                }
                double width = (r.Place ?? new DetailAnnotation()).NoteWidth;
                int perLine = Math.Max(8, (int)Math.Floor(width / 1.64));
                Dictionary<NoteSpec, double> anchorY = new Dictionary<NoteSpec, double>();
                double limit = Double.PositiveInfinity;
                foreach (NoteSpec n in notes.OrderByDescending(n => n.TargetY))
                {
                    double h = Lines(n.Text, perLine) * 4.0 * d, gap = 2.5 * d;
                    double y = Math.Min(n.TargetY, limit - h / 2);
                    anchorY[n] = y;
                    limit = y - h / 2 - gap;
                }
                foreach (NoteSpec n in notes)
                {
                    Dictionary<string, object> leader = Json.Object("op", "leader", "layer", Use(S.Thin).Name, "point", P(n.NoteX, anchorY[n]), "target", P(n.TargetX, n.TargetY), "text", n.Text, "width", width);
                    if (leaderBlock != null)
                    {
                        leader["block"] = leaderBlock;
                        if (String.Equals(leaderBlock, OfficeLeaderBlock, StringComparison.OrdinalIgnoreCase)) leader["visibility"] = "1 arrow";
                    }
                    else leader["height"] = 2.5;
                    Ann(leader);
                }
                notes.Clear();
            }

            internal void CheckNoteGaps(DetailResult result)
            {
                List<double> ys = new List<double>(NoteYs);
                ys.Sort();
                for (int i = 1; i < ys.Count; i++)
                    if (ys[i] - ys[i - 1] < NoteGapDenominators * d)
                    {
                        result.Warnings.Add("Two notes are closer than " + NoteGapDenominators + " mm on paper at 1:" + scale + "; move one by hand.");
                        return;
                    }
            }
        }

        // Annotation placement. model leaves everything in model space; none drops the annotation; paper maps it to a layout at true size.
        private static void Place(DetailResult r, DetailAnnotation place, int scale, double dimScale, double bx0, double by0, double bx1, double by1, double ox, double oy)
        {
            double d = scale;
            List<Dictionary<string, object>> items = r.Items;
            if (place.Mode != "model")
            {
                double mcx = ox + (bx0 + bx1) / 2.0, mcy = oy + (by0 + by1) / 2.0;
                if (place.ModelCentre != null) { mcx = place.ModelCentre[0]; mcy = place.ModelCentre[1]; }
                List<Dictionary<string, object>> outItems = new List<Dictionary<string, object>>();
                double minX = double.MaxValue, minY = double.MaxValue, maxX = double.MinValue, maxY = double.MinValue;
                Func<object, object> map = pt =>
                {
                    object[] q = (object[])pt;
                    double x = Math.Round(place.PaperCentre[0] + ((double)q[0] - mcx) / d, 3), y = Math.Round(place.PaperCentre[1] + ((double)q[1] - mcy) / d, 3);
                    minX = Math.Min(minX, x); maxX = Math.Max(maxX, x); minY = Math.Min(minY, y); maxY = Math.Max(maxY, y);
                    return new object[] { x, y };
                };
                foreach (Dictionary<string, object> item in items)
                {
                    string op = Json.GetString(item, "op"), lay = Json.GetString(item, "layer");
                    bool annotation = r.Ann.Contains(item);
                    if (!annotation) { outItems.Add(item); continue; }
                    if (place.Mode == "none") continue;
                    switch (op)
                    {
                        case "line": item["start"] = map(item["start"]); item["end"] = map(item["end"]); break;
                        case "text": item["point"] = map(item["point"]); item["height"] = Math.Round((double)item["height"] / d, 3); break;
                        case "insert": item["point"] = map(item["point"]); break;
                        case "leader": item["point"] = map(item["point"]); item["target"] = map(item["target"]); break;   // landing, width and height are paper millimetres already
                        case "dim_rotated":
                            item["from"] = map(item["from"]); item["to"] = map(item["to"]); item["location"] = map(item["location"]);
                            if (dimScale > 0) item["scale"] = dimScale; else item.Remove("scale");   // the style's own paper size applies in paper space
                            item["linear_factor"] = d;                                              // measured paper length x scale = the model size
                            break;
                    }
                    r.PaperItems.Add(item);
                }
                items.Clear();
                items.AddRange(outItems);
                r.Summary["model_centre"] = new object[] { Math.Round(mcx, 3), Math.Round(mcy, 3) };
                if (place.Mode == "paper")
                {
                    r.Summary["paper_centre"] = new object[] { place.PaperCentre[0], place.PaperCentre[1] };
                    r.Summary["parts_size_paper_mm"] = new object[] { Math.Round((bx1 - bx0) / d, 1), Math.Round((by1 - by0) / d, 1) };
                    r.Summary["annotation_anchor_extent_paper"] = new object[] { Math.Round(minX, 1), Math.Round(minY, 1), Math.Round(maxX, 1), Math.Round(maxY, 1) };
                    r.Summary["viewport_setup"] = "Viewport at scale 1:" + scale + " (CustomScale " + (1.0 / d).ToString("0.######", CultureInfo.InvariantCulture) + "), view centred on model point " + Mm(mcx) + ", " + Mm(mcy)
                        + ". Annotation is placed assuming exactly that view; AutoCAD does not let this tool set the viewport's view centre.";
                }
            }
        }


        private static readonly string[] CustomAllowed = { "view", "parts", "lines", "levels", "notes", "dimensions", "title", "overall_dimensions", "floor", "hidden_lines" };
        private static readonly string[] Materials = { "mdf", "ply", "stone", "marble", "corian", "steel", "glass", "outline" };
        private const int MaxCustomParts = 200;

        // ---- arcs: AutoCAD bulge = tan(sweep / 4), positive anticlockwise ----
        internal static List<double[]> Flatten(List<double[]> pts, List<double> bulges)
        {
            List<double[]> o = new List<double[]>();
            for (int i = 0; i < pts.Count; i++)
            {
                double[] a = pts[i], b = pts[(i + 1) % pts.Count];
                o.Add(a);
                double bulge = bulges[i];
                if (bulge == 0) continue;
                double dx = b[0] - a[0], dy = b[1] - a[1], k = (1 - bulge * bulge) / (4 * bulge);
                double cx = (a[0] + b[0]) / 2 - k * dy, cy = (a[1] + b[1]) / 2 + k * dx;
                double radius = Math.Sqrt((a[0] - cx) * (a[0] - cx) + (a[1] - cy) * (a[1] - cy));
                double sweep = 4 * Math.Atan(bulge), start = Math.Atan2(a[1] - cy, a[0] - cx);
                double step = radius > 0.2 ? 2 * Math.Acos(1 - 0.2 / radius) : Math.PI / 8;
                int n = Math.Max(2, Math.Min(720, (int)Math.Ceiling(Math.Abs(sweep) / step)));
                for (int k2 = 1; k2 < n; k2++)
                {
                    double t = start + sweep * k2 / n;
                    o.Add(new[] { cx + radius * Math.Cos(t), cy + radius * Math.Sin(t) });
                }
            }
            return o;
        }

        // ---- polygon geometry for custom parts ----
        private static double Cross(double[] o, double[] a, double[] b) { return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]); }

        private static bool SegmentsTouch(double[] a, double[] b, double[] c, double[] d)
        {
            double d1 = Cross(c, d, a), d2 = Cross(c, d, b), d3 = Cross(a, b, c), d4 = Cross(a, b, d);
            if (((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9)) && ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9))) return true;
            Func<double[], double[], double[], bool> on = (p, q, x) => Math.Abs(Cross(p, q, x)) <= 1e-9 && x[0] >= Math.Min(p[0], q[0]) - 1e-9 && x[0] <= Math.Max(p[0], q[0]) + 1e-9 && x[1] >= Math.Min(p[1], q[1]) - 1e-9 && x[1] <= Math.Max(p[1], q[1]) + 1e-9;
            return on(c, d, a) || on(c, d, b) || on(a, b, c) || on(a, b, d);
        }

        private static bool SegmentsCross(double[] a, double[] b, double[] c, double[] d)
        {
            double d1 = Cross(c, d, a), d2 = Cross(c, d, b), d3 = Cross(a, b, c), d4 = Cross(a, b, d);
            return ((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9)) && ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9));
        }

        private static double Area(List<double[]> p)
        {
            double a = 0;
            for (int i = 0; i < p.Count; i++) { double[] u = p[i], v = p[(i + 1) % p.Count]; a += u[0] * v[1] - v[0] * u[1]; }
            return a / 2.0;
        }

        // Strictly inside: not on an edge.
        private static bool Inside(double[] x, List<double[]> p)
        {
            for (int i = 0; i < p.Count; i++)
            {
                double[] u = p[i], v = p[(i + 1) % p.Count];
                if (Math.Abs(Cross(u, v, x)) <= 1e-9 && x[0] >= Math.Min(u[0], v[0]) - 1e-9 && x[0] <= Math.Max(u[0], v[0]) + 1e-9 && x[1] >= Math.Min(u[1], v[1]) - 1e-9 && x[1] <= Math.Max(u[1], v[1]) + 1e-9) return false;
            }
            bool c = false;
            for (int i = 0, j = p.Count - 1; i < p.Count; j = i++)
                if ((p[i][1] > x[1]) != (p[j][1] > x[1]) && x[0] < (p[j][0] - p[i][0]) * (x[1] - p[i][1]) / (p[j][1] - p[i][1]) + p[i][0]) c = !c;
            return c;
        }

        // Two parts overlap when their interiors share area; touching edges and corners are fine.
        private static bool Overlap(List<double[]> a, List<double[]> b)
        {
            for (int i = 0; i < a.Count; i++)
                for (int j = 0; j < b.Count; j++)
                    if (SegmentsCross(a[i], a[(i + 1) % a.Count], b[j], b[(j + 1) % b.Count])) return true;
            Func<List<double[]>, List<double[]>, bool> probe = (p, q) =>
            {
                double cx = p.Average(v => v[0]), cy = p.Average(v => v[1]);
                if (Inside(new[] { cx, cy }, q)) return true;
                for (int i = 0; i < p.Count; i++)
                {
                    double[] u = p[i], v = p[(i + 1) % p.Count];
                    if (Inside(u, q) || Inside(new[] { (u[0] + v[0]) / 2, (u[1] + v[1]) / 2 }, q)) return true;
                }
                return false;
            };
            return probe(a, b) || probe(b, a);
        }

        // Splits each segment where it crosses the outline q and drops the pieces inside q (strictly: pieces along q's edge stay).
        private static List<double[]> HideBehind(List<double[]> segments, List<double[]> q, ref bool hid)
        {
            List<double[]> kept = new List<double[]>();
            foreach (double[] g in segments)
            {
                double[] a = { g[0], g[1] }, b = { g[2], g[3] };
                List<double> ts = new List<double> { 0, 1 };
                for (int i = 0; i < q.Count; i++)
                {
                    double[] c = q[i], d = q[(i + 1) % q.Count];
                    double den = (b[0] - a[0]) * (d[1] - c[1]) - (b[1] - a[1]) * (d[0] - c[0]);
                    if (Math.Abs(den) < 1e-12) continue;
                    double t = ((c[0] - a[0]) * (d[1] - c[1]) - (c[1] - a[1]) * (d[0] - c[0])) / den;
                    double u = ((c[0] - a[0]) * (b[1] - a[1]) - (c[1] - a[1]) * (b[0] - a[0])) / den;
                    if (t > 1e-9 && t < 1 - 1e-9 && u >= -1e-9 && u <= 1 + 1e-9) ts.Add(t);
                }
                ts.Sort();
                for (int k = 0; k + 1 < ts.Count; k++)
                {
                    double t0 = ts[k], t1 = ts[k + 1];
                    if (t1 - t0 < 1e-9) continue;
                    double tm = (t0 + t1) / 2;
                    if (Inside(new[] { a[0] + (b[0] - a[0]) * tm, a[1] + (b[1] - a[1]) * tm }, q)) { hid = true; continue; }
                    double[] piece = { a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0, a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1 };
                    double[] last = kept.Count > 0 ? kept[kept.Count - 1] : null;
                    if (last != null && Math.Abs(last[2] - piece[0]) < 1e-9 && Math.Abs(last[3] - piece[1]) < 1e-9 && Math.Abs(Cross(new[] { last[0], last[1] }, new[] { last[2], last[3] }, new[] { piece[2], piece[3] })) < 1e-9)
                    { last[2] = piece[2]; last[3] = piece[3]; }
                    else kept.Add(piece);
                }
            }
            return kept;
        }

        // The rightmost point of the outline at height y (where a note's leader starts); the bounding box edge if the line misses it.
        private static double RightAt(Part part, double y)
        {
            List<double[]> p = part.Outline();
            double best = Double.NegativeInfinity;
            for (int i = 0; i < p.Count; i++)
            {
                double[] u = p[i], v = p[(i + 1) % p.Count];
                if ((u[1] - y) * (v[1] - y) > 0 || u[1] == v[1]) { if (u[1] == y) best = Math.Max(best, Math.Max(u[0], v[0])); continue; }
                best = Math.Max(best, u[0] + (y - u[1]) * (v[0] - u[0]) / (v[1] - u[1]));
            }
            return Double.IsInfinity(best) ? part.X1 : best;
        }
        private static readonly System.Text.RegularExpressions.Regex PartId = new System.Text.RegularExpressions.Regex("^[A-Za-z0-9_-]{1,30}$");

        private static List<IDictionary<string, object>> Objects(IDictionary<string, object> input, string key, int max, bool required)
        {
            object v;
            List<IDictionary<string, object>> list = new List<IDictionary<string, object>>();
            if (!input.TryGetValue(key, out v))
            {
                if (required) throw new ToolException("params." + key + " is required.");
                return list;
            }
            System.Collections.IEnumerable seq = v as System.Collections.IEnumerable;
            if (v is string || seq == null) throw new ToolException("params." + key + " must be a list.");
            int i = 0;
            foreach (object o in seq)
            {
                IDictionary<string, object> d = o as IDictionary<string, object>;
                if (d == null) throw new ToolException("params." + key + "[" + i + "] must be an object.");
                list.Add(d);
                i++;
            }
            if (list.Count == 0 && required) throw new ToolException("params." + key + " needs at least one entry.");
            if (list.Count > max) throw new ToolException("params." + key + " has " + list.Count + " entries; the most allowed is " + max + ".");
            return list;
        }

        private static double[] Pair(object v)
        {
            System.Collections.IEnumerable seq = v as System.Collections.IEnumerable;
            if (v == null || v is string || seq == null) return null;
            List<double> n = new List<double>();
            foreach (object o in seq) { double x; if (!Schema.TryNumber(o, out x) || Math.Abs(x) > 10000) return null; n.Add(x); }
            return n.Count == 2 ? n.ToArray() : null;
        }

        // One outline point: [x, y], [x, y, bulge], or {x, y, bulge | radius | rise}; the arc is that of the segment to the next point.
        private static double[] Vertex(object o, double[] next, string where)
        {
            IDictionary<string, object> d = o as IDictionary<string, object>;
            if (d == null)
            {
                System.Collections.IEnumerable seq = o as System.Collections.IEnumerable;
                if (o == null || o is string || seq == null) return null;
                List<double> n = new List<double>();
                foreach (object v in seq) { double x; if (!Schema.TryNumber(v, out x)) return null; n.Add(x); }
                if (n.Count < 2 || n.Count > 3 || Math.Abs(n[0]) > 10000 || Math.Abs(n[1]) > 10000) return null;
                if (n.Count == 3 && Math.Abs(n[2]) > 10) throw new ToolException(where + ": a bulge must be from -10 to 10 (1 = half circle).");
                return new[] { n[0], n[1], n.Count == 3 ? n[2] : 0 };
            }
            OnlyKeys(d, where, "x", "y", "bulge", "radius", "rise");
            double px = Coord(d, "x", where, -10000, 10000), py = Coord(d, "y", where, -10000, 10000), bulge = 0;
            int ways = (d.ContainsKey("bulge") ? 1 : 0) + (d.ContainsKey("radius") ? 1 : 0) + (d.ContainsKey("rise") ? 1 : 0);
            if (ways > 1) throw new ToolException(where + ": give one of bulge, radius or rise.");
            if (ways == 0) return new[] { px, py, 0.0 };
            if (next == null) throw new ToolException(where + ": radius and rise need the next point; use bulge on the last point instead.");
            double chord = Math.Sqrt((next[0] - px) * (next[0] - px) + (next[1] - py) * (next[1] - py));
            if (chord < 0.01) throw new ToolException(where + ": the arc's two ends are the same point.");
            if (d.ContainsKey("bulge")) { bulge = Coord(d, "bulge", where, -10, 10); }
            else if (d.ContainsKey("rise"))
            {
                double rise = Coord(d, "rise", where, -10000, 10000);   // height of the arc from its chord; positive: anticlockwise, so the arc bows out to the right of the direction of travel
                bulge = 2 * rise / chord;
            }
            else
            {
                double radius = Coord(d, "radius", where, -100000, 100000);   // positive: anticlockwise (the arc bows out to the right of the direction of travel); always the shorter arc
                if (Math.Abs(radius) < chord / 2 - 1e-9) throw new ToolException(where + ": radius " + Mm(Math.Abs(radius)) + " is smaller than half the chord (" + Mm(chord / 2) + ").");
                double half = Math.Asin(Math.Min(1, chord / (2 * Math.Abs(radius))));
                bulge = Math.Sign(radius) * Math.Tan(half / 2);
            }
            if (Math.Abs(bulge) > 10) throw new ToolException(where + ": that arc is too large (bulge over 10).");
            return new[] { px, py, bulge };
        }

        private static void OnlyKeys(IDictionary<string, object> d, string where, params string[] allowed)
        {
            foreach (string k in d.Keys)
                if (Array.IndexOf(allowed, k) < 0) throw new ToolException(where + ": unknown field '" + k + "'. Allowed: " + String.Join(", ", allowed) + ".");
        }

        private static double Coord(IDictionary<string, object> d, string key, string where, double min, double max)
        {
            object v; double n;
            if (!d.TryGetValue(key, out v) || !Schema.TryNumber(v, out n)) throw new ToolException(where + ": '" + key + "' must be a number (mm).");
            if (n < min || n > max) throw new ToolException(where + ": '" + key + "' must be between " + Mm(min) + " and " + Mm(max) + " mm.");
            return n;
        }

        private static string Words(IDictionary<string, object> d, string key, string where, int max, bool required)
        {
            object v;
            if (!d.TryGetValue(key, out v))
            {
                if (required) throw new ToolException(where + ": '" + key + "' is required.");
                return null;
            }
            string t = v as string;
            if (t == null || t.Trim().Length == 0 || t.Length > max || t.IndexOf('\n') >= 0) throw new ToolException(where + ": '" + key + "' must be one line of text, 1 to " + max + " characters.");
            return t;
        }

        // custom_section: the caller supplies the parts, materials, levels, notes and dimensions it read from pictures and plans. Nothing is
        // invented here: every wording and every number is the caller's, and the generator only draws it, checks it and annotates it.
        private static DetailResult BuildCustom(IDictionary<string, object> input, int scale, double ox, double oy, string dimStyle, string textStyle, double dimScale, DetailAnnotation place)
        {
            foreach (string key in input.Keys)
                if (Array.IndexOf(CustomAllowed, key) < 0) throw new ToolException("Unknown parameter: " + key + ". Allowed: " + String.Join(", ", CustomAllowed) + ".");
            double d = scale;
            DetailResult r = new DetailResult();
            r.Scale = scale; r.Annotation = place.Mode; r.Place = place; r.HeightUnit = place.Mode == "paper" ? 1 : scale;

            // ---- view ----
            string view = "section";
            if (input.ContainsKey("view"))
            {
                view = Words(input, "view", "params", 20, true);
                if (view != "section" && view != "elevation" && view != "plan") throw new ToolException("params.view must be section, elevation or plan.");
            }
            bool cut = view == "section";

            // ---- parts ----
            List<Part> parts = new List<Part>();
            List<IDictionary<string, object>> given = Objects(input, "parts", MaxCustomParts, true);
            for (int i = 0; i < given.Count; i++)
            {
                string at = "params.parts[" + i + "]";
                IDictionary<string, object> p = given[i];
                OnlyKeys(p, at, "id", "material", "x0", "y0", "x1", "y1", "points", "repeat", "hatch");
                string id = Words(p, "id", at, 30, true);
                if (!PartId.IsMatch(id)) throw new ToolException(at + ": id may use letters, digits, '_' and '-' only (up to 30).");
                string material = Words(p, "material", at, 20, true);
                if (Array.IndexOf(Materials, material) < 0) throw new ToolException(at + ": material must be one of: " + String.Join(", ", Materials) + ".");

                Part shape = new Part { Id = id, Material = material };
                if (p.ContainsKey("points"))
                {
                    if (p.ContainsKey("x0") || p.ContainsKey("y0") || p.ContainsKey("x1") || p.ContainsKey("y1")) throw new ToolException(at + " ('" + id + "'): give either points or x0, y0, x1, y1, not both.");
                    System.Collections.IEnumerable seq = p["points"] as System.Collections.IEnumerable;
                    List<object> rawPts = new List<object>();
                    if (seq != null && !(p["points"] is string)) foreach (object o in seq) rawPts.Add(o);
                    if (rawPts.Count < 3 || rawPts.Count > 100) throw new ToolException(at + " ('" + id + "'): points must be a list of 3 to 100 [x, y] points in mm (within 10 m).");
                    // first pass for plain coordinates (radius and rise need the next point)
                    List<double[]> plain = new List<double[]>();
                    foreach (object o in rawPts)
                    {
                        IDictionary<string, object> od = o as IDictionary<string, object>;
                        double px2, py2;
                        if (od != null && od.ContainsKey("x") && od.ContainsKey("y") && Schema.TryNumber(od["x"], out px2) && Schema.TryNumber(od["y"], out py2)) { plain.Add(new[] { px2, py2 }); continue; }
                        double[] v0 = od == null ? Vertex(o, null, at + " ('" + id + "')") : null;
                        plain.Add(v0 == null ? null : new[] { v0[0], v0[1] });
                    }
                    if (plain.Any(q => q == null)) throw new ToolException(at + " ('" + id + "'): points must be a list of 3 to 100 [x, y] points in mm (within 10 m).");
                    bool closingRepeated = plain.Count > 3 && Math.Abs(plain[0][0] - plain[plain.Count - 1][0]) < 1e-9 && Math.Abs(plain[0][1] - plain[plain.Count - 1][1]) < 1e-9;
                    int count0 = closingRepeated ? plain.Count - 1 : plain.Count;
                    List<double[]> pts = new List<double[]>();
                    List<double> bulges = new List<double>();
                    for (int k = 0; k < count0; k++)
                    {
                        double[] v = Vertex(rawPts[k], plain[(k + 1) % count0], at + " ('" + id + "') point " + k);
                        if (v == null) throw new ToolException(at + " ('" + id + "'): points must be a list of 3 to 100 [x, y] points in mm (within 10 m).");
                        pts.Add(new[] { v[0], v[1] });
                        bulges.Add(v[2]);
                    }
                    if (closingRepeated && rawPts[plain.Count - 1] is IDictionary<string, object> && ((IDictionary<string, object>)rawPts[plain.Count - 1]).Keys.Any(key => key != "x" && key != "y"))
                        throw new ToolException(at + " ('" + id + "'): put the arc on the point where it starts, not on the repeated closing point.");
                    if (bulges.Any(b => b != 0)) shape.Bulges = bulges;
                    for (int k = 0; k < pts.Count; k++)
                        if (Math.Abs(pts[k][0] - pts[(k + 1) % pts.Count][0]) < 0.01 && Math.Abs(pts[k][1] - pts[(k + 1) % pts.Count][1]) < 0.01) throw new ToolException(at + " ('" + id + "'): point " + k + " repeats the next point.");
                    List<double[]> fl = shape.Bulges == null ? pts : Flatten(pts, shape.Bulges);
                    for (int k = 0; k < fl.Count; k++)
                        for (int m = k + 1; m < fl.Count; m++)
                        {
                            if (m == k + 1 || (k == 0 && m == fl.Count - 1)) continue;   // neighbouring edges share a point
                            if (SegmentsTouch(fl[k], fl[(k + 1) % fl.Count], fl[m], fl[(m + 1) % fl.Count]))
                                throw new ToolException(at + " ('" + id + "'): the outline crosses itself" + (shape.Bulges == null ? " (edges " + k + " and " + m + ")." : " (check the arcs)."));
                        }
                    if (Math.Abs(Area(fl)) < 1) throw new ToolException(at + " ('" + id + "'): the points enclose no area.");
                    shape.Pts = pts;
                    shape.X0 = fl.Min(q => q[0]); shape.X1 = fl.Max(q => q[0]); shape.Y0 = fl.Min(q => q[1]); shape.Y1 = fl.Max(q => q[1]);
                }
                else
                {
                    shape.X0 = Coord(p, "x0", at, -10000, 10000); shape.Y0 = Coord(p, "y0", at, -10000, 10000); shape.X1 = Coord(p, "x1", at, -10000, 10000); shape.Y1 = Coord(p, "y1", at, -10000, 10000);
                    if (shape.X1 - shape.X0 < 1 || shape.Y1 - shape.Y0 < 1) throw new ToolException(at + " ('" + id + "'): x1 must exceed x0 and y1 must exceed y0, each by at least 1 mm.");
                }

                if (p.ContainsKey("hatch"))
                {
                    if (p["hatch"] is string)
                    {
                        if ((string)p["hatch"] != "none") throw new ToolException(at + ": hatch must be \"none\" or an object {pattern, scale?, angle?}.");
                        shape.HatchPattern = "none";
                    }
                    else
                    {
                        IDictionary<string, object> h = p["hatch"] as IDictionary<string, object>;
                        if (h == null) throw new ToolException(at + ": hatch must be \"none\" or an object {pattern, scale?, angle?}.");
                        OnlyKeys(h, at + ".hatch", "pattern", "scale", "angle");
                        shape.HatchPattern = Words(h, "pattern", at + ".hatch", 31, true).ToUpperInvariant();
                        if (h.ContainsKey("scale")) shape.HatchScale = Coord(h, "scale", at + ".hatch", 0.001, 100);
                        if (h.ContainsKey("angle")) shape.HatchAngle = Coord(h, "angle", at + ".hatch", -360, 360);
                    }
                }

                int count = 1; double px = 0, py = 0;
                if (p.ContainsKey("repeat"))
                {
                    IDictionary<string, object> rep = p["repeat"] as IDictionary<string, object>;
                    if (rep == null) throw new ToolException(at + ": repeat must be an object {count, pitch_x?, pitch_y?}.");
                    OnlyKeys(rep, at + ".repeat", "count", "pitch_x", "pitch_y");
                    double c = Coord(rep, "count", at + ".repeat", 2, MaxCustomParts);
                    if (Math.Truncate(c) != c) throw new ToolException(at + ".repeat: count must be a whole number.");
                    count = (int)c;
                    if (rep.ContainsKey("pitch_x")) px = Coord(rep, "pitch_x", at + ".repeat", -10000, 10000);
                    if (rep.ContainsKey("pitch_y")) py = Coord(rep, "pitch_y", at + ".repeat", -10000, 10000);
                    if (Math.Abs(px) < 1 && Math.Abs(py) < 1) throw new ToolException(at + ".repeat: give pitch_x or pitch_y of at least 1 mm.");
                }
                for (int k = 0; k < count; k++)
                {
                    string pid = count == 1 ? id : id + "-" + (k + 1);
                    if (parts.Any(q => String.Equals(q.Id, pid, StringComparison.OrdinalIgnoreCase) || String.Equals(q.Group, pid, StringComparison.OrdinalIgnoreCase)) || (count > 1 && parts.Any(q => String.Equals(q.Id, id, StringComparison.OrdinalIgnoreCase))))
                        throw new ToolException(at + ": id '" + pid + "' is used twice.");
                    if (parts.Count >= MaxCustomParts) throw new ToolException("More than " + MaxCustomParts + " parts after repeats. Split the view into two calls.");
                    double dx = px * k, dy = py * k;
                    Part part = new Part
                    {
                        Id = pid, Group = count > 1 ? id : null, Material = material, HatchPattern = shape.HatchPattern, HatchScale = shape.HatchScale, HatchAngle = shape.HatchAngle,
                        X0 = shape.X0 + dx, X1 = shape.X1 + dx, Y0 = shape.Y0 + dy, Y1 = shape.Y1 + dy,
                        Pts = shape.Pts == null ? null : shape.Pts.Select(q => new[] { q[0] + dx, q[1] + dy }).ToList(),
                        Bulges = shape.Bulges
                    };
                    if (Math.Abs(part.X0) > 10000 || Math.Abs(part.X1) > 10000 || Math.Abs(part.Y0) > 10000 || Math.Abs(part.Y1) > 10000) throw new ToolException(at + ": repeat '" + pid + "' falls outside 10 m.");
                    parts.Add(part);
                }
            }
            if (cut)
                for (int i = 0; i < parts.Count; i++)
                    for (int j = i + 1; j < parts.Count; j++)
                    {
                        double w = Math.Min(parts[i].X1, parts[j].X1) - Math.Max(parts[i].X0, parts[j].X0);
                        double h = Math.Min(parts[i].Y1, parts[j].Y1) - Math.Max(parts[i].Y0, parts[j].Y0);
                        if (w <= 0.01 || h <= 0.01) continue;
                        if (parts[i].Pts == null && parts[j].Pts == null)
                            throw new ToolException("The parts '" + parts[i].Id + "' and '" + parts[j].Id + "' overlap by " + Mm(w) + " x " + Mm(h) + " mm. Check the dimensions read from the pictures.");
                        if (Overlap(parts[i].Outline(), parts[j].Outline()))
                            throw new ToolException("The parts '" + parts[i].Id + "' and '" + parts[j].Id + "' overlap. In a section, parts are cut and cannot overlap; check the points.");
                    }
            // elevation and plan: a part listed later is nearer the viewer and hides the lines of earlier parts behind it
            bool hideLines = !cut;
            object hiddenFlag;
            if (input.TryGetValue("hidden_lines", out hiddenFlag)) { if (!(hiddenFlag is bool)) throw new ToolException("params.hidden_lines must be true or false."); hideLines = (bool)hiddenFlag && !cut; }
            List<string> hiddenParts = new List<string>();
            if (hideLines)
                for (int i = 0; i < parts.Count; i++)
                {
                    List<double[]> o = parts[i].Outline();
                    List<double[]> segs = new List<double[]>();
                    for (int k = 0; k < o.Count; k++) segs.Add(new[] { o[k][0], o[k][1], o[(k + 1) % o.Count][0], o[(k + 1) % o.Count][1] });
                    bool hid = false;
                    for (int j = i + 1; j < parts.Count; j++)
                    {
                        if (Math.Min(parts[i].X1, parts[j].X1) - Math.Max(parts[i].X0, parts[j].X0) <= 0.01 || Math.Min(parts[i].Y1, parts[j].Y1) - Math.Max(parts[i].Y0, parts[j].Y0) <= 0.01) continue;
                        segs = HideBehind(segs, parts[j].Outline(), ref hid);
                    }
                    if (!hid) continue;
                    parts[i].Visible = segs;
                    hiddenParts.Add(parts[i].Id);
                    if (parts[i].HatchPattern != null && parts[i].HatchPattern != "none") r.Warnings.Add("The hatch of '" + parts[i].Id + "' was left out because nearer parts hide part of it.");
                }

            double minX = parts.Min(q => q.X0), minY = Math.Min(0, parts.Min(q => q.Y0)), maxX = parts.Max(q => q.X1), maxY = parts.Max(q => q.Y1);
            if (view == "plan") minY = parts.Min(q => q.Y0);
            double bx0 = minX, by0 = parts.Min(q => q.Y0);
            if (maxX - minX > 10000 || maxY - minY > 10000) throw new ToolException("The parts span more than 10 m; check the dimensions.");

            // ---- lines (LED strips and other single lines that belong to the drawing, not to the annotation) ----
            List<IDictionary<string, object>> lineSpecs = Objects(input, "lines", 100, false);
            List<double[]> lineGeo = new List<double[]>();
            List<string> lineLayers = new List<string>();
            for (int i = 0; i < lineSpecs.Count; i++)
            {
                string at = "params.lines[" + i + "]";
                OnlyKeys(lineSpecs[i], at, "from", "to", "kind");
                double[] a = Pair(lineSpecs[i].ContainsKey("from") ? lineSpecs[i]["from"] : null), b = Pair(lineSpecs[i].ContainsKey("to") ? lineSpecs[i]["to"] : null);
                if (a == null || b == null) throw new ToolException(at + ": 'from' and 'to' must be [x, y] points in mm (within 10 m).");
                if (Math.Abs(a[0] - b[0]) < 0.01 && Math.Abs(a[1] - b[1]) < 0.01) throw new ToolException(at + ": 'from' and 'to' are the same point.");
                string kind = lineSpecs[i].ContainsKey("kind") ? Words(lineSpecs[i], "kind", at, 10, true) : "line";
                if (kind != "led" && kind != "line") throw new ToolException(at + ": kind must be led (the scheme's lighting layer) or line (its outline layer).");
                lineGeo.Add(new[] { a[0], a[1], b[0], b[1] });
                lineLayers.Add(kind);
            }

            // ---- the caller's annotation ----
            List<IDictionary<string, object>> levels = Objects(input, "levels", 12, false);
            List<IDictionary<string, object>> notes = Objects(input, "notes", 30, false);
            List<IDictionary<string, object>> dims = Objects(input, "dimensions", 30, false);
            bool overall = true, floor = view != "plan";
            object flag;
            if (input.TryGetValue("overall_dimensions", out flag)) { if (!(flag is bool)) throw new ToolException("params.overall_dimensions must be true or false."); overall = (bool)flag; }
            if (input.TryGetValue("floor", out flag)) { if (!(flag is bool)) throw new ToolException("params.floor must be true or false."); floor = (bool)flag; }
            string titleText = view.ToUpperInvariant();
            if (input.ContainsKey("title")) titleText = Words(input, "title", "params", 80, true);

            DetailScheme scheme = ResolveScheme(place, view);
            Emitter em = new Emitter(r, ox, oy, scale, dimStyle, textStyle, dimScale, scheme);
            em.Layers();
            if (floor) em.Floor(minX - 26 * d, maxX + 12 * d);
            em.Parts(parts, cut);
            for (int i = 0; i < lineGeo.Count; i++) em.Line(lineGeo[i][0], lineGeo[i][1], lineGeo[i][2], lineGeo[i][3], lineLayers[i] == "led" ? scheme.Light : scheme.Outline);

            int maxChain = 0;
            for (int i = 0; i < dims.Count; i++)
            {
                string at = "params.dimensions[" + i + "]";
                IDictionary<string, object> g = dims[i];
                OnlyKeys(g, at, "from", "to", "axis", "chain");
                double[] a, b;
                a = Pair(g.ContainsKey("from") ? g["from"] : null); b = Pair(g.ContainsKey("to") ? g["to"] : null);
                if (a == null || b == null) throw new ToolException(at + ": 'from' and 'to' must be [x, y] points in mm (within 10 m).");
                string axis = Words(g, "axis", at, 1, true);
                if (axis != "x" && axis != "y") throw new ToolException(at + ": axis must be x (a horizontal dimension, below the detail) or y (a vertical dimension, on the left).");
                int chain = 1;
                if (g.ContainsKey("chain")) { double c = Coord(g, "chain", at, 1, 4); if (Math.Truncate(c) != c) throw new ToolException(at + ": chain must be 1, 2, 3 or 4."); chain = (int)c; }
                if ((axis == "x" ? Math.Abs(b[0] - a[0]) : Math.Abs(b[1] - a[1])) < 1) throw new ToolException(at + ": the two points must differ by at least 1 mm along the axis.");
                maxChain = Math.Max(maxChain, chain);
                if (axis == "x") em.Dim(a[0], a[1], b[0], b[1], (a[0] + b[0]) / 2.0, minY - 10 * d * chain, 0);
                else em.Dim(a[0], a[1], b[0], b[1], minX - (10 + 8 * (chain - 1)) * d, (a[1] + b[1]) / 2.0, 90);
            }
            if (overall)
            {
                int c = Math.Min(maxChain + 1, 5);
                em.Dim(minX, minY, maxX, minY, (minX + maxX) / 2.0, minY - 10 * d * c, 0);
                em.Dim(minX, minY, minX, maxY, minX - (10 + 8 * (c - 1)) * d, (minY + maxY) / 2.0, 90);
            }

            double markX = minX - 80 * d;
            for (int i = 0; i < levels.Count; i++)
            {
                string at = "params.levels[" + i + "]";
                OnlyKeys(levels[i], at, "y", "label", "elevation", "description");
                bool hasLabel = levels[i].ContainsKey("label"), hasElevation = levels[i].ContainsKey("elevation");
                if (hasLabel == hasElevation) throw new ToolException(at + ": give either 'label' (one line of text) or 'elevation' with an optional 'description' (the office level block's two lines).");
                if (levels[i].ContainsKey("description") && !hasElevation) throw new ToolException(at + ": 'description' goes with 'elevation'.");
                double ly = Coord(levels[i], "y", at, -10000, 20000);
                if (hasLabel) em.Level(ly, Words(levels[i], "label", at, 80, true), null, markX);
                else em.Level(ly, Words(levels[i], "elevation", at, 40, true), levels[i].ContainsKey("description") ? Words(levels[i], "description", at, 40, true) : null, markX);
            }

            double noteX = maxX + 34 * d;
            HashSet<string> noted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < notes.Count; i++)
            {
                string at = "params.notes[" + i + "]";
                OnlyKeys(notes[i], at, "part", "text", "y");
                string partId = Words(notes[i], "part", at, 30, true);
                Part target = parts.FirstOrDefault(q => String.Equals(q.Id, partId, StringComparison.OrdinalIgnoreCase));
                List<Part> members = parts.Where(q => String.Equals(q.Group, partId, StringComparison.OrdinalIgnoreCase)).ToList();
                if (target == null && members.Count > 0) target = members.OrderByDescending(q => q.X1).First();   // a group: its rightmost member, nearest the notes
                if (target == null) throw new ToolException(at + ": part '" + partId + "' is not in params.parts.");
                double y = notes[i].ContainsKey("y") ? Coord(notes[i], "y", at, target.Y0, target.Y1) : (target.Y0 + target.Y1) / 2.0;
                em.Note(RightAt(target, y), y, Words(notes[i], "text", at, 120, true), noteX);
                noted.Add(target.Id);
                foreach (Part m in members) noted.Add(m.Id);
            }
            em.FlushNotes(r);
            if (notes.Count == 0) r.Warnings.Add("No notes were given: the materials and thicknesses are not annotated. Add params.notes from the specification.");
            else
            {
                string[] bare = parts.Where(q => !noted.Contains(q.Id)).Select(q => q.Group ?? q.Id).Distinct().ToArray();
                if (bare.Length > 0) r.Warnings.Add("Parts without a note: " + String.Join(", ", bare) + ". Add a note or confirm that they are covered by another.");
            }

            double ty = minY - 40 * d;
            em.Title(minX, ty, titleText, scale);

            em.Finish();
            Place(r, place, scale, dimScale, bx0, by0, maxX, maxY, ox, oy);
            r.Summary["template"] = CustomSection;
            r.Summary["view"] = view;
            r.Summary["annotation"] = place.Mode;
            r.Summary["scale"] = "1:" + scale;
            r.Summary["parts"] = parts.Select(q => q.Group ?? q.Id).Distinct().ToArray();
            r.Summary["part_count"] = parts.Count;
            if (hiddenParts.Count > 0) r.Summary["partly_hidden_parts"] = hiddenParts.ToArray();
            r.Summary["materials"] = parts.Select(q => q.Material).Distinct().ToArray();
            r.Summary["overall_width"] = maxX - minX;
            r.Summary["overall_height"] = maxY - minY;
            r.Summary["units"] = "mm";
            r.Summary["note"] = "Every dimension, material and note is as given; the generator does not check the design against any code or against the pictures.";
            r.Summary["steps"] = r.Items.Count + r.PaperItems.Count;
            if (r.Items.Count > AutoCadPlan.MaxItems || r.PaperItems.Count > AutoCadPlan.MaxItems)
                throw new ToolException("This view needs " + Math.Max(r.Items.Count, r.PaperItems.Count) + " steps in one plan; the most is " + AutoCadPlan.MaxItems + ". Split it into two calls (for example half of the repeated parts each).");
            AutoCadPlan.Parse(r.Items.Cast<object>().ToArray());
            if (r.PaperItems.Count > 0) AutoCadPlan.Parse(r.PaperItems.Cast<object>().ToArray());
            return r;
        }

        internal const string OfficeLeaderBlock = "Multiple Leader Lab", OfficeLevelBlock = "level indicator", OfficeTitleBlock = "DWG-VIEWTITLE";
        private const double OfficeLevelScale = 0.015984;   // the office level indicator is inserted at this scale on the counter sheets

        // The block to use for a kind of annotation, or null. Only in paper mode. With the drawing known, a block is used when the drawing has it
        // (a requested block that is missing is reported); in a preview, asking for the office layers or naming a block takes it as present.
        private static string BlockFor(DetailAnnotation place, string requested, string office, DetailResult r)
        {
            if (place.Mode != "paper") return null;
            string name = requested ?? office;
            if (place.Facts != null)
            {
                if (place.Facts.Blocks.Contains(name)) return name;
                if (requested != null) r.Warnings.Add("Block '" + requested + "' is not in the drawing, so the plain annotation is used instead.");
                return null;
            }
            return (requested != null || place.Scheme == "ao") ? name : null;
        }

        // Which layer set a detail uses. auto picks the office counter-sheet set (ao) when the drawing already has its layers, otherwise the
        // generator's own set; without a drawing (a preview) auto is the generator's own set. generic and ao force a set.
        internal static string SchemeName(DetailAnnotation place)
        {
            if (place.Scheme == "generic" || place.Scheme == "ao") return place.Scheme;
            if (place.Facts != null && new[] { "AO_DIMZ", "0_AO_DIMZ", "AO-Z.Lvl", "AO-MDF_SECTION_PLAN", "AO-CORIAN C-TOP" }.Any(n => place.Facts.Layers.Contains(n))) return "ao";
            return "generic";
        }

        internal static DetailScheme ResolveScheme(DetailAnnotation place, string view)
        {
            if (place.Scheme != "auto" && place.Scheme != "generic" && place.Scheme != "ao") throw new ToolException("layer_scheme must be auto, generic or ao.");
            return SchemeName(place) == "ao" ? DetailScheme.Ao(view) : DetailScheme.Generic();
        }

        // Builds the plan. scale is the detail scale denominator (10 for 1:10); origin is where the floor line meets the staff face.
        internal static DetailResult Build(string template, IDictionary<string, object> input, int scale, double ox, double oy, string dimStyle, string textStyle, double dimScale)
        {
            return Build(template, input, scale, ox, oy, dimStyle, textStyle, dimScale, null);
        }

        internal static DetailResult Build(string template, IDictionary<string, object> input, int scale, double ox, double oy, string dimStyle, string textStyle, double dimScale, DetailAnnotation place)
        {
            if (place == null) place = new DetailAnnotation();
            if (place.Mode != "model" && place.Mode != "paper" && place.Mode != "none") throw new ToolException("annotation must be model, paper or none.");
            if (place.Mode == "paper" && place.PaperCentre == null) throw new ToolException("annotation paper needs view.paper_centre: where the detail sits on the sheet, as [x, y] in paper millimetres.");
            if (place.LevelBlock != null && place.Mode != "paper") throw new ToolException("level_block is used with annotation paper only.");
            if (template != ReceptionCounterSection && template != CustomSection) throw new ToolException("Unknown template: " + template + ". Available: " + ReceptionCounterSection + ", " + CustomSection + ".");
            if (scale < 1 || scale > 200) throw new ToolException("scale must be between 1 and 200.");
            if (input == null) input = new Dictionary<string, object>();
            if (template == CustomSection) return BuildCustom(input, scale, ox, oy, dimStyle, textStyle, dimScale, place);
            foreach (string key in input.Keys)
                if (Array.IndexOf(Allowed, key) < 0) throw new ToolException("Unknown parameter: " + key + ". Allowed: " + String.Join(", ", Allowed) + ".");

            string section = Choice(input, "section", "standard", "standard", "accessible");
            bool accessible = section == "accessible";
            string topMaterial = Choice(input, "top_material", "corian", "corian", "stone");
            double T = Num(input, "board_thickness", 18, 6, 50);
            double H = Num(input, "height", 900, 300, 1500);
            double D = Num(input, "depth", 600, 250, 1500);
            double PH = Num(input, "plinth_height", 100, 0, 300);
            double PS = Num(input, "plinth_setback", 50, 0, 200);
            double FG = Num(input, "floor_clearance", 2, 0, 30);
            double OS = Num(input, "top_overhang_staff", 0, 0, 150);
            double OC = Num(input, "top_overhang_customer", 0, 0, 150);
            double SH = Num(input, "shelf_height", 450, 0, 1500);
            bool bar = Flag(input, "raised_bar");
            double barRise = Num(input, "bar_rise", 200, 50, 600);
            double barDepth = Num(input, "bar_depth", 300, 100, 800);

            double accH = 0, kneeH = 0, kneeD = 0; string code = null;
            if (accessible)
            {
                object reference;
                string[] needed = { "accessible_height", "knee_clearance_height", "knee_clearance_depth", "code_reference" };
                foreach (string n in needed)
                    if (!input.ContainsKey(n))
                        throw new ToolException("The accessible section needs " + String.Join(", ", needed) + " from the code you adopt. No values are built in, because they depend on the code and its edition.");
                accH = Num(input, "accessible_height", 0, 300, 1200);
                kneeH = Num(input, "knee_clearance_height", 0, 100, 1200);
                kneeD = Num(input, "knee_clearance_depth", 0, 100, 1000);
                input.TryGetValue("code_reference", out reference);
                code = reference as string;
                if (code == null || code.Trim().Length < 3 || code.Length > 80) throw new ToolException("params.code_reference must name the code and edition used (3 to 80 characters).");
                if (bar) throw new ToolException("raised_bar applies to the standard section only.");
                H = accH;
            }

            DetailResult r = new DetailResult();
            r.Scale = scale;
            r.Annotation = place.Mode;
            r.Place = place;
            r.HeightUnit = place.Mode == "paper" ? 1 : scale;
            double tf = topMaterial == "stone" ? StoneThickness : CorianThickness;     // finish thickness
            double ts = T;                                                              // substrate under the finish
            string subMaterial = topMaterial == "stone" ? "ply" : "mdf";
            double topUnder = H - tf - ts;
            double d = scale;                                                           // model millimetres per paper millimetre
            double textH = 2.5 * d;                                                     // notes and levels: the reference sheets use 2.5 mm leader text

            // ---- checks that the brief can be built ----
            if (topUnder - (PH + T) < 120) throw new ToolException("The height is too small for the plinth, bottom panel and top: less than 120 mm of carcass remains.");
            if (FG >= PH && PH > 0) throw new ToolException("params.floor_clearance must be smaller than plinth_height.");
            double boxDepth = accessible ? D - kneeD : D;
            if (boxDepth < 2 * T + 100) throw new ToolException(accessible ? "The knee clearance depth leaves less than 100 mm of carcass behind it." : "params.depth is too small for two boards and 100 mm of space.");
            if (2 * (PS + T) + 50 > boxDepth) throw new ToolException("params.plinth_setback is too large for the depth.");
            if (accessible && topUnder < kneeH) throw new ToolException("Knee clearance cannot be met: the underside of the top is " + Mm(topUnder) + " mm above the floor but " + Mm(kneeH) + " mm is required. Raise accessible_height or use a thinner top.");
            if (SH > 0 && (SH < PH + T + 50 || SH + T > topUnder - 50)) throw new ToolException("params.shelf_height must leave 50 mm clear above the bottom panel and below the top (use 0 for no shelf).");
            if (bar && barRise < tf + ts + 100) throw new ToolException("params.bar_rise must be at least " + Mm(tf + ts + 100) + " mm to leave 100 mm between the counter top and the underside of the bar.");
            if (bar && barDepth > D) throw new ToolException("params.bar_depth cannot exceed the depth.");
            if (bar && barDepth > 350) r.Warnings.Add("The raised bar overhangs " + Mm(barDepth) + " mm from its riser: add a support or confirm the cantilever with the fabricator.");

            // ---- boards, in section coordinates (x from the staff face to the customer face, y up from the floor) ----
            List<Part> boards = new List<Part>();
            Action<string, string, double, double, double, double> add = (id, material, x0, y0, x1, y1) => boards.Add(new Part { Id = id, Material = material, X0 = x0, Y0 = y0, X1 = x1, Y1 = y1 });
            double topEndX = D + OC;
            double barTop = H + barRise;
            if (!accessible)
            {
                add("bottom", "mdf", 0, PH, D, PH + T);
                add("staff", "mdf", 0, PH + T, T, topUnder);
                add("cust", "mdf", D - T, PH + T, D, bar ? barTop - tf - ts : topUnder);
                if (SH > 0) add("shelf", "mdf", T, SH, D - T, SH + T);
                double topX1 = bar ? D - T : topEndX;
                add("topsub", subMaterial, -OS, topUnder, topX1, topUnder + ts);
                add("topfin", topMaterial, -OS, topUnder + ts, topX1, H);
                if (bar)
                {
                    add("barsub", subMaterial, D - barDepth, barTop - tf - ts, topEndX, barTop - tf);
                    add("barfin", topMaterial, D - barDepth, barTop - tf, topEndX, barTop);
                }
                if (PH > FG)
                {
                    add("plinthS", "mdf", PS, FG, PS + T, PH);
                    add("plinthC", "mdf", D - PS - T, FG, D - PS, PH);
                }
            }
            else
            {
                add("bottom", "mdf", 0, PH, boxDepth, PH + T);
                add("staff", "mdf", 0, PH + T, T, topUnder);
                add("kneepanel", "mdf", boxDepth - T, PH + T, boxDepth, topUnder);
                if (SH > 0 && SH + T <= topUnder - 50) add("shelf", "mdf", T, SH, boxDepth - T, SH + T);
                add("topsub", subMaterial, -OS, topUnder, topEndX, topUnder + ts);
                add("topfin", topMaterial, -OS, topUnder + ts, topEndX, H);
                if (PH > FG)
                {
                    add("plinthS", "mdf", PS, FG, PS + T, PH);
                    add("plinthK", "mdf", boxDepth - PS - T, FG, boxDepth - PS, PH);
                }
            }
            for (int i = 0; i < boards.Count; i++)
                for (int j = i + 1; j < boards.Count; j++)
                {
                    double w = Math.Min(boards[i].X1, boards[j].X1) - Math.Max(boards[i].X0, boards[j].X0);
                    double h = Math.Min(boards[i].Y1, boards[j].Y1) - Math.Max(boards[i].Y0, boards[j].Y0);
                    if (w > 0.01 && h > 0.01) throw new ToolException("The parts '" + boards[i].Id + "' and '" + boards[j].Id + "' overlap by " + Mm(w) + " x " + Mm(h) + " mm. Check the parameters.");
                }

            // ---- steps ----
            Emitter em = new Emitter(r, ox, oy, scale, dimStyle, textStyle, dimScale, ResolveScheme(place, "section"));
            List<Dictionary<string, object>> items = r.Items;
            Func<double, double, object[]> P = em.P;
            em.Layers();
            em.Floor(-26 * d, Math.Max(D, topEndX) + 12 * d);
            em.Parts(boards);

            // dimensions: vertical chains on the staff side, horizontal chain below, extra on the customer side
            Action<double, double, double, double, double, double, double> dim = em.Dim;
            double chain1 = -10 * d, chain2 = -18 * d, chain3 = -26 * d;
            if (PH > 0) dim(0, 0, 0, PH, chain1, PH / 2.0, 90);
            dim(0, 0, -OS, H, chain2, H / 2.0, 90);
            dim(0, 0, D, 0, D / 2.0, -10 * d, 0);
            if (accessible)
            {
                dim(0, 0, 0, topUnder, chain3, topUnder / 2.0, 90);              // clear height under the top, measured at the staff end of the flat underside
                dim(D - kneeD, 0, D, 0, D - kneeD / 2.0, -20 * d, 0);            // knee clearance depth, in the second chain below the floor
            }
            if (bar)
            {
                dim(-OS, H, D - barDepth, barTop, chain2, (H + barTop) / 2.0, 90);   // the step, stacked on the overall height line
                dim(D - barDepth, barTop, D, barTop, D - barDepth / 2.0, barTop + 10 * d, 0);
            }

            // levels on the left, with a thin reference line stopping before the dimension chains
            double markX = -80 * d;
            Action<double, string, string> level = (y, elevation, description) => em.Level(y, elevation, description, markX);
            level(0, "EL +0.00", "F.F.L.");
            level(H, Level(H), accessible ? "ACCESSIBLE COUNTER TOP" : "COUNTER TOP");
            if (bar) level(barTop, Level(barTop), "BAR TOP");

            // notes with horizontal leaders on the customer side
            double noteX = topEndX + 34 * d;
            Action<double, double, string> note = (targetX, y, text) => em.Note(targetX, y, text, noteX);
            string topNote = topMaterial == "stone"
                ? Mm(StoneThickness) + "MM THK. STONE TOP ON " + Mm(ts) + "MM THK. MARINE PLYWOOD BACKING"
                : Mm(CorianThickness) + "MM THK. SOLID SURFACE (CORIAN) TOP ON " + Mm(ts) + "MM THK. MDF SUBSTRATE";
            double carcassY = PH + T + (topUnder - PH - T) * 0.7;
            double plinthY = (FG + PH) / 2.0;
            if (bar) note(topEndX, barTop - tf / 2.0, topNote + " (ALL TOPS)");
            else note(topEndX, H - tf / 2.0, topNote);
            if (accessible) note(boxDepth, carcassY, Mm(T) + "MM THK. MDF CARCASS IN MELAMINE FINISH");
            else note(D, carcassY, Mm(T) + "MM THK. MDF CARCASS IN MELAMINE FINISH");
            if (PH > FG) note(accessible ? boxDepth - PS : D - PS, plinthY, Mm(T) + "MM THK. MDF PLINTH ON ADJUSTABLE LEGS");
            em.FlushNotes(r);

            // titles
            string title = accessible ? "SECTION X3 - ACCESSIBLE COUNTER" : (bar ? "SECTION X1 - RAISED BAR COUNTER" : "SECTION X2 - RECEPTION COUNTER");
            em.Title(0, -40 * d, title, scale);
            if (accessible) em.Text(0, -52 * d, "ACCESSIBLE COUNTER: HEIGHT AND KNEE CLEARANCE PER " + code.ToUpperInvariant() + " (TO BE VERIFIED)", textH);

            em.Finish();
            Place(r, place, scale, dimScale, boards.Select(x => x.X0).Min(), boards.Select(x => x.Y0).Min(), boards.Select(x => x.X1).Max(), boards.Select(x => x.Y1).Max(), ox, oy);
            r.Summary["annotation"] = place.Mode;

            // ---- summary and a last check that the plan is one apply_plan accepts ----
            r.Summary["template"] = template;
            r.Summary["section"] = section;
            r.Summary["scale"] = "1:" + scale;
            r.Summary["top_material"] = topMaterial;
            r.Summary["height"] = H;
            r.Summary["depth"] = D;
            r.Summary["top_underside_above_floor"] = topUnder;
            if (accessible) { r.Summary["clear_height_under_top"] = topUnder; r.Summary["knee_clearance_depth"] = kneeD; r.Summary["code_reference"] = code; }
            r.Summary["parts"] = boards.Select(b => b.Id).ToArray();
            r.Summary["units"] = "mm";
            AutoCadPlan.Parse(items.Cast<object>().ToArray());
            if (r.PaperItems.Count > 0) AutoCadPlan.Parse(r.PaperItems.Cast<object>().ToArray());
            r.Summary["steps"] = items.Count + r.PaperItems.Count;
            return r;
        }
    }
}
