import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { MobileConfirmations, REMOTE_REQUEST_PREFIX, parseMobileAnswers } from '../dist/mobile-confirmation.js';
import { runCodexAppServer } from '../dist/codex-app-runner.js';

function relay(decide, delay = 0, questionAnswer = '个人版') {
  const tasks = [];
  return {
    tasks,
    async createTask(input) {
      const task = { ...input, id: 'task-' + tasks.length, status: 'awaiting_decision' };
      tasks.push(task);
      if (decide) setTimeout(() => {
        const request = JSON.parse(task.detail.slice(REMOTE_REQUEST_PREFIX.length));
        task.status = decide === 'approve' ? 'approved' : 'rejected';
        const questionId = request.questions?.[0]?.id ?? 'choice';
        task.decisionComment = request.kind === 'question' ? JSON.stringify({ answers: { [questionId]: { answers: [questionAnswer] } } }) : '手机确认';
      }, delay);
      return task;
    },
    async listTasks(status) { return tasks.filter((t) => t.status === status); },
    async submitDecision(id, action, comment) {
      const task = tasks.find((t) => t.id === id);
      if (task.status !== 'awaiting_decision') throw new Error('Already resolved');
      task.status = action === 'approve' ? 'approved' : 'rejected'; task.decisionComment = comment;
    },
  };
}

test('approval survives a competing consumer; status polling does not pull decisions', async () => {
  const api = relay('approve');
  const answer = await new MobileConfirmations(api, 'project', 5).request('确认', { kind: 'command', reason: '命令' }, new AbortController().signal, 500);
  assert.equal(answer.approved, true);
});

test('cancellation while publishing a request closes the newly created task', async () => {
  const api = relay();
  const controller = new AbortController();
  const original = api.createTask;
  api.createTask = async (input) => { const task = await original(input); controller.abort(); return task; };
  const answer = await new MobileConfirmations(api, 'project', 5).request('确认', { kind: 'command', reason: '命令' }, controller.signal, 500);
  assert.equal(answer.approved, false);
  assert.equal(api.tasks[0].status, 'rejected');
});

test('expired/offline request never approves and is dismissed', async () => {
  const api = relay();
  const answer = await new MobileConfirmations(api, 'project', 5).request('确认', { kind: 'confirmation', reason: '测试' }, new AbortController().signal, 35);
  assert.equal(answer.approved, false);
  assert.equal(api.tasks[0].status, 'rejected');
});

test('question answers require every original question and discard unrelated ids', () => {
  const questions = [{ id: 'a', question: '选择' }];
  assert.throws(() => parseMobileAnswers('{"answers":{}}', questions));
  assert.deepEqual(parseMobileAnswers(JSON.stringify({ answers: { a: { answers: ['个人版'] }, other: { answers: ['x'] } } }), questions), { a: { answers: ['个人版'] } });
});

for (const [mode, decision, expected] of [['command', 'approve', 'accept'], ['command', 'reject', 'decline'], ['files', 'approve', 'accept'], ['question', 'approve', '个人版'], ['mcp-approval', 'approve', 'Accept'], ['permissions', 'approve', '"scope":"turn"'], ['active', null, '正在执行任务'], ['disconnect', null, '[agent-error]']]) {
  test(`App Server transport: ${mode}/${decision ?? 'none'}`, async () => {
    const api = relay(decision, 80, mode === 'mcp-approval' ? 'Accept' : '个人版');
    const progress = [];
    const result = await runCodexAppServer({
      codex: process.execPath, appServerArgs: [fileURLToPath(new URL('./fixtures/app-server.mjs', import.meta.url)), mode],
      workspace: path.resolve('.'), prompt: '测试', model: 'test',
      resumeChatId: mode === 'active' ? 'test-thread' : undefined,
      idleTimeoutMs: 3000, maxTimeoutMs: 5000,
      confirmations: new MobileConfirmations(api, 'project', 5),
      onProgress: (v) => progress.push(v), kill: (child) => child.kill(),
    });
    assert.ok(result.text.includes(expected), result.text);
    if (decision) {
      assert.equal(api.tasks.length, 1);
      const req = JSON.parse(api.tasks[0].detail.slice(REMOTE_REQUEST_PREFIX.length));
      assert.equal(req.threadId, 'test-thread');
      assert.equal(req.turnId, 'test-turn');
      assert.ok(progress.some((p) => p.status === 'waiting_user'));
      if (mode === 'files') assert.deepEqual(req.paths, ['test.txt']);
      if (mode === 'mcp-approval') {
        assert.equal(req.kind, 'question');
        assert.equal(req.questions[0].options[0].label, 'Accept');
      }
    } else assert.equal(api.tasks.length, 0);
  });
}
