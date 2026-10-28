import createDOMPurify from 'dompurify';

export function createSanitizer(window) {
  const purify = createDOMPurify(window);
  purify.addHook('uponSanitizeAttribute', (node, data) => {
    if (data.attrName !== 'style') return;
    if (!node.closest?.('.katex')) { data.keepAttr = false; return; }
    const allowed = new Set(['height', 'width', 'min-width', 'top', 'left', 'right', 'vertical-align', 'margin-left', 'margin-right', 'padding-left', 'padding-right', 'border-bottom-width']);
    const declarations = data.attrValue.split(';').filter(Boolean);
    data.keepAttr = declarations.every(declaration => {
      const [property, value = ''] = declaration.split(':').map(s => s.trim());
      return (allowed.has(property) && /^-?[\d.]+(?:em|ex|px|%)?$/.test(value)) ||
        (property === 'position' && value === 'relative') ||
        (['color', 'border-color'].includes(property) && /^(?:#[a-f\d]{3,8}|[a-z]+|rgba?\([\d.,%\s]+\))$/i.test(value));
    });
  });
  // Media falls back to the next <source> when one fails, so a remote source after a local one
  // would reveal over the network whether the local file exists.
  const isRemote = url => /^[a-z][a-z\d+.-]*:/i.test(url ?? '') && !/^madmd:/i.test(url);
  purify.addHook('afterSanitizeElements', node => {
    if (!['VIDEO', 'AUDIO'].includes(node.nodeName)) return;
    const sources = [...node.querySelectorAll(':scope > source')];
    const local = [node.getAttribute('src'), ...sources.map(source => source.getAttribute('src'))].some(src => src && !isRemote(src));
    if (local) sources.filter(source => isRemote(source.getAttribute('src'))).forEach(source => source.remove());
  });
  return html => purify.sanitize(html, {
    USE_PROFILES: { html: true, svg: true, mathMl: true },
    ADD_ATTR: ['data-kind', 'data-source', 'align', 'target'],
    FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'textarea', 'button', 'select'],
    ALLOW_UNKNOWN_PROTOCOLS: false,
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|madmd):|[^a-z]|[a-z+.-]+(?:[^a-z+.:\-]|$))/i
  });
}
