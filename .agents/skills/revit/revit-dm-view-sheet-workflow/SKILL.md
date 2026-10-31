---
name: revit-dm-view-sheet-workflow
category: revit
description: Duplicate selected Revit views and sheets for DM documentation, preserve detailing and overrides, apply naming/templates, and align grids and viewports.
---

# DM Views and Sheets

- Operate on selected views/sheets only unless the user explicitly expands the scope.
- If a required DM view does not exist, duplicate the source **with detailing**. Reuse one DM duplicate; never create repeated copies of the same source.
- Preserve the level prefix (for example L00-L10) and source naming; use the suffix ' - DM'. Remove 'Copy', 'Copy 1', or 'Overall' only when requested.
- Assign the established DM view template/category and place each DM view on the corresponding DM sheet. Preserve view settings, annotations, and applied overrides.
- Derive sheet numbering from the user's latest stated pattern; do not reuse an older conflicting pattern.
- Copy grid setup from the named reference DM plan: extents, bubble ends, symbols, and elbows. Add or adjust elbows to prevent bubble overlap (including close grids such as 06-07). Hide only grids that fall outside the floor area in that view.
- On selected sheets, align viewports and viewport-title locations to the approved Ground Floor reference.
- Use the separate 'revit-grouped-dimension-dm' skill for dimensions inside detail groups. Never ungroup.
- Read back names, templates, categories, sheet placement, and viewport/grid state after writes.

