import { createSanitizer } from './sanitize.js';
import { createRenderer } from './renderer.js';

const md = createRenderer();
const preview = document.getElementById('preview');
let source = '', mode = 'preview', theme = 'light', revision = 0, requestID = '';
let editorPromise, diagramPromise;
let paintedSource, paintedTheme;
const post = (type, data = {}) => window.webkit?.messageHandlers?.madmd?.postMessage({ type, ...data });
const script = name => new Promise((resolve, reject) => {
  if (name === 'editor') {
    const css = document.createElement('link'); css.rel = 'stylesheet'; css.href = 'madmd://bundle/editor.css'; document.head.append(css);
  }
  const el = document.createElement('script');
  el.src = `madmd://bundle/${name}.js`; el.onload = resolve; el.onerror = reject; document.head.append(el);
});

const sanitize = createSanitizer(window);
function paint(force = false) {
  if (!force && paintedSource === source && paintedTheme === theme) return;
  paintedSource = source; paintedTheme = theme;
  const start = performance.now(), current = ++revision, request = requestID;
  window.madmdDisposeDiagrams?.();
  preview.innerHTML = sanitize(md.render(source));
  preview.querySelectorAll('img').forEach(img => { img.loading = 'lazy'; img.decoding = 'async'; });
  preview.querySelectorAll('input').forEach(el => { el.disabled = true; if (el.type !== 'checkbox') el.remove(); });
  preview.querySelectorAll('a').forEach(a => a.rel = 'noopener noreferrer');
  const nodes = [...preview.querySelectorAll('.diagram')];
  if (nodes.length) {
    diagramPromise ??= script('diagrams');
    diagramPromise.then(async () => {
      if (current !== revision) return;
      await window.madmdDiagrams(nodes, theme, () => current === revision);
    }).catch(error => post('warning', { message: String(error) }));
  }
  let delivered = false;
  const complete = () => {
    if (delivered || current !== revision) return;
    delivered = true;
    post('rendered', { request, revision: current, milliseconds: performance.now() - start });
  };
  requestAnimationFrame(() => requestAnimationFrame(complete));
  // Quick Look can prepare an offscreen view, where animation frames are paused.
  setTimeout(complete, 50);
}
window.madmd = {
  async load(text, appearance = 'light', request = '', baseURL) {
    if (baseURL) document.querySelector('base').href = baseURL;
    source = text; requestID = request; theme = appearance; document.documentElement.dataset.theme = theme;
    window.madmdEditor?.setTheme(theme);
    if (window.madmdEditor) window.madmdEditor.setValue(text);
    paint(true);
  },
  async setMode(next) {
    mode = next;
    if (next === 'edit') {
      try {
        editorPromise ??= script('editor'); await editorPromise;
        if (!window.madmdEditor) await window.createMadmdEditor(source, theme, value => { source = value; post('changed', { text: value }); });
        if (mode !== 'edit') return;
        preview.hidden = true; document.getElementById('editor').hidden = false;
        window.madmdEditor.layout(); window.madmdEditor.focus();
        post('editorReady');
      } catch (error) { post('error', { message: String(error) }); }
    } else {
      document.getElementById('editor').hidden = true; preview.hidden = false; paint();
    }
  },
  setTheme(next) {
    theme = next; document.documentElement.dataset.theme = next;
    window.madmdEditor?.setTheme(next);
    if (preview.querySelector('.diagram') && source) paint();
  },
  getValue() { return window.madmdEditor?.getValue() ?? source; },
  action(id) { window.madmdEditor?.action(id); },
  markSaved() { window.madmdEditor?.markSaved(); },
  setBaseURL(url) { document.querySelector('base').href = url; paintedSource = undefined; },
  // Used by the native integration checks against the real WebKit runtime.
  inspect() { return { mode, theme, text: this.getValue(), editorLoaded: !!window.madmdEditor,
    headings: preview.querySelectorAll('h1,h2,h3').length, tables: preview.querySelectorAll('table').length,
    highlighted: preview.querySelectorAll('.hljs-keyword,.hljs-string').length,
    math: preview.querySelectorAll('.katex').length, html: preview.innerHTML }; }
};
document.addEventListener('click', event => {
  const a = event.target.closest('a'); if (!a) return;
  event.preventDefault();
  const href = a.getAttribute('href');
  if (href?.startsWith('#')) { document.getElementById(decodeURIComponent(href.slice(1)))?.scrollIntoView(); return; }
  post('link', { href: a.href });
});
document.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') { event.preventDefault(); post('save'); }
});
post('ready');
