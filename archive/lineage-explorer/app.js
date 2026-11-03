(() => {
  'use strict';

  const state = {
    data: null,
    activeCriterion: '',
    query: '',
    environment: 'all',
    itemType: 'all',
    evidence: 'all',
    selectedWorkspace: '',
    selectedDetail: null,
    expandedWorkspaces: new Set(),
    expandedItems: new Set(),
    expandedSources: new Set(),
    maps: {
      itemsByWorkspace: new Map(),
      itemsByQualifiedName: new Map(),
      sourcesByKey: new Map(),
      sourceEdgesByItem: new Map(),
      sourceEdgesBySource: new Map(),
      dependenciesByItem: new Map()
    }
  };

  const els = {};

  function $(id) {
    return document.getElementById(id);
  }

  function toArray(value) {
    if (!value) return [];
    return Array.isArray(value) ? value : [value];
  }

  function text(value, fallback = '') {
    if (value === null || value === undefined) return fallback;
    return String(value);
  }

  function normalize(value) {
    return text(value).toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/\s+/g, ' ').trim();
  }

  function formatNumber(value) {
    return new Intl.NumberFormat('es-ES').format(Number(value || 0));
  }

  function create(tag, className, content) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (content !== undefined && content !== null) node.textContent = content;
    return node;
  }

  function clear(node) {
    node.replaceChildren();
  }

  function unique(values) {
    return Array.from(new Set(values.filter(Boolean))).sort((a, b) => a.localeCompare(b));
  }

  function isReviewStatus(value) {
    const clean = normalize(value);
    return clean.includes('likely') ||
      clean.includes('blocked') ||
      clean.includes('missing') ||
      clean.includes('review') ||
      clean.includes('ambiguous') ||
      clean.includes('unknown');
  }

  function hasConfirmedEvidence(item) {
    const dep = item.dependencies || {};
    const objects = item.source_objects || {};
    return Number(dep.confirmed || 0) > 0 || Number(objects.confirmed_count || 0) > 0;
  }

  function needsReviewEvidence(item) {
    const dep = item.dependencies || {};
    const objects = item.source_objects || {};
    const orchestration = item.orchestration || {};
    return Number(dep.likely || 0) > 0 ||
      Number(objects.likely_count || 0) > 0 ||
      isReviewStatus(orchestration.v2_status) ||
      isReviewStatus(orchestration.ideal_parallel_readiness);
  }

  function itemMatchesEvidence(item) {
    if (state.evidence === 'confirmed') return hasConfirmedEvidence(item);
    if (state.evidence === 'needs_review') return needsReviewEvidence(item);
    return true;
  }

  function itemMatchesCriterion(item) {
    return toArray(item.criteria).includes(state.activeCriterion);
  }

  function itemSearchText(item) {
    return [
      item.qualified_name,
      item.workspace_name,
      item.workspace_environment,
      item.item_type,
      item.item_name,
      item.description,
      item.orchestration && item.orchestration.v2_status,
      item.orchestration && item.orchestration.ideal_stage
    ].map(text).join(' ');
  }

  function workspaceSearchText(workspace) {
    return [
      workspace.name,
      workspace.normalized_name,
      workspace.environment,
      workspace.workspace_type,
      workspace.capacity_name,
      workspace.domain_name,
      workspace.owner,
      workspace.admin_principals
    ].map(text).join(' ');
  }

  function sourceSearchText(source) {
    return [
      source.display_name,
      source.source_type,
      source.source_server,
      source.source_database,
      source.schema_name,
      source.object_name,
      source.object_type,
      toArray(source.affected_workspaces).join(' ')
    ].map(text).join(' ');
  }

  function indexData(data) {
    state.maps.itemsByWorkspace.clear();
    state.maps.itemsByQualifiedName.clear();
    state.maps.sourcesByKey.clear();
    state.maps.sourceEdgesByItem.clear();
    state.maps.sourceEdgesBySource.clear();
    state.maps.dependenciesByItem.clear();

    toArray(data.items).forEach(item => {
      state.maps.itemsByQualifiedName.set(item.qualified_name, item);
      const workspace = item.workspace_name || '';
      if (!state.maps.itemsByWorkspace.has(workspace)) state.maps.itemsByWorkspace.set(workspace, []);
      state.maps.itemsByWorkspace.get(workspace).push(item);
    });

    toArray(data.source_objects).forEach(source => {
      state.maps.sourcesByKey.set(source.object_key, source);
    });

    toArray(data.relationships && data.relationships.source_object_edges).forEach(edge => {
      if (!state.maps.sourceEdgesByItem.has(edge.item_qualified_name)) state.maps.sourceEdgesByItem.set(edge.item_qualified_name, []);
      if (!state.maps.sourceEdgesBySource.has(edge.source_object_key)) state.maps.sourceEdgesBySource.set(edge.source_object_key, []);
      state.maps.sourceEdgesByItem.get(edge.item_qualified_name).push(edge);
      state.maps.sourceEdgesBySource.get(edge.source_object_key).push(edge);
    });

    toArray(data.relationships && data.relationships.dependencies).forEach(edge => {
      [edge.from, edge.to].forEach(key => {
        if (!key) return;
        if (!state.maps.dependenciesByItem.has(key)) state.maps.dependenciesByItem.set(key, []);
        state.maps.dependenciesByItem.get(key).push(edge);
      });
    });
  }

  async function loadData() {
    if (window.LINEAGE_MULTI_CRITERIA_DATA) return window.LINEAGE_MULTI_CRITERIA_DATA;
    const response = await fetch('./data/lineage-explorer.json', { cache: 'no-store' });
    if (!response.ok) throw new Error(`No se pudo cargar el modelo: ${response.status}`);
    return response.json();
  }

  function filteredItems() {
    const query = normalize(state.query);
    return toArray(state.data.items).filter(item => {
      if (!itemMatchesCriterion(item)) return false;
      if (state.selectedWorkspace && item.workspace_name !== state.selectedWorkspace) return false;
      if (state.environment !== 'all' && item.workspace_environment !== state.environment) return false;
      if (state.itemType !== 'all' && item.item_type !== state.itemType) return false;
      if (!itemMatchesEvidence(item)) return false;
      if (query && !normalize(itemSearchText(item)).includes(query)) return false;
      return true;
    });
  }

  function workspaceItems(workspaceName) {
    return filteredItems().filter(item => item.workspace_name === workspaceName);
  }

  function filteredWorkspaces(items) {
    const names = new Set(items.map(item => item.workspace_name));
    const query = normalize(state.query);
    return toArray(state.data.workspaces).filter(workspace => {
      if (!names.has(workspace.name)) return false;
      if (state.environment !== 'all' && workspace.environment !== state.environment) return false;
      if (query && normalize(workspaceSearchText(workspace)).includes(query)) return true;
      return true;
    }).sort((a, b) => a.name.localeCompare(b.name));
  }

  function filteredSourceObjects(items) {
    if (state.activeCriterion === 'source_and_storage') {
      const query = normalize(state.query);
      return toArray(state.data.source_objects)
        .filter(source => {
          if (state.selectedWorkspace && !toArray(source.affected_workspaces).includes(state.selectedWorkspace)) return false;
          if (state.evidence === 'confirmed' && isReviewStatus(source.object_type_status)) return false;
          if (state.evidence === 'needs_review' && !isReviewStatus(source.object_type_status) && !isReviewStatus(source.object_type)) return false;
          if (query && !normalize(sourceSearchText(source)).includes(query)) return false;
          return true;
        })
        .sort((a, b) => text(a.display_name).localeCompare(text(b.display_name)));
    }

    const itemKeys = new Set(items.map(item => item.qualified_name));
    const sourceKeys = new Set();
    state.maps.sourceEdgesByItem.forEach((edges, itemKey) => {
      if (!itemKeys.has(itemKey)) return;
      edges.forEach(edge => {
        if (edge.source_object_key) sourceKeys.add(edge.source_object_key);
      });
    });
    const query = normalize(state.query);
    return Array.from(sourceKeys)
      .map(key => state.maps.sourcesByKey.get(key))
      .filter(Boolean)
      .filter(source => !query || normalize(sourceSearchText(source)).includes(query) || toArray(source.affected_workspaces).some(workspace => normalize(workspace).includes(query)))
      .sort((a, b) => text(a.display_name).localeCompare(text(b.display_name)));
  }

  function populateFilters() {
    const environments = unique(toArray(state.data.workspaces).map(workspace => workspace.environment || 'UNKNOWN'));
    els.environmentFilter.replaceChildren(create('option', '', 'Todos'));
    els.environmentFilter.firstChild.value = 'all';
    environments.forEach(environment => {
      const option = create('option', '', environment);
      option.value = environment;
      els.environmentFilter.appendChild(option);
    });

    const criterion = toArray(state.data.criteria).find(row => row.id === state.activeCriterion);
    const itemTypes = criterion ? toArray(criterion.item_types) : unique(toArray(state.data.items).map(item => item.item_type));
    els.itemTypeFilter.replaceChildren(create('option', '', 'Todos'));
    els.itemTypeFilter.firstChild.value = 'all';
    itemTypes.forEach(type => {
      const option = create('option', '', type);
      option.value = type;
      els.itemTypeFilter.appendChild(option);
    });
  }

  function renderCriteria() {
    clear(els.criteriaTabs);
    toArray(state.data.criteria).forEach(criterion => {
      const button = create('button', `criteria-tab${criterion.id === state.activeCriterion ? ' active' : ''}`);
      button.type = 'button';
      button.dataset.criterion = criterion.id;
      const label = create('span', '', criterion.label);
      const meta = create('small', '', `${formatNumber(criterion.workspace_count)} WS · ${formatNumber(criterion.item_count)} items`);
      label.appendChild(meta);
      button.appendChild(label);
      button.appendChild(create('span', 'count-pill', formatNumber(criterion.item_count)));
      button.addEventListener('click', () => {
        state.activeCriterion = criterion.id;
        state.selectedWorkspace = '';
        state.selectedDetail = null;
        state.itemType = 'all';
        state.expandedWorkspaces.clear();
        state.expandedItems.clear();
        populateFilters();
        render();
      });
      els.criteriaTabs.appendChild(button);
    });
  }

  function renderMetrics(items, workspaces, sources) {
    const confirmed = items.filter(hasConfirmedEvidence).length;
    const review = items.filter(needsReviewEvidence).length;
    const metrics = [
      ['Workspaces', workspaces.length],
      ['Items', items.length],
      ['Objetos fuente', sources.length],
      ['Confirmados', confirmed],
      ['A revisar', review]
    ];
    els.metrics.replaceChildren(...metrics.map(([label, value]) => {
      const card = create('article', 'metric');
      card.appendChild(create('strong', '', formatNumber(value)));
      card.appendChild(create('p', '', label));
      return card;
    }));
  }

  function renderWorkspaceList(workspaces, items) {
    clear(els.workspaceList);
    els.workspaceTotal.textContent = formatNumber(workspaces.length);
    els.workspaceSubtitle.textContent = `${formatNumber(workspaces.length)} visibles`;

    const itemCounts = new Map();
    items.forEach(item => itemCounts.set(item.workspace_name, (itemCounts.get(item.workspace_name) || 0) + 1));

    workspaces.slice(0, 120).forEach(workspace => {
      const card = create('button', `workspace-card${state.selectedWorkspace === workspace.name ? ' active' : ''}`);
      card.type = 'button';
      card.appendChild(create('span', 'workspace-name', workspace.name));
      const meta = create('span', 'workspace-meta');
      meta.appendChild(create('span', 'chip', workspace.environment || 'UNKNOWN'));
      meta.appendChild(create('span', 'chip', `${formatNumber(itemCounts.get(workspace.name) || 0)} items`));
      if (workspace.deployment_pipeline && workspace.deployment_pipeline.has_pipeline) meta.appendChild(create('span', 'chip', 'Pipeline'));
      card.appendChild(meta);
      card.addEventListener('click', () => {
        state.selectedWorkspace = state.selectedWorkspace === workspace.name ? '' : workspace.name;
        if (state.selectedWorkspace) state.expandedWorkspaces.add(workspace.name);
        state.selectedDetail = { type: 'workspace', value: workspace.name };
        render();
      });
      els.workspaceList.appendChild(card);
    });
  }

  function statusChipsForItem(item) {
    const chips = [];
    if (hasConfirmedEvidence(item)) chips.push(['confirmed', 'Confirmado']);
    if (needsReviewEvidence(item)) chips.push(['needs-review', 'A revisar']);
    if (item.execution && Number(item.execution.enabled_schedules || 0) > 0) chips.push(['info', 'Schedule']);
    if (item.orchestration && item.orchestration.v2_status) chips.push([isReviewStatus(item.orchestration.v2_status) ? 'blocked' : 'info', item.orchestration.v2_status]);
    return chips;
  }

  function renderChipRow(chips) {
    const row = create('div', 'chip-row');
    chips.forEach(([kind, label]) => row.appendChild(create('span', `status-chip ${kind}`, label)));
    return row;
  }

  function itemMeta(item) {
    const meta = create('span', 'item-meta');
    meta.appendChild(create('span', 'chip', item.item_type || 'Item'));
    if (item.workspace_environment) meta.appendChild(create('span', 'chip', item.workspace_environment));
    if (item.orchestration && item.orchestration.ideal_wave_index) meta.appendChild(create('span', 'chip', `Wave ${item.orchestration.ideal_wave_index}`));
    return meta;
  }

  function renderMiniGrid(rows) {
    const grid = create('div', 'mini-grid');
    rows.forEach(([label, value]) => {
      const tile = create('div', 'mini-tile');
      tile.appendChild(create('strong', '', formatNumber(value)));
      tile.appendChild(create('span', '', label));
      grid.appendChild(tile);
    });
    return grid;
  }

  function renderItemBody(item) {
    const body = create('div', 'item-body');
    const dep = item.dependencies || {};
    const exec = item.execution || {};
    const objects = item.source_objects || {};
    body.appendChild(renderMiniGrid([
      ['Entrantes', dep.incoming || 0],
      ['Salientes', dep.outgoing || 0],
      ['Objetos', objects.count || 0],
      ['Runs', exec.run_count || 0],
      ['Fallos', exec.failed_count || 0],
      ['Schedules', exec.enabled_schedules || 0]
    ]));

    const sourceEdges = toArray(state.maps.sourceEdgesByItem.get(item.qualified_name)).slice(0, 18);
    if (sourceEdges.length) {
      const row = create('div', 'chip-row');
      sourceEdges.forEach(edge => {
        const source = state.maps.sourcesByKey.get(edge.source_object_key);
        const button = create('button', 'link-button', source ? source.display_name : edge.source_object_key);
        button.type = 'button';
        button.addEventListener('click', event => {
          event.stopPropagation();
          state.selectedDetail = { type: 'source', value: edge.source_object_key };
          renderDetails();
        });
        row.appendChild(button);
      });
      body.appendChild(row);
    }

    body.appendChild(renderChipRow(statusChipsForItem(item)));
    return body;
  }

  function renderItemCard(item) {
    const expanded = state.expandedItems.has(item.qualified_name);
    const card = create('article', `item-card${expanded ? ' expanded' : ''}`);
    const header = create('button', 'item-header');
    header.type = 'button';
    header.appendChild(create('span', 'expander', expanded ? '-' : '+'));
    const titleWrap = create('span');
    titleWrap.appendChild(create('span', 'item-title', item.item_name || item.qualified_name));
    titleWrap.appendChild(itemMeta(item));
    header.appendChild(titleWrap);
    header.appendChild(create('span', 'count-pill', formatNumber((item.source_objects && item.source_objects.count) || 0)));
    header.addEventListener('click', () => {
      if (expanded) state.expandedItems.delete(item.qualified_name);
      else state.expandedItems.add(item.qualified_name);
      state.selectedDetail = { type: 'item', value: item.qualified_name };
      render();
    });
    card.appendChild(header);
    card.appendChild(renderItemBody(item));
    return card;
  }

  function renderSourceCard(source) {
    const expanded = state.expandedSources.has(source.object_key);
    const card = create('article', `source-card${expanded ? ' expanded' : ''}`);
    const header = create('button', 'source-header');
    header.type = 'button';
    header.appendChild(create('span', 'expander', expanded ? '-' : '+'));
    const titleWrap = create('span');
    titleWrap.appendChild(create('span', 'source-title', source.display_name || source.object_key));
    const meta = create('span', 'source-meta');
    meta.appendChild(create('span', 'chip', source.source_type || 'Origen'));
    meta.appendChild(create('span', 'chip', source.object_type || 'Objeto'));
    titleWrap.appendChild(meta);
    header.appendChild(titleWrap);
    header.appendChild(create('span', 'count-pill', formatNumber(source.affected_item_count || 0)));
    header.addEventListener('click', () => {
      if (expanded) state.expandedSources.delete(source.object_key);
      else state.expandedSources.add(source.object_key);
      state.selectedDetail = { type: 'source', value: source.object_key };
      render();
    });
    card.appendChild(header);

    const body = create('div', 'source-body');
    body.appendChild(renderMiniGrid([
      ['Items', source.affected_item_count || 0],
      ['Workspaces', source.affected_workspace_count || 0],
      ['Lecturas', countByKey(source.operation_counts, 'read')]
    ]));
    body.appendChild(renderChipRow([[isReviewStatus(source.object_type_status) ? 'needs-review' : 'confirmed', source.object_type_status || source.object_type_confidence || 'evidencia']]));
    card.appendChild(body);
    return card;
  }

  function countByKey(rows, key) {
    const found = toArray(rows).find(row => row.key === key);
    return found ? Number(found.count || 0) : 0;
  }

  function renderTree(workspaces, items, sources) {
    clear(els.lineageTree);
    const criterion = toArray(state.data.criteria).find(row => row.id === state.activeCriterion);
    els.treeTitle.textContent = criterion ? criterion.label : 'Linaje corporativo';
    els.treeSubtitle.textContent = `${formatNumber(items.length)} items · ${formatNumber(sources.length)} objetos fuente`;

    if (!items.length && !sources.length) {
      els.lineageTree.appendChild(create('div', 'empty-state', 'Sin resultados con el filtro actual.'));
      return;
    }

    if (state.activeCriterion === 'source_and_storage') {
      sources.slice(0, 160).forEach(source => els.lineageTree.appendChild(renderSourceCard(source)));
      return;
    }

    workspaces.slice(0, 40).forEach(workspace => {
      const workspaceItemRows = workspaceItems(workspace.name).sort((a, b) => `${a.item_type} ${a.item_name}`.localeCompare(`${b.item_type} ${b.item_name}`));
      if (!workspaceItemRows.length) return;
      const expanded = state.expandedWorkspaces.has(workspace.name) || state.selectedWorkspace === workspace.name || workspaces.length <= 4;
      const node = create('article', `tree-workspace${expanded ? ' expanded' : ''}`);
      const header = create('button', 'tree-header');
      header.type = 'button';
      header.appendChild(create('span', 'expander', expanded ? '-' : '+'));
      const titleWrap = create('span');
      titleWrap.appendChild(create('span', 'workspace-name', workspace.name));
      const meta = create('span', 'workspace-meta');
      meta.appendChild(create('span', 'chip', workspace.environment || 'UNKNOWN'));
      meta.appendChild(create('span', 'chip', workspace.workspace_type || 'Workspace'));
      if (workspace.deployment_pipeline && workspace.deployment_pipeline.has_pipeline) meta.appendChild(create('span', 'chip', 'Deployment pipeline'));
      titleWrap.appendChild(meta);
      header.appendChild(titleWrap);
      header.appendChild(create('span', 'count-pill', formatNumber(workspaceItemRows.length)));
      header.addEventListener('click', () => {
        if (expanded) state.expandedWorkspaces.delete(workspace.name);
        else state.expandedWorkspaces.add(workspace.name);
        state.selectedDetail = { type: 'workspace', value: workspace.name };
        render();
      });
      node.appendChild(header);
      const body = create('div', 'tree-body');
      workspaceItemRows.slice(0, 80).forEach(item => body.appendChild(renderItemCard(item)));
      if (workspaceItemRows.length > 80) body.appendChild(create('div', 'empty-state', `+ ${formatNumber(workspaceItemRows.length - 80)} items`));
      node.appendChild(body);
      els.lineageTree.appendChild(node);
    });
  }

  function kv(label, value) {
    const row = create('div', 'kv');
    row.appendChild(create('span', '', label));
    row.appendChild(create('span', '', value || '-'));
    return row;
  }

  function detailSection(title, rows) {
    const section = create('section', 'detail-section');
    section.appendChild(create('h3', '', title));
    rows.forEach(row => section.appendChild(row));
    return section;
  }

  function renderDetails() {
    clear(els.detailContent);
    if (!state.selectedDetail) {
      els.detailSubtitle.textContent = 'Sin selección';
      els.detailContent.appendChild(create('div', 'empty-state', 'Sin selección'));
      return;
    }

    if (state.selectedDetail.type === 'workspace') {
      const workspace = toArray(state.data.workspaces).find(row => row.name === state.selectedDetail.value);
      if (!workspace) return;
      els.detailSubtitle.textContent = workspace.name;
      els.detailContent.appendChild(detailSection('Workspace', [
        kv('Nombre', workspace.name),
        kv('Entorno', workspace.environment),
        kv('Tipo', workspace.workspace_type),
        kv('Capacity', workspace.capacity_name || workspace.capacity_id),
        kv('Region', workspace.capacity_region),
        kv('Dominio', workspace.domain_name)
      ]));
      els.detailContent.appendChild(detailSection('Acceso', [
        kv('Owner', workspace.owner),
        kv('Admins', workspace.admin_principals)
      ]));
      const stages = toArray(workspace.deployment_pipeline && workspace.deployment_pipeline.stages);
      els.detailContent.appendChild(detailSection('Deployment pipeline', [
        kv('Asignado', workspace.deployment_pipeline && workspace.deployment_pipeline.has_pipeline ? 'Si' : 'No'),
        kv('Etapas', stages.map(stage => `${stage.deployment_pipeline_name} / ${stage.stage_name}`).join('; '))
      ]));
      if (workspace.governance) {
        els.detailContent.appendChild(detailSection('Governance Phase 11', [
          kv('Principales', workspace.governance.principal_count),
          kv('Usuarios', workspace.governance.user_count),
          kv('Grupos', workspace.governance.group_count),
          kv('Service principals', workspace.governance.service_principal_count),
          kv('Deployment memberships', workspace.governance.deployment_pipeline_count),
          kv('DevOps candidatos', workspace.governance.devops_candidate_count),
          kv('Gaps', workspace.governance.governance_gap_flags),
          kv('Evidencia', workspace.governance.evidence)
        ]));
      }
      return;
    }

    if (state.selectedDetail.type === 'item') {
      const item = state.maps.itemsByQualifiedName.get(state.selectedDetail.value);
      if (!item) return;
      const dep = item.dependencies || {};
      const exec = item.execution || {};
      const objects = item.source_objects || {};
      const orchestration = item.orchestration || {};
      const deep = item.deep_lineage || {};
      els.detailSubtitle.textContent = item.item_name;
      els.detailContent.appendChild(detailSection('Item', [
        kv('Nombre', item.item_name),
        kv('Tipo', item.item_type),
        kv('Workspace', item.workspace_name),
        kv('ID tecnico', item.technical_id)
      ]));
      els.detailContent.appendChild(detailSection('Dependencias', [
        kv('Entrantes', dep.incoming),
        kv('Salientes', dep.outgoing),
        kv('Confirmadas', dep.confirmed),
        kv('Likely', dep.likely)
      ]));
      els.detailContent.appendChild(detailSection('Ejecución', [
        kv('Runs', exec.run_count),
        kv('Fallos', exec.failed_count),
        kv('Schedules activos', exec.enabled_schedules),
        kv('Ultimo estado', exec.latest_status),
        kv('Ultimo inicio', exec.latest_start_time)
      ]));
      els.detailContent.appendChild(detailSection('Objetos fuente', [
        kv('Total', objects.count),
        kv('Read', objects.read_count),
        kv('Write', objects.write_count),
        kv('Execute', objects.execute_count),
        kv('Confirmados', objects.confirmed_count),
        kv('Likely', objects.likely_count)
      ]));
      if (item.deep_lineage) {
        els.detailContent.appendChild(detailSection('Deep Object Lineage Phase 12', [
          kv('Estado', deep.status),
          kv('Cobertura', deep.coverage_status),
          kv('Review', deep.review_status),
          kv('Fuentes', deep.source_count),
          kv('Objetos unicos', deep.unique_object_count),
          kv('Referencias', deep.object_reference_count),
          kv('Exactas', deep.exact_object_reference_count),
          kv('Ambiguas', deep.ambiguous_object_reference_count),
          kv('Read', deep.read_count),
          kv('Write', deep.write_count),
          kv('Execute', deep.execute_count),
          kv('Unknown', deep.unknown_count),
          kv('Confirmadas', deep.confirmed_lineage_rows),
          kv('Likely', deep.likely_lineage_rows),
          kv('Siguiente accion', deep.next_action)
        ]));
      }
      els.detailContent.appendChild(detailSection('Orquestación', [
        kv('Wave', orchestration.ideal_wave_index),
        kv('Stage', orchestration.ideal_stage),
        kv('Readiness', orchestration.ideal_parallel_readiness),
        kv('V2 status', orchestration.v2_status),
        kv('Siguiente acción', orchestration.v2_recommended_next_action)
      ]));
      return;
    }

    if (state.selectedDetail.type === 'source') {
      const source = state.maps.sourcesByKey.get(state.selectedDetail.value);
      if (!source) return;
      els.detailSubtitle.textContent = source.display_name || source.object_key;
      const edges = toArray(state.maps.sourceEdgesBySource.get(source.object_key));
      els.detailContent.appendChild(detailSection('Objeto fuente', [
        kv('Nombre', source.display_name),
        kv('Tipo origen', source.source_type),
        kv('Servidor', source.source_server),
        kv('Base', source.source_database),
        kv('Schema', source.schema_name),
        kv('Objeto', source.object_name),
        kv('Tipo objeto', source.object_type),
        kv('Estado tipo', source.object_type_status)
      ]));
      els.detailContent.appendChild(detailSection('Impacto', [
        kv('Items afectados', source.affected_item_count),
        kv('Workspaces', toArray(source.affected_workspaces).join('; ')),
        kv('Lecturas', countByKey(source.operation_counts, 'read')),
        kv('Escrituras', countByKey(source.operation_counts, 'write')),
        kv('Ejecuciones', countByKey(source.operation_counts, 'execute'))
      ]));
      els.detailContent.appendChild(detailSection('Muestra de items', edges.slice(0, 12).map(edge => kv(edge.operation_type, `${edge.workspace_name} / ${edge.item_type} / ${edge.item_name}`))));
    }
  }

  function render() {
    const items = filteredItems();
    const workspaces = filteredWorkspaces(items);
    const sources = filteredSourceObjects(items);
    renderCriteria();
    renderMetrics(items, workspaces, sources);
    renderWorkspaceList(workspaces, items);
    renderTree(workspaces, items, sources);
    renderDetails();
  }

  function bindEvents() {
    els.globalSearch.addEventListener('input', event => {
      state.query = event.target.value;
      render();
    });
    els.environmentFilter.addEventListener('change', event => {
      state.environment = event.target.value;
      state.selectedWorkspace = '';
      render();
    });
    els.itemTypeFilter.addEventListener('change', event => {
      state.itemType = event.target.value;
      render();
    });
    els.evidenceFilter.addEventListener('change', event => {
      state.evidence = event.target.value;
      render();
    });
    els.resetButton.addEventListener('click', () => {
      state.query = '';
      state.environment = 'all';
      state.itemType = 'all';
      state.evidence = 'all';
      state.selectedWorkspace = '';
      state.selectedDetail = null;
      state.expandedWorkspaces.clear();
      state.expandedItems.clear();
      state.expandedSources.clear();
      els.globalSearch.value = '';
      els.environmentFilter.value = 'all';
      els.evidenceFilter.value = 'all';
      populateFilters();
      render();
    });
    els.clearWorkspaceButton.addEventListener('click', () => {
      state.selectedWorkspace = '';
      state.selectedDetail = null;
      render();
    });
    els.expandAllButton.addEventListener('click', () => {
      filteredWorkspaces(filteredItems()).slice(0, 40).forEach(workspace => state.expandedWorkspaces.add(workspace.name));
      render();
    });
    els.collapseAllButton.addEventListener('click', () => {
      state.expandedWorkspaces.clear();
      state.expandedItems.clear();
      render();
    });
    els.drawerToggle.addEventListener('click', () => {
      $('detailDrawer').classList.toggle('hidden');
    });
  }

  async function init() {
    ['criteriaTabs', 'metrics', 'workspaceSubtitle', 'workspaceTotal', 'workspaceList', 'lineageTree', 'treeTitle', 'treeSubtitle', 'detailSubtitle', 'detailContent', 'globalSearch', 'environmentFilter', 'itemTypeFilter', 'evidenceFilter', 'resetButton', 'clearWorkspaceButton', 'expandAllButton', 'collapseAllButton', 'drawerToggle'].forEach(id => {
      els[id] = $(id);
    });
    try {
      state.data = await loadData();
      indexData(state.data);
      state.activeCriterion = toArray(state.data.criteria)[0].id;
      populateFilters();
      bindEvents();
      render();
    } catch (error) {
      clear(els.lineageTree);
      els.lineageTree.appendChild(create('div', 'empty-state', error.message));
      console.error(error);
    }
  }

  document.addEventListener('DOMContentLoaded', init);
})();
