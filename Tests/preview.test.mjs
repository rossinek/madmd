import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { JSDOM } from 'jsdom';
import { build } from 'esbuild';

test('an optional diagram bundle failure preserves the successful Markdown preview', async () => {
  const result = await build({ entryPoints: ['Web/src/preview.js'], bundle: true,
    write: false, format: 'iife', target: 'safari17' });
  const dom = new JSDOM(await readFile('Web/src/index.html', 'utf8'), {
    url: 'madmd://bundle/index.html', runScripts: 'outside-only', pretendToBeVisual: true
  });
  try {
    const messages = [];
    dom.window.webkit = { messageHandlers: { madmd: { postMessage: message => messages.push(message) } } };
    dom.window.eval(result.outputFiles[0].text);
    await dom.window.madmd.load('# Still readable\n\n```mermaid\ngraph TD; A-->B;\n```', 'light', 'diagram-failure');
    dom.window.document.querySelector('script[src$="diagrams.js"]').dispatchEvent(new dom.window.Event('error'));
    await new Promise(resolve => setTimeout(resolve, 80));
    assert.equal(dom.window.document.querySelector('h1').textContent, 'Still readable');
    assert.match(dom.window.document.querySelector('.diagram pre').textContent, /A-->B/);
    assert.ok(messages.some(message => message.type === 'warning'));
    assert.ok(messages.some(message => message.type === 'rendered' && message.request === 'diagram-failure'));
    assert.ok(!messages.some(message => message.type === 'error'));
  } finally { dom.window.close(); }
});
