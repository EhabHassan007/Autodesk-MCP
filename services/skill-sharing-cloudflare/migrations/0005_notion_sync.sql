CREATE TABLE notion_sync (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  at INTEGER NOT NULL,
  summary TEXT NOT NULL
);
