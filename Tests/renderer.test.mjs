import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { createRenderer } from '../Web/src/renderer.js';
import { createSanitizer } from '../Web/src/sanitize.js';

const md = createRenderer();
const window = new JSDOM('').window;
const sanitize = createSanitizer(window);
function render(source) { return new JSDOM(sanitize(md.render(source))).window.document; }

test('GFM tables, tasks, strikethrough and automatic links', () => {
  const doc = render('| left | right |\n|---|---:|\n| A | B |\n\n- [x] Done\n- [ ] Pending\n\n~~deleted~~ https://example.com');
  assert.equal(doc.querySelectorAll('table tbody tr').length, 1);
  assert.equal(doc.querySelectorAll('input[type=checkbox]').length, 2);
  assert.equal(doc.querySelector('input').checked, true);
  assert.equal(doc.querySelector('s').textContent, 'deleted');
  assert.equal(doc.querySelector('a').href, 'https://example.com/');
});
test('HTML details, picture, sized images, footnotes, emoji and duplicate anchors', () => {
  const doc = render('# Hello\n# Hello\n\n<details><summary>More</summary>Details</details>\n\n<picture><source media="(prefers-color-scheme: dark)" srcset="dark.png"><img src="image.png" width="42"></picture>\n\nFootnote[^a] :rocket:\n\n[^a]: Description');
  assert.equal(doc.querySelectorAll('details summary').length, 1);
  assert.equal(doc.querySelector('img').getAttribute('width'), '42');
  assert.equal(doc.querySelectorAll('h1[id]').length, 2);
  assert.notEqual(...[...doc.querySelectorAll('h1')].map(el => el.id));
  assert.match(doc.body.textContent, /🚀/);
  assert.equal(doc.querySelectorAll('.footnotes-list li').length, 1);
});
test('all five GitHub alert kinds', () => {
  for (const kind of ['NOTE', 'TIP', 'IMPORTANT', 'WARNING', 'CAUTION']) {
    const doc = render(`> [!${kind}]\n> Keep **this**.`);
    assert.equal(doc.querySelector(`.markdown-alert-${kind.toLowerCase()} strong`).textContent, 'this');
  }
});
test('math inline, display and math fences', () => {
  const doc = render('$x^2$\n\n$$\n\\sum_{n=1}^3 n\n$$\n\n```math\nx=2\n```\n\n$`x < y`$');
  assert.equal(doc.querySelectorAll('.katex').length, 4);
  assert.equal(doc.querySelectorAll('.katex-error').length, 0);
});
test('syntax highlighting and unrecognized language fallback', () => {
  assert.ok(render('```swift\nlet a = "hi"\n```').querySelector('.hljs-keyword'));
  assert.equal(render('```unknown\n<script>bad</script>\n```').querySelector('script'), null);
});
test('diagram sources survive sanitization without becoming executable HTML', () => {
  for (const kind of ['mermaid', 'geojson', 'topojson', 'stl']) {
    const doc = render('```' + kind + '\n<img src=x onerror=alert(1)>\n```');
    assert.equal(doc.querySelector('.diagram').dataset.kind, kind);
    assert.match(decodeURIComponent(doc.querySelector('.diagram').dataset.source), /<img/);
    assert.equal(doc.querySelector('img'), null);
  }
});
test('Mermaid arrows survive XML attribute sanitization', () => {
  const doc = render('```mermaid\ngraph TD; A-->B;\n```');
  assert.equal(decodeURIComponent(doc.querySelector('.diagram').dataset.source), 'graph TD; A-->B;\n');
});
test('KaTeX layout styles survive, arbitrary HTML styles do not', () => {
  const doc = render('$x^2$\n\n<p style="position:fixed;inset:0">text</p>');
  assert.ok(doc.querySelector('.katex [style]'));
  assert.equal(doc.querySelector('p[style]'), null);
});
test('hostile HTML, dangerous links and event handlers are removed', () => {
  const doc = render('<script>alert(1)</script><iframe src="https://evil.test"></iframe><img src="x" onerror="alert(1)"><a href="javascript:alert(1)">bad</a><svg onload="alert(1)"><circle/></svg>');
  assert.equal(doc.querySelector('script,iframe,[onerror],[onload],[href^="javascript:"]'), null);
});
test('relative, remote and private-scheme images remain available', () => {
  const doc = render('![a](images/photo.png)\n![b](https://example.com/photo.png)\n<img src="madmd://document/images/local.png">');
  assert.equal(doc.querySelectorAll('img[src]').length, 3);
});
test('large ordinary document rendering remains bounded', () => {
  const source = ('## Heading\n\nA paragraph with **bold** and `code`.\n\n').repeat(5000);
  const start = performance.now(); const html = md.render(source);
  assert.ok(html.length > source.length);
  assert.ok(performance.now() - start < 3000);
});
