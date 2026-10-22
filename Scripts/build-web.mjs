import { build } from 'esbuild';
import { mkdir, cp, writeFile, readFile, rm, readdir } from 'node:fs/promises';
const out = 'Web/dist';
const packagePaths = new Set(['node_modules/github-markdown-css', 'node_modules/katex', 'node_modules/leaflet']);
await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });
for (const entry of ['preview', 'editor', 'diagrams']) {
  const result = await build({ entryPoints: [`Web/src/${entry}.js`], bundle: true, minify: true, metafile: true,
    format: 'iife', target: 'safari17', outfile: `${out}/${entry}.js`,
    loader: { '.ttf': 'file', '.woff': 'file', '.woff2': 'file', '.svg': 'file' },
    assetNames: 'assets/[name]-[hash]', legalComments: 'linked' });
  for (const input of Object.keys(result.metafile.inputs)) {
    const packagePath = input.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)/)?.[1];
    if (packagePath) packagePaths.add(packagePath);
  }
}
await build({ entryPoints: ['monaco-editor/esm/vs/editor/editor.worker.js'], bundle: true,
  minify: true, format: 'iife', target: 'safari17', outfile: `${out}/editor.worker.js` });
await cp('node_modules/katex/dist/fonts', `${out}/fonts`, { recursive: true });
await cp('Web/src/index.html', `${out}/index.html`);
const light = (await readFile('node_modules/github-markdown-css/github-markdown-light.css', 'utf8')).replaceAll('.markdown-body', ':root[data-theme="light"] .markdown-body');
const dark = (await readFile('node_modules/github-markdown-css/github-markdown-dark.css', 'utf8')).replaceAll('.markdown-body', ':root[data-theme="dark"] .markdown-body');
const css = await Promise.all([
  'node_modules/katex/dist/katex.min.css', 'node_modules/leaflet/dist/leaflet.css',
  'Web/src/style.css'].map(p => readFile(p, 'utf8')));
await writeFile(`${out}/style.css`, [light, dark, ...css].join('\n'));
const notices = [];
for (const path of [...packagePaths].sort()) {
  const pkg = JSON.parse(await readFile(`${path}/package.json`, 'utf8'));
  const files = (await readdir(path)).filter(name => /^(?:licen[cs]e|copying|thirdpartynotices)(?:[._-]|$)/i.test(name));
  const text = await Promise.all(files.map(name => readFile(`${path}/${name}`, 'utf8').catch(() => '')));
  notices.push(`${pkg.name} ${pkg.version}\nLicense: ${pkg.license ?? 'See notices'}\n${text.join('\n')}`);
}
await writeFile(`${out}/THIRD_PARTY_NOTICES.txt`, notices.join('\n\n' + '='.repeat(72) + '\n\n'));
// The extension ships only the preview runtime. Monaco never enters its bundle.
const quickLook = 'Web/quicklook/dist';
await rm('Web/quicklook', { recursive: true, force: true });
await mkdir(quickLook, { recursive: true });
for (const name of ['index.html', 'preview.js', 'preview.js.LEGAL.txt', 'diagrams.js', 'diagrams.js.LEGAL.txt', 'style.css', 'fonts', 'THIRD_PARTY_NOTICES.txt']) {
  await cp(`${out}/${name}`, `${quickLook}/${name}`, { recursive: true });
}
