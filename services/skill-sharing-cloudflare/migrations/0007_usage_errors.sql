-- How many of the counted calls failed. A count only: never the error text, which can name projects.
-- Clients before this version send no errors, so their rows keep 0.
ALTER TABLE usage ADD COLUMN errors INTEGER NOT NULL DEFAULT 0;
