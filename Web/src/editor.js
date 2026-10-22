import * as monaco from 'monaco-editor/esm/vs/editor/editor.api.js';
import 'monaco-editor/esm/vs/basic-languages/markdown/markdown.contribution.js';
import 'monaco-editor/esm/vs/editor/contrib/find/browser/findController.js';
import 'monaco-editor/esm/vs/editor/contrib/multicursor/browser/multicursor.js';
import 'monaco-editor/esm/vs/editor/contrib/wordOperations/browser/wordOperations.js';
import 'monaco-editor/esm/vs/editor/contrib/linesOperations/browser/linesOperations.js';
import 'monaco-editor/esm/vs/editor/contrib/comment/browser/comment.js';
import 'monaco-editor/esm/vs/editor/contrib/bracketMatching/browser/bracketMatching.js';
import 'monaco-editor/esm/vs/editor/contrib/folding/browser/folding.js';
import 'monaco-editor/esm/vs/editor/contrib/clipboard/browser/clipboard.js';
import 'monaco-editor/esm/vs/editor/contrib/contextmenu/browser/contextmenu.js';
import 'monaco-editor/esm/vs/editor/contrib/suggest/browser/suggestController.js';
import 'monaco-editor/esm/vs/editor/contrib/quickAccess/browser/commandsQuickAccess.js';
import 'monaco-editor/esm/vs/editor/contrib/quickAccess/browser/gotoLineQuickAccess.js';

window.createMadmdEditor = async (source, theme, changed) => {
  // WebKit custom schemes cannot start URL workers. A bundled, self-contained
  // classic worker in a Blob retains Monaco's off-thread diff/text services.
  const response = await fetch('madmd://bundle/editor.worker.js');
  if (!response.ok) throw new Error('Cannot load editor worker');
  const workerURL = URL.createObjectURL(new Blob([await response.text()], { type: 'text/javascript' }));
  window.MonacoEnvironment = { getWorker: () => new Worker(workerURL) };
  monaco.editor.defineTheme('madmd-light', { base: 'vs', inherit: true, rules: [], colors: { 'editor.background': '#ffffff', 'editorLineNumber.foreground': '#afb8c1' } });
  monaco.editor.defineTheme('madmd-dark', { base: 'vs-dark', inherit: true, rules: [], colors: { 'editor.background': '#0d1117', 'editor.foreground': '#e6edf3' } });
  const editor = monaco.editor.create(document.getElementById('editor'), {
    value: source, language: 'markdown', theme: `madmd-${theme}`, automaticLayout: true,
    fontFamily: '"SF Mono", Menlo, monospace', fontSize: 14, lineHeight: 23,
    minimap: { enabled: false }, padding: { top: 25, bottom: 25 },
    scrollBeyondLastLine: false, wordWrap: 'on', lineNumbersMinChars: 4,
    renderLineHighlight: 'none', overviewRulerLanes: 0, hideCursorInOverviewRuler: true,
    smoothScrolling: true, cursorBlinking: 'smooth', fixedOverflowWidgets: true,
    unicodeHighlight: { ambiguousCharacters: false }, accessibilitySupport: 'auto',
    ariaLabel: 'Markdown editor', tabSize: 2, insertSpaces: true
  });
  let replacing = false;
  editor.onDidChangeModelContent(() => { if (!replacing) changed(editor.getValue()); });
  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => window.webkit?.messageHandlers?.madmd?.postMessage({ type: 'save' }));
  window.madmdEditor = {
    getValue: () => editor.getValue(),
    setValue(value) { if (value === editor.getValue()) return; replacing = true; editor.setValue(value); replacing = false; },
    setTheme: next => monaco.editor.setTheme(`madmd-${next}`),
    focus: () => editor.focus(), layout: () => editor.layout(),
    action: id => editor.trigger('native', id, null),
    markSaved: () => editor.pushUndoStop(),
    testEdit: value => editor.executeEdits('test', [{ range: editor.getModel().getFullModelRange(), text: value }])
  };
};
