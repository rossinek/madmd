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
  return html => purify.sanitize(html, {
    USE_PROFILES: { html: true, svg: true, mathMl: true },
    ADD_ATTR: ['data-kind', 'data-source', 'align', 'target'],
    FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'textarea', 'button', 'select'],
    ALLOW_UNKNOWN_PROTOCOLS: false,
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|madmd):|[^a-z]|[a-z+.-]+(?:[^a-z+.:\-]|$))/i
  });
}
