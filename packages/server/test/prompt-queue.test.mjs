import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { openDb } from "../dist/db.js";
import { Store } from "../dist/store.js";

async function createStore(t) {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), "codeassist-prompt-queue-"));
  const db = openDb(path.join(temp, "queue.sqlite"));
  const store = new Store(db);
  const project = store.registerProject({
    name: "Queue test",
    workspacePath: temp,
    ide: "codex",
  });
  t.after(async () => {
    db.close();
    await fs.rm(temp, { recursive: true, force: true });
  });
  return { db, store, project };
}

test("a queued delivery starts after the running delivery completes", async (t) => {
  const { store, project } = await createStore(t);
  const first = store.createPrompt({
    content: "first",
    projectId: project.id,
  }).deliveries[0];
  const second = store.createPrompt({
    content: "second",
    projectId: project.id,
  }).deliveries[0];

  assert.deepEqual(store.pullPrompts(project.id).map((delivery) => delivery.id), [
    first.id,
  ]);
  assert.deepEqual(store.pullPrompts(project.id), []);
  store.ackPrompt(first.id);
  store.completePrompt(first.id, "done", "first complete");

  assert.deepEqual(store.pullPrompts(project.id).map((delivery) => delivery.id), [
    second.id,
  ]);
});

test("an abandoned delivered item is requeued behind the active item", async (t) => {
  const { db, store, project } = await createStore(t);
  const first = store.createPrompt({
    content: "first",
    projectId: project.id,
  }).deliveries[0];
  const second = store.createPrompt({
    content: "second",
    projectId: project.id,
  }).deliveries[0];

  store.pullPrompts(project.id);
  store.ackPrompt(first.id);

  const expired = new Date(Date.now() - 120_000).toISOString();
  db.prepare(
    "UPDATE prompt_deliveries SET status = 'delivered', updated_at = ? WHERE id = ?",
  ).run(expired, second.id);
  db.prepare(
    "UPDATE prompts SET status = 'delivered', updated_at = ? WHERE id = ?",
  ).run(expired, second.promptId);

  assert.deepEqual(store.pullPrompts(project.id), []);
  assert.equal(store.getDelivery(second.id)?.status, "queued");

  store.completePrompt(first.id, "done", "first complete");
  const next = store.pullPrompts(project.id);
  assert.deepEqual(next.map((delivery) => delivery.id), [second.id]);
  assert.equal(next[0].status, "delivered");
});
