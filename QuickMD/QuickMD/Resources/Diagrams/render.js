/* All renderers run locally. Source is passed as data by callAsyncJavaScript. */
'use strict';
const libraries = new Map();
function loadScript(path) {
  if (!libraries.has(path)) libraries.set(path, new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = path;
    script.onload = resolve;
    script.onerror = () => reject(new Error('Unable to load bundled renderer: ' + path));
    document.head.appendChild(script);
  }));
  return libraries.get(path);
}
function dimension(value, fallback) {
  const match = String(value || '').match(/^\s*([\d.]+)\s*(px|pt|in|cm|mm)?\s*$/);
  return match ? Number(match[1]) * ({px:1,pt:96/72,in:96,cm:96/2.54,mm:96/25.4}[match[2] || 'px']) : fallback;
}
function svgDocument(text) {
  const doc = new DOMParser().parseFromString(text, 'image/svg+xml');
  const root = doc.documentElement;
  if (doc.querySelector('parsererror') || root.localName !== 'svg' || root.namespaceURI !== 'http://www.w3.org/2000/svg') {
    throw new Error('Invalid SVG document.');
  }
  let box = (root.getAttribute('viewBox') || '').trim().split(/[\s,]+/).map(Number);
  if (box.length !== 4 || !box.every(Number.isFinite) || box[2] <= 0 || box[3] <= 0) {
    box = [0, 0, dimension(root.getAttribute('width'), 300), dimension(root.getAttribute('height'), 150)];
    if (!(box[2] > 0 && box[3] > 0)) throw new Error('SVG must have positive dimensions.');
    root.setAttribute('viewBox', box.join(' '));
  }
  // Normalize physical units and cap the intrinsic size while preserving the viewBox.
  const scale = Math.min(1, 32768 / Math.max(box[2], box[3]));
  root.setAttribute('width', box[2] * scale);
  root.setAttribute('height', box[3] * scale);
  return {doc, root, width: box[2] * scale, height: box[3] * scale};
}
window.quickmdRender = async function(kind, source, isDark) {
  const work = document.getElementById('work');
  work.replaceChildren();
  let svg;
  if (kind === 'mermaid') {
    await loadScript('../mermaid.min.js');
    mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:isDark ? 'dark' : 'default',
      fontFamily:'-apple-system, BlinkMacSystemFont, sans-serif'});
    svg = (await mermaid.render('quickmd-mermaid', source)).svg;
  } else if (kind === 'plantuml') {
    await loadScript('vendor/viz-global.js');
    await loadScript('vendor/plantuml.js');
    // The engine resolves bundled themes/icons relative to document.baseURI.
    await loadScript('vendor/emoji.js');
    await loadScript('vendor/openiconic.js');
    await loadScript('vendor/themes.js');
    svg = await new Promise((resolve, reject) => {
      PlantUML.renderToString(source.split(/\r\n|\r|\n/), resolve,
        message => reject(new Error(message)), {dark:isDark});
    });
  } else if (kind === 'bpmn') {
    await loadScript('vendor/bpmn-viewer.js');
    const viewer = new BpmnJS({container:work});
    try {
      await viewer.importXML(source);
      svg = (await viewer.saveSVG()).svg;
      // BPMN labels are dark by default, including labels outside shapes.
      // Keep a white canvas so they remain readable in dark document themes.

      // Preserve the original viewer's unmodified attribution artwork in a
      // separate footer, so neither the process nor a preview can cover it.
      const parsed = svgDocument(svg);
      const logo = work.querySelector('.bjs-powered-by svg');
      if (logo) {
        const box = parsed.root.getAttribute('viewBox').split(/[\s,]+/).map(Number);
        const footer = parsed.doc.createElementNS('http://www.w3.org/2000/svg', 'a');
        footer.setAttribute('href', 'https://bpmn.io');
        const mark = parsed.doc.importNode(logo, true);
        const width = Math.max(box[2], 120);
        mark.setAttribute('x', box[0] + width - 65);
        mark.setAttribute('y', box[1] + box[3] + 12);
        mark.setAttribute('width', '50'); mark.setAttribute('height', '22');
        footer.appendChild(mark); parsed.root.appendChild(footer);
        parsed.root.setAttribute('viewBox', [box[0], box[1], width, box[3] + 46].join(' '));
        const background = parsed.doc.createElementNS('http://www.w3.org/2000/svg', 'rect');
        background.setAttribute('x', box[0]); background.setAttribute('y', box[1]);
        background.setAttribute('width', width); background.setAttribute('height', box[3] + 46);
        background.setAttribute('fill', '#fff');
        parsed.root.insertBefore(background, parsed.root.firstChild);
        svg = new XMLSerializer().serializeToString(parsed.root);
      }
    } finally { viewer.destroy(); }
  } else if (kind === 'svg') {
    svg = source;
  } else { throw new Error('Unsupported diagram type: ' + kind); }
  const parsed = svgDocument(svg);
  // SVG never enters the display DOM. The viewer uses an <img> data URL,
  // where WebKit disables SVG scripts, event handlers and external resources.
  return { svg: new XMLSerializer().serializeToString(parsed.root), width:parsed.width, height:parsed.height };
};
