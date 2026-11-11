using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;

namespace SmartConnector
{
    // One checked step of an apply_plan call. Angles are degrees here and converted when the object is created.
    internal sealed class PlanItem
    {
        internal int Index;
        internal string Op, Id, Layer, TextStyle, Text, BlockName, Linetype;
        internal int Color;                    // layer step only; 0 = leave as is
        internal int Lineweight = -1;          // layer step only; -1 = leave as is
        internal double[] Point, End;
        internal double Radius, StartAngle, EndAngle, Height, Width, Rotation;
        internal double Scale = 1;             // insert scale, hatch pattern scale
        internal List<double[]> Vertices;
        internal bool Closed;
        internal string Pattern, DimStyle;     // hatch pattern name; dimension style
        internal string Boundary;              // hatch: id of an earlier closed polyline or circle step
        internal List<string> Holes;           // hatch: ids of earlier closed steps, each an inner loop
        internal double[] Location;            // dimensions: a point the dimension line passes through
        internal double DimScale;              // dimensions: overall scale of sizes (DIMSCALE for this dimension); 0 = the style decides
        internal double LinearFactor;          // dimensions in paper space: the measured value is multiplied by this (DIMLFAC), so a dimension of model geometry reads true; 0 = the style decides
        internal List<KeyValuePair<string, string>> Attributes;   // insert: attribute tag and value
        internal List<double> Bulges;          // polyline: bulge of the segment that starts at each point (0 = straight); null = all straight
    }

    // The pure part of apply_plan: it checks a plan before AutoCAD is contacted, and checks it against the drawing's
    // layers, linetypes, text styles and blocks. No COM here, so the whole plan can be refused without touching the drawing.
    internal static class AutoCadPlan
    {
        internal const int MaxItems = 500;
        internal const int MaxVertices = 2000;
        private const int MaxErrors = 20;

        private static readonly Regex Name = new Regex("^[^<>/\\\\\":;?*|,=`]{1,255}$", RegexOptions.CultureInvariant);
        private static readonly Regex IdPattern = new Regex("^[A-Za-z0-9_.-]{1,40}$", RegexOptions.CultureInvariant);
        // Layer lineweights AutoCAD accepts, in hundredths of a millimetre.
        private static readonly int[] Lineweights = { 0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211 };

        private static readonly Dictionary<string, string[]> Allowed = new Dictionary<string, string[]>
        {
            { "layer", new[] { "op", "id", "name", "color", "linetype", "lineweight" } },
            { "line", new[] { "op", "id", "layer", "start", "end" } },
            { "circle", new[] { "op", "id", "layer", "center", "radius" } },
            { "arc", new[] { "op", "id", "layer", "center", "radius", "start_angle", "end_angle" } },
            { "polyline", new[] { "op", "id", "layer", "points", "closed", "bulges" } },
            { "text", new[] { "op", "id", "layer", "point", "text", "height", "rotation", "style" } },
            { "mtext", new[] { "op", "id", "layer", "point", "width", "text", "height", "rotation", "style" } },
            { "insert", new[] { "op", "id", "layer", "name", "point", "scale", "rotation", "attributes" } },
            { "hatch", new[] { "op", "id", "layer", "pattern", "boundary", "holes", "scale", "angle", "color" } },
            { "dim_aligned", new[] { "op", "id", "layer", "from", "to", "location", "style", "scale", "linear_factor" } },
            { "dim_rotated", new[] { "op", "id", "layer", "from", "to", "location", "angle", "style", "scale", "linear_factor" } }
        };

        private static ToolException Fail(int index, string message)
        {
            return new ToolException("items[" + index.ToString(CultureInfo.InvariantCulture) + "]: " + message);
        }

