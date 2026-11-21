-- New PCs wait for the owner's approval (Team members → Status in Notion, or the dashboard).
ALTER TABLE devices ADD COLUMN pending INTEGER NOT NULL DEFAULT 0;
-- When the owner was @mentioned in Notion about this PC joining; NULL until the comment is posted.
ALTER TABLE devices ADD COLUMN notified_at INTEGER;
