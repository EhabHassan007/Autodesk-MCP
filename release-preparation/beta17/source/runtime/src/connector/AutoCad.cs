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
                    Schema.Tool("list_entities", "Read paginated top-level model-space or named-layout objects, including geometry/text where available. Does not expand blocks or xrefs. Offset refers to collection index; one call examines at most 2000 objects, so continue from next_offset when it is set.",
                        Json.Object("layout", str(), "layer", str(), "offset", Json.Object("type", "integer", "minimum", 0), "limit", Json.Object("type", "integer", "minimum", 1, "maximum", 200)), new string[0], true),
                    Schema.Tool("get_entity", "Read an object by handle from the expected drawing.", Json.Object("expected_drawing", target(), "handle", str()), new[] { "expected_drawing", "handle" }, true),
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
                    Schema.Tool("apply_plan", "Create many objects in ONE undoable call from a plan (one round trip instead of hundreds). items are ordered steps {op, ...}: layer{name,color?,linetype?,lineweight?}, line{layer,start,end}, circle{layer,center,radius}, arc{layer,center,radius,start_angle,end_angle}, polyline{layer,points:[[x,y],...],closed?}, text{layer,point,text,height,rotation?,style?}, mtext{layer,point,width,text,height?,rotation?,style?; \\P = new line}, insert{layer,name,point,scale?,rotation?,attributes? (object of attribute tag: text; a tag the block lacks fails the step)}, hatch{layer,pattern,boundary,holes?,scale?,angle?,color?} (boundary and holes are ids of EARLIER closed polyline or circle steps, so give those steps an id), dim_aligned{layer,from,to,location,style?,scale?}, dim_rotated{layer,from,to,location,angle,style?,scale?} (location is a point the dimension line passes through; the value shown is the measured one; scale sets the dimension's overall scale, for example the detail scale denominator; linear_factor, for a dimension drawn in a paper-space layout over model geometry, multiplies the measured value so it reads the model size, for example 10 for a 1:10 viewport). Points are [x,y] or [x,y,z] in WCS drawing units; angles are degrees counter-clockwise; lineweight is in hundredths of mm. A step may carry an id; its handle is returned. A layer must already exist (or be created by an earlier layer step) and be unlocked; blocks, linetypes, text styles and dimension styles must already be in the drawing. At most 500 steps. Run with dry_run=true first: it checks everything against the drawing and changes nothing. A failed run removes what it created. Does not save.",
                        Json.Object("expected_drawing", target(), "layout", str(), "dry_run", Json.Object("type", "boolean"),
                            "items", Json.Object("type", "array", "items", Json.Object("type", "object"), "minItems", 1, "maxItems", AutoCadPlan.MaxItems)),
                        new[] { "expected_drawing", "items" }, false),
                    Schema.Tool("execute_autocad", "Execute controlled C# against the active AutoCAD drawing: the full AutoCAD ActiveX API, for work the other tools do not cover (hatches, dimensions, tables, block definitions, styles, queries). The code is the body of a method with two dynamic variables, cad (the AutoCAD Application) and doc (the active Document), and must return a string. Use execution_mode read for inspection (allow_model_changes=false); use write for edits (allow_model_changes=true, one Undo group). Call drawing_info first. Does not save unless the code does. Not a sandbox: the code runs with your Windows permissions, so run only code you have read.",
                        Json.Object("expected_drawing", target(), "execution_mode", Json.Object("type", "string", "enum", new object[] { "read", "write" }),
                            "allow_model_changes", Json.Object("type", "boolean"),
                            "code", Json.Object("type", "string", "minLength", 1, "maxLength", AutoCadScript.MaxCodeLength),
                            "timeout_seconds", Json.Object("type", "integer", "minimum", 1, "maximum", 300)),
                        new[] { "expected_drawing", "execution_mode", "allow_model_changes", "code" }, false),
                    Schema.Tool("generate_detail", "Detail Generator: build a draft construction detail from a short brief, and optionally draw it. Two templates. custom_section draws a section from parts the caller read off pictures and plans: params.parts [{id, material (mdf, ply, stone, corian, steel, glass, outline), x0, y0, x1, y1}] in mm with x from the staff face and y up from the floor, optional levels [{y, label}], notes [{part, text, y?}], dimensions [{from, to, axis x|y, chain?}], title, overall_dimensions, floor; every number and wording is the caller's and nothing is invented or checked against a code. reception_counter_section is a vertical section through a reception counter, in millimetres only: boards, plinth, top (corian by default, or stone), optional shelf, optional raised bar, or a wheelchair-accessible section (params.section = accessible; it needs accessible_height, knee_clearance_height, knee_clearance_depth and code_reference from the code you adopt, none are built in). params holds the design parameters in mm, all with defaults except the accessible ones. scale is the detail scale denominator (10 = 1:10); origin is where the floor meets the staff face. With apply=false (the default) AutoCAD is not contacted: you get a summary, warnings and, with return_plan, the steps. With apply=true (expected_drawing required) the drawing must be in millimetres, the plan is checked against it and drawn like apply_plan; dry_run defaults to true. Existing layers are left as they are unless update_layers. Unless dimension_style or text_style is given (or use_reference_styles is false), the drawing's reference styles are used when present: dimension style na1, text style EN-S for notes and levels, EN-SCB for titles; if one is missing the result says so. annotation says where dimensions, notes, levels and titles go: model (default, drawn in model space at the detail scale), paper (drawn in the layout named by layout at true paper size, text 2.5 mm, dimensions reading the model size; view.paper_centre [x,y] is where the detail sits on the sheet, optional view.model_centre; the layout needs a viewport at scale 1:scale centred on the model centre, which the result states and which this tool cannot set), or none (geometry only). level_block (with level_tag, default LEVEL, and level_block_scale) uses an office block with an attribute for level markers in paper mode. Every result is a draft for a designer's review.",
                        Json.Object("expected_drawing", target(), "template", Json.Object("type", "string", "enum", new object[] { AutoCadDetail.ReceptionCounterSection, AutoCadDetail.CustomSection }),
                            "params", Json.Object("type", "object"), "scale", Json.Object("type", "integer", "minimum", 1, "maximum", 200), "origin", point(),
                            "dimension_style", str(), "text_style", str(), "dimension_scale", Json.Object("type", "number", "exclusiveMinimum", 0),
                            "apply", Json.Object("type", "boolean"), "dry_run", Json.Object("type", "boolean"), "update_layers", Json.Object("type", "boolean"), "use_reference_styles", Json.Object("type", "boolean"), "return_plan", Json.Object("type", "boolean"),
                            "annotation", Json.Object("type", "string", "enum", new object[] { "model", "paper", "none" }), "layout", str(), "view", Json.Object("type", "object"),
                            "level_block", str(), "level_tag", str(), "level_block_scale", Json.Object("type", "number", "exclusiveMinimum", 0)),
                        new[] { "template" }, false),
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

        private static Dictionary<string, object> ReadEntity(object source)
        {
            dynamic entity = source;
            string type = Convert.ToString(entity.ObjectName);
            Dictionary<string, object> result = Json.Object("handle", Convert.ToString(entity.Handle), "type", type, "layer", Convert.ToString(entity.Layer));
            string[] properties;
            bool learning = !PropertiesByType.TryGetValue(type, out properties);
            List<string> present = new List<string>();
            foreach (string property in learning ? EntityProperties : properties)
            {
                try
                {
                    object value = Microsoft.VisualBasic.Interaction.CallByName(source, property, Microsoft.VisualBasic.CallType.Get);
                    present.Add(property);
                    if (value != null) result[property] = Plain(value);
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
        private static void SetAttributes(object blockSource, PlanItem p)
        {
            dynamic block = blockSource;
            Dictionary<string, dynamic> found = new Dictionary<string, dynamic>(StringComparer.OrdinalIgnoreCase);
            if ((bool)block.HasAttributes)
                foreach (dynamic attribute in (System.Collections.IEnumerable)block.GetAttributes())
                    found[Convert.ToString(attribute.TagString)] = attribute;
            foreach (KeyValuePair<string, string> pair in p.Attributes)
            {
                dynamic attribute;
                if (!found.TryGetValue(pair.Key, out attribute)) throw new ToolException("items[" + p.Index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]: block '" + p.BlockName + "' has no attribute '" + pair.Key + "'.");
                attribute.TextString = pair.Value;
                if (Convert.ToString(attribute.TextString) != pair.Value) throw new ToolException("items[" + p.Index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]: attribute '" + pair.Key + "' did not take the text.");
            }
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
                        if (p.Closed) polyline.Closed = true;
                        return polyline;
                    }
                case "text":
                    {
                        dynamic text = space.AddText(p.Text, p.Point, p.Height);
                        if (p.Rotation != 0) text.Rotation = p.Rotation * toRadians;
                        return text;
                    }
                case "mtext":
                    {
                        dynamic mtext = space.AddMText(p.Point, p.Width, p.Text);
                        if (p.Height > 0) mtext.Height = p.Height;
                        if (p.Rotation != 0) mtext.Rotation = p.Rotation * toRadians;
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
            bool needsLinetypes = plan.Any(p => p.Linetype != null), needsStyles = plan.Any(p => p.TextStyle != null), needsBlocks = plan.Any(p => p.Op == "insert"), needsDimStyles = plan.Any(p => p.DimStyle != null);
            HashSet<string> linetypes = needsLinetypes ? Names((object)doc.Linetypes) : new HashSet<string>();
            HashSet<string> styles = needsStyles ? Names((object)doc.TextStyles) : new HashSet<string>();
            HashSet<string> blocks = needsBlocks ? Names((object)doc.Blocks) : new HashSet<string>();
            HashSet<string> dimStyles = needsDimStyles ? Names((object)doc.DimStyles) : new HashSet<string>();
            List<string> problems = AutoCadPlan.CheckReferences(plan, layers, linetypes, styles, blocks, dimStyles);
            if (problems.Count > 0) throw new ToolException("The plan cannot be applied:\n" + String.Join("\n", problems.ToArray()));

            List<string> toCreate = AutoCadPlan.LayersToCreate(plan, layers.Keys);
            Dictionary<string, object> counts = AutoCadPlan.Counts(plan);
            if (dryRun)
                return Json.Object("drawing", DrawingId((object)doc), "dry_run", true, "valid", true, "steps", plan.Count, "counts", counts, "layers_to_create", toCreate,
                    "layout", layout.Length == 0 ? "Model" : layout, "save_performed", false);

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
                foreach (string key in view.Keys) if (key != "paper_centre" && key != "model_centre") throw new ToolException("Unknown view field: " + key + ". Allowed: paper_centre, model_centre.");
                if (view.ContainsKey("paper_centre")) place.PaperCentre = Schema.Point(view["paper_centre"]);
                if (view.ContainsKey("model_centre")) place.ModelCentre = Schema.Point(view["model_centre"]);
            }
            if (a.ContainsKey("level_block")) place.LevelBlock = Json.GetString(a, "level_block");
            if (a.ContainsKey("level_tag")) place.LevelTag = Json.GetString(a, "level_tag");
            if (a.ContainsKey("level_block_scale")) place.LevelBlockScale = Convert.ToDouble(a["level_block_scale"], System.Globalization.CultureInfo.InvariantCulture);
            if (place.Mode == "paper" && apply0(a) && Json.GetString(a, "layout").Length == 0) throw new ToolException("annotation paper needs layout: the name of the layout to annotate.");
            if (place.Mode != "paper" && a.ContainsKey("layout")) throw new ToolException("layout is used with annotation paper only.");
            DetailResult built = AutoCadDetail.Build(Json.GetString(a, "template"), parameters, scale, ox, oy, dimStyle, textStyle, dimScale, place);

            Dictionary<string, object> generated = Json.Object("summary", built.Summary, "warnings", built.Warnings);
            if (a.ContainsKey("return_plan") && (bool)a["return_plan"]) { generated["items"] = built.Items; if (built.PaperItems.Count > 0) generated["paper_items"] = built.PaperItems; }
            bool apply = a.ContainsKey("apply") && (bool)a["apply"];
            if (!apply) return Json.Object("applied", false, "generated", generated);
            if (Json.GetString(a, "expected_drawing").Length == 0) throw new ToolException("expected_drawing is required when apply is true.");

            dynamic cad = Connect();
            if (Convert.ToInt32(cad.Documents.Count) == 0) throw new ToolException("Open a drawing in AutoCAD first.");
            dynamic doc = cad.ActiveDocument;
            return ApplyGenerated((object)doc, a, built, generated);
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
            Dictionary<string, object> paperArguments = Json.Object("expected_drawing", id, "dry_run", true, "items", paperSteps.ToArray(), "layout", layout);
            object modelCheck = ApplyPlan(docSource, Json.Object("expected_drawing", id, "dry_run", true, "items", steps.ToArray()));
            object paperCheck = ApplyPlan(docSource, paperArguments);
            string viewportWarning = ViewportWarning(docSource, layout, built.Scale);
            if (viewportWarning != null) generated["viewport_warning"] = viewportWarning;
            if (dry) return Json.Object("applied", false, "generated", generated, "plan_result", modelCheck, "paper_plan_result", paperCheck);

            object modelResult = ApplyPlan(docSource, planArguments);
            paperArguments["dry_run"] = false;
            try { return Json.Object("applied", true, "generated", generated, "plan_result", modelResult, "paper_plan_result", ApplyPlan(docSource, paperArguments)); }
            catch (ToolException e) { throw new ToolException("The geometry was drawn in model space, but the annotation in layout '" + layout + "' failed and was rolled back: " + e.Message + " Undo once (U) to remove the geometry, fix the cause, then run again."); }
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
                    {
                        dynamic space = Space((object)doc, Json.GetString(a, "layout"));
                        int limit = a.ContainsKey("limit") ? Convert.ToInt32(a["limit"]) : 100;
                        int i = a.ContainsKey("offset") ? Convert.ToInt32(a["offset"]) : 0, start = i;
                        int count = Convert.ToInt32(space.Count);
                        string layer = Json.GetString(a, "layer");
                        List<object> items = new List<object>();
                        while (i < count && items.Count < limit && (i - start) < MaxScanPerCall)
                        {
                            dynamic entity = space.Item(i); i++;
                            if (layer.Length == 0 || String.Equals(Convert.ToString(entity.Layer), layer, StringComparison.OrdinalIgnoreCase)) items.Add(ReadEntity((object)entity));
                        }
                        return Json.Object("drawing", DrawingId((object)doc), "entities", items, "next_offset", i < count ? (object)i : null, "collection_count", count, "scanned", i - start);
                    }
                case "get_entity":
                    return ReadEntity((object)doc.HandleToObject(Json.GetString(a, "handle")));
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
