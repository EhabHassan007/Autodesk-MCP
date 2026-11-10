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

        private const double CorianThickness = 12, StoneThickness = 20;
        private const int NoteGapDenominators = 5;   // notes closer than this many paper millimetres are reported

        // Layers, as in the office set, with this generator's own lineweights (hundredths of a millimetre).
        private const string LCut = "A-DETL-WIDE", LOutline = "A-DETL", LThin = "A-DETL-THIN", LHatch = "A-DETL-GENF", LDim = "A-ANNO-DIMS", LText = "G-ANNO-TEXT";

        private static readonly string[] Allowed =
        {
            "section", "height", "depth", "board_thickness", "plinth_height", "plinth_setback", "floor_clearance", "top_material",
            "top_overhang_staff", "top_overhang_customer", "shelf_height", "raised_bar", "bar_rise", "bar_depth",
            "accessible_height", "knee_clearance_height", "knee_clearance_depth", "code_reference"
        };

        private sealed class Board
        {
            internal string Id, Material;
            internal double X0, Y0, X1, Y1;
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
            if (template != ReceptionCounterSection) throw new ToolException("Unknown template: " + template + ". Available: " + ReceptionCounterSection + ".");
            if (scale < 1 || scale > 200) throw new ToolException("scale must be between 1 and 200.");
            if (input == null) input = new Dictionary<string, object>();
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
            List<Board> boards = new List<Board>();
            Action<string, string, double, double, double, double> add = (id, material, x0, y0, x1, y1) => boards.Add(new Board { Id = id, Material = material, X0 = x0, Y0 = y0, X1 = x1, Y1 = y1 });
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
            List<Dictionary<string, object>> items = r.Items;
            Func<double, double> X = x => Math.Round(ox + x, 3);
            Func<double, double> Y = y => Math.Round(oy + y, 3);
            Func<double, double, object[]> P = (x, y) => new object[] { X(x), Y(y) };
            Action<string, int, int> layer = (name, color, lw) => items.Add(Json.Object("op", "layer", "name", name, "color", color, "lineweight", lw));
            layer(LCut, 214, 50); layer(LOutline, 90, 25); layer(LThin, 151, 13); layer(LHatch, 92, 9); layer(LDim, 211, 13); layer(LText, 231, 13);

            // floor line
            items.Add(Json.Object("op", "line", "layer", LCut, "start", P(-26 * d, 0), "end", P(Math.Max(D, topEndX) + 12 * d, 0)));
            foreach (Board b in boards)
                items.Add(Json.Object("op", "polyline", "id", b.Id, "layer", LCut, "points", new object[] { P(b.X0, b.Y0), P(b.X1, b.Y0), P(b.X1, b.Y1), P(b.X0, b.Y1) }, "closed", true));
            foreach (Board b in boards)
            {
                string pattern; double factor;
                switch (b.Material)
                {
                    case "corian": pattern = "SOLID"; factor = 0; break;
                    case "stone": pattern = "ANSI36"; factor = 0.5; break;
                    case "ply": pattern = "ANSI32"; factor = 0.3; break;
                    default: pattern = "ANSI31"; factor = 0.6; break;
                }
                Dictionary<string, object> hatch = Json.Object("op", "hatch", "layer", LHatch, "pattern", pattern, "boundary", b.Id);
                if (factor > 0) hatch["scale"] = Math.Round(factor * d, 3);
                items.Add(hatch);
            }

            // dimensions: vertical chains on the staff side, horizontal chain below, extra on the customer side
            Action<double, double, double, double, double, double, double> dim = (x0, y0, x1, y1, lx, ly, angle) =>
            {
                Dictionary<string, object> s = Json.Object("op", "dim_rotated", "layer", LDim, "from", P(x0, y0), "to", P(x1, y1), "location", P(lx, ly), "angle", angle);
                if (dimStyle != null) s["style"] = dimStyle;
                s["scale"] = dimScale > 0 ? dimScale : (double)scale;
                items.Add(s);
            };
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
            Action<double, string> level = (y, label) =>
            {
                items.Add(Json.Object("op", "line", "layer", LThin, "start", P(markX, y), "end", P(-30 * d, y)));
                if (place.LevelBlock != null)
                {
                    // the office level block carries the text in an attribute; it stands where the drawn marker and text would be
                    items.Add(Json.Object("op", "insert", "layer", LText, "name", place.LevelBlock, "point", P(markX, y), "scale", place.LevelBlockScale,
                        "attributes", Json.Object(place.LevelTag, label)));
                    return;
                }
                items.Add(Json.Object("op", "line", "layer", LThin, "start", P(markX, y), "end", P(markX - 2 * d, y + 3 * d)));
                items.Add(Json.Object("op", "line", "layer", LThin, "start", P(markX - 2 * d, y + 3 * d), "end", P(markX + 2 * d, y + 3 * d)));
                items.Add(Json.Object("op", "line", "layer", LThin, "start", P(markX + 2 * d, y + 3 * d), "end", P(markX, y)));
                Dictionary<string, object> t = Json.Object("op", "text", "layer", LText, "point", P(markX + 4 * d, y + 1 * d), "text", label, "height", textH);
                if (textStyle != null) t["style"] = textStyle;
                items.Add(t);
            };
            level(0, "EL +0.00 F.F.L.");
            level(H, Level(H) + (accessible ? " ACCESSIBLE COUNTER TOP" : " COUNTER TOP"));
            if (bar) level(barTop, Level(barTop) + " BAR TOP");

            // notes with horizontal leaders on the customer side
            double noteX = topEndX + 34 * d;
            List<double> noteYs = new List<double>();
            Action<double, double, string> note = (targetX, y, text) =>
            {
                items.Add(Json.Object("op", "line", "layer", LThin, "start", P(targetX, y), "end", P(noteX - 2 * d, y)));
                Dictionary<string, object> t = Json.Object("op", "text", "layer", LText, "point", P(noteX, y - 1 * d), "text", text, "height", textH);
                if (textStyle != null) t["style"] = textStyle;
                items.Add(t);
                noteYs.Add(y);
            };
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
            noteYs.Sort();
            for (int i = 1; i < noteYs.Count; i++)
                if (noteYs[i] - noteYs[i - 1] < NoteGapDenominators * d)
                    r.Warnings.Add("Two notes are closer than " + NoteGapDenominators + " mm on paper at 1:" + scale + "; move one by hand.");

            // titles
            string title = accessible ? "SECTION X3 - ACCESSIBLE COUNTER" : (bar ? "SECTION X1 - RAISED BAR COUNTER" : "SECTION X2 - RECEPTION COUNTER");
            Dictionary<string, object> tt = Json.Object("op", "text", "layer", LText, "point", P(0, -40 * d), "text", title, "height", 3.5 * d);
            Dictionary<string, object> ts2 = Json.Object("op", "text", "layer", LText, "point", P(0, -46 * d), "text", "SCALE 1:" + scale, "height", 2.5 * d);
            if (textStyle != null) { tt["style"] = textStyle; ts2["style"] = textStyle; }
            items.Add(tt); items.Add(ts2);
            if (accessible)
            {
                Dictionary<string, object> req = Json.Object("op", "text", "layer", LText, "point", P(0, -52 * d), "text", "ACCESSIBLE COUNTER: HEIGHT AND KNEE CLEARANCE PER " + code.ToUpperInvariant() + " (TO BE VERIFIED)", "height", textH);
                if (textStyle != null) req["style"] = textStyle;
                items.Add(req);
            }

            // ---- where the annotation goes ----
            if (place.Mode != "model")
            {
                double mcx = ox + (boards.Min(b => b.X0) + boards.Max(b => b.X1)) / 2.0, mcy = oy + (boards.Min(b => b.Y0) + boards.Max(b => b.Y1)) / 2.0;
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
                            item["linear_factor"] = (double)d;                                      // measured paper length x scale = the model size
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
                    r.Summary["parts_size_paper_mm"] = new object[] { Math.Round((boards.Max(b => b.X1) - boards.Min(b => b.X0)) / d, 1), Math.Round((boards.Max(b => b.Y1) - boards.Min(b => b.Y0)) / d, 1) };
                    r.Summary["annotation_anchor_extent_paper"] = new object[] { Math.Round(minX, 1), Math.Round(minY, 1), Math.Round(maxX, 1), Math.Round(maxY, 1) };
                    r.Summary["viewport_setup"] = "Viewport at scale 1:" + scale + " (CustomScale " + (1.0 / d).ToString("0.######", CultureInfo.InvariantCulture) + "), view centred on model point " + Mm(mcx) + ", " + Mm(mcy)
                        + ". Annotation is placed assuming exactly that view; AutoCAD does not let this tool set the viewport's view centre.";
                }
            }
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
