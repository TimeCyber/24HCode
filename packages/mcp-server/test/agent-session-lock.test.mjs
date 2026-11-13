import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';

test('a stale malformed lock can be replaced and released', async (t) => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'codeassist-lock-test-'));
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  const locks = path.join(temp, 'codeassist-agent-locks');
  const name = createHash('sha256').update('project:chat').digest('hex');
  const lockPath = path.join(locks, `${name}.lock`);
  await fs.mkdir(locks);
  await fs.writeFile(lockPath, '{"pid":');
  const old = new Date(Date.now() - 60_000);
  await fs.utimes(lockPath, old, old);

  const entry = new URL('../dist/live-pull.js', import.meta.url).href;
  // Bound the child process so a regression in the lock loop fails this test.
  const { stdout } = await promisify(execFile)(process.execPath, [
    '--input-type=module', '-e', `
      import { acquireAgentSessionLock } from ${JSON.stringify(entry)};
      import assert from 'node:assert/strict';
      import fs from 'node:fs';
      const lock = await acquireAgentSessionLock('project', 'chat');
      lock.setAgentPid(process.pid);
      const owner = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
      await assert.rejects(
        acquireAgentSessionLock('project', 'chat', { waitMs: 80 }),
        /执行锁超时/,
      );
      assert.equal(JSON.parse(fs.readFileSync(process.argv[1], 'utf8')).token, owner.token);
      lock.release();
      console.log(owner.pid === process.pid && owner.agentPid === process.pid);
    `, lockPath,
  ], { env: { ...process.env, TEMP: temp, TMP: temp, TMPDIR: temp }, timeout: 5_000 });
  assert.equal(stdout.trim(), 'true');
  await assert.rejects(fs.stat(lockPath), { code: 'ENOENT' });
});

test('the queue serializes consumers and takes the next delivery after completion', async (t) => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'codeassist-queue-test-'));
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  const locks = path.join(temp, 'codeassist-agent-locks');
  const name = createHash('sha256').update('project:__prompt_queue__').digest('hex');
  const lockPath = path.join(locks, `${name}.lock`);
  await fs.mkdir(locks);
  await fs.writeFile(lockPath, '{"pid":');
  const old = new Date(Date.now() - 60_000);
  await fs.utimes(lockPath, old, old);

  await fs.writeFile(path.join(temp, 'app-server'), `
    require('node:readline').createInterface({ input: process.stdin }).on('line', (line) => {
      const request = JSON.parse(line);
      const send = (message) => console.log(JSON.stringify(message));
      const reply = (result) => send({ id: request.id, result });
      if (request.method === 'initialize') reply({});
      if (request.method === 'thread/start') reply({ thread: { id: 'test-thread' } });
      if (request.method === 'turn/start') {
        const prompt = request.params.input[0].text;
        const match = prompt.match(/DeliveryIds: (delivery-[12])/);
        if (!match) process.exit(2);
        const deliveryId = match[1];
        reply({ turn: { id: deliveryId } });
        send({ method: 'item/completed', params: { threadId: 'test-thread', turnId: deliveryId, item: { id: 'reply', type: 'agentMessage', text: deliveryId + ' 执行完成' } } });
        send({ method: 'turn/completed', params: { threadId: 'test-thread', turn: { id: deliveryId, status: 'completed' } } });
      }
    });
  `);

  const entry = new URL('../dist/live-pull.js', import.meta.url).href;
  const { stdout } = await promisify(execFile)(process.execPath, [
    '--input-type=module', '-e', `
      import { startLivePull } from ${JSON.stringify(entry)};
      // Suppress Windows desktop toasts while running the simulated delivery.
      Object.defineProperty(process, 'platform', { value: 'linux' });
      const pending = [
        { id: 'delivery-1', chatSessionId: 'chat', content: '第一条', projectId: 'project' },
        { id: 'delivery-2', chatSessionId: 'chat', content: '第二条', projectId: 'project' },
      ];
      const claims = [];
      const acknowledged = [];
      const completed = [];
      let active;
      let stopFirst;
      let stopSecond;
      const api = {
        async pullPrompts() {
          const observedIdle = active == null;
          if (!observedIdle) return [];
          // Let concurrent consumers overlap the old check-then-claim window.
          await new Promise((resolve) => setTimeout(resolve, 50));
          if (!observedIdle) return [];
          const next = pending.shift();
          if (!next) return [];
          active = next.id;
          claims.push({ id: next.id, completedBeforeClaim: completed.length });
          return [next];
        },
        async claimOpenWorkspace() { return []; },
        async ackPrompt(id) { active = id; acknowledged.push(id); },
        async syncSessionContext() {},
        async getChatSession() { return {}; },
        async updateChatSession() {},
        async createTask() {},
        async completePrompt(id, status, result) {
          completed.push({ id, status, result });
          if (active === id) active = undefined;
          if (completed.length === 2) {
            console.log(JSON.stringify({ claims, acknowledged, completed }));
            stopFirst();
            stopSecond();
          }
        },
      };
      const options = {
        serverUrl: 'http://127.0.0.1:1', token: 'test', ide: 'codex',
        getProjectId: () => 'project', getWorkspace: () => process.cwd(), onPrompts() {},
      };
      stopFirst = startLivePull(api, options);
      stopSecond = startLivePull(api, options);
    `,
  ], {
    cwd: temp,
    env: { ...process.env, TEMP: temp, TMP: temp, TMPDIR: temp, CODEASSIST_CODEX_CMD: process.execPath, CODEASSIST_POLL_MS: '1000' },
    timeout: 8_000,
  });
  const result = JSON.parse(stdout);
  assert.deepEqual(result.claims, [
    { id: 'delivery-1', completedBeforeClaim: 0 },
    { id: 'delivery-2', completedBeforeClaim: 1 },
  ]);
  assert.deepEqual([...new Set(result.acknowledged)], ['delivery-1', 'delivery-2']);
  assert.deepEqual(result.completed.map(({ id, status }) => ({ id, status })), [
    { id: 'delivery-1', status: 'done' },
    { id: 'delivery-2', status: 'done' },
  ]);
  await assert.rejects(fs.stat(lockPath), { code: 'ENOENT' });
});
