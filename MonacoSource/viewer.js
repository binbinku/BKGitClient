import { editor, Uri } from 'monaco-editor/editor.js';
import 'monaco-editor/basic-languages/monaco.contribution.js';
import 'monaco-editor/language/json/monaco.contribution.js';
import 'monaco-editor/features/bracketMatching/register.js';
import 'monaco-editor/features/contextmenu/register.js';
import 'monaco-editor/features/diffEditor/register.js';
import 'monaco-editor/features/find/register.js';
import 'monaco-editor/features/folding/register.js';
import 'monaco-editor/features/gotoLine/register.js';
import createDOMPurify from 'dompurify';
import MarkdownIt from 'markdown-it';
import './viewer.css';
import editorWorker from 'viewer-worker:editor';
import jsonWorker from 'viewer-worker:json';

const workerURLs = new Map();
globalThis.MonacoEnvironment = {
  getWorker(_module, label) {
    const kind = label === 'json' ? 'json' : 'editor';
    if (!workerURLs.has(kind)) {
      const code = kind === 'json' ? jsonWorker : editorWorker;
      workerURLs.set(kind, URL.createObjectURL(new Blob([code], { type: 'text/javascript' })));
    }
    return new Worker(workerURLs.get(kind), { name: kind });
  },
};

const editorElement = document.getElementById('editor');
const diffElement = document.getElementById('diff-editor');
const preview = document.getElementById('markdown-preview');
const content = document.getElementById('markdown-content');
const fileInfoPadding = { bottom: 56 };
const markdown = new MarkdownIt({ html: true });
const htmlSanitizer = createDOMPurify(window);

const transparentColors = {
  'editor.background': '#00000000',
  'editorGutter.background': '#00000000',
};
editor.defineTheme('bk-light', { base: 'vs', inherit: true, rules: [], colors: transparentColors });
editor.defineTheme('bk-dark', { base: 'vs-dark', inherit: true, rules: [], colors: transparentColors });

preview.addEventListener('pointerdown', () => {
  window.webkit?.messageHandlers?.dismissMarkdownOutline?.postMessage(null);
});

function renderMarkdown(text) {
  if (!htmlSanitizer.isSupported) throw new Error('Markdown HTML sanitizer is unavailable');
  // Parse in an inert template. Only sanitized nodes are ever placed in the preview.
  const template = document.createElement('template');
  template.innerHTML = markdown.render(text);
  const fragment = htmlSanitizer.sanitize(template.content, {
    RETURN_DOM_FRAGMENT: true,
    ALLOWED_TAGS: [
      'a', 'b', 'blockquote', 'br', 'caption', 'code', 'dd', 'del', 'details', 'div', 'dl', 'dt', 'em',
      'figcaption', 'figure', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'i', 'img', 'kbd', 'li',
      'mark', 'ol', 'p', 'pre', 's', 'small', 'span', 'strong', 'sub', 'summary', 'sup', 'table',
      'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'u', 'ul',
    ],
    ALLOWED_ATTR: ['align', 'alt', 'class', 'colspan', 'height', 'href', 'open', 'rowspan', 'src', 'start', 'title', 'width'],
    ALLOW_ARIA_ATTR: false,
    ALLOW_DATA_ATTR: false,
  });

  const references = [];
  for (const image of fragment.querySelectorAll('img')) {
    const placeholder = document.createElement('span');
    placeholder.className = 'markdown-image';
    placeholder.textContent = image.getAttribute('alt') || '图片不可用';
    const reference = image.getAttribute('src');
    if (reference && references.length < 64) {
      placeholder.dataset.imageIndex = String(references.push(reference) - 1);
      for (const dimension of ['width', 'height']) {
        const value = image.getAttribute(dimension);
        if (value && /^[1-9]\d{0,4}$/.test(value)) placeholder.dataset[dimension] = value;
      }
    }
    // Markdown images and HTML images both go through the native project-path check.
    image.replaceWith(placeholder);
  }
  for (const table of fragment.querySelectorAll('table')) {
    const scroller = document.createElement('div');
    scroller.className = 'markdown-table-scroll';
    table.replaceWith(scroller);
    scroller.append(table);
  }
  content.replaceChildren(fragment);
  const headings = [...content.querySelectorAll('h1, h2, h3, h4, h5, h6')].flatMap((heading, index) => {
    const title = heading.textContent.replace(/\s+/g, ' ').trim();
    return title ? [{ id: index, title, level: Number(heading.tagName[1]) }] : [];
  });
  return { images: references, headings };
}

