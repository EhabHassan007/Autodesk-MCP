using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using Autodesk.Revit.DB;

namespace BimCadMcp.Revit
{
    // Revision cloud helpers: what the document has loaded (revisions, cloud tag types), how views resolve to their primary
    // view, and revision clouds with an optional text note, created in batches. Plan views only for creation.
    internal static class RevisionClouds
    {
        private const double MillimetreInFeet = 1.0 / 304.8;
        internal const int MaxItems = 40;

        private static bool IsValid(ElementId id)
        {
            return id != null && !id.Equals(ElementId.InvalidElementId);
        }

        private static string IdText(ElementId id)
        {
            return id.Value.ToString(CultureInfo.InvariantCulture);
        }

        private static ElementId ParseId(string text, string what)
        {
            long value;
            if (!Int64.TryParse((text ?? "").Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
                throw new McpException("invalid_request", what + " must be an integer element id.");
            return new ElementId(value);
        }

        private static View FindView(Document document, string text)
        {
            View view = document.GetElement(ParseId(text, "view_id")) as View;
            if (view == null) throw new McpException("invalid_request", "view_id " + text + " is not a view.");
            return view;
        }

        // A dependent view cannot hold its own annotations: they belong to its primary view.
        private static View ResolvePrimary(Document document, View view)
        {
            ElementId primary = view.GetPrimaryViewId();
            if (!IsValid(primary)) return view;
            View resolved = document.GetElement(primary) as View;
            return resolved ?? view;
        }

        private static bool IsPlan(View view)
        {
            return view.ViewType == ViewType.FloorPlan || view.ViewType == ViewType.CeilingPlan ||
                view.ViewType == ViewType.EngineeringPlan || view.ViewType == ViewType.AreaPlan;
        }

        // arguments: zero or more view ids to resolve.
        internal static string Info(Document document, string[] arguments)
        {
            List<string> revisions = new List<string>();
            foreach (Revision revision in new FilteredElementCollector(document).OfClass(typeof(Revision)).Cast<Revision>().OrderBy(r => r.SequenceNumber))
            {
                revisions.Add("{" +
                    Json.Property("id", IdText(revision.Id)) + "," +
                    Json.NumberProperty("sequence", revision.SequenceNumber) + "," +
                    Json.Property("number", revision.RevisionNumber) + "," +
                    Json.Property("date", revision.RevisionDate) + "," +
                    Json.Property("description", revision.Description) + "," +
                    Json.Property("issued", revision.Issued) + "}");
            }

            // The Revision Cloud Tags category can hold a family that is not a tag at all (a model family put there by mistake).
            // Only a view-based (annotation) family can be a tag, so likely_tag says whether a type could be placed as one.
            List<string> tags = new List<string>();
            int likely = 0;
            foreach (FamilySymbol symbol in new FilteredElementCollector(document).OfClass(typeof(FamilySymbol)).OfCategory(BuiltInCategory.OST_RevisionCloudTags).Cast<FamilySymbol>())
            {
                Family family = symbol.Family;
                bool tag = family != null && family.FamilyPlacementType == FamilyPlacementType.ViewBased;
                if (tag) likely++;
                tags.Add("{" +
                    Json.Property("id", IdText(symbol.Id)) + "," +
                    Json.Property("family", family == null ? "" : family.Name) + "," +
                    Json.Property("type", symbol.Name) + "," +
                    Json.Property("placement_type", family == null ? "" : family.FamilyPlacementType.ToString()) + "," +
                    Json.Property("likely_tag", tag) + "}");
            }

            List<string> views = new List<string>();
            foreach (string text in arguments)
            {
                View view = FindView(document, text);
                View primary = ResolvePrimary(document, view);
                List<string> dependents = new List<string>();
                if (!view.IsTemplate)
                {
                    foreach (ElementId id in view.GetDependentViewIds()) dependents.Add("\"" + IdText(id) + "\"");
                }
                views.Add("{" +
                    Json.Property("id", IdText(view.Id)) + "," +
                    Json.Property("name", view.Name) + "," +
                    Json.Property("view_type", view.ViewType.ToString()) + "," +
                    Json.Property("is_template", view.IsTemplate) + "," +
                    Json.Property("is_dependent", IsValid(view.GetPrimaryViewId())) + "," +
                    Json.Property("primary_view_id", IdText(primary.Id)) + "," +
                    Json.Property("primary_view_name", primary.Name) + "," +
                    Json.Property("supports_cloud_creation_here", IsPlan(primary) && !primary.IsTemplate) + "," +
                    "\"dependent_view_ids\":[" + String.Join(",", dependents.ToArray()) + "]}");
            }

            return "{" +
                Json.Property("document_id", RevitOperations.DocumentId(document)) + "," +
                "\"revisions\":[" + String.Join(",", revisions.ToArray()) + "]," +
                "\"cloud_tag_types\":[" + String.Join(",", tags.ToArray()) + "]," +
                Json.NumberProperty("likely_tag_types", likely) + "," +
                "\"views\":[" + String.Join(",", views.ToArray()) + "]}";
        }

        // arguments: expected_document, revision_id, view_id, options (note_type_id, note_side, gap_mm, dry_run),
        // then one field per cloud: "xmin;ymin;xmax;ymax;base64(comment);base64(note)" in model millimetres.
        internal static string Create(Document document, string[] arguments)
        {
            if (arguments == null || arguments.Length < 5)
                throw new McpException("invalid_request", "Invalid request arguments.");
            if (!String.Equals(RevitOperations.DocumentId(document), arguments[0], StringComparison.OrdinalIgnoreCase))
                throw new McpException("document_changed", "Active Revit document changed. Read document_info again.");
            if (document.IsReadOnly) throw new McpException("document_read_only", "The active Revit document is read-only.");
            int count = arguments.Length - 4;
            if (count > MaxItems)
                throw new McpException("invalid_request", "At most " + MaxItems.ToString(CultureInfo.InvariantCulture) + " clouds per call; send the rest in further calls.");

            Revision revision = document.GetElement(ParseId(arguments[1], "revision_id")) as Revision;
            if (revision == null) throw new McpException("invalid_request", "revision_id " + arguments[1] + " is not a revision.");
            if (revision.Issued) throw new McpException("revision_issued", "Revision " + revision.RevisionNumber + " is issued; clouds cannot be added to an issued revision. Use an open revision.");

            View requested = FindView(document, arguments[2]);
            View view = ResolvePrimary(document, requested);
            if (view.IsTemplate) throw new McpException("invalid_request", "view_id is a view template, not a view.");
            if (!IsPlan(view)) throw new McpException("invalid_request", "create_revision_clouds works in plan views (floor, ceiling, structural and area plans); view " + view.Name + " is " + view.ViewType.ToString() + ".");
            XYZ normal = view.ViewDirection;
            if (Math.Abs(normal.Z) < 0.5) throw new McpException("invalid_request", "The view plane is not horizontal; this tool places clouds in plan views only.");

            string options = arguments[3];
            bool dryRun = String.Equals(RunOptions.Value(options, "dry_run"), "true", StringComparison.OrdinalIgnoreCase);
            string side = RunOptions.Value(options, "note_side").ToLowerInvariant();
            if (side.Length == 0) side = "right";
            if (side != "right" && side != "left") throw new McpException("invalid_request", "note_side must be right or left.");
            double gap = 200.0;
            string gapText = RunOptions.Value(options, "gap_mm");
            if (gapText.Length > 0 && !Double.TryParse(gapText, NumberStyles.Float, CultureInfo.InvariantCulture, out gap))
                throw new McpException("invalid_request", "gap_mm must be a number.");
            string typeText = RunOptions.Value(options, "note_type_id");
            ElementId noteType = typeText.Length > 0 ? ParseId(typeText, "note_type_id") : document.GetDefaultElementTypeId(ElementTypeGroup.TextNoteType);
            if (!(document.GetElement(noteType) is TextNoteType)) throw new McpException("invalid_request", "note_type_id is not a text note type.");

            List<double[]> boxes = new List<double[]>();
            List<string> comments = new List<string>();
            List<string> notes = new List<string>();
            for (int i = 0; i < count; i++)
            {
                string[] parts = arguments[4 + i].Split(';');
                if (parts.Length != 6) throw new McpException("invalid_request", "Cloud " + i.ToString(CultureInfo.InvariantCulture) + " is not valid.");
                double[] box = new double[4];
                for (int k = 0; k < 4; k++)
                {
                    if (!Double.TryParse(parts[k], NumberStyles.Float, CultureInfo.InvariantCulture, out box[k]))
                        throw new McpException("invalid_request", "Cloud " + i.ToString(CultureInfo.InvariantCulture) + " has a coordinate that is not a number.");
                }
                if (box[2] <= box[0] || box[3] <= box[1])
                    throw new McpException("invalid_request", "Cloud " + i.ToString(CultureInfo.InvariantCulture) + " needs x_max_mm > x_min_mm and y_max_mm > y_min_mm.");
                boxes.Add(box);
                comments.Add(Protocol.Decode(parts[4]));
                notes.Add(Protocol.Decode(parts[5]));
            }

            List<string> created = new List<string>();
            List<string> failed = new List<string>();
            string changes;
            Changes.Run(document, "Smart Connector: Revision clouds", dryRun, delegate
            {
                for (int i = 0; i < boxes.Count; i++)
                {
                    // Each cloud and its note are one sub-transaction: if the note (or anything else) fails, the cloud is rolled
                    // back too, so a failed item leaves nothing behind and a retry cannot duplicate it.
                    using (SubTransaction item = new SubTransaction(document))
                    {
                        try
                        {
                            item.Start();
                            double[] b = boxes[i];
                            List<Curve> loop = new List<Curve>();
                            XYZ p1 = OnPlane(view, b[0], b[1]), p2 = OnPlane(view, b[2], b[1]), p3 = OnPlane(view, b[2], b[3]), p4 = OnPlane(view, b[0], b[3]);
                            loop.Add(Line.CreateBound(p1, p2));
                            loop.Add(Line.CreateBound(p2, p3));
                            loop.Add(Line.CreateBound(p3, p4));
                            loop.Add(Line.CreateBound(p4, p1));
                            RevisionCloud cloud = RevisionCloud.Create(document, view, revision.Id, loop);
                            bool commentSet = false;
                            if (comments[i].Length > 0)
                            {
                                // The built-in parameter does not depend on Revit's display language; the name is the fallback.
                                Parameter parameter = cloud.get_Parameter(BuiltInParameter.ALL_MODEL_INSTANCE_COMMENTS) ?? cloud.LookupParameter("Comments");
                                if (parameter != null && !parameter.IsReadOnly) commentSet = parameter.Set(comments[i]);
                            }
                            string noteId = "";
                            if (notes[i].Length > 0)
                            {
                                bool right = side == "right";
                                XYZ at = right ? OnPlane(view, b[2] + gap, b[3]) : OnPlane(view, b[0] - gap, b[3]);
                                TextNoteOptions noteOptions = new TextNoteOptions(noteType);
                                noteOptions.HorizontalAlignment = right ? HorizontalTextAlignment.Left : HorizontalTextAlignment.Right;
                                noteId = IdText(TextNote.Create(document, view.Id, at, notes[i], noteOptions).Id);
                            }
                            TransactionStatus status = item.Commit();
                            if (status != TransactionStatus.Committed)
                                throw new InvalidOperationException("Revit did not keep this cloud (status " + status.ToString() + ").");
                            created.Add("{" + Json.NumberProperty("index", i) + "," + Json.Property("cloud_id", IdText(cloud.Id)) + "," + Json.Property("note_id", noteId) + "," + Json.Property("comment_set", commentSet) + "}");
                        }
                        catch (Exception exception)
                        {
                            if (item.GetStatus() == TransactionStatus.Started) item.RollBack();
                            failed.Add("{" + Json.NumberProperty("index", i) + "," + Json.Property("error", exception.GetType().Name + ": " + exception.Message) + "," + Json.Property("rolled_back", true) + "}");
                        }
                    }
                }
                return "";
            }, out changes);

            return "{" +
                Json.Property("document_id", RevitOperations.DocumentId(document)) + "," +
                Json.Property("revision_id", IdText(revision.Id)) + "," +
                Json.Property("view_id", IdText(view.Id)) + "," +
                Json.Property("view_name", view.Name) + "," +
                Json.Property("resolved_from_dependent_view", !requested.Id.Equals(view.Id)) + "," +
                Json.NumberProperty("requested", count) + "," +
                Json.NumberProperty("created", created.Count) + "," +
                Json.NumberProperty("failed", failed.Count) + "," +
                (dryRun ? Json.Property("dry_run", true) + "," + Json.Property("rolled_back", true) + ",\"changes\":" + changes + "," : "") +
                "\"clouds\":[" + String.Join(",", created.ToArray()) + "]," +
                "\"failures\":[" + String.Join(",", failed.ToArray()) + "]}";
        }

        // A model-space point (millimetres) on the view's own plane.
        private static XYZ OnPlane(View view, double xMillimetres, double yMillimetres)
        {
            double x = xMillimetres * MillimetreInFeet;
            double y = yMillimetres * MillimetreInFeet;
            XYZ origin = view.Origin;
            XYZ normal = view.ViewDirection;
            double z = origin.Z - (normal.X * (x - origin.X) + normal.Y * (y - origin.Y)) / normal.Z;
            return new XYZ(x, y, z);
        }
    }
}