        internal static List<PlanItem> Parse(object source)
        {
            object[] raw = source as object[];
            if (raw == null) { ArrayList list = source as ArrayList; if (list != null) raw = list.ToArray(); }
            if (raw == null) throw new ToolException("items must be an array of steps.");
            if (raw.Length == 0) throw new ToolException("items is empty.");
            if (raw.Length > MaxItems) throw new ToolException("A plan has at most " + MaxItems + " steps; split it into several calls.");

            List<PlanItem> plan = new List<PlanItem>();
            Dictionary<string, PlanItem> ids = new Dictionary<string, PlanItem>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < raw.Length; i++)
            {
                IDictionary<string, object> d = raw[i] as IDictionary<string, object>;
                if (d == null) throw Fail(i, "a step must be an object.");
                string op = d.ContainsKey("op") ? d["op"] as string : null;
                if (op == null || !Allowed.ContainsKey(op)) throw Fail(i, "op must be one of: " + String.Join(", ", Allowed.Keys.ToArray()) + ".");
                foreach (string key in d.Keys)
                    if (Array.IndexOf(Allowed[op], key) < 0) throw Fail(i, "unknown field '" + key + "' for op '" + op + "'.");

                PlanItem p = new PlanItem { Index = i, Op = op };
                if (d.ContainsKey("id"))
                {
                    string id = d["id"] as string;
                    if (id == null || !IdPattern.IsMatch(id)) throw Fail(i, "id must be 1-40 letters, digits, '_', '.' or '-'.");
                    if (ids.ContainsKey(id)) throw Fail(i, "duplicate id '" + id + "'.");
                    p.Id = id;
                }

                switch (op)
                {
                    case "layer":
                        p.Layer = NameField(d, "name", i, true);
                        if (d.ContainsKey("color"))
                        {
                            p.Color = (int)Number(d, "color", i);
                            if (p.Color < 1 || p.Color > 255 || Number(d, "color", i) != p.Color) throw Fail(i, "color must be an integer from 1 to 255.");
                        }
                        if (d.ContainsKey("linetype")) p.Linetype = NameField(d, "linetype", i, true);
                        if (d.ContainsKey("lineweight"))
                        {
                            double w = Number(d, "lineweight", i);
                            if (Math.Truncate(w) != w || Array.IndexOf(Lineweights, (int)w) < 0) throw Fail(i, "lineweight must be a standard AutoCAD value in hundredths of mm (for example 5, 18, 50, 100).");
                            p.Lineweight = (int)w;
                        }
                        break;
                    case "line":
                        p.Layer = NameField(d, "layer", i, true);
                        p.Point = Point(d, "start", i);
                        p.End = Point(d, "end", i);
                        if (p.Point[0] == p.End[0] && p.Point[1] == p.End[1] && p.Point[2] == p.End[2]) throw Fail(i, "line start and end must differ.");
                        break;
                    case "circle":
                        p.Layer = NameField(d, "layer", i, true);
                        p.Point = Point(d, "center", i);
                        p.Radius = Positive(d, "radius", i);
                        break;
                    case "arc":
                        p.Layer = NameField(d, "layer", i, true);
                        p.Point = Point(d, "center", i);
                        p.Radius = Positive(d, "radius", i);
                        p.StartAngle = Number(d, "start_angle", i);
                        p.EndAngle = Number(d, "end_angle", i);
                        if (p.StartAngle == p.EndAngle) throw Fail(i, "arc start_angle and end_angle must differ.");
                        break;
                    case "polyline":
                        p.Layer = NameField(d, "layer", i, true);
                        p.Vertices = Vertices(d, "points", i);
                        if (d.ContainsKey("closed")) { if (!(d["closed"] is bool)) throw Fail(i, "closed must be true or false."); p.Closed = (bool)d["closed"]; }
                        if (p.Closed && p.Vertices.Count < 3) throw Fail(i, "a closed polyline needs at least 3 points.");
                        if (d.ContainsKey("bulges"))
                        {
                            object[] bulges = AsArray(d["bulges"]);
                            if (bulges == null || bulges.Length != p.Vertices.Count) throw Fail(i, "'bulges' must be a list with one number per point (the arc of the segment that starts there; 0 = straight).");
                            p.Bulges = new List<double>();
                            foreach (object b in bulges)
                            {
                                double v;
                                if (!Schema.TryNumber(b, out v) || Math.Abs(v) > 10) throw Fail(i, "each bulge must be a number from -10 to 10 (1 = half circle).");
                                p.Bulges.Add(v);
                            }
                        }
                        break;
                    case "text":
                    case "mtext":
                        p.Layer = NameField(d, "layer", i, true);
                        p.Point = Point(d, "point", i);
                        p.Text = TextField(d, "text", i, op == "text" ? 500 : 4000);
                        if (op == "text" && p.Text.IndexOf('\n') >= 0) throw Fail(i, "text is one line; use op 'mtext' for several lines.");
                        if (op == "text" || d.ContainsKey("height")) p.Height = Positive(d, "height", i);
                        if (op == "mtext") p.Width = Positive(d, "width", i);
                        if (d.ContainsKey("rotation")) p.Rotation = Number(d, "rotation", i);
                        if (d.ContainsKey("style")) p.TextStyle = NameField(d, "style", i, true);
                        break;
                    case "insert":
                        p.Layer = NameField(d, "layer", i, true);
                        p.BlockName = NameField(d, "name", i, true);
                        p.Point = Point(d, "point", i);
                        if (d.ContainsKey("scale")) p.Scale = Positive(d, "scale", i);
                        if (d.ContainsKey("rotation")) p.Rotation = Number(d, "rotation", i);
                        if (d.ContainsKey("attributes"))
                        {
                            IDictionary<string, object> attributes = d["attributes"] as IDictionary<string, object>;
                            if (attributes == null || attributes.Count == 0 || attributes.Count > 20) throw Fail(i, "'attributes' must be an object of 1 to 20 tag: text pairs.");
                            p.Attributes = new List<KeyValuePair<string, string>>();
                            foreach (KeyValuePair<string, object> pair in attributes)
                            {
                                string value = pair.Value as string;
                                if (pair.Key.Length == 0 || pair.Key.Length > 40 || value == null || value.Length > 255 || value.IndexOf('\n') >= 0)
                                    throw Fail(i, "attribute '" + pair.Key + "' must be a tag of up to 40 characters with a one-line text of up to 255.");
                                p.Attributes.Add(new KeyValuePair<string, string>(pair.Key, value));
                            }
                        }
                        break;
                    case "hatch":
                        p.Layer = NameField(d, "layer", i, true);
                        p.Pattern = PatternName(d, i);
                        p.Boundary = ClosedId(d.ContainsKey("boundary") ? d["boundary"] : null, "boundary", i, ids);
                        if (d.ContainsKey("holes"))
                        {
                            object[] holeIds = AsArray(d["holes"]);
                            if (holeIds == null || holeIds.Length == 0 || holeIds.Length > 50) throw Fail(i, "'holes' must be a list of 1 to 50 step ids.");
                            p.Holes = new List<string>();
                            foreach (object holeId in holeIds)
                            {
                                string hole = ClosedId(holeId, "holes", i, ids);
                                if (String.Equals(hole, p.Boundary, StringComparison.OrdinalIgnoreCase)) throw Fail(i, "a hole cannot be the boundary itself.");
                                p.Holes.Add(hole);
                            }
                        }
                        if (d.ContainsKey("scale")) p.Scale = Positive(d, "scale", i);
                        if (d.ContainsKey("angle")) p.Rotation = Number(d, "angle", i);
                        if (d.ContainsKey("color"))
                        {
                            double c = Number(d, "color", i);
                            if (c < 1 || c > 255 || Math.Truncate(c) != c) throw Fail(i, "color must be an integer from 1 to 255.");
                            p.Color = (int)c;
                        }
                        break;
                    case "dim_aligned":
                    case "dim_rotated":
                        p.Layer = NameField(d, "layer", i, true);
                        p.Point = Point(d, "from", i);
                        p.End = Point(d, "to", i);
                        p.Location = Point(d, "location", i);
                        if (p.Point[0] == p.End[0] && p.Point[1] == p.End[1] && p.Point[2] == p.End[2]) throw Fail(i, "'from' and 'to' must differ.");
                        if (op == "dim_rotated") p.Rotation = Number(d, "angle", i);
                        if (d.ContainsKey("style")) p.DimStyle = NameField(d, "style", i, true);
                        if (d.ContainsKey("scale")) p.DimScale = Positive(d, "scale", i);
                        if (d.ContainsKey("linear_factor")) p.LinearFactor = Positive(d, "linear_factor", i);
                        break;
                }
                if (p.Id != null) ids[p.Id] = p;
                plan.Add(p);
            }
            return plan;
        }

