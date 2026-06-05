#!/usr/bin/env node
/*
 * get-ncm-map.js
 *
 * Headless Playwright extractor for the NCM device map.
 *
 * Why this exists:
 *   wpp-conf.vestasext.net/powerplant/<id>?edit=1 renders the NCM device list
 *   client-side via a Vue component (<ncm-tab>). PowerShell can't see the
 *   <select id="ncm-devices"> because it doesn't exist in the server-side
 *   HTML. We rent a real browser for ~3 seconds to do what PowerShell can't:
 *   execute the JS, wait for the Vue render, then dump the device map plus
 *   the session cookies. PowerShell consumes both and continues the per-
 *   device subconfig fan-out without re-authenticating.
 *
 * Usage:
 *   node get-ncm-map.js --powerplant <id> --out-file <map.json>
 *                       [--cookie-file <cookies.json>] [--headed] [--timeout-ms 30000]
 *                       [--skip-combo-probe]
 *
 * Credentials are read from ..\conf\.env (WPP_USERNAME, WPP_PASSWORD).
 * NEVER pass credentials on argv — they'd leak to process listings.
 *
 * Output (always written to --out-file):
 *   [
 *     {
 *       "ncm_device_id": 34664,
 *       "hostname": "CIAS-0025-VES1-CORE-SW1",
 *       "combos": [
 *         { "base_template": "1.1.0 EMEA", "boot_system_bootflash": "" },
 *         { "base_template": "1.2.0 EMEA", "boot_system_bootflash": "flash:image.bin" }
 *       ]
 *     },
 *     ...
 *   ]
 *
 *   When --skip-combo-probe is passed, "combos" is omitted (old shape).
 *
 * Output (when --cookie-file is set):
 *   {
 *     "cookies":   [{ name, value, domain, path, expires, httpOnly, secure, sameSite }, ...],
 *     "csrfToken": "<40-char meta value>",
 *     "fetchedAt": "<ISO timestamp>"
 *   }
 *
 * Exit codes:
 *   0  success
 *   2  authentication failure (IDP rejected credentials, SAML loop did not complete)
 *   3  page-parse failure (NCM select did not render within --timeout-ms)
 *   1  any other error
 */

const fs       = require('fs');
const path     = require('path');
const minimist = require('minimist');
const dotenv   = require('dotenv');
const { chromium } = require('playwright');

// ---------- Args ----------
const argv = minimist(process.argv.slice(2));
const powerplantId  = argv.powerplant;
const searchName    = argv['search-name'];
const outFile       = argv['out-file'];
const cookieFile    = argv['cookie-file'];
const headed        = !!argv.headed;
const timeoutMs     = parseInt(argv['timeout-ms'] || '60000', 10);
const skipComboProbe = !!argv['skip-combo-probe'];

if (!powerplantId || !outFile || !searchName) {
  console.error('Usage: node get-ncm-map.js --powerplant <id> --search-name <PowerplantName> --out-file <map.json> [--cookie-file <cookies.json>] [--headed] [--timeout-ms 60000] [--skip-combo-probe]');
  console.error('Example: node get-ncm-map.js --powerplant 5750 --search-name "DE-HeDreiht" --out-file map.json');
  process.exit(1);
}

// ---------- Credentials ----------
const envPath = path.resolve(__dirname, '..', 'conf', '.env');
if (!fs.existsSync(envPath)) {
  console.error(`Missing credentials file: ${envPath}`);
  process.exit(1);
}
dotenv.config({ path: envPath });
const username = process.env.WPP_USERNAME;
const password = process.env.WPP_PASSWORD;
if (!username || !password) {
  console.error(`WPP_USERNAME or WPP_PASSWORD missing/empty in ${envPath}`);
  process.exit(1);
}

