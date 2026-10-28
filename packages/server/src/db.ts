import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

export type Db = DatabaseSync;

export function openDb(dbPath: string): Db {
  const dir = path.dirname(dbPath);
  fs.mkdirSync(dir, { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec(`
    PRAGMA journal_mode = WAL;

    CREATE TABLE IF NOT EXISTS projects (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      workspace_path TEXT NOT NULL,
      ide TEXT NOT NULL,
      last_seen_at TEXT NOT NULL,
      online INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE IF NOT EXISTS tasks (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      type TEXT NOT NULL,
      title TEXT NOT NULL,
      detail TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL,
      require_decision INTEGER NOT NULL DEFAULT 0,
      decision_comment TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS decisions (
      id TEXT PRIMARY KEY,
      task_id TEXT NOT NULL,
      project_id TEXT NOT NULL,
      action TEXT NOT NULL,
      comment TEXT,
      created_at TEXT NOT NULL,
      consumed INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS prompts (
      id TEXT PRIMARY KEY,
      content TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      result TEXT
    );

    CREATE TABLE IF NOT EXISTS prompt_deliveries (
      id TEXT PRIMARY KEY,
      prompt_id TEXT NOT NULL,
      project_id TEXT NOT NULL,
      content TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      result TEXT
    );

    CREATE TABLE IF NOT EXISTS session_contexts (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL UNIQUE,
      summary TEXT NOT NULL,
      current_step TEXT NOT NULL DEFAULT '',
      open_files TEXT NOT NULL DEFAULT '[]',
      status TEXT NOT NULL DEFAULT 'idle',
      extra TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS chat_sessions (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      title TEXT NOT NULL,
      cursor_chat_id TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS file_transfers (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      chat_session_id TEXT,
      file_name TEXT NOT NULL,
      mime_type TEXT,
      size INTEGER NOT NULL,
      storage_name TEXT NOT NULL,
      prompt_id TEXT,
      created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id);
    CREATE INDEX IF NOT EXISTS idx_decisions_project ON decisions(project_id, consumed);
    CREATE INDEX IF NOT EXISTS idx_prompt_deliveries_project ON prompt_deliveries(project_id, status);
    CREATE INDEX IF NOT EXISTS idx_session_contexts_project ON session_contexts(project_id);
    CREATE INDEX IF NOT EXISTS idx_chat_sessions_project ON chat_sessions(project_id, updated_at);
    CREATE INDEX IF NOT EXISTS idx_file_transfers_session ON file_transfers(chat_session_id, created_at);
  `);

  migrateColumn(db, "prompts", "chat_session_id", "TEXT");
  migrateColumn(db, "prompt_deliveries", "chat_session_id", "TEXT");
  migrateColumn(db, "prompts", "attachment_id", "TEXT");
  migrateColumn(db, "chat_sessions", "context_summary", "TEXT");
  migrateColumn(db, "chat_sessions", "context_step", "TEXT");
  migrateColumn(db, "chat_sessions", "context_status", "TEXT");
  migrateColumn(db, "chat_sessions", "context_extra", "TEXT");
  migrateColumn(db, "file_transfers", "direction", "TEXT");
  return db;
}

function migrateColumn(
  db: Db,
  table: string,
  column: string,
  type: string,
): void {
  const cols = db
    .prepare(`PRAGMA table_info(${table})`)
    .all() as Array<{ name: string }>;
  if (!cols.some((c) => c.name === column)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
  }
}
