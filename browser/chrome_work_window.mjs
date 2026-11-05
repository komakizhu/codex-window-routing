// Use in Computer Use's JS runtime with its documented Browser binding.
// Pass a fresh Hammerspoon newWindowPlacement() result before each creation.
// Deliberately does not use tabs.new(), activate(), or focused:true.
function requirePlacement(placement) {
    if (!placement || placement.enabled !== true || placement.reason
        || !placement.targetScreenUUID || !placement.bounds) {
        throw new Error(`副屏不可用，未开窗：${placement?.reason || 'missing_placement'}`);
    }
    const { left, top, width, height } = placement.bounds;
    if (![left, top, width, height].every(Number.isInteger)
        || width < 420 || height < 320) {
        throw new Error('副屏位置无效，未开窗');
    }
    return { left, top, width, height, focused: false, state: 'normal' };
}

// All opening purposes share the Hammerspoon gateway request. Return Chrome's
// exact IDs so the native side never guesses a window while the user types.
export async function createChromeFromGateway(browser, request, extensionInstanceId) {
    if (request?.kind !== 'browser' || typeof request.requestID !== 'string' || !request.requestID
        || typeof extensionInstanceId !== 'string' || !extensionInstanceId) {
        throw new Error('缺少本次开窗登记或浏览器连接；未开窗');
    }
    if (request.extensionInstanceId && request.extensionInstanceId !== extensionInstanceId) {
        throw new Error('本次登记的浏览器连接不匹配；未开窗');
    }
    requirePlacement(request.placement);
    const work = request.placement.intent === 'automation'
        ? await createChromeWorkWindow(browser, request.placement)
        : await createChromeReviewWindow(browser, request.placement);
    const management = await browser.capabilities.get('management');
    const bounds = await management.windows.get(work.windowId, { populate: false });
    const expected = requirePlacement(request.placement);
    if (bounds.focused || !['left', 'top', 'width', 'height'].every(k => bounds[k] === expected[k])) {
        throw new Error('新窗口位置或前台状态不符；停止操作');
    }
    return { ...work, requestID: request.requestID, proof: {
        windowId: work.windowId, tabId: work.tabId, extensionInstanceId, bounds,
    } };
}

// A user-facing window is deliberately separate from automation windows.
// Do not claim its tab as an ephemeral agent tab or activate the app.
export async function createChromeReviewWindow(browser, placement) {
    if (placement?.intent !== 'review' && placement?.intent !== 'user') {
        throw new Error('个人查看窗口必须明确使用 review 或 user 入口');
    }
    const bounds = requirePlacement(placement);
    const management = await browser.capabilities.get('management');
    const created = await management.windows.create(bounds);
    const windowId = created?.id, tabId = created?.tabs?.[0]?.id;
    if (!Number.isInteger(windowId) || !Number.isInteger(tabId)) throw new Error('未取得个人窗口编号');
    const actual = await management.windows.get(windowId, { populate: false });
    if (actual.focused || !['left', 'top', 'width', 'height'].every(key => actual[key] === bounds[key])) {
        throw new Error('个人窗口没有按主屏后台要求创建；停止操作');
    }
    return { windowId, tabId, intent: placement.intent, targetScreenUUID: placement.targetScreenUUID };
}

