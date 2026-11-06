import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { GuestProvider } from '../ios/guest/provider.mjs';

const decision = { route: 'guest' };

function setup() {
  const base = mkdtempSync(join(tmpdir(), 'dsh-ios-guest-policy-'));
  const workspace = join(base, 'workspace');
  const temporary = join(base, 'tmp');
  mkdirSync(workspace);
  mkdirSync(temporary);
  const requests = [];
  const channel = {
    exec(request) {
      requests.push(request);
      return { finished: Promise.resolve({ exitCode: 0, signal: null, resourcesSettled: true }), signal() {}, abandon() {} };
    },
    dispose() {},
  };
  const provider = new GuestProvider({ channel, temporaryRoot: temporary, forbiddenRoots: [join(base, 'state')] });
  return { base, workspace, requests, provider };
}

async function execute(provider, workspace, mode) {
  const stderr = [];
  const result = await provider.execute({
    decision,
    argv: ['bash', '-c', 'uname -a'],
    policy: { mode, workspaceRoot: workspace },
    cwd: workspace,
    env: {},
    stdin: Buffer.alloc(0),
    graceMs: 1000,
    output: async (stream, data) => { if (stream === 'stderr') stderr.push(data.toString()); },
  });
  return { result, stderr };
}

test('full access runs the guest at workspace scope instead of refusing it', async () => {
  const { base, workspace, requests, provider } = setup();
  try {
    for (const mode of ['read-only', 'workspace-write', 'danger-full-access']) {
      requests.length = 0;
      const { result } = await execute(provider, workspace, mode);
      assert.equal(result.exitCode, 0, mode);
      assert.equal(requests.length, 1, mode);
      const expected = mode === 'read-only' ? 'read-only' : 'workspace-write';
      assert.equal(requests[0].mode, expected, mode);
      assert.deepEqual(requests[0].argv, ['/bin/sh', '-c', 'uname -a']);
      for (const mount of requests[0].mounts) assert.equal(mount.readOnly, mode === 'read-only', mode);
    }
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
});

test('an unknown policy mode still needs a confined ticket', async () => {
  const { base, workspace, requests, provider } = setup();
  try {
    const { result, stderr } = await execute(provider, workspace, 'administrator');
    assert.equal(result.exitCode, 126);
    assert.match(stderr.join(''), /IOS_GUEST_POLICY_REQUIRED/);
    assert.equal(requests.length, 0);
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
});