        // Checks the plan against what the drawing already holds. layers maps a layer name to whether it is locked.
        // Layers created by an earlier layer step count as existing, unlocked layers for the steps after it.
        // Returns up to 20 messages; an empty list means the plan can be applied.
        internal static List<string> CheckReferences(List<PlanItem> plan, IDictionary<string, bool> layers, ICollection<string> linetypes, ICollection<string> textStyles, ICollection<string> blocks, ICollection<string> dimStyles)
        {
            List<string> errors = new List<string>();
            Dictionary<string, bool> known = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, bool> pair in layers) known[pair.Key] = pair.Value;
            HashSet<string> lt = new HashSet<string>(linetypes, StringComparer.OrdinalIgnoreCase);
            HashSet<string> st = new HashSet<string>(textStyles, StringComparer.OrdinalIgnoreCase);
            HashSet<string> bl = new HashSet<string>(blocks, StringComparer.OrdinalIgnoreCase);
            HashSet<string> ds = new HashSet<string>(dimStyles, StringComparer.OrdinalIgnoreCase);

            foreach (PlanItem p in plan)
            {
                string at = "items[" + p.Index.ToString(CultureInfo.InvariantCulture) + "]: ";
                if (p.Op == "layer")
                {
                    if (p.Linetype != null && !lt.Contains(p.Linetype)) errors.Add(at + "linetype '" + p.Linetype + "' is not loaded in the drawing.");
                    if (!known.ContainsKey(p.Layer)) known[p.Layer] = false;
                }
                else
                {
                    bool locked;
                    if (!known.TryGetValue(p.Layer, out locked)) errors.Add(at + "layer '" + p.Layer + "' does not exist; add a layer step before it.");
                    else if (locked) errors.Add(at + "layer '" + p.Layer + "' is locked.");
                    if (p.TextStyle != null && !st.Contains(p.TextStyle)) errors.Add(at + "text style '" + p.TextStyle + "' does not exist in the drawing.");
                    if (p.Op == "insert" && !bl.Contains(p.BlockName)) errors.Add(at + "block '" + p.BlockName + "' is not defined in the drawing.");
                    if (p.DimStyle != null && !ds.Contains(p.DimStyle)) errors.Add(at + "dimension style '" + p.DimStyle + "' does not exist in the drawing.");
                }
                if (errors.Count >= MaxErrors) { errors.Add("(more problems not listed)"); break; }
            }
            return errors;
        }

        internal static Dictionary<string, object> Counts(List<PlanItem> plan)
        {
            Dictionary<string, object> counts = new Dictionary<string, object>();
            foreach (PlanItem p in plan) counts[p.Op] = counts.ContainsKey(p.Op) ? (object)((int)counts[p.Op] + 1) : 1;
            return counts;
        }

        internal static List<string> LayersToCreate(List<PlanItem> plan, ICollection<string> existing)
        {
            HashSet<string> have = new HashSet<string>(existing, StringComparer.OrdinalIgnoreCase);
            List<string> result = new List<string>();
            foreach (PlanItem p in plan)
                if (p.Op == "layer" && have.Add(p.Layer)) result.Add(p.Layer);
            return result;
        }

        // A hatch refers to earlier steps by id, and only closed polylines and circles can bound one.
        private static string ClosedId(object value, string key, int index, Dictionary<string, PlanItem> ids)
        {
            string id = value as string;
            PlanItem target;
            if (id == null || !ids.TryGetValue(id, out target) || !(target.Op == "circle" || (target.Op == "polyline" && target.Closed)))
                throw Fail(index, "'" + key + "' must be the id of an earlier closed polyline or circle step (give that step an id).");
            return target.Id;
        }

        private static string PatternName(IDictionary<string, object> d, int index)
        {
            string name = d.ContainsKey("pattern") ? d["pattern"] as string : null;
            if (name == null || !Regex.IsMatch(name, "^[A-Za-z0-9_-]{1,34}$")) throw Fail(index, "'pattern' must be a hatch pattern name such as SOLID, ANSI31 or AR-CONC.");
            return name;
        }

        private static string NameField(IDictionary<string, object> d, string key, int index, bool required)
        {
            object value;
            if (!d.TryGetValue(key, out value)) { if (required) throw Fail(index, "missing '" + key + "'."); return null; }
            string text = value as string;
            if (text == null || text.Trim().Length == 0 || text != text.Trim() || !Name.IsMatch(text)) throw Fail(index, "'" + key + "' must be a valid name (no leading or trailing space, none of < > / \\ \" : ; ? * | , = `).");
            return text;
        }

        private static string TextField(IDictionary<string, object> d, string key, int index, int max)
        {
            object value;
            if (!d.TryGetValue(key, out value)) throw Fail(index, "missing '" + key + "'.");
            string text = value as string;
            if (text == null || text.Trim().Length == 0) throw Fail(index, "'" + key + "' must be non-empty text.");
            if (text.Length > max) throw Fail(index, "'" + key + "' is longer than " + max + " characters.");
            return text;
        }

        private static double Number(IDictionary<string, object> d, string key, int index)
        {
            object value;
            if (!d.TryGetValue(key, out value)) throw Fail(index, "missing '" + key + "'.");
            double number;
            if (!Schema.TryNumber(value, out number)) throw Fail(index, "'" + key + "' must be a finite number.");
            return number;
        }

        private static double Positive(IDictionary<string, object> d, string key, int index)
        {
            double number = Number(d, key, index);
            if (number <= 0) throw Fail(index, "'" + key + "' must be greater than 0.");
            return number;
        }

        private static object[] AsArray(object value)
        {
            object[] items = value as object[];
            if (items == null) { ArrayList list = value as ArrayList; if (list != null) items = list.ToArray(); }
            return items;
        }

        // [x, y] or [x, y, z]; z defaults to 0.
        private static double[] Point(IDictionary<string, object> d, string key, int index)
        {
            object value;
            if (!d.TryGetValue(key, out value)) throw Fail(index, "missing '" + key + "'.");
            return ToPoint(AsArray(value), key, index);
        }

        private static double[] ToPoint(object[] items, string key, int index)
        {
            if (items == null || (items.Length != 2 && items.Length != 3)) throw Fail(index, "'" + key + "' must be [x, y] or [x, y, z].");
            double[] result = new double[3];
            for (int k = 0; k < items.Length; k++)
                if (!Schema.TryNumber(items[k], out result[k])) throw Fail(index, "'" + key + "' coordinates must be finite numbers.");
            return result;
        }

        private static List<double[]> Vertices(IDictionary<string, object> d, string key, int index)
        {
            object value;
            if (!d.TryGetValue(key, out value)) throw Fail(index, "missing '" + key + "'.");
            object[] items = AsArray(value);
            if (items == null || items.Length < 2) throw Fail(index, "'" + key + "' needs at least 2 points.");
            if (items.Length > MaxVertices) throw Fail(index, "'" + key + "' has more than " + MaxVertices + " points.");
            List<double[]> result = new List<double[]>();
            foreach (object item in items)
            {
                object[] pair = AsArray(item);
                if (pair == null || pair.Length != 2) throw Fail(index, "each of '" + key + "' must be [x, y].");
                result.Add(ToPoint(pair, key, index));
            }
            return result;
        }
    }
}
