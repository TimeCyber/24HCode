import readline from 'node:readline';
const mode = process.argv[2] || 'command';
const send = (v) => process.stdout.write(JSON.stringify(v) + '\n');
const threadId = 'test-thread';
const turnId = 'test-turn';
const events = (method, params) => send({ method, params: { threadId, turnId, ...params } });
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const m = JSON.parse(line);
  if (m.method === 'initialize') send({ id: m.id, result: {} });
  if (m.method === 'thread/start' || m.method === 'thread/resume') {
    if (m.params.approvalsReviewer !== 'user' || m.params.sandbox !== 'workspace-write') process.exit(12);
    send({ id: m.id, result: { thread: { id: threadId, status: { type: mode === 'active' ? 'active' : 'idle' } } } });
  }
  if (m.method === 'turn/start') {
    send({ id: m.id, result: { turn: { id: turnId } } });
    events('turn/started', { turn: { id: turnId } });
    if (mode === 'disconnect') { process.exit(4); return; }
    const isQuestion = mode === 'question' || mode === 'mcp-approval';
    events('item/started', { item: { id: 'item', type: mode === 'files' ? 'fileChange' : mode === 'mcp-approval' ? 'mcpToolCall' : 'commandExecution', command: 'echo hello', changes: [{ path: 'test.txt' }] } });
    send({ id: 800, method: mode === 'mcp-approval' ? 'tool/requestUserInput' : mode === 'question' ? 'item/tool/requestUserInput' : mode === 'permissions' ? 'item/permissions/requestApproval' : mode === 'files' ? 'item/fileChange/requestApproval' : 'item/commandExecution/requestApproval',
      params: { threadId, turnId, itemId: 'item', command: 'echo hello', reason: '测试确认',
        ...(isQuestion ? { questions: [{ id: mode === 'mcp-approval' ? 'approval' : 'choice', question: mode === 'mcp-approval' ? '允许调用 send_file_to_client 吗？' : '选择版本', options: mode === 'mcp-approval' ? [{ label: 'Accept' }, { label: 'Decline' }, { label: 'Cancel' }] : [{ label: '个人版' }] }] } : {}),
        ...(mode === 'permissions' ? { permissions: { network: { enabled: true }, fileSystem: null } } : {}) } });
  }
  if (m.id === 800 && !m.method) {
    const answer = mode === 'question' ? m.result?.answers?.choice?.answers?.[0] : mode === 'mcp-approval' ? m.result?.answers?.approval?.answers?.[0] : mode === 'permissions' ? JSON.stringify(m.result) : m.result?.decision;
    events('serverRequest/resolved', { requestId: 800 });
    events('item/completed', { item: { id: 'reply', type: 'agentMessage', text: '收到：' + answer } });
    events('turn/completed', { turn: { id: turnId, status: 'completed' } });
  }
});