const view = editor.create(editorElement, {
  model: null,
  readOnly: true,
  domReadOnly: true,
  automaticLayout: true,
  ariaLabel: '只读文件预览',
  minimap: { enabled: false },
  scrollBeyondLastLine: false,
  padding: fileInfoPadding,
  folding: true,
  links: false,
  occurrencesHighlight: 'off',
  renderValidationDecorations: 'off',
  fontSize: 13,
});

let documentID = '';
let latestRevision = -1;
let activeMode;
let sourceState;
let previewScroll = 0;
let previewDocument;
let diff;
let diffID;
let diffModel;

globalThis.bkViewer = {
  async showDiff(original, modified, path, id, dark, revision) {
    if (revision < latestRevision) return;
    latestRevision = revision;
    editor.setTheme(dark ? 'bk-dark' : 'bk-light');
    editorElement.hidden = true;
    preview.hidden = true;
    diffElement.hidden = false;

    diff ??= editor.createDiffEditor(diffElement, {
      readOnly: true,
      domReadOnly: true,
      originalEditable: false,
      renderSideBySide: false,
      renderMarginRevertIcon: false,
      renderGutterMenu: false,
      ignoreTrimWhitespace: false,
      hideUnchangedRegions: { enabled: true },
      automaticLayout: true,
      minimap: { enabled: false },
      scrollBeyondLastLine: false,
      padding: fileInfoPadding,
      links: false,
      renderValidationDecorations: 'off',
      fontSize: 13,
      ariaLabel: '只读文件 Diff',
    });

    if (diffID !== id) {
      const previous = diff.getModel();
      const makeModel = (text, side) => editor.createModel(text, undefined, Uri.from({
        scheme: 'inmemory',
        path: '/diff/' + id + '/' + side + '/' + path,
      }));
      diffModel = diff.createViewModel({
        original: makeModel(original, 'original'),
        modified: makeModel(modified, 'modified'),
      });
      diff.setModel(diffModel);
      previous?.original.dispose();
      previous?.modified.dispose();
      diffID = id;
      diff.layout();
      diff.revealFirstDiff();
    }
    await diffModel.waitForDiff();
    if (revision === latestRevision && !diff.getLineChanges()?.length) {
      throw new Error('Monaco did not find any displayable changes');
    }
    return true;
  },
  show(text, path, id, dark, mode, revision) {
    if (revision < latestRevision) return [];
    latestRevision = revision;
    editor.setTheme(dark ? 'bk-dark' : 'bk-light');
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';

    if (documentID !== id) {
      documentID = id;
      const previous = view.getModel();
      view.setModel(null);
      previous?.dispose();
      content.replaceChildren();
      activeMode = undefined;
      sourceState = undefined;
      previewScroll = 0;
      previewDocument = undefined;
    }

    if (mode === 'preview') {
      if (!previewDocument) {
        previewDocument = renderMarkdown(text);
      }
      if (activeMode !== 'preview') {
        if (activeMode === 'source') sourceState = view.saveViewState();
        editorElement.hidden = true;
        preview.hidden = false;
        preview.scrollTop = previewScroll;
      }
    } else {
      if (activeMode === 'preview') previewScroll = preview.scrollTop;
      preview.hidden = true;
      editorElement.hidden = false;
      if (!view.getModel()) {
        view.setModel(editor.createModel(text, undefined, Uri.from({
          scheme: 'inmemory',
          path: '/preview/' + id + '/' + path,
        })));
      }
      if (activeMode !== 'source') {
        view.layout();
        if (sourceState) view.restoreViewState(sourceState);
        else view.setScrollPosition({ scrollTop: 0, scrollLeft: 0 });
      }
    }
    activeMode = mode;
    return mode === 'preview' ? previewDocument : null;
  },
  jumpToHeading(id, index) {
    if (documentID !== id || activeMode !== 'preview') return;
    const heading = content.querySelectorAll('h1, h2, h3, h4, h5, h6')[index];
    if (!heading) return;
    heading.tabIndex = -1;
    heading.focus({ preventScroll: true });
    heading.scrollIntoView({ block: 'start', inline: 'nearest' });
  },
  setImages(id, images) {
    if (id !== documentID) return;
    for (const { index, url } of images) {
      const placeholder = content.querySelector('[data-image-index="' + index + '"]');
      if (!placeholder) continue;
      const image = document.createElement('img');
      image.alt = placeholder.textContent;
      image.decoding = 'async';
      for (const dimension of ['width', 'height']) {
        if (placeholder.dataset[dimension]) image.setAttribute(dimension, placeholder.dataset[dimension]);
      }
      image.addEventListener('load', () => placeholder.replaceChildren(image), { once: true });
      image.src = url;
    }
  },
};
