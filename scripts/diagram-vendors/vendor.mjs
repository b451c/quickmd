import { build } from 'esbuild';
import { cp, mkdir, writeFile, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.resolve(here, '../../QuickMD/QuickMD/Resources/Diagrams/vendor');
await mkdir(out, { recursive: true });
const plant = path.join(here, 'node_modules/@plantuml/core');
const bpmn = path.join(here, 'node_modules/bpmn-js');
// Classic script avoids ES-module file-origin restrictions in WKWebView.
// Do not minify: esbuild minification of this TeaVM output produces an
// undeclared-label syntax error in WebKit (covered by DiagramRendererTests).
await build({ entryPoints: [path.join(plant, 'plantuml.js')], outfile: path.join(out, 'plantuml.js'),
  bundle: true, format: 'iife', globalName: 'PlantUML', target: 'safari16', minify: false });
for (const file of ['viz-global.js', 'emoji.js', 'openiconic.js', 'themes.js']) {
  await cp(path.join(plant, file), path.join(out, file));
}
await cp(path.join(plant, 'LICENSE'), path.join(out, 'PlantUML-LICENSE.txt'));
await cp(path.join(bpmn, 'dist/bpmn-viewer.production.min.js'), path.join(out, 'bpmn-viewer.js'));
await cp(path.join(bpmn, 'dist/assets/diagram-js.css'), path.join(out, 'diagram-js.css'));
await cp(path.join(bpmn, 'dist/assets/bpmn-js.css'), path.join(out, 'bpmn-js.css'));
await cp(path.join(bpmn, 'LICENSE'), path.join(out, 'BPMN-LICENSE.txt'));
await cp(path.join(here, 'licenses'), out, { recursive: true });
const files = ['plantuml.js', 'viz-global.js', 'emoji.js', 'openiconic.js', 'themes.js',
  'bpmn-viewer.js', 'diagram-js.css', 'bpmn-js.css'];
const hashes = {};
for (const file of files) hashes[file] = createHash('sha256').update(await readFile(path.join(out, file))).digest('hex');
await writeFile(path.join(out, 'manifest.json'), JSON.stringify({
  packages: { '@plantuml/core': '1.2026.8', 'bpmn-js': '18.28.0' }, sha256: hashes
}, null, 2) + '\n');
