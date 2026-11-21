-- The Team members Status ("Active"/"Blocked") the service last saw in Notion for this device.
-- A different value in Notion means the owner changed it there; NULL until the first sync.
ALTER TABLE devices ADD COLUMN notion_status TEXT;
