const fs = require('fs');
const { defineConfig, devices } = require('@playwright/test');

const port = process.env.LINEAGE_VISUAL_PORT || '8765';
const systemChromium = ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome']
  .find(candidate => fs.existsSync(candidate));
const chromiumExecutable = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || systemChromium || undefined;
const jsonOutput = process.env.PLAYWRIGHT_JSON_OUTPUT_NAME || 'analysis/visual-validation/playwright-results.json';

module.exports = defineConfig({
  testDir: './tests/visual',
  timeout: 70000,
  expect: {
    timeout: 20000
  },
  fullyParallel: false,
  reporter: [
    ['list'],
    ['json', { outputFile: jsonOutput }]
  ],
  outputDir: 'analysis/visual-validation/test-results',
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    acceptDownloads: true,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    launchOptions: chromiumExecutable ? { executablePath: chromiumExecutable } : undefined
  },
  webServer: {
    // The real app server, not a bare static file server: the standalone
    // export tests below don't need the /api/* surface, but the auth-gate
    // tests do, and reuseExistingServer means this is a no-op whenever a
    // developer already has backend/scripts/lineage_web_server.py running
    // on this port (the common case), so this only changes behavior for a
    // cold CI/fresh-checkout run.
    command: `python backend/scripts/lineage_web_server.py --port ${port} --bind 127.0.0.1 --directory frontend/semantic-lineage`,
    url: `http://127.0.0.1:${port}/standalone.html`,
    reuseExistingServer: true,
    timeout: 120000
  },
  projects: [
    {
      name: 'desktop-chromium',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1440, height: 950 }
      }
    },
    {
      name: 'mobile-chromium',
      use: {
        ...devices['Pixel 7'],
        viewport: { width: 412, height: 915 }
      }
    }
  ]
});
