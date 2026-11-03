const fs = require('fs');
const path = require('path');
const { expect, test } = require('@playwright/test');

const outputDir = path.join(process.cwd(), 'analysis', 'visual-validation');

function safeName(value) {
  return value.replace(/[^a-z0-9_-]+/gi, '-').toLowerCase();
}

async function waitForExplorer(page) {
  await page.goto('/standalone.html', { waitUntil: 'domcontentloaded' });
  await expect(page.locator('#pageTitle')).toHaveText(/Explorador de linaje|Lineage Explorer/);
  await expect(page.locator('.workspace-card').first()).toBeVisible();
  await expect(page.locator('.semantic-board')).toBeVisible();
  await expect(page.locator('.semantic-model-card').first()).toBeVisible();
}

async function expectNonBlankCanvas(page) {
  const signal = await page.evaluate(async () => {
    const canvas = document.getElementById('lineageScene');
    if (!canvas) return { width: 0, height: 0, nonBlank: 0 };
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const ctx = canvas.getContext('2d');
    const width = canvas.width;
    const height = canvas.height;
    if (!ctx || width === 0 || height === 0) return { width, height, nonBlank: 0 };
    const sampleWidth = Math.min(width, 240);
    const sampleHeight = Math.min(height, 180);
    const data = ctx.getImageData(0, 0, sampleWidth, sampleHeight).data;
    let nonBlank = 0;
    for (let index = 0; index < data.length; index += 4) {
      if (data[index] || data[index + 1] || data[index + 2] || data[index + 3]) nonBlank += 1;
    }
    return { width, height, nonBlank };
  });
  expect(signal.width).toBeGreaterThan(0);
  expect(signal.height).toBeGreaterThan(0);
  expect(signal.nonBlank).toBeGreaterThan(0);
}

async function expectSceneDisabled(page) {
  await expect(page.locator('#sceneToggleButton')).toHaveCount(0);
  const signal = await page.evaluate(() => {
    const canvas = document.getElementById('lineageScene');
    return {
      bodyDisabled: document.body.classList.contains('scene-disabled'),
      hasCanvas: Boolean(canvas),
      opacity: canvas ? window.getComputedStyle(canvas).opacity : ''
    };
  });
  expect(signal.hasCanvas).toBe(true);
  expect(signal.bodyDisabled).toBe(true);
  expect(Number.parseFloat(signal.opacity)).toBe(0);
}

async function capture(page, testInfo, label) {
  fs.mkdirSync(outputDir, { recursive: true });
  const fileName = `${safeName(testInfo.project.name)}-${label}.png`;
  const target = path.join(outputDir, fileName);
  await page.screenshot({ path: target, fullPage: true });
  expect(fs.statSync(target).size).toBeGreaterThan(10000);
  await testInfo.attach(label, {
    path: target,
    contentType: 'image/png'
  });
}

