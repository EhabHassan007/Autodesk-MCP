# Running C# in Revit: lessons from a large workshared model

Runner template rules, silent rollbacks + failure logger, timeouts, batching, family reload via UI.

Related rules (revit-rules): RVT-005, RVT-007, RVT-026, RVT-028, RVT-029, RVT-033

Imported from the APG team Revit guide "revit-csharp-runner" (2026-11-25) and adapted to Smart Connector: C# runs through `execute_csharp` (rules RVT-005, RVT-026), and timeouts follow RVT-007. Where this text and revit-rules disagree, revit-rules wins.

## Overview

`execute_csharp` wraps your code in `Run(UIApplication application, Document document, string parametersJson)`. These rules come from repeated failures on a large workshared cloud model (Revit 2024, about 40 links). Following them avoids silent data loss and wasted rounds.

## Code template rules

- The document variable is `document`. Don't declare a local that shadows outer names (e.g. `doc`): it fails to compile.
- **execution_mode=transaction already runs a Transaction.** Never start your own Transaction on `document` in that mode. Use execution_mode=manual when you need your own transactions, including on *other* documents such as a family doc opened with `EditFamily` (RVT-026).
- Language level is C# 5 (RVT-005): no `?.`, no string interpolation, no `nameof`. `System.Linq`, `System.Text`, `System.IO` and `System.Collections.Generic` are already imported; fully qualify `Autodesk.Revit.DB.Events.*`.
- Revit 2024: use `new ElementId(long)` and `.Value`. `ElementId(int)` and `IntegerValue` are deprecated.
- Return a short string summary. Large outputs are slow. Write big dumps to a file in the working folder the user named instead.

## Silent rollbacks: always verify

The runner can say "success" while Revit rolls back the transaction at commit because of an error. Known triggers:
- editing elements inside groups ("Changes to groups are allowed only in group edit mode")
- system types such as "Linear Dimension Style"
- tags pushed outside their room without a leader
- read-only parameters

After every write, run a **separate read-back call**. When changes don't stick, attach this one-shot failure logger in the same call as the write:

```csharp
Document d=document; string path=@"<working folder>\failure_log.txt";
bool[] done=new bool[]{false};
EventHandler<Autodesk.Revit.DB.Events.FailuresProcessingEventArgs> h=null;
h=(sender,args)=>{ if(done[0]) return; Autodesk.Revit.DB.FailuresAccessor fa=args.GetFailuresAccessor(); if(fa.GetDocument().Title!=d.Title) return; done[0]=true;
  var sb=new System.Text.StringBuilder();
  foreach(FailureMessageAccessor m in fa.GetFailureMessages()){ sb.Append(m.GetSeverity()+" | "+m.GetDescriptionText()+" | "); foreach(ElementId i in m.GetFailingElementIds()) sb.Append(i.Value+","); sb.AppendLine(); }
  System.IO.File.WriteAllText(path,sb.ToString());
  ((Autodesk.Revit.ApplicationServices.Application)sender).FailuresProcessing-=h; };
d.Application.FailuresProcessing+=h;
// ... the write code ...
```
Then read the log through the device shell or file tools.

## Timeouts and batching

- A timeout does not mean the work failed. Follow RVT-007: do not re-send the request; use `get_job` when a job id is returned, otherwise wait for Revit to go idle, check `connection_status`, then do a fresh read-back before anything else.
- Keep batches small: 1–3 views per call and about 300–400 element changes. Return `remain=N` and loop.
- Collect with `ElementMulticategoryFilter` or `OfCategory`. A bare `FilteredElementCollector(doc, viewId)` over everything is very slow with many links.
- **Read first, write after.** Calling `get_BoundingBox(view)` or reading geometry after a move forces a regeneration on each iteration.
- Skip grouped elements: `e.GroupId.Value > 0`.

## Model and worksharing notes

- After a sync with central, the Undo stack is cleared, so you cannot undo by UI. Plan script-based reverts: store the original positions or types before bulk moves. Element IDs of new elements such as templates can also change, so look things up by name.
- Heavy sheets regenerate for minutes. Ask the user to switch the active view to a light one (schedule or legend) and close sheet tabs before scripts run.
- `View.Duplicate` fails on view templates. Create templates from a view with `CreateViewTemplate()`; see revit-template-standardisation.
- `SetLinkOverrides` cannot set the Custom link type.
- `View.GetOrderedFilters()`: the first filter wins. Remove and re-add a filter to move it to the bottom.
- Linked elements: `RoomTag.TaggedRoomId` and `IndependentTag.GetTaggedElementIds()` return `LinkElementId`. Convert positions with `RevitLinkInstance.GetTotalTransform()`, and check rooms with `room.IsPointInRoom(inv.OfPoint(pt))` at z = level + 1 ft.

## Families

- `document.EditFamily(fam)` gives a family doc. Modify it inside your own `Transaction`, `SaveAs` a **new** .rfa name in the project's Families_STD folder so the original is never overwritten, then `Close(false)`.
- `LoadFamily` called from inside the runner transaction can fail with "document must not be modifiable". New names sometimes load via `document.LoadFamily(path, out fam)`. Reloading an existing family always needs the UI (below).

### Family reload via UI (computer use)

1. Revit may be on a secondary monitor. Take a screenshot, then switch display if needed.
2. Computer-use access lasts about 30 min. Re-grant through `computer_resolve_access`, then `computer_request_access` for "Revit 20xx".
3. Go to Insert › Load Family. In the file dialog, navigate by double-clicking folders, since typing paths is unreliable. Pick the .rfa and click Open.
4. Choose **"Overwrite the existing version"**. If Revit asks to make the elements editable (workshared), answer **Yes**.
5. Verify by script: the type count, label positions and parameter values.

## Communication

- Users are architects and BIM professionals. Be concise and use Revit terms.
- When something is rolled back or skipped, say so plainly with counts. Never report work as done without a read-back.
- Syncing with central is the user's action. Remind them at the end of a big batch.
