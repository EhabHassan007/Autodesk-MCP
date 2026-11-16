-- Connector error reports (POST /v1/failures). One row per distinct error, keyed by a fingerprint of the product, tool,
-- error code and cleaned message, with counts per device, day and connector version. Never arguments, drawings or models.
CREATE TABLE failures (
  fingerprint TEXT PRIMARY KEY,
  product TEXT NOT NULL,
  tool TEXT NOT NULL,
  code TEXT NOT NULL,
  message TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE failure_counts (
  fingerprint TEXT NOT NULL REFERENCES failures(fingerprint),
  device TEXT NOT NULL REFERENCES devices(id),
  day TEXT NOT NULL,
  version TEXT NOT NULL,
  failed INTEGER NOT NULL DEFAULT 0,
  recovered INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (fingerprint, device, day, version)
);
CREATE INDEX failure_counts_day ON failure_counts(day);
CREATE TABLE notion_failure_sync (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  at INTEGER NOT NULL,
  summary TEXT NOT NULL
);