test('lineage explorer renders a populated flow without 3D control', async ({ page }, testInfo) => {
  await waitForExplorer(page);

  await page.locator('#clearWorkspacesButton').click();
  await page.locator('#searchInput').fill('Corporate Affairs [DEV]');
  await page.locator('.workspace-card', { hasText: 'Corporate Affairs [DEV]' }).first().click();
  await expect(page.locator('.semantic-board')).toBeVisible();
  await expect(page.locator('.semantic-lineage-row').first()).toBeVisible();
  await expect(page.locator('.semantic-source-card').first()).toBeVisible();
  await expect(page.locator('.semantic-report-card').first()).toBeVisible();
  await expect(page.locator('.ms-icon.icon-semantic').first()).toBeVisible();
  await expect(page.locator('.ms-icon.icon-report').first()).toBeVisible();
  const officialIconSignal = await page.evaluate(() => {
    return ['icon-semantic', 'icon-report'].map(name => {
      const icon = document.querySelector(`.ms-icon.${name}`);
      if (!icon) return { name, found: false };
      const style = window.getComputedStyle(icon);
      const before = window.getComputedStyle(icon, '::before');
      return {
        name,
        found: true,
        backgroundImage: style.backgroundImage,
        width: Number.parseFloat(style.width),
        height: Number.parseFloat(style.height),
        beforeContent: before.content,
        beforeDisplay: before.display
      };
    });
  });
  for (const signal of officialIconSignal) {
    expect(signal.found).toBe(true);
    expect(signal.backgroundImage).toContain('/assets/fabric-icons/');
    expect(signal.width).toBeGreaterThanOrEqual(16);
    expect(signal.height).toBeGreaterThanOrEqual(16);
    expect(signal.beforeContent === 'none' || signal.beforeDisplay === 'none').toBe(true);
  }
  await expect(page.locator('.semantic-model-footprint').first()).toBeVisible();
  await page.locator('.semantic-model-card').first().click();
  await expect(page.locator('#detailContent')).toContainText(/Tablas semánticas|Semantic tables/);
  await expect(page.locator('.semantic-object-more summary').first()).toBeVisible();
  await expect(page.locator('.semantic-object-pill')).toHaveCount(0);
  await expect(page.locator('.semantic-object-more summary').first()).toContainText(/objetos fuente|source objects/i);
  await expect(page.locator('.semantic-object-more summary').first()).not.toContainText(/objetos más|more objects/i);
  await page.locator('.semantic-object-more summary').first().click();
  await expect(page.locator('.semantic-object-schema').first()).toBeVisible();
  await expect(page.locator('.semantic-object-row').first()).toBeVisible();
  const firstSourceObjectName = (await page.locator('.semantic-object-row strong').first().textContent() || '').trim();
  await page.locator('.semantic-object-row').first().click();
  await expect(page.locator('.semantic-object-more[open]').first()).toBeVisible();
  await expect(page.locator('#detailContent')).toContainText(/Objetos por schema|Objects by schema/);
  if (firstSourceObjectName) {
    await expect(page.locator('#detailContent')).toContainText(firstSourceObjectName);
  }

  const nativeScrollSignal = await page.locator('#graphViewport').evaluate(viewport => {
    const style = window.getComputedStyle(viewport);
    viewport.scrollLeft = 0;
    viewport.scrollTop = 0;
    return {
      overflowX: style.overflowX,
      overflowY: style.overflowY,
      canScrollX: viewport.scrollWidth > viewport.clientWidth,
      canScrollY: viewport.scrollHeight > viewport.clientHeight,
      left: viewport.scrollLeft,
      top: viewport.scrollTop
    };
  });
  expect(nativeScrollSignal.overflowX).toBe('auto');
  expect(nativeScrollSignal.overflowY).toBe('auto');
  expect(nativeScrollSignal.left + nativeScrollSignal.top).toBe(0);

  if (testInfo.project.name === 'desktop-chromium') {
    expect(nativeScrollSignal.canScrollX || nativeScrollSignal.canScrollY).toBe(true);
    const dragPoint = await page.locator('#graphViewport').evaluate(viewport => {
      const blocked = '.node-card, .impact-board, .planning-source-selector, .semantic-object-more, .semantic-object-pill, .semantic-object-row, .filter-menu';
      const rect = viewport.getBoundingClientRect();
      for (let y = rect.top + 34; y < rect.bottom - 34; y += 38) {
        for (let x = rect.left + 34; x < rect.right - 34; x += 38) {
          const element = document.elementFromPoint(x, y);
          if (element && !element.closest(blocked)) return { x, y };
        }
      }
      return { x: rect.left + 42, y: rect.top + 42 };
    });
    await page.mouse.move(dragPoint.x, dragPoint.y);
    await page.mouse.down();
    await page.mouse.move(dragPoint.x - 110, dragPoint.y - 120, { steps: 6 });
    await page.mouse.up();
    const draggedScrollSignal = await page.locator('#graphViewport').evaluate(viewport => ({
      left: viewport.scrollLeft,
      top: viewport.scrollTop
    }));
    expect(draggedScrollSignal.left + draggedScrollSignal.top).toBeGreaterThan(0);
  }

  const modelBox = await page.locator('.semantic-model-card').first().boundingBox();
  expect(modelBox).not.toBeNull();
  expect(modelBox.width).toBeLessThanOrEqual(430);

  const graphHeaderLayout = await page.evaluate(() => {
    const header = document.querySelector('.graph-header');
    const surface = document.querySelector('.graph-surface');
    const copy = document.querySelector('.graph-copy');
    const legend = document.querySelector('#modeLegend');
    const controls = document.querySelector('.viewport-controls');
    if (!header || !surface || !copy || !legend || !controls) return { ok: false };
    const headerBox = header.getBoundingClientRect();
    const surfaceBox = surface.getBoundingClientRect();
    const copyBox = copy.getBoundingClientRect();
    const legendBox = legend.getBoundingClientRect();
    const controlsBox = controls.getBoundingClientRect();
    const insideSurface = controlsBox.left >= surfaceBox.left - 1 &&
      controlsBox.right <= surfaceBox.right + 1 &&
      legendBox.right <= surfaceBox.right + 1;
    const controlsBelowTitle = controlsBox.top >= copyBox.bottom - 1;
    const desktopCleanLine = window.innerWidth <= 840 ||
      (controlsBox.left <= headerBox.left + 12 && controlsBox.height <= 44);
    return { ok: insideSurface && controlsBelowTitle && desktopCleanLine };
  });
  expect(graphHeaderLayout.ok).toBe(true);

  if (testInfo.project.name === 'desktop-chromium') {
    await page.locator('#fitButton').click();
    for (let index = 0; index < 10; index += 1) {
      await page.locator('#zoomOutButton').click();
    }
    const zoomedOutScale = await page.locator('#treeStage').evaluate(stage => {
      const zoom = Number.parseFloat(stage.style.zoom);
      if (Number.isFinite(zoom)) return zoom;
      const matrix = new DOMMatrixReadOnly(window.getComputedStyle(stage).transform);
      return matrix.a || 1;
    });
    expect(zoomedOutScale).toBeLessThanOrEqual(0.2);
    await page.locator('#fitButton').click();
  }

  await expectSceneDisabled(page);
  await capture(page, testInfo, 'semantic-flow');
});

