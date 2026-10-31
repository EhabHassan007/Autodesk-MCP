---
name: revit-linked-room-schedules
category: revit
description: Build exact Revit schedules and Excel floor rollups for selected Room-name groups stored in linked architectural models.
---

# Linked Room Schedules

- Audit placed Rooms in the authoritative links and include real spelling variants. Ignore unplaced Rooms ('Area <= 0').
- Revit schedule filters are combined with AND. Do not add several Name filters expecting OR; that produces an empty schedule.
- For an exact combined schedule without editing linked Rooms, use view-specific Detail Item data carriers in a dedicated drafting view such as 'ZZ-DATA - ROOM SCHEDULE SOURCE'. Store source link/Room ID, Room Name, Area, Level, and a hidden group key.
- Create one schedule per requested group. Show Room Name, Area, and Level; sort/group by Level; enable Area totals in each level footer and the grand total. Refresh the carriers when linked Room data changes.
- Established electrical variants include 'ELEC. ROOM', 'ELEC.ROOM', 'ELEC.', 'ELEC', 'ELEC. RM.', 'GENERATOR ROOM', 'LV ROOM', and 'SS ROOM'.
- Established telecom/security variants include 'TEL.', 'TEL', 'GSM', 'SECURITY CONTROL', 'SECURITY CONTROL ROOM', 'MTR', and 'FCC'. Report requested names that are absent rather than inventing rows.
- When updating the project area workbook, put the full electrical-schedule level total under **Elec.** and the full telecom/security-schedule total under **Tel.** Preserve Gym, Canopy, Plot Coverage, formatting, and floors with no matching Rooms.
- Read back record counts, level totals, fields, filters, and grand totals after creation or refresh.

