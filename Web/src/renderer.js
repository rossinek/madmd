import MarkdownIt from 'markdown-it';
import GithubSlugger from 'github-slugger';
import footnote from 'markdown-it-footnote';
import taskLists from 'markdown-it-task-lists';
import { full as emoji } from 'markdown-it-emoji';
import texmath from 'markdown-it-texmath';
import katex from 'katex';
import hljs from 'highlight.js';

export function createRenderer() {
  const md = new MarkdownIt({ html: true, linkify: true, typographer: false,
    highlight(code, language) {
      if (code.length < 100_000 && language && hljs.getLanguage(language)) {
        try { return hljs.highlight(code, { language, ignoreIllegals: true }).value; } catch {}
      }
      return md.utils.escapeHtml(code);
    }
  }).use(footnote).use(taskLists).use(emoji)
    .use(texmath, { engine: katex, delimiters: 'dollars', katexOptions: { throwOnError: false, trust: false, strict: false, maxExpand: 1000 } });
  const fence = md.renderer.rules.fence;
  md.inline.ruler.before('math_inline', 'github-code-math', (state, silent) => {
    const match = state.src.slice(state.pos).match(/^\$`([^`]+)`\$/);
    if (!match) return false;
    if (!silent) {
      const token = state.push('html_inline', '', 0);
      token.content = katex.renderToString(match[1], { throwOnError: false, trust: false, maxExpand: 1000 });
    }
    state.pos += match[0].length; return true;
  });
  md.core.ruler.push('github-heading-ids', state => {
    const slugger = new GithubSlugger();
    for (let i = 0; i < state.tokens.length; i++) {
      if (state.tokens[i].type !== 'heading_open') continue;
      const text = (state.tokens[i + 1]?.children ?? []).filter(t => ['text', 'code_inline', 'emoji'].includes(t.type)).map(t => t.content).join('');
      state.tokens[i].attrSet('id', slugger.slug(text));
    }
  });
  md.renderer.rules.fence = (tokens, index, options, env, self) => {
    const token = tokens[index], language = token.info.trim().split(/\s/)[0].toLowerCase();
    if (['mermaid', 'geojson', 'topojson', 'stl'].includes(language)) {
      return `<div class="diagram" data-kind="${language}" data-source="${md.utils.escapeHtml(encodeURIComponent(token.content))}"><pre><code>${md.utils.escapeHtml(token.content)}</code></pre></div>`;
    }
    if (language === 'math') {
      return katex.renderToString(token.content, { displayMode: true, throwOnError: false, trust: false, maxExpand: 1000 });
    }
    return fence(tokens, index, options, env, self);
  };
  md.core.ruler.after('inline', 'github-alerts', state => {
    for (let i = 0; i < state.tokens.length - 2; i++) {
      const open = state.tokens[i], inline = state.tokens[i + 2];
      if (open.type !== 'blockquote_open' || inline.type !== 'inline') continue;
      const match = inline.content.match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\s*\n|$)/);
      if (!match) continue;
      open.attrSet('class', `markdown-alert markdown-alert-${match[1].toLowerCase()}`);
      inline.content = inline.content.slice(match[0].length);
      inline.children = state.md.parseInline(inline.content, state.env)[0].children;
      const label = new state.Token('html_inline', '', 0);
      label.content = `<span class="markdown-alert-title">${match[1][0]}${match[1].slice(1).toLowerCase()}</span>`;
      inline.children.unshift(label);
    }
  });
  return md;
}
