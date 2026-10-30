ALTER TABLE devices ADD COLUMN source TEXT NOT NULL DEFAULT 'admin';
ALTER TABLE devices ADD COLUMN person_name TEXT;
ALTER TABLE devices ADD COLUMN email TEXT;
ALTER TABLE devices ADD COLUMN pc_name TEXT;
ALTER TABLE devices ADD COLUMN windows_user TEXT;
ALTER TABLE devices ADD COLUMN connector_version TEXT;
ALTER TABLE devices ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN enroll_ip TEXT;
ALTER TABLE devices ADD COLUMN last_seen INTEGER NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN last_ip TEXT;
CREATE TABLE usage (
  device TEXT NOT NULL REFERENCES devices(id),
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  day TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (device, kind, name, day)
);
CREATE INDEX usage_day ON usage(day);
CREATE TABLE submission_log (
  device TEXT NOT NULL REFERENCES devices(id),
  digest TEXT NOT NULL,
  at INTEGER NOT NULL,
  skills TEXT NOT NULL,
  status TEXT NOT NULL
);
CREATE INDEX submission_log_device ON submission_log(device, at);
CREATE TABLE limits (
  key TEXT PRIMARY KEY,
  hour INTEGER NOT NULL,
  count INTEGER NOT NULL
);
