import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createChromeWorkWindow, ensureChromeWorkspace, createChromeReviewWindow } from './chrome_work_window.mjs';
import * as routing from './chrome_work_window.mjs';

const placement = {
    enabled: true, intent: 'automation', targetScreenUUID: 'side-screen',
    bounds: { left: -1200, top: 40, width: 1100, height: 800 },
};

test('unified gateway creates Chrome and returns exact browser ownership proof', async () => {
    assert.equal(typeof routing.createChromeFromGateway, 'function');
    const f = fixture();
    const work = await routing.createChromeFromGateway(f.browser,
        { kind: 'browser', requestID: 'own-request', placement }, 'connection-one');
    assert.equal(work.proof.windowId, 101);
    assert.equal(work.proof.tabId, 102);
    assert.equal(work.proof.extensionInstanceId, 'connection-one');
    assert.equal(work.requestID, 'own-request');
    assert.equal(work.proof.bounds.focused, false);
});

test('unified gateway rejects missing tickets or connections before any browser change', async () => {
    assert.equal(typeof routing.createChromeFromGateway, 'function');
    for (const [request, connection] of [[{ kind: 'browser', placement }, 'one'],
        [{ kind: 'native_pending', requestID: 'one', placement }, 'one'],
        [{ kind: 'browser', requestID: 'one', placement }, '']]) {
        const f = fixture();
        await assert.rejects(routing.createChromeFromGateway(f.browser, request, connection));
        assert.equal(f.calls.length, 0);
    }
});

test('a browser connection different from the opening ticket cannot create a window', async () => {
    const f=fixture();
    await assert.rejects(routing.createChromeFromGateway(f.browser,
        {kind:'browser',requestID:'ticket',placement,extensionInstanceId:'expected'},'different'),/连接不匹配/);
    assert.deepEqual(f.calls,[]);
});

function fixture({ tabMissing = false, focused = false, differentBounds = false } = {}) {
    const calls = [];
    const tab = { id: '102' };
    const state = { bounds: { ...placement.bounds, left: differentBounds ? 0 : placement.bounds.left, focused },
        windowId: 101, tabs: [{ id: 102, url: 'about:blank' }] };
    const management = { windows: {
        create: async options => {
            calls.push(['create', options]);
            return { id: 101, tabs: [{ id: 102 }] };
        },
        get: async id => {
            calls.push(['get', id]);
            return { ...state.bounds };
        },
        update: async (id, bounds) => {
            calls.push(['update', id, bounds]); state.bounds = { ...bounds }; return state.bounds;
        },
    }, tabs: {
        get: async id => { assert.equal(id, 102); return { windowId: state.windowId }; },
        query: async () => state.tabs,
        group: async options => {
            calls.push(['group', options]); state.tabs[0].groupId = 205; return 205;
        },
    }, tabGroups: {
        update: async (id, options) => { calls.push(['group-update', id, options]); },
    } };
    management.windows.getAll = async () => [{ id: state.windowId }];
    const browser = {
        capabilities: { get: async id => {
            assert.equal(id, 'management'); return management;
        } },
        user: {
            openTabs: async () => tabMissing ? [{ id: '999' }] : [{ id: '999' }, tab],
            claimTab: async info => {
                calls.push(['claim', info.id]); assert.equal(info.id, '102'); return tab;
            },
        },
    };
    return { browser, calls, tab, state };
}

test('uses the exact created tab and inactive bounds, including negative coordinates', async () => {
    const f = fixture();
    const work = await createChromeWorkWindow(f.browser, placement);
    assert.equal(work.tab, f.tab);
    assert.equal(work.windowId, 101);
    assert.deepEqual(f.calls[0], ['create', { ...placement.bounds, focused: false, state: 'normal' }]);
    assert.deepEqual(f.calls[1], ['claim', '102']);
});

test('paused, disconnected, and invalid placements never open a window', async () => {
    for (const route of [null, { ...placement, enabled: false },
        { ...placement, reason: 'fixed_screen_not_connected' },
        { ...placement, bounds: { ...placement.bounds, width: -1 } }]) {
        const f = fixture();
        await assert.rejects(createChromeWorkWindow(f.browser, route));
        assert.deepEqual(f.calls, []);
    }
});

test('missing created tab never falls back to a personal tab', async () => {
    const f = fixture({ tabMissing: true });
    await assert.rejects(createChromeWorkWindow(f.browser, placement), /未找到新标签/);
    assert.equal(f.calls.length, 1);
});

test('a new window unexpectedly focused or placed incorrectly is rejected', async () => {
    for (const options of [{ focused: true }, { differentBounds: true }]) {
        const f = fixture(options);
        await assert.rejects(createChromeWorkWindow(f.browser, placement), /停止/);
        assert.deepEqual(f.calls.map(x => x[0]), ['create', 'claim', 'get']);
    }
});

test('a registered side-screen task window may be focused during its work', async () => {
    const f=fixture();
    const work=await createChromeWorkWindow(f.browser,placement);
    f.state.bounds.focused=true;
    let operated=false;
    await work.runOnSideScreen(placement,async()=>{operated=true;});
    assert.equal(operated,true);
    assert.equal(f.state.bounds.focused,true);
});

