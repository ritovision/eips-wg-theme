import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import vm from 'node:vm';

const root = resolve(process.argv[2]);
const scripts = resolve(root, 'static/assets/scripts');

class Element {
    constructor(tag = 'div') { this.tag = tag; this.children = []; this.attrs = {}; this.events = {}; this._text = ''; this.classList = { add() {}, remove() {} }; }
    set textContent(s) { this._text = s; this.children = []; }
    get textContent() { return this._text + this.children.map(c => c.textContent).join(''); }
    setAttribute(k, v) { this.attrs[k] = v; }
    appendChild(child) { this.children.push(child); return child; }
    addEventListener(k, fn) { this.events[k] = fn; }
    focus() {}
    get childElementCount() { return this.children.length; }
}

async function modules(basePath, values = new Map(), search = async () => ({ results: [] })) {
    const document = {
        getElementById() { return { textContent: JSON.stringify({ enabled: true, base_path: basePath }) }; },
        createElement(tag) { return new Element(tag); },
        body: new Element('body'),
        addEventListener() {},
        querySelector() { return null; },
    };
    const context = vm.createContext({ console, URL, URLSearchParams, Date, setTimeout,
        document, window: { document, setTimeout, location: { origin: 'https://example.test' },
            localStorage: { getItem: k => values.get(k) ?? null, setItem: (k, v) => values.set(k, v), removeItem: k => values.delete(k) } } });
    const cache = new Map();
    async function get(path) {
        if (cache.has(path)) return cache.get(path);
        let source = path.endsWith('/loader.mjs') ? 'export const debouncedPagefindSearch = globalThis.testSearch;' : await readFile(path, 'utf8');
        if (path.endsWith('/modal.mjs')) source += '\nexport { runQuickSearch, quickSearch, openQuickSearch, closeQuickSearch };';
        const module = new vm.SourceTextModule(source, { context, identifier: path });
        cache.set(path, module);
        return module;
    }
    context.testSearch = search;
    async function load(name) {
        const m = await get(resolve(scripts, 'search', name));
        await m.link((specifier, parent) => get(resolve(dirname(parent.identifier), specifier)));
        await m.evaluate();
        return m.namespace;
    }
    return { load, document };
}

// Two independently initialized sites share one same-origin localStorage map.
const values = new Map([['eips.search', 'unreleased old key is not migrated or touched']]);
const eip = await (await modules('/EIPs/', values)).load('storage.mjs');
const erc = await (await modules('/ERCs/', values)).load('storage.mjs');
eip.writeLastSearchUrl('/EIPs/search/?q=1559');
erc.writeLastSearchUrl('/ERCs/search/?q=20');
assert.equal(eip.readLastSearchUrl({}), '/EIPs/search/?q=1559');
assert.equal(erc.readLastSearchUrl({}), '/ERCs/search/?q=20');
eip.clearLastSearch();
assert.equal(erc.readLastSearchUrl({}), '/ERCs/search/?q=20');
eip.writeLastSearchUrl('/wrong/search/?q=invalid');
assert.equal(eip.readLastSearchUrl({}), null);
assert.equal(erc.readLastSearchUrl({}), '/ERCs/search/?q=20');
const invalidErc = JSON.parse(values.get('eips.search:/ERCs/search/'));
invalidErc.expiresAt = '2000-01-01T00:00:00Z';
values.set('eips.search:/ERCs/search/', JSON.stringify(invalidErc));
eip.writeLastSearchUrl('/EIPs/search/?q=kept');
assert.equal(erc.readLastSearchUrl({}), null);
assert.equal(eip.readLastSearchUrl({}), '/EIPs/search/?q=kept');
assert.equal(values.get('eips.search'), 'unreleased old key is not migrated or touched');
console.log('PASS storage: read/write/clear/invalid/expiry isolation across EIPs and ERCs; no migration');

function deferred() { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; }
const pending = new Map();
const { load } = await modules('/EIPs/', new Map(), async q => ({ results: [{ data: () => pending.get(q).promise }] }));
const modal = await load('modal.mjs');
modal.openQuickSearch();
const data = title => ({ meta: { title }, url: '/EIPs/1559/' });
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
pending.set('older', deferred());
pending.set('newer', deferred());
const older = modal.runQuickSearch('older');
await flush();
const newer = modal.runQuickSearch('newer');
await flush();
pending.get('newer').resolve(data('newer result'));
await newer;
const current = modal.quickSearch.results.textContent;
pending.get('older').resolve(data('stale result'));
await older;
assert.equal(modal.quickSearch.results.textContent, current);
assert.ok(current.includes('newer result'));
assert.equal(modal.quickSearch.fullSearchLink.href, '/EIPs/search/?q=newer');
assert.equal(modal.quickSearch.status.textContent, '1 result.');
for (const action of ['clear', 'reopen', 'close']) {
    pending.set(action, deferred());
    const task = modal.runQuickSearch(action);
    await flush();
    if (action === 'clear') await modal.runQuickSearch('');
    else if (action === 'reopen') { modal.closeQuickSearch(); modal.openQuickSearch(); }
    else modal.closeQuickSearch();
    const before = modal.quickSearch.results.textContent;
    const beforeStatus = modal.quickSearch.status.textContent;
    pending.get(action).resolve(data('must not publish'));
    await task;
    assert.equal(modal.quickSearch.results.textContent, before, action);
    assert.equal(modal.quickSearch.status.textContent, beforeStatus, action);
}
console.log('PASS quick search: deferred older data cannot overwrite newer results, empty query, or reopened/closed modal');

