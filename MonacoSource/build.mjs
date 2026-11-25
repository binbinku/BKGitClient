import { build } from 'esbuild';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('.', import.meta.url));
const output = resolve(process.argv[2] ?? resolve(source, '../BKGitClient/MonacoViewer'));
const options = {
  absWorkingDir: source,
  bundle: true,
  minify: true,
  format: 'iife',
  target: 'safari17',
  legalComments: 'none',
};

const workers = new Map();
for (const [name, entry] of [
  ['editor', 'monaco-editor/editor/editor.worker.js'],
  ['json', 'monaco-editor/language/json/json.worker.js'],
]) {
  const result = await build({ ...options, entryPoints: [entry], write: false });
  workers.set(name, result.outputFiles[0].text);
}

await mkdir(output, { recursive: true });
await build({
  ...options,
  entryPoints: ['viewer.js'],
  outdir: output,
  loader: { '.ttf': 'dataurl', '.woff': 'dataurl', '.woff2': 'dataurl' },
  plugins: [{
    name: 'inline-worker',
    setup(builder) {
      builder.onResolve({ filter: /^viewer-worker:/ }, args => ({
        path: args.path.split(':')[1],
        namespace: 'viewer-worker',
      }));
      builder.onLoad({ filter: /.*/, namespace: 'viewer-worker' }, args => ({
        contents: 'export default ' + JSON.stringify(workers.get(args.path)) + ';',
      }));
    },
  }],
});

await copyFile(resolve(source, 'index.html'), resolve(output, 'index.html'));
for (const name of ['LICENSE', 'ThirdPartyNotices.txt']) {
  await copyFile(resolve(source, 'node_modules/monaco-editor', name), resolve(output, name));
}
const markdownLicenses = await Promise.all([
  ['dompurify', 'LICENSE'],
  ['markdown-it', 'LICENSE'],
  ['entities', 'LICENSE'],
  ['linkify-it', 'LICENSE'],
  ['mdurl', 'LICENSE'],
  ['punycode.js', 'LICENSE-MIT.txt'],
  ['uc.micro', 'LICENSE.txt'],
].map(async ([name, file]) => name + '\n\n' + await readFile(resolve(source, 'node_modules', name, file), 'utf8')));
await writeFile(resolve(output, 'MarkdownNotices.txt'), markdownLicenses.join('\n\n'));
