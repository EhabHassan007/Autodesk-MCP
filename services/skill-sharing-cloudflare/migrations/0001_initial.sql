CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  hash TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE rate (
  device TEXT PRIMARY KEY REFERENCES devices(id),
  hour INTEGER NOT NULL,
  count INTEGER NOT NULL
);
CREATE TABLE batches (
  digest TEXT PRIMARY KEY,
  url TEXT,
  lease_owner TEXT,
  lease_until INTEGER NOT NULL DEFAULT 0
);