// A window-management deliverable, kept separate from ephemeral task tabs.
// Uses native tab-group metadata only; it does not inject a page or claim tabs.
export async function ensureChromeWorkspace(browser, placement, extensionInstanceId) {
    if (placement?.intent !== 'automation') throw new Error('Codex 工作窗必须使用 automation 入口');
    const bounds = requirePlacement(placement);
    if (typeof extensionInstanceId !== 'string' || !extensionInstanceId) {
        throw new Error('缺少 Chrome 连接标识；未创建工作窗');
    }
    const management = await browser.capabilities.get('management');
    const previous = placement.chromeWorkspace;
    let windowId, tabId, groupId, reused = false;
    if (previous && previous.extensionInstanceId === extensionInstanceId) {
        const windows = await management.windows.getAll({ populate: false });
        const tabs = windows.some(window => window.id === previous.windowId)
            ? await management.tabs.query({ windowId: previous.windowId }) : [];
        const own = tabs.find(tab => tab.id === previous.tabId && tab.groupId === previous.groupId);
        if (own) {
            if (tabs.length !== 1) throw new Error('工作窗混入其他标签；停止操作，不移动个人标签');
            if (!['about:blank', 'chrome://newtab/', 'chrome://new-tab-page/'].includes(own.url)) {
                throw new Error('工作窗已用于其他网页；停止操作，不移动个人页面');
            }
            ({ windowId, tabId, groupId } = previous);
            reused = true;
        }
    }
    if (!reused) {
        const created = await management.windows.create(bounds);
        windowId = created?.id;
        tabId = created?.tabs?.[0]?.id;
        if (!Number.isInteger(windowId) || !Number.isInteger(tabId)) {
            throw new Error('未取得专用工作窗编号；停止操作');
        }
    }
    let actual = await management.windows.get(windowId, { populate: false });
    const matches = () => ['left', 'top', 'width', 'height'].every(key => actual[key] === bounds[key]);
    if (actual.focused && !reused) throw new Error('Chrome 新工作窗意外取得前台焦点；停止后台安排');
    if (!matches()) {
        if (!reused) throw new Error('新工作窗没有直接落到指定副屏；停止操作');
        await management.windows.update(windowId, bounds);
        actual = await management.windows.get(windowId, { populate: false });
        if ((actual.focused && !reused) || !matches()) throw new Error('工作窗副屏位置恢复失败；停止操作');
    }
    if (!reused) {
        groupId = await management.tabs.group({ tabIds: [tabId], createProperties: { windowId } });
        if (!Number.isInteger(groupId) || groupId < 0) throw new Error('工作窗标签组编号无效；停止操作');
        await management.tabGroups.update(groupId, { title: 'Codex 副屏工作窗', color: 'green', collapsed: false });
    }
    return { windowId, tabId, groupId, extensionInstanceId, targetScreenUUID: placement.targetScreenUUID, reused };
}

export async function createChromeWorkWindow(browser, placement) {
    if (placement?.intent !== 'automation') throw new Error('任务窗口必须使用 automation 入口');
    const bounds = requirePlacement(placement);
    const management = await browser.capabilities.get('management');
    const created = await management.windows.create({
        ...bounds,
    });
    const tabId = created?.tabs?.[0]?.id;
    if (!Number.isInteger(created?.id) || !Number.isInteger(tabId)) {
        throw new Error('Chrome 未返回新窗口和新标签编号；停止操作，不猜测旧窗口');
    }
    const userTabs = await browser.user.openTabs();
    const exactTab = userTabs.find(tab => tab.id === String(tabId));
    if (!exactTab) {
        throw new Error(`未找到新标签 ${tabId}；停止操作，保留新窗口 ${created.id}`);
    }
    const tab = await browser.user.claimTab(exactTab);
    let repairedForTarget = null;
    async function verifyPlacement(currentPlacement, allowRepair = true, allowFocused = false) {
        const expected = requirePlacement(currentPlacement);
        const currentTab = await management.tabs.get(tabId);
        if (currentTab.windowId !== created.id) {
            throw new Error('工作标签已离开专用窗口；停止操作，不移动其他窗口');
        }
        let actual = await management.windows.get(created.id, { populate: false });
        if (actual.focused && !allowFocused) throw new Error('Chrome 新工作窗意外取得前台焦点；停止操作');
        const matches = window => ['left', 'top', 'width', 'height']
            .every(key => window[key] === expected[key]);
        if (!matches(actual)) {
            if (!allowRepair) throw new Error('Chrome 首次开窗未落在指定副屏；停止操作');
            const tabs = await management.tabs.query({ windowId: created.id });
            if (tabs.length !== 1 || tabs[0].id !== tabId) {
                throw new Error('专用窗口混入其他标签；停止操作，不移动个人标签');
            }
            if (repairedForTarget === currentPlacement.targetScreenUUID) {
                throw new Error('工作窗口反复偏离副屏；停止操作，不循环移动');
            }
            repairedForTarget = currentPlacement.targetScreenUUID;
            await management.windows.update(created.id, expected);
            actual = await management.windows.get(created.id, { populate: false });
            if ((actual.focused && !allowFocused) || !matches(actual)) throw new Error('副屏位置恢复失败；停止操作');
        }
        return { windowId: created.id, targetScreenUUID: currentPlacement.targetScreenUUID, bounds: actual };
    }
    await verifyPlacement(placement, false);
    return {
        tab, windowId: created.id, tabId, targetScreenUUID: placement.targetScreenUUID,
        verifyPlacement,
        async runOnSideScreen(currentPlacement, action) {
            await verifyPlacement(currentPlacement, true, true);
            let value, actionError, failed = false;
            try { value = await action(tab); }
            catch (error) { actionError = error; failed = true; }
            try { await verifyPlacement(currentPlacement, true, true); }
            catch (error) {
                if (failed) throw new AggregateError([actionError, error], '网页操作和副屏检查均失败');
                throw error;
            }
            if (failed) throw actionError;
            return value;
        },
    };
}