test('semantic deployment-pipeline rows keep cards contained and object schemas expandable', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'The deployment-pipeline semantic layout is covered on desktop.');

  await waitForExplorer(page);
  await page.locator('#clearWorkspacesButton').click();
  await page.locator('#searchInput').fill('DPL_Community_Programs');
  await page.locator('.workspace-card', { hasText: 'DPL_Community_Programs' }).first().click();
  await expect(page.locator('.semantic-lineage-row').first()).toBeVisible();
  await expect.poll(async () => page.locator('.semantic-source-card').count()).toBeGreaterThan(1);

  const overflow = await page.evaluate(() => {
    const cards = Array.from(document.querySelectorAll('.semantic-source-main, .semantic-model-card, .semantic-report-card'));
    return cards.filter(card => {
      const cardBox = card.getBoundingClientRect();
      return Array.from(card.children).some(child => {
        const childBox = child.getBoundingClientRect();
        return childBox.right > cardBox.right + 1 || childBox.bottom > cardBox.bottom + 1;
      });
    }).length;
  });
  expect(overflow).toBe(0);

  await expect(page.locator('.semantic-object-pill')).toHaveCount(0);
  await expect(page.locator('.semantic-object-more summary').first()).toContainText(/objetos fuente|source objects/i);
  await page.locator('.semantic-object-more summary').first().click();
  await expect(page.locator('.semantic-object-schema').first()).toBeVisible();
  await expect(page.locator('.semantic-object-row').first()).toBeVisible();
  await capture(page, testInfo, 'semantic-pipeline-contained');
});

test('lineage diagram filters expose clean labels and checkbox object selection', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'Diagram filter checklist is covered on desktop.');

  await waitForExplorer(page);
  await expect(page.locator('#sceneToggleButton')).toHaveCount(0);
  await page.locator('#filterButton').click();
  await expect(page.locator('#filterMenu')).toBeVisible();
  await expect(page.locator('#diagramObjectChecklist')).toBeVisible();
  await expect(page.locator('[data-diagram-object-all]')).toBeChecked();
  await expect.poll(async () => page.locator('[data-diagram-object-key]').count()).toBeGreaterThan(0);

  const sourceFilterText = await page.locator('#sourceTypeFilter').textContent();
  expect(sourceFilterText || '').not.toMatch(/FabricOrSQL|LakehouseTable/);
  expect(sourceFilterText || '').toMatch(/SQL Server|Lakehouse|SQL endpoint/i);
  const objectTypeText = await page.locator('#itemTypeFilter').textContent();
  expect(objectTypeText || '').toMatch(/Tabla|Vista|Procedimiento|Archivo|Table|View|Stored procedure|File/i);

  await page.locator('[data-diagram-object-all]').uncheck();
  await expect(page.locator('[data-diagram-object-all]')).not.toBeChecked();
  await expect.poll(async () => page.locator('.semantic-source-card').count()).toBe(0);

  const firstFilteredObjectLabel = ((await page.locator('.diagram-object-checklist-body .diagram-object-check strong').first().textContent()) || '').trim();
  await page.locator('[data-diagram-object-key]').first().check();
  await expect(page.locator('[data-diagram-object-all]')).not.toBeChecked();
  await expect.poll(async () => page.locator('.semantic-source-card').count()).toBeGreaterThan(0);
  await page.locator('#filterButton').click();
  await page.locator('.semantic-model-card').first().click();
  await expect(page.locator('#detailExcelExport')).toBeVisible();
  const [filteredExcelDownload] = await Promise.all([
    page.waitForEvent('download'),
    page.locator('#detailExcelExport').click()
  ]);
  expect(filteredExcelDownload.suggestedFilename()).toMatch(/\.xls$/);
  const filteredExcelPath = await filteredExcelDownload.path();
  expect(filteredExcelPath).toBeTruthy();
  const filteredExcelContent = fs.readFileSync(filteredExcelPath, 'utf8');
  expect(filteredExcelContent).toMatch(/DP \/ WS|NB \/ item|Tabla \/ vista \/ SP \/ archivo|Lineage list|Lista de linaje/);
  if (firstFilteredObjectLabel) {
    expect(filteredExcelContent).toContain(firstFilteredObjectLabel);
  }

  await page.locator('[data-mode="notebooks"]').click();
  await page.locator('#filterButton').click();
  await expect(page.locator('#diagramObjectChecklist')).toBeVisible();
  await expect.poll(async () => page.locator('[data-diagram-object-key]').count()).toBeGreaterThan(0);
  const notebookSourceFilterText = await page.locator('#sourceTypeFilter').textContent();
  expect(notebookSourceFilterText || '').not.toMatch(/FabricOrSQL|LakehouseTable/);
  const notebookLineageIcons = await page.evaluate(() => ({
    lakehouseSourceIcon: iconClassForNode({
      kind: 'source',
      data: {
        item_type: 'NotebookObjectLineage',
        source_type: 'LakehouseTable',
        label: 'LH_Northwind_Gold',
        database: 'LH_Northwind_Gold'
      }
    }),
    lakehouseSourceType: nodeTypeClass({
      kind: 'source',
      data: {
        item_type: 'NotebookObjectLineage',
        source_type: 'LakehouseTable',
        label: 'LH_Northwind_Gold',
        database: 'LH_Northwind_Gold'
      }
    }),
    tableObjectIcon: iconClassForNode({
      kind: 'object',
      data: { type: 'table_or_view', raw_object_type: 'LakehouseTable', source_type: 'LakehouseTable' }
    }),
    viewObjectIcon: iconClassForNode({ kind: 'object', data: { type: 'view', source_type: 'SQL' } }),
    procedureObjectIcon: iconClassForNode({ kind: 'object', data: { type: 'stored_procedure', source_type: 'SQL' } }),
    fileObjectIcon: iconClassForNode({ kind: 'object', data: { type: 'file', source_type: 'File' } })
  }));
  expect(notebookLineageIcons.lakehouseSourceIcon).toBe('icon-lakehouse');
  expect(notebookLineageIcons.lakehouseSourceType).toBe('type-lakehouse');
  expect(notebookLineageIcons.tableObjectIcon).toBe('icon-table');
  expect(notebookLineageIcons.viewObjectIcon).toBe('icon-view');
  expect(notebookLineageIcons.procedureObjectIcon).toBe('icon-procedure');
  expect(notebookLineageIcons.fileObjectIcon).toBe('icon-file');
  await capture(page, testInfo, 'diagram-filter-checklist');
});