test('background actions check the screen before and after', async () => {
    const f = fixture();
    const work = await createChromeWorkWindow(f.browser, placement);
    const value = await work.runOnSideScreen(placement, async tab => {
        assert.equal(tab, f.tab);
        f.state.bounds.left = 0;
        return 'done';
    });
    assert.equal(value, 'done');
    assert.equal(f.state.bounds.left, placement.bounds.left);
    assert.equal(f.calls.filter(x => x[0] === 'update').length, 1);
    f.state.bounds.left = 0;
    await assert.rejects(work.verifyPlacement(placement), /反复偏离副屏/);
    assert.equal(f.calls.filter(x => x[0] === 'update').length, 1);
});

test('never moves a personal destination window or mixed window', async () => {
    for (const mixed of [false, true]) {
        const f = fixture();
        const work = await createChromeWorkWindow(f.browser, placement);
        if (mixed) { f.state.bounds.left = 0; f.state.tabs.push({ id: 999 }); }
        else f.state.windowId = 999;
        let actionRan = false;
        await assert.rejects(work.runOnSideScreen(placement, () => { actionRan = true; }), /停止操作/);
        assert.equal(actionRan, false);
        assert.equal(f.calls.filter(x => x[0] === 'update').length, 0);
    }
});

test('an action failure still checks and restores the dedicated position', async () => {
    const f = fixture();
    const work = await createChromeWorkWindow(f.browser, placement);
    const failure = new Error('test page failed');
    await assert.rejects(work.runOnSideScreen(placement, () => {
        f.state.bounds.left = 0;
        throw failure;
    }), error => error === failure);
    assert.equal(f.state.bounds.left, placement.bounds.left);
    assert.equal(f.calls.filter(x => x[0] === 'update').length, 1);
});

test('keeps both errors when the page action and placement check fail', async () => {
    const f = fixture();
    const work = await createChromeWorkWindow(f.browser, placement);
    const failure = new Error('test page failed');
    await assert.rejects(work.runOnSideScreen(placement, () => {
        f.state.windowId = 999;
        throw failure;
    }), error => error instanceof AggregateError && error.errors[0] === failure
        && /停止操作/.test(error.errors[1].message));
    assert.equal(f.calls.filter(x => x[0] === 'update').length, 0);
});

test('retained workspace uses native organization and reuses only its recorded IDs', async () => {
    const f = fixture();
    const first = await ensureChromeWorkspace(f.browser, placement, 'profile-one');
    assert.equal(first.reused, false);
    assert.equal(first.groupId, 205);
    assert.equal(f.calls.filter(x => x[0] === 'claim').length, 0);
    const second = await ensureChromeWorkspace(f.browser, { ...placement, chromeWorkspace: first }, 'profile-one');
    assert.equal(second.reused, true);
    assert.equal(f.calls.filter(x => x[0] === 'create').length, 1);
    assert.equal(f.calls.filter(x => x[0] === 'group-update').length, 1);
});

test('workspace checks pause and refuses to move a window mixed with personal tabs', async () => {
    const f = fixture();
    await assert.rejects(ensureChromeWorkspace(f.browser, { ...placement, enabled: false }, 'profile-one'));
    assert.equal(f.calls.length, 0);
    const own = await ensureChromeWorkspace(f.browser, placement, 'profile-one');
    f.state.tabs.push({ id: 999 });
    f.state.bounds.left = 0;
    await assert.rejects(ensureChromeWorkspace(f.browser, { ...placement, chromeWorkspace: own }, 'profile-one'), /个人标签/);
    assert.equal(f.calls.filter(x => x[0] === 'update').length, 0);
});

test('workspace used for a real webpage is no longer moved automatically', async () => {
    const f = fixture();
    const own = await ensureChromeWorkspace(f.browser, placement, 'profile-one');
    f.state.tabs[0].url = 'https://user-work.invalid/';
    f.state.bounds.left = 0;
    await assert.rejects(ensureChromeWorkspace(f.browser, { ...placement, chromeWorkspace: own }, 'profile-one'), /个人页面/);
    assert.equal(f.calls.filter(x => x[0] === 'update').length, 0);
});

test('user review creates a background window without claiming it as an agent tab', async () => {
    const f = fixture();
    const result = await createChromeReviewWindow(f.browser, { ...placement, intent: 'review' });
    assert.equal(result.intent, 'review');
    assert.equal(result.windowId, 101);
    assert.equal(f.calls.filter(x => x[0] === 'claim').length, 0);
});

test('automation and personal-view entry points cannot be silently exchanged', async () => {
    const f = fixture();
    await assert.rejects(createChromeReviewWindow(f.browser, placement));
    await assert.rejects(createChromeWorkWindow(f.browser, { ...placement, intent: 'review' }));
    await assert.rejects(ensureChromeWorkspace(f.browser, { ...placement, intent: 'review' }, 'profile-one'));
    assert.equal(f.calls.length, 0);
});
