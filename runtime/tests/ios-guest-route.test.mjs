import test from 'node:test';
import assert from 'node:assert/strict';
import { decideRoute } from '../ios/guest/route.mjs';

test('an installed guest becomes the default shell for ordinary scripts', () => {
  assert.equal(decideRoute({}), 'guest');
  assert.equal(decideRoute({ missing: 3 }), 'guest');
  assert.equal(decideRoute({ unresolvedCommand: true }), 'guest');
});

test('the Node worker keeps its virtual shell and mixed scripts stay unsupported', () => {
  assert.equal(decideRoute({ node: true }), 'virtual');
  assert.equal(decideRoute({ node: true, missing: 1 }), 'unsupported');
  assert.equal(decideRoute({ node: true, unresolvedCommand: true }), 'unsupported');
});
