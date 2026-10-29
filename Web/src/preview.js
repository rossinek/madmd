import { createSanitizer } from './sanitize.js';
import { createRenderer } from './renderer.js';

const md = createRenderer();
const preview = document.getElementById('preview');
let source = '', mode = 'preview', theme = 'light', revision = 0, requestID = '';
let editorPromise, diagramPromise;
let sourceNavigation = false;
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
// Native code knows why local media is missing; it answers through window.madmd.explainMedia.
const failures = { 403: 'No permission to read', 404: 'Not found', 413: 'Too large' };
let placeholders = 0;
function placeholder(element, url) {
  const label = document.createElement('span'); label.className = 'media-placeholder'; label.dataset.id = String(++placeholders);
  label.dataset.kind = { IMG: 'Image', VIDEO: 'Video', AUDIO: 'Audio' }[element.tagName];
  let name = url ?? '';
  try { name = decodeURIComponent(new URL(url).pathname.split('/').filter(Boolean).pop() ?? name); } catch {}
  label.title = name; label.dataset.name = name;
  const alt = element.getAttribute('alt')?.trim();
  if (alt) { const caption = document.createElement('span'); caption.className = 'media-placeholder-alt'; caption.textContent = alt; label.append(caption); }
  label.append(Object.assign(document.createElement('span'), { className: 'media-placeholder-reason' }));
  explain(label, `${label.dataset.kind} unavailable`);
  element.hidden = true; element.after(label);
  if (url?.startsWith('madmd://document/')) post('mediaError', { id: label.dataset.id, src: url });
}
function explain(label, reason, allow = false) {
  const line = label.querySelector('.media-placeholder-reason');
  line.textContent = `${reason}: ${label.dataset.name}`; label.dataset.reason = reason;
  if (!allow) return;
  // A placeholder can sit inside a link, so the button keeps its click to itself.
  const button = Object.assign(document.createElement('button'), { type: 'button', className: 'media-placeholder-allow', textContent: 'Allow Access…' });
  button.addEventListener('click', event => { event.preventDefault(); event.stopPropagation(); post('allowMedia'); });
  line.append(' · ', button);
}
// A player with <source> children reports failure on the last source, after the earlier ones failed.
function watchMedia(media) {
  const last = [...media.querySelectorAll('source')].pop();
  if (media.getAttribute('src') || !last) media.addEventListener('error', () => placeholder(media, media.currentSrc || media.src), { once: true });
  else last.addEventListener('error', () => placeholder(media, last.src), { once: true });
}
function paint(force = false) {
  if (!force && paintedSource === source && paintedTheme === theme) return;
  paintedSource = source; paintedTheme = theme;
  const start = performance.now(), current = ++revision, request = requestID;
  window.madmdDisposeDiagrams?.();
  preview.innerHTML = sanitize(md.render(source));
  preview.querySelectorAll('img').forEach(img => { img.loading = 'lazy'; img.decoding = 'async'; img.addEventListener('error', () => placeholder(img, img.src), { once: true }); });
  preview.querySelectorAll('video, audio').forEach(watchMedia);
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
  async load(text, appearance = 'light', request = '', baseURL, canNavigate = false) {
    sourceNavigation = canNavigate;
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
  async revealSource(offset) {
    await this.setMode('edit');
    window.madmdEditor?.revealOffset(offset);
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
  explainMedia(id, status, allow = false) {
    const label = preview.querySelector(`.media-placeholder[data-id="${id}"]`); if (!label) return;
    if (failures[status]) explain(label, failures[status], allow && status === 403);
    else if (status === 415) explain(label, label.dataset.kind === 'Image' ? 'Not an image' : 'Not a media file');
  },
  // Used by the native integration checks against the real WebKit runtime.
  inspect() { return { mode, theme, text: this.getValue(), editorLoaded: !!window.madmdEditor,
    headings: preview.querySelectorAll('h1,h2,h3').length, tables: preview.querySelectorAll('table').length,
    highlighted: preview.querySelectorAll('.hljs-keyword,.hljs-string').length,
    math: preview.querySelectorAll('.katex').length, html: preview.innerHTML }; }
};
function updateCommand(event) {
  preview.classList.toggle('source-navigation', sourceNavigation && mode === 'preview' && event.metaKey);
}
document.addEventListener('keydown', updateCommand);
document.addEventListener('keyup', updateCommand);
document.addEventListener('mousemove', updateCommand);
window.addEventListener('blur', () => preview.classList.remove('source-navigation'));
preview.addEventListener('click', event => {
  if (!sourceNavigation || !event.metaKey || mode !== 'preview') return;
  const block = event.target.closest('[data-source-start]');
  if (!block) return;
  event.preventDefault(); event.stopImmediatePropagation();
  const starts = [0];
  for (const match of source.matchAll(/\r\n|\n|\r/g)) starts.push(match.index + match[0].length);
  const start = starts[Number(block.dataset.sourceStart)] ?? 0;
  const end = starts[Number(block.dataset.sourceEnd)] ?? source.length;
  let offset = start;
  const caret = document.caretRangeFromPoint?.(event.clientX, event.clientY);
  const node = caret?.startContainer;
  if (node?.nodeType === Node.TEXT_NODE && block.contains(node)) {
    const text = node.textContent, fragment = source.slice(start, end);
    const index = text.trim() ? fragment.indexOf(text) : -1;
    if (index >= 0 && fragment.indexOf(text, index + 1) < 0) offset += index + caret.startOffset;
  }
  preview.classList.remove('source-navigation');
  post('editSource', { offset });
}, true);
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
