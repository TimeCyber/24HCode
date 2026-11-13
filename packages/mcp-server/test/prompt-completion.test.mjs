import assert from 'node:assert/strict';
import test from 'node:test';
import { ApiClient } from '../dist/api-client.js';

test('result delivery retries a dropped connection with the same status and result', async (t) => {
  const requests = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    requests.push({ url, body: options.body });
    if (requests.length === 1) throw new TypeError('fetch failed');
    return Response.json({ id: 'delivery', status: 'done', result: 'finished' });
  });
  const api = new ApiClient('http://relay.example', 'test-token');
  const result = await api.completePrompt('delivery', 'done', 'finished');
  assert.equal(result.status, 'done');
  assert.equal(requests.length, 2);
  assert.deepEqual(requests[0], requests[1]);
});

test('a missing delivery fails once', async (t) => {
  const fetchMock = t.mock.method(globalThis, 'fetch', async () =>
    Response.json({ error: 'not found' }, { status: 404 }),
  );
  const api = new ApiClient('http://relay.example', 'test-token');
  await assert.rejects(api.completePrompt('missing', 'done', 'finished'), /404/);
  assert.equal(fetchMock.mock.callCount(), 1);
});
