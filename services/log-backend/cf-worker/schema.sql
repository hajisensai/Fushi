CREATE TABLE IF NOT EXISTS logs (
  id      TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  created TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_logs_id_desc ON logs (id DESC);
