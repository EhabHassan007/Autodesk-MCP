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
                    Schema.Tool("apply_plan", "Create many objects in ONE undoable call from a plan (one round trip instead of hundreds). items are ordered steps {op, ...}: layer{name,color?,linetype?,lineweight?}, line{layer,start,end}, circle{layer,center,radius}, arc{layer,center,radius,start_angle,end_angle}, polyline{layer,points:[[x,y],...],closed?}, text{layer,point,text,height,rotation?,style?}, mtext{layer,point,width,text,height?,rotation?,style?; \\P = new line}, insert{layer,name,point,scale?,rotation?}. Points are [x,y] or [x,y,z] in WCS drawing units; angles are degrees counter-clockwise; lineweight is in hundredths of mm. A step may carry an id; its handle is returned. A layer must already exist (or be created by an earlier layer step) and be unlocked; blocks, linetypes and text styles must already be in the drawing. At most 500 steps. Run with dry_run=true first: it checks everything against the drawing and changes nothing. A failed run removes what it created. Does not save.",
                        Json.Object("expected_drawing", target(), "layout", str(), "dry_run", Json.Object("type", "boolean"),
                            "items", Json.Object("type", "array", "items", Json.Object("type", "object"), "minItems", 1, "maxItems", AutoCadPlan.MaxItems)),
                        new[] { "expected_drawing", "items" }, false),
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

        private static string DrawingId(object source)
        {
            dynamic document = source;
            string path = Convert.ToString(document.Path);
            return String.IsNullOrEmpty(path) ? Convert.ToString(document.Name) : Convert.ToString(document.FullName);
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
                case "insert": return space.InsertBlock(p.Point, p.BlockName, p.Scale, p.Scale, p.Scale, p.Rotation * toRadians);
            }
            throw new ToolException("Unsupported plan step: " + p.Op);
        }

        // Validates the whole plan against this drawing, then (unless dry_run) creates it in one Undo group. Anything
        // created is removed again if a step fails, and the object count is read back to confirm the result.
        private static object ApplyPlan(object source, IDictionary<string, object> a)
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
            bool needsLinetypes = plan.Any(p => p.Linetype != null), needsStyles = plan.Any(p => p.TextStyle != null), needsBlocks = plan.Any(p => p.Op == "insert");
            HashSet<string> linetypes = needsLinetypes ? Names((object)doc.Linetypes) : new HashSet<string>();
            HashSet<string> styles = needsStyles ? Names((object)doc.TextStyles) : new HashSet<string>();
            HashSet<string> blocks = needsBlocks ? Names((object)doc.Blocks) : new HashSet<string>();
            List<string> problems = AutoCadPlan.CheckReferences(plan, layers, linetypes, styles, blocks);
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
                        dynamic entity = CreateItem((object)space, p);
                        created.Add((object)entity);
                        entity.Layer = p.Layer;
                        if (p.TextStyle != null) entity.StyleName = p.TextStyle;
                        objects++;
                        if (p.Id != null) handles[p.Id] = Convert.ToString(entity.Handle);
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
            return Json.Object("drawing", DrawingId((object)doc), "result", data, "save_performed", false);
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