test('copyjobs mode, filter panel, and planning view stay interactive', async ({ page }, testInfo) => {
  await waitForExplorer(page);

  await page.locator('[data-mode="copyjobs"]').click();
  await expect(page.locator('.workspace-card').first()).toBeVisible();
  await expect(page.locator('.flow-card.workspace-root, .flow-card.deployment-root').first()).toBeVisible();
  await expect(page.locator('.flow-edge').first()).toBeVisible();

  const copyRootBox = await page.locator('.flow-card.workspace-root, .flow-card.deployment-root').first().boundingBox();
  expect(copyRootBox).not.toBeNull();
  expect(copyRootBox.width).toBeLessThanOrEqual(430);

  await page.locator('#filterButton').click();
  await expect(page.locator('#filterMenu')).toBeVisible();
  const sourceOptionCount = await page.locator('#sourceTypeFilter option').count();
  expect(sourceOptionCount).toBeGreaterThan(0);
  await page.locator('#filterButton').click();

  const copyJobFixture = await page.evaluate(() => {
    const data = window.LINEAGE_EXPLORER_DATA || window.SEMANTIC_LINEAGE_DATA;
    for (const workspace of data.workspaces || []) {
      for (const item of workspace.copyjobs || []) {
        const sources = item.sources || [];
        const readSource = sources.find(source =>
          (source.source_type === 'SQL' || source.item_type === 'External' || source.source_type === 'FabricOrSQL') &&
          (source.objects || []).length > 0
        );
        const writeTarget = sources.find(source =>
          (source.source_type === 'Fabric' || source.item_type === 'Lakehouse' || /lakehouse|^lh_/i.test(`${source.label || ''} ${source.database || ''}`)) &&
          !(source.objects || []).length
        );
        if (readSource && writeTarget) {
          return {
            workspaceName: workspace.name,
            copyJobLabel: item.label,
            readSourceLabel: readSource.label || readSource.database,
            writeTargetLabel: writeTarget.label || writeTarget.database
          };
        }
      }
    }
    return null;
  });
  expect(copyJobFixture).toBeTruthy();
  await page.locator('#clearWorkspacesButton').click();
  await page.locator('#searchInput').fill(copyJobFixture.workspaceName);
  await page.locator('.workspace-card', { hasText: copyJobFixture.workspaceName }).first().click();
  const copyJobCard = page.locator('.flow-card.type-copyjob', { hasText: copyJobFixture.copyJobLabel }).first();
  await expect(copyJobCard).toBeVisible();
  await copyJobCard.click();
  const readGroup = page.locator('.flow-card.type-read-source', { hasText: /Orígenes leídos|Read sources/ }).first();
  const writeGroup = page.locator('.flow-card.type-write-target', { hasText: /Destinos escritos|Write targets/ }).first();
  await expect(readGroup).toBeVisible();
  await expect(writeGroup).toBeVisible();
  await readGroup.click();
  await expect(page.locator('.flow-card.type-sql, .flow-card.source', { hasText: copyJobFixture.readSourceLabel }).first()).toBeVisible();
  await writeGroup.click();
  await expect(page.locator('.flow-card.type-lakehouse, .flow-card.source', { hasText: copyJobFixture.writeTargetLabel }).first()).toBeVisible();

  await capture(page, testInfo, 'copyjobs-flow');

  await page.locator('[data-mode="semantic"]').click();
  await page.locator('#clearWorkspacesButton').click();
  await page.locator('#searchInput').fill('DP-Northwind_Pro');
  await page.locator('.workspace-card', { hasText: 'DP-Northwind_Pro' }).first().click();
  await page.locator('#scheduleButton').click();
  await expect(page.locator('.planning-canvas-board')).toBeVisible();
  await expect(page.locator('.planning-summary')).toBeVisible();
  await expect(page.locator('.planning-source-selector')).toBeVisible();
  await expect(page.locator('#planningSourceSearch')).toBeVisible();
  await expect(page.locator('.planning-canvas')).toBeVisible();
  await expect(page.locator('.planning-column').first()).toBeVisible();
  await expect(page.locator('.planning-card').first()).toBeVisible();
  await expect(page.locator('.planning-card.planning-stage-input')).toHaveCount(0);
  await expect(page.locator('.planning-card.planning-stage-store')).toHaveCount(0);
  await expect(page.locator('.planning-card.type-report')).toHaveCount(0);
  await expect(page.locator('.planning-card.type-semantic').first()).toBeVisible();
  await page.locator('.planning-source-chip').first().click();
  await expect(page.locator('.planning-source-chip.active').first()).toBeVisible();
  await expect(page.locator('.planning-canvas-board')).toContainText(/Oleada|Wave/);
  await expect(page.locator('.planning-canvas-board')).toContainText(/Refresh modelos|Model refresh/);
  await expect(page.locator('.planning-canvas-board')).not.toContainText(/Consumo validado|Validated consumption/);
  await expect(page.locator('.planning-edge-read, .planning-edge-write, .planning-edge-report')).toHaveCount(0);
  await expect.poll(async () => page.locator('.planning-edge').count()).toBeGreaterThan(0);
  await capture(page, testInfo, 'planning-board');
});

