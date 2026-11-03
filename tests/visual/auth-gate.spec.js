const { expect, test } = require('@playwright/test');

// Covers the sign-in wall added in Fase 1 (see
// docs/102_admin_panel_and_user_auth.md): nothing in .app-shell -- toolbar,
// diagram, the multi-MB lineage payload -- should load or become visible
// until a session exists. Runs against the real backend/scripts/lineage_web_server.py
// (see playwright.config.js's webServer), not the standalone export, since
// the standalone export intentionally has no server and skips this gate
// entirely (see the isStandalone check in app.js's init()).

test.describe('auth gate', () => {
  test('blocks the app and shows the sign-in screen when signed out', async ({ page }) => {
    await page.goto('/index.html', { waitUntil: 'load' });
    await expect(page.locator('#authGate')).toBeVisible();
    await expect(page.locator('main.app-shell')).toBeHidden();
    await expect(page.locator('.auth-gate-title')).toHaveText(/Inicia sesión/);
    await expect(page.locator('#authGateSignInButton')).toBeVisible();
  });

  test('/api/auth/me returns 401 with no session cookie', async ({ request }) => {
    const response = await request.get('/api/auth/me');
    expect(response.status()).toBe(401);
  });

  test('clicking sign in starts a real device-code flow with a code and a link', async ({ page }) => {
    await page.goto('/index.html', { waitUntil: 'load' });
    await page.click('#authGateSignInButton');
    await expect(page.locator('#authGateDeviceCode')).toBeVisible({ timeout: 15000 });

    const userCode = await page.locator('#authGateUserCode').textContent();
    expect(userCode).toMatch(/^[A-Z0-9]+$/);

    const link = await page.locator('#authGateVerificationLink').getAttribute('href');
    expect(link).toMatch(/^https:\/\//);
  });

  test('cancel hides the device-code panel and re-enables the sign-in button', async ({ page }) => {
    await page.goto('/index.html', { waitUntil: 'load' });
    await page.click('#authGateSignInButton');
    await expect(page.locator('#authGateDeviceCode')).toBeVisible({ timeout: 15000 });

    await page.click('#authGateCancelButton');
    await expect(page.locator('#authGateDeviceCode')).toBeHidden();
    await expect(page.locator('#authGateSignInButton')).toBeEnabled();
  });

  test('admin and full-scan endpoints reject anonymous requests', async ({ request }) => {
    const adminSettings = await request.get('/api/admin/settings');
    expect(adminSettings.status()).toBe(401);

    const scanStop = await request.post('/api/scan-stop');
    expect([401, 409]).toContain(scanStop.status());
  });
});
