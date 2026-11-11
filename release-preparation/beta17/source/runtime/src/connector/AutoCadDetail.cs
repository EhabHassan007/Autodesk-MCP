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
    }

    // Where the annotation goes. model: in model space at the detail scale (the original behaviour). paper: dimensions, notes, levels and titles
    // in a layout at true paper size, around a viewport at 1:scale whose view is centred on the detail. none: geometry only.
    internal sealed class DetailAnnotation
    {
        internal string Mode = "model";
        internal double[] PaperCentre;          // paper position the detail's centre is shown at (centre of the viewport)
        internal double[] ModelCentre;          // model point at that centre; null = the centre of the parts
        internal string LevelBlock, LevelTag = "LEVEL";
        internal double LevelBlockScale = 1;
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
        private const string LCut = "A-DETL-WIDE", LOutline = "A-DETL", LThin = "A-DETL-THIN", LHatch = "A-DETL-GENF", LDim = "A-ANNO-DIMS", LText = "G-ANNO-TEXT", LLight = "A-DETL-LITE";

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
            internal List<double[]> Outline()
            {
                return Pts ?? new List<double[]> { new[] { X0, Y0 }, new[] { X1, Y0 }, new[] { X1, Y1 }, new[] { X0, Y1 } };
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
            internal readonly List<double> NoteYs = new List<double>();

            internal Emitter(DetailResult result, double originX, double originY, int detailScale, string dimensionStyle, string textStyleName, double dimensionScale)
            {
                r = result; ox = originX; oy = originY; scale = detailScale; d = detailScale; dimStyle = dimensionStyle; textStyle = textStyleName; dimScale = dimensionScale;
            }

            internal double TextH { get { return 2.5 * d; } }                         // notes and levels: the reference sheets use 2.5 mm leader text
            internal object[] P(double x, double y) { return new object[] { Math.Round(ox + x, 3), Math.Round(oy + y, 3) }; }

            internal void Layers()
            {
                Action<string, int, int> layer = (name, color, lw) => r.Items.Add(Json.Object("op", "layer", "name", name, "color", color, "lineweight", lw));
                layer(LCut, 214, 50); layer(LOutline, 90, 25); layer(LThin, 151, 13); layer(LHatch, 92, 9); layer(LDim, 211, 13); layer(LText, 231, 13);
            }

            internal void Floor(double fromX, double toX)
            {
                r.Items.Add(Json.Object("op", "line", "layer", LCut, "start", P(fromX, 0), "end", P(toX, 0)));
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
                    if (b.Visible != null) { foreach (double[] g in b.Visible) Line(g[0], g[1], g[2], g[3], LOutline); continue; }   // partly hidden: its visible lines only
                    r.Items.Add(Json.Object("op", "polyline", "id", b.Id, "layer", cut ? LCut : LOutline, "points", b.Outline().Select(q => (object)P(q[0], q[1])).ToArray(), "closed", true));
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
                    Dictionary<string, object> hatch = Json.Object("op", "hatch", "layer", LHatch, "pattern", pattern, "boundary", b.Id);
                    if (factor > 0) hatch["scale"] = Math.Round(factor * d, 3);
                    if (b.HatchPattern != null && b.HatchAngle != 0) hatch["angle"] = b.HatchAngle;
                    if (color > 0) hatch["color"] = color;
                    r.Items.Add(hatch);
                }
            }

            internal void Line(double x0, double y0, double x1, double y1, string layer)
            {
                r.Items.Add(Json.Object("op", "line", "layer", layer, "start", P(x0, y0), "end", P(x1, y1)));
            }

            internal void Dim(double x0, double y0, double x1, double y1, double lx, double ly, double angle)
            {
                Dictionary<string, object> s = Json.Object("op", "dim_rotated", "layer", LDim, "from", P(x0, y0), "to", P(x1, y1), "location", P(lx, ly), "angle", angle);
                if (dimStyle != null) s["style"] = dimStyle;
                s["scale"] = dimScale > 0 ? dimScale : (double)scale;
                r.Items.Add(s);
            }

            internal void Text(double x, double y, string text, double height)
            {
                Dictionary<string, object> t = Json.Object("op", "text", "layer", LText, "point", P(x, y), "text", text, "height", height);
                if (textStyle != null) t["style"] = textStyle;
                r.Items.Add(t);
            }

            internal void Level(double y, string label, double markX)
            {
                r.Items.Add(Json.Object("op", "line", "layer", LThin, "start", P(markX, y), "end", P(-30 * d, y)));
                if (r.Place != null && r.Place.LevelBlock != null)
                {
                    // the office level block carries the text in an attribute; it stands where the drawn marker and text would be
                    r.Items.Add(Json.Object("op", "insert", "layer", LText, "name", r.Place.LevelBlock, "point", P(markX, y), "scale", r.Place.LevelBlockScale,
                        "attributes", Json.Object(r.Place.LevelTag, label)));
                    return;
                }
                r.Items.Add(Json.Object("op", "line", "layer", LThin, "start", P(markX, y), "end", P(markX - 2 * d, y + 3 * d)));
                r.Items.Add(Json.Object("op", "line", "layer", LThin, "start", P(markX - 2 * d, y + 3 * d), "end", P(markX + 2 * d, y + 3 * d)));
                r.Items.Add(Json.Object("op", "line", "layer", LThin, "start", P(markX + 2 * d, y + 3 * d), "end", P(markX, y)));
                Text(markX + 4 * d, y + 1 * d, label, TextH);
            }

            internal void Note(double targetX, double y, string text, double noteX)
            {
                r.Items.Add(Json.Object("op", "line", "layer", LThin, "start", P(targetX, y), "end", P(noteX - 2 * d, y)));
                Text(noteX, y - 1 * d, text, TextH);
                NoteYs.Add(y);
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
                    bool annotation = op != "layer" && (lay == LDim || lay == LText || lay == LThin);
                    if (!annotation) { outItems.Add(item); continue; }
                    if (place.Mode == "none") continue;
                    switch (op)
                    {
                        case "line": item["start"] = map(item["start"]); item["end"] = map(item["end"]); break;
                        case "text": item["point"] = map(item["point"]); item["height"] = Math.Round((double)item["height"] / d, 3); break;
                        case "insert": item["point"] = map(item["point"]); break;
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
                    List<double[]> pts = new List<double[]>();
                    if (seq != null && !(p["points"] is string)) foreach (object o in seq) { double[] q = Pair(o); if (q == null) { pts = null; break; } pts.Add(q); }
                    if (pts == null || pts.Count < 3 || pts.Count > 100) throw new ToolException(at + " ('" + id + "'): points must be a list of 3 to 100 [x, y] points in mm (within 10 m).");
                    if (pts.Count > 3 && Math.Abs(pts[0][0] - pts[pts.Count - 1][0]) < 1e-9 && Math.Abs(pts[0][1] - pts[pts.Count - 1][1]) < 1e-9) pts.RemoveAt(pts.Count - 1);   // closing point repeated
                    for (int k = 0; k < pts.Count; k++)
                        if (Math.Abs(pts[k][0] - pts[(k + 1) % pts.Count][0]) < 0.01 && Math.Abs(pts[k][1] - pts[(k + 1) % pts.Count][1]) < 0.01) throw new ToolException(at + " ('" + id + "'): point " + k + " repeats the next point.");
                    for (int k = 0; k < pts.Count; k++)
                        for (int m = k + 1; m < pts.Count; m++)
                        {
                            if (m == k + 1 || (k == 0 && m == pts.Count - 1)) continue;   // neighbouring edges share a point
                            if (SegmentsTouch(pts[k], pts[(k + 1) % pts.Count], pts[m], pts[(m + 1) % pts.Count])) throw new ToolException(at + " ('" + id + "'): the outline crosses itself (edges " + k + " and " + m + ").");
                        }
                    if (Math.Abs(Area(pts)) < 1) throw new ToolException(at + " ('" + id + "'): the points enclose no area.");
                    shape.Pts = pts;
                    shape.X0 = pts.Min(q => q[0]); shape.X1 = pts.Max(q => q[0]); shape.Y0 = pts.Min(q => q[1]); shape.Y1 = pts.Max(q => q[1]);
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
                        Pts = shape.Pts == null ? null : shape.Pts.Select(q => new[] { q[0] + dx, q[1] + dy }).ToList()
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
                if (kind != "led" && kind != "line") throw new ToolException(at + ": kind must be led (lighting layer " + LLight + ") or line (outline layer " + LOutline + ").");
                lineGeo.Add(new[] { a[0], a[1], b[0], b[1] });
                lineLayers.Add(kind == "led" ? LLight : LOutline);
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

            Emitter em = new Emitter(r, ox, oy, scale, dimStyle, textStyle, dimScale);
            em.Layers();
            if (lineLayers.Contains(LLight)) r.Items.Add(Json.Object("op", "layer", "name", LLight, "color", 2, "lineweight", 18));
            if (floor) em.Floor(minX - 26 * d, maxX + 12 * d);
            em.Parts(parts, cut);
            for (int i = 0; i < lineGeo.Count; i++) em.Line(lineGeo[i][0], lineGeo[i][1], lineGeo[i][2], lineGeo[i][3], lineLayers[i]);

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
                OnlyKeys(levels[i], at, "y", "label");
                em.Level(Coord(levels[i], "y", at, -10000, 20000), Words(levels[i], "label", at, 80, true), markX);
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
            em.CheckNoteGaps(r);
            if (notes.Count == 0) r.Warnings.Add("No notes were given: the materials and thicknesses are not annotated. Add params.notes from the specification.");
            else
            {
                string[] bare = parts.Where(q => !noted.Contains(q.Id)).Select(q => q.Group ?? q.Id).Distinct().ToArray();
                if (bare.Length > 0) r.Warnings.Add("Parts without a note: " + String.Join(", ", bare) + ". Add a note or confirm that they are covered by another.");
            }

            double ty = minY - 40 * d;
            em.Text(minX, ty, titleText, 3.5 * d);
            em.Text(minX, ty - 6 * d, "SCALE 1:" + scale, 2.5 * d);

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
            Emitter em = new Emitter(r, ox, oy, scale, dimStyle, textStyle, dimScale);
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
            Action<double, string> level = (y, label) => em.Level(y, label, markX);
            level(0, "EL +0.00 F.F.L.");
            level(H, Level(H) + (accessible ? " ACCESSIBLE COUNTER TOP" : " COUNTER TOP"));
            if (bar) level(barTop, Level(barTop) + " BAR TOP");

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
            em.CheckNoteGaps(r);

            // titles
            string title = accessible ? "SECTION X3 - ACCESSIBLE COUNTER" : (bar ? "SECTION X1 - RAISED BAR COUNTER" : "SECTION X2 - RECEPTION COUNTER");
            em.Text(0, -40 * d, title, 3.5 * d);
            em.Text(0, -46 * d, "SCALE 1:" + scale, 2.5 * d);
            if (accessible) em.Text(0, -52 * d, "ACCESSIBLE COUNTER: HEIGHT AND KNEE CLEARANCE PER " + code.ToUpperInvariant() + " (TO BE VERIFIED)", textH);

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