test('reverse impact view shows affected items and details', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'The reverse-impact board is covered on desktop.');
  testInfo.setTimeout(120000);

  await waitForExplorer(page);

  await page.locator('#impactButton').click();
  await expect(page.locator('.impact-board')).toBeVisible();
  await expect(page.locator('.impact-summary')).toHaveCount(0);
  await expect(page.locator('.impact-table')).toBeVisible();
  await expect(page.locator('.impact-table-row').first()).toBeVisible();
  const semanticImpactHeader = await page.locator('.impact-table thead').textContent();
  expect(semanticImpactHeader || '').toMatch(/objeto origen|source object/i);
  expect(semanticImpactHeader || '').toMatch(/modelos|models/i);
  expect(semanticImpactHeader || '').toMatch(/informes|reports/i);
  expect(semanticImpactHeader || '').not.toMatch(/notebooks|pipelines|otros elementos|other elements/i);
  await expect(page.locator('#graphTitle')).toHaveText(/Impacto inverso|Reverse impact/);
  await expect(page.locator('#graphSubtitle')).not.toContainText(/Objetos origen|Items directos|Informes descendentes|Tipos exactos|Tipos pendientes|Source objects|Direct items|Downstream reports|Exact types|Pending types/i);
  await page.locator('#impactFocusObjectSearch').click();
  await page.keyboard.type('dbo');
  await expect(page.locator('#impactFocusObjectSearch')).toBeFocused();
  await expect(page.locator('#impactFocusObjectSearch')).toHaveValue('dbo');

  const sourceObjectCount = await page.evaluate(() => {
    const impact = window.OBJECT_IMPACT_DATA || {};
    return impact.summary ? impact.summary.source_objects || 0 : 0;
  });
  expect(sourceObjectCount).toBeGreaterThan(0);

  await expect(page.locator('.impact-focus-panel')).toBeVisible();
  await expect(page.locator('.impact-filter-chip').first()).toBeVisible();
  await page.locator('.impact-focus-search input').fill('dbo.CUSTOMER');
  await expect(page.locator('.impact-focus-search input')).toHaveValue('dbo.CUSTOMER');
  await expect.poll(async () => page.locator('.impact-table-row').count()).toBeGreaterThan(0);
  await expect(page.locator('.impact-table-row').first()).toContainText(/dbo\.CUSTOMER|CUSTOMER/i);
  const impactSourceColumnAlignment = await page.locator('.impact-table-row').first().evaluate(row => {
    const cell = row.querySelector('td:first-child');
    const button = row.querySelector('.impact-table-object');
    const children = button ? Array.from(button.children) : [];
    if (!cell || !button || !children.length) return { ok: false };
    const cellBox = cell.getBoundingClientRect();
    const buttonBox = button.getBoundingClientRect();
    const childLefts = children
      .map(child => child.getBoundingClientRect().left)
      .filter(left => Number.isFinite(left));
    const alignedToButton = childLefts.every(left => Math.abs(left - buttonBox.left) <= 2);
    return {
      ok: Math.abs(buttonBox.left - cellBox.left) <= 10 && alignedToButton,
      cellLeft: cellBox.left,
      buttonLeft: buttonBox.left,
      childLefts
    };
  });
  expect(impactSourceColumnAlignment.ok).toBe(true);
  const impactMatchListLayout = await page.locator('.impact-filter-chip-group:not(.selected)').first().evaluate(group => {
    const groupBox = group.getBoundingClientRect();
    const chips = Array.from(group.querySelectorAll('.impact-filter-chip'));
    return {
      count: chips.length,
      vertical: chips.every((chip, index) => index === 0 || chip.getBoundingClientRect().top > chips[index - 1].getBoundingClientRect().top),
      oneLine: chips.every(chip => chip.getBoundingClientRect().height <= 38),
      fullWidth: chips.every(chip => chip.getBoundingClientRect().width >= groupBox.width - 12),
      leftAligned: chips.every(chip => Array.from(chip.children).every(child => child.getBoundingClientRect().left >= chip.getBoundingClientRect().left))
    };
  });
  expect(impactMatchListLayout.count).toBeGreaterThan(0);
  expect(impactMatchListLayout.count).toBeLessThanOrEqual(5);
  expect(impactMatchListLayout.vertical).toBe(true);
  expect(impactMatchListLayout.oneLine).toBe(true);
  expect(impactMatchListLayout.fullWidth).toBe(true);
  expect(impactMatchListLayout.leftAligned).toBe(true);
  await page.locator('.impact-filter-chip').first().click();
  await expect(page.locator('.impact-filter-chip.active').first()).toBeVisible();
  const impactSelectedListLayout = await page.locator('.impact-filter-chip-group.selected').first().evaluate(group => {
    const groupBox = group.getBoundingClientRect();
    const chip = group.querySelector('.impact-filter-chip');
    const chipBox = chip ? chip.getBoundingClientRect() : { height: 0, width: 0 };
    return {
      hasChip: Boolean(chip),
      oneLine: chipBox.height <= 38,
      fullWidth: chipBox.width >= groupBox.width - 12
    };
  });
  expect(impactSelectedListLayout.hasChip).toBe(true);
  expect(impactSelectedListLayout.oneLine).toBe(true);
  expect(impactSelectedListLayout.fullWidth).toBe(true);
  await page.locator('.impact-focus-panel > button').click();
  await expect(page.locator('.impact-focus-search input')).toHaveValue('');

  await page.locator('.impact-focus-search input').fill('dbo.CUSTOMER');
  await expect(page.locator('.impact-focus-search input')).toHaveValue('dbo.CUSTOMER');
  await expect.poll(async () => page.locator('.impact-table-row').count()).toBeGreaterThan(0);
  await expect(page.locator('.impact-table-row').first()).toContainText(/dbo\.CUSTOMER|CUSTOMER/i);
  await page.locator('.impact-table-object').first().click();
  await expect(page.locator('#detailContent')).toContainText(/Impacto directo|Direct impact/);
  await expect(page.locator('#detailContent')).toContainText(/Metadatos origen|Source metadata/);
  await expect(page.locator('#detailPdfExport')).toBeVisible();
  await expect(page.locator('#detailPngExport')).toBeVisible();
  await expect(page.locator('#detailExcelExport')).toBeVisible();
  const [impactExcelDownload] = await Promise.all([
    page.waitForEvent('download'),
    page.locator('#detailExcelExport').click()
  ]);
  expect(impactExcelDownload.suggestedFilename()).toMatch(/\.xls$/);
  const impactExcelDownloadPath = await impactExcelDownload.path();
  expect(impactExcelDownloadPath).toBeTruthy();
  const impactExcelContent = fs.readFileSync(impactExcelDownloadPath, 'utf8');
  expect(impactExcelContent).toContain('<table>');
  expect(impactExcelContent).toMatch(/dbo\.CUSTOMER|CUSTOMER/i);
  expect(impactExcelContent).toMatch(/direct_impact|downstream_report/);
  const [impactDownload] = await Promise.all([
    page.waitForEvent('download'),
    page.locator('#detailPdfExport').click()
  ]);
  expect(impactDownload.suggestedFilename()).toMatch(/\.pdf$/);
  const impactDownloadPath = await impactDownload.path();
  expect(impactDownloadPath).toBeTruthy();
  const impactPdfBuffer = fs.readFileSync(impactDownloadPath);
  expect(impactPdfBuffer.subarray(0, 5).toString()).toBe('%PDF-');
  expect(impactPdfBuffer.length).toBeGreaterThan(25000);

  const expandableCell = page.locator('.impact-table-row', { has: page.locator('.impact-more-button') }).first();
  if (await expandableCell.count()) {
    const visibleItemsBefore = await expandableCell.locator('.impact-table-item').count();
    await expandableCell.locator('.impact-more-button').first().click();
    await expect.poll(async () => expandableCell.locator('.impact-table-item').count()).toBeGreaterThan(visibleItemsBefore);
    await expect(expandableCell.locator('.impact-more-button', { hasText: /Ver menos|Show less/ }).first()).toBeVisible();
  }

  await capture(page, testInfo, 'reverse-impact');
});

