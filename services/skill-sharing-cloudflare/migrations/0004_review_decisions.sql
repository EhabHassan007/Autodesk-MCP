CREATE TABLE review_decisions (
  pr INTEGER NOT NULL,
  skill TEXT NOT NULL,
  head_sha TEXT NOT NULL,
  content_key TEXT NOT NULL,
  decision TEXT NOT NULL,
  category TEXT,
  commit_sha TEXT,
  at INTEGER NOT NULL,
  PRIMARY KEY (pr, skill)
);
CREATE INDEX review_decisions_content ON review_decisions(skill, content_key);
