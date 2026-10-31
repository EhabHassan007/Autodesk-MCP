---
name: revit-dm-room-area-tags
description: Update Room and Area names/tags in selected DM Revit views while preserving groups and keeping tags legible inside their spaces.
---

# DM Room and Area Tags

- Do not touch Area Tags unless the current request explicitly asks for them.
- Limit changes to selected views/elements. Match Area names to Room names at the same location only after checking the spatial correspondence.
- Established DM tag mappings include:
  - 'APG-AR-ROOM WITH AREA TAG' / 'APG_AR_Room Name + Area' to 'APG-AR-ROOM WITH AREA TAG-DM' / 'APG_AR_Room Name + Number'.
  - 'APG-AR-ID ROOM TAG' to 'APG-AR-ID ROOM TAG-DM'.
  - 'Room Tag1' to 'Room Tag - DM'.
  - 'APG-AR-ROOM TAG' to 'APG-AR-ROOM WITH AREA TAG-DM'.
- When the user names a reference view, reuse its tag family/type in the selected BUA/GFA plans.
- Keep tags inside their Room/Area when space is sufficient and move them clear of walls. Add a leader only when an inside placement cannot remain legible. Do not move every tag outside its area.
- If leaders must be undone, remove only the leaders created by the operation and restore the prior tag positions.
- Never ungroup a detail group. Duplicate/edit the group type only through the established grouped-dimension workflow when relevant.
- Read back changed tag types, positions, leaders, and unmatched rooms/areas.