test('notebook impact limits matching objects in focus list', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'Notebook impact focus limits are covered on desktop.');

  await waitForExplorer(page);

  await page.locator('[data-mode="notebooks"]').click();
  await page.locator('#impactButton').click();
  await expect(page.locator('.impact-board')).toBeVisible();
  await expect(page.locator('.impact-table')).toBeVisible();
  const notebookImpactHeader = await page.locator('.impact-table thead').textContent();
  expect(notebookImpactHeader || '').toMatch(/objeto origen|source object/i);
  expect(notebookImpactHeader || '').toMatch(/notebooks/i);
  expect(notebookImpactHeader || '').not.toMatch(/modelos|models|pipelines|otros elementos|other elements/i);

  await page.locator('#impactFocusObjectSearch').fill('dbo');
  await expect(page.locator('#impactFocusObjectSearch')).toHaveValue('dbo');
  await expect(page.locator('.impact-filter-chip').first()).toBeVisible();
  const matchingNotebookObjects = await page.locator('.impact-filter-chip-group:not(.selected) .impact-filter-chip').count();
  expect(matchingNotebookObjects).toBeGreaterThan(0);
  expect(matchingNotebookObjects).toBeLessThanOrEqual(5);
});

test('multi-entry selection keeps grouped roots interactive', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'The multi-workspace convergence check is covered on desktop.');

  await waitForExplorer(page);
  await page.locator('[data-mode="pipelines"]').click();
  await expect(page.locator('.flow-board')).toBeVisible();

  await page.locator('#selectAllWorkspacesButton').click();
  await expect(page.locator('#workspacePanelSubtitle')).toContainText(/seleccionados|selected/);
  await expect.poll(async () => page.locator('.flow-card.workspace-root, .flow-card.deployment-root').count()).toBeGreaterThan(1);

  const expandableRoot = page.locator('.flow-card.deployment-root').first();
  if (await expandableRoot.count()) {
    if (!await page.locator('.flow-card.type-deployment-stage').first().isVisible().catch(() => false)) {
      await expandableRoot.click();
    }
    await expect(page.locator('.flow-card.type-deployment-stage').first()).toBeVisible();
  }

  await capture(page, testInfo, 'multi-entry-grouped');
});

