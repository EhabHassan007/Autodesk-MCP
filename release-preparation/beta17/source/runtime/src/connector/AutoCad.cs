using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

namespace SmartConnector
{
    // IDispatch, which every AutoCAD automation object implements. A hatch loop must reach AutoCAD as an array of automation
    // objects (a SAFEARRAY of VT_DISPATCH, which is what Visual Basic's Object() and AcadEntity() arrays are). An array of this
    // interface is marshaled that way; a plain object[] becomes an array of variants and AutoCAD answers "Invalid object array".
    [System.Runtime.InteropServices.ComImport]
    [System.Runtime.InteropServices.Guid("00020400-0000-0000-C000-000000000046")]
    [System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIDispatch)]
    internal interface IDispatchOnly { }

    // AutoCAD tools, over AutoCAD's own COM automation (full AutoCAD only; AutoCAD LT has none).
    internal static class AutoCadBridge
    {
        private static List<Dictionary<string, object>> _tools;

        // Every property read is a call into AutoCAD that waits for its main thread, so AutoCAD stalls while a tool runs.
        // Only the properties an object type actually has are read (learned once per type).
        private static readonly string[] EntityProperties = { "Color", "Linetype", "Lineweight", "StartPoint", "EndPoint", "Center", "Radius", "InsertionPoint", "TextString", "Height", "Rotation", "Coordinates", "Closed", "Length", "Area", "Name" };
        private static readonly Dictionary<string, string[]> PropertiesByType = new Dictionary<string, string[]>();
        // One list_entities call examines at most this many objects, so a layer filter on a large drawing returns in
        // seconds with next_offset instead of holding AutoCAD for minutes.
        private const int MaxScanPerCall = 2000;

        internal static List<Dictionary<string, object>> Tools
        {
            get
            {
                if (_tools != null) return _tools;
                Func<Dictionary<string, object>> str = () => Json.Object("type", "string", "minLength", 1);
                Func<Dictionary<string, object>> point = () => Json.Object("type", "array", "items", Json.Object("type", "number"), "minItems", 3, "maxItems", 3, "description", "World coordinates [x,y,z], in drawing units.");
                Func<Dictionary<string, object>> target = () => Json.Object("type", "string", "minLength", 1, "description", "Exact drawing path returned by drawing_info (name for an unsaved drawing).");
                _tools = new List<Dictionary<string, object>>
                {
                    Schema.Tool("drawing_info", "Read active drawing identity, units, layouts, object count and save state. Call before writes.", Json.Object(), new string[0], true),
                    Schema.Tool("list_layers", "Read all layers in the active drawing.", Json.Object(), new string[0], true),
                    Schema.Tool("list_entities", "Read top-level model-space or named-layout objects. summary=true returns only counts by layer and type plus the bounding box (cheapest way to see what a drawing holds or to verify a result). Otherwise objects, 25 per call by default (limit up to 200); fields (such as [\"TextString\",\"Height\"]) limits the properties read; values that are only the inherited default (ByLayer colour, linetype, lineweight) are left out. total_count is everything in the space; with a layer filter, filtered_count is the matches found. Does not expand blocks or xrefs. Offset refers to collection index; one call examines at most 2000 objects, so continue from next_offset when it is set.",
                        Json.Object("layout", str(), "layer", str(), "offset", Json.Object("type", "integer", "minimum", 0), "limit", Json.Object("type", "integer", "minimum", 1, "maximum", 200), "summary", Json.Object("type", "boolean"), "fields", Json.Object("type", "array", "items", Json.Object("type", "string"))), new string[0], true),
                    Schema.Tool("get_entity", "Read an object by handle from the expected drawing. fields limits the properties read; inherited defaults are left out.", Json.Object("expected_drawing", target(), "handle", str(), "fields", Json.Object("type", "array", "items", Json.Object("type", "string"))), new[] { "expected_drawing", "handle" }, true),
                    Schema.Tool("create_entity", "Create a line, circle or single-line text in model space or a named layout. Requires an existing unlocked layer. Coordinates are WCS, lengths are drawing units. Does not save.",
                        Json.Object("expected_drawing", target(), "kind", Json.Object("type", "string", "enum", new object[] { "line", "circle", "text" }), "layer", str(), "layout", str(),
                            "point", point(), "end", point(), "radius", Json.Object("type", "number", "exclusiveMinimum", 0), "text", str(), "height", Json.Object("type", "number", "exclusiveMinimum", 0)),
                        new[] { "expected_drawing", "kind", "layer", "point" }, false),
                    Schema.Tool("edit_entity", "Edit a top-level entity by handle. Actions: move by WCS displacement, change_layer, replace_text (TEXT/MTEXT), set_radius (circle), delete. One Undo group per call. Does not edit inside block definitions or xrefs; does not save.",
                        Json.Object("expected_drawing", target(), "handle", str(), "action", Json.Object("type", "string", "enum", new object[] { "move", "change_layer", "replace_text", "set_radius", "delete" }),
                            "displacement", point(), "layer", str(), "text", Json.Object("type", "string"), "radius", Json.Object("type", "number", "exclusiveMinimum", 0)),
                        new[] { "expected_drawing", "handle", "action" }, false),
                    Schema.Tool("set_layer", "Create a layer or set exactly one layer property: color (ACI 1-255), on, frozen, locked. Does not save.",
                        Json.Object("expected_drawing", target(), "name", str(), "action", Json.Object("type", "string", "enum", new object[] { "create", "color", "on", "frozen", "locked" }),
                            "color", Json.Object("type", "integer", "minimum", 1, "maximum", 255), "value", Json.Object("type", "boolean")),
                        new[] { "expected_drawing", "name", "action" }, false),
                    Schema.Tool("apply_plan", "Create many objects in ONE undoable call from a plan (one round trip instead of hundreds). items are ordered steps {op, ...}: layer{name,color?,linetype?,lineweight?}, line{layer,start,end}, circle{layer,center,radius}, arc{layer,center,radius,start_angle,end_angle}, polyline{layer,points:[[x,y],...],closed?,bulges? (one per point: the arc of the segment that starts there, 0 straight, 1 half circle, positive anticlockwise)}, text{layer,point,text,height,rotation?,style?,justify?}, mtext{layer,point,width,text,height?,rotation?,style?,justify?; \\P = new line} (justify puts the point at that spot of the text: left, center, right, middle, top-left, top-center, top-right, middle-left, middle-center, middle-right, bottom-left, bottom-center, bottom-right; use middle-center to centre a label on a point), insert{layer,name,point,scale?,rotation?,attributes? (object of attribute tag: text; a tag the block lacks fails the step)}, hatch{layer,pattern,boundary,holes?,scale?,angle?,color?} (boundary and holes are ids of EARLIER closed polyline or circle steps, so give those steps an id), dim_aligned{layer,from,to,location,style?,scale?}, dim_rotated{layer,from,to,location,angle,style?,scale?} (location is a point the dimension line passes through; the value shown is the measured one; scale sets the dimension's overall scale, for example the detail scale denominator; linear_factor, for a dimension drawn in a paper-space layout over model geometry, multiplies the measured value so it reads the model size, for example 10 for a 1:10 viewport). Points are [x,y] or [x,y,z] in WCS drawing units; angles are degrees counter-clockwise; lineweight is in hundredths of mm. A step may carry an id; its handle is returned. A layer must already exist (or be created by an earlier layer step) and be unlocked; blocks, linetypes, text styles and dimension styles must already be in the drawing. At most 500 steps. Run with dry_run=true first: it checks everything against the drawing and changes nothing. A real run is refused unless a dry run of the same plan on the same drawing passed in this session in the last 30 minutes; a dry run is used up by one real run. After the dry run, show the user what will be created and wait for their yes. A failed run removes what it created. Does not save.",
                        Json.Object("expected_drawing", target(), "layout", str(), "dry_run", Json.Object("type", "boolean"),
                            "items", Json.Object("type", "array", "items", Json.Object("type", "object"), "minItems", 1, "maxItems", AutoCadPlan.MaxItems)),
                        new[] { "expected_drawing", "items" }, false),
                    Schema.Tool("execute_autocad", "Execute controlled C# against the active AutoCAD drawing: the full AutoCAD ActiveX API, for work the other tools do not cover (hatches, dimensions, tables, block definitions, styles, queries). The code is the body of a method with two dynamic variables, cad (the AutoCAD Application) and doc (the active Document), and must return a string. Use execution_mode read for inspection (allow_model_changes=false); use write for edits (allow_model_changes=true, one Undo group). Call drawing_info first. Does not save unless the code does. Not a sandbox: the code runs with your Windows permissions, so run only code you have read.",
                        Json.Object("expected_drawing", target(), "execution_mode", Json.Object("type", "string", "enum", new object[] { "read", "write" }),
                            "allow_model_changes", Json.Object("type", "boolean"),
                            "code", Json.Object("type", "string", "minLength", 1, "maxLength", AutoCadScript.MaxCodeLength),
                            "timeout_seconds", Json.Object("type", "integer", "minimum", 1, "maximum", 300)),
                        new[] { "expected_drawing", "execution_mode", "allow_model_changes", "code" }, false),
                    Schema.Tool("generate_detail", "Draft a construction detail from a brief, in millimetres, and optionally draw it. template custom_section: params.parts [{id, material (mdf, ply, stone, corian, steel, glass, outline), x0, y0, x1, y1 or points}] with optional levels, notes, dimensions, title; every number and word is the caller's, nothing is invented or checked against a code. template reception_counter_section: a counter section from params (defaults in the skill; the accessible variant needs accessible_height, knee_clearance_height, knee_clearance_depth and code_reference from the code the user names). scale is the denominator (10 = 1:10); origin is where the floor meets the staff face. apply=false (default) never contacts AutoCAD: summary, warnings and, with return_plan, the steps. apply=true (expected_drawing required; drawing in millimetres) checks the plan against the drawing; dry_run defaults to true, and a real run (dry_run false) is refused unless the same job passed a dry run on this drawing in the last 30 minutes. Present the brief and wait for the user's yes before the real run. annotation: model (default), paper (dimensions, notes, levels, title in the layout named by layout at true paper size; view.paper_centre [x,y], create_viewport makes the 1:scale viewport on G-ANNO-VPRT; notes are leaders, levels the office level indicator, titles DWG-VIEWTITLE when the drawing has those blocks, else native multileaders and text; leader_block, level_block, title_block, level_block_scale, note_width and sheet {project, sheet_no, view_no} adjust them) or none. layer_scheme auto uses the office counter-sheet layers when the drawing has them, else generic A-DETL layers (ao or generic forces one). Existing layers are never changed unless update_layers. Reference styles na1, EN-S, EN-SCB are used when present (dimension_style, text_style, use_reference_styles override). Read the detail-generator skill for the full options. Every result is a draft for a designer's review.",
                        Json.Object("expected_drawing", target(), "template", Json.Object("type", "string", "enum", new object[] { AutoCadDetail.ReceptionCounterSection, AutoCadDetail.CustomSection }),
                            "params", Json.Object("type", "object"), "scale", Json.Object("type", "integer", "minimum", 1, "maximum", 200), "origin", point(),
                            "dimension_style", str(), "text_style", str(), "dimension_scale", Json.Object("type", "number", "exclusiveMinimum", 0),
                            "apply", Json.Object("type", "boolean"), "dry_run", Json.Object("type", "boolean"), "update_layers", Json.Object("type", "boolean"), "use_reference_styles", Json.Object("type", "boolean"), "return_plan", Json.Object("type", "boolean"),
                            "annotation", Json.Object("type", "string", "enum", new object[] { "model", "paper", "none" }), "layout", str(), "view", Json.Object("type", "object"),
                            "level_block", str(), "leader_block", str(), "title_block", str(), "level_block_scale", Json.Object("type", "number", "exclusiveMinimum", 0),
                            "note_width", Json.Object("type", "number", "minimum", 15, "maximum", 150), "sheet", Json.Object("type", "object"),
                            "create_viewport", Json.Object("type", "boolean"),
                            "layer_scheme", Json.Object("type", "string", "enum", new object[] { "auto", "generic", "ao" })),
                        new[] { "template" }, false),
                    Schema.Tool("verify_standards", "Check a drawing and return violations only (a few tokens when all is well). required_layers [{name, color?}]; forbidden_layers [names] (nothing may be drawn on them, e.g. 0); text_height {min?, max?, layer?}; expected_counts [{layer?, type?, count}] with type line, circle, arc, polyline, text, mtext, hatch, dimension, insert or an AcDb name (leave type and layer out for the whole drawing; an unknown type is refused). Read-only; up to 2000 objects per call (offset continues).",
                        Json.Object("expected_drawing", target(), "layout", str(), "offset", Json.Object("type", "integer", "minimum", 0),
                            "required_layers", Json.Object("type", "array", "items", Json.Object("type", "object")), "forbidden_layers", Json.Object("type", "array", "items", Json.Object("type", "string")),
                            "text_height", Json.Object("type", "object"), "expected_counts", Json.Object("type", "array", "items", Json.Object("type", "object"))),
                        new[] { "expected_drawing" }, true),
                    Schema.Tool("save_drawing", "Explicitly save the expected drawing to its EXISTING path. Invoke only when saving is requested; no Save As.", Json.Object("expected_drawing", target()), new[] { "expected_drawing" }, false)
                };
                return _tools;
            }
        }

        internal static List<string> ProgIds()
        {
            List<string> ids = new List<string>();
            try
            {
                using (RegistryKey current = Registry.ClassesRoot.OpenSubKey(@"AutoCAD.Application\CurVer"))
                {
                    string value = current == null ? null : current.GetValue("") as string;
                    if (!String.IsNullOrEmpty(value)) ids.Add(value);
                }
            }
            catch (Exception) { }
            try
            {
                Regex versioned = new Regex(@"^AutoCAD\.Application\.(\d+(?:\.\d+)?)$");
                IEnumerable<string> names = Registry.ClassesRoot.GetSubKeyNames()
                    .Where(n => versioned.IsMatch(n))
                    .OrderByDescending(n => new Version(versioned.Match(n).Groups[1].Value.Contains(".") ? versioned.Match(n).Groups[1].Value : versioned.Match(n).Groups[1].Value + ".0"));
                ids.AddRange(names);
            }
            catch (Exception) { }
            ids.Add("AutoCAD.Application");
            return ids.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        }

        private static dynamic Connect()
        {
            List<string> ids = ProgIds();
            foreach (string id in ids)
            {
                try { return Marshal.GetActiveObject(id); } catch (Exception) { }
            }
            throw new ToolException("No running full AutoCAD instance was found. Start AutoCAD and open a drawing. Tried: " + String.Join(", ", ids) + ".");
        }

        private static bool AutoCadRunning()
        {
            Process[] processes = Process.GetProcessesByName("acad");
            foreach (Process process in processes) process.Dispose();
            return processes.Length > 0;
        }

        // AutoCAD keeps every object this program has touched alive until .NET releases its reference. One connector
        // runs per open Codex or Claude window all day, so references are released after every call.
        internal static void ClearReferences()
        {
            GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
        }

        // Read-only reachability probe for connection_status. Never throws. The COM calls run on their own thread, so
        // an AutoCAD that is busy in a command or dialog cannot block the tool past the timeout.
        internal static Dictionary<string, object> ConnectionStatus()
        {
            const int timeoutMilliseconds = 3000;
            Dictionary<string, object> status = null;
            Exception failure = null;
            List<string> ids = ProgIds();
            Thread probe = new Thread(() =>
            {
                try
                {
                    foreach (string id in ids)
                    {
                        dynamic cad;
                        try { cad = Marshal.GetActiveObject(id); } catch (Exception) { continue; }
                        string version = ""; int count = 0;
                        // A briefly busy AutoCAD can answer with empty values (no version, zero drawings); re-read.
                        for (int attempt = 0; attempt < 3; attempt++)
                        {
                            if (attempt > 0) Thread.Sleep(250);
                            version = Convert.ToString(cad.Version);
                            count = Convert.ToInt32(cad.Documents.Count);
                            if (version.Length > 0 && count > 0) break;
                        }
                        dynamic document = count > 0 ? cad.ActiveDocument : null;
                        status = Json.Object("available", true, "version", version, "prog_id", id, "drawing_open", count > 0, "open_drawings", count,
                            "active_drawing", document != null ? Convert.ToString(document.Name) : "",
                            "active_drawing_path", document != null ? Convert.ToString(document.FullName) : "");
                        return;
                    }
                    status = Json.Object("available", false, "running", AutoCadRunning());
                }
                catch (Exception exception) { failure = exception; }
                finally { ClearReferences(); }
            });
            probe.IsBackground = true;
            probe.SetApartmentState(ApartmentState.STA);
            probe.Start();
            if (!probe.Join(timeoutMilliseconds))
            {
                // The stuck thread is left to finish on its own.
                return Json.Object("available", false, "running", true, "summary", "AutoCAD is running but did not answer within " + (timeoutMilliseconds / 1000) + " s; it may be busy in a command or dialog.");
            }
            if (failure != null || status == null)
                return Json.Object("available", false, "running", false, "summary", "AutoCAD status could not be read: " + (failure != null ? failure.Message : "AutoCAD probe returned no result."));
            bool available = true.Equals(status["available"]);
            string summary;
            if (available && Json.GetString(status, "version").Length == 0) summary = "AutoCAD is connected but busy and returned no details; retry in a moment.";
            else if (available && true.Equals(status["drawing_open"])) summary = "AutoCAD " + status["version"] + " is connected; active drawing: " + status["active_drawing"] + ".";
            else if (available) summary = "AutoCAD " + status["version"] + " is connected, but no drawing is open.";
            else if (true.Equals(status["running"])) summary = "AutoCAD is running but not reachable over COM; it may still be starting, or it is not a full AutoCAD (for example AutoCAD LT).";
            else summary = "AutoCAD is not running.";
            status["summary"] = summary;
            return status;
        }

        // A saved drawing is identified by its full path, an unsaved one by its name. The full name itself decides: a never-saved
        // drawing in AutoCAD 2024 reports a non-empty Path but an empty FullName, which made the id blank.
        private static string DrawingId(object source)
        {
            dynamic document = source;
            string full = Convert.ToString(document.FullName);
            return Regex.IsMatch(full, @"^([A-Za-z]:[\\/]|\\\\)") ? full : Convert.ToString(document.Name);
        }

        private static bool IsMissingMember(Exception exception)
        {
            if (exception is Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) return true;
            COMException com = exception as COMException;
            return com != null && (uint)com.ErrorCode == 0x80020006;   // DISP_E_UNKNOWNNAME
        }

        private static object Plain(object value)
        {
            // COM hands back points as double arrays and enums as numbers; both serialize as they are.
            if (value == null || value is string || value is bool || value is Array || value.GetType().IsPrimitive || value is decimal) return value;
            return Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
        }

        // How a property is read from an object. Replaceable so tests can read a stand-in.
        internal static Func<object, string, object> PropertyReader = delegate (object o, string name) { return Microsoft.VisualBasic.Interaction.CallByName(o, name, Microsoft.VisualBasic.CallType.Get); };

        // A value that says nothing because the object inherits it: ByLayer colour (256), ByLayer linetype, ByLayer lineweight (-1).
        private static bool IsDefaultValue(string property, object value)
        {
            if (property == "Color") { double n; return Double.TryParse(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out n) && n == 256; }
            if (property == "Linetype") return String.Equals(Convert.ToString(value), "ByLayer", StringComparison.OrdinalIgnoreCase);
            if (property == "Lineweight") { double n; return Double.TryParse(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out n) && n == -1; }
            return false;
        }

        // handle, type and layer always; then the properties the type has, without the ones that are only the inherited default.
        // fields (property names) limits the properties read to those named, so a caller that wants only text does not pay for geometry.
        private static Dictionary<string, object> ReadEntity(object source, HashSet<string> fields = null)
        {
            dynamic entity = source;
            string type = Convert.ToString(entity.ObjectName);
            Dictionary<string, object> result = Json.Object("handle", Convert.ToString(entity.Handle), "type", type, "layer", Convert.ToString(entity.Layer));
            string[] properties;
            bool learning = fields == null && !PropertiesByType.TryGetValue(type, out properties);
            if (fields == null && !learning) properties = PropertiesByType[type];
            else if (fields != null) properties = fields.ToArray();
            else properties = EntityProperties;
            List<string> present = new List<string>();
            foreach (string property in properties)
            {
                try
                {
                    object value = PropertyReader(source, property);
                    present.Add(property);
                    if (value != null && !IsDefaultValue(property, value)) result[property] = Plain(value);
                }
                catch (Exception exception)
                {
                    Exception inner = exception.InnerException ?? exception;
                    if (!IsMissingMember(exception) && !IsMissingMember(inner) && !(inner is MissingMemberException)) present.Add(property);
                }
            }
            if (learning) PropertiesByType[type] = present.ToArray();
            return result;
        }

        // The property names a caller asked for, or null for the default set. Names are checked so nothing odd reaches the property reader.
        private static HashSet<string> FieldSet(IDictionary<string, object> a)
        {
            if (!a.ContainsKey("fields") || a["fields"] == null) return null;
            System.Collections.IEnumerable list = a["fields"] as System.Collections.IEnumerable;
            if (list == null || a["fields"] is string) throw new ToolException("fields must be a list of property names.");
            HashSet<string> fields = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (object o in list)
            {
                string name = o as string;
                if (name == null || !Regex.IsMatch(name, "^[A-Za-z][A-Za-z0-9]{0,40}$")) throw new ToolException("fields must be a list of property names such as TextString, Height, StartPoint.");
                fields.Add(name);
            }
            return fields.Count == 0 ? null : fields;
        }

        private static readonly Dictionary<string, string> TypeNames = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "line", "AcDbLine" }, { "circle", "AcDbCircle" }, { "arc", "AcDbArc" }, { "polyline", "AcDbPolyline" }, { "text", "AcDbText" }, { "mtext", "AcDbMText" },
            { "hatch", "AcDbHatch" }, { "insert", "AcDbBlockReference" }, { "dimension", "AcDbRotatedDimension" }
        };

        private static object[] ListOf(object value)
        {
            object[] items = value as object[];
            if (items != null) return items;
            System.Collections.ArrayList list = value as System.Collections.ArrayList;
            return list == null ? null : list.ToArray();
        }

        private static double? NumberOf(object value)
        {
            double n;
            return value != null && Double.TryParse(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out n) ? (double?)n : null;
        }

        // verify_standards: the violations only. One pass over the objects counts by layer and type and checks text heights; the layer
        // checks read the layer table. Nothing is changed.
        internal static object VerifyStandards(object docSource, IDictionary<string, object> a)
        {
            dynamic doc = docSource;
            List<string> violations = new List<string>();
            Func<string, string> note = text => text;
            // layers
            Dictionary<string, object> layerColors = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            dynamic layerTable = doc.Layers;
            int layerCount = Convert.ToInt32(layerTable.Count);
            for (int i = 0; i < layerCount; i++) { dynamic l = layerTable.Item(i); layerColors[Convert.ToString(l.Name)] = Plain(l.Color); }
            object[] required = a.ContainsKey("required_layers") ? ListOf(a["required_layers"]) : null;
            if (required != null)
                foreach (object o in required)
                {
                    IDictionary<string, object> rule = o as IDictionary<string, object>;
                    string layerName = rule == null ? "" : Json.GetString(rule, "name");
                    if (layerName.Length == 0) throw new ToolException("Every required_layers entry needs a name.");
                    object color;
                    if (!layerColors.TryGetValue(layerName, out color)) { violations.Add("layer " + layerName + " is missing"); continue; }
                    if (rule.ContainsKey("color") && NumberOf(rule["color"]) != NumberOf(color))
                        violations.Add("layer " + layerName + " has colour " + Convert.ToString(color, System.Globalization.CultureInfo.InvariantCulture) + ", expected " + Convert.ToString(rule["color"], System.Globalization.CultureInfo.InvariantCulture));
                }
            HashSet<string> forbidden = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            object[] forbiddenList = a.ContainsKey("forbidden_layers") ? ListOf(a["forbidden_layers"]) : null;
            if (forbiddenList != null) foreach (object o in forbiddenList) forbidden.Add(Convert.ToString(o));
            IDictionary<string, object> heights = a.ContainsKey("text_height") ? a["text_height"] as IDictionary<string, object> : null;
            double? minHeight = heights != null && heights.ContainsKey("min") ? NumberOf(heights["min"]) : null, maxHeight = heights != null && heights.ContainsKey("max") ? NumberOf(heights["max"]) : null;
            string heightLayer = heights == null ? "" : Json.GetString(heights, "layer");
            object[] expected = a.ContainsKey("expected_counts") ? ListOf(a["expected_counts"]) : null;

            // objects
            dynamic space = Space((object)doc, Json.GetString(a, "layout"));
            int count = Convert.ToInt32(space.Count);
            int start = a.ContainsKey("offset") ? Convert.ToInt32(a["offset"]) : 0, index = start;
            Dictionary<string, int> byLayerType = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, int> onForbidden = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            List<string> badText = new List<string>();
            int badTextCount = 0;
            bool needObjects = forbidden.Count > 0 || heights != null || expected != null;
            while (needObjects && index < count && (index - start) < MaxScanPerCall)
            {
                dynamic entity = space.Item(index); index++;
                string layer = Convert.ToString(entity.Layer), type = Convert.ToString(entity.ObjectName);
                string key = layer + "|" + type;
                byLayerType[key] = (byLayerType.ContainsKey(key) ? byLayerType[key] : 0) + 1;
                if (forbidden.Contains(layer)) onForbidden[layer] = (onForbidden.ContainsKey(layer) ? onForbidden[layer] : 0) + 1;
                if (heights != null && (type == "AcDbText" || type == "AcDbMText") && (heightLayer.Length == 0 || String.Equals(layer, heightLayer, StringComparison.OrdinalIgnoreCase)))
                {
                    double? h = NumberOf(PropertyReader((object)entity, "Height"));
                    if (h.HasValue && ((minHeight.HasValue && h.Value < minHeight.Value - 1e-9) || (maxHeight.HasValue && h.Value > maxHeight.Value + 1e-9)))
                    {
                        badTextCount++;
                        if (badText.Count < 5) badText.Add(Convert.ToString(entity.Handle) + " (" + Convert.ToString(h.Value, System.Globalization.CultureInfo.InvariantCulture) + ")");
                    }
                }
            }
            bool complete = index >= count;
            foreach (KeyValuePair<string, int> pair in onForbidden) violations.Add(pair.Value + " object(s) on forbidden layer " + pair.Key);
            if (badTextCount > 0) violations.Add(badTextCount + " text(s) outside the height range" + (minHeight.HasValue ? " min " + minHeight.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) : "") + (maxHeight.HasValue ? " max " + maxHeight.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) : "") + ", e.g. handle " + String.Join(", ", badText.ToArray()));
            if (expected != null && complete && start == 0)
                foreach (object o in expected)
                {
                    IDictionary<string, object> rule = o as IDictionary<string, object>;
                    if (rule == null || !rule.ContainsKey("count")) throw new ToolException("Every expected_counts entry needs a count.");
                    string wantLayer = Json.GetString(rule, "layer"), wantType = Json.GetString(rule, "type");
                    string mapped;
                    // "total", "all" or "any" as a type means every object; an unknown type is refused, never counted as zero.
                    if (String.Equals(wantType, "total", StringComparison.OrdinalIgnoreCase) || String.Equals(wantType, "all", StringComparison.OrdinalIgnoreCase) || String.Equals(wantType, "any", StringComparison.OrdinalIgnoreCase)) wantType = "";
                    else if (wantType.Length > 0 && TypeNames.TryGetValue(wantType, out mapped)) wantType = mapped;
                    else if (wantType.Length > 0 && !wantType.StartsWith("AcDb", StringComparison.OrdinalIgnoreCase))
                        throw new ToolException("expected_counts type '" + wantType + "' is not known. Use line, circle, arc, polyline, text, mtext, hatch, dimension, insert or an AcDb name; leave type out to count every object.");
                    int found = 0;
                    foreach (KeyValuePair<string, int> pair in byLayerType)
                    {
                        string[] parts = pair.Key.Split('|');
                        if (wantLayer.Length > 0 && !String.Equals(parts[0], wantLayer, StringComparison.OrdinalIgnoreCase)) continue;
                        if (wantType.Length > 0 && !(String.Equals(parts[1], wantType, StringComparison.OrdinalIgnoreCase) || (wantType == "AcDbRotatedDimension" && parts[1].IndexOf("Dimension", StringComparison.Ordinal) >= 0))) continue;
                        found += pair.Value;
                    }
                    double? want = NumberOf(rule["count"]);
                    if (want.HasValue && found != (int)want.Value)
                        violations.Add("expected " + (int)want.Value + " " + (Json.GetString(rule, "type").Length > 0 ? Json.GetString(rule, "type") + " " : "object(s) ") + (wantLayer.Length > 0 ? "on " + wantLayer : "in the drawing") + ", found " + found);
                }
            else if (expected != null && !(complete && start == 0)) violations.Add("expected_counts needs the whole drawing in one call, which is more than " + MaxScanPerCall + " objects here; use summary in list_entities instead");
            Dictionary<string, object> result = Json.Object("drawing", DrawingId((object)doc), "ok", violations.Count == 0, "scanned", index - start);
            if (violations.Count > 0) result["violations"] = violations.Take(20).ToList();
            if (!complete) { result["complete"] = false; result["next_offset"] = index; }
            return result;
        }

        private const int DefaultEntityLimit = 25;

        // list_entities. summary: counts by layer and type plus the drawing's bounding box, no objects. Otherwise the objects (default 25),
        // with total_count (everything in the space) and, for a layer filter, filtered_count (matches found in this call's scan; exact when
        // filtered_count_complete is true, which is the case from offset 0 up to 2000 objects).
        internal static object ListEntities(object docSource, IDictionary<string, object> a)
        {
            dynamic doc = docSource;
            dynamic space = Space((object)doc, Json.GetString(a, "layout"));
            int count = Convert.ToInt32(space.Count);
            int i = a.ContainsKey("offset") ? Convert.ToInt32(a["offset"]) : 0, start = i;
            string layer = Json.GetString(a, "layer");
            bool summary = a.ContainsKey("summary") && a["summary"] is bool && (bool)a["summary"];
            HashSet<string> fields = FieldSet(a);
            if (summary)
            {
                SortedDictionary<string, int> byLayer = new SortedDictionary<string, int>(StringComparer.OrdinalIgnoreCase), byType = new SortedDictionary<string, int>();
                double[] box = null;
                int matched = 0;
                while (i < count && (i - start) < MaxScanPerCall)
                {
                    dynamic entity = space.Item(i); i++;
                    string entityLayer = Convert.ToString(entity.Layer);
                    if (layer.Length > 0 && !String.Equals(entityLayer, layer, StringComparison.OrdinalIgnoreCase)) continue;
                    matched++;
                    string type = Convert.ToString(entity.ObjectName);
                    byLayer[entityLayer] = (byLayer.ContainsKey(entityLayer) ? byLayer[entityLayer] : 0) + 1;
                    byType[type] = (byType.ContainsKey(type) ? byType[type] : 0) + 1;
                    try
                    {
                        object low = null, high = null;
                        entity.GetBoundingBox(ref low, ref high);
                        double[] lo = ((Array)low).Cast<object>().Select(x => Convert.ToDouble(x, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
                        double[] hi = ((Array)high).Cast<object>().Select(x => Convert.ToDouble(x, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
                        if (box == null) box = new[] { lo[0], lo[1], hi[0], hi[1] };
                        else { box[0] = Math.Min(box[0], lo[0]); box[1] = Math.Min(box[1], lo[1]); box[2] = Math.Max(box[2], hi[0]); box[3] = Math.Max(box[3], hi[1]); }
                    }
                    catch (Exception) { }   // an object without extents (a point, an empty text) adds none
                }
                Dictionary<string, object> result = Json.Object("drawing", DrawingId((object)doc), "summary", true, "total_count", count, "counted", matched,
                    "by_layer", byLayer, "by_type", byType, "bbox", box == null ? null : (object)box.Select(x => (object)Math.Round(x, 3)).ToArray());
                if (i < count) { result["complete"] = false; result["next_offset"] = i; } else result["complete"] = true;
                return result;
            }
            int limit = a.ContainsKey("limit") ? Convert.ToInt32(a["limit"]) : DefaultEntityLimit;
            List<object> items = new List<object>();
            int matches = 0, resume = -1;
            while (i < count && (i - start) < MaxScanPerCall)
            {
                dynamic entity = space.Item(i); i++;
                if (layer.Length > 0 && !String.Equals(Convert.ToString(entity.Layer), layer, StringComparison.OrdinalIgnoreCase)) continue;
                matches++;
                if (items.Count < limit) { items.Add(ReadEntity((object)entity, fields)); if (items.Count == limit) resume = i; }
            }
            // more matches than the limit: continue right after the last object returned
            int next = resume >= 0 && matches > limit ? resume : (i < count ? i : -1);
            Dictionary<string, object> data = Json.Object("drawing", DrawingId((object)doc), "entities", items, "total_count", count, "next_offset", next >= 0 ? (object)next : null);
            if (layer.Length > 0) { data["filtered_count"] = matches; data["filtered_count_complete"] = i >= count && start == 0; }
            return data;
        }

        private static dynamic Space(object source, string layout)
        {
            dynamic document = source;
            if (String.IsNullOrEmpty(layout) || layout == "Model") return document.ModelSpace;
            return document.Layouts.Item(layout).Block;
        }

        private static void AssertUnlocked(object source, string layer)
        {
            dynamic document = source;
            dynamic item = document.Layers.Item(layer);
            if ((bool)item.Lock) throw new ToolException("Layer is locked: " + layer);
        }

        private static void Require(IDictionary<string, object> a, string key)
        {
            if (!a.ContainsKey(key)) throw new ToolException("Missing argument for this action: " + key);
        }

        // The collection is passed as object: a lambda cannot be an argument of a dynamically dispatched call.
        private static List<object> Each(object source, Func<dynamic, object> select)
        {
            dynamic collection = source;
            List<object> items = new List<object>();
            int count = Convert.ToInt32(collection.Count);
            for (int i = 0; i < count; i++) items.Add(select(collection.Item(i)));
            return items;
        }

        internal static object Invoke(string name, object arguments)
        {
            try
            {
                IDictionary<string, object> checkedArguments = Schema.Check(Tools, name, arguments, false);
                // A malformed plan is refused before AutoCAD is contacted.
                if (name == "apply_plan") AutoCadPlan.Parse(checkedArguments["items"]);
                // Code is checked and compiled before AutoCAD is contacted, and runs on its own thread with a time limit.
                if (name == "execute_autocad") return ExecuteScript(checkedArguments);
                if (name == "generate_detail") return GenerateDetail(checkedArguments);
                return InvokeCore(name, checkedArguments);
            }
            finally { ClearReferences(); }
        }

        // Names of the members of a collection such as Layers, Linetypes, TextStyles or Blocks.
        private static HashSet<string> Names(object source)
        {
            dynamic collection = source;
            HashSet<string> names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int count = Convert.ToInt32(collection.Count);
            for (int i = 0; i < count; i++) names.Add(Convert.ToString(collection.Item(i).Name));
            return names;
        }

        private static void AddForm(List<string> forms, string form)
        {
            if (!forms.Contains(form)) forms.Add(form);
        }

        // Tries the array forms AutoCAD might accept for a hatch loop, best first, and says which one worked, so the form that
        // works on a given AutoCAD is visible in the result. A form that cannot even be built here is skipped.
        private static readonly string[] LoopForms = { "dispatch-array", "wrapped-variants", "variant-array" };

        private static string AppendLoop(object hatchSource, bool inner, object entity)
        {
            dynamic hatch = hatchSource;
            Exception last = null;
            for (int attempt = 0; attempt < LoopForms.Length; attempt++)
            {
                dynamic array;
                try { array = LoopArray(attempt, entity); }
                catch (Exception exception) { last = exception; continue; }
                try
                {
                    if (inner) hatch.AppendInnerLoop(array); else hatch.AppendOuterLoop(array);
                    return LoopForms[attempt];
                }
                catch (Exception exception) { last = exception; }
            }
            throw new ToolException("AutoCAD refused the hatch loop in every array form tried (" + String.Join(", ", LoopForms) + "): " + (last == null ? "no detail" : last.Message));
        }

        private static object LoopArray(int attempt, object entity)
        {
            if (attempt == 0) { IDispatchOnly[] array = new IDispatchOnly[1]; array[0] = (IDispatchOnly)entity; return array; }
            if (attempt == 1) return new object[] { new System.Runtime.InteropServices.DispatchWrapper(entity) };
            return new object[] { entity };
        }

        // The boundary and holes are objects created by earlier steps. Pattern type 1 is acHatchPatternTypePreDefined:
        // a pattern found by name (SOLID, ANSI31, or a custom pattern on the support path). The hatch is not associative.
        // If a loop is refused, the half-built hatch is deleted before the error leaves.
        private static dynamic CreateHatch(object spaceSource, PlanItem p, Dictionary<string, object> byId, List<string> loopForms)
        {
            dynamic space = spaceSource;
            dynamic hatch = space.AddHatch(1, p.Pattern, false);
            try
            {
                AddForm(loopForms, AppendLoop((object)hatch, false, byId[p.Boundary]));
                if (p.Holes != null)
                    foreach (string hole in p.Holes) AddForm(loopForms, AppendLoop((object)hatch, true, byId[hole]));
                if (!String.Equals(p.Pattern, "SOLID", StringComparison.OrdinalIgnoreCase))
                {
                    hatch.PatternScale = p.Scale;
                    if (p.Rotation != 0) hatch.PatternAngle = p.Rotation * Math.PI / 180.0;
                }
                if (p.Color > 0) hatch.Color = p.Color;
                hatch.Evaluate();
            }
            catch (Exception)
            {
                try { hatch.Delete(); } catch (Exception) { }
                throw;
            }
            return hatch;
        }

        // Fills the block's attributes by tag (case-insensitive). A tag the block does not have fails the step, so a wrong tag is never silent.
        // A key written @elevation or @description is a role, not a tag: the office level block has used LEVEL = the elevation and Area = the
        // description, and an older one ELEVATION = the elevation and LEVEL = the description, so the role is resolved from the tags this block has.
        private static void SetAttributes(object blockSource, PlanItem p)
        {
            dynamic block = blockSource;
            Dictionary<string, dynamic> found = new Dictionary<string, dynamic>(StringComparer.OrdinalIgnoreCase);
            if ((bool)block.HasAttributes)
                foreach (dynamic attribute in (System.Collections.IEnumerable)block.GetAttributes())
                    found[Convert.ToString(attribute.TagString)] = attribute;
            string where = "items[" + p.Index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]: block '" + p.BlockName + "'";
            foreach (KeyValuePair<string, string> pair in p.Attributes)
            {
                string tag = pair.Key;
                if (tag.StartsWith("@"))
                {
                    bool elevation = String.Equals(tag, "@elevation", StringComparison.OrdinalIgnoreCase), description = String.Equals(tag, "@description", StringComparison.OrdinalIgnoreCase);
                    if (!elevation && !description) throw new ToolException(where + ": unknown attribute role '" + tag + "' (use @elevation or @description).");
                    if (found.ContainsKey("Area")) tag = elevation ? "LEVEL" : "Area";
                    else if (found.ContainsKey("ELEVATION")) tag = elevation ? "ELEVATION" : "LEVEL";
                    else if (elevation) tag = "LEVEL";
                    else continue;   // a one-line level block has no place for a description
                }
                dynamic attribute;
                if (!found.TryGetValue(tag, out attribute)) throw new ToolException(where + " has no attribute '" + tag + "'.");
                attribute.TextString = pair.Value;
                if (Convert.ToString(attribute.TextString) != pair.Value) throw new ToolException(where + ": attribute '" + tag + "' did not take the text.");
            }
        }

        // Sets one dynamic property of a block reference. The block is fetched again by its handle before every property, because setting a
        // property (visibility especially) invalidates the property wrappers (as the counter-sheet script found live). A missing or read-only
        // property fails the step.
        private static void SetDynamicProperty(object docSource, string handle, string name, object value, PlanItem p)
        {
            dynamic doc = docSource;
            dynamic reference = doc.HandleToObject(handle);
            foreach (dynamic property in (System.Collections.IEnumerable)reference.GetDynamicBlockProperties())
            {
                if (!String.Equals(Convert.ToString(property.PropertyName), name, StringComparison.OrdinalIgnoreCase) || (bool)property.ReadOnly) continue;
                if (Convert.ToString(property.Value, System.Globalization.CultureInfo.InvariantCulture) != Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture)) property.Value = value;
                return;
            }
            throw new ToolException("items[" + p.Index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]: block '" + p.BlockName + "' has no writable dynamic property '" + name + "'.");
        }

        // A note with a leader. With a block (the office "Multiple Leader Lab"): the block goes at the label anchor, its LABEL attribute takes the
        // text wrapped to the width, and its dynamic Distance1 (landing), Distance2 (leader length) and Angle1 draw the leader to the target, as
        // the counter-sheet script does. Without a block: a native AutoCAD multileader with an arrowhead. Either way a real leader, never a bare line.
        private static dynamic CreateLeader(object spaceSource, PlanItem p)
        {
            dynamic space = spaceSource;
            string at = "items[" + p.Index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]: ";
            if (p.BlockName == null)
            {
                double[] points = { p.End[0], p.End[1], 0, p.Point[0] - p.Landing, p.Point[1], 0 };
                int index = 0;
                dynamic multi = space.AddMLeader(points, ref index);
                try
                {
                    multi.TextString = p.Text;
                    if (p.Height > 0) multi.TextHeight = p.Height;
                }
                catch (Exception) { try { multi.Delete(); } catch (Exception) { } throw; }
                return multi;
            }
            dynamic block = space.InsertBlock(new double[] { p.Point[0], p.Point[1], 0 }, p.BlockName, 1.0, 1.0, 1.0, 0.0);
            try
            {
                block.Layer = p.Layer;
                bool taken = false;
                if ((bool)block.HasAttributes)
                    foreach (dynamic attribute in (System.Collections.IEnumerable)block.GetAttributes())
                        if (String.Equals(Convert.ToString(attribute.TagString), p.Tag, StringComparison.OrdinalIgnoreCase))
                        {
                            attribute.TextString = p.Text;
                            try { attribute.MTextBoundaryWidth = p.Width; } catch (Exception) { }   // only a multi-line attribute has a boundary width
                            taken = true;
                        }
                if (!taken) throw new ToolException(at + "block '" + p.BlockName + "' has no attribute '" + p.Tag + "' for the text.");
                double dx = p.End[0] - (p.Point[0] - p.Landing), dy = p.End[1] - p.Point[1];
                string handle = Convert.ToString(block.Handle);
                object document = space.Document;
                if (p.Visibility != null) SetDynamicProperty(document, handle, "Visibility1", p.Visibility, p);
                SetDynamicProperty(document, handle, "Distance1", p.Landing, p);
                SetDynamicProperty(document, handle, "Distance2", Math.Sqrt(dx * dx + dy * dy), p);
                SetDynamicProperty(document, handle, "Angle1", Math.Atan2(dy, dx) - Math.PI, p);
            }
            catch (Exception) { try { block.Delete(); } catch (Exception) { } throw; }
            return block;
        }

        private static dynamic CreateItem(object spaceSource, PlanItem p)
        {
            dynamic space = spaceSource;
            double toRadians = Math.PI / 180.0;
            switch (p.Op)
            {
                case "line": return space.AddLine(p.Point, p.End);
                case "circle": return space.AddCircle(p.Point, p.Radius);
                case "arc": return space.AddArc(p.Point, p.Radius, p.StartAngle * toRadians, p.EndAngle * toRadians);
                case "polyline":
                    {
                        double[] flat = new double[p.Vertices.Count * 2];
                        for (int i = 0; i < p.Vertices.Count; i++) { flat[2 * i] = p.Vertices[i][0]; flat[2 * i + 1] = p.Vertices[i][1]; }
                        dynamic polyline = space.AddLightWeightPolyline(flat);
                        if (p.Bulges != null)
                            for (int i = 0; i < p.Bulges.Count; i++)
                                if (p.Bulges[i] != 0) polyline.SetBulge(i, p.Bulges[i]);
                        if (p.Closed) polyline.Closed = true;
                        return polyline;
                    }
                case "text":
                    {
                        dynamic text = space.AddText(p.Text, p.Point, p.Height);
                        if (p.Rotation != 0) text.Rotation = p.Rotation * toRadians;
                        if (p.Justify != null && p.Justify != "left")
                        {
                            // the alignment first, then the point the text is aligned at (the insertion point no longer places it)
                            try { text.Alignment = AutoCadPlan.Justifications[p.Justify][0]; text.TextAlignmentPoint = new double[] { p.Point[0], p.Point[1], p.Point.Length > 2 ? p.Point[2] : 0.0 }; }
                            catch (Exception) { try { text.Delete(); } catch (Exception) { } throw; }
                        }
                        return text;
                    }
                case "mtext":
                    {
                        dynamic mtext = space.AddMText(p.Point, p.Width, p.Text);
                        if (p.Height > 0) mtext.Height = p.Height;
                        if (p.Rotation != 0) mtext.Rotation = p.Rotation * toRadians;
                        if (p.Justify != null && p.Justify != "top-left")
                        {
                            try { mtext.AttachmentPoint = AutoCadPlan.Justifications[p.Justify][1]; }
                            catch (Exception) { try { mtext.Delete(); } catch (Exception) { } throw; }
                        }
                        return mtext;
                    }
                case "insert":
                    {
                        dynamic block = space.InsertBlock(p.Point, p.BlockName, p.Scale, p.Scale, p.Scale, p.Rotation * toRadians);
                        if (p.Attributes != null)
                        {
                            // the block is not in the plan's rollback list yet, so a failed attribute must remove it here
                            try { SetAttributes((object)block, p); }
                            catch (Exception) { try { block.Delete(); } catch (Exception) { } throw; }
                        }
                        return block;
                    }
                case "leader": return CreateLeader((object)space, p);
                case "dim_aligned": return space.AddDimAligned(p.Point, p.End, p.Location);
                case "dim_rotated": return space.AddDimRotated(p.Point, p.End, p.Location, p.Rotation * toRadians);
            }
            throw new ToolException("Unsupported plan step: " + p.Op);
        }

        // Validates the whole plan against this drawing, then (unless dry_run) creates it in one Undo group. Anything
        // created is removed again if a step fails, and the object count is read back to confirm the result.
        internal static object ApplyPlan(object source, IDictionary<string, object> a)
        {
            dynamic doc = source;
            List<PlanItem> plan = AutoCadPlan.Parse(a["items"]);
            bool dryRun = a.ContainsKey("dry_run") && (bool)a["dry_run"];
            string layout = Json.GetString(a, "layout");
            if (!dryRun && (bool)doc.ReadOnly) throw new ToolException("Drawing is read-only.");
            if (layout.Length > 0 && layout != "Model" && !Names((object)doc.Layouts).Contains(layout)) throw new ToolException("Layout not found: " + layout);

            Dictionary<string, bool> layers = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            dynamic layerTable = doc.Layers;
            int layerCount = Convert.ToInt32(layerTable.Count);
            for (int i = 0; i < layerCount; i++) { dynamic item = layerTable.Item(i); layers[Convert.ToString(item.Name)] = (bool)item.Lock; }
            bool needsLinetypes = plan.Any(p => p.Linetype != null), needsStyles = plan.Any(p => p.TextStyle != null), needsBlocks = plan.Any(p => p.Op == "insert" || (p.Op == "leader" && p.BlockName != null)), needsDimStyles = plan.Any(p => p.DimStyle != null);
            HashSet<string> linetypes = needsLinetypes ? Names((object)doc.Linetypes) : new HashSet<string>();
            HashSet<string> styles = needsStyles ? Names((object)doc.TextStyles) : new HashSet<string>();
            HashSet<string> blocks = needsBlocks ? Names((object)doc.Blocks) : new HashSet<string>();
            HashSet<string> dimStyles = needsDimStyles ? Names((object)doc.DimStyles) : new HashSet<string>();
            List<string> problems = AutoCadPlan.CheckReferences(plan, layers, linetypes, styles, blocks, dimStyles);
            if (problems.Count > 0) throw new ToolException("The plan cannot be applied:\n" + String.Join("\n", problems.ToArray()));

            List<string> toCreate = AutoCadPlan.LayersToCreate(plan, layers.Keys);
            Dictionary<string, object> counts = AutoCadPlan.Counts(plan);
            // The dry-run rule: a plan applied inside generate_detail is covered by that tool's own check (it passes __guard_skip).
            bool guarded = !a.ContainsKey("__guard_skip");
            string guardKey = guarded ? DryRunGuard.Key(DrawingId((object)doc), layout, a["items"]) : null;
            if (dryRun)
            {
                if (guarded) DryRunGuard.Passed_(guardKey);
                return Json.Object("drawing", DrawingId((object)doc), "dry_run", true, "valid", true, "steps", plan.Count, "counts", counts, "layers_to_create", toCreate,
                    "layout", layout.Length == 0 ? "Model" : layout, "save_performed", false);
            }
            if (guarded) DryRunGuard.Require(guardKey);

            dynamic space = Space((object)doc, layout);
            int before = Convert.ToInt32(space.Count);
            List<object> created = new List<object>();
            List<string> layersCreated = new List<string>();
            Dictionary<string, object> handles = new Dictionary<string, object>();
            Dictionary<string, object> byId = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            List<string> loopForms = new List<string>();
            List<string> warnings = new List<string>();
            int objects = 0;
            doc.StartUndoMark();
            try
            {
                try
                {
                    foreach (PlanItem p in plan)
                    {
                        if (p.Op == "layer")
                        {
                            dynamic layer;
                            if (toCreate.Contains(p.Layer, StringComparer.OrdinalIgnoreCase) && !layersCreated.Contains(p.Layer, StringComparer.OrdinalIgnoreCase))
                            {
                                layer = doc.Layers.Add(p.Layer);
                                layersCreated.Add(p.Layer);
                            }
                            else layer = doc.Layers.Item(p.Layer);
                            if (p.Color > 0) layer.Color = p.Color;
                            if (p.Linetype != null) layer.Linetype = p.Linetype;
                            if (p.Lineweight >= 0) layer.Lineweight = p.Lineweight;
                            continue;
                        }
                        dynamic entity = p.Op == "hatch" ? CreateHatch((object)space, p, byId, loopForms) : CreateItem((object)space, p);
                        created.Add((object)entity);
                        entity.Layer = p.Layer;
                        if (p.TextStyle != null) entity.StyleName = p.TextStyle;
                        if (p.DimStyle != null) entity.StyleName = p.DimStyle;
                        if (p.DimScale > 0)
                        {
                            try { entity.ScaleFactor = p.DimScale; }
                            catch (Exception) { warnings.Add("items[" + p.Index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]: the dimension scale could not be applied; set the scale in the dimension style instead."); }
                        }
                        if (p.LinearFactor > 0)
                        {
                            // A paper-space dimension of model geometry must read the model value. The reference sheets use a negative factor; the size is what counts.
                            // If neither sign is accepted the whole plan is refused (and rolled back), because a dimension that reads the wrong value must never be left in a drawing.
                            try { entity.LinearScaleFactor = -p.LinearFactor; }
                            catch (Exception)
                            {
                                try { entity.LinearScaleFactor = p.LinearFactor; }
                                catch (Exception) { throw new ToolException("items[" + p.Index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]: the dimension's linear scale factor could not be set, so nothing was kept."); }
                            }
                            if (Math.Abs(Math.Abs(Convert.ToDouble(entity.LinearScaleFactor)) - p.LinearFactor) > 1e-9) throw new ToolException("items[" + p.Index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]: the dimension's linear scale factor did not read back as " + p.LinearFactor.ToString(System.Globalization.CultureInfo.InvariantCulture) + ", so nothing was kept.");
                        }
                        objects++;
                        if (p.Id != null) { handles[p.Id] = Convert.ToString(entity.Handle); byId[p.Id] = (object)entity; }
                    }
                }
                catch (Exception)
                {
                    for (int i = created.Count - 1; i >= 0; i--) { try { ((dynamic)created[i]).Delete(); } catch (Exception) { } }
                    foreach (string layerName in layersCreated) { try { doc.Layers.Item(layerName).Delete(); } catch (Exception) { } }
                    throw;
                }
            }
            finally { doc.EndUndoMark(); }

            if (guarded) DryRunGuard.Used(guardKey);   // a plan is drawn once per dry run
            int after = Convert.ToInt32(space.Count);
            Dictionary<string, object> data = Json.Object("steps", plan.Count, "objects_created", objects, "layers_created", layersCreated, "counts", counts, "handles", handles,
                "layout", layout.Length == 0 ? "Model" : layout, "object_count_before", before, "object_count_after", after, "count_matches_plan", after - before == objects);
            if (loopForms.Count > 0) data["hatch_loop_array_form"] = loopForms;
            if (warnings.Count > 0) data["warnings"] = warnings;
            return Json.Object("drawing", DrawingId((object)doc), "result", data, "save_performed", false);
        }

        private static object ExecuteScript(IDictionary<string, object> a)
        {
            string mode = Json.GetString(a, "execution_mode");
            bool allowChanges = (bool)a["allow_model_changes"];
            if (mode == "write" && !allowChanges) throw new ToolException("Model-changing execution requires allow_model_changes=true.");
            if (mode == "read" && allowChanges) throw new ToolException("Read execution requires allow_model_changes=false.");
            System.Reflection.MethodInfo run = AutoCadScript.Compile(Json.GetString(a, "code"));
            int timeout = a.ContainsKey("timeout_seconds") ? Convert.ToInt32(a["timeout_seconds"]) : 60;

            // The whole run, including the connection, happens on one STA thread so that AutoCAD's objects stay on it.
            // A thread inside an AutoCAD call is never aborted (that has hung AutoCAD); on timeout it is left to finish.
            object result = null;
            Exception failure = null;
            Thread worker = new Thread(() =>
            {
                try { result = RunScriptOnThread(a, run, mode); }
                catch (Exception exception) { failure = exception; }
                finally { ClearReferences(); }
            });
            worker.IsBackground = true;
            worker.SetApartmentState(ApartmentState.STA);
            worker.Start();
            if (!worker.Join(TimeSpan.FromSeconds(timeout)))
                throw new ToolException("The code did not finish within " + timeout + " s. AutoCAD may be busy or showing a dialog. The code keeps running and cannot be stopped from here; check AutoCAD before sending anything else.");
            if (failure != null)
            {
                if (failure is ToolException) throw failure;
                throw new ToolException("C# execution failed: " + failure.GetType().Name + ": " + failure.Message);
            }
            return result;
        }

        private static object RunScriptOnThread(IDictionary<string, object> a, System.Reflection.MethodInfo run, string mode)
        {
            dynamic cad = Connect();
            if (Convert.ToInt32(cad.Documents.Count) == 0) throw new ToolException("Open a drawing in AutoCAD first.");
            dynamic doc = cad.ActiveDocument;
            return RunScriptOnDrawing((object)cad, (object)doc, a, run, mode);
        }

        // What a read run must not change, as one comparable text: the number of objects in model space and in the layouts,
        // layers, blocks, and the DBMOD flag. This check only warns, so every reading is optional: a value AutoCAD will not
        // give (AutoCAD 2024 refuses HANDSEED over COM) must never stop the code from running.
        private static string Fingerprint(object source)
        {
            dynamic doc = source;
            string f = "";
            try { f += "m" + Convert.ToInt32(doc.ModelSpace.Count); } catch (Exception) { f += "m?"; }
            try
            {
                dynamic layouts = doc.Layouts;
                int count = Convert.ToInt32(layouts.Count), total = 0;
                for (int i = 0; i < count; i++) total += Convert.ToInt32(layouts.Item(i).Block.Count);
                f += "|p" + total;
            }
            catch (Exception) { f += "|p?"; }
            try { f += "|l" + Convert.ToInt32(doc.Layers.Count); } catch (Exception) { f += "|l?"; }
            try { f += "|b" + Convert.ToInt32(doc.Blocks.Count); } catch (Exception) { f += "|b?"; }
            try { f += "|d" + Convert.ToString(doc.GetVariable("DBMOD")); } catch (Exception) { f += "|d?"; }
            return f;
        }

        private static bool SavedFlag(object source)
        {
            try { dynamic doc = source; return (bool)doc.Saved; }
            catch (Exception) { return true; }
        }

        // The run itself, given the drawing, so it can be tested against a stand-in for AutoCAD.
        internal static object RunScriptOnDrawing(object cadSource, object docSource, IDictionary<string, object> a, System.Reflection.MethodInfo run, string mode)
        {
            dynamic doc = docSource;
            if (!String.Equals(DrawingId(docSource), Json.GetString(a, "expected_drawing"), StringComparison.OrdinalIgnoreCase))
                throw new ToolException("Active drawing changed or expected_drawing is incorrect. Read drawing_info again.");
            if (mode == "write" && (bool)doc.ReadOnly) throw new ToolException("Drawing is read-only.");

            // AutoCAD's API cannot enforce read-only, so a read run is checked afterwards. Edits that add or remove objects
            // change the counts; any edit clears the Saved flag of a drawing that was saved. Changing an existing object in a
            // drawing that was already unsaved cannot be seen, so the check is a warning and not a guarantee.
            string before = Fingerprint(docSource);
            bool savedBefore = SavedFlag(docSource);
            string text;
            if (mode == "write")
            {
                doc.StartUndoMark();
                try { text = AutoCadScript.Run(run, cadSource, docSource); }
                catch (ToolException exception)
                {
                    throw new ToolException(exception.Message + " Changes made before the error stay in the drawing; one UNDO reverts them.");
                }
                finally { try { doc.EndUndoMark(); } catch (Exception) { } }
            }
            else text = AutoCadScript.Run(run, cadSource, docSource);

            bool savedAfter = SavedFlag(docSource);
            bool changed = Fingerprint(docSource) != before || (savedBefore && !savedAfter);
            bool truncated;
            string limited = AutoCadScript.Limit(text, out truncated);
            Dictionary<string, object> data = Json.Object("execution_mode", mode, "result", limited, "result_truncated", truncated, "drawing_changed", changed, "unsaved_changes", !savedAfter);
            if (mode == "read" && changed)
                data["warning"] = "The drawing changed during a read run. Run UNDO in AutoCAD to revert it, and use execution_mode=write with allow_model_changes=true for edits.";
            return Json.Object("drawing", DrawingId(docSource), "result", data);
        }

        // Detail Generator: the plan is built and checked before AutoCAD is contacted. With apply it is then dry-run or drawn through ApplyPlan.
        private static bool apply0(IDictionary<string, object> a)
        {
            return a.ContainsKey("apply") && (bool)a["apply"];
        }

        private static object GenerateDetail(IDictionary<string, object> a)
        {
            IDictionary<string, object> parameters = null;
            if (a.ContainsKey("params"))
            {
                parameters = a["params"] as IDictionary<string, object>;
                if (parameters == null) throw new ToolException("params must be an object.");
            }
            int scale = a.ContainsKey("scale") ? Convert.ToInt32(a["scale"]) : 10;
            double ox = 0, oy = 0;
            if (a.ContainsKey("origin")) { double[] o = Schema.Point(a["origin"]); ox = o[0]; oy = o[1]; }
            string dimStyle = a.ContainsKey("dimension_style") ? Json.GetString(a, "dimension_style") : null;
            string textStyle = a.ContainsKey("text_style") ? Json.GetString(a, "text_style") : null;
            double dimScale = a.ContainsKey("dimension_scale") ? Convert.ToDouble(a["dimension_scale"], System.Globalization.CultureInfo.InvariantCulture) : 0;
            DetailAnnotation place = new DetailAnnotation();
            if (a.ContainsKey("annotation")) place.Mode = Json.GetString(a, "annotation");
            if (a.ContainsKey("view"))
            {
                IDictionary<string, object> view = a["view"] as IDictionary<string, object>;
                if (view == null) throw new ToolException("view must be an object.");
                foreach (string key in view.Keys) if (key != "paper_centre" && key != "model_centre" && key != "viewport_size") throw new ToolException("Unknown view field: " + key + ". Allowed: paper_centre, model_centre, viewport_size.");
                if (view.ContainsKey("paper_centre")) place.PaperCentre = Pair(view["paper_centre"], "view.paper_centre", -100000, 100000);
                if (view.ContainsKey("model_centre")) place.ModelCentre = Pair(view["model_centre"], "view.model_centre", -1e9, 1e9);
                if (view.ContainsKey("viewport_size"))
                {
                    if (!(a.ContainsKey("create_viewport") && (bool)a["create_viewport"])) throw new ToolException("view.viewport_size is used with create_viewport only.");
                    double[] size = Pair(view["viewport_size"], "view.viewport_size", 10, 2000);
                    a["__viewport_size"] = size;
                }
            }
            if (a.ContainsKey("layer_scheme")) place.Scheme = Json.GetString(a, "layer_scheme");
            if (a.ContainsKey("level_block")) place.LevelBlock = Json.GetString(a, "level_block");
            if (a.ContainsKey("leader_block")) place.LeaderBlock = Json.GetString(a, "leader_block");
            if (a.ContainsKey("title_block")) place.TitleBlock = Json.GetString(a, "title_block");
            if (a.ContainsKey("note_width")) place.NoteWidth = Convert.ToDouble(a["note_width"], System.Globalization.CultureInfo.InvariantCulture);
            if (a.ContainsKey("sheet"))
            {
                IDictionary<string, object> sheet = a["sheet"] as IDictionary<string, object>;
                if (sheet == null) throw new ToolException("sheet must be an object.");
                foreach (string key in sheet.Keys) if (key != "project" && key != "sheet_no" && key != "view_no") throw new ToolException("Unknown sheet field: " + key + ". Allowed: project, sheet_no, view_no.");
                Func<string, string> text = key =>
                {
                    if (!sheet.ContainsKey(key)) return null;
                    string v = sheet[key] as string;
                    if (v == null || v.Length > 80 || v.IndexOf('\n') >= 0) throw new ToolException("sheet." + key + " must be one line of text of up to 80 characters.");
                    return v;
                };
                place.SheetProject = text("project"); place.SheetNo = text("sheet_no"); place.ViewNo = text("view_no");
            }
            if (place.Mode != "paper" && (place.LeaderBlock != null || place.TitleBlock != null || place.LevelBlock != null || a.ContainsKey("sheet") || a.ContainsKey("note_width")))
                throw new ToolException("level_block, leader_block, title_block, note_width and sheet are used with annotation paper only.");
            if (a.ContainsKey("level_block_scale")) place.LevelBlockScale = Convert.ToDouble(a["level_block_scale"], System.Globalization.CultureInfo.InvariantCulture);
            if (place.Mode == "paper" && apply0(a) && Json.GetString(a, "layout").Length == 0) throw new ToolException("annotation paper needs layout: the name of the layout to annotate.");
            if (place.Mode != "paper" && a.ContainsKey("layout")) throw new ToolException("layout is used with annotation paper only.");
            bool createViewport = a.ContainsKey("create_viewport") && (bool)a["create_viewport"];
            if (createViewport && place.Mode != "paper") throw new ToolException("create_viewport is used with annotation paper only.");
            dynamic doc = null;
            string centreSource = null;
            if (place.Mode == "paper" && place.PaperCentre == null && createViewport)
            {
                // The viewport is ours, so the detail can go in the middle of the sheet: that needs the layout's paper size from AutoCAD.
                if (!apply0(a)) throw new ToolException("view.paper_centre is needed to preview without AutoCAD. With apply and create_viewport it defaults to the centre of the layout's sheet.");
                if (Json.GetString(a, "expected_drawing").Length == 0) throw new ToolException("expected_drawing is required when apply is true.");
                doc = ActiveDrawing();
                if (!String.Equals(DrawingId((object)doc), Json.GetString(a, "expected_drawing"), StringComparison.OrdinalIgnoreCase))
                    throw new ToolException("Active drawing changed or expected_drawing is incorrect. Read drawing_info again.");
                place.PaperCentre = SheetCentre((object)doc, Json.GetString(a, "layout"));
                centreSource = "the centre of the sheet of layout '" + Json.GetString(a, "layout") + "' (approximate: printer margins can move it a few millimetres)";
            }
            DetailResult built = AutoCadDetail.Build(Json.GetString(a, "template"), parameters, scale, ox, oy, dimStyle, textStyle, dimScale, place);
            bool apply = a.ContainsKey("apply") && (bool)a["apply"];
            if (apply)
            {
                // The brief is valid. Now the drawing's own layers and blocks decide which layer set is used, so read them and build again.
                if (Json.GetString(a, "expected_drawing").Length == 0) throw new ToolException("expected_drawing is required when apply is true.");
                if (doc == null) doc = ActiveDrawing();
                place.Facts = ReadFacts((object)doc);
                built = AutoCadDetail.Build(Json.GetString(a, "template"), parameters, scale, ox, oy, dimStyle, textStyle, dimScale, place);
            }

            Dictionary<string, object> generated = Json.Object("summary", built.Summary, "warnings", built.Warnings);
            if (centreSource != null) generated["paper_centre_source"] = centreSource;
            if (a.ContainsKey("return_plan") && (bool)a["return_plan"]) { generated["items"] = built.Items; if (built.PaperItems.Count > 0) generated["paper_items"] = built.PaperItems; }
            if (!apply) return Json.Object("applied", false, "generated", generated);
            return ApplyGenerated((object)doc, a, built, generated);
        }

        // The layers and blocks the drawing already has.
        private static DrawingFacts ReadFacts(object docSource)
        {
            dynamic doc = docSource;
            DrawingFacts facts = new DrawingFacts();
            facts.Layers = Names((object)doc.Layers);
            facts.Blocks = Names((object)doc.Blocks);
            return facts;
        }

        private static dynamic ActiveDrawing()
        {
            dynamic cad = Connect();
            if (Convert.ToInt32(cad.Documents.Count) == 0) throw new ToolException("Open a drawing in AutoCAD first.");
            return cad.ActiveDocument;
        }

        private static double[] Pair(object value, string name, double min, double max)
        {
            System.Collections.IEnumerable seq = value as System.Collections.IEnumerable;
            List<double> n = new List<double>();
            if (value != null && !(value is string) && seq != null)
                foreach (object o in seq) { double x; if (!Schema.TryNumber(o, out x)) { n.Clear(); break; } n.Add(x); }
            if (n.Count < 2 || n.Count > 3 || n[0] < min || n[0] > max || n[1] < min || n[1] > max)
                throw new ToolException(name + " must be [x, y] with numbers between " + min.ToString(System.Globalization.CultureInfo.InvariantCulture) + " and " + max.ToString(System.Globalization.CultureInfo.InvariantCulture) + ".");
            return new[] { n[0], n[1] };
        }

        // The centre of a layout's sheet in paper millimetres, from its paper size and plot rotation. Paper-space coordinates start at the
        // printable area, so this can be a few millimetres off the true sheet centre; it is a default, and the viewport and annotation share it.
        internal static double[] SheetCentre(object docSource, string layout)
        {
            dynamic doc = docSource;
            if (layout.Length == 0 || layout == "Model" || !Names((object)doc.Layouts).Contains(layout)) throw new ToolException("Layout not found: " + layout);
            dynamic sheet = doc.Layouts.Item(layout);
            double w = 0, h = 0;
            try { sheet.GetPaperSize(out w, out h); }
            catch (Exception) { throw new ToolException("The paper size of layout '" + layout + "' could not be read. Give view.paper_centre."); }
            int units = Convert.ToInt32(sheet.PaperUnits);
            if (units == 0) { w *= 25.4; h *= 25.4; }
            else if (units != 1) throw new ToolException("Layout '" + layout + "' uses pixel paper units. Give view.paper_centre.");
            int rotation = Convert.ToInt32(sheet.PlotRotation);
            if (rotation == 1 || rotation == 3) { double t = w; w = h; h = t; }
            if (w < 50 || h < 50) throw new ToolException("Layout '" + layout + "' has no usable paper size (" + w.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture) + " x " + h.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture) + " mm). Choose a paper size in Page Setup, or give view.paper_centre.");
            return new[] { Math.Round(w / 2.0, 1), Math.Round(h / 2.0, 1) };
        }

        // The reference sheets use dimension style na1, text style EN-S for notes and EN-SCB for titles. A step the caller gave an
        // explicit style keeps it; the others take the reference style if the drawing has it. Anything missing is reported.
        private static void ResolveReferenceStyles(object docSource, DetailResult built, Dictionary<string, object> generated)
        {
            dynamic doc = docSource;
            HashSet<string> dimStyles = Names((object)doc.DimStyles), textStyles = Names((object)doc.TextStyles);
            List<string> notes = new List<string>();
            string refDim = dimStyles.Contains("na1") ? "na1" : null;
            string refText = textStyles.Contains("EN-S") ? "EN-S" : null;
            string refTitle = textStyles.Contains("EN-SCB") ? "EN-SCB" : refText;
            bool wantsDim = false, wantsText = false, wantsTitle = false;
            foreach (Dictionary<string, object> item in built.Items.Concat(built.PaperItems))
            {
                string op = Json.GetString(item, "op");
                if (item.ContainsKey("style")) continue;
                if (op == "dim_rotated")
                {
                    wantsDim = true;
                    if (refDim != null) item["style"] = refDim;
                }
                else if (op == "text")
                {
                    bool title = Convert.ToDouble(item["height"], System.Globalization.CultureInfo.InvariantCulture) >= 3.4 * built.HeightUnit;
                    if (title) { wantsTitle = true; if (refTitle != null) item["style"] = refTitle; }
                    else { wantsText = true; if (refText != null) item["style"] = refText; }
                }
            }
            if (wantsDim && refDim == null) notes.Add("Dimension style na1 was not found, so the current dimension style is used and the dimension sizes will not match the reference sheets.");
            if (wantsText && refText == null) notes.Add("Text style EN-S was not found, so the current text style is used for notes and levels.");
            if (wantsTitle && refTitle == null) notes.Add("Text style EN-SCB was not found, so the current text style is used for titles.");
            Dictionary<string, object> used = Json.Object("dimension", refDim, "notes", refText, "titles", refTitle);
            generated["reference_styles"] = used;
            if (notes.Count > 0) generated["style_notes"] = notes;
        }

        // Checks the drawing (identity, millimetres, existing layers), then dry-runs or draws the generated plan.
        internal static object ApplyGenerated(object docSource, IDictionary<string, object> a, DetailResult built, Dictionary<string, object> generated)
        {
            dynamic doc = docSource;
            string id = DrawingId(docSource);
            if (!String.Equals(id, Json.GetString(a, "expected_drawing"), StringComparison.OrdinalIgnoreCase))
                throw new ToolException("Active drawing changed or expected_drawing is incorrect. Read drawing_info again.");
            int units;
            try { units = Convert.ToInt32(doc.GetVariable("INSUNITS")); }
            catch (Exception) { throw new ToolException("The drawing's units could not be read, so nothing was drawn. The Detail Generator works in millimetres only."); }
            if (units != 4)
                throw new ToolException("The drawing is not in millimetres (INSUNITS = " + units.ToString(System.Globalization.CultureInfo.InvariantCulture) + "), so nothing was drawn. The Detail Generator works in millimetres only; start from a millimetre template such as acadiso.dwt.");

            if (!a.ContainsKey("use_reference_styles") || (bool)a["use_reference_styles"]) ResolveReferenceStyles(docSource, built, generated);
            bool update = a.ContainsKey("update_layers") && (bool)a["update_layers"];
            HashSet<string> existing = Names((object)doc.Layers);
            List<object> steps = new List<object>();
            List<string> kept = new List<string>();
            foreach (Dictionary<string, object> item in built.Items)
            {
                if (!update && Json.GetString(item, "op") == "layer" && existing.Contains(Json.GetString(item, "name"))) { kept.Add(Json.GetString(item, "name")); continue; }
                steps.Add(item);
            }
            bool dry = !a.ContainsKey("dry_run") || (bool)a["dry_run"];
            Dictionary<string, object> planArguments = Json.Object("expected_drawing", id, "dry_run", dry, "items", steps.ToArray());
            if (kept.Count > 0) generated["existing_layers_left_unchanged"] = kept;
            if (built.PaperItems.Count == 0)
            {
                object planResult = ApplyPlan(docSource, planArguments);
                return Json.Object("applied", !dry, "generated", generated, "plan_result", planResult);
            }

            // Annotation in a layout: the model-space geometry and the paper-space annotation are two plans. Both are checked against the drawing
            // before anything is drawn, so a missing layout, style or block refuses the whole job. The layer steps are repeated in the layout plan.
            string layout = Json.GetString(a, "layout");
            List<object> paperSteps = new List<object>();
            foreach (object step in steps) if (Json.GetString((IDictionary<string, object>)step, "op") == "layer") paperSteps.Add(step);
            paperSteps.AddRange(built.PaperItems.Cast<object>());
            Dictionary<string, object> paperArguments = Json.Object("expected_drawing", id, "dry_run", true, "items", paperSteps.ToArray(), "layout", layout, "__guard_skip", true);
            object modelCheck = ApplyPlan(docSource, Json.Object("expected_drawing", id, "dry_run", true, "items", steps.ToArray(), "__guard_skip", true));
            object paperCheck = ApplyPlan(docSource, paperArguments);
            bool createViewport = a.ContainsKey("create_viewport") && (bool)a["create_viewport"];
            ViewportPlan viewport = null;
            if (createViewport)
            {
                viewport = PlanViewport(docSource, a, built);
                generated["viewport"] = viewport.Describe();
            }
            else
            {
                string viewportWarning = ViewportWarning(docSource, layout, built.Scale);
                if (viewportWarning != null) generated["viewport_warning"] = viewportWarning;
            }
            // The dry-run rule for the whole job (geometry, annotation and viewport): one key over everything that decides what is drawn.
            string guardKey = DryRunGuard.Key(id, steps, paperSteps, layout, createViewport,
                built.Summary.ContainsKey("paper_centre") ? built.Summary["paper_centre"] : null, built.Summary.ContainsKey("model_centre") ? built.Summary["model_centre"] : null,
                a.ContainsKey("__viewport_size") ? a["__viewport_size"] : null);
            if (dry)
            {
                DryRunGuard.Passed_(guardKey);
                return Json.Object("applied", false, "generated", generated, "plan_result", modelCheck, "paper_plan_result", paperCheck);
            }
            DryRunGuard.Require(guardKey);

            planArguments["__guard_skip"] = true;
            object modelResult = ApplyPlan(docSource, planArguments);
            paperArguments["dry_run"] = false;
            object paperResult;
            DryRunGuard.Used(guardKey);
            try { paperResult = ApplyPlan(docSource, paperArguments); }
            catch (ToolException e) { throw new ToolException("The geometry was drawn in model space, but the annotation in layout '" + layout + "' failed and was rolled back: " + e.Message + " Undo once (U) to remove the geometry, fix the cause, then run again."); }
            if (viewport == null) return Json.Object("applied", true, "generated", generated, "plan_result", modelResult, "paper_plan_result", paperResult);
            try
            {
                object viewportResult = RetryWhenBusy(delegate { return CreateViewport(docSource, layout, viewport); });
                return Json.Object("applied", true, "generated", generated, "plan_result", modelResult, "paper_plan_result", paperResult, "viewport_result", viewportResult);
            }
            catch (Exception e)
            {
                // The geometry and annotation are in and correct; only the viewport is missing. Report it with the results instead of failing them.
                string reason = e is ToolException ? e.Message : e.GetType().Name + ": " + e.Message;
                generated["viewport_error"] = "The viewport could not be made, and nothing of it was kept: " + reason;
                generated["viewport_next_step"] = "The geometry and annotation are in place. Add a viewport at 1:" + built.Scale.ToString(System.Globalization.CultureInfo.InvariantCulture)
                    + " centred on model point " + viewport.ViewCentre[0].ToString(System.Globalization.CultureInfo.InvariantCulture) + ", " + viewport.ViewCentre[1].ToString(System.Globalization.CultureInfo.InvariantCulture)
                    + " at paper point " + viewport.Centre[0].ToString(System.Globalization.CultureInfo.InvariantCulture) + ", " + viewport.Centre[1].ToString(System.Globalization.CultureInfo.InvariantCulture)
                    + ", or type U twice in AutoCAD to remove the annotation and the geometry.";
                return Json.Object("applied", true, "generated", generated, "plan_result", modelResult, "paper_plan_result", paperResult, "viewport_result", null);
            }
        }

        // AutoCAD answers a COM call with "Call was rejected by callee" (RPC_E_CALL_REJECTED) or "server busy" while it is busy for a moment
        // (right after a large drawing step, a regeneration or a user command). Such a call is tried again after a short wait; a failed attempt
        // has already removed what it made (CreateViewport cleans up before it rethrows), so trying again is safe. Any other error is not retried.
        internal static Action<int> Pause = delegate (int milliseconds) { System.Threading.Thread.Sleep(milliseconds); };
        internal const int BusyRetries = 6;

        internal static bool IsAutoCadBusy(Exception exception)
        {
            for (Exception e = exception; e != null; e = e.InnerException)
            {
                COMException com = e as COMException;
                if (com != null)
                {
                    uint code = (uint)com.ErrorCode;
                    return code == 0x80010001 || code == 0x8001010A;   // RPC_E_CALL_REJECTED, RPC_E_SERVERCALL_RETRYLATER
                }
            }
            return false;
        }

        internal static T RetryWhenBusy<T>(Func<T> operation)
        {
            for (int attempt = 1; ; attempt++)
            {
                try { return operation(); }
                catch (Exception e)
                {
                    if (attempt >= BusyRetries || !IsAutoCadBusy(e)) throw;
                    Pause(1000 * attempt);
                }
            }
        }

        private const double ViewportMargin = 10;   // paper millimetres around the parts

        internal sealed class ViewportPlan
        {
            internal double[] Centre, ViewCentre;
            internal double Width, Height;
            internal int Scale;
            internal bool LayerExists;
            internal string LayerName = "G-ANNO-VPRT";
            internal Dictionary<string, object> Describe()
            {
                return Json.Object("layer", LayerName, "plotted", false, "centre", new object[] { Centre[0], Centre[1] }, "size", new object[] { Width, Height },
                    "scale", "1:" + Scale.ToString(System.Globalization.CultureInfo.InvariantCulture), "view_centre", new object[] { ViewCentre[0], ViewCentre[1] },
                    "layer_to_create", !LayerExists);
            }
        }

        // Where the viewport goes and how big it is, checked before anything is drawn: the parts must fit and the layer must be usable.
        internal static ViewportPlan PlanViewport(object docSource, IDictionary<string, object> a, DetailResult built)
        {
            dynamic doc = docSource;
            Func<object, double[]> two = o => ((object[])o).Select(x => Convert.ToDouble(x, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
            double[] parts = two(built.Summary["parts_size_paper_mm"]);
            ViewportPlan v = new ViewportPlan { Centre = two(built.Summary["paper_centre"]), ViewCentre = two(built.Summary["model_centre"]), Scale = built.Scale };
            v.Width = Math.Round(parts[0] + 2 * ViewportMargin, 1);
            v.Height = Math.Round(parts[1] + 2 * ViewportMargin, 1);
            if (a.ContainsKey("__viewport_size"))
            {
                double[] size = (double[])a["__viewport_size"];
                if (size[0] < parts[0] || size[1] < parts[1])
                    throw new ToolException("view.viewport_size " + size[0].ToString(System.Globalization.CultureInfo.InvariantCulture) + " x " + size[1].ToString(System.Globalization.CultureInfo.InvariantCulture) + " mm is smaller than the parts on paper (" + parts[0].ToString(System.Globalization.CultureInfo.InvariantCulture) + " x " + parts[1].ToString(System.Globalization.CultureInfo.InvariantCulture) + " mm), so they would be cut off. Nothing was drawn.");
                v.Width = size[0]; v.Height = size[1];
            }
            Dictionary<string, bool> locks = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            dynamic layers = doc.Layers;
            int count = Convert.ToInt32(layers.Count);
            for (int i = 0; i < count; i++) { dynamic l = layers.Item(i); locks[Convert.ToString(l.Name)] = (bool)l.Lock; }
            // The viewport goes on the drawing's own not-plotted viewport layer: the scheme's, else AO-MV (counter sheets), else G-ANNO-NPLT
            // (kitchen library sheets); only when the drawing has none is one created, not plotted.
            string preferred = built.Summary.ContainsKey("layer_scheme") && (string)built.Summary["layer_scheme"] == "ao" ? "AO-MV" : "G-ANNO-VPRT";
            v.LayerName = new[] { preferred, "AO-MV", "G-ANNO-NPLT" }.FirstOrDefault(n => locks.ContainsKey(n)) ?? preferred;
            bool locked;
            v.LayerExists = locks.TryGetValue(v.LayerName, out locked);
            if (v.LayerExists && locked) throw new ToolException("Layer " + v.LayerName + " is locked, so the viewport cannot be placed on it. Unlock it and run again. Nothing was drawn.");
            return v;
        }

        // How the viewport's view is read: DXF 12 (view centre in DCS), 17 (target), 51 (twist), 45 (view height). AutoCAD's COM interface
        // has no view-centre property, so one read-only AutoLISP entget is sent and its answer read from a file (as get-viewport-centres.ps1
        // does, live-proven on the counter sheets). The last argument is the wait in milliseconds. Replaceable for tests.
        internal static Func<object, string, int, double[]> ReadViewportView = LispViewportView;

        private static double[] LispViewportView(object docSource, string handle, int waitMs)
        {
            dynamic doc = docSource;
            string file = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "dg-vp-" + Guid.NewGuid().ToString("N") + ".txt");
            string path = file.Replace('\\', '/');
            string lisp = "(progn (setq dg:e (entget (handent \"" + handle + "\")) dg:c (cdr (assoc 12 dg:e)) dg:t (cdr (assoc 17 dg:e)) dg:f (open \"" + path + "\" \"w\"))"
                + " (write-line (strcat (rtos (car dg:c) 2 8) \",\" (rtos (cadr dg:c) 2 8) \",\" (rtos (car dg:t) 2 8) \",\" (rtos (cadr dg:t) 2 8) \",\" (rtos (cdr (assoc 51 dg:e)) 2 8) \",\" (rtos (cdr (assoc 45 dg:e)) 2 8) \",END\") dg:f)"
                + " (close dg:f) (setq dg:e nil dg:c nil dg:t nil dg:f nil) (princ))\n";
            doc.SendCommand(lisp);
            try
            {
                for (int waited = 0; waited < waitMs; waited += 200)
                {
                    System.Threading.Thread.Sleep(200);
                    if (!System.IO.File.Exists(file)) continue;
                    string text;
                    try { text = System.IO.File.ReadAllText(file).Trim(); } catch (System.IO.IOException) { continue; }
                    string[] parts = text.Split(',');
                    if (parts.Length != 7 || parts[6] != "END") continue;
                    double[] values = new double[6];
                    for (int k = 0; k < 6; k++) values[k] = Double.Parse(parts[k], System.Globalization.CultureInfo.InvariantCulture);
                    return values;
                }
            }
            finally { try { System.IO.File.Delete(file); } catch (Exception) { } }
            throw new ToolException("AutoCAD did not answer the read-only view query within " + (waitMs / 1000).ToString(System.Globalization.CultureInfo.InvariantCulture) + " seconds. Is a dialog open or a command running? Press Esc in AutoCAD and run again.");
        }

        // Makes the viewport in one Undo group. Route 1, live-proven on AutoCAD 2024: layout current, paper space, regen, add the viewport,
        // turn it on, regen, switch into it, zoom to the model centre, set the scale. (Without the second regen AutoCAD answers "There is no
        // active modelspace viewport".) Route 2, if route 1 throws, the counter-sheet method with COM properties only: read the view offset,
        // set Target = model centre - offset, then the scale. The view centre is then read back and, if it is off, corrected through Target.
        // A layer it creates is not plotted; an existing layer is left as it is. On failure everything of it is removed.
        internal static object CreateViewport(object docSource, string layout, ViewportPlan v)
        {
            dynamic doc = docSource;
            int busy = 0;
            try { busy = Convert.ToInt32(doc.GetVariable("CMDACTIVE")); } catch (Exception) { }
            if (busy != 0) throw new ToolException("a command is running in AutoCAD. Press Esc and run again.");
            dynamic sheet = doc.Layouts.Item(layout);
            dynamic viewport = null;
            bool layerCreated = false;
            Func<double, string> n = x => x.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
            doc.StartUndoMark();
            try
            {
                try
                {
                    if (!v.LayerExists)
                    {
                        dynamic layer = doc.Layers.Add(v.LayerName);
                        layerCreated = true;
                        layer.Color = 8;
                        layer.Plottable = false;
                    }
                    doc.ActiveLayout = sheet;
                    try { doc.ActiveSpace = 0; } catch (Exception) { }
                    try { doc.Regen(1); } catch (Exception) { }
                    viewport = sheet.Block.AddPViewport(new double[] { v.Centre[0], v.Centre[1], 0 }, v.Width, v.Height);
                    viewport.Layer = v.LayerName;
                    viewport.Display(true);
                    string handle = Convert.ToString(viewport.Handle);
                    string method, zoomError = null;
                    try
                    {
                        doc.Regen(1);
                        doc.MSpace = true;
                        doc.ActivePViewport = viewport;
                        doc.Application.ZoomCenter(new double[] { v.ViewCentre[0], v.ViewCentre[1], 0 }, v.Height * v.Scale);
                        viewport.CustomScale = 1.0 / v.Scale;
                        doc.MSpace = false;
                        method = "zoom";
                    }
                    catch (Exception e)
                    {
                        zoomError = e.Message;
                        try { doc.MSpace = false; } catch (Exception) { }
                        double[] offset = ReadViewportView(docSource, handle, 12000);
                        if (Math.Abs(offset[4]) > 1e-9) throw new ToolException("the new viewport's view is twisted; only plan views are supported.");
                        viewport.Target = new double[] { v.ViewCentre[0] - offset[0], v.ViewCentre[1] - offset[1], 0 };
                        viewport.CustomScale = 1.0 / v.Scale;
                        method = "target";
                    }

                    // read the view back; correct it through Target if it is off; without an answer, say it was not read back
                    bool readBack = false, corrected = false;
                    double cx = Double.NaN, cy = Double.NaN;
                    double[] view = null;
                    try { view = ReadViewportView(docSource, handle, 6000); } catch (Exception) { }
                    if (view != null)
                    {
                        cx = view[2] + view[0]; cy = view[3] + view[1];
                        if (Math.Sqrt(Math.Pow(cx - v.ViewCentre[0], 2) + Math.Pow(cy - v.ViewCentre[1], 2)) > 0.5)
                        {
                            viewport.Target = new double[] { v.ViewCentre[0] - view[0], v.ViewCentre[1] - view[1], 0 };
                            corrected = true;
                            view = ReadViewportView(docSource, handle, 6000);
                            cx = view[2] + view[0]; cy = view[3] + view[1];
                            if (Math.Sqrt(Math.Pow(cx - v.ViewCentre[0], 2) + Math.Pow(cy - v.ViewCentre[1], 2)) > 0.5)
                                throw new ToolException("the viewport's view centre read back as " + n(cx) + ", " + n(cy) + " instead of " + n(v.ViewCentre[0]) + ", " + n(v.ViewCentre[1]) + ", even after correcting it.");
                        }
                        readBack = true;
                    }
                    viewport.DisplayLocked = true;
                    double custom = Convert.ToDouble(viewport.CustomScale);
                    if (Math.Abs(custom * v.Scale - 1.0) > 1e-6) throw new ToolException("the viewport scale read back as " + custom.ToString(System.Globalization.CultureInfo.InvariantCulture) + " instead of 1:" + v.Scale.ToString(System.Globalization.CultureInfo.InvariantCulture) + ".");
                    if (!(bool)viewport.DisplayLocked) throw new ToolException("the viewport display did not lock.");
                    try { doc.Regen(1); } catch (Exception) { }
                    Dictionary<string, object> result = Json.Object("handle", handle, "method", method, "layer", v.LayerName, "layer_created", layerCreated, "custom_scale", custom, "display_locked", true,
                        "centre", new object[] { v.Centre[0], v.Centre[1] }, "size", new object[] { v.Width, v.Height }, "view_centre_read_back", readBack);
                    if (readBack) { result["view_centre"] = new object[] { Math.Round(cx, 3), Math.Round(cy, 3) }; result["view_centre_corrected"] = corrected; }
                    else result["note"] = "AutoCAD did not answer the view read-back, so the centre is not proven: check that the section sits in the middle of the viewport.";
                    if (zoomError != null) result["zoom_route_error"] = zoomError;
                    return result;
                }
                catch (Exception)
                {
                    try { doc.MSpace = false; } catch (Exception) { }
                    if (viewport != null) { try { viewport.Delete(); } catch (Exception) { } }
                    if (layerCreated) { try { doc.Layers.Item(v.LayerName).Delete(); } catch (Exception) { } }
                    throw;
                }
            }
            finally { doc.EndUndoMark(); }
        }

        // The annotation is placed for a viewport at 1:scale. If the layout has viewports and none is at that scale, say so; the view centre cannot be read.
        private static string ViewportWarning(object docSource, string layout, int scale)
        {
            try
            {
                dynamic block = ((dynamic)docSource).Layouts.Item(layout).Block;
                int count = Convert.ToInt32(block.Count), viewports = 0;
                bool match = false;
                for (int i = 0; i < count; i++)
                {
                    dynamic entity = block.Item(i);
                    if (Convert.ToString(entity.ObjectName) != "AcDbViewport") continue;
                    double custom = Convert.ToDouble(entity.CustomScale);
                    if (custom <= 0) continue;   // the layout's own paper viewport
                    viewports++;
                    if (Math.Abs(custom * scale - 1.0) < 0.001) match = true;
                }
                if (viewports == 0) return "Layout '" + layout + "' has no viewport yet. Add one at scale 1:" + scale + " centred on the model point given in generated.summary.viewport_setup, or the annotation will not line up with the detail.";
                if (!match) return "Layout '" + layout + "' has " + viewports.ToString(System.Globalization.CultureInfo.InvariantCulture) + " viewport(s) but none at scale 1:" + scale + ". Dimensions read the model size only if the viewport is at that scale.";
                return null;
            }
            catch (Exception) { return "The layout's viewports could not be read, so the viewport scale was not checked."; }
        }

        private static object InvokeCore(string name, IDictionary<string, object> a)
        {
            dynamic cad = Connect();
            if (Convert.ToInt32(cad.Documents.Count) == 0) throw new ToolException("Open a drawing in AutoCAD first.");
            dynamic doc = cad.ActiveDocument;
            string expected = Json.GetString(a, "expected_drawing");
            if (expected.Length > 0 && !String.Equals(DrawingId((object)doc), expected, StringComparison.OrdinalIgnoreCase))
                throw new ToolException("Active drawing changed or expected_drawing is incorrect. Read drawing_info again.");

            switch (name)
            {
                case "drawing_info":
                    return Json.Object("name", Convert.ToString(doc.Name), "path", Convert.ToString(doc.FullName), "drawing_id", DrawingId((object)doc), "version", Convert.ToString(cad.Version),
                        "units_code", Plain(doc.GetVariable("INSUNITS")), "model_space_objects", Convert.ToInt32(doc.ModelSpace.Count), "saved", (bool)doc.Saved, "read_only", (bool)doc.ReadOnly,
                        "active_layout", Convert.ToString(doc.ActiveLayout.Name), "layouts", Each((object)doc.Layouts, l => Convert.ToString(l.Name)));
                case "list_layers":
                    return Json.Object("drawing", DrawingId((object)doc), "layers", Each((object)doc.Layers, l => Json.Object("name", Convert.ToString(l.Name), "color", Plain(l.Color), "on", (bool)l.LayerOn, "frozen", (bool)l.Freeze, "locked", (bool)l.Lock)));
                case "list_entities":
                    return ListEntities((object)doc, a);
                case "get_entity":
                    return ReadEntity((object)doc.HandleToObject(Json.GetString(a, "handle")), FieldSet(a));
                case "verify_standards":
                    return VerifyStandards((object)doc, a);
            }

            if (name == "apply_plan") return ApplyPlan((object)doc, a);
            if ((bool)doc.ReadOnly) throw new ToolException("Drawing is read-only.");
            if (name == "save_drawing")
            {
                if (String.IsNullOrEmpty(Convert.ToString(doc.Path))) throw new ToolException("Save this drawing to a file in AutoCAD first.");
                doc.Save();
                return Json.Object("drawing", DrawingId((object)doc), "saved", (bool)doc.Saved);
            }

            // Every action-specific argument is checked before anything changes.
            dynamic space2 = null, entity2 = null, layerItem = null;
            string action = Json.GetString(a, "action");
            switch (name)
            {
                case "create_entity":
                    AssertUnlocked((object)doc, Json.GetString(a, "layer"));
                    space2 = Space((object)doc, Json.GetString(a, "layout"));
                    string kind = Json.GetString(a, "kind");
                    if (kind == "line")
                    {
                        Require(a, "end");
                        if (String.Join(",", Schema.Point(a["point"])) == String.Join(",", Schema.Point(a["end"]))) throw new ToolException("Line endpoints must differ.");
                    }
                    if (kind == "circle") Require(a, "radius");
                    if (kind == "text") { Require(a, "text"); Require(a, "height"); }
                    break;
                case "edit_entity":
                    entity2 = doc.HandleToObject(Json.GetString(a, "handle"));
                    dynamic owner = doc.ObjectIDToObject(entity2.OwnerID);
                    if (!(bool)owner.IsLayout) throw new ToolException("Only top-level layout/model-space entities can be edited.");
                    AssertUnlocked((object)doc, Convert.ToString(entity2.Layer));
                    string objectName = Convert.ToString(entity2.ObjectName);
                    if (action == "move") Require(a, "displacement");
                    if (action == "change_layer") { Require(a, "layer"); AssertUnlocked((object)doc, Json.GetString(a, "layer")); }
                    if (action == "replace_text") { Require(a, "text"); if (objectName != "AcDbText" && objectName != "AcDbMText") throw new ToolException("Object is not TEXT or MTEXT."); }
                    if (action == "set_radius") { Require(a, "radius"); if (objectName != "AcDbCircle") throw new ToolException("Object is not a circle."); }
                    break;
                case "set_layer":
                    if (action != "create") layerItem = doc.Layers.Item(Json.GetString(a, "name"));
                    if (action == "color") Require(a, "color");
                    if (action == "on" || action == "frozen" || action == "locked") Require(a, "value");
                    break;
            }

            object data = null;
            doc.StartUndoMark();
            try
            {
                switch (name)
                {
                    case "create_entity":
                        {
                            dynamic created = null;
                            try
                            {
                                double[] at = Schema.Point(a["point"]);
                                switch (Json.GetString(a, "kind"))
                                {
                                    case "line": created = space2.AddLine(at, Schema.Point(a["end"])); break;
                                    case "circle": created = space2.AddCircle(at, Convert.ToDouble(a["radius"])); break;
                                    case "text": created = space2.AddText(Json.GetString(a, "text"), at, Convert.ToDouble(a["height"])); break;
                                }
                                created.Layer = Json.GetString(a, "layer");
                            }
                            catch (Exception)
                            {
                                if (created != null) { try { created.Delete(); } catch (Exception) { } }
                                throw;
                            }
                            data = ReadEntity((object)created);
                            break;
                        }
                    case "edit_entity":
                        switch (action)
                        {
                            case "move": entity2.Move(new double[] { 0, 0, 0 }, Schema.Point(a["displacement"])); break;
                            case "change_layer": entity2.Layer = Json.GetString(a, "layer"); break;
                            case "replace_text": entity2.TextString = Json.GetString(a, "text"); break;
                            case "set_radius": entity2.Radius = Convert.ToDouble(a["radius"]); break;
                            case "delete": entity2.Delete(); break;
                        }
                        data = action == "delete" ? (object)Json.Object("deleted_handle", Json.GetString(a, "handle")) : ReadEntity((object)entity2);
                        break;
                    case "set_layer":
                        switch (action)
                        {
                            case "create": layerItem = doc.Layers.Add(Json.GetString(a, "name")); break;
                            case "color": layerItem.Color = Convert.ToInt32(a["color"]); break;
                            case "on": layerItem.LayerOn = (bool)a["value"]; break;
                            case "frozen": layerItem.Freeze = (bool)a["value"]; break;
                            case "locked": layerItem.Lock = (bool)a["value"]; break;
                        }
                        data = Json.Object("layer", Convert.ToString(layerItem.Name), "color", Plain(layerItem.Color), "on", (bool)layerItem.LayerOn, "frozen", (bool)layerItem.Freeze, "locked", (bool)layerItem.Lock);
                        break;
                }
            }
            finally { doc.EndUndoMark(); }
            return Json.Object("drawing", DrawingId((object)doc), "result", data, "save_performed", false);
        }
    }
}
