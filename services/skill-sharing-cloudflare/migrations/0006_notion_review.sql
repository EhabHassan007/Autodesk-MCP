-- One row per Notion "Skill review" page the service created: what that page is about, as the service saw it.
-- A decision typed in Notion is applied to THESE values, never to anything read back from the page.
CREATE TABLE notion_review (
  page_id TEXT PRIMARY KEY,
  pr INTEGER NOT NULL,
  skill TEXT NOT NULL,
  head_sha TEXT NOT NULL,
  content_key TEXT NOT NULL,
  approved_key TEXT NOT NULL,
  flagged INTEGER NOT NULL,
  at INTEGER NOT NULL,
  UNIQUE (pr, skill)
);

-- The last review sync, for the admin overview (same idea as notion_sync).
CREATE TABLE notion_review_sync (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  at INTEGER NOT NULL,
  summary TEXT NOT NULL
);