test('deployment pipeline grouping and no-pipeline marker are visible', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'The deployment-pipeline grouping check is covered on desktop.');

  await waitForExplorer(page);
  await page.locator('[data-mode="pipelines"]').click();
  await expect(page.locator('.flow-board')).toBeVisible();

  await expect(page.locator('.workspace-card.pipeline-entry').first()).toBeVisible();
  await expect(page.locator('.workspace-card.pipeline-entry .icon-deployment').first()).toBeVisible();
  await expect(page.locator('.workspace-card.pipeline-entry .pipeline-stage-rail').first()).toBeVisible();
  await expect(page.locator('.workspace-card.pipeline-entry .pipeline-stage-pill.production-stage').first()).toBeVisible();
  await expect(page.locator('.workspace-card.standalone-entry .icon-deployment-off').first()).toBeVisible();
  const proWorkspaceFilter = page.locator('[data-workspace-env-filter="PRO"]');
  await expect(proWorkspaceFilter).toBeVisible();
  await proWorkspaceFilter.click();
  await expect(proWorkspaceFilter).toHaveClass(/active/);
  await expect(page.locator('.workspace-card.standalone-entry .icon-deployment-off').first()).toBeVisible();
  await expect(page.locator('.workspace-card.pipeline-entry').first()).toBeVisible();
  await expect.poll(async () => page.locator('.workspace-card.pipeline-entry .pipeline-stage-pill:not(.production-stage)').count()).toBe(0);
  await proWorkspaceFilter.click();
  await expect(proWorkspaceFilter).not.toHaveClass(/active/);

  const pipelineCard = page.locator('.workspace-card.pipeline-entry').first();
  if (!(await pipelineCard.evaluate(element => element.classList.contains('active')))) {
    await pipelineCard.click();
  }
  await expect(page.locator('.flow-card.deployment-root').first()).toBeVisible();
  await expect(page.locator('.flow-card.type-deployment-stage').first()).toBeVisible();
  await expect(page.locator('.diagram-stage-selector').first()).toBeVisible();

  const stageButtons = page.locator('.diagram-stage-button:not(.all-stage)');
  const stageButtonCount = await stageButtons.count();
  test.skip(stageButtonCount < 2, 'No multi-stage deployment pipeline is available in the fixture.');
  const allStageButton = page.locator('.diagram-stage-button.all-stage').first();
  const initialStageCardCount = await page.locator('.flow-card.type-deployment-stage').count();
  expect(initialStageCardCount).toBeGreaterThan(1);
  await stageButtons.first().click();
  await expect(stageButtons.first()).toHaveClass(/active/);
  await expect.poll(async () => page.locator('.flow-card.type-deployment-stage').count()).toBe(1);
  await allStageButton.click();
  await expect(allStageButton).toHaveClass(/active/);
  await expect.poll(async () => page.locator('.flow-card.type-deployment-stage').count()).toBeGreaterThan(1);

  await capture(page, testInfo, 'deployment-pipeline-grouping');
});

test('all mode filters by item type and expands report lineage', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'The report lineage drilldown is covered on desktop.');

  await waitForExplorer(page);

  await page.locator('[data-mode="all"]').click();
  await page.locator('#filterButton').click();
  await expect(page.locator('#itemTypeFilter')).toBeVisible();
  const itemTypeOptionCount = await page.locator('#itemTypeFilter option').count();
  expect(itemTypeOptionCount).toBeGreaterThan(5);

  await page.locator('#itemTypeFilter').selectOption('Report');
  await page.locator('#filterButton').click();
  const reportWorkspaceName = await page.evaluate(() => {
    const data = window.LINEAGE_EXPLORER_DATA || window.SEMANTIC_LINEAGE_DATA;
    const workspace = (data.workspaces || []).find(candidate =>
      !(candidate.deployment_pipeline && candidate.deployment_pipeline.has_pipeline) &&
      (candidate.all || []).some(item => item.item_type === 'Report' && (item.models || []).length > 0)
    );
    return workspace ? workspace.name : '';
  });
  test.skip(!reportWorkspaceName, 'No standalone report workspace with model lineage is available in the fixture.');
  await page.locator('#clearWorkspacesButton').click();
  await page.locator('#searchInput').fill(reportWorkspaceName);
  await page.locator('.workspace-card', { hasText: reportWorkspaceName }).first().click();
  await expect(page.locator('.flow-card.report').first()).toBeVisible();
  await expect(page.locator('#graphSubtitle')).toContainText(/Informe|Report/);

  const firstReport = page.locator('.flow-card.report').first();
  await firstReport.click();
  const modelGroups = page.locator('.flow-card', { hasText: /Modelos usados|Used models/ });
  await expect(modelGroups.first()).toBeVisible();

  const semanticCountBefore = await page.locator('.flow-card.type-semantic').count();
  await modelGroups.first().click();
  await expect.poll(async () => page.locator('.flow-card.type-semantic').count()).toBeGreaterThan(semanticCountBefore);

  await page.locator('.flow-card.type-semantic').nth(semanticCountBefore).click();
  await expect(page.locator('.flow-card', { hasText: /Orígenes de datos|Data sources/ }).first()).toBeVisible();

  await capture(page, testInfo, 'all-report-lineage');
});