// ---------- Main ----------
(async () => {
  const internalHost  = 'wpp-conf.vestasext.net';
  const idpHost       = 'wpp-idp.vestasext.net';
  const loginEntryUrl = `https://${internalHost}/login`;
  // Drop ?edit=1 — read-only view is enough to enumerate the NCM device list.
  const powerplantUrl = `https://${internalHost}/powerplant/${encodeURIComponent(powerplantId)}`;

  const browser = await chromium.launch({ channel: 'msedge', headless: !headed });
  const context = await browser.newContext({ acceptDownloads: false });
  let   page    = await context.newPage();

  // Auto-accept any confirm/alert/prompt dialogs the page may throw at us.
  // Vue apps sometimes confirm() before navigating; Playwright's default is to
  // dismiss, which silently cancels the action.
  context.on('page',  p => p.on('dialog', async d => { console.error(`[ncm-map] Dialog (${d.type()}): ${d.message()} — accepting`); await d.accept().catch(()=>{}); }));
  page.on('dialog', async d => { console.error(`[ncm-map] Dialog (${d.type()}): ${d.message()} — accepting`); await d.accept().catch(()=>{}); });

  try {
    // STEP 1 — enter at /login (canonical SAML entry). Going straight to a
    // protected URL like /powerplant/<id> with no session triggers the SP's
    // redirect-to-IDP loop, which Chromium kills with ERR_TOO_MANY_REDIRECTS
    // when state can't be preserved between hops. Starting at /login lets the
    // SP issue its SAMLRequest cleanly with RelayState=/.
    console.error(`[ncm-map] Opening ${loginEntryUrl}`);
    await page.goto(loginEntryUrl, { waitUntil: 'domcontentloaded', timeout: timeoutMs });
    console.error(`[ncm-map] After /login redirect chain, landed on ${page.url()}`);

    // STEP 2 — if we're on the IDP host, fill credentials. The form is
    // Vue-rendered so we wait for the password input rather than the form tag.
    const landedHost = new URL(page.url()).host;
    if (landedHost === idpHost) {
      console.error(`[ncm-map] IDP login form at ${page.url()}`);
      await page.locator('input[type=password]').first().waitFor({ timeout: timeoutMs });
      const userField = page.locator('input[type=email], input[type=text], input[name*=user i], input[id*=user i]').first();
      await userField.fill(username);
      await page.locator('input[type=password]').first().fill(password);
      const submit = page.locator('button[type=submit], input[type=submit]').first();
      console.error('[ncm-map] Submitting credentials...');
      await Promise.all([
        page.waitForURL(url => new URL(url).host === internalHost, { timeout: timeoutMs }),
        submit.click()
      ]);
      console.error(`[ncm-map] Authenticated. Landed on ${page.url()}`);
    } else if (landedHost === internalHost) {
      console.error(`[ncm-map] Already on internal host (session pre-existed or SAML auto-completed).`);
    } else {
      throw new Error(`Unexpected host after /login: ${landedHost} (URL ${page.url()}). Possibly an unfamiliar SSO step.`);
    }

    try { await page.screenshot({ path: 'debug-after-login.png', fullPage: true }); } catch {}
    console.error('[ncm-map] Saved post-login screenshot to debug-after-login.png');

    // STEP 3 — drive the UI flow that the app expects:
    //   Top nav -> "Power plant" -> "List" -> search by name -> View/edit.
    // Direct URL hits to /powerplant/<id> are gated by app-level state.

    // 3a: open the "Power plant" menu in the top nav.
    console.error('[ncm-map] Clicking "Power plant" menu...');
    const powerPlantMenu = page.locator(
      'a:has-text("Power plant"), button:has-text("Power plant"), li:has-text("Power plant") > a'
    ).first();
    await powerPlantMenu.waitFor({ timeout: timeoutMs });
    await powerPlantMenu.click();

    // 3b: click "List" in the dropdown/sub-menu.
    console.error('[ncm-map] Clicking "List"...');
    const listLink = page.locator(
      'a:has-text("List"):visible, button:has-text("List"):visible'
    ).first();
    await listLink.waitFor({ timeout: timeoutMs });
    await Promise.all([
      page.waitForLoadState('domcontentloaded', { timeout: timeoutMs }).catch(() => {}),
      listLink.click()
    ]);
    try { await page.screenshot({ path: 'debug-powerplant-list.png', fullPage: true }); } catch {}
    console.error(`[ncm-map] On list page: ${page.url()}`);

    // 3c: find the search input and type the powerplant name.
    console.error(`[ncm-map] Searching for "${searchName}"...`);
    const searchBox = page.locator(
      'input[type=search], input[placeholder*="search" i], input[aria-label*="search" i], input[name*="search" i]'
    ).first();
    await searchBox.waitFor({ timeout: timeoutMs });
    await searchBox.fill(searchName);
    // DataTables search has debounce + server-side fetch — wait for the row
    // containing the search term to actually appear, not just a fixed timer.
    console.error('[ncm-map] Waiting for matching row to appear...');
    const matchingRow = page.locator(`tr:has-text("${searchName}")`).first();
    await matchingRow.waitFor({ state: 'visible', timeout: 60000 });
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
    try { await page.screenshot({ path: 'debug-search-results.png', fullPage: true }); } catch {}

    // 3d: click whatever opens the powerplant detail page from the matched row.
    // Try selectors in order of reliability — a link to /powerplant/<id> is the
    // most stable signal regardless of button text, icon, or language.
    console.error('[ncm-map] Locating action element in matched row...');
    const candidates = [
      { name: 'a -> /powerplant/<id>',  sel: 'a[href*="/powerplant/"]' },
      { name: 'a "View/edit"',          sel: 'a:has-text("View/edit")' },
      { name: 'a "View / Edit"',        sel: 'a:has-text("View / Edit")' },
      { name: 'a "View"',               sel: 'a:has-text("View")' },
      { name: 'a "Edit"',               sel: 'a:has-text("Edit")' },
      { name: 'a [title*=edit]',        sel: 'a[title*="edit" i]' },
      { name: 'a [title*=view]',        sel: 'a[title*="view" i]' },
      { name: 'button "View/edit"',     sel: 'button:has-text("View/edit")' },
      { name: 'button "Edit"',          sel: 'button:has-text("Edit")' },
      { name: 'icon fa-edit/pencil/eye', sel: 'i.fa-edit, i.fa-pencil, i.fa-pencil-alt, i.fa-eye, i.fas.fa-edit' },
    ];

    let target = null; let chosen = null;
    for (const c of candidates) {
      const loc = matchingRow.locator(c.sel).first();
      const present = await loc.count();
      if (present === 0) continue;
      const visible = await loc.isVisible({ timeout: 500 }).catch(() => false);
      if (visible) { target = loc; chosen = c; break; }
    }

    if (!target) {
      // Dump the matched row's HTML so we can see what's actually there.
      const rowHtml = await matchingRow.evaluate(el => el.outerHTML).catch(() => '<unavailable>');
      const trunc   = rowHtml.length > 4000 ? rowHtml.substring(0, 4000) + '...<truncated>' : rowHtml;
      console.error('[ncm-map] No View/edit candidate matched. Row outerHTML follows:');
      console.error(trunc);
      throw new Error('Could not find a clickable element to open the powerplant detail. See row HTML above + debug-search-results.png.');
    }
    const hrefBefore = await target.getAttribute('href').catch(() => null);
    console.error(`[ncm-map] Found link via selector: ${chosen.name}  (${chosen.sel})  href=${hrefBefore}`);
    try { await page.screenshot({ path: 'debug-before-click.png', fullPage: true }); } catch {}

    // STRATEGY: Ctrl+click to open the detail page in a NEW TAB. This bypasses
    // any in-page Vue/JS click handlers that might be intercepting the
    // navigation on the list page (which is why the previous regular-click
    // attempt succeeded as a click but never changed page.url()).
    console.error('[ncm-map] Ctrl+clicking to open detail in new tab...');
    const newTabPromise = context.waitForEvent('page', { timeout: 30000 }).catch(() => null);
    await target.click({ modifiers: ['Control'], force: true, noWaitAfter: true, timeout: 30000 });
    const newPage = await newTabPromise;

    if (newPage) {
      console.error(`[ncm-map] New tab opened: ${newPage.url()}`);
      newPage.on('dialog', async d => { console.error(`[ncm-map] Dialog (${d.type()}): ${d.message()} — accepting`); await d.accept().catch(()=>{}); });
      page = newPage;  // switch context to the new tab for the rest of the flow
    } else {
      // Ctrl+click did not open a new tab (Vue may have hijacked it). Fall
      // back to a direct goto with a generous 5-minute timeout, waiting only
      // until commit so we don't block on heavy XHR fan-out.
      console.error('[ncm-map] No new tab — falling back to direct goto (5min, waitUntil=commit)...');
      if (hrefBefore) {
        await page.goto(hrefBefore, { waitUntil: 'commit', timeout: 300000 });
      } else {
        throw new Error('No new tab AND no href captured to fall back on.');
      }
    }

    // Poll for the URL to settle on /powerplant/<id> (3 min window).
    console.error('[ncm-map] Waiting up to 180s for URL to settle on /powerplant/<id>...');
    const navStart = Date.now();
    let landed = false;
    while (Date.now() - navStart < 180000) {
      if (/\/powerplant\/\d+/.test(page.url())) { landed = true; break; }
      await page.waitForTimeout(1000);
    }
    if (!landed) {
      try { await page.screenshot({ path: 'debug-no-url-change.png', fullPage: true }); } catch {}
      throw new Error(`URL didn't reach /powerplant/<id> within 180s. Current: ${page.url()} (see debug-no-url-change.png)`);
    }
    console.error(`[ncm-map] URL settled on ${page.url()}`);
    await page.waitForLoadState('domcontentloaded', { timeout: 180000 }).catch(() => {});
    console.error('[ncm-map] DOMContentLoaded reached on powerplant page.');

    // Sanity-check: the URL should now contain /powerplant/<id> (or just /powerplant/...)
    if (!/\/powerplant\//.test(page.url())) {
      throw new Error(`Expected to land on /powerplant/... after View/edit, but URL is ${page.url()}`);
    }
    if (powerplantId && !page.url().includes(`/powerplant/${powerplantId}`)) {
      console.error(`[ncm-map] WARN: powerplant id in URL doesn't match expected ${powerplantId}. URL: ${page.url()}`);
    }

    // Click the NCM tab to activate that panel. Try several locators in order:
    // the user-provided exact xpath first, then semantic fallbacks.
    console.error('[ncm-map] Locating and clicking NCM tab...');
    const ncmTabCandidates = [
      { name: 'xpath: 3rd tab > a', sel: 'xpath=/html/body/div[2]/div/div/section[2]/div/div[2]/div/div/div[2]/ul/li[3]/a' },
      { name: 'tab with bold NCM',  sel: 'a:has(b:text("NCM"))' },
      { name: 'href="#wpptab_2"',   sel: 'a[href="#wpptab_2"]' },
      { name: 'role=tab name=NCM',  sel: 'a[role="tab"]:has-text("NCM")' },
      { name: 'plain a "NCM"',      sel: 'a:has-text("NCM")' },
    ];
    let tabClicked = false;
    for (const tc of ncmTabCandidates) {
      const locator = page.locator(tc.sel).first();
      if ((await locator.count()) === 0) continue;
      try {
        await locator.scrollIntoViewIfNeeded({ timeout: 5000 }).catch(() => {});
        await locator.click({ force: true, timeout: 10000 });
        console.error(`[ncm-map] NCM tab clicked via ${tc.name}`);
        tabClicked = true;
        break;
      } catch (e) {
        console.error(`[ncm-map] Click via ${tc.name} failed: ${e.message}`);
      }
    }
    if (!tabClicked) {
      try { await page.screenshot({ path: 'debug-no-ncm-tab.png', fullPage: true }); } catch {}
      throw new Error('Could not click any NCM tab candidate. See debug-no-ncm-tab.png');
    }

    // STEP 3.5 — reveal the full asset list before reading the select.
    //
    // The NCM panel renders with a collapsed/filtered default view that omits
    // some assets, so #ncm-devices only carries a subset. A toggle control (an
    // <i> icon inside a <label>) inside the panel must be clicked to expand the
    // full device list. WITHOUT this the extracted map is missing assets — the
    // symptom observed on the Configuration Backup report. The toggle lives in
    // the same NCM panel as the tab (shared xpath prefix
    //   .../section[2]/div/div[2]/div/div/div[2]/...),
    // so it only exists once the tab above has activated the panel.
    //
    // Non-fatal by design: the toggle is addressed by a deep absolute xpath
    // that the SPA may renumber on redesign. If it can't be clicked we WARN +
    // screenshot and continue, rather than failing the whole run — but the log
    // makes clear the resulting map may be incomplete.
    console.error('[ncm-map] Clicking NCM asset-list toggle to reveal all assets...');
    const ncmToggleXpath = '/html/body/div[2]/div/div/section[2]/div/div[2]/div/div/div[2]/div/div[3]/div/div/div/div[1]/div/div[1]/label/i[1]';
    const ncmToggleCandidates = [
      { name: 'xpath: label > i[1] (user-provided)', sel: 'xpath=' + ncmToggleXpath },
      { name: 'xpath: parent label',                 sel: 'xpath=/html/body/div[2]/div/div/section[2]/div/div[2]/div/div/div[2]/div/div[3]/div/div/div/div[1]/div/div[1]/label' },
    ];
    // The toggle renders as <i class="fa fa-toggle-off ... unchecked"> inside a
    // <label> that Playwright reports as "not visible" (zero-box / CSS-hidden
    // ancestor while the tab pane is inactive), so a normal OR force click is
    // rejected — it needs a hittable point this element doesn't expose. Instead
    // dispatch a native click in the DOM via evaluate(): it bubbles to the Vue
    // / label handler regardless of visibility. force-click is kept as a first
    // attempt for the case where the element IS visible.
    // Capture the pre-toggle device count so we can prove the toggle actually
    // expanded the list (the only reliable success signal — see below). Brief
    // best-effort wait; if the select isn't populated yet beforeToggleCount = 0.
    await page.waitForSelector('#ncm-devices option[value]:not([value=""])', { timeout: 8000, state: 'attached' }).catch(() => {});
    const beforeToggleCount = await page.$$eval('#ncm-devices option[value]:not([value=""])', o => o.length).catch(() => 0);
    console.error(`[ncm-map] NCM device count before toggle: ${beforeToggleCount}`);

    let toggleClicked = false;
    for (const tc of ncmToggleCandidates) {
      const locator = page.locator(tc.sel).first();
      if ((await locator.count()) === 0) continue;
      await locator.scrollIntoViewIfNeeded({ timeout: 5000 }).catch(() => {});
      try {
        await locator.click({ force: true, timeout: 5000 });
        console.error(`[ncm-map] NCM asset-list toggle clicked (force) via ${tc.name}`);
        toggleClicked = true;
        break;
      } catch (e) {
        console.error(`[ncm-map] force-click via ${tc.name} failed: ${e.message.split('\n')[0]} — trying DOM dispatch...`);
        try {
          await locator.evaluate(el => el.click());
          console.error(`[ncm-map] NCM asset-list toggle clicked (DOM dispatch) via ${tc.name}`);
          toggleClicked = true;
          break;
        } catch (e2) {
          console.error(`[ncm-map] DOM dispatch via ${tc.name} failed: ${e2.message.split('\n')[0]}`);
        }
      }
    }
    if (!toggleClicked) {
      try { await page.screenshot({ path: 'debug-no-ncm-toggle.png', fullPage: true }); } catch {}
      console.error('[ncm-map] WARN: NCM asset-list toggle not found/clickable — extracted map MAY BE MISSING ASSETS. See debug-no-ncm-toggle.png');
    }
    // The toggle re-renders / re-fetches the list; let it settle before we read
    // #ncm-devices so we capture the expanded set, not the pre-toggle subset.
    await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});

    // Confirm the toggle's EFFECT rather than its icon state. The Vue panel
    // re-renders when the toggle fires, so re-reading the icon's class is
    // unreliable — it can read stale/reset even on a successful toggle (observed
    // as a false "still OFF" warning on a run that actually expanded 104 -> 404).
    // The honest signal is whether the device list actually grew.
    if (toggleClicked) {
      const afterToggleCount = await page.$$eval('#ncm-devices option[value]:not([value=""])', o => o.length).catch(() => 0);
      if (afterToggleCount > beforeToggleCount) {
        console.error(`[ncm-map] Toggle expanded the asset list: ${beforeToggleCount} -> ${afterToggleCount} device(s).`);
      } else if (beforeToggleCount > 0 && afterToggleCount === beforeToggleCount) {
        console.error(`[ncm-map] WARN: toggle clicked but device count is unchanged (${afterToggleCount}). The list was either already complete or the toggle had no effect — verify the count looks right.`);
      } else {
        console.error(`[ncm-map] Toggle clicked; ${afterToggleCount} device(s) present after settle.`);
      }
    }

    // Wait for #ncm-devices options to be ATTACHED to the DOM (not necessarily
    // visible — they may be inside an inactive tab panel hidden by CSS, but
    // the data is there and that's all we need for extraction).
    console.error('[ncm-map] Waiting for #ncm-devices options in DOM...');
    try {
      await page.waitForSelector('#ncm-devices option[value]:not([value=""])', {
        timeout: 180000,
        state: 'attached'
      });
    } catch (waitErr) {
      try { await page.screenshot({ path: 'debug-ncm-tab.png', fullPage: true }); } catch {}
      console.error(`[ncm-map] NCM select did not populate. Screenshot: debug-ncm-tab.png  URL: ${page.url()}`);
      throw waitErr;
    }

    // Extract the map.
    const devices = await page.$$eval('#ncm-devices option[value]:not([value=""])', opts =>
      opts
        .map(o => ({ ncm_device_id: Number(o.value), hostname: (o.textContent || '').trim() }))
        .filter(d => d.ncm_device_id > 0 && d.hostname.length > 0)
    );
    console.error(`[ncm-map] Extracted ${devices.length} NCM device(s).`);

    // STEP 4 — discover (base_template, boot_system_bootflash) combos per device.
    //
    // The /get-ncm-device-subconfig endpoint serves all three drill-down levels.
    // To enumerate Level-2 combos we let the Vue app fire its own XHR by
    // changing the device <select>, then snoop on the response. Each record in
    // the response body carries base_template + boot_system_bootflash; we
    // deduplicate those into the combo set for the device whose id appears in
    // the URL's `data[ncm_device_id]` query string.
    //
    // The probe is best-effort: any device that ends up with zero combos after
    // its XHR fires falls back to an in-page fetch() to confirm the server has
    // no Level-2 rows for it (i.e. the device truly has no configs to report).
    if (!skipComboProbe) {
      // STRATEGY: per device, hit /get-ncm-device-details?ncm_device_id=<id>&id=<powerplantId>.
      // This is the same endpoint the ncm-details.vue component uses; its
      // response carries the device's current `base_template` as a top-level
      // string. We pair it with empty boot_system_bootflash (the Configurations
      // table's default filter) to produce one combo per device:
      //   { base_template: <from response>, boot_system_bootflash: '' }
      //
      // We tried /get-ncm-device-subconfig with assorted filter shapes; it
      // does strict equality on data[base_template], so without the real value
      // (which we don't know up front) it only matches the rare devices whose
      // base_template is empty. /get-ncm-device-details gives us the value.
      //
      // Parallelized in batches of CONCURRENCY since each call is a small GET.
      const CONCURRENCY = 10;
      console.error(`[ncm-map] Resolving base_template for ${devices.length} device(s) via /get-ncm-device-details (concurrency=${CONCURRENCY})...`);

      const csrfToken = await page.getAttribute('meta[name="csrf-token"]', 'content').catch(() => '');
      if (!csrfToken) {
        console.error('[ncm-map] WARN: no CSRF token found on page -- server may return errors.');
      }

      const combosByDevice = new Map();
      const diagSamples    = [];
      let okCount = 0, emptyCount = 0, errCount = 0;

      async function fetchForDevice(deviceId, ppId) {
        return page.evaluate(async (args) => {
          const { id, ppId, csrfToken } = args;
          const url = '/get-ncm-device-details?ncm_device_id=' + encodeURIComponent(String(id))
                    + '&id=' + encodeURIComponent(String(ppId));
          const headers = {
            'Accept': 'application/json, text/javascript, */*; q=0.01',
            'X-Requested-With': 'XMLHttpRequest'
          };
          if (csrfToken) { headers['X-CSRF-TOKEN'] = csrfToken; }
          try {
            const r = await fetch(url, { method: 'GET', credentials: 'include', headers });
            const status = r.status;
            const ct = r.headers.get('content-type') || '';
            if (!r.ok) {
              const text = await r.text().catch(() => '');
              return { ok: false, status, snippet: text.slice(0, 200) };
            }
            if (!/json/i.test(ct)) {
              const text = await r.text().catch(() => '');
              return { ok: false, status, nonjson: true, snippet: text.slice(0, 200) };
            }
            return { ok: true, status, body: await r.json() };
          } catch (err) {
            return { ok: false, error: String(err && err.message || err) };
          }
        }, { id: deviceId, ppId, csrfToken });
      }

      let probed = 0;
      for (let i = 0; i < devices.length; i += CONCURRENCY) {
        const batch = devices.slice(i, i + CONCURRENCY);
        const results = await Promise.all(batch.map(d =>
          fetchForDevice(d.ncm_device_id, powerplantId)
            .then(res => ({ device: d, res }))
            .catch(err => ({ device: d, res: { ok: false, error: String(err && err.message || err) } }))
        ));

        for (const { device, res } of results) {
          if (res && res.ok && res.body && typeof res.body === 'object') {
            const bt = (res.body.base_template != null) ? String(res.body.base_template) : '';
            if (bt.length > 0) {
              combosByDevice.set(device.ncm_device_id, [{ base_template: bt, boot_system_bootflash: '' }]);
              okCount++;
            } else {
              combosByDevice.set(device.ncm_device_id, []);
              emptyCount++;
            }
          } else {
            combosByDevice.set(device.ncm_device_id, []);
            errCount++;
            if (diagSamples.length < 5) {
              diagSamples.push({ hostname: device.hostname, deviceId: device.ncm_device_id, res });
            }
          }
        }

        probed += batch.length;
        console.error(`[ncm-map] Details probed: ${probed}/${devices.length}  (ok=${okCount} empty=${emptyCount} err=${errCount})`);
      }
      let totalCombos = 0;
      let devicesWithCombos = 0;
      for (const d of devices) {
        d.combos = combosByDevice.get(d.ncm_device_id) || [];
        if (d.combos.length > 0) devicesWithCombos++;
        totalCombos += d.combos.length;
      }
      console.error(`[ncm-map] Combo discovery done: ${devicesWithCombos}/${devices.length} device(s) with combos, ${totalCombos} combo(s) total.`);
      if (diagSamples.length > 0) {
        console.error('[ncm-map] Diagnostic samples for first failing devices:');
        for (const s of diagSamples) {
          const r = s.res || {};
          const snip = (r.snippet || '').replace(/\s+/g,' ').slice(0,120);
          console.error(`  - ${s.hostname} (id=${s.deviceId}): ok=${r.ok} status=${r.status} err=${r.error || ''} nonjson=${!!r.nonjson} snippet=${snip}`);
        }
      }
    } else {
      console.error('[ncm-map] --skip-combo-probe set — emitting old shape (no combos field).');
    }

    // Write the map.
    fs.writeFileSync(outFile, JSON.stringify(devices, null, 2), { encoding: 'utf8' });

    // Optionally dump cookies + CSRF for PowerShell to reuse the session.
    if (cookieFile) {
      const cookies   = await context.cookies();
      const csrfToken = await page.getAttribute('meta[name="csrf-token"]', 'content').catch(() => null);
      fs.writeFileSync(cookieFile, JSON.stringify({
        cookies,
        csrfToken: csrfToken || '',
        fetchedAt: new Date().toISOString()
      }, null, 2), { encoding: 'utf8' });
      console.error(`[ncm-map] Cookies + CSRF dumped to ${cookieFile}.`);
    }

    process.exit(0);
  } catch (err) {
    console.error(`[ncm-map] FAILED: ${err.message}`);
    // Categorize: auth-flow timeout vs page-render timeout.
    const onIdpNow = !page.url().startsWith(`https://${internalHost}`);
    if (onIdpNow) process.exit(2);
    if (err.message && /Timeout|waitForSelector|locator/.test(err.message)) process.exit(3);
    process.exit(1);
  } finally {
    await browser.close().catch(() => {});
  }
})();