test('clean shell keeps reinvestigate hidden and detail PDF PNG exports visible', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'The clean shell and detail export check is covered on desktop.');

  await waitForExplorer(page);

  await expect(page.locator('#reinvestigateButton')).toHaveCount(0);
  await expect(page.locator('.topbar button')).toHaveCount(2);
  await expect(page.locator('#inspectionButton')).toBeVisible();
  await expect(page.locator('#inspectionButton')).toHaveClass(/active/);
  await expect(page.locator('#inspectionButton')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#impactButton')).not.toHaveClass(/active/);
  await expect(page.locator('#scheduleButton')).not.toHaveClass(/active/);
  await page.locator('#impactButton').click();
  await expect(page.locator('#impactButton')).toHaveClass(/active/);
  await expect(page.locator('#impactButton')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#inspectionButton')).not.toHaveClass(/active/);
  await expect(page.locator('#scheduleButton')).not.toHaveClass(/active/);
  await page.locator('#scheduleButton').click();
  await expect(page.locator('#scheduleButton')).toHaveClass(/active/);
  await expect(page.locator('#scheduleButton')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#inspectionButton')).not.toHaveClass(/active/);
  await expect(page.locator('#impactButton')).not.toHaveClass(/active/);
  await page.locator('#inspectionButton').click();
  await expect(page.locator('#inspectionButton')).toHaveClass(/active/);
  await expect(page.locator('#inspectionButton')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#impactButton')).not.toHaveClass(/active/);
  await expect(page.locator('#scheduleButton')).not.toHaveClass(/active/);
  await page.locator('.semantic-model-card').first().click();
  await expect(page.locator('#detailPdfExport')).toBeVisible();
  await expect(page.locator('#detailPngExport')).toBeVisible();
  await expect(page.locator('#detailExcelExport')).toBeVisible();
  await expect(page.locator('#detailCsvExport')).toHaveCount(0);
  await expect(page.locator('#detailContent .status-chip')).toHaveCount(0);
  await expect(page.locator('#detailContent')).toContainText(/Resumen|Overview/);
  await expect(page.locator('#detailContent')).toContainText(/Fuentes relacionadas|Related sources/);
  await expect(page.locator('#detailContent')).not.toContainText(/Confirmado|Confirmed|No confirmado|Unconfirmed|Probable|Likely|Confianza|Confidence|Baja evidencia|Low evidence|Calidad linaje|Lineage quality|Evidencia|Evidence/);
  const [download] = await Promise.all([
    page.waitForEvent('download'),
    page.locator('#detailPdfExport').click()
  ]);
  expect(download.suggestedFilename()).toMatch(/\.pdf$/);
  const downloadPath = await download.path();
  expect(downloadPath).toBeTruthy();
  const pdfBuffer = fs.readFileSync(downloadPath);
  expect(pdfBuffer.subarray(0, 5).toString()).toBe('%PDF-');
  expect(pdfBuffer.length).toBeGreaterThan(25000);
  const [pngDownload] = await Promise.all([
    page.waitForEvent('download'),
    page.locator('#detailPngExport').click()
  ]);
  expect(pngDownload.suggestedFilename()).toMatch(/\.png$/);
  const pngDownloadPath = await pngDownload.path();
  expect(pngDownloadPath).toBeTruthy();
  const pngBuffer = fs.readFileSync(pngDownloadPath);
  expect(pngBuffer.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))).toBe(true);
  const pngWidth = pngBuffer.readUInt32BE(16);
  const pngHeight = pngBuffer.readUInt32BE(20);
  expect(pngWidth).toBeGreaterThanOrEqual(2800);
  expect(pngHeight).toBeGreaterThanOrEqual(1500);
  expect(pngWidth * pngHeight).toBeGreaterThan(12000000);
  expect(pngBuffer.length).toBeGreaterThan(100000);
  const [excelDownload] = await Promise.all([
    page.waitForEvent('download'),
    page.locator('#detailExcelExport').click()
  ]);
  expect(excelDownload.suggestedFilename()).toMatch(/\.xls$/);
  const excelDownloadPath = await excelDownload.path();
  expect(excelDownloadPath).toBeTruthy();
  const excelContent = fs.readFileSync(excelDownloadPath, 'utf8');
  expect(excelContent).toContain('<table>');
  expect(excelContent).toMatch(/DP \/ WS|NB \/ item|Tabla \/ vista \/ SP \/ archivo|Lineage list|Lista de linaje/);

  await capture(page, testInfo, 'clean-shell-detail-pdf-export');
});

test('spanish notebook details expose operation and planning metadata', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop-chromium', 'The notebook detail translation check is covered on desktop.');

  await waitForExplorer(page);

  await page.locator('[data-mode="notebooks"]').click();
  await page.locator('#searchInput').fill('NB_Bronze_VendorApi_Handler');
  await expect(page.locator('.workspace-card').first()).toContainText(/Fabric capacity · a1b2c3d4/);
  await page.locator('.workspace-card').first().click();
  await expect(page.locator('.flow-card.type-notebook').first()).toBeVisible();
  await page.locator('.flow-card.type-notebook').first().click();
  await expect(page.locator('.flow-card.type-read-source', { hasText: /Orígenes leídos|Read sources/ }).first()).toBeVisible();
  await expect(page.locator('.flow-card.type-write-target', { hasText: /Destinos escritos|Write targets/ }).first()).toBeVisible();
  await page.locator('.flow-card.type-read-source', { hasText: /Orígenes leídos|Read sources/ }).first().click();
  await expect(page.locator('.flow-card.source').first()).toBeVisible();
  await page.locator('.flow-card.source').first().click();
  await expect(page.locator('.flow-card.object').first()).toBeVisible();

  await expect(page.locator('#detailContent')).toContainText('Operación');
  await expect(page.locator('#detailContent')).toContainText('Duración media');
  await expect(page.locator('#detailContent')).toContainText('Planificación');
  await expect(page.locator('#detailContent')).toContainText('Recomendación');
  await expect(page.locator('#detailContent')).toContainText('Estabilizar antes de optimizar');
  await expect(page.locator('#detailContent')).not.toContainText('enabled');
  await expect(page.locator('#detailContent')).not.toContainText('disabled');

  await capture(page, testInfo, 'notebook-details-es');
});
