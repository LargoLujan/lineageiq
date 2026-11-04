const state = {
  data: null,
  impact: null,
  lang: 'es',
  theme: 'auto',
  mode: 'all',
  viewMode: 'lineage',
  selectedWorkspace: '',
  selectedWorkspaces: new Set(),
  selectedDeploymentPipelines: new Set(),
  selectedStageWorkspaces: new Map(),
  selectedWorkspaceEnvironments: new Set(),
  selectedWorkspaceDomain: 'all',
  selectedNode: null,
  history: [],
  expanded: new Set(),
  search: '',
  impactObjectSearch: '',
  impactSelectedObjectKeys: new Set(),
  diagramObjectSelectionMode: 'all',
  diagramSelectedObjectKeys: new Set(),
  planningSourceSearch: '',
  planningSelectedSources: new Set(),
  workspaceSearchQuery: '',
  // Manual drag offsets, keyed by the *stable* node.key (qualified-name
  // based) rather than node.id (which is assigned by insertion order while
  // building the graph and can differ between renders of the same item).
  // Persists across re-renders of the same scope so a dragged layout
  // survives selecting a card, filtering sources, etc.
  planningNodePositions: new Map(),
  // Multi-select for the planning canvas: an ordered array (not a Set) so
  // "most recently selected" is just the last element, used to decide what
  // the detail panel shows when a deselect click leaves more than one node
  // still selected. Keyed by node.id like everything else in that graph.
  planningSelectedIds: [],
  filters: {
    sourceType: 'all',
    confidence: 'all',
    itemType: 'all',
    diagramStore: 'all',
    diagramObjectType: 'all',
    impactDatabase: 'all',
    impactObjectType: 'all',
    impactObjectKey: 'all'
  },
  focusMode: false,
  snapshotExport: false,
  showDetails: true,
  sceneEnabled: false,
  view: { x: 0, y: 0, scale: 1 },
  drag: { active: false, x: 0, y: 0 },
  filterPanel: { x: null, y: null, active: false, x0: 0, y0: 0 },
  sceneStarted: false
};

const els = {
  pageTitle: document.getElementById('pageTitle'),
  langEsButton: document.getElementById('langEsButton'),
  langEnButton: document.getElementById('langEnButton'),
  themeAutoButton: document.getElementById('themeAutoButton'),
  themeLightButton: document.getElementById('themeLightButton'),
  themeDarkButton: document.getElementById('themeDarkButton'),
  authGateThemeAutoButton: document.getElementById('authGateThemeAutoButton'),
  authGateThemeLightButton: document.getElementById('authGateThemeLightButton'),
  authGateThemeDarkButton: document.getElementById('authGateThemeDarkButton'),
  reinvestigateButton: document.getElementById('reinvestigateButton'),
  helpButton: document.getElementById('helpButton'),
  helpPanel: document.getElementById('helpPanel'),
  authArea: document.getElementById('authArea'),
  userBadge: document.getElementById('userBadge'),
  userBadgeName: document.getElementById('userBadgeName'),
  userBadgeAvatarImg: document.getElementById('userBadgeAvatarImg'),
  userBadgeInitials: document.getElementById('userBadgeInitials'),
  modalBackdrop: document.getElementById('modalBackdrop'),
  adminInfoPopover: document.getElementById('adminInfoPopover'),
  profileMenu: document.getElementById('profileMenu'),
  profileMenuAvatarImg: document.getElementById('profileMenuAvatarImg'),
  profileMenuInitials: document.getElementById('profileMenuInitials'),
  profileMenuName: document.getElementById('profileMenuName'),
  profileMenuEmail: document.getElementById('profileMenuEmail'),
  profileMenuAdminLabel: document.getElementById('profileMenuAdminLabel'),
  profileMenuHelpLabel: document.getElementById('profileMenuHelpLabel'),
  profileMenuSignOutLabel: document.getElementById('profileMenuSignOutLabel'),
  profileMenuSignOutButton: document.getElementById('profileMenuSignOutButton'),
  profileMenuSignOutDivider: document.getElementById('profileMenuSignOutDivider'),
  profileMenuProfileButton: document.getElementById('profileMenuProfileButton'),
  profileMenuProfileLabel: document.getElementById('profileMenuProfileLabel'),
  profilePanel: document.getElementById('profilePanel'),
  adminButton: document.getElementById('adminButton'),
  adminPanel: document.getElementById('adminPanel'),
  governancePanel: document.getElementById('governancePanel'),
  notificationsButton: document.getElementById('notificationsButton'),
  notificationsButtonLabel: document.getElementById('notificationsButtonLabel'),
  notificationsBadge: document.getElementById('notificationsBadge'),
  notificationsPanel: document.getElementById('notificationsPanel'),
  governanceButton: document.getElementById('governanceButton'),
  governanceButtonLabel: document.getElementById('governanceButtonLabel'),
  privacyButton: document.getElementById('privacyButton'),
  privacyButtonLabel: document.getElementById('privacyButtonLabel'),
  privacyPanel: document.getElementById('privacyPanel'),
  glossaryPanel: document.getElementById('glossaryPanel'),
  glossaryBody: document.getElementById('glossaryBody'),
  glossaryTitle: document.getElementById('glossaryTitle'),
  glossaryCloseButton: document.getElementById('glossaryCloseButton'),
  impactBreakdownModal: document.getElementById('impactBreakdownModal'),
  impactBreakdownTitle: document.getElementById('impactBreakdownTitle'),
  impactBreakdownSubtitle: document.getElementById('impactBreakdownSubtitle'),
  impactBreakdownBody: document.getElementById('impactBreakdownBody'),
  impactBreakdownCloseButton: document.getElementById('impactBreakdownCloseButton'),
  sensitivityDetailModal: document.getElementById('sensitivityDetailModal'),
  sensitivityDetailTitle: document.getElementById('sensitivityDetailTitle'),
  sensitivityDetailSubtitle: document.getElementById('sensitivityDetailSubtitle'),
  sensitivityDetailBody: document.getElementById('sensitivityDetailBody'),
  sensitivityDetailCloseButton: document.getElementById('sensitivityDetailCloseButton'),
  workspaceAccessModal: document.getElementById('workspaceAccessModal'),
  workspaceAccessTitle: document.getElementById('workspaceAccessTitle'),
  workspaceAccessSubtitle: document.getElementById('workspaceAccessSubtitle'),
  workspaceAccessBody: document.getElementById('workspaceAccessBody'),
  workspaceAccessCloseButton: document.getElementById('workspaceAccessCloseButton'),
  tenantAdminWorkspacesModal: document.getElementById('tenantAdminWorkspacesModal'),
  tenantAdminWorkspacesTitle: document.getElementById('tenantAdminWorkspacesTitle'),
  tenantAdminWorkspacesSubtitle: document.getElementById('tenantAdminWorkspacesSubtitle'),
  tenantAdminWorkspacesBody: document.getElementById('tenantAdminWorkspacesBody'),
  tenantAdminWorkspacesCloseButton: document.getElementById('tenantAdminWorkspacesCloseButton'),
  installerWizardModal: document.getElementById('installerWizardModal'),
  installerWizardBody: document.getElementById('installerWizardBody'),
  installerWizardCloseButton: document.getElementById('installerWizardCloseButton'),
  workspaceCreateModal: document.getElementById('workspaceCreateModal'),
  workspaceCreateBody: document.getElementById('workspaceCreateBody'),
  workspaceCreateCloseButton: document.getElementById('workspaceCreateCloseButton'),
  impactBreakdownExcelButton: document.getElementById('impactBreakdownExcelButton'),
  planningEvidenceModal: document.getElementById('planningEvidenceModal'),
  planningEvidenceModalTitle: document.getElementById('planningEvidenceModalTitle'),
  planningEvidenceModalBody: document.getElementById('planningEvidenceModalBody'),
  planningEvidenceModalCloseButton: document.getElementById('planningEvidenceModalCloseButton'),
  appShell: document.querySelector('main.app-shell'),
  authGate: document.getElementById('authGate'),
  authGateLangEsButton: document.getElementById('authGateLangEsButton'),
  authGateLangEnButton: document.getElementById('authGateLangEnButton'),
  authGateTitle: document.getElementById('authGateTitle'),
  authGateLede: document.getElementById('authGateLede'),
  authGateSignInButton: document.getElementById('authGateSignInButton'),
  authGateError: document.getElementById('authGateError'),
  authGateDeviceCode: document.getElementById('authGateDeviceCode'),
  authGateHint1: document.getElementById('authGateHint1'),
  authGateHint2: document.getElementById('authGateHint2'),
  authGateVerificationLink: document.getElementById('authGateVerificationLink'),
  authGateUserCode: document.getElementById('authGateUserCode'),
  authGateCopyCodeButton: document.getElementById('authGateCopyCodeButton'),
  authGateStatusMessage: document.getElementById('authGateStatusMessage'),
  authGateCancelButton: document.getElementById('authGateCancelButton'),
  localScanPanel: document.getElementById('localScanPanel'),
  localScanWorkspaceSelect: document.getElementById('localScanWorkspaceSelect'),
  localScanButton: document.getElementById('localScanButton'),
  fullScanButton: document.getElementById('fullScanButton'),
  stopScanButton: document.getElementById('stopScanButton'),
  scanHistoryButton: document.getElementById('scanHistoryButton'),
  scanHistoryPanel: document.getElementById('scanHistoryPanel'),
  scanHistoryCloseButton: document.getElementById('scanHistoryCloseButton'),
  scanHistoryBody: document.getElementById('scanHistoryBody'),
  localScanHint: document.getElementById('localScanHint'),
  localScanAccessHint: document.getElementById('localScanAccessHint'),
  localScanStatus: document.getElementById('localScanStatus'),
  scanProgressWrap: document.getElementById('scanProgressWrap'),
  scanProgressFill: document.getElementById('scanProgressFill'),
  scanProgressText: document.getElementById('scanProgressText'),
  scanProgressStep: document.getElementById('scanProgressStep'),
  localScanQueue: document.getElementById('localScanQueue'),
  searchLabel: document.getElementById('searchLabel'),
  searchInput: document.getElementById('searchInput'),
  resetButton: document.getElementById('resetButton'),
  focusButton: document.getElementById('focusButton'),
  detailsToggleButton: document.getElementById('detailsToggleButton'),
  inspectionButton: document.getElementById('inspectionButton'),
  impactButton: document.getElementById('impactButton'),
  scheduleButton: document.getElementById('scheduleButton'),
  modeButtons: Array.from(document.querySelectorAll('.mode-button')),
  modeBarVisible: document.getElementById('modeBarVisible'),
  modeOverflowToggle: document.getElementById('modeOverflowToggle'),
  modeOverflowMenu: document.getElementById('modeOverflowMenu'),
  metricWorkspaces: document.getElementById('metricWorkspaces'),
  metricWorkspacesLabel: document.getElementById('metricWorkspacesLabel'),
  metricPrimary: document.getElementById('metricPrimary'),
  metricPrimaryLabel: document.getElementById('metricPrimaryLabel'),
  metricSources: document.getElementById('metricSources'),
  metricSourcesLabel: document.getElementById('metricSourcesLabel'),
  metricObjects: document.getElementById('metricObjects'),
  metricObjectsLabel: document.getElementById('metricObjectsLabel'),
  workspacePanelTitle: document.getElementById('workspacePanelTitle'),
  workspacePanelSubtitle: document.getElementById('workspacePanelSubtitle'),
  workspaceCount: document.getElementById('workspaceCount'),
  selectAllWorkspacesButton: document.getElementById('selectAllWorkspacesButton'),
  clearWorkspacesButton: document.getElementById('clearWorkspacesButton'),
  workspaceSearchToggle: document.getElementById('workspaceSearchToggle'),
  workspaceSearchToggleLabel: document.getElementById('workspaceSearchToggleLabel'),
  workspaceSearchPanel: document.getElementById('workspaceSearchPanel'),
  workspaceSearchInput: document.getElementById('workspaceSearchInput'),
  workspaceSearchResults: document.getElementById('workspaceSearchResults'),
  workspaceEnvironmentButtons: Array.from(document.querySelectorAll('[data-workspace-env-filter]')),
  workspaceDomainFilterRow: document.getElementById('workspaceDomainFilterRow'),
  workspaceDomainFilterLabel: document.getElementById('workspaceDomainFilterLabel'),
  workspaceDomainFilter: document.getElementById('workspaceDomainFilter'),
  workspaceList: document.getElementById('workspaceList'),
  graphTitle: document.getElementById('graphTitle'),
  graphSubtitle: document.getElementById('graphSubtitle'),
  modeLegend: document.getElementById('modeLegend'),
  graphSurface: document.getElementById('graphSurface'),
  inspectionMapCloseButton: document.getElementById('inspectionMapCloseButton'),
  inspectionMapPngButton: document.getElementById('inspectionMapPngButton'),
  inspectionMapExcelButton: document.getElementById('inspectionMapExcelButton'),
  filterButton: document.getElementById('filterButton'),
  filterMenu: document.getElementById('filterMenu'),
  sourceTypeFilter: document.getElementById('sourceTypeFilter'),
  confidenceFilter: document.getElementById('confidenceFilter'),
  itemTypeFilter: document.getElementById('itemTypeFilter'),
  objectFilter: document.getElementById('objectFilter'),
  impactObjectSearch: document.getElementById('impactObjectSearch'),
  impactObjectOptions: document.getElementById('impactObjectOptions'),
  impactObjectClear: document.getElementById('impactObjectClear'),
  diagramObjectChecklist: document.getElementById('diagramObjectChecklist'),
  planningFilterSources: document.getElementById('planningFilterSources'),
  sourceFilterLabel: document.getElementById('sourceFilterLabel'),
  confidenceFilterLabel: document.getElementById('confidenceFilterLabel'),
  itemTypeFilterLabel: document.getElementById('itemTypeFilterLabel'),
  objectFilterLabel: document.getElementById('objectFilterLabel'),
  objectFilterRow: document.getElementById('objectFilterRow'),
  zoomOutButton: document.getElementById('zoomOutButton'),
  planningResetLayoutButton: document.getElementById('planningResetLayoutButton'),
  fitButton: document.getElementById('fitButton'),
  zoomInButton: document.getElementById('zoomInButton'),
  sceneToggleButton: document.getElementById('sceneToggleButton'),
  viewport: document.getElementById('graphViewport'),
  treeStage: document.getElementById('treeStage'),
  sceneCanvas: document.getElementById('lineageScene'),
  detailTitle: document.getElementById('detailTitle'),
  detailSubtitle: document.getElementById('detailSubtitle'),
  detailContent: document.getElementById('detailContent')
};

const IMPACT_SEARCH_DEBOUNCE_MS = 1400;
const MIN_ZOOM_SCALE = 0.16;
const MAX_ZOOM_SCALE = 3.4;
let impactSearchRenderTimer = null;

function cancelImpactSearchRender() {
  if (!impactSearchRenderTimer) return;
  window.clearTimeout(impactSearchRenderTimer);
  impactSearchRenderTimer = null;
}

function scheduleImpactSearchRender(selector, selectionStart = null, selectionEnd = null) {
  cancelImpactSearchRender();
  impactSearchRenderTimer = window.setTimeout(() => {
    impactSearchRenderTimer = null;
    renderPreservingFocus(selector, selectionStart, selectionEnd);
  }, IMPACT_SEARCH_DEBOUNCE_MS);
}

function scheduleImpactObjectSearchRender(selector, value, selectionStart = null, selectionEnd = null) {
  cancelImpactSearchRender();
  impactSearchRenderTimer = window.setTimeout(() => {
    impactSearchRenderTimer = null;
    setImpactObjectSearch(value);
    renderPreservingFocus(selector, selectionStart, selectionEnd);
  }, IMPACT_SEARCH_DEBOUNCE_MS);
}

const i18n = {
  es: {
    title: 'Explorador de linaje',
    search: 'Buscar',
    searchPlaceholder: 'Workspace alojado, modelo, notebook, origen...',
    reset: 'Reiniciar',
    reinvestigate: 'Reinvestigar',
    filter: 'Filtro',
    back: 'Volver',
    focus: 'Índice WS',
    details: 'Detalles',
    inspect: 'Inspeccion',
    impact: 'Impacto',
    schedule: 'Planificación',
    selectAll: 'Todos',
    clear: 'Limpiar',
    workspaceSearchToggle: 'Buscar y seleccionar workspace...',
    workspaceSearchPlaceholder: 'Escribe para buscar...',
    workspaceSearchNoMatch: 'Sin resultados',
    workspaces: 'Workspaces',
    workspaceHint: 'Workspaces donde se alojan elementos del árbol elegido',
    deploymentPipelines: 'Deployment pipelines',
    deploymentPipeline: 'Deployment pipeline',
    deploymentStage: 'Etapa',
    stageFilter: 'Workspaces del deployment',
    stageFilterAll: 'Todos',
    stageFilterHint: 'Sin seleccion: todos',
    deploymentEnvironmentFilter: 'Filtro DEV/QA/PRO',
    noDeploymentPipeline: 'Sin deployment pipeline',
    assignedStages: 'etapas asignadas',
    indexedWorkspaces: 'workspaces indexados',
    productionWorkspace: 'Workspace PRO',
    productionModels: 'modelos PRO',
    stageNotIndexed: 'Sin workspace local',
    stageIndexed: 'Indexado',
    unassignedStage: 'Sin workspace local',
    selectWorkspace: 'Selecciona un workspace',
    graphHint: 'Abre el árbol poco a poco para mantener la pantalla limpia.',
    planningTitle: 'Planificación candidata',
    planningHint: 'Propuesta DAG de items: ejecutar CopyJobs/Notebooks/Pipelines y refrescar modelos semánticos con dependencias limpias.',
    impactTitle: 'Impacto inverso',
    impactHint: 'Busca una tabla, vista, SP, archivo o consulta y revisa qué items e informes quedarían afectados.',
    reinvestigateTitle: 'Reinvestigación solo lectura',
    reinvestigateHint: 'Este HTML no ejecuta cambios. Usa estos comandos en terminal y con aprobación humana.',
    refresh: {
      latest: 'Último refresh',
      artifacts: 'Frescura de artefactos',
      commands: 'Comandos recomendados',
      when: 'Cuándo usarlo',
      safety: 'Regla de seguridad',
      packageGenerated: 'Estado embebido',
      runLog: 'Run log',
      manifest: 'Manifest',
      mode: 'Modo',
      status: 'Estado',
      started: 'Inicio',
      ended: 'Fin',
      duration: 'Duración',
      visual: 'Validación visual',
      external: 'Sistemas externos',
      noExternal: 'Ninguno',
      passed: 'pasadas',
      failedCount: 'fallidas',
      skipped: 'omitidas',
      lines: 'líneas',
      modified: 'modificado',
      age: 'edad',
      completed: 'completado',
      failed: 'fallido',
      unknownStatus: 'desconocido',
      none: 'Sin datos embebidos',
      useLocal: 'Cambios visuales, documentación, mapping local o regenerar standalone.',
      useLocalVisual: 'Antes de enseñar la web o cerrar una fase visual.',
      useInventory: 'Cuando hayan cambiado workspaces, items, conexiones u orígenes en Fabric.',
      useFull: 'Antes de decisiones de planificación con programaciones, duraciones y refresh.',
      useTmdl: 'Cuando cambien modelos semánticos o necesitemos más tablas/vistas/nativas.',
      safetyText: 'La web no modifica Fabric ni ejecuta comandos. La aprobación y ejecución final son humanas.'
    },
    planning: {
      summary: 'Resumen DAG',
      readinessSummary: 'Readiness de modelos semánticos',
      dataGroups: 'orígenes / almacenes',
      affectedModels: 'modelos afectados',
      modelsAffected: 'Modelos afectados',
      dataReadiness: 'Readiness de datos',
      dataArrival: 'Llegada de datos',
      noArrivalEvidence: 'Sin última llegada local',
      upstreamLatest: 'Última ejecución upstream',
      noUpstream: 'Sin proceso upstream enlazado',
      refreshEvidence: 'Refresh modelo',
      noRefreshEvidence: 'Sin refresh reciente registrado',
      modelSchedule: 'Schedule modelo',
      objectCount: 'objetos origen',
      readinessHint: 'Canvas visual: procesos y modelos semánticos conectados por dependencias entre items.',
      noReadiness: 'No hay fuentes de modelos semánticos para el alcance actual.',
      sourceSelectorTitle: 'Seleccionar Lakehouse / origen',
      sourceSearchPlaceholder: 'Buscar Lakehouse, SQL, almacén u origen...',
      sourceSearchHint: 'Filtra o selecciona uno o varios orígenes para ver solo sus modelos afectados.',
      selectedSources: 'Orígenes seleccionados',
      matchingSources: 'Orígenes disponibles',
      clearSources: 'Limpiar orígenes',
      noSourceMatch: 'No hay orígenes para esta selección.',
      canvasHint: 'Flujo propuesto entre items Fabric. Las líneas muestran dependencias entre items y no ejecutan nada.',
      criticalPathDuration: 'Tiempo total estimado (camino más largo)',
      failedNodeCount: 'con fallos previos',
      controlFlowLegend: 'Flechas: verde = si tiene éxito, rojo = si falla, gris = siempre. Las demás muestran dependencias de datos inferidas.',
      blockerCount: 'bloqueos',
      wave: 'Oleada',
      dependencies: 'dependencias',
      dependency: 'dependencia',
      nodes: 'nodos',
      readySources: 'Entradas leídas',
      writtenData: 'Datos escritos',
      dataStores: 'Almacenes de datos',
      executableProcesses: 'Procesos ejecutables',
      dependentProcesses: 'Procesos dependientes',
      modelRefresh: 'Refresh modelos',
      dataStores: 'Datos / orígenes',
      consumption: 'Consumo validado',
      critical: 'Crítico',
      failure: 'Fallo',
      parallel: 'Paralelo',
      scheduled: 'Programado',
      avg: 'Media',
      failShort: 'fallos',
      sourceEdge: 'origen',
      readEdge: 'lee',
      writeEdge: 'escribe',
      referenceEdge: 'referencia',
      executeEdge: 'ejecuta',
      modelEdge: 'modelo',
      reportEdge: 'consumo',
      humanOnly: 'Propuesta visual. No despliega ni modifica Fabric.',
      freshnessNotice: date => `Las señales de crítico/paralelo/horario reflejan el último análisis completo de orquestación (${date}). Si un workspace se escaneó después con el botón de escaneo rápido, su linaje puede ser más reciente que estas señales.`,
      selectedScope: 'Alcance seleccionado',
      rendered: 'Renderizados',
      hidden: 'ocultos por límite visual'
    },
    statusLabels: {
      confirmed: 'Confirmado',
      likely: 'No confirmado',
      catalogOnly: 'Solo catálogo',
      unknown: 'Sin evidencia',
      blocked: 'Bloqueado por evidencia'
    },
    impactLabels: {
      summary: 'Resumen de impacto',
      sourceObjects: 'Objetos origen',
      directItems: 'Items directos',
      downstreamReports: 'Informes descendentes',
      exactTypes: 'Tipos exactos',
      unresolvedTypes: 'Tipos pendientes',
      catalogObjects: 'Objetos catálogo',
      catalogConfirmed: 'Catálogo confirmado',
      catalogOnly: 'Objeto conocido sin consumidor detectado',
      noDetectedImpact: 'Sin impacto directo detectado',
      totalImpact: 'impactos',
      affectedItems: 'Afectados directos',
      reports: 'Informes',
      semanticModels: 'modelos',
      notebooks: 'notebooks',
      copyjobs: 'copyjobs',
      pipelines: 'pipelines',
      dataflows: 'dataflows',
      workspaces: 'workspaces',
      sourceObject: 'Objeto origen',
      sourceMetadata: 'Metadatos origen',
      impactPath: 'Ruta de impacto',
      directImpact: 'Impacto directo',
      downstream: 'Descendencia por modelo semántico',
      selectedScope: 'Alcance seleccionado',
      allScope: 'Todos los workspaces',
      noImpact: 'No hay impactos para los filtros actuales.',
      hiddenObjects: 'objetos ocultos por límite visual',
      hiddenItems: 'items más',
      showLess: 'Ver menos',
      typeEvidence: 'Evidencia de tipo',
      maxImpact: 'Máximo impacto',
      itemPreview: 'Vista previa',
      sourceTypeFilter: 'Tipo de origen',
      dataStoreFilter: 'BBDD / Lakehouse / Warehouse',
      objectTypeFilter: 'Tipo de objeto',
      objectFilter: 'Tabla / vista / SP / file',
      objectSearchPlaceholder: 'Buscar objeto concreto...',
      objectSearchHint: 'Selecciona un objeto para limpiar la vista.',
      objectSearchResults: 'objetos coincidentes',
      selectedObjects: 'Objetos seleccionados',
      matchingObjects: 'Objetos coincidentes',
      oneRowPerObject: 'Un objeto por fila, impacto clasificado por tipo.',
      otherElements: 'Otros elementos',
      clearObject: 'Limpiar',
      catalogStatus: 'Estado catálogo',
      sqlEndpoint: 'SQL Endpoint',
      endpointResolution: 'Resolución endpoint',
      catalogEvidence: 'Evidencia catálogo',
      breakdownEmpty: 'No hay elementos en esta categoría.',
      writerTitle: '¿Quién genera este objeto?',
      writerHint: 'Proceso Fabric (CopyJob, Notebook, Dataflow o Pipeline) que escribe en este objeto, y su última ejecución. Solo se puede saber cuando el origen es un proceso escaneado en Fabric -- si el objeto viene de un sistema externo (SQL Server, etc.) sin un proceso Fabric que lo escriba, no hay forma de saberlo con la información disponible.',
      noWriterDetected: 'No se detectó ningún proceso Fabric que escriba en este objeto (probablemente un origen externo, o el proceso que lo escribe no ha sido escaneado todavía).',
      noExecutionData: 'Sin datos de ejecución'
    },
    diagramFilterLabels: {
      sourceType: 'Tipo de origen',
      dataStore: 'Base de datos / Lakehouse / Warehouse',
      objectType: 'Tipo de objeto final',
      objects: 'Tablas, vistas, SP o archivos',
      selectAllObjects: 'Seleccionar todo',
      selectedObjects: 'objetos seleccionados',
      availableObjects: 'objetos disponibles',
      noObjects: 'No hay objetos para estos filtros.',
      listHint: 'Marca solo los objetos que quieres ver en el diagrama.'
    },
    sourceTypeLabels: {
      SQL: 'SQL Server',
      FabricOrSQL: 'SQL endpoint / SQL Server',
      Fabric: 'Fabric Lakehouse / Warehouse',
      FabricSqlEndpointMetadata: 'SQL endpoint',
      Lakehouse: 'Lakehouse',
      LakehouseTable: 'Tabla de Lakehouse',
      File: 'Archivo',
      SharePoint: 'SharePoint',
      NotebookStaticData: 'Objetos detectados en notebook',
      ExternalAPI: 'API externa',
      CommonDataService: 'Dataverse',
      MicrosoftOutlook: 'Outlook',
      CopyJob: 'CopyJob',
      AmazonS3: 'Amazon S3',
      AzureDataLakeStorage: 'Azure Data Lake Storage',
      AmazonRedshift: 'Amazon Redshift',
      FabricDataPipelines: 'Pipeline de Fabric',
      Odbc: 'ODBC',
      AnalysisServices: 'Analysis Services',
      OData: 'OData',
      DataPipeline: 'Pipeline de Fabric',
      CapacityMetricsCES: 'Métricas de capacidad',
      MetricsDataConnector: 'Métricas de Fabric',
      PowerBIDatasets: 'Modelo Power BI',
      UsageMetricsDataConnector: 'Métricas de uso',
      Web: 'Web',
      Eventstream: 'Eventstream',
      GraphQLApi: 'GraphQL API'
    },
    semanticFlow: {
      title: 'Linaje de modelos semánticos',
      hint: 'Vista limpia: informes -> modelo semántico -> fuentes reales y objetos.',
      selectedScope: 'Alcance seleccionado',
      renderedModels: 'modelos renderizados',
      sources: 'Fuentes / objetos',
      model: 'Modelo semántico',
      reports: 'Informes',
      noSources: 'Sin fuente real para los filtros actuales',
      noReports: 'Sin informes dependientes detectados',
      hiddenModels: 'modelos ocultos por límite visual',
      hiddenSources: 'fuentes más',
      hiddenReports: 'informes más',
      hiddenObjects: 'objetos más',
      production: 'Producción',
      stage: 'Etapa',
      pipeline: 'Pipeline',
      sourceObjects: 'Objetos fuente',
      refresh: 'Refresh',
      disabledSchedule: 'schedule deshabilitado'
    },
    empty: 'No hay datos para los filtros actuales.',
    flowTruncated: 'Selección muy grande: se muestra una parte para mantener la página fluida. Reduce los workspaces seleccionados o usa el buscador para ver el resto.',
    source: 'Origen',
    evidence: 'Evidencia',
    itemType: 'Tipo de item',
    all: 'Todo',
    confirmed: 'Confirmado',
    likely: 'No confirmado',
    unknown: 'Sin evidencia',
    lowEvidence: 'Revisión pendiente',
    lowEvidenceShort: 'Revisar',
    limitedLineage: 'Sin linaje detectado',
    limitedLineageShort: 'Sin linaje',
    elements: 'Elementos',
    sources: 'Orígenes',
    objects: 'Tablas / vistas / SP',
    selected: 'seleccionados',
    available: 'disponibles',
    uses: 'usos',
    fromWorkspace: 'desde',
    otherWorkspace: 'Otro workspace',
    otherWorkspaceShort: 'Otro WS',
    enabled: 'habilitados',
    disabled: 'deshabilitados',
    yes: 'Sí',
    mode: {
      semantic: 'Modelos semánticos',
      notebooks: 'Notebooks',
      copyjobs: 'CopyJobs',
      pipelines: 'Pipelines',
      dataflows: 'Dataflows',
      all: 'Todos',
      report: 'Informes',
      paginatedreport: 'Informes paginados',
      dashboard: 'Dashboards',
      sqlendpoint: 'SQL Endpoints',
      lakehouse: 'Lakehouses',
      warehouse: 'Warehouses',
      variablelibrary: 'Variable Libraries',
      environments: 'Environments',
      kqldashboard: 'KQL Dashboards',
      kqlqueryset: 'KQL Querysets',
      eventstream: 'Eventstreams',
      reflex: 'Reflex (Activator)',
      graphqlapi: 'GraphQL APIs',
      userdatafunction: 'User Data Functions',
      dataagent: 'Data Agents',
      datamart: 'Datamarts',
      mlexperiment: 'Experimentos ML',
      exploration: 'Exploraciones',
      sqldatabase: 'Bases de datos SQL',
      app: 'Apps'
    },
    legend: {
      workspace: 'Workspace',
      item: 'Elemento',
      report: 'Informe',
      source: 'Origen',
      object: 'Tabla/vista/SP',
      pipeline: 'Pipeline',
      deployment: 'Deployment pipeline',
      cross: 'Otro workspace'
    },
    nodeKinds: {
      workspace: 'Workspace',
      deploymentPipeline: 'Deployment pipeline',
      deploymentStage: 'Etapa deployment',
      item: 'Elemento',
      pipeline: 'Pipeline',
      report: 'Informe',
      source: 'Origen',
      object: 'Objeto',
      impactObject: 'Objeto origen',
      execute: 'Ejecución',
      group: 'Grupo'
    },
    confidenceLabels: {
      confirmed: 'Confirmado',
      likely: 'No confirmado',
      unknown: 'Sin evidencia',
      mixed: 'Mixto'
    },
    objectTypeSources: {
      override: 'Override confirmado',
      manual_review: 'Revisión manual',
      definition_extraction: 'Extracción definición',
      tmdl_lookup_pending: 'TMDL pendiente de tipo físico',
      native_query_pending: 'Consulta nativa pendiente',
      metadata_readonly: 'Metadata solo lectura',
      sql_endpoint_catalog: 'Catálogo SQL Endpoint',
      automatic_candidate: 'Candidato automático',
      override_conflict: 'Conflicto de override',
      manual_review_conflict: 'Conflicto de revisión manual'
    },
    jobStatuses: {
      Completed: 'Completado',
      Failed: 'Fallido',
      Cancelled: 'Cancelado',
      Canceled: 'Cancelado',
      InProgress: 'En ejecución',
      Running: 'En ejecución',
      Unknown: 'Desconocido'
    },
    groups: {
      reports: 'Informes asociados',
      sources: 'Orígenes de datos',
      readSources: 'Orígenes leídos',
      writeTargets: 'Destinos escritos',
      executedObjects: 'Objetos ejecutados',
      referenceSources: 'Referencias sin dirección',
      detectedReadObjects: 'Objetos leídos',
      detectedWriteObjects: 'Objetos escritos',
      detectedExecutedObjects: 'Objetos ejecutados',
      detectedReferencedObjects: 'Objetos referenciados',
      objects: 'Tablas, vistas o SP',
      executes: 'Elementos activados',
      models: 'Modelos usados'
    },
    itemTypes: {
      App: 'Aplicación',
      CopyJob: 'CopyJob',
      Dashboard: 'Dashboard',
      DataAgent: 'Data Agent',
      Datamart: 'Datamart',
      Dataflow: 'Dataflow',
      DataPipeline: 'Pipeline',
      Environment: 'Environment',
      Eventhouse: 'Eventhouse',
      Eventstream: 'Eventstream',
      Exploration: 'Exploración',
      GraphQLApi: 'GraphQL API',
      KQLDashboard: 'KQL Dashboard',
      KQLDatabase: 'KQL Database',
      KQLQueryset: 'KQL Queryset',
      Lakehouse: 'Lakehouse',
      MirroredDatabase: 'Base de datos espejada',
      MLExperiment: 'Experimento ML',
      MLModel: 'Modelo ML',
      Notebook: 'Notebook',
      PaginatedReport: 'Informe paginado',
      Reflex: 'Reflex',
      Report: 'Informe',
      SemanticModel: 'Modelo semántico',
      SparkJobDefinition: 'Definición de trabajo Spark',
      SQLDatabase: 'Base de datos SQL',
      SQLEndpoint: 'SQL Endpoint',
      UserDataFunction: 'User Data Function',
      VariableLibrary: 'Variable Library',
      Warehouse: 'Warehouse'
    },
    roleTypes: {
      Admin: 'Administrador',
      Member: 'Miembro',
      Contributor: 'Colaborador',
      Viewer: 'Visor'
    },
    objectTypes: {
      table: 'Tabla',
      view: 'Vista',
      stored_procedure: 'Procedimiento almacenado',
      file: 'Archivo',
      shortcut: 'Acceso directo',
      query: 'Consulta',
      table_or_view: 'Tabla o vista',
      native_query_object: 'Objeto SQL',
      manual_object: 'Objeto manual',
      unknown: 'Desconocido'
    },
    help: {
      title: '¿Qué es esto?',
      items: [
        'Mapa de qué está conectado con qué en Microsoft Fabric: workspaces, notebooks, pipelines, modelos semánticos, informes y las tablas/vistas que leen y escriben.',
        'Modelos semánticos / Notebooks / CopyJobs / Pipelines / Todos: distintas vistas del mismo mapa, cada una centrada en un tipo de elemento.',
        'Solo lectura: esta web no cambia nada en Fabric. Nadie puede modificar, borrar ni ejecutar nada desde aquí.',
        'Impacto: busca un objeto de origen (tabla, vista, procedimiento) y muestra qué se vería afectado si cambiara.'
      ],
      lastUpdated: date => `Datos actualizados: ${date}`,
      lastUpdatedUnknown: 'Fecha de actualización no disponible'
    },
    glossary: {
      title: 'Qué significa esto',
      iconLabel: 'Más información',
      terms: {
        confidence: {
          label: 'Confianza',
          text: 'Confirmado: el linaje se verificó directamente (definición del objeto descargada, conexión de Fabric confirmada, etc.). No confirmado: hay indicios razonables (coincidencia de nombres, patrón de código) pero sin verificación directa. Sin evidencia: no se pudo determinar con la información escaneada; queda visible para revisión manual. Mixto: la lista combina orígenes con distinta confianza.'
        },
        objectTypeSource: {
          label: 'Origen tipo objeto',
          text: 'Override confirmado: alguien marcó manualmente el tipo real y se confirma con una fuente adicional. Revisión manual: se marcó a mano tras revisión humana, sin verificación automática adicional. Extracción definición: el tipo se determinó descargando y analizando la definición real del objeto en Fabric. TMDL pendiente de tipo físico: detectado en el modelo semántico, falta confirmar el tipo físico exacto en el origen. Consulta nativa pendiente: detectado en SQL embebido, falta confirmar el tipo exacto en el origen. Metadata solo lectura: proviene de un catálogo de solo lectura, sin poder confirmarse con una consulta adicional. Catálogo SQL Endpoint: proviene del catálogo de objetos del SQL Endpoint de un Lakehouse/Warehouse. Candidato automático: detección automática sin ninguna de las fuentes anteriores; es la mejor suposición disponible. Conflicto de override / Conflicto de revisión manual: hay más de un valor manual distinto para el mismo objeto; requiere revisión.'
        },
        analysisStatus: {
          label: 'Estado análisis',
          text: 'Analizado completo: se pudo descargar o consultar toda la información necesaria para este elemento (definición, conexiones, etc.). Análisis parcial: falta información para completar el análisis (por ejemplo, la API de definición no estaba disponible para este tipo de elemento en esta fase); el linaje mostrado puede no ser completo.'
        },
        lineageQuality: {
          label: 'Revisión linaje',
          text: 'Sin linaje detectado: no se encontró ningún origen, informe, modelo ni ejecución asociado a este elemento con la información escaneada hasta ahora. No siempre significa que el elemento no tenga relaciones reales -- puede que aún no se haya escaneado la evidencia necesaria.'
        }
      }
    },
    loading: {
      title: 'Cargando linaje...',
      downloading: pct => `Descargando datos... ${pct}%`,
      parsing: 'Procesando datos...',
      file: {
        data: 'Linaje principal',
        impact: 'Impacto de objetos',
        notebookSuperLineage: 'Linaje detallado de notebooks'
      },
      fallback: 'Cargando (modo compatibilidad)...'
    },
    detail: {
      overview: 'Resumen',
      operations: 'Operación',
      lineage: 'Linaje',
      evidence: 'Evidencia',
      workspace: 'Workspace',
      contextWorkspace: 'Workspace inspeccionado',
      hostedWorkspace: 'Workspace real',
      environment: 'Entorno',
      type: 'Tipo',
      rawObjectType: 'Tipo original',
      objectTypeSource: 'Origen tipo objeto',
      objectTypeConfidence: 'Estado tipo objeto',
      objectTypeEvidence: 'Evidencia tipo objeto',
      capacity: 'Capacidad',
      capacityId: 'ID capacidad',
      capacityRegion: 'Región capacidad',
      description: 'Descripción',
      sensitivityLabel: 'Etiqueta de sensibilidad',
      devopsRepo: 'Repositorio Azure DevOps',
      openInFabric: 'Abrir en Fabric',
      openInFabricText: 'Abrir elemento ↗',
      domain: 'Dominio',
      owner: 'Owner',
      admins: 'Usuarios/admins',
      accessRoles: 'Roles de acceso',
      yourRole: 'Tu rol en este workspace',
      yourRoleBadge: 'tú',
      deploymentPipeline: 'Deployment pipeline',
      deploymentStage: 'Etapa',
      stageOrder: 'Orden etapa',
      stageWorkspace: 'Workspace etapa',
      indexedWorkspaces: 'Workspaces indexados',
      status: 'Estado',
      name: 'Nombre',
      qualified: 'Nombre técnico',
      server: 'Servidor',
      database: 'Base / origen',
      schema: 'Schema',
      table: 'Tabla',
      columns: 'Columnas',
      columnType: 'Tipo de dato',
      columnNullable: 'Permite nulos',
      sourceType: 'Tipo de origen',
      pipelineActivity: 'Actividad pipeline',
      pipelineActivityType: 'Tipo actividad',
      invokedItem: 'Item invocado',
      migration: 'Equivalente Fabric',
      migrationStatus: 'Estado migración',
      confidence: 'Confianza',
      defaultIdentity: 'Identidad predeterminada',
      tags: 'Etiquetas',
      curatedTags: 'Etiquetas (curadas)',
      dataProduct: 'Producto de datos',
      dataProductOwner: 'Dueño del producto de datos',
      certified: 'Certificado',
      certifiedBy: 'Certificado por',
      certifiedNote: 'Nota de certificación',
      usageType: 'Relación',
      usageTypeLabels: {
        reads_from: 'Lee de',
        writes_to: 'Escribe en',
        executes: 'Ejecuta',
        unknown: 'Desconocido'
      },
      schedules: 'Schedules',
      scheduledTime: 'Hora habitual',
      avgDuration: 'Duración media',
      runs: 'Ejecuciones',
      failures: 'Fallos',
      latestStatus: 'Último estado',
      sharedUses: 'Usos en vista',
      lineageQuality: 'Revisión linaje',
      planningEvidence: 'Planificación',
      planningEvidenceButton: 'Ver planificación detallada',
      fieldColumn: 'Campo',
      valueColumn: 'Valor',
      noData: 'Sin datos',
      criticalPath: 'Ruta crítica',
      failureHotspot: 'Punto crítico de fallos',
      parallelCandidates: 'Paralelismo candidato',
      orchestrationGroup: 'Grupo orquestación',
      recommendationHint: 'Recomendación',
      analysisNotes: 'Notas análisis',
      analysisStatus: 'Estado análisis',
      analysisStatusAnalyzed: 'Analizado completo',
      analysisStatusPartial: 'Análisis parcial'
      ,
      objectKey: 'Clave objeto',
      sourceServer: 'Servidor origen',
      objectTypeValues: 'Tipos detectados',
      objectTypeSources: 'Fuentes de tipo',
      affectedItems: 'Items afectados',
      downstreamReports: 'Informes descendentes',
      impactPath: 'Ruta de impacto',
      sourceObjects: 'Objetos origen',
      sourceObjectsBySchema: 'Objetos por schema',
      relatedSources: 'Fuentes relacionadas',
      relatedReports: 'Informes relacionados',
      relatedModels: 'Modelos relacionados',
      upstreamItem: 'Proceso upstream',
      latestArrival: 'Última llegada local',
      latestStart: 'Último inicio',
      latestEnd: 'Último fin',
      semanticTable: 'Tabla semántica',
      semanticTables: 'Tablas semánticas',
      semanticTableCount: 'Tablas semánticas',
      physicalObjects: 'Objetos físicos',
      noSemanticTable: 'Sin tabla semántica',
      dynamicVariable: 'Variable de código',
      dynamicVariableHint: name => `El notebook calcula este nombre en tiempo de ejecución a partir de la variable "${name}"; no es un nombre de tabla literal.`,
      invocationParameters: 'Parámetros de invocación',
      hiddenRows: 'Registros adicionales',
      objectCount: 'Objetos',
      reportCount: 'Informes',
      sourceCount: 'Fuentes',
      affectedModels: 'Modelos afectados',
      inspectedScope: 'Alcance inspeccionado',
      noSelection: 'Selecciona una tarjeta para ver el detalle técnico sin cargar la vista principal.'
      ,
      exportPdf: 'Descargar PDF',
      exportPng: 'Diagrama PNG',
      exportExcel: 'Descargar Excel',
      pdfExportHint: 'Genera un informe A4 local con el diagrama visible y el resumen seleccionado.',
      pngExportHint: 'Descarga una imagen PNG local de alta resolución del diagrama seleccionado con sus nodos desplegados.',
      excelExportHint: 'Descarga la lista completa de elementos afectados por este objeto.',
      lineageExcelHint: 'Descarga la lista filtrada de objetos finales del diagrama seleccionado.',
      excelGenerated: 'Generado',
      excelImpactList: 'Lista de impactos',
      excelLineageList: 'Lista de linaje',
      excelDpOrWorkspace: 'DP / WS',
      excelNotebookOrItem: 'NB / item',
      excelDirection: 'Origen / destino',
      excelFinalObject: 'Tabla / vista / SP / archivo',
      excelSourceOrTarget: 'Origen / destino de datos',
      excelParentItem: 'Item contenedor',
      pdfDiagram: 'Diagrama visible',
      pdfSummary: 'Resumen del detalle',
      pdfGenerated: 'Generado',
      pdfView: 'Vista',
      pdfSelection: 'Seleccion',
      pdfAdditionalRows: 'Filas adicionales resumidas'
    }
  },
  en: {
    title: 'Lineage Explorer',
    search: 'Search',
    searchPlaceholder: 'Hosting workspace, model, notebook, source...',
    reset: 'Reset',
    reinvestigate: 'Reinvestigate',
    filter: 'Filter',
    back: 'Back',
    focus: 'WS index',
    details: 'Details',
    inspect: 'Inspection',
    impact: 'Impact',
    schedule: 'Planning',
    selectAll: 'All',
    clear: 'Clear',
    workspaceSearchToggle: 'Search and select workspace...',
    workspaceSearchPlaceholder: 'Type to search...',
    workspaceSearchNoMatch: 'No matches',
    workspaces: 'Workspaces',
    workspaceHint: 'Workspaces hosting items for the selected tree',
    deploymentPipelines: 'Deployment pipelines',
    deploymentPipeline: 'Deployment pipeline',
    deploymentStage: 'Stage',
    stageFilter: 'Deployment workspaces',
    stageFilterAll: 'All',
    stageFilterHint: 'No selection: all',
    deploymentEnvironmentFilter: 'DEV/QA/PRO filter',
    noDeploymentPipeline: 'No deployment pipeline',
    assignedStages: 'assigned stages',
    indexedWorkspaces: 'indexed workspaces',
    productionWorkspace: 'PRO workspace',
    productionModels: 'PRO models',
    stageNotIndexed: 'No local workspace',
    stageIndexed: 'Indexed',
    unassignedStage: 'No local workspace',
    selectWorkspace: 'Select a workspace',
    graphHint: 'Expand the tree progressively to keep the screen clean.',
    planningTitle: 'Candidate planning',
    planningHint: 'Item DAG proposal: run CopyJobs/Notebooks/Pipelines and refresh semantic models with clean dependencies.',
    impactTitle: 'Reverse impact',
    impactHint: 'Search a table, view, stored procedure, file, or query and review which items and reports could be affected.',
    reinvestigateTitle: 'Read-only reinvestigation',
    reinvestigateHint: 'This HTML does not execute changes. Use these terminal commands with human approval.',
    refresh: {
      latest: 'Latest refresh',
      artifacts: 'Artifact freshness',
      commands: 'Recommended commands',
      when: 'When to use it',
      safety: 'Safety rule',
      packageGenerated: 'Embedded status',
      runLog: 'Run log',
      manifest: 'Manifest',
      mode: 'Mode',
      status: 'Status',
      started: 'Started',
      ended: 'Ended',
      duration: 'Duration',
      visual: 'Visual validation',
      external: 'External systems',
      noExternal: 'None',
      passed: 'passed',
      failedCount: 'failed',
      skipped: 'skipped',
      lines: 'lines',
      modified: 'modified',
      age: 'age',
      completed: 'completed',
      failed: 'failed',
      unknownStatus: 'unknown',
      none: 'No embedded data',
      useLocal: 'Visual changes, documentation, local mapping, or standalone rebuild.',
      useLocalVisual: 'Before presenting the web or closing a visual phase.',
      useInventory: 'When workspaces, items, connections, or sources changed in Fabric.',
      useFull: 'Before planning decisions involving schedules, durations, and refreshes.',
      useTmdl: 'When semantic models changed or more tables/views/native queries are needed.',
      safetyText: 'The web does not modify Fabric or execute commands. Final approval and execution are human-controlled.'
    },
    planning: {
      summary: 'DAG summary',
      readinessSummary: 'Semantic model readiness',
      dataGroups: 'sources / stores',
      affectedModels: 'affected models',
      modelsAffected: 'Affected models',
      dataReadiness: 'Data readiness',
      dataArrival: 'Data arrival',
      noArrivalEvidence: 'No local latest arrival',
      upstreamLatest: 'Latest upstream run',
      noUpstream: 'No linked upstream process',
      refreshEvidence: 'Model refresh',
      noRefreshEvidence: 'No recent refresh recorded',
      modelSchedule: 'Model schedule',
      objectCount: 'source objects',
      readinessHint: 'Visual canvas: processes and semantic models connected by item dependencies.',
      noReadiness: 'No semantic model sources for the current scope.',
      sourceSelectorTitle: 'Select Lakehouse / source',
      sourceSearchPlaceholder: 'Search Lakehouse, SQL, store, or source...',
      sourceSearchHint: 'Filter or select one or more sources to show only their affected models.',
      selectedSources: 'Selected sources',
      matchingSources: 'Available sources',
      clearSources: 'Clear sources',
      noSourceMatch: 'No sources for this selection.',
      canvasHint: 'Proposed Fabric item flow. Lines show item dependencies and do not execute anything.',
      criticalPathDuration: 'Total estimated time (longest chain)',
      failedNodeCount: 'with prior failures',
      controlFlowLegend: 'Arrows: green = on success, red = on failure, gray = always. All other arrows show inferred data dependencies.',
      blockerCount: 'blockers',
      wave: 'Wave',
      dependencies: 'dependencies',
      dependency: 'dependency',
      nodes: 'nodes',
      readySources: 'Read inputs',
      writtenData: 'Written data',
      dataStores: 'Data stores',
      executableProcesses: 'Executable processes',
      dependentProcesses: 'Dependent processes',
      modelRefresh: 'Model refresh',
      dataStores: 'Data stores / origins',
      consumption: 'Validated consumption',
      critical: 'Critical',
      failure: 'Failure',
      parallel: 'Parallel',
      scheduled: 'Schedule',
      avg: 'Avg',
      failShort: 'failures',
      sourceEdge: 'source',
      readEdge: 'reads',
      writeEdge: 'writes',
      referenceEdge: 'reference',
      executeEdge: 'executes',
      modelEdge: 'model',
      reportEdge: 'consumption',
      humanOnly: 'Visual proposal. It does not deploy or modify Fabric.',
      freshnessNotice: date => `Critical/parallel/schedule signals reflect the last full orchestration analysis (${date}). If a workspace was scanned afterwards with the quick scan button, its lineage may be newer than these signals.`,
      selectedScope: 'Selected scope',
      rendered: 'Rendered',
      hidden: 'hidden by visual limit'
    },
    statusLabels: {
      confirmed: 'Confirmed',
      likely: 'Unconfirmed',
      catalogOnly: 'Catalog-only',
      unknown: 'No evidence',
      blocked: 'Evidence-blocked'
    },
    impactLabels: {
      summary: 'Impact summary',
      sourceObjects: 'Source objects',
      directItems: 'Direct items',
      downstreamReports: 'Downstream reports',
      exactTypes: 'Exact types',
      unresolvedTypes: 'Pending types',
      catalogObjects: 'Catalog objects',
      catalogConfirmed: 'Catalog confirmed',
      catalogOnly: 'Known object without detected consumer',
      noDetectedImpact: 'No direct impact detected',
      totalImpact: 'impacts',
      affectedItems: 'Directly affected',
      reports: 'Reports',
      semanticModels: 'models',
      notebooks: 'notebooks',
      copyjobs: 'copyjobs',
      pipelines: 'pipelines',
      dataflows: 'dataflows',
      workspaces: 'workspaces',
      sourceObject: 'Source object',
      sourceMetadata: 'Source metadata',
      impactPath: 'Impact path',
      directImpact: 'Direct impact',
      downstream: 'Semantic model downstream',
      selectedScope: 'Selected scope',
      allScope: 'All workspaces',
      noImpact: 'No impacts for the current filters.',
      hiddenObjects: 'objects hidden by visual limit',
      hiddenItems: 'more items',
      showLess: 'Show less',
      typeEvidence: 'Type evidence',
      maxImpact: 'Max impact',
      itemPreview: 'Preview',
      sourceTypeFilter: 'Source type',
      dataStoreFilter: 'DB / Lakehouse / Warehouse',
      objectTypeFilter: 'Object type',
      objectFilter: 'Table / view / SP / file',
      objectSearchPlaceholder: 'Search concrete object...',
      objectSearchHint: 'Select one object to clean up the view.',
      objectSearchResults: 'matching objects',
      selectedObjects: 'Selected objects',
      matchingObjects: 'Matching objects',
      oneRowPerObject: 'One source object per row, impact classified by type.',
      otherElements: 'Other elements',
      clearObject: 'Clear',
      catalogStatus: 'Catalog status',
      sqlEndpoint: 'SQL Endpoint',
      endpointResolution: 'Endpoint resolution',
      catalogEvidence: 'Catalog evidence',
      breakdownEmpty: 'No items in this category.',
      writerTitle: 'Who generates this object?',
      writerHint: 'The Fabric process (CopyJob, Notebook, Dataflow, or Pipeline) that writes to this object, and its last run. This is only knowable when the writer is itself a scanned Fabric process -- if the object comes from an external system (SQL Server, etc.) with no Fabric process writing to it, there is no way to know from the data available.',
      noWriterDetected: 'No Fabric process writing to this object was detected (likely an external source, or the process that writes it has not been scanned yet).',
      noExecutionData: 'No execution data'
    },
    diagramFilterLabels: {
      sourceType: 'Source type',
      dataStore: 'Database / Lakehouse / Warehouse',
      objectType: 'Final object type',
      objects: 'Tables, views, SP or files',
      selectAllObjects: 'Select all',
      selectedObjects: 'selected objects',
      availableObjects: 'available objects',
      noObjects: 'No objects for these filters.',
      listHint: 'Tick only the objects you want in the diagram.'
    },
    sourceTypeLabels: {
      SQL: 'SQL Server',
      FabricOrSQL: 'SQL endpoint / SQL Server',
      Fabric: 'Fabric Lakehouse / Warehouse',
      FabricSqlEndpointMetadata: 'SQL endpoint',
      Lakehouse: 'Lakehouse',
      LakehouseTable: 'Lakehouse table',
      File: 'File',
      SharePoint: 'SharePoint',
      NotebookStaticData: 'Notebook detected objects',
      ExternalAPI: 'External API',
      CommonDataService: 'Dataverse',
      MicrosoftOutlook: 'Outlook',
      CopyJob: 'CopyJob',
      AmazonS3: 'Amazon S3',
      AzureDataLakeStorage: 'Azure Data Lake Storage',
      AmazonRedshift: 'Amazon Redshift',
      FabricDataPipelines: 'Fabric pipeline',
      Odbc: 'ODBC',
      AnalysisServices: 'Analysis Services',
      OData: 'OData',
      DataPipeline: 'Fabric pipeline',
      CapacityMetricsCES: 'Capacity metrics',
      MetricsDataConnector: 'Fabric metrics',
      PowerBIDatasets: 'Power BI model',
      UsageMetricsDataConnector: 'Usage metrics',
      Web: 'Web',
      Eventstream: 'Eventstream',
      GraphQLApi: 'GraphQL API'
    },
    semanticFlow: {
      title: 'Semantic model lineage',
      hint: 'Clean view: reports -> semantic model -> real sources and objects.',
      selectedScope: 'Selected scope',
      renderedModels: 'rendered models',
      sources: 'Sources / objects',
      model: 'Semantic model',
      reports: 'Reports',
      noSources: 'No real source for the current filters',
      noReports: 'No dependent reports detected',
      hiddenModels: 'models hidden by visual limit',
      hiddenSources: 'more sources',
      hiddenReports: 'more reports',
      hiddenObjects: 'more objects',
      production: 'Production',
      stage: 'Stage',
      pipeline: 'Pipeline',
      sourceObjects: 'Source objects',
      refresh: 'Refresh',
      disabledSchedule: 'disabled schedule'
    },
    empty: 'No data for the current filters.',
    flowTruncated: 'Selection too large: showing a subset to keep the page responsive. Narrow down the selected workspaces or use search to see the rest.',
    source: 'Source',
    evidence: 'Evidence',
    itemType: 'Item type',
    all: 'All',
    confirmed: 'Confirmed',
    likely: 'Unconfirmed',
    unknown: 'No evidence',
    lowEvidence: 'Needs review',
    lowEvidenceShort: 'Review',
    limitedLineage: 'No lineage detected',
    limitedLineageShort: 'No lineage',
    elements: 'Items',
    sources: 'Sources',
    objects: 'Tables / views / SP',
    selected: 'selected',
    available: 'available',
    uses: 'uses',
    fromWorkspace: 'from',
    otherWorkspace: 'Other workspace',
    otherWorkspaceShort: 'Other WS',
    enabled: 'enabled',
    disabled: 'disabled',
    yes: 'Yes',
    mode: {
      semantic: 'Semantic models',
      notebooks: 'Notebooks',
      copyjobs: 'CopyJobs',
      pipelines: 'Pipelines',
      dataflows: 'Dataflows',
      all: 'All',
      report: 'Reports',
      paginatedreport: 'Paginated reports',
      dashboard: 'Dashboards',
      sqlendpoint: 'SQL Endpoints',
      lakehouse: 'Lakehouses',
      warehouse: 'Warehouses',
      variablelibrary: 'Variable Libraries',
      environments: 'Environments',
      kqldashboard: 'KQL Dashboards',
      kqlqueryset: 'KQL Querysets',
      eventstream: 'Eventstreams',
      reflex: 'Reflex (Activator)',
      graphqlapi: 'GraphQL APIs',
      userdatafunction: 'User Data Functions',
      dataagent: 'Data Agents',
      datamart: 'Datamarts',
      mlexperiment: 'ML Experiments',
      exploration: 'Explorations',
      sqldatabase: 'SQL Databases',
      app: 'Apps'
    },
    legend: {
      workspace: 'Workspace',
      item: 'Item',
      report: 'Report',
      source: 'Source',
      object: 'Table/view/SP',
      pipeline: 'Pipeline',
      deployment: 'Deployment pipeline',
      cross: 'Other workspace'
    },
    nodeKinds: {
      workspace: 'Workspace',
      deploymentPipeline: 'Deployment pipeline',
      deploymentStage: 'Deployment stage',
      item: 'Item',
      pipeline: 'Pipeline',
      report: 'Report',
      source: 'Source',
      object: 'Object',
      impactObject: 'Source object',
      execute: 'Execution',
      group: 'Group'
    },
    confidenceLabels: {
      confirmed: 'Confirmed',
      likely: 'Unconfirmed',
      unknown: 'No evidence',
      mixed: 'Mixed'
    },
    objectTypeSources: {
      override: 'Confirmed override',
      manual_review: 'Manual review',
      definition_extraction: 'Definition extraction',
      tmdl_lookup_pending: 'TMDL pending physical type',
      native_query_pending: 'Native query pending',
      metadata_readonly: 'Read-only metadata',
      sql_endpoint_catalog: 'SQL Endpoint catalog',
      automatic_candidate: 'Automatic candidate',
      override_conflict: 'Override conflict',
      manual_review_conflict: 'Manual review conflict'
    },
    jobStatuses: {
      Completed: 'Completed',
      Failed: 'Failed',
      Cancelled: 'Cancelled',
      Canceled: 'Cancelled',
      InProgress: 'In progress',
      Running: 'Running',
      Unknown: 'Unknown'
    },
    groups: {
      reports: 'Associated reports',
      sources: 'Data sources',
      readSources: 'Read sources',
      writeTargets: 'Write targets',
      executedObjects: 'Executed objects',
      referenceSources: 'Undirected references',
      detectedReadObjects: 'Read objects',
      detectedWriteObjects: 'Written objects',
      detectedExecutedObjects: 'Executed objects',
      detectedReferencedObjects: 'Referenced objects',
      objects: 'Tables, views or SP',
      executes: 'Activated items',
      models: 'Used models'
    },
    itemTypes: {
      App: 'App',
      CopyJob: 'CopyJob',
      Dashboard: 'Dashboard',
      DataAgent: 'Data Agent',
      Datamart: 'Datamart',
      Dataflow: 'Dataflow',
      DataPipeline: 'Pipeline',
      Environment: 'Environment',
      Eventhouse: 'Eventhouse',
      Eventstream: 'Eventstream',
      Exploration: 'Exploration',
      GraphQLApi: 'GraphQL API',
      KQLDashboard: 'KQL Dashboard',
      KQLDatabase: 'KQL Database',
      KQLQueryset: 'KQL Queryset',
      Lakehouse: 'Lakehouse',
      MirroredDatabase: 'Mirrored database',
      MLExperiment: 'ML experiment',
      MLModel: 'ML model',
      Notebook: 'Notebook',
      PaginatedReport: 'Paginated report',
      Reflex: 'Reflex',
      Report: 'Report',
      SemanticModel: 'Semantic model',
      SparkJobDefinition: 'Spark job definition',
      SQLDatabase: 'SQL database',
      SQLEndpoint: 'SQL Endpoint',
      UserDataFunction: 'User Data Function',
      VariableLibrary: 'Variable Library',
      Warehouse: 'Warehouse'
    },
    roleTypes: {
      Admin: 'Admin',
      Member: 'Member',
      Contributor: 'Contributor',
      Viewer: 'Viewer'
    },
    objectTypes: {
      table: 'Table',
      view: 'View',
      stored_procedure: 'Stored procedure',
      file: 'File',
      shortcut: 'Shortcut',
      query: 'Query',
      table_or_view: 'Table or view',
      native_query_object: 'SQL object',
      manual_object: 'Manual object',
      unknown: 'Unknown'
    },
    help: {
      title: 'What is this?',
      items: [
        'A map of what is connected to what in Microsoft Fabric: workspaces, notebooks, pipelines, semantic models, reports, and the tables/views they read and write.',
        'Semantic models / Notebooks / CopyJobs / Pipelines / All: different views of the same map, each focused on one item type.',
        'Read-only: this site never changes anything in Fabric. No one can modify, delete, or run anything from here.',
        'Impact: search for a source object (table, view, procedure) to see what would be affected if it changed.'
      ],
      lastUpdated: date => `Data last updated: ${date}`,
      lastUpdatedUnknown: 'Last update date not available'
    },
    glossary: {
      title: 'What this means',
      iconLabel: 'More information',
      terms: {
        confidence: {
          label: 'Confidence',
          text: 'Confirmed: the lineage was directly verified (object definition downloaded, Fabric connection confirmed, etc.). Unconfirmed: there is reasonable evidence (name match, code pattern) but no direct verification. No evidence: it could not be determined with the information scanned so far; left visible for manual review. Mixed: the list combines sources with different confidence levels.'
        },
        objectTypeSource: {
          label: 'Object type source',
          text: 'Confirmed override: someone manually flagged the real type and it is confirmed by an additional source. Manual review: flagged by hand after human review, with no additional automatic verification. Definition extraction: the type was determined by downloading and parsing the object\'s real definition in Fabric. TMDL pending physical type: detected in the semantic model, the exact physical type in the source still needs confirming. Native query pending: detected in embedded SQL, the exact type in the source still needs confirming. Read-only metadata: comes from a read-only catalog, cannot be confirmed with an additional query. SQL Endpoint catalog: comes from a Lakehouse/Warehouse SQL Endpoint object catalog. Automatic candidate: automatic detection with none of the sources above; it is the best available guess. Override conflict / Manual review conflict: there is more than one differing manual value for the same object; needs review.'
        },
        analysisStatus: {
          label: 'Analysis status',
          text: 'Fully analyzed: all the information needed for this item could be downloaded or queried (definition, connections, etc.). Partially analyzed: information is missing to complete the analysis (for example, the definition API was not available for this item type in this phase); the lineage shown may not be complete.'
        },
        lineageQuality: {
          label: 'Lineage review',
          text: 'No lineage detected: no source, report, model, or execution was found linked to this item with the information scanned so far. This does not always mean the item has no real relationships -- the evidence needed may simply not have been scanned yet.'
        }
      }
    },
    loading: {
      title: 'Loading lineage...',
      downloading: pct => `Downloading data... ${pct}%`,
      parsing: 'Processing data...',
      file: {
        data: 'Main lineage',
        impact: 'Object impact',
        notebookSuperLineage: 'Detailed notebook lineage'
      },
      fallback: 'Loading (compatibility mode)...'
    },
    detail: {
      overview: 'Overview',
      operations: 'Operations',
      lineage: 'Lineage',
      evidence: 'Evidence',
      workspace: 'Workspace',
      contextWorkspace: 'Inspected workspace',
      hostedWorkspace: 'Actual workspace',
      environment: 'Environment',
      type: 'Type',
      rawObjectType: 'Original type',
      objectTypeSource: 'Object type source',
      objectTypeConfidence: 'Object type status',
      objectTypeEvidence: 'Object type evidence',
      capacity: 'Capacity',
      capacityId: 'Capacity ID',
      capacityRegion: 'Capacity region',
      description: 'Description',
      sensitivityLabel: 'Sensitivity label',
      devopsRepo: 'Azure DevOps repository',
      openInFabric: 'Open in Fabric',
      openInFabricText: 'Open item ↗',
      domain: 'Domain',
      owner: 'Owner',
      admins: 'Users/admins',
      accessRoles: 'Access roles',
      yourRole: 'Your role in this workspace',
      yourRoleBadge: 'you',
      deploymentPipeline: 'Deployment pipeline',
      deploymentStage: 'Stage',
      stageOrder: 'Stage order',
      stageWorkspace: 'Stage workspace',
      indexedWorkspaces: 'Indexed workspaces',
      status: 'Status',
      name: 'Name',
      qualified: 'Qualified name',
      server: 'Server',
      database: 'Database / source',
      schema: 'Schema',
      table: 'Table',
      columns: 'Columns',
      columnType: 'Data type',
      columnNullable: 'Nullable',
      sourceType: 'Source type',
      pipelineActivity: 'Pipeline activity',
      pipelineActivityType: 'Activity type',
      invokedItem: 'Invoked item',
      migration: 'Fabric equivalent',
      migrationStatus: 'Migration status',
      confidence: 'Confidence',
      defaultIdentity: 'Default identity',
      tags: 'Tags',
      curatedTags: 'Curated tags',
      dataProduct: 'Data product',
      dataProductOwner: 'Data product owner',
      certified: 'Certified',
      certifiedBy: 'Certified by',
      certifiedNote: 'Certification note',
      usageType: 'Relationship',
      usageTypeLabels: {
        reads_from: 'Reads from',
        writes_to: 'Writes to',
        executes: 'Executes',
        unknown: 'Unknown'
      },
      schedules: 'Schedules',
      scheduledTime: 'Usual time',
      avgDuration: 'Average duration',
      runs: 'Runs',
      failures: 'Failures',
      latestStatus: 'Latest status',
      sharedUses: 'Uses in view',
      lineageQuality: 'Lineage review',
      planningEvidence: 'Planning',
      planningEvidenceButton: 'View planning details',
      fieldColumn: 'Field',
      valueColumn: 'Value',
      noData: 'No data',
      criticalPath: 'Critical path',
      failureHotspot: 'Failure hotspot',
      parallelCandidates: 'Parallel candidates',
      orchestrationGroup: 'Orchestration group',
      recommendationHint: 'Recommendation',
      analysisNotes: 'Analysis notes',
      analysisStatus: 'Analysis status',
      analysisStatusAnalyzed: 'Fully analyzed',
      analysisStatusPartial: 'Partially analyzed'
      ,
      objectKey: 'Object key',
      sourceServer: 'Source server',
      objectTypeValues: 'Detected types',
      objectTypeSources: 'Type sources',
      affectedItems: 'Affected items',
      downstreamReports: 'Downstream reports',
      impactPath: 'Impact path',
      sourceObjects: 'Source objects',
      sourceObjectsBySchema: 'Objects by schema',
      relatedSources: 'Related sources',
      relatedReports: 'Related reports',
      relatedModels: 'Related models',
      upstreamItem: 'Upstream process',
      latestArrival: 'Latest local arrival',
      latestStart: 'Latest start',
      latestEnd: 'Latest end',
      semanticTable: 'Semantic table',
      semanticTables: 'Semantic tables',
      semanticTableCount: 'Semantic tables',
      physicalObjects: 'Physical objects',
      noSemanticTable: 'No semantic table',
      dynamicVariable: 'Code variable',
      dynamicVariableHint: name => `The notebook computes this name at runtime from the variable "${name}"; it is not a literal table name.`,
      invocationParameters: 'Invocation parameters',
      hiddenRows: 'Additional rows',
      objectCount: 'Objects',
      reportCount: 'Reports',
      sourceCount: 'Sources',
      affectedModels: 'Affected models',
      inspectedScope: 'Inspected scope',
      noSelection: 'Select a card to see technical detail without loading the main view.'
      ,
      exportPdf: 'Download PDF',
      exportPng: 'Diagram PNG',
      exportExcel: 'Download Excel',
      pdfExportHint: 'Generate a local A4 report with the visible diagram and selected summary.',
      pngExportHint: 'Download a high-resolution local PNG image of the selected diagram with its nodes expanded.',
      excelExportHint: 'Download the full list of items affected by this object.',
      lineageExcelHint: 'Download the filtered final-object list for the selected diagram.',
      excelGenerated: 'Generated',
      excelImpactList: 'Impact list',
      excelLineageList: 'Lineage list',
      excelDpOrWorkspace: 'DP / WS',
      excelNotebookOrItem: 'NB / item',
      excelDirection: 'Source / target',
      excelFinalObject: 'Table / view / SP / file',
      excelSourceOrTarget: 'Data source / target',
      excelParentItem: 'Container item',
      pdfDiagram: 'Visible diagram',
      pdfSummary: 'Detail summary',
      pdfGenerated: 'Generated',
      pdfView: 'View',
      pdfSelection: 'Selection',
      pdfAdditionalRows: 'Additional summarized rows'
    }
  }
};

function t(path) {
  return path.split('.').reduce((value, key) => value && value[key], i18n[state.lang]) || path;
}

function number(value) {
  return new Intl.NumberFormat(state.lang === 'es' ? 'es-ES' : 'en-US').format(value || 0);
}

function text(value) {
  return value === undefined || value === null || value === '' ? '' : String(value);
}

function escapeHtml(value) {
  return text(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function truncate(value, length = 54) {
  const clean = text(value);
  return clean.length > length ? `${clean.slice(0, length - 1)}…` : clean;
}

function normalize(value) {
  return String(value || '').toLowerCase();
}

function workspaceHasFabricItems(workspace) {
  const fabricTypes = new Set([
    'Lakehouse',
    'Notebook',
    'CopyJob',
    'DataPipeline',
    'Warehouse',
    'SQLEndpoint',
    'Dataflow',
    'Eventstream',
    'GraphQLApi',
    'KQLDashboard',
    'KQLQueryset',
    'Reflex',
    'UserDataFunction',
    'VariableLibrary'
  ]);
  return Boolean(workspace && asList(workspace.all).some(item => fabricTypes.has(item.item_type)));
}

function powerBiCapacityLabel(workspace) {
  const signature = normalize(`${workspace.capacity_name || ''} ${workspace.workspace_type || ''} ${workspace.description || ''}`);
  if (signature.includes('embedded') || signature.includes(' em')) return 'Power BI Embedded';
  if (signature.includes('premium') || signature.includes(' p')) return 'Power BI Premium';
  if (signature.includes('trial')) return 'Power BI trial';
  if (signature.includes('personal')) return 'Power BI personal';
  return workspace.capacity_name ? `Power BI · ${workspace.capacity_name}` : 'Power BI Pro';
}

function shortCapacityId(workspace) {
  const id = text(workspace && workspace.capacity_id);
  return id ? id.slice(0, 8) : '';
}

// Falling back to the raw capacity_id here would just duplicate the ID
// already shown in its own row below -- capacity_name is only resolvable
// via the Fabric capacities API for capacities this account administers
// (production capacities are often managed by someone else),
// so when it's genuinely unknown this row stays empty instead of faking a
// name from the ID.
function workspaceCapacityValue(workspace) {
  if (!workspace) return '';
  return workspace.capacity_name || '';
}

function fabricCapacityLabel(workspace) {
  if (workspace.capacity_name) {
    return normalize(workspace.capacity_name).includes('trial')
      ? `Fabric trial · ${workspace.capacity_name}`
      : `Fabric capacity · ${workspace.capacity_name}`;
  }
  const capacityId = shortCapacityId(workspace);
  return capacityId ? `Fabric capacity · ${capacityId}` : 'Fabric workspace';
}

function workspacePlatformLabel(workspace) {
  return workspaceHasFabricItems(workspace) ? fabricCapacityLabel(workspace) : powerBiCapacityLabel(workspace);
}

function iconClassForWorkspace(workspace) {
  return workspaceHasFabricItems(workspace) ? 'icon-fabric' : 'icon-powerbi';
}

function iconClassForMode(mode) {
  return {
    semantic: 'icon-semantic',
    notebooks: 'icon-notebook',
    copyjobs: 'icon-copyjob',
    pipelines: 'icon-pipeline',
    dataflows: 'icon-dataflow',
    all: 'icon-fabric',
    report: 'icon-report',
    paginatedreport: 'icon-paginated-report',
    dashboard: 'icon-dashboard',
    kqldashboard: 'icon-realtime-dashboard',
    kqlqueryset: 'icon-kql-queryset',
    kqldatabase: 'icon-kql',
    eventstream: 'icon-eventstream',
    eventhouse: 'icon-eventhouse',
    reflex: 'icon-reflex',
    graphqlapi: 'icon-graphql',
    userdatafunction: 'icon-user-data-function',
    dataagent: 'icon-data-agent',
    variablelibrary: 'icon-variable-library',
    environments: 'icon-environment',
    mlexperiment: 'icon-ml',
    sqlendpoint: 'icon-sql',
    lakehouse: 'icon-lakehouse',
    warehouse: 'icon-warehouse',
    datamart: 'icon-datamart',
    exploration: 'icon-report',
    sqldatabase: 'icon-sqldatabase',
    app: 'icon-app'
  }[mode] || 'icon-item';
}

// Every item type discovered anywhere in the tenant gets its own mode --
// this used to be a fixed 5-mode list; now state.data.modes (built by
// 11_build_lineage_explorer_fast.py's mode_key_for_item_type, ordered most
// to fewest elements) drives it instead, so a governance tool showing
// "everything scanned" doesn't need a code change every time a new item
// type shows up. Falls back to the original 5 before data has loaded.
function availableModes() {
  const data = state.data;
  const modeCounts = (data && data.summary && data.summary.mode_counts) || {};
  const orderedKeys = (data && Array.isArray(data.modes) && data.modes.length)
    ? data.modes
    : ['semantic', 'notebooks', 'copyjobs', 'pipelines', 'dataflows'];
  return orderedKeys.filter(key => key !== 'all').map(key => ({ key, count: modeCounts[key] || 0 }));
}

function modeButtonHtml(entry) {
  const active = entry.key === state.mode ? ' active' : '';
  const label = t(`mode.${entry.key}`);
  return `<button type="button" class="mode-button${active}" data-mode="${escapeHtml(entry.key)}" title="${escapeHtml(label)} · ${number(entry.count)}">
    <span class="ms-icon ${iconClassForMode(entry.key)}" aria-hidden="true"></span>
    <span>${escapeHtml(label)}</span>
  </button>`;
}

// How many modes actually fit in one row depends on real pixel widths
// (label length varies a lot: "Todos" vs "User Data Functions") and the
// available header width, not a fixed guess -- a fixed slot count either
// leaves a dead gap before the "⋯" button on wide screens or overflows on
// narrow ones. So every mode button is rendered once (giving each its
// real measured width), then as many as fit the row are kept, and the
// remainder moves into the overflow menu.
function renderModeBar() {
  if (!els.modeBarVisible) return;
  const modes = availableModes();
  const totalCount = modes.reduce((sum, entry) => sum + entry.count, 0);
  const entries = [{ key: 'all', count: totalCount }, ...modes];

  els.modeBarVisible.innerHTML = entries.map(modeButtonHtml).join('');
  const buttons = Array.from(els.modeBarVisible.children);

  const containerWidth = els.modeBarVisible.clientWidth;
  const gap = 6;
  const overflowReserve = 40; // toggle button width + its own gap to the last visible button
  let usedWidth = 0;
  let fitCount = 0;
  for (const button of buttons) {
    const buttonWidth = button.getBoundingClientRect().width;
    const widthWithThis = usedWidth + (fitCount > 0 ? gap : 0) + buttonWidth;
    const hasMoreAfter = fitCount + 1 < buttons.length;
    if (fitCount > 0 && widthWithThis + (hasMoreAfter ? overflowReserve : 0) > containerWidth) break;
    usedWidth = widthWithThis;
    fitCount += 1;
  }
  fitCount = Math.max(fitCount, 1); // "Todos" always stays visible even on a very narrow header

  const overflow = entries.slice(fitCount);
  buttons.forEach((button, index) => {
    if (index >= fitCount) button.remove();
  });
  els.modeBarVisible.querySelectorAll('.mode-button').forEach(button => {
    button.addEventListener('click', () => setMode(button.dataset.mode));
  });

  if (els.modeOverflowToggle && els.modeOverflowMenu) {
    els.modeOverflowToggle.hidden = overflow.length === 0;
    const overflowActive = overflow.some(entry => entry.key === state.mode);
    els.modeOverflowToggle.classList.toggle('active', overflowActive);
    els.modeOverflowMenu.innerHTML = overflow.map(entry => {
      const active = entry.key === state.mode ? ' active' : '';
      const label = t(`mode.${entry.key}`);
      return `<button type="button" class="mode-overflow-item${active}" data-mode="${escapeHtml(entry.key)}" role="menuitem">
        <span class="ms-icon ${iconClassForMode(entry.key)}" aria-hidden="true"></span>
        <span>${escapeHtml(label)}</span>
        <i>${number(entry.count)}</i>
      </button>`;
    }).join('');
    els.modeOverflowMenu.querySelectorAll('.mode-overflow-item').forEach(button => {
      button.addEventListener('click', () => {
        setMode(button.dataset.mode);
        els.modeOverflowMenu.hidden = true;
        els.modeOverflowToggle.setAttribute('aria-expanded', 'false');
      });
    });
  }

  // The old click-wiring at page load assumed a static button list; mode
  // buttons are rebuilt every call now, so this reference (read elsewhere
  // for e.g. disabling every mode button during initial data load) is
  // refreshed here instead of captured once.
  els.modeButtons = Array.from(document.querySelectorAll('.mode-button'));
}

let modeBarResizeHandle = null;
window.addEventListener('resize', () => {
  if (modeBarResizeHandle) window.clearTimeout(modeBarResizeHandle);
  modeBarResizeHandle = window.setTimeout(() => {
    modeBarResizeHandle = null;
    renderModeBar();
  }, 150);
});

function sourceIconKey(data = {}) {
  return normalize([
    data.source_type,
    data.item_type,
    data.label,
    data.database,
    data.server,
    data.qualified_name
  ].filter(Boolean).join(' '));
}

function iconClassForSourceData(data = {}) {
  const key = sourceIconKey(data);
  if (key.includes('sharepoint')) return 'icon-sharepoint';
  if (
    key.includes('lakehousetable') ||
    key.includes('lakehouse') ||
    key.includes('/tables') ||
    key.includes('.lakehouse') ||
    key.includes('lh_')
  ) return 'icon-lakehouse';
  if (key.includes('warehouse')) return 'icon-warehouse';
  if (key.includes('onelake') || key.includes('one lake')) return 'icon-onelake';
  if (key.includes('sql endpoint') || key.includes('sqlendpoint') || key.includes('fabricorsql') || key.includes('sql')) return 'icon-sql';
  if (key.includes('file') || key.includes('/files') || key.includes('abfss://')) return 'icon-file';
  return iconClassForType(data.source_type || data.item_type || data.type || 'source');
}

function iconClassForObjectData(data = {}) {
  const key = normalize([
    data.type,
    data.object_type,
    data.object_type_values,
    data.raw_object_type,
    data.source_type,
    data.object_name,
    data.label
  ].filter(Boolean).join(' '));
  if (key.includes('stored') || key.includes('procedure') || /\bsp\b/.test(key)) return 'icon-procedure';
  if (key.includes('file') || key.includes('/files')) return 'icon-file';
  if (key.includes('table_or_view') || key.includes('table or view')) return 'icon-table';
  if (key.includes('view')) return 'icon-view';
  if (key.includes('lakehousetable') || key.includes('table')) return 'icon-table';
  if (key.includes('schema') || key.includes('database')) return 'icon-databases';
  return iconClassForType(data.type || data.object_type || data.raw_object_type || data.source_type || data.item_type);
}

function iconClassForType(type, sourceType = '') {
  const key = normalize(`${type} ${sourceType}`).trim();
  if (key.includes('external semantic') || key.includes('externalsemantic')) return 'icon-external-semantic';
  if (key.includes('shared semantic') || key.includes('sharedsemantic')) return 'icon-shared-semantic';
  if (key.includes('semantic')) return 'icon-semantic';
  if (key.includes('paginated') || key.includes('rdl')) return 'icon-paginated-report';
  if (key.includes('real time dashboard') || key.includes('realtimedashboard') || key.includes('kqldashboard')) return 'icon-realtime-dashboard';
  if (key.includes('dashboard')) return 'icon-dashboard';
  if (key.includes('report')) return 'icon-report';
  if (key.includes('notebook')) return 'icon-notebook';
  if (key.includes('copy')) return 'icon-copyjob';
  if (key.includes('pipeline')) return 'icon-pipeline';
  if (key.includes('streaming dataflow') || key.includes('streamingdataflow')) return 'icon-streaming-dataflow';
  if (key.includes('dataflow')) return 'icon-dataflow';
  if (key.includes('external datamart') || key.includes('externaldatamart')) return 'icon-datamart';
  if (key.includes('datamart')) return 'icon-datamart';
  if (key.includes('event house') || key.includes('eventhouse')) return 'icon-eventhouse';
  if (key.includes('eventstream') || key.includes('event stream')) return 'icon-eventstream';
  if (key.includes('kql script') || key.includes('kqlscript')) return 'icon-kql-script';
  if (key.includes('kql')) return 'icon-kql';
  if (key.includes('mirrored')) return 'icon-mirrored-database';
  if (key.includes('mlmodel') || key.includes('mlexperiment') || key.includes('ml model') || key.includes('ml experiment')) return 'icon-ml';
  if (key.includes('stored') || key.includes('procedure') || key === 'sp') return 'icon-procedure';
  if (key.includes('file')) return 'icon-file';
  if (key.includes('table_or_view') || key.includes('table or view')) return 'icon-table';
  if (key.includes('view')) return 'icon-view';
  if (key.includes('table')) return 'icon-table';
  if (key.includes('lakehouse')) return 'icon-lakehouse';
  if (key.includes('onelake') || key.includes('one lake')) return 'icon-onelake';
  if (key.includes('warehouse')) return 'icon-warehouse';
  if (key.includes('sql')) return 'icon-sql';
  if (key.includes('sharepoint')) return 'icon-sharepoint';
  if (key.includes('database')) return 'icon-databases';
  if (key.includes('fabric')) return 'icon-fabric';
  if (key.includes('external') || key.includes('source')) return 'icon-source';
  return 'icon-item';
}

function iconClassForNode(node) {
  const data = node.data || {};
  if (node.kind === 'deploymentPipeline') return 'icon-deployment';
  if (node.kind === 'deploymentStage') return 'icon-environment';
  if (node.kind === 'workspace') return iconClassForWorkspace(data);
  if (node.kind === 'impactObject') return iconClassForType(data.object_type_values, data.source_type);
  if (node.kind === 'pipeline') return 'icon-pipeline';
  if (node.kind === 'report') return iconClassForType(data.item_type || 'Report');
  if (node.kind === 'source') return iconClassForSourceData(data);
  if (node.kind === 'object') return iconClassForObjectData(data);
  if (node.kind === 'execute') return iconClassForType(data.item_type);
  if (node.kind === 'group') return {
    reports: 'icon-report',
    models: 'icon-semantic',
    sources: 'icon-source',
    readSources: 'icon-source',
    writeTargets: 'icon-lakehouse',
    executedObjects: 'icon-procedure',
    referenceSources: 'icon-databases',
    executes: 'icon-pipeline'
  }[node.group] || 'icon-item';
  return iconClassForType(data.item_type);
}

function iconClassForLegend(key) {
  return {
    deployment: 'icon-deployment',
    workspace: 'icon-fabric',
    item: iconClassForMode(state.mode),
    report: 'icon-report',
    source: 'icon-source',
    object: 'icon-table',
    impact: 'icon-table',
    pipeline: 'icon-pipeline',
    cross: 'icon-cross'
  }[key] || 'icon-item';
}

function itemTypeLabel(type) {
  return (i18n[state.lang].itemTypes && i18n[state.lang].itemTypes[type]) || type;
}

function objectTypeLabel(type) {
  return (i18n[state.lang].objectTypes && i18n[state.lang].objectTypes[type]) || type;
}

function roleLabel(role) {
  return (i18n[state.lang].roleTypes && i18n[state.lang].roleTypes[role]) || role;
}

function sourceTypeLabel(type) {
  const value = text(type);
  return (i18n[state.lang].sourceTypeLabels && i18n[state.lang].sourceTypeLabels[value]) ||
    value.replace(/([a-z])([A-Z])/g, '$1 $2') ||
    t('unknown');
}

function sourceTypeDisplay(type) {
  return type ? sourceTypeLabel(type) : '';
}

function nodeKindLabel(kind) {
  return (i18n[state.lang].nodeKinds && i18n[state.lang].nodeKinds[kind]) || kind;
}

const UNRESOLVED_VARIABLE_PATTERN = /Unresolved variables:\s*(.+)$/;

// Static code parsing sometimes cannot resolve a table/path name because the
// notebook builds it from a Python variable at runtime (e.g. `spark.read.table(full_table_name)`).
// The backend already flags this in the evidence text; this only reads that
// flag back out so the frontend can show "this is a code variable" instead of
// a garbled literal-looking object name.
function unresolvedVariableName(object) {
  const evidence = object && text(object.evidence);
  if (!evidence) return '';
  const match = evidence.match(UNRESOLVED_VARIABLE_PATTERN);
  return match ? match[1].trim() : '';
}

function isUnresolvedVariableObject(object) {
  return Boolean(unresolvedVariableName(object));
}

function asList(value) {
  if (Array.isArray(value)) return value;
  if (value && typeof value === 'object') return [value];
  return [];
}

function objectEvidenceStatus(object) {
  const confidence = object && (object.object_type_confidence || object.confidence);
  const type = object && (object.type || object.object_type || object.raw_object_type);
  const source = object && object.object_type_source;
  if (!object) return 'unknown';
  if (String(source || '').includes('conflict')) return 'blocked';
  if (confidence === 'confirmed' || ['table', 'view', 'stored_procedure', 'file', 'shortcut'].includes(type)) return 'confirmed';
  if (confidence === 'likely' || ['native_query_object', 'manual_object'].includes(type)) return 'likely';
  return 'unknown';
}

function sourceEvidenceStatus(source) {
  if (!source) return 'unknown';
  if (source.confidence === 'confirmed') return 'confirmed';
  if (source.confidence === 'likely') return 'likely';
  if (asList(source.objects).some(object => objectEvidenceStatus(object) === 'confirmed')) return 'confirmed';
  return source.confidence || 'unknown';
}

function impactObjectEvidenceStatus(object) {
  if (!object) return 'unknown';
  if (Number(object.total_impact_count || 0) > 0) return 'confirmed';
  if (object.catalog_only || object.catalog_status) return 'catalogOnly';
  if (String(object.object_type_sources || '').includes('conflict')) return 'blocked';
  return object.object_type_values ? 'likely' : 'unknown';
}

function objectTypeSourceLabel(value) {
  return (i18n[state.lang].objectTypeSources && i18n[state.lang].objectTypeSources[value]) || value;
}

function jobStatusLabel(value) {
  return (i18n[state.lang].jobStatuses && i18n[state.lang].jobStatuses[value]) || value;
}

function externalSystemLabel(value) {
  if (!value) return t('refresh.noExternal');
  if (state.lang !== 'es') return value;
  const labels = {
    'None': 'Ninguno',
    'Fabric REST read-only': 'Fabric REST solo lectura',
    'Fabric REST and Power BI REST read-only': 'Fabric REST y Power BI REST solo lectura'
  };
  return labels[value] || value;
}

function recommendationHintLabel(value) {
  if (!value || state.lang !== 'es') return value;
  const labels = {
    'Stabilize before optimizing schedule or parallelism.': 'Estabilizar antes de optimizar schedules o paralelismo.',
    'Review as critical-path candidate because runtime exceeds threshold.': 'Revisar como candidato de ruta crítica porque la duración supera el umbral.',
    'Candidate parallel execution exists; validate reads/writes before parallel execution.': 'Existe paralelismo candidato; validar lecturas/escrituras antes de ejecutarlo en paralelo.',
    'Review orchestration fan-out before changing schedules.': 'Revisar el fan-out de orquestación antes de cambiar schedules.',
    'Review disabled schedules before changing orchestration.': 'Revisar schedules deshabilitados antes de cambiar la orquestación.'
  };
  return value
    .split(' | ')
    .map(part => labels[part] || part)
    .join(' | ');
}

function rawModeItems(workspace) {
  return workspace ? asList(workspace[state.mode]) : [];
}

function itemTypeVisible(item) {
  return state.filters.itemType === 'all' || item.item_type === state.filters.itemType;
}

function modeItems(workspace) {
  return rawModeItems(workspace).filter(itemTypeVisible);
}

function modeCount(workspace) {
  return modeItems(workspace).length;
}

function matchesSourceText(source, query) {
  return normalize(source.label).includes(query) ||
    normalize(source.workspace_name).includes(query) ||
    normalize(source.server).includes(query) ||
    normalize(source.database).includes(query) ||
    asList(source.objects).some(object =>
      normalize(object.label).includes(query) ||
      normalize(object.qualified_name).includes(query) ||
      normalize(object.object_name).includes(query)
    );
}

function matchesItemReferenceText(item, query) {
  return normalize(item.label).includes(query) ||
    normalize(item.qualified_name).includes(query) ||
    normalize(item.workspace_name).includes(query) ||
    normalize(item.item_type).includes(query);
}

function matchesItemText(item, query) {
  return matchesItemReferenceText(item, query) ||
    asList(item.sources).some(source => matchesSourceText(source, query)) ||
    asList(item.reports).some(report => matchesItemReferenceText(report, query)) ||
    asList(item.models).some(model =>
      matchesItemReferenceText(model, query) ||
      asList(model.sources).some(source => matchesSourceText(source, query))
    ) ||
    asList(item.executes).some(executed => matchesItemReferenceText(executed, query));
}

function currentWorkspacesIgnoringItemType() {
  const query = state.viewMode === 'impact' ? '' : normalize(state.search);
  return state.data.workspaces
    .filter(workspace => rawModeItems(workspace).length > 0)
    .filter(workspacePassesEnvironmentFilter)
    .filter(workspacePassesDomainFilter)
    .filter(workspace => {
      if (!query) return true;
      const items = rawModeItems(workspace);
      const deployment = workspace.deployment_pipeline || {};
      return normalize(workspace.name).includes(query) ||
        normalize(workspace.environment).includes(query) ||
        normalize(workspace.capacity_name).includes(query) ||
        normalize(deployment.deployment_pipeline_name).includes(query) ||
        normalize(deployment.stage_name).includes(query) ||
        items.some(item => matchesItemText(item, query));
    });
}

function currentWorkspaces() {
  const query = state.viewMode === 'impact' ? '' : normalize(state.search);
  return state.data.workspaces
    .filter(workspace => modeCount(workspace) > 0)
    .filter(workspacePassesEnvironmentFilter)
    .filter(workspacePassesDomainFilter)
    .filter(workspace => {
      if (!query) return true;
      const items = modeItems(workspace);
      const deployment = workspace.deployment_pipeline || {};
      return normalize(workspace.name).includes(query) ||
        normalize(workspace.environment).includes(query) ||
        normalize(workspace.capacity_name).includes(query) ||
        normalize(deployment.deployment_pipeline_name).includes(query) ||
        normalize(deployment.stage_name).includes(query) ||
        items.some(item => matchesItemText(item, query));
    });
}

function workspaceMapByName(workspaces = state.data.workspaces || []) {
  return new Map(workspaces.map(workspace => [workspace.name, workspace]));
}

// Fabric's own "Copy link" action on any item produces this exact,
// item-type-agnostic URL shape -- /groups/{workspaceId}/items/{itemId} --
// and the portal resolves the right type-specific view itself, so this
// works for every item type without needing a lookup table of ~20 URL
// slugs (report vs notebook vs lakehouse vs ...) that would need updating
// every time Fabric adds a new item type.
function fabricWorkspaceUrl(workspaceName) {
  const workspace = workspaceMapByName().get(workspaceName);
  const workspaceId = workspace && workspace.workspace_id;
  if (!workspaceId) return '';
  return `https://app.fabric.microsoft.com/groups/${workspaceId}/list`;
}

function fabricItemUrl(data) {
  if (!data) return '';
  const itemId = data.technical_id;
  const workspaceName = data.workspace_name;
  if (!itemId || !workspaceName) return '';
  const workspace = workspaceMapByName().get(workspaceName);
  const workspaceId = workspace && workspace.workspace_id;
  if (!workspaceId) return '';
  return `https://app.fabric.microsoft.com/groups/${workspaceId}/items/${itemId}?experience=fabric-developer`;
}

function deploymentPipelineIdForWorkspace(workspace) {
  return workspace && workspace.deployment_pipeline && workspace.deployment_pipeline.has_pipeline
    ? workspace.deployment_pipeline.deployment_pipeline_id
    : '';
}

function workspaceHasDeploymentPipeline(workspace) {
  return Boolean(deploymentPipelineIdForWorkspace(workspace));
}

function isTruthyText(value) {
  return ['true', '1', 'yes', 'sí', 'si'].includes(normalize(value));
}

function isProductionStage(stage) {
  if (!stage) return false;
  return normalize(stage.stage_name).includes('production') ||
    normalize(stage.stage_name).includes('produccion') ||
    normalize(stage.local_workspace_name || stage.workspace_name).includes('_pro') ||
    isTruthyText(stage.is_public);
}

function isProductionWorkspace(workspace) {
  if (!workspace) return false;
  const deployment = workspace.deployment_pipeline || {};
  return workspace.environment === 'PRO' ||
    normalize(workspace.name).includes('_pro') ||
    normalize(workspace.stage_name).includes('production') ||
    normalize(workspace.stage_name).includes('produccion') ||
    normalize(deployment.stage_name).includes('production') ||
    normalize(deployment.stage_name).includes('produccion') ||
    isTruthyText(workspace.is_public) ||
    isTruthyText(deployment.is_public);
}

function hasWorkspaceEnvironmentFilter() {
  return state.selectedWorkspaceEnvironments && state.selectedWorkspaceEnvironments.size > 0;
}

function workspaceEnvironmentFilterValue(workspace) {
  const deployment = workspace && workspace.deployment_pipeline ? workspace.deployment_pipeline : {};
  const signature = normalize([
    workspace && workspace.environment,
    workspace && workspace.name,
    workspace && workspace.stage_name,
    deployment.stage_name,
    deployment.deployment_stage_name
  ].filter(Boolean).join(' '));
  if (!workspace) return '';
  if (isProductionWorkspace(workspace) || /\b(pro|prod|production|produccion)\b/.test(signature) || signature.includes('_pro')) return 'PRO';
  if (/\b(qa|test|testing)\b/.test(signature) || signature.includes('_qa')) return 'QA';
  if (/\b(dev|develop|development|desarrollo)\b/.test(signature) || signature.includes('_dev')) return 'DEV';
  return text(workspace.environment).toUpperCase();
}

function workspacePassesEnvironmentFilter(workspace) {
  if (!hasWorkspaceEnvironmentFilter()) return true;
  if (!workspaceHasDeploymentPipeline(workspace)) return true;
  return state.selectedWorkspaceEnvironments.has(workspaceEnvironmentFilterValue(workspace));
}

function pipelineStagePassesEnvironmentFilter(stage) {
  if (!hasWorkspaceEnvironmentFilter()) return true;
  return Boolean(stage && stage.workspace && workspacePassesEnvironmentFilter(stage.workspace));
}

// Filtro por dominio nativo de Fabric (roadmap Nivel 2, 2026-08-17) --
// domain_name ya se descubre y se muestra en el panel de detalle desde
// hace tiempo, pero nunca se había usado para filtrar el índice de
// workspaces; esto reutiliza ese mismo dato, sin tocar el backend.
function availableWorkspaceDomains() {
  if (!state.data || !Array.isArray(state.data.workspaces)) return [];
  const names = new Set();
  state.data.workspaces.forEach(workspace => {
    const domain = text(workspace.domain_name).trim();
    if (domain) names.add(domain);
  });
  return Array.from(names).sort((a, b) => a.localeCompare(b, state.lang === 'es' ? 'es' : 'en'));
}

function workspacePassesDomainFilter(workspace) {
  if (!state.selectedWorkspaceDomain || state.selectedWorkspaceDomain === 'all') return true;
  return text(workspace && workspace.domain_name).trim() === state.selectedWorkspaceDomain;
}

// Oculto por completo si el tenant no usa dominios de Fabric o solo tiene
// uno -- un filtro de una sola opción no filtra nada, es ruido en el panel.
function populateWorkspaceDomainFilter() {
  if (!els.workspaceDomainFilterRow || !els.workspaceDomainFilter) return;
  const domains = availableWorkspaceDomains();
  if (domains.length < 2) {
    els.workspaceDomainFilterRow.hidden = true;
    if (state.selectedWorkspaceDomain !== 'all') {
      state.selectedWorkspaceDomain = 'all';
    }
    return;
  }
  els.workspaceDomainFilterRow.hidden = false;
  if (!domains.includes(state.selectedWorkspaceDomain)) state.selectedWorkspaceDomain = 'all';
  els.workspaceDomainFilter.innerHTML = [
    optionHtml('all', t('all')),
    ...domains.map(domain => optionHtml(domain, domain)),
  ].join('');
  els.workspaceDomainFilter.value = state.selectedWorkspaceDomain;
}

function semanticModelCountForWorkspace(workspace) {
  return workspace && Array.isArray(workspace.semantic) ? workspace.semantic.length : 0;
}

function productionWorkspacesForPipeline(entry) {
  const data = entry && entry.data ? entry.data : entry || {};
  const stages = data.stages || [];
  return uniqueBy(
    stages
      .filter(isProductionStage)
      .map(stage => stage.workspace)
      .filter(Boolean)
      .filter(isProductionWorkspace),
    workspace => workspace.name
  );
}

function stageWorkspaceName(stage) {
  return stage.local_workspace_name || stage.workspace_name || t('stageNotIndexed');
}

function stageClass(stage) {
  const classes = ['pipeline-stage-pill'];
  if (isProductionStage(stage)) classes.push('production-stage');
  if (!stage.local_workspace_name) classes.push('missing-stage');
  return classes.join(' ');
}

function stagePillHtml(stage) {
  const workspace = stage.workspace || null;
  const modelCount = workspace ? semanticModelCountForWorkspace(workspace) : 0;
  const title = [
    stage.stage_name,
    stageWorkspaceName(stage),
    workspace ? `${number(modelCount)} ${t('semanticFlow.model')}` : t('stageNotIndexed'),
    stage.evidence
  ].filter(Boolean).join(' · ');
  return `
    <span class="${stageClass(stage)}" title="${escapeHtml(title)}">
      <b>${escapeHtml(stage.stage_name || t('deploymentStage'))}</b>
      <em>${escapeHtml(stageWorkspaceName(stage))}</em>
      ${workspace ? `<i>${number(modelCount)} ${escapeHtml(t('semanticFlow.model').toLowerCase())}</i>` : `<i>${escapeHtml(t('stageNotIndexed'))}</i>`}
    </span>
  `;
}

function enrichDeploymentPipeline(pipeline, workspaceByName) {
  const stages = (pipeline.stages || [])
    .map(stage => ({
      ...stage,
      workspace: stage.local_workspace_name ? workspaceByName.get(stage.local_workspace_name) || null : null
    }))
    .filter(pipelineStagePassesEnvironmentFilter);
  const localWorkspaces = uniqueBy(
    stages.map(stage => stage.workspace).filter(Boolean),
    workspace => workspace.name
  );
  if (!localWorkspaces.length) return null;
  return {
    kind: 'deploymentPipeline',
    id: pipeline.deployment_pipeline_id,
    key: `deploymentPipeline:${pipeline.deployment_pipeline_id}`,
    label: pipeline.deployment_pipeline_name,
    data: {
      ...pipeline,
      stages,
      local_workspaces: localWorkspaces,
      filtered_workspace_names: localWorkspaces.map(workspace => workspace.name)
    }
  };
}

function currentDeploymentPipelineEntries(workspaces = currentWorkspaces()) {
  const workspaceByName = workspaceMapByName(workspaces);
  return (state.data.deployment_pipelines || [])
    .map(pipeline => enrichDeploymentPipeline(pipeline, workspaceByName))
    .filter(Boolean)
    .sort((a, b) => a.label.localeCompare(b.label));
}

function currentIndexEntries() {
  const workspaces = currentWorkspaces();
  const pipelineEntries = currentDeploymentPipelineEntries(workspaces);
  const groupedWorkspaceNames = new Set(
    pipelineEntries.flatMap(entry => entry.data.local_workspaces.map(workspace => workspace.name))
  );
  const standaloneWorkspaces = workspaces
    .filter(workspace => !groupedWorkspaceNames.has(workspace.name))
    .map(workspace => ({
      kind: 'workspace',
      id: workspace.name,
      key: `workspace:${workspace.name}`,
      label: workspace.name,
      data: workspace
    }));
  return [...pipelineEntries, ...standaloneWorkspaces];
}

function entryWorkspaceNames(entry) {
  if (!entry) return [];
  if (entry.kind === 'deploymentPipeline') {
    return (entry.data.local_workspaces || []).map(workspace => workspace.name);
  }
  return [entry.data.name];
}

function entryIsSelected(entry) {
  if (!entry) return false;
  if (entry.kind === 'deploymentPipeline') return state.selectedDeploymentPipelines.has(entry.id);
  return state.selectedWorkspaces.has(entry.data.name);
}

function deploymentStageSelectionKey(data) {
  return data && (data.deployment_pipeline_id || data.id || data.deployment_pipeline_name) || '';
}

function stageWorkspaceValue(stage) {
  return stage && (stage.local_workspace_name || (stage.workspace && stage.workspace.name) || '');
}

function selectablePipelineStages(data) {
  return uniqueBy(
    asList(data && data.stages)
      .filter(stage => stageWorkspaceValue(stage))
      .map(stage => ({
        ...stage,
        local_workspace_name: stageWorkspaceValue(stage),
        workspace: stage.workspace || workspaceMapByName(currentWorkspaces()).get(stageWorkspaceValue(stage)) || null
      })),
    stage => stage.local_workspace_name
  ).sort((a, b) => Number(a.stage_order || 999) - Number(b.stage_order || 999));
}

function activeStageWorkspaceSelection(data) {
  const key = deploymentStageSelectionKey(data);
  const validStages = selectablePipelineStages(data);
  const validNames = new Set(validStages.map(stage => stage.local_workspace_name));
  const current = new Set(Array.from(state.selectedStageWorkspaces.get(key) || []).filter(name => validNames.has(name)));
  if (key && current.size !== (state.selectedStageWorkspaces.get(key) || new Set()).size) {
    if (current.size) state.selectedStageWorkspaces.set(key, current);
    else state.selectedStageWorkspaces.delete(key);
  }
  return current;
}

function filteredDeploymentPipelineData(data) {
  const selection = activeStageWorkspaceSelection(data);
  if (!selection.size) return data;
  const stages = asList(data.stages).filter(stage => selection.has(stageWorkspaceValue(stage)));
  const localWorkspaces = uniqueBy(
    stages
      .map(stage => stage.workspace || (stageWorkspaceValue(stage) ? workspaceMapByName(currentWorkspaces()).get(stageWorkspaceValue(stage)) : null))
      .filter(Boolean),
    workspace => workspace.name
  );
  return {
    ...data,
    stages,
    local_workspaces: localWorkspaces,
    filtered_workspace_names: localWorkspaces.map(workspace => workspace.name)
  };
}

function pipelineVisibleWorkspaceNames(data) {
  return filteredDeploymentPipelineData(data).local_workspaces.map(workspace => workspace.name);
}

function visibleWorkspaceNameSetForLineage() {
  const roots = selectedRootNodes();
  const names = new Set();
  for (const root of roots) {
    if (root.kind === 'deploymentPipeline') {
      pipelineVisibleWorkspaceNames(root.data).forEach(name => names.add(name));
    } else if (root.kind === 'workspace' && root.data.name) {
      names.add(root.data.name);
    }
  }
  return names;
}

function selectedLineageWorkspaceList() {
  const visibleNames = visibleWorkspaceNameSetForLineage();
  return selectedWorkspaceList().filter(workspace => visibleNames.has(workspace.name));
}

function selectedDeploymentPipelineEntries() {
  return currentIndexEntries().filter(entry =>
    entry.kind === 'deploymentPipeline' &&
    state.selectedDeploymentPipelines.has(entry.id)
  );
}

function clearStageWorkspaceSelectionsFor(entry) {
  if (!entry || entry.kind !== 'deploymentPipeline') return;
  state.selectedStageWorkspaces.delete(deploymentStageSelectionKey(entry.data));
}

function toggleStageWorkspaceFilter(data, workspaceName) {
  const key = deploymentStageSelectionKey(data);
  if (!key || !workspaceName) return;
  const validNames = selectablePipelineStages(data).map(stage => stage.local_workspace_name);
  const validSet = new Set(validNames);
  const next = activeStageWorkspaceSelection(data);
  if (next.has(workspaceName)) next.delete(workspaceName);
  else next.add(workspaceName);
  for (const name of Array.from(next)) {
    if (!validSet.has(name)) next.delete(name);
  }
  if (!next.size || next.size === validSet.size) state.selectedStageWorkspaces.delete(key);
  else state.selectedStageWorkspaces.set(key, next);
  state.history = [];
  state.selectedNode = null;
  render();
}

function clearStageWorkspaceFilter(data) {
  const key = deploymentStageSelectionKey(data);
  if (!key) return;
  state.selectedStageWorkspaces.delete(key);
  state.history = [];
  state.selectedNode = null;
  render();
}

function createDiagramStageSelector(entries) {
  const pipelineEntries = asList(entries)
    .filter(entry => entry && entry.kind === 'deploymentPipeline')
    .map(entry => ({ ...entry, stages: selectablePipelineStages(entry.data) }))
    .filter(entry => entry.stages.length > 1);
  if (!pipelineEntries.length || state.viewMode !== 'lineage') return null;

  const wrap = document.createElement('section');
  wrap.className = 'diagram-stage-selector';
  wrap.setAttribute('aria-label', t('stageFilter'));

  for (const entry of pipelineEntries) {
    const article = document.createElement('article');
    article.className = 'diagram-stage-selector-row';
    const selection = activeStageWorkspaceSelection(entry.data);
    const title = document.createElement('strong');
    title.textContent = entry.label || entry.data.deployment_pipeline_name || t('deploymentPipeline');
    article.append(title);

    const buttons = document.createElement('div');
    buttons.className = 'diagram-stage-buttons';

    const allButton = document.createElement('button');
    allButton.type = 'button';
    allButton.className = `diagram-stage-button all-stage${selection.size ? '' : ' active'}`;
    allButton.setAttribute('aria-pressed', selection.size ? 'false' : 'true');
    allButton.innerHTML = `<span>${escapeHtml(t('stageFilterAll'))}</span><i>${number(entry.stages.length)} ${escapeHtml(t('workspaces').toLowerCase())}</i>`;
    allButton.addEventListener('click', event => {
      event.preventDefault();
      event.stopPropagation();
      clearStageWorkspaceFilter(entry.data);
    });
    buttons.append(allButton);

    for (const stage of entry.stages) {
      const workspaceName = stage.local_workspace_name;
      const isActive = selection.has(workspaceName);
      const button = document.createElement('button');
      button.type = 'button';
      button.className = `diagram-stage-button${isActive ? ' active' : ''}${isProductionStage(stage) ? ' production-stage' : ''}`;
      button.setAttribute('aria-pressed', isActive ? 'true' : 'false');
      button.title = [stage.stage_name, workspaceName].filter(Boolean).join(' · ');
      button.innerHTML = `
        <span>${escapeHtml(stage.stage_name || stage.stage_order || t('deploymentStage'))}</span>
        <i>${escapeHtml(workspaceName)}</i>
      `;
      button.addEventListener('click', event => {
        event.preventDefault();
        event.stopPropagation();
        toggleStageWorkspaceFilter(entry.data, workspaceName);
      });
      buttons.append(button);
    }
    article.append(buttons);
    wrap.append(article);
  }
  return wrap;
}

function applyIndexEntrySelection(entry, additive = true) {
  if (!entry) return;
  const isSelected = entryIsSelected(entry);
  const workspaceNames = entryWorkspaceNames(entry);
  if (!additive) {
    state.selectedDeploymentPipelines = new Set();
    state.selectedWorkspaces = new Set();
    state.expanded = new Set();
    state.selectedStageWorkspaces = new Map();
  }

  if (entry.kind === 'deploymentPipeline') {
    if (additive && isSelected) {
      state.selectedDeploymentPipelines.delete(entry.id);
      workspaceNames.forEach(name => state.selectedWorkspaces.delete(name));
      state.expanded.delete(entry.key);
      clearStageWorkspaceSelectionsFor(entry);
    } else {
      state.selectedDeploymentPipelines.add(entry.id);
      workspaceNames.forEach(name => state.selectedWorkspaces.add(name));
      state.expanded.add(entry.key);
    }
  } else if (additive && isSelected) {
    state.selectedWorkspaces.delete(entry.data.name);
    state.expanded.delete(entry.key);
  } else {
    state.selectedWorkspaces.add(entry.data.name);
    state.expanded.add(entry.key);
  }

  state.selectedWorkspace = state.selectedWorkspaces.values().next().value || '';
  state.history = [];
  state.selectedNode = null;
  state.planningSourceSearch = '';
  state.planningSelectedSources = new Set();
}

function selectedWorkspaceList() {
  const workspaces = currentWorkspaces();
  return workspaces.filter(workspace => state.selectedWorkspaces.has(workspace.name));
}

// Planning must show the same orchestration plan for a given workspace
// selection no matter which top-nav mode (Modelos semanticos/Notebooks/
// CopyJobs/Pipelines/Todos) happens to be active. currentWorkspaces() is
// mode-filtered (it hides workspaces with zero items of the active mode's
// type), so routing Planning through it made the workspace scope silently
// shrink/change depending on which mode was selected when the workspace was
// picked. Planning always reads from the full workspace list instead.
function selectedWorkspaceListForPlanning() {
  return state.data.workspaces.filter(workspace => state.selectedWorkspaces.has(workspace.name));
}

function selectedRootNodes() {
  const entries = currentIndexEntries();
  const pipelineEntries = entries.filter(entry => entry.kind === 'deploymentPipeline' && state.selectedDeploymentPipelines.has(entry.id));
  const pipelineWorkspaceNames = new Set(
    pipelineEntries.flatMap(entry => entry.data.local_workspaces.map(workspace => workspace.name))
  );
  const workspaceEntries = entries.filter(entry =>
    entry.kind === 'workspace' &&
    state.selectedWorkspaces.has(entry.data.name) &&
    !pipelineWorkspaceNames.has(entry.data.name)
  );
  return [
    ...pipelineEntries.map(entry => ({
      id: entry.key,
      kind: 'deploymentPipeline',
      label: entry.label,
      data: filteredDeploymentPipelineData(entry.data)
    })),
    ...workspaceEntries.map(entry => ({
      id: entry.key,
      kind: 'workspace',
      label: entry.label,
      data: entry.data
    }))
  ];
}

function selectedWorkspace() {
  const selected = selectedWorkspaceList();
  return selected.find(workspace => workspace.name === state.selectedWorkspace) || selected[0] || null;
}

function nodeWorkspaceName(node) {
  const data = node && node.data ? node.data : {};
  if (node && node.kind === 'workspace') return data.name || '';
  if (node && node.kind === 'deploymentStage') return data.local_workspace_name || data.workspace_name || '';
  return data.workspace_name || data.source_workspace_name || '';
}

function isCrossWorkspaceNode(node) {
  if (node && (node.kind === 'deploymentPipeline' || node.kind === 'deploymentStage')) return false;
  const nodeWorkspace = nodeWorkspaceName(node);
  if (!nodeWorkspace || (node && node.kind === 'workspace')) return false;
  if (state.selectedWorkspaces.has(nodeWorkspace)) return false;
  const workspace = selectedWorkspace();
  return Boolean(workspace && nodeWorkspace && nodeWorkspace !== workspace.name);
}

function hasActiveFilters() {
  if (state.viewMode === 'impact') {
    return state.filters.sourceType !== 'all' ||
      state.filters.impactDatabase !== 'all' ||
      state.filters.impactObjectType !== 'all' ||
      state.filters.impactObjectKey !== 'all' ||
      state.impactSelectedObjectKeys.size > 0 ||
      Boolean(state.impactObjectSearch);
  }
  if (state.viewMode === 'planning') {
    return state.filters.sourceType !== 'all' ||
      state.planningSelectedSources.size > 0 ||
      Boolean(state.planningSourceSearch);
  }
  return state.filters.sourceType !== 'all' ||
    state.filters.itemType !== 'all' ||
    state.filters.diagramStore !== 'all' ||
    state.filters.diagramObjectType !== 'all' ||
    state.diagramObjectSelectionMode !== 'all';
}

function supportsDiagramObjectFilters() {
  return state.viewMode === 'lineage' && ['semantic', 'notebooks', 'copyjobs', 'pipelines', 'dataflows'].includes(state.mode);
}

function diagramSourceTypeMatches(source) {
  return state.filters.sourceType === 'all' || source.source_type === state.filters.sourceType;
}

function diagramStoreKey(source) {
  const store = sourceDisplayStoreName(source);
  const label = sourceDisplayLabelCandidate(source);
  return [
    source.server || '',
    store,
    label,
    source.item_type || '',
    source.source_type || ''
  ].map(value => encodeURIComponent(text(value))).join('|');
}

function diagramStoreLabel(source, duplicateNames = new Set()) {
  const name = sourceDisplayStoreName(source) || sourceDisplayLabelCandidate(source) || source.server || sourceTypeDisplay(source.source_type) || t('unknown');
  const type = source.item_type ? itemTypeLabel(source.item_type) : sourceTypeLabel(source.source_type);
  const server = source.server && normalize(source.server) !== normalize(name) ? source.server : '';
  const suffix = duplicateNames.has(name)
    ? [server, type].filter(Boolean).join(' · ')
    : type;
  return suffix && normalize(suffix) !== normalize(name) ? `${name} · ${suffix}` : name;
}

function diagramObjectRawType(object) {
  return object.type || object.object_type || object.raw_object_type || 'unknown';
}

function notebookLineageItemNameFromQualified(source = {}) {
  const parts = text(source.qualified_name).split(' / ').map(part => part.trim()).filter(Boolean);
  if (parts.length >= 5 && ['read', 'write', 'execute'].includes(normalize(parts[parts.length - 2]))) {
    return parts[parts.length - 3] || '';
  }
  return '';
}

function isNotebookObjectLineageSource(source = {}) {
  return source.item_type === 'NotebookObjectLineage' || Boolean(source.notebook_super_lineage_only);
}

function cleanObjectStoreCandidate(value, source = {}) {
  const candidate = text(value).trim();
  if (!candidate || isGenericNotebookSourceLabel(candidate)) return '';
  if (isNotebookObjectLineageSource(source) && isGenericNotebookSourceLabel(source.label || source.original_label)) {
    const itemName = notebookLineageItemNameFromQualified(source);
    if (itemName && normalize(candidate) === normalize(itemName)) return '';
  }
  return candidate;
}

function sourceDisplayStoreName(source = {}) {
  return objectStoreName({}, source);
}

function sourceDisplayLabelCandidate(source = {}) {
  const label = text(source.label || source.name).trim();
  return label && !isGenericNotebookSourceLabel(label) ? label : '';
}

function objectStoreName(object = {}, source = {}) {
  const candidates = [
    object.database,
    object.source_database,
    object.source_name,
    source.database,
    source.source_database,
    source.source_name
  ];
  for (const candidate of candidates) {
    const clean = cleanObjectStoreCandidate(candidate, source);
    if (clean) return clean;
  }
  return '';
}

function objectSchemaName(object = {}) {
  return text(object.schema || object.schema_name || object.object_schema || '').trim();
}

function startsWithObjectPrefix(value, prefix, separator = '.') {
  return Boolean(value && prefix && text(value).toLowerCase().startsWith(`${text(prefix).toLowerCase()}${separator}`));
}

function canonicalObjectDisplayName(object = {}, source = {}) {
  const dynamicVariable = unresolvedVariableName(object);
  if (dynamicVariable) {
    // Only the lakehouse/schema part is a runtime variable here (e.g. code
    // builds the path as f"{sales_silver_lh_id}.dbo.CustomerCountry");
    // the actual table name after it is real and resolved. Collapsing
    // straight to "ƒ(sales_silver_lh_id)" with nothing else discarded
    // that real name, so every table sharing that same variable (there can
    // be dozens under one notebook) rendered as the exact same repeated
    // label -- indistinguishable noise instead of the real distinct tables
    // it actually reads. Keep the resolved object name alongside the
    // variable marker.
    const resolvedObjectName = text(object.object_name || object.name || '').trim();
    if (resolvedObjectName && normalize(resolvedObjectName) !== normalize(dynamicVariable)) {
      return `ƒ(${dynamicVariable}).${resolvedObjectName}`;
    }
    return `ƒ(${dynamicVariable})`;
  }
  const store = objectStoreName(object, source);
  const schema = objectSchemaName(object);
  const rawObjectName = text(object.object_name || object.name || '').trim();
  const rawLabel = text(object.object_display_name || object.label || object.qualified_name || rawObjectName || t('unknown')).trim();
  const sourceType = object.source_type || source.source_type || object.raw_object_type || '';
  const rawName = rawObjectName || rawLabel;
  if (!rawName) return rawLabel || t('unknown');
  if (store && (startsWithObjectPrefix(rawName, store) || startsWithObjectPrefix(rawLabel, store))) {
    return startsWithObjectPrefix(rawName, store) ? rawName : rawLabel;
  }
  if (sourceType === 'File') {
    if (store && startsWithObjectPrefix(rawName, store, '/')) return rawName;
    if (store && rawObjectName && !rawObjectName.includes('://')) return `${store}/${rawObjectName.replace(/^\/+/, '')}`;
    return rawLabel || rawName;
  }
  if (schema && startsWithObjectPrefix(rawName, schema)) {
    return store ? `${store}.${rawName}` : rawName;
  }
  if (schema && startsWithObjectPrefix(rawLabel, schema)) {
    return store ? `${store}.${rawLabel}` : rawLabel;
  }
  if (store && schema && rawObjectName) return `${store}.${schema}.${rawObjectName}`;
  if (schema && rawObjectName) return `${schema}.${rawObjectName}`;
  if (store && rawObjectName) return `${store}.${rawObjectName}`;
  return rawLabel || rawName;
}

// Igual que canonicalObjectDisplayName pero sin el prefijo "store.schema." --
// para listas donde el origen y el schema ya se muestran aparte (tarjeta de
// origen y/o columnas propias), repetirlos dentro del propio nombre sólo
// ocupa espacio sin aportar nada nuevo.
function objectBareName(object = {}) {
  const dynamicVariable = unresolvedVariableName(object);
  if (dynamicVariable) {
    const resolvedObjectName = text(object.object_name || object.name || '').trim();
    if (resolvedObjectName && normalize(resolvedObjectName) !== normalize(dynamicVariable)) {
      return `ƒ(${dynamicVariable}).${resolvedObjectName}`;
    }
    return `ƒ(${dynamicVariable})`;
  }
  const rawObjectName = text(object.object_name || object.name || '').trim();
  const rawLabel = text(object.object_display_name || object.label || object.qualified_name || rawObjectName || t('unknown')).trim();
  return rawObjectName || rawLabel || t('unknown');
}

function diagramObjectTypeMatches(object) {
  const filter = state.filters.diagramObjectType;
  if (filter === 'all') return true;
  return diagramObjectRawType(object) === filter;
}

function diagramObjectKey(source, object) {
  return [
    object.source_workspace_name || source.workspace_name,
    object.source_label || source.label,
    object.source_qualified_name || source.qualified_name,
    object.server || source.server,
    object.database || source.database,
    object.source_type || source.source_type,
    diagramObjectRawType(object),
    object.schema || object.schema_name || object.object_schema,
    object.object_name || object.name,
    object.label || object.qualified_name
  ].map(value => normalize(value)).join('|');
}

function diagramObjectLabel(object, source = {}) {
  return canonicalObjectDisplayName(object, source);
}

function diagramObjectMeta(source, object) {
  const store = objectStoreName(object, source);
  const sourceLabel = sourceDisplayLabelCandidate(source);
  return [
    objectTypeLabel(diagramObjectRawType(object)),
    store || sourceLabel || source.server,
    sourceTypeLabel(object.source_type || source.source_type)
  ].filter(Boolean).join(' · ');
}

function diagramObjectVisible(source, object) {
  if (!supportsDiagramObjectFilters()) return true;
  if (!diagramObjectTypeMatches(object)) return false;
  if (state.diagramObjectSelectionMode === 'none') return false;
  if (state.diagramObjectSelectionMode === 'custom') {
    return state.diagramSelectedObjectKeys.has(diagramObjectKey(source, object));
  }
  return true;
}

function visibleObjectsForSource(source) {
  return asList(source.objects).filter(object => diagramObjectVisible(source, object));
}

function sourceVisible(source) {
  if (!diagramSourceTypeMatches(source)) return false;
  if (!supportsDiagramObjectFilters()) return true;
  if (state.filters.diagramStore !== 'all' && diagramStoreKey(source) !== state.filters.diagramStore) return false;
  const objects = asList(source.objects);
  if (!objects.length) {
    return state.filters.diagramObjectType === 'all' && state.diagramObjectSelectionMode === 'all';
  }
  return objects.some(object => diagramObjectVisible(source, object));
}

function normalizedLineageRole(value) {
  const key = normalize(value);
  if (['read', 'reads', 'source', 'input', 'reads_from'].includes(key)) return 'read';
  if (['write', 'writes', 'sink', 'target', 'destination', 'output', 'writes_to'].includes(key)) return 'write';
  if (['execute', 'executes', 'executed'].includes(key)) return 'execute';
  return 'reference';
}

function objectLineageRole(object) {
  return normalizedLineageRole(object && object.usage_type);
}

function copyJobSourceRole(source, item) {
  if (!item || item.item_type !== 'CopyJob' || !source) return '';
  const key = sourceIconKey(source);
  const objects = asList(source.objects);
  const hasReadObject = objects.some(object => normalizedLineageRole(object.usage_type) === 'read');
  const hasWriteObject = objects.some(object => normalizedLineageRole(object.usage_type) === 'write');
  if (hasReadObject && !hasWriteObject) return 'read';
  if (hasReadObject && hasWriteObject && (key.includes('sql') || key.includes('external'))) return 'read';
  if (sourceEvidenceImpliesWrite(source)) return 'write';
  if ((key.includes('sql') || key.includes('external') || key.includes('fabricorsql')) && objects.length) return 'read';
  if (sourceIsFabricStore(source) || key.includes('lakehouse') || key.includes('/tables') || key.includes('lh_')) {
    return objects.length ? (hasWriteObject ? 'write' : 'read') : 'write';
  }
  return '';
}

function sourceLineageRole(source, item) {
  return copyJobSourceRole(source, item) || sourcePlanningUsage(source, item);
}

function objectLineageRoleForSource(source, item, object) {
  const copyJobRole = copyJobSourceRole(source, item);
  return copyJobRole || objectLineageRole(object);
}

function sourceInferredLineageRoles(source, item) {
  const usage = sourceLineageRole(source, item);
  if (usage === 'readWrite') return ['read', 'write'];
  if (usage === 'write') return ['write'];
  if (usage === 'execute') return ['execute'];
  if (usage === 'reference') return ['reference'];
  return ['read'];
}

function processLineageGroupSpecs() {
  return [
    { role: 'read', group: 'readSources', labelKey: 'readSources', objectLabelKey: 'detectedReadObjects', planningRole: 'input' },
    { role: 'write', group: 'writeTargets', labelKey: 'writeTargets', objectLabelKey: 'detectedWriteObjects', planningRole: 'output' },
    { role: 'execute', group: 'executedObjects', labelKey: 'executedObjects', objectLabelKey: 'detectedExecutedObjects', planningRole: 'execute' },
    { role: 'reference', group: 'referenceSources', labelKey: 'referenceSources', objectLabelKey: 'detectedReferencedObjects', planningRole: 'reference' }
  ];
}

function isGenericNotebookSourceLabel(value) {
  return /^(?:Notebook (?:read sources|write targets|executed objects|file inputs)|Origen pendiente|Destino pendiente|Objetos ejecutados|Archivos|Unresolved source|Unresolved target|Executed objects|Files)$/i.test(text(value).trim());
}

function processSourceDisplayLabel(source, item, spec) {
  const label = text(source.label).trim();
  if (label && !isGenericNotebookSourceLabel(label)) return label;
  const objectDatabases = uniqueBy(asList(source.objects)
    .map(object => object.database || object.source_name || object.source_database)
    .filter(value => value && normalize(value) !== normalize(item && item.label)), value => normalize(value));
  if (objectDatabases.length === 1) return objectDatabases[0];
  if (source.database && normalize(source.database) !== normalize(item && item.label)) return source.database;
  if (source.server && normalize(source.server) !== normalize(item && item.workspace_name)) return source.server;
  if (source.source_type === 'File') return label || t('groups.detectedReadObjects');
  return t(`groups.${spec.objectLabelKey}`);
}

function processSourceShouldFlatten(source, objects) {
  return isGenericNotebookSourceLabel(source.label) && asList(objects).length > 0;
}

function processObjectNode(parentNode, source, item, object, spec, sourceIndex, objectIndex) {
  const sourceLabel = processSourceDisplayLabel(source, item, spec);
  const label = canonicalObjectDisplayName(object, source);
  return {
    id: `${parentNode.id}:lineage:${spec.role}:object:${sourceIndex}:${objectIndex}:${object.object_name || object.label || objectIndex}`,
    kind: 'object',
    label,
    data: {
      ...object,
      label,
      workspace_name: object.workspace_name || item.workspace_name,
      source_workspace_name: source.workspace_name || item.workspace_name,
      source_label: sourceLabel,
      source_type: object.source_type || source.source_type,
      lineage_usage_role: spec.role,
      lineage_usage_label: t(`groups.${spec.labelKey}`)
    }
  };
}

function processSourceNode(parentNode, source, item, objects, spec, sourceIndex) {
  const sourceLabel = processSourceDisplayLabel(source, item, spec);
  const clonedObjects = asList(objects).map(object => ({
    ...object,
    workspace_name: object.workspace_name || item.workspace_name,
    source_workspace_name: source.workspace_name || item.workspace_name,
    source_label: sourceLabel,
    source_type: object.source_type || source.source_type,
    lineage_usage_role: spec.role,
    lineage_usage_label: t(`groups.${spec.labelKey}`)
  }));
  return {
    id: `${parentNode.id}:lineage:${spec.role}:source:${sourceIndex}:${source.id || sourceKey(source)}`,
    kind: 'source',
    label: sourceLabel,
    data: {
      ...source,
      label: sourceLabel,
      original_label: source.label,
      lineage_usage_role: spec.role,
      lineage_usage_label: t(`groups.${spec.labelKey}`),
      lineage_object_count: clonedObjects.length,
      planning_role: spec.planningRole,
      objects: clonedObjects
    }
  };
}

// Single relationship model for every item kind: classify each source's
// objects by real role (read/write/execute/reference, see
// objectLineageRoleForSource) the exact same way regardless of whether the
// item is a Notebook, a CopyJob, a SemanticModel or a Report. What used to
// decide the *type of item* -- Notebook/CopyJob/DataPipeline got separate
// read/write/execute groups, everything else got a single flattened
// "sources" bucket -- is now decided by the *data*: only split into
// separate role groups when a role other than "read" actually has
// anything in it. An item that only ever reads (which today is every
// SemanticModel/Report, but is not hardcoded to be) collapses into one
// "Origenes de datos" heading together with any related models; an item
// that also writes/executes/references keeps the role split, because that
// distinction is genuinely useful there.
function processLineageGroupsForItem(node) {
  const item = node.data || {};
  const visibleSources = asList(item.sources).filter(sourceVisible);
  const relatedModels = asList(item.models);
  if (!visibleSources.length && !relatedModels.length) return null;

  const nodesByRole = {};
  for (const spec of processLineageGroupSpecs()) {
    const nodes = [];
    visibleSources.forEach((source, sourceIndex) => {
      const allObjects = asList(source.objects);
      const visibleObjects = visibleObjectsForSource(source);
      const objects = visibleObjects.filter(object => objectLineageRoleForSource(source, item, object) === spec.role);
      const inferredRoles = allObjects.length ? [] : sourceInferredLineageRoles(source, item);
      const includeSourceWithoutObjects = !allObjects.length && inferredRoles.includes(spec.role);
      if (!objects.length && !includeSourceWithoutObjects) return;

      if (processSourceShouldFlatten(source, objects)) {
        objects.forEach((object, objectIndex) => {
          nodes.push(processObjectNode(node, source, item, object, spec, sourceIndex, objectIndex));
        });
      } else {
        nodes.push(processSourceNode(node, source, item, objects, spec, sourceIndex));
      }
    });
    if (nodes.length) nodesByRole[spec.role] = nodes;
  }

  // reached_via_lineage_path marks a model embedded here as part of tracing
  // *toward* the origin (e.g. from a report) -- childrenForNode's 'item'
  // branch uses it to skip re-adding the model's own "reports" group below,
  // which would otherwise show every report that uses this model (including
  // the very one the user is drilling down from) as if expanding the model
  // were forward progress, when what the user actually asked for by
  // drilling this direction is the model's real upstream source/database,
  // not a loop back toward reports.
  const modelNodes = relatedModels.map((model, index) => ({
    id: `${node.id}:models:${index}`,
    kind: kindForItem(model, 'item'),
    label: model.label,
    data: { ...model, reached_via_lineage_path: true }
  }));

  const hasDistinctRole = Boolean(nodesByRole.write || nodesByRole.execute);
  if (!hasDistinctRole) {
    const mergedNodes = [...(nodesByRole.read || []), ...(nodesByRole.reference || []), ...modelNodes];
    if (!mergedNodes.length) return null;
    return [{
      id: `${node.id}:sources`,
      kind: 'group',
      group: 'sources',
      label: t('groups.sources'),
      data: { nodes: mergedNodes }
    }];
  }

  const groups = [];
  for (const spec of processLineageGroupSpecs()) {
    const nodes = nodesByRole[spec.role];
    if (!nodes || !nodes.length) continue;
    groups.push({
      id: `${node.id}:lineage:${spec.role}`,
      kind: 'group',
      group: spec.group,
      label: t(`groups.${spec.labelKey}`),
      data: {
        nodes,
        lineage_group: spec.role,
        lineage_group_label: t(`groups.${spec.labelKey}`)
      }
    });
  }
  if (modelNodes.length) {
    groups.push({ id: `${node.id}:models`, kind: 'group', group: 'models', label: t('groups.models'), data: { nodes: modelNodes } });
  }
  return groups.length ? groups : null;
}

function impactData() {
  return state.impact || (state.data && state.data.impact) || window.OBJECT_IMPACT_DATA || { summary: {}, objects: [] };
}

// Same fix as selectedWorkspaceListForPlanning(): selectedWorkspaceList()
// is built on currentWorkspaces(), which hides workspaces with zero items
// of the CURRENT mode's type. Routing Impact's workspace scope through it
// meant a workspace selection could silently shrink depending on which
// mode was active -- e.g. a workspace whose only item is a Dataflow would
// drop out of scope while in Semantic Models mode, hiding that workspace's
// objects from the impact board entirely instead of just their (absent)
// semantic-model column. Impact always reads from the full workspace list.
function selectedImpactWorkspaceSet() {
  return new Set(selectedWorkspaceListForPlanning().map(workspace => workspace.name));
}

function impactObjectInScope(object) {
  const selected = selectedImpactWorkspaceSet();
  if (!selected.size) return true;
  return asList(object.workspaces).some(workspace => selected.has(workspace)) ||
    asList(object.direct_items).some(item => selected.has(item.workspace_name)) ||
    asList(object.downstream_reports).some(report => selected.has(report.workspace_name));
}

function impactDatabaseKey(object) {
  return [object.source_server || '', object.source_database || '', object.source_type || '']
    .map(value => encodeURIComponent(value))
    .join('|');
}

function impactDatabaseLabel(object, duplicateNames = new Set()) {
  const name = object.source_database || object.source_server || sourceTypeDisplay(object.source_type) || t('unknown');
  if (!duplicateNames.has(name)) return name;
  const server = object.source_server ? ` · ${object.source_server}` : '';
  return `${name}${server}`;
}

function impactObjectTypeTokens(object) {
  const values = text(object.object_type_values)
    .split(';')
    .map(value => value.trim())
    .filter(Boolean);
  return values.length ? values : ['unknown'];
}

function impactObjectHasType(object, type) {
  return type === 'all' || impactObjectTypeTokens(object).includes(type);
}

function impactObjectFilterLabel(object) {
  return canonicalObjectDisplayName({
    object_display_name: object.object_display_name,
    source_database: object.source_database,
    source_name: object.source_database,
    schema_name: object.schema_name,
    object_name: object.object_name,
    source_type: object.source_type,
    raw_object_type: object.object_type_values
  }) || object.object_key || t('unknown');
}

// Igual que impactObjectFilterLabel pero sin el prefijo "base.schema." -- la
// tabla de Impacto (impactObjectTable) ya muestra origen y schema como sus
// propias columnas, así que repetirlos dentro del nombre sólo quita sitio.
function impactObjectBareName(object) {
  return objectBareName({
    object_display_name: object.object_display_name,
    object_name: object.object_name,
    label: object.object_display_name,
    qualified_name: object.object_key
  }) || object.object_key || t('unknown');
}

function impactObjectOrigin(object) {
  return object.source_database || object.source_server || sourceTypeDisplay(object.source_type) || '—';
}

function impactObjectSchema(object) {
  return text(object.schema_name).trim() || '—';
}

function impactObjectSearchLabel(object) {
  const label = impactObjectFilterLabel(object);
  const source = [
    object.source_database || object.source_server || sourceTypeDisplay(object.source_type),
    object.source_database && object.source_server ? object.source_server : '',
    impactObjectTypeLabel(object)
  ].filter(Boolean).join(' · ');
  const impact = Number(object.total_impact_count || 0) > 0
    ? `${number(object.total_impact_count)} ${t('impactLabels.totalImpact')}`
    : t('impactLabels.catalogOnly');
  return [label, source, impact].filter(Boolean).join(' · ');
}

function impactObjectSearchText(object) {
  return normalize([
    impactObjectSearchLabel(object),
    impactObjectFilterLabel(object),
    object.search_text,
    object.object_key,
    object.object_display_name,
    object.object_name,
    object.schema_name,
    object.source_type,
    object.source_server,
    object.source_database,
    object.object_type_values,
    object.object_type_sources
  ].filter(Boolean).join(' '));
}

function impactObjectMatchesPickerQuery(object) {
  if (state.impactSelectedObjectKeys.size || state.filters.impactObjectKey !== 'all') return true;
  const query = normalize(state.impactObjectSearch);
  return !query || impactObjectSearchText(object).includes(query);
}

function clearImpactObjectSearch() {
  cancelImpactSearchRender();
  state.impactObjectSearch = '';
  state.filters.impactObjectKey = 'all';
  state.impactSelectedObjectKeys = new Set();
  state.history = [];
  state.selectedNode = null;
}

function setImpactObjectSearch(value) {
  state.impactObjectSearch = value;
  state.filters.impactObjectKey = 'all';
  state.history = [];
  state.selectedNode = null;
}

function impactObjectMatchesFilters(object) {
  const sourceTypeOk = state.filters.sourceType === 'all' || object.source_type === state.filters.sourceType;
  const databaseOk = state.filters.impactDatabase === 'all' || impactDatabaseKey(object) === state.filters.impactDatabase;
  const objectTypeOk = impactObjectHasType(object, state.filters.impactObjectType);
  const objectOk = state.impactSelectedObjectKeys.size
    ? state.impactSelectedObjectKeys.has(object.object_key)
    : (state.filters.impactObjectKey === 'all' || object.object_key === state.filters.impactObjectKey);
  return sourceTypeOk && databaseOk && objectTypeOk && objectOk;
}

function impactObjectMatchesSearch(object, query) {
  if (!query) return true;
  if (normalize(object.search_text).includes(query)) return true;
  return [
    object.object_display_name,
    object.source_type,
    object.source_server,
    object.source_database,
    object.schema_name,
    object.object_name,
    object.object_type_values,
    object.object_type_sources
  ].some(value => normalize(value).includes(query)) ||
    asList(object.workspaces).some(workspace => normalize(workspace).includes(query)) ||
    asList(object.direct_items).some(item => matchesItemReferenceText(item, query) || normalize(item.semantic_table).includes(query)) ||
    asList(object.downstream_reports).some(report => matchesItemReferenceText(report, query));
}

function impactObjectsForScope() {
  return asList(impactData().objects).filter(impactObjectInScope);
}

function filteredImpactObjects() {
  const query = normalize(state.search);
  return impactObjectsForScope()
    .filter(impactObjectMatchesFilters)
    .filter(impactObjectMatchesPickerQuery)
    .filter(object => impactObjectMatchesSearch(object, query));
}

function applyLayoutState() {
  document.body.classList.toggle('focus-mode', state.focusMode);
  document.body.classList.toggle('details-collapsed', !state.showDetails);
  document.body.classList.toggle('scene-disabled', !state.sceneEnabled);
  els.focusButton.classList.toggle('active', state.focusMode);
  els.focusButton.textContent = state.focusMode ? '›' : '‹';
  els.focusButton.title = state.focusMode
    ? (state.lang === 'es' ? 'Abrir indice' : 'Open index')
    : (state.lang === 'es' ? 'Cerrar indice' : 'Close index');
  els.focusButton.setAttribute('aria-label', els.focusButton.title);
  els.focusButton.setAttribute('aria-expanded', state.focusMode ? 'false' : 'true');
  els.detailsToggleButton.classList.toggle('active', !state.showDetails);
  els.detailsToggleButton.textContent = state.showDetails ? '›' : '‹';
  els.detailsToggleButton.title = state.showDetails
    ? (state.lang === 'es' ? 'Cerrar detalles' : 'Close details')
    : (state.lang === 'es' ? 'Abrir detalles' : 'Open details');
  els.detailsToggleButton.setAttribute('aria-label', els.detailsToggleButton.title);
  els.detailsToggleButton.setAttribute('aria-expanded', state.showDetails ? 'true' : 'false');
  els.inspectionButton.classList.toggle('active', state.viewMode === 'lineage');
  els.impactButton.classList.toggle('active', state.viewMode === 'impact');
  els.scheduleButton.classList.toggle('active', state.viewMode === 'planning');
  els.inspectionButton.setAttribute('aria-pressed', state.viewMode === 'lineage' ? 'true' : 'false');
  els.impactButton.setAttribute('aria-pressed', state.viewMode === 'impact' ? 'true' : 'false');
  els.scheduleButton.setAttribute('aria-pressed', state.viewMode === 'planning' ? 'true' : 'false');
  if (els.sceneToggleButton) els.sceneToggleButton.classList.toggle('active', state.sceneEnabled);
  // Un único botón "abrir mapa" en la barra de herramientas, cuyo destino
  // cambia con el modo activo: Planificación abre su propio popup de mapa;
  // Inspección maximiza su propio árbol +/- a pantalla completa (ver
  // toggleInspectionMap) -- NO el Graph Map de tenant completo, que ya
  // tiene su propio botón aparte arriba; Impacto no lo necesita (ya tiene
  // su propia tabla de objetos afectados).
  const planningMapButton = document.getElementById('planningMapButton');
  if (planningMapButton) {
    planningMapButton.hidden = state.viewMode === 'impact';
    planningMapButton.title = state.viewMode === 'planning'
      ? (state.lang === 'es' ? 'Abrir mapa de planificación' : 'Open planning map')
      : (state.lang === 'es' ? 'Maximizar árbol de inspección' : 'Maximize inspection tree');
  }
  els.filterButton.classList.toggle('filter-active', hasActiveFilters());
}

function rememberSelection(node) {
  if (!state.selectedNode || state.selectedNode.id === node.id) return;
  state.history.push(state.selectedNode);
  if (state.history.length > 40) state.history.shift();
}

function selectNode(node, remember = true) {
  if (!node) return;
  cancelImpactSearchRender();
  const viewportSnapshot = viewportScrollSnapshot();
  if (remember) rememberSelection(node);
  state.selectedNode = node;
  renderDetails(node);
  renderTree();
  restoreViewportScroll(viewportSnapshot);
  applyLayoutState();
  trackUsageEvent('item_view', (node.data && node.data.qualified_name) || node.qualified_name || node.id || '', (node.data && node.data.item_type) || node.mode || '');
}

// Lineage-usage analytics (2026-08-24 Fase 6): fire-and-forget, never
// awaited and never lets a failure surface to the user -- this is
// instrumentation, not a feature the app depends on. selectNode() is the
// single place every node selection (search, graph click, tree
// expand-and-jump) already funnels through, so this one call site covers
// all of them without touching each interaction path separately. See
// backend/scripts/lineage_web/analytics.py for what this feeds (the
// admin panel's Analíticas tab: busiest items, usage trend, active users).
function trackUsageEvent(eventType, qualifiedName, itemType) {
  if (!qualifiedName) return;
  // The endpoint only records signed-in sessions; skip the request (and
  // its 401) when browsing anonymously in demo mode.
  if (!authState.signedIn) return;
  try {
    fetch(`${TRIGGER_SERVER_ORIGIN}/api/analytics/event`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ event_type: eventType, qualified_name: qualifiedName, item_type: itemType }),
      keepalive: true,
    }).catch(() => {});
  } catch (error) {
    // best-effort -- see this function's own comment above
  }
}

// Mapa de Inspección (2026-07-20): a diferencia de Planificación (una vista
// aparte, con su propio popup y motor de render que hay que mantener
// sincronizado con el lienzo normal), Inspección no necesita una segunda
// copia -- su árbol +/- YA es lo que se quiere ver maximizado. "Abrir el
// mapa" aquí sólo significa: el mismo #graphSurface (cabecera, filtro,
// árbol, leyenda) a pantalla completa vía position:fixed. Nada se
// reconstruye ni se desconecta, así que cada funcionalidad (filtro, zoom,
// expandir/colapsar nodos) sigue funcionando exactamente igual dentro.
function inspectionMapIsOpen() {
  return Boolean(els.graphSurface && els.graphSurface.classList.contains('maximized'));
}

function openInspectionMap() {
  if (!els.graphSurface || inspectionMapIsOpen()) return;
  els.graphSurface.classList.add('maximized');
  if (els.inspectionMapCloseButton) els.inspectionMapCloseButton.hidden = false;
  if (els.inspectionMapPngButton) els.inspectionMapPngButton.hidden = false;
  if (els.inspectionMapExcelButton) els.inspectionMapExcelButton.hidden = false;
  document.body.classList.add('inspection-map-open');
  requestAnimationFrame(() => requestAnimationFrame(applyTransform));
}

function closeInspectionMap() {
  if (!els.graphSurface || !inspectionMapIsOpen()) return;
  els.graphSurface.classList.remove('maximized');
  if (els.inspectionMapCloseButton) els.inspectionMapCloseButton.hidden = true;
  if (els.inspectionMapPngButton) els.inspectionMapPngButton.hidden = true;
  if (els.inspectionMapExcelButton) els.inspectionMapExcelButton.hidden = true;
  document.body.classList.remove('inspection-map-open');
  requestAnimationFrame(() => requestAnimationFrame(applyTransform));
}

function toggleInspectionMap() {
  if (inspectionMapIsOpen()) closeInspectionMap();
  else openInspectionMap();
}

function setDiagramViewMode(viewMode) {
  if (!['lineage', 'impact', 'planning'].includes(viewMode)) return;
  cancelImpactSearchRender();
  hideFilterMenu();
  closeInspectionMap();
  state.viewMode = viewMode;
  state.view = { x: 0, y: 0, scale: 1 };
  state.history = [];
  state.selectedNode = null;
  render();
}

function keepValidWorkspaceSelection(autoSelect = false) {
  const workspaces = currentWorkspaces();
  // Prune against a mode-independent workspace list, not currentWorkspaces()
  // (mode-filtered) or currentWorkspacesIgnoringItemType() (still filters by
  // state.mode via rawModeItems() despite the name -- it only ignores the
  // finer state.filters.itemType). A workspace the user selected while in
  // one mode (say, Notebooks) must not silently drop out of the selection
  // just because it has zero items of whatever mode gets clicked next. That
  // mode-driven pruning was the other half of what made Planning (and the
  // workspace selection generally) look inconsistent across modes.
  const validNames = new Set(
    state.data.workspaces
      .filter(workspace => asList(workspace.all).length > 0)
      .filter(workspacePassesEnvironmentFilter)
    .filter(workspacePassesDomainFilter)
      .map(workspace => workspace.name)
  );
  const entries = currentIndexEntries();
  const validPipelineIds = new Set(entries.filter(entry => entry.kind === 'deploymentPipeline').map(entry => entry.id));
  state.selectedWorkspaces = new Set(Array.from(state.selectedWorkspaces).filter(name => validNames.has(name)));
  state.selectedDeploymentPipelines = new Set(
    Array.from(state.selectedDeploymentPipelines).filter(id => validPipelineIds.has(id))
  );
  state.selectedStageWorkspaces = new Map(
    Array.from(state.selectedStageWorkspaces.entries()).filter(([id]) => validPipelineIds.has(id))
  );
  if (state.selectedWorkspace && !validNames.has(state.selectedWorkspace)) {
    state.selectedWorkspace = state.selectedWorkspaces.values().next().value || '';
  }
  if (autoSelect && !state.selectedWorkspaces.size && !state.selectedDeploymentPipelines.size && entries.length) {
    applyIndexEntrySelection(entries[0], false);
  }
  state.expanded = new Set(Array.from(state.expanded).filter(id => {
    if (id.startsWith('workspace:')) return validNames.has(id.slice('workspace:'.length));
    if (id.startsWith('deploymentPipeline:')) return validPipelineIds.has(id.slice('deploymentPipeline:'.length));
    return true;
  }));
  for (const id of state.selectedDeploymentPipelines) state.expanded.add(`deploymentPipeline:${id}`);
  for (const entry of entries) {
    if (entry.kind === 'workspace' && state.selectedWorkspaces.has(entry.data.name)) {
      state.expanded.add(`workspace:${entry.data.name}`);
    }
  }
  return workspaces;
}

function toggleWorkspaceEnvironmentFilter(environment) {
  const key = text(environment).toUpperCase();
  if (!['DEV', 'QA', 'PRO'].includes(key)) return;
  if (state.selectedWorkspaceEnvironments.has(key)) state.selectedWorkspaceEnvironments.delete(key);
  else state.selectedWorkspaceEnvironments.add(key);
  state.selectedStageWorkspaces = new Map();
  state.history = [];
  state.selectedNode = null;
  state.planningSourceSearch = '';
  state.planningSelectedSources = new Set();
  keepValidWorkspaceSelection(true);
  render();
}

function setWorkspaceDomainFilter(domain) {
  state.selectedWorkspaceDomain = domain || 'all';
  state.selectedStageWorkspaces = new Map();
  state.history = [];
  state.selectedNode = null;
  state.planningSourceSearch = '';
  state.planningSelectedSources = new Set();
  keepValidWorkspaceSelection(true);
  render();
}

function selectAllWorkspaces() {
  const entries = currentIndexEntries();
  state.selectedDeploymentPipelines = new Set(entries.filter(entry => entry.kind === 'deploymentPipeline').map(entry => entry.id));
  state.selectedWorkspaces = new Set(entries.flatMap(entryWorkspaceNames));
  state.selectedStageWorkspaces = new Map();
  state.selectedWorkspace = state.selectedWorkspaces.values().next().value || '';
  const standaloneNames = entries.filter(entry => entry.kind === 'workspace').map(entry => entry.data.name);
  state.expanded = new Set([
    ...Array.from(state.selectedDeploymentPipelines).map(id => `deploymentPipeline:${id}`),
    ...standaloneNames.map(name => `workspace:${name}`)
  ]);
  state.history = [];
  state.selectedNode = null;
  state.planningSourceSearch = '';
  state.planningSelectedSources = new Set();
  render();
}

function clearWorkspaceSelection() {
  state.selectedWorkspaces = new Set();
  state.selectedDeploymentPipelines = new Set();
  state.selectedStageWorkspaces = new Map();
  state.selectedWorkspace = '';
  state.expanded = new Set();
  state.history = [];
  state.selectedNode = null;
  state.planningSourceSearch = '';
  state.planningSelectedSources = new Set();
  render();
}

function resetAll() {
  cancelImpactSearchRender();
  state.mode = 'all';
  state.viewMode = 'lineage';
  state.search = '';
  state.filters = {
    sourceType: 'all',
    confidence: 'all',
    itemType: 'all',
    diagramStore: 'all',
    diagramObjectType: 'all',
    impactDatabase: 'all',
    impactObjectType: 'all',
    impactObjectKey: 'all'
  };
  state.impactObjectSearch = '';
  state.impactSelectedObjectKeys = new Set();
  clearDiagramObjectSelection('all');
  state.planningSourceSearch = '';
  state.planningSelectedSources = new Set();
  // Folded in 2026-07-19 when planningResetLayoutButton (a second,
  // Planning-only "restaurar orden" icon living right next to zoom
  // controls) was removed as a separate visible button -- one reset
  // control now clears dragged card positions too, instead of that
  // capability only being reachable via a second icon.
  state.planningNodePositions = new Map();
  state.focusMode = false;
  state.showDetails = true;
  state.history = [];
  state.expanded = new Set();
  state.selectedNode = null;
  state.selectedWorkspace = '';
  state.selectedWorkspaces = new Set();
  state.selectedDeploymentPipelines = new Set();
  state.selectedStageWorkspaces = new Map();
  state.selectedWorkspaceEnvironments = new Set();
  state.view = { x: 0, y: 0, scale: 1 };
  els.searchInput.value = '';
  hideFilterMenu();
  setMode('semantic');
}

const THEME_STORAGE_KEY = 'fabric_lineage_theme';

// 'auto' follows prefers-color-scheme (see the inline <head> script and the
// @media block in styles.css, which apply the same logic before this file
// even loads, to avoid a flash of the wrong theme); 'light'/'dark' pin an
// explicit choice via the data-theme attribute both of those also check.
function setTheme(theme) {
  state.theme = theme;
  if (theme === 'auto') {
    document.documentElement.removeAttribute('data-theme');
  } else {
    document.documentElement.setAttribute('data-theme', theme);
  }
  try {
    window.localStorage.setItem(THEME_STORAGE_KEY, theme);
  } catch (e) {}
  [
    [els.themeAutoButton, els.themeLightButton, els.themeDarkButton],
    [els.authGateThemeAutoButton, els.authGateThemeLightButton, els.authGateThemeDarkButton]
  ].forEach(([autoBtn, lightBtn, darkBtn]) => {
    if (!autoBtn || !lightBtn || !darkBtn) return;
    autoBtn.classList.toggle('active', theme === 'auto');
    lightBtn.classList.toggle('active', theme === 'light');
    darkBtn.classList.toggle('active', theme === 'dark');
  });
  if (window.GraphMap) window.GraphMap.onThemeChange(theme);
  if (window.DagView) window.DagView.onThemeChange(theme);
}

function initTheme() {
  let stored = 'auto';
  try {
    const raw = window.localStorage.getItem(THEME_STORAGE_KEY);
    if (raw === 'light' || raw === 'dark' || raw === 'auto') stored = raw;
  } catch (e) {}
  setTheme(stored);
}

function setLanguage(lang) {
  state.lang = lang;
  document.documentElement.lang = lang;
  applyAuthGateLanguage();
  renderUserBadgeName();
  // Graph Map Mode (graph-map.js) and the DAG view own their own rendering
  // entirely; these are the hooks they need so their text (including their
  // toolbar button labels, visible from page load) stays in sync. Called
  // before the early return below: switching language on the sign-in gate,
  // before any data exists, used to leave "Grafo"/"Flujo" in Spanish.
  if (window.GraphMap) window.GraphMap.onLanguageChange(lang);
  if (window.DagView) window.DagView.onLanguageChange(lang);
  if (!state.data) return; // gate is still up; nothing else has rendered yet
  render();
  if (els.helpPanel && !els.helpPanel.hidden) renderHelpPanel();
  // Any other modal already open when the language switches keeps showing
  // whichever language it was rendered in until closed/reopened otherwise
  // -- re-render it in place so it doesn't lag behind the rest of the UI.
  if (els.adminPanel && !els.adminPanel.hidden) renderAdminPanel();
  if (els.governancePanel && !els.governancePanel.hidden) renderGovernancePanel();
  if (els.glossaryPanel && !els.glossaryPanel.hidden) renderGlossaryPanel();
  if (els.scanHistoryPanel && !els.scanHistoryPanel.hidden) renderScanHistoryTable(scanHistoryRunsCache);
  if (els.profileMenu && !els.profileMenu.hidden) renderProfileMenu();
  if (els.profilePanel && !els.profilePanel.hidden) renderProfilePanel();
  if (els.notificationsPanel && !els.notificationsPanel.hidden) renderAlertsPanel();
  if (els.impactBreakdownModal && !els.impactBreakdownModal.hidden && impactBreakdownState) {
    renderImpactBreakdownModal(impactBreakdownState.objectKey, impactBreakdownState.category);
  }
  if (planningMapState.open) renderPlanningMapLabels();
  // The "last scan" hint next to the scan controls is fetched text, not a
  // static label -- rebuild it so it doesn't stay in the old language.
  updateLocalScanHint();
}

function setMode(mode) {
  cancelImpactSearchRender();
  state.mode = mode;
  state.viewMode = 'lineage';
  state.filters.sourceType = 'all';
  state.filters.itemType = 'all';
  state.filters.diagramStore = 'all';
  state.filters.diagramObjectType = 'all';
  clearDiagramObjectSelection('all');
  state.planningSourceSearch = '';
  state.planningSelectedSources = new Set();
  state.history = [];
  state.expanded = new Set();
  state.selectedNode = null;
  // Deliberately NOT resetting selectedWorkspaces/selectedDeploymentPipelines/
  // selectedStageWorkspaces here: this used to wipe the whole workspace
  // selection down to a single auto-picked workspace on every mode click,
  // which made Planning (and anything else reading the selection) look
  // inconsistent between modes even for the exact same intended scope.
  // keepValidWorkspaceSelection still prunes anything no longer valid.
  keepValidWorkspaceSelection(true);
  render();
  const root = selectedRootNodes()[0];
  if (root) selectNode(root, false);
  animateModeSwitch();
}

// "Clipboard tab" switch feedback (2026-08-18): even when two modes render
// near-identical content, a visible transition confirms the tab actually
// changed. render() above already rebuilt both the tree/graph area and the
// mode buttons synchronously, so this just replays a one-shot CSS animation
// on the (already updated) content and the now-active button -- remove +
// force reflow + re-add is what lets the same animation retrigger on back-
// to-back mode clicks instead of only playing once.
// Forcibly drops the clip-path reveal class + any inline clip-path once
// the animation ends (or via a fallback timer if animationend never fires
// for any reason) -- #graphSurface is the main pan/zoom/click surface for
// the whole dependency tree, so a clip-path stuck mid-animation here would
// leave most of the screen unable to receive pointer events at all (a
// live report, 2026-08-18: "no me deja moverme, como bloqueado" -- this
// class of bug is exactly what a bare CSS animation with no guaranteed
// cleanup risks, see the identical fix on Graph Map Mode's own reveal).
function clearModeSwitchClip() {
  const container = document.getElementById('graphSurface');
  if (container) {
    container.classList.remove('mode-switch-in');
    container.style.clipPath = '';
  }
}

function animateModeSwitch() {
  const container = document.getElementById('graphSurface');
  if (container) {
    clearModeSwitchClip();
    void container.offsetWidth;
    container.classList.add('mode-switch-in');
    container.addEventListener('animationend', clearModeSwitchClip, { once: true });
    setTimeout(clearModeSwitchClip, 600);
  }
  const activeButton = (els.modeBarVisible && els.modeBarVisible.querySelector('.mode-button.active'))
    || (els.modeOverflowToggle && els.modeOverflowToggle.classList.contains('active') ? els.modeOverflowToggle : null);
  if (activeButton) {
    activeButton.classList.remove('mode-switch-pulse');
    void activeButton.offsetWidth;
    activeButton.classList.add('mode-switch-pulse');
  }
}

function renderLabels() {
  els.pageTitle.textContent = t('title');
  if (els.notificationsButtonLabel) els.notificationsButtonLabel.textContent = state.lang === 'es' ? 'Avisos' : 'Alerts';
  if (els.notificationsButton) els.notificationsButton.title = state.lang === 'es' ? 'Notificaciones' : 'Notifications';
  if (els.governanceButtonLabel) els.governanceButtonLabel.textContent = state.lang === 'es' ? 'Gobernanza' : 'Governance';
  if (els.governanceButton) els.governanceButton.title = state.lang === 'es' ? 'Gobernanza' : 'Governance';
  if (els.privacyButtonLabel) els.privacyButtonLabel.textContent = state.lang === 'es' ? 'Privacidad' : 'Privacy';
  if (els.privacyButton) els.privacyButton.title = state.lang === 'es' ? 'Privacidad' : 'Privacy';
  els.searchLabel.textContent = t('search');
  els.searchInput.placeholder = t('searchPlaceholder');
  els.resetButton.title = t('reset');
  els.resetButton.setAttribute('aria-label', t('reset'));
  els.filterButton.textContent = t('filter');
  els.filterButton.title = t('filter');
  const filterTitle = els.filterMenu.querySelector('.filter-title');
  if (filterTitle) filterTitle.textContent = t('filter');
  if (els.zoomOutButton) {
    const zoomOutLabel = state.lang === 'es' ? 'Alejar' : 'Zoom out';
    els.zoomOutButton.title = zoomOutLabel;
    els.zoomOutButton.setAttribute('aria-label', zoomOutLabel);
  }
  if (els.zoomInButton) {
    const zoomInLabel = state.lang === 'es' ? 'Acercar' : 'Zoom in';
    els.zoomInButton.title = zoomInLabel;
    els.zoomInButton.setAttribute('aria-label', zoomInLabel);
  }
  if (els.fitButton) {
    const fitLabel = state.lang === 'es' ? 'Ajustar vista' : 'Fit view';
    els.fitButton.title = fitLabel;
    els.fitButton.setAttribute('aria-label', fitLabel);
  }
  if (els.planningResetLayoutButton) els.planningResetLayoutButton.title = state.lang === 'es' ? 'Restaurar orden' : 'Reset layout';
  const workspaceEnvFiltersEl = document.getElementById('workspaceEnvironmentFilters');
  if (workspaceEnvFiltersEl) workspaceEnvFiltersEl.setAttribute('aria-label', state.lang === 'es' ? 'Filtros de entorno de deployment pipeline' : 'Deployment pipeline environment filters');
  if (els.workspaceDomainFilterLabel) els.workspaceDomainFilterLabel.textContent = state.lang === 'es' ? 'Dominio' : 'Domain';
  els.inspectionButton.textContent = t('inspect');
  els.impactButton.textContent = t('impact');
  els.scheduleButton.textContent = t('schedule');
  els.workspacePanelTitle.textContent = t('workspaces');
  els.workspacePanelSubtitle.textContent = t('workspaceHint');
  els.sourceFilterLabel.textContent = t('source');
  els.itemTypeFilterLabel.textContent = t('itemType');
  els.metricWorkspacesLabel.textContent = t('workspaces');
  els.metricPrimaryLabel.textContent = t(`mode.${state.mode}`);
  els.metricSourcesLabel.textContent = t('sources');
  els.metricObjectsLabel.textContent = t('objects');
  els.selectAllWorkspacesButton.textContent = t('selectAll');
  els.clearWorkspacesButton.textContent = t('clear');
  if (els.workspaceSearchToggleLabel) els.workspaceSearchToggleLabel.textContent = t('workspaceSearchToggle');
  if (els.workspaceSearchInput) els.workspaceSearchInput.placeholder = t('workspaceSearchPlaceholder');
  els.workspaceEnvironmentButtons.forEach(button => {
    const environment = text(button.dataset.workspaceEnvFilter).toUpperCase();
    const active = state.selectedWorkspaceEnvironments.has(environment);
    button.classList.toggle('active', active);
    button.setAttribute('aria-pressed', active ? 'true' : 'false');
    button.title = t('deploymentEnvironmentFilter');
  });
  els.langEsButton.classList.toggle('active', state.lang === 'es');
  els.langEnButton.classList.toggle('active', state.lang === 'en');
  renderModeBar();
  const es = state.lang === 'es';
  if (els.adminButton) els.adminButton.title = es ? 'Panel de administración' : 'Admin panel';
  if (els.localScanButton) els.localScanButton.textContent = es ? 'Escanear este workspace' : 'Scan this workspace';
  if (els.fullScanButton) {
    els.fullScanButton.textContent = es ? 'Escaneo completo' : 'Full scan';
    els.fullScanButton.title = es
      ? 'Reescanea los workspaces a los que tienes acceso (varias horas)'
      : 'Rescans the workspaces you have access to (several hours)';
  }
  if (els.scanHistoryButton) els.scanHistoryButton.title = es ? 'Historial de escaneos' : 'Scan history';
  if (els.stopScanButton) els.stopScanButton.title = es ? 'Detener escaneo' : 'Stop scan';
  const scanHistoryTitleEl = document.getElementById('scanHistoryTitle');
  if (scanHistoryTitleEl) scanHistoryTitleEl.textContent = es ? 'Historial de escaneos' : 'Scan history';
  const scanHistoryCloseEl = document.getElementById('scanHistoryCloseButton');
  if (scanHistoryCloseEl) scanHistoryCloseEl.setAttribute('aria-label', es ? 'Cerrar' : 'Close');
  if (els.localScanWorkspaceSelect) els.localScanWorkspaceSelect.setAttribute('aria-label', es ? 'Workspace a escanear' : 'Workspace to scan');
  if (els.impactBreakdownExcelButton) els.impactBreakdownExcelButton.textContent = i18n[state.lang].detail.exportExcel;
  if (els.impactBreakdownCloseButton) els.impactBreakdownCloseButton.setAttribute('aria-label', es ? 'Cerrar' : 'Close');
  if (els.glossaryCloseButton) els.glossaryCloseButton.setAttribute('aria-label', es ? 'Cerrar' : 'Close');
}

function renderMetrics() {
  if (state.viewMode === 'impact') {
    const impact = impactData();
    const filteredObjects = filteredImpactObjects();
    const selectedCount = selectedWorkspaceList().length || currentWorkspaces().length;
    els.metricWorkspaces.textContent = number(selectedCount);
    els.metricPrimary.textContent = number(filteredObjects.length);
    els.metricSources.textContent = number(impact.summary && impact.summary.impacted_direct_items);
    els.metricObjects.textContent = number(impact.summary && impact.summary.downstream_reports);
    els.metricWorkspacesLabel.textContent = t('workspaces');
    els.metricPrimaryLabel.textContent = t('impactLabels.sourceObjects');
    els.metricSourcesLabel.textContent = t('impactLabels.directItems');
    els.metricObjectsLabel.textContent = t('impactLabels.downstreamReports');
    return;
  }
  const workspaces = currentWorkspaces();
  const items = workspaces.flatMap(workspace => modeItems(workspace));
  const sources = items.flatMap(item => asList(item.sources)).filter(sourceVisible);
  const objects = sources.flatMap(source => asList(source.objects));
  els.metricWorkspaces.textContent = number(workspaces.length);
  els.metricPrimary.textContent = number(items.length);
  els.metricSources.textContent = number(sources.length);
  els.metricObjects.textContent = number(objects.length);
}

// Only rendered for workspaces that are actually Git-connected (most
// aren't, in a typical tenant) -- "in sync" (green) means Fabric's last
// pull from git happened before or during our last scan of this
// workspace, so nothing should be missing; "stale" (amber) means Fabric
// synced from git more recently than we scanned, so there may be changes
// we haven't captured yet. See scripts/67_discover_workspace_git_
// connections.ps1 for how workspace.git.sync_status is computed.
function gitSyncIndicatorHtml(workspace) {
  const git = workspace.git;
  if (!git || !git.connected) return '';
  const es = state.lang === 'es';
  if (git.sync_status === 'stale') {
    const title = es
      ? `Fabric sincronizó desde git (${git.branch_name || 'main'}) después de nuestro último escaneo -- puede faltar algo por capturar.`
      : `Fabric synced from git (${git.branch_name || 'main'}) after our last scan -- something may be missing.`;
    return `<span class="git-sync-indicator git-sync-stale" title="${escapeHtml(title)}">git ≈</span>`;
  }
  if (git.sync_status === 'synced') {
    const title = es
      ? `Conectado a git (${git.branch_name || 'main'}) -- nuestro último escaneo es igual de reciente o más.`
      : `Connected to git (${git.branch_name || 'main'}) -- our last scan is at least as recent.`;
    return `<span class="git-sync-indicator git-sync-ok" title="${escapeHtml(title)}">git ✓</span>`;
  }
  const title = es ? `Conectado a git (${git.branch_name || 'main'}), sin escanear todavía.` : `Connected to git (${git.branch_name || 'main'}), not scanned yet.`;
  return `<span class="git-sync-indicator git-sync-unknown" title="${escapeHtml(title)}">git ✕</span>`;
}

function gitRepoDisplayValue(git) {
  if (!git || !git.connected) return '';
  const parts = [git.organization_name, git.project_name, git.repository_name].filter(Boolean).join('/');
  const branch = git.branch_name ? ` (${git.branch_name})` : '';
  return parts ? `${parts}${branch}` : '';
}

// Lets a signed-in user tell at a glance whether they're an Admin/Member/
// Contributor/Viewer in each workspace without opening every detail panel.
// Accepts either one workspace or (for a deployment pipeline entry) every
// workspace in it -- mergedRoleAssignmentsForWorkspaces/
// bestRoleAssignmentAcrossWorkspaces then surface the highest-ranked role
// the signed-in user holds across all of them.
function yourRoleBadgeHtml(workspaceOrWorkspaces) {
  const assignment = bestRoleAssignmentAcrossWorkspaces(workspaceOrWorkspaces);
  if (!assignment) return '';
  const label = roleLabel(assignment.role);
  const roleClass = (assignment.role || '').toLowerCase();
  return `<span class="your-role-badge your-role-${escapeHtml(roleClass)}" title="${escapeHtml(i18n[state.lang].detail.yourRole)}: ${escapeHtml(label)}">${escapeHtml(label)}</span>`;
}

function workspaceCardBadgesRowHtml(badgesHtml) {
  return badgesHtml ? `<span class="workspace-card-badges">${badgesHtml}</span>` : '';
}

// Desplegable de búsqueda tipo "filtro de columna de Excel" (2026-07-20):
// con muchos workspaces/deployment pipelines, encontrar uno concreto a base
// de scroll en la lista de tarjetas de abajo es lento. Esto no sustituye
// esa lista (sigue mostrando todo, sin filtrar) -- es un atajo aparte:
// escribes, aparecen coincidencias, marcas la casilla, y eso dispara
// exactamente la misma selección que pulsar la tarjeta a mano
// (applyIndexEntrySelection), así que ambas vistas quedan siempre en
// sincronía sin un segundo modelo de selección que mantener.
function workspaceSearchPanelOpen() {
  return Boolean(els.workspaceSearchPanel && !els.workspaceSearchPanel.hidden);
}

function renderWorkspaceSearchResults() {
  if (!els.workspaceSearchResults) return;
  if (!workspaceSearchPanelOpen()) {
    els.workspaceSearchResults.innerHTML = '';
    return;
  }
  const query = normalize(state.workspaceSearchQuery);
  const entries = currentIndexEntries();
  const matches = query ? entries.filter(entry => normalize(entry.label).includes(query)) : entries;
  if (!matches.length) {
    els.workspaceSearchResults.innerHTML = `<p class="workspace-search-empty">${escapeHtml(t('workspaceSearchNoMatch'))}</p>`;
    return;
  }
  els.workspaceSearchResults.innerHTML = matches.map(entry => {
    const checked = entryIsSelected(entry) ? 'checked' : '';
    return `
      <label class="workspace-search-row">
        <input type="checkbox" data-workspace-search-key="${escapeHtml(entry.key)}" ${checked} />
        <span>${escapeHtml(entry.label)}</span>
      </label>
    `;
  }).join('');
}

function openWorkspaceSearchPanel() {
  if (!els.workspaceSearchPanel || workspaceSearchPanelOpen()) return;
  els.workspaceSearchPanel.hidden = false;
  if (els.workspaceSearchToggle) els.workspaceSearchToggle.setAttribute('aria-expanded', 'true');
  renderWorkspaceSearchResults();
  if (els.workspaceSearchInput) els.workspaceSearchInput.focus();
}

function closeWorkspaceSearchPanel() {
  if (!els.workspaceSearchPanel || !workspaceSearchPanelOpen()) return;
  els.workspaceSearchPanel.hidden = true;
  if (els.workspaceSearchToggle) els.workspaceSearchToggle.setAttribute('aria-expanded', 'false');
}

function toggleWorkspaceSearchPanel() {
  if (workspaceSearchPanelOpen()) closeWorkspaceSearchPanel();
  else openWorkspaceSearchPanel();
}

function renderWorkspaceList() {
  keepValidWorkspaceSelection(false);
  const entries = currentIndexEntries();
  els.workspaceList.innerHTML = '';
  const selectedEntries = entries.filter(entryIsSelected);
  const selectedCount = selectedEntries.length;
  els.workspaceCount.textContent = selectedCount ? `${number(selectedCount)}/${number(entries.length)}` : number(entries.length);
  els.workspacePanelSubtitle.textContent = `${number(selectedCount)} ${t('selected')} · ${number(entries.length)} ${t('available')}`;
  els.selectAllWorkspacesButton.classList.toggle('active', selectedCount > 0 && selectedCount === entries.length);
  if (!entries.length) {
    els.workspaceList.innerHTML = `<div class="empty-state">${t('empty')}</div>`;
    return;
  }
  for (const entry of entries) {
    const button = document.createElement('button');
    const isActive = entryIsSelected(entry);
    const selectionIndex = selectedEntries.findIndex(selected => selected.key === entry.key) + 1;
    const productionEntry = entry.kind === 'deploymentPipeline'
      ? productionWorkspacesForPipeline(entry).length > 0 || (entry.data.stages || []).some(isProductionStage)
      : isProductionWorkspace(entry.data);
    button.className = `workspace-card ${entry.kind === 'deploymentPipeline' ? 'pipeline-entry' : 'standalone-entry'}${productionEntry ? ' production-entry' : ''}${isActive ? ' active' : ''}`;
    button.type = 'button';
    button.setAttribute('aria-pressed', isActive ? 'true' : 'false');
    if (entry.kind === 'deploymentPipeline') {
      const stages = entry.data.stages || [];
      const productionWorkspaces = productionWorkspacesForPipeline(entry);
      const productionModelCount = productionWorkspaces.reduce((sum, workspace) => sum + semanticModelCountForWorkspace(workspace), 0);
      // Badges (role, and eventually anything else per-card) get their own
      // row instead of being appended inline to the title/stats text -- both
      // of those already truncate with an ellipsis at the card's fixed
      // width, which was silently clipping the badge along with them.
      const badgesRow = workspaceCardBadgesRowHtml(yourRoleBadgeHtml(entry.data.local_workspaces));
      button.innerHTML = `
        <span class="ms-icon icon-deployment" aria-hidden="true"></span>
        <span class="workspace-card-copy">
          <strong>${escapeHtml(entry.label)}</strong>
          ${badgesRow}
          <span class="workspace-card-stats">${number(stages.length)} ${t('assignedStages')} · ${number(entry.data.local_workspaces.length)} ${t('indexedWorkspaces')} · ${number(productionModelCount)} ${t('productionModels')}</span>
          <span class="pipeline-stage-rail">${stages.map(stagePillHtml).join('')}</span>
        </span>
        <span class="deployment-status" title="${escapeHtml(t('deploymentPipeline'))}"><i class="ms-icon icon-deployment" aria-hidden="true"></i></span>
        <span class="selection-mark" aria-hidden="true">${isActive ? escapeHtml(selectionIndex) : ''}</span>
      `;
    } else {
      const workspace = entry.data;
      const capacity = workspacePlatformLabel(workspace);
      const badgesRow = workspaceCardBadgesRowHtml(gitSyncIndicatorHtml(workspace) + yourRoleBadgeHtml(workspace));
      button.innerHTML = `
        <span class="ms-icon ${iconClassForWorkspace(workspace)}" aria-hidden="true"></span>
        <span class="workspace-card-copy">
          <strong>${escapeHtml(workspace.name)}</strong>
          ${badgesRow}
          <span>${escapeHtml(truncate(capacity, 42))}</span>
        </span>
        <span class="deployment-status" title="${escapeHtml(t('noDeploymentPipeline'))}"><i class="ms-icon icon-deployment-off" aria-hidden="true"></i></span>
        <span class="selection-mark" aria-hidden="true">${isActive ? escapeHtml(selectionIndex) : ''}</span>
      `;
    }
    button.addEventListener('click', () => {
      applyIndexEntrySelection(entry, true);
      render();
    });
    els.workspaceList.append(button);
  }
  renderWorkspaceSearchResults();
}

// Un renglón por tipo de icono realmente presente en la selección actual
// (no una lista genérica fija) -- p.ej. si sólo hay notebooks seleccionados,
// sólo aparece "Notebook", no también "Pipeline" o "Informe" porque el modo
// los soporte en general. 'cross' (nodo de otro workspace) queda fuera:
// sólo se sabe si aparece recorriendo el árbol ya expandido nodo a nodo,
// no a partir de los items en bruto -- un coste que no compensa para una
// leyenda.
function legendEntriesForSelection() {
  const workspaces = supportsDiagramObjectFilters() ? selectedLineageWorkspaceList() : selectedWorkspaceList();
  const items = workspaces.flatMap(workspace => modeItems(workspace));
  const entries = new Map();

  if (workspaces.length > 1) entries.set('icon-fabric', t('legend.workspace'));
  if (workspaces.some(workspace => workspace.deployment_pipeline && workspace.deployment_pipeline.has_pipeline)) {
    entries.set('icon-deployment', t('legend.deployment'));
  }
  for (const item of items) {
    const iconClass = iconClassForType(item.item_type);
    if (!entries.has(iconClass)) entries.set(iconClass, itemTypeLabel(item.item_type));
  }
  if (items.some(item => asList(item.reports).length > 0)) entries.set('icon-report', t('legend.report'));
  if (items.some(item => asList(item.sources).length > 0)) entries.set('icon-source', t('legend.source'));
  if (items.some(item => asList(item.sources).some(source => asList(source.objects).length > 0))) {
    entries.set('icon-table', t('legend.object'));
  }
  return Array.from(entries, ([iconClass, label]) => ({ iconClass, label }));
}

function renderLegend() {
  // Now always visible (bottom-left of the diagram, not the header -- see
  // 2026-07-19 toolbar cleanup), so it must not fight Planning's own
  // control-flow-color legend (a separate banner already explaining what
  // Planning's edges mean): showing a second, Inspección-flavored icon
  // legend (workspace/deployment/report...) that has nothing to do with
  // Planning's actual node kinds would just be clutter, not help.
  if (state.viewMode === 'planning') {
    els.modeLegend.hidden = true;
    return;
  }
  // Impacto ya tiene su propio índice/resumen de objetos afectados -- este
  // segundo listado de iconos era redundante (2026-07-20).
  if (state.viewMode === 'impact') {
    els.modeLegend.hidden = true;
    return;
  }
  els.modeLegend.hidden = false;
  const legend = legendEntriesForSelection();
  els.modeLegend.innerHTML = legend
    .map(entry => `<span><i class="ms-icon ${entry.iconClass}" aria-hidden="true"></i>${escapeHtml(entry.label)}</span>`)
    .join('');
}

function availableSourceTypes() {
  const sourceTypes = new Set();
  if (state.viewMode === 'impact') {
    for (const object of impactObjectsForScope()) {
      if (object.source_type) sourceTypes.add(object.source_type);
    }
    return Array.from(sourceTypes).sort((a, b) => sourceTypeLabel(a).localeCompare(sourceTypeLabel(b)));
  }
  const selected = supportsDiagramObjectFilters() ? selectedLineageWorkspaceList() : selectedWorkspaceList();
  const items = selected.flatMap(workspace => modeItems(workspace));
  for (const item of items) {
    for (const source of asList(item.sources)) {
      if (source.source_type) sourceTypes.add(source.source_type);
    }
  }
  return Array.from(sourceTypes).sort((a, b) => sourceTypeLabel(a).localeCompare(sourceTypeLabel(b)));
}

function availableItemTypes() {
  const itemTypes = new Set();
  if (state.viewMode === 'impact') {
    for (const object of impactObjectsForScope()) {
      for (const type of object.affected_item_types || []) {
        if (type) itemTypes.add(type);
      }
    }
    return Array.from(itemTypes).sort((a, b) => itemTypeLabel(a).localeCompare(itemTypeLabel(b)));
  }
  const workspaces = currentWorkspacesIgnoringItemType();
  for (const workspace of workspaces) {
    for (const item of rawModeItems(workspace)) {
      if (item.item_type) itemTypes.add(item.item_type);
    }
  }
  return Array.from(itemTypes).sort((a, b) => itemTypeLabel(a).localeCompare(itemTypeLabel(b)));
}

function impactObjectsForCascade({ sourceType = 'all', database = 'all', objectType = 'all' } = {}) {
  return impactObjectsForScope().filter(object => {
    const sourceTypeOk = sourceType === 'all' || object.source_type === sourceType;
    const databaseOk = database === 'all' || impactDatabaseKey(object) === database;
    const objectTypeOk = impactObjectHasType(object, objectType);
    return sourceTypeOk && databaseOk && objectTypeOk;
  });
}

function optionHtml(value, label, count = null) {
  const suffix = count === null ? '' : ` (${number(count)})`;
  return `<option value="${escapeHtml(value)}">${escapeHtml(label + suffix)}</option>`;
}

function clearDiagramObjectSelection(mode = 'all') {
  state.diagramObjectSelectionMode = mode;
  state.diagramSelectedObjectKeys = new Set();
}

function diagramFilterItems() {
  return selectedLineageWorkspaceList().flatMap(workspace => modeItems(workspace));
}

function diagramFilterSources({ sourceType = 'all', store = 'all' } = {}) {
  return diagramFilterItems()
    .flatMap(item => asList(item.sources))
    .filter(source => sourceType === 'all' || source.source_type === sourceType)
    .filter(source => store === 'all' || diagramStoreKey(source) === store);
}

function diagramStoreOptionsForFilter(sourceType = 'all') {
  const sources = diagramFilterSources({ sourceType });
  const nameCounts = new Map();
  for (const source of sources) {
    const name = source.database || source.source_database || source.label || source.server || sourceTypeDisplay(source.source_type) || t('unknown');
    nameCounts.set(name, (nameCounts.get(name) || 0) + 1);
  }
  const duplicates = new Set(Array.from(nameCounts.entries()).filter(([, count]) => count > 1).map(([name]) => name));
  const options = new Map();
  for (const source of sources) {
    const key = diagramStoreKey(source);
    const current = options.get(key) || { key, label: diagramStoreLabel(source, duplicates), count: 0 };
    current.count += Math.max(1, asList(source.objects).length);
    options.set(key, current);
  }
  return Array.from(options.values()).sort((a, b) => a.label.localeCompare(b.label));
}

function diagramObjectTypeOptionsForFilter({ sourceType = 'all', store = 'all' } = {}) {
  const counts = new Map();
  for (const source of diagramFilterSources({ sourceType, store })) {
    for (const object of asList(source.objects)) {
      const type = diagramObjectRawType(object);
      counts.set(type, (counts.get(type) || 0) + 1);
    }
  }
  return Array.from(counts.entries())
    .map(([key, count]) => ({ key, label: objectTypeLabel(key), count }))
    .sort((a, b) => a.label.localeCompare(b.label));
}

function diagramObjectOptionsForFilter({ sourceType = state.filters.sourceType, store = state.filters.diagramStore, objectType = state.filters.diagramObjectType } = {}) {
  const options = new Map();
  for (const source of diagramFilterSources({ sourceType, store })) {
    for (const object of asList(source.objects)) {
      if (objectType !== 'all' && diagramObjectRawType(object) !== objectType) continue;
      const key = diagramObjectKey(source, object);
      const current = options.get(key) || {
        key,
        label: diagramObjectLabel(object, source),
        meta: diagramObjectMeta(source, object),
        count: 0
      };
      current.count += 1;
      options.set(key, current);
    }
  }
  return Array.from(options.values()).sort((a, b) =>
    a.label.localeCompare(b.label) || a.meta.localeCompare(b.meta)
  );
}

function reconcileDiagramObjectSelection(options) {
  if (state.diagramObjectSelectionMode !== 'custom') return;
  const valid = new Set(options.map(option => option.key));
  state.diagramSelectedObjectKeys = new Set(Array.from(state.diagramSelectedObjectKeys).filter(key => valid.has(key)));
  if (!state.diagramSelectedObjectKeys.size) state.diagramObjectSelectionMode = 'none';
}

function renderDiagramObjectChecklist(options) {
  if (!els.diagramObjectChecklist) return;
  if (!supportsDiagramObjectFilters()) {
    els.diagramObjectChecklist.hidden = true;
    els.diagramObjectChecklist.innerHTML = '';
    return;
  }
  els.diagramObjectChecklist.hidden = false;
  if (els.filterMenu.hidden) {
    els.diagramObjectChecklist.innerHTML = '';
    return;
  }
  const optionCount = options.length;
  const selectedCount = state.diagramObjectSelectionMode === 'all'
    ? optionCount
    : state.diagramObjectSelectionMode === 'none'
      ? 0
      : state.diagramSelectedObjectKeys.size;
  const checkedAll = state.diagramObjectSelectionMode === 'all';
  const rows = options.map(option => {
    const checked = state.diagramObjectSelectionMode === 'all' ||
      (state.diagramObjectSelectionMode === 'custom' && state.diagramSelectedObjectKeys.has(option.key));
    const count = option.count > 1 ? ` (${number(option.count)})` : '';
    return `
      <label class="diagram-object-check" title="${escapeHtml([option.label, option.meta].filter(Boolean).join(' · '))}">
        <input type="checkbox" data-diagram-object-key="${escapeHtml(option.key)}" ${checked ? 'checked' : ''} />
        <span>
          <strong>${escapeHtml(option.label)}</strong>
          <em>${escapeHtml(option.meta + count)}</em>
        </span>
      </label>
    `;
  }).join('');
  els.diagramObjectChecklist.innerHTML = `
    <div class="diagram-object-checklist-head">
      <label class="diagram-object-check select-all">
        <input type="checkbox" data-diagram-object-all="true" ${checkedAll ? 'checked' : ''} />
        <span>
          <strong>${escapeHtml(t('diagramFilterLabels.selectAllObjects'))}</strong>
          <em>${number(selectedCount)} / ${number(optionCount)} ${escapeHtml(t('diagramFilterLabels.availableObjects'))}</em>
        </span>
      </label>
    </div>
    <div class="diagram-object-checklist-body">
      ${rows || `<div class="diagram-object-empty">${escapeHtml(t('diagramFilterLabels.noObjects'))}</div>`}
    </div>
    <p>${escapeHtml(t('diagramFilterLabels.listHint'))}</p>
  `;
}

function populateImpactFilters() {
  const confidenceFilterRow = els.confidenceFilter ? els.confidenceFilter.closest('label') : null;
  if (confidenceFilterRow) confidenceFilterRow.hidden = false;
  if (els.diagramObjectChecklist) {
    els.diagramObjectChecklist.hidden = true;
    els.diagramObjectChecklist.innerHTML = '';
  }
  const objectCombo = els.impactObjectSearch ? els.impactObjectSearch.closest('.object-filter-combo') : null;
  if (objectCombo) objectCombo.hidden = false;
  els.sourceFilterLabel.textContent = t('impactLabels.sourceTypeFilter');
  els.confidenceFilterLabel.textContent = t('impactLabels.dataStoreFilter');
  els.itemTypeFilterLabel.textContent = t('impactLabels.objectTypeFilter');
  els.objectFilterLabel.textContent = t('impactLabels.objectFilter');
  els.objectFilterRow.hidden = false;

  const scopedObjects = impactObjectsForScope();
  const sourceCounts = new Map();
  for (const object of scopedObjects) {
    const key = object.source_type || t('unknown');
    sourceCounts.set(key, (sourceCounts.get(key) || 0) + 1);
  }
  const sourceTypes = Array.from(sourceCounts.keys()).sort((a, b) => a.localeCompare(b));
  if (state.filters.sourceType !== 'all' && !sourceCounts.has(state.filters.sourceType)) {
    state.filters.sourceType = 'all';
    state.filters.impactDatabase = 'all';
    state.filters.impactObjectType = 'all';
    state.filters.impactObjectKey = 'all';
  }
  els.sourceTypeFilter.innerHTML = [
    optionHtml('all', t('all'), scopedObjects.length),
    ...sourceTypes.map(type => optionHtml(type, sourceTypeLabel(type), sourceCounts.get(type)))
  ].join('');
  els.sourceTypeFilter.value = state.filters.sourceType;

  const databaseObjects = impactObjectsForCascade({ sourceType: state.filters.sourceType });
  const nameCounts = new Map();
  for (const object of databaseObjects) {
    const name = object.source_database || object.source_server || sourceTypeDisplay(object.source_type) || t('unknown');
    nameCounts.set(name, (nameCounts.get(name) || 0) + 1);
  }
  const duplicateNames = new Set(Array.from(nameCounts.entries()).filter(([, count]) => count > 1).map(([name]) => name));
  const databaseOptions = new Map();
  for (const object of databaseObjects) {
    const key = impactDatabaseKey(object);
    const current = databaseOptions.get(key) || { label: impactDatabaseLabel(object, duplicateNames), count: 0 };
    current.count += 1;
    databaseOptions.set(key, current);
  }
  if (state.filters.impactDatabase !== 'all' && !databaseOptions.has(state.filters.impactDatabase)) {
    state.filters.impactDatabase = 'all';
    state.filters.impactObjectType = 'all';
    state.filters.impactObjectKey = 'all';
  }
  const sortedDatabases = Array.from(databaseOptions.entries()).sort((a, b) => a[1].label.localeCompare(b[1].label));
  els.confidenceFilter.innerHTML = [
    optionHtml('all', t('all'), databaseObjects.length),
    ...sortedDatabases.map(([key, entry]) => optionHtml(key, entry.label, entry.count))
  ].join('');
  els.confidenceFilter.value = state.filters.impactDatabase;

  const typeObjects = impactObjectsForCascade({
    sourceType: state.filters.sourceType,
    database: state.filters.impactDatabase
  });
  const typeCounts = new Map();
  for (const object of typeObjects) {
    for (const type of impactObjectTypeTokens(object)) {
      typeCounts.set(type, (typeCounts.get(type) || 0) + 1);
    }
  }
  if (state.filters.impactObjectType !== 'all' && !typeCounts.has(state.filters.impactObjectType)) {
    state.filters.impactObjectType = 'all';
    state.filters.impactObjectKey = 'all';
  }
  const sortedTypes = Array.from(typeCounts.keys()).sort((a, b) => objectTypeLabel(a).localeCompare(objectTypeLabel(b)));
  els.itemTypeFilter.innerHTML = [
    optionHtml('all', t('all'), typeObjects.length),
    ...sortedTypes.map(type => optionHtml(type, objectTypeLabel(type), typeCounts.get(type)))
  ].join('');
  els.itemTypeFilter.value = state.filters.impactObjectType;

  const objectOptions = impactObjectsForCascade({
    sourceType: state.filters.sourceType,
    database: state.filters.impactDatabase,
    objectType: state.filters.impactObjectType
  });
  const objectKeys = new Set(objectOptions.map(object => object.object_key));
  state.impactSelectedObjectKeys = new Set(Array.from(state.impactSelectedObjectKeys).filter(key => objectKeys.has(key)));
  if (state.filters.impactObjectKey !== 'all' && !objectKeys.has(state.filters.impactObjectKey)) {
    state.filters.impactObjectKey = 'all';
    state.impactObjectSearch = '';
  }
  els.objectFilter.innerHTML = [
    optionHtml('all', t('all'), objectOptions.length)
  ].join('');
  els.objectFilter.value = state.filters.impactObjectKey;
  if (els.impactObjectOptions) {
    els.impactObjectOptions.innerHTML = '';
  }
  if (els.impactObjectSearch) {
    els.impactObjectSearch.value = state.impactObjectSearch;
    els.impactObjectSearch.placeholder = t('impactLabels.objectSearchPlaceholder');
    els.impactObjectSearch.disabled = objectOptions.length === 0;
  }
  if (els.impactObjectClear) {
    els.impactObjectClear.textContent = t('impactLabels.clearObject');
    els.impactObjectClear.hidden = !state.impactObjectSearch && state.filters.impactObjectKey === 'all' && !state.impactSelectedObjectKeys.size;
  }
}

// Planificación no tiene "tipo de item"/objetos individuales como Inspección
// o Impacto -- cada fila ya es un origen (base de datos/lakehouse) que
// alimenta uno o más modelos, así que reutiliza sólo el desplegable de
// Origen (sourceType) y añade su propio buscador+chips en
// #planningFilterSources, en vez de forzar el resto de controles a encajar
// en una forma que no les corresponde.
function populatePlanningFilters() {
  const confidenceFilterRow = els.confidenceFilter ? els.confidenceFilter.closest('label') : null;
  if (confidenceFilterRow) confidenceFilterRow.hidden = true;
  const itemTypeFilterRow = els.itemTypeFilter ? els.itemTypeFilter.closest('label') : null;
  if (itemTypeFilterRow) itemTypeFilterRow.hidden = true;
  const objectCombo = els.impactObjectSearch ? els.impactObjectSearch.closest('.object-filter-combo') : null;
  if (objectCombo) objectCombo.hidden = true;
  if (els.diagramObjectChecklist) {
    els.diagramObjectChecklist.hidden = true;
    els.diagramObjectChecklist.innerHTML = '';
  }
  state.filters.confidence = 'all';
  els.objectFilterRow.hidden = true;
  els.sourceFilterLabel.textContent = t('diagramFilterLabels.sourceType');

  const selected = selectedWorkspaceListForPlanning();
  const scope = planningScopeWorkspaces(selected);
  const readiness = buildPlanningReadiness(scope);

  const sourceTypeCounts = new Map();
  for (const row of readiness.rows) {
    const sourceTypeKey = (row.source && row.source.source_type) || t('unknown');
    sourceTypeCounts.set(sourceTypeKey, (sourceTypeCounts.get(sourceTypeKey) || 0) + 1);
  }
  if (state.filters.sourceType !== 'all' && !sourceTypeCounts.has(state.filters.sourceType)) {
    state.filters.sourceType = 'all';
  }
  const sortedSourceTypes = Array.from(sourceTypeCounts.keys()).sort((a, b) => sourceTypeLabel(a).localeCompare(sourceTypeLabel(b)));
  els.sourceTypeFilter.innerHTML = [
    optionHtml('all', t('all'), readiness.rows.length),
    ...sortedSourceTypes.map(type => optionHtml(type, sourceTypeLabel(type), sourceTypeCounts.get(type)))
  ].join('');
  els.sourceTypeFilter.value = state.filters.sourceType;

  renderPlanningFilterSources(readiness);
}

function populateFilters() {
  if (els.filterMenu.hidden) {
    if (els.diagramObjectChecklist) {
      els.diagramObjectChecklist.hidden = true;
      els.diagramObjectChecklist.innerHTML = '';
    }
    if (els.planningFilterSources) els.planningFilterSources.hidden = true;
    return;
  }
  if (els.planningFilterSources) els.planningFilterSources.hidden = state.viewMode !== 'planning';
  if (state.viewMode === 'impact') {
    populateImpactFilters();
    return;
  }
  if (state.viewMode === 'planning') {
    populatePlanningFilters();
    return;
  }
  const confidenceFilterRow = els.confidenceFilter ? els.confidenceFilter.closest('label') : null;
  const objectCombo = els.impactObjectSearch ? els.impactObjectSearch.closest('.object-filter-combo') : null;
  const useObjectFilters = supportsDiagramObjectFilters();
  if (confidenceFilterRow) confidenceFilterRow.hidden = !useObjectFilters;
  if (objectCombo) objectCombo.hidden = useObjectFilters;
  state.filters.confidence = 'all';
  els.objectFilterRow.hidden = !useObjectFilters;
  els.sourceFilterLabel.textContent = useObjectFilters ? t('diagramFilterLabels.sourceType') : t('source');
  els.confidenceFilterLabel.textContent = t('diagramFilterLabels.dataStore');
  els.itemTypeFilterLabel.textContent = useObjectFilters ? t('diagramFilterLabels.objectType') : t('itemType');
  els.objectFilterLabel.textContent = t('diagramFilterLabels.objects');

  const sourceTypes = ['all', ...availableSourceTypes()];
  if (!sourceTypes.includes(state.filters.sourceType)) state.filters.sourceType = 'all';
  els.sourceTypeFilter.innerHTML = sourceTypes
    .map(type => optionHtml(type, type === 'all' ? t('all') : sourceTypeLabel(type)))
    .join('');
  els.sourceTypeFilter.value = state.filters.sourceType;

  if (useObjectFilters) {
    const storeOptions = diagramStoreOptionsForFilter(state.filters.sourceType);
    const validStores = new Set(storeOptions.map(option => option.key));
    if (state.filters.diagramStore !== 'all' && !validStores.has(state.filters.diagramStore)) {
      state.filters.diagramStore = 'all';
      clearDiagramObjectSelection('all');
    }
    els.confidenceFilter.innerHTML = [
      optionHtml('all', t('all'), storeOptions.reduce((sum, option) => sum + option.count, 0)),
      ...storeOptions.map(option => optionHtml(option.key, option.label, option.count))
    ].join('');
    els.confidenceFilter.value = state.filters.diagramStore;
  } else {
    els.confidenceFilter.innerHTML = optionHtml('all', t('all'));
    els.confidenceFilter.value = state.filters.confidence;
    if (els.diagramObjectChecklist) {
      els.diagramObjectChecklist.hidden = true;
      els.diagramObjectChecklist.innerHTML = '';
    }
  }

  if (useObjectFilters) {
    const objectTypes = diagramObjectTypeOptionsForFilter({
      sourceType: state.filters.sourceType,
      store: state.filters.diagramStore
    });
    const validObjectTypes = new Set(objectTypes.map(option => option.key));
    if (state.filters.diagramObjectType !== 'all' && !validObjectTypes.has(state.filters.diagramObjectType)) {
      state.filters.diagramObjectType = 'all';
      clearDiagramObjectSelection('all');
    }
    els.itemTypeFilter.innerHTML = [
      optionHtml('all', t('all'), objectTypes.reduce((sum, option) => sum + option.count, 0)),
      ...objectTypes.map(option => optionHtml(option.key, option.label, option.count))
    ].join('');
    els.itemTypeFilter.value = state.filters.diagramObjectType;
    const objectOptions = diagramObjectOptionsForFilter();
    reconcileDiagramObjectSelection(objectOptions);
    renderDiagramObjectChecklist(objectOptions);
  } else {
    const availableTypes = availableItemTypes();
    const itemTypes = ['all', ...availableTypes];
    if (state.filters.itemType !== 'all' && !availableTypes.includes(state.filters.itemType)) {
      itemTypes.push(state.filters.itemType);
    }
    els.itemTypeFilter.innerHTML = itemTypes
      .map(type => `<option value="${escapeHtml(type)}">${escapeHtml(type === 'all' ? t('all') : itemTypeLabel(type))}</option>`)
      .join('');
    els.itemTypeFilter.value = state.filters.itemType;
  }
}

function kindForItem(item, fallback = 'item') {
  if (!item || !item.item_type) return fallback;
  if (item.item_type === 'DataPipeline') return 'pipeline';
  if (['Report', 'PaginatedReport', 'Dashboard', 'KQLDashboard'].includes(item.item_type)) return 'report';
  return fallback;
}

function lineageChildCount(data) {
  if (!data) return 0;
  return asList(data.reports).length +
    asList(data.models).length +
    asList(data.executes).length +
    asList(data.sources).length;
}

function nodeHasLimitedLineage(node) {
  if (!node || !['item', 'pipeline', 'report', 'execute'].includes(node.kind)) return false;
  return lineageChildCount(node.data || {}) === 0;
}

function nodeHasLowEvidence(node) {
  return false;
}

function lineageQualityLabel(node) {
  if (nodeHasLimitedLineage(node)) return t('limitedLineage');
  if (nodeHasLowEvidence(node)) return t('lowEvidence');
  return '';
}

function badgeForNode(node) {
  if (node.kind === 'workspace') return '';
  if (node.kind === 'deploymentPipeline') return `${node.data.stage_count || (node.data.stages || []).length} ${t('deploymentStage')}`;
  if (node.kind === 'deploymentStage') return node.data.local_workspace_name ? (node.data.stage_order || t('deploymentStage')) : t('unassignedStage');
  if (node.shared_count > 1) return `${node.shared_count} ${t('uses')}`;
  if (isCrossWorkspaceNode(node)) return t('otherWorkspaceShort');
  if (node.kind === 'group') return asList(node.data.nodes || node.data.items).length;
  if (nodeHasLimitedLineage(node)) return t('limitedLineageShort');
  return (node.data && itemTypeLabel(node.data.item_type)) || node.kind;
}

function nodeSubtext(node) {
  const data = node.data || {};
  const workspaceText = isCrossWorkspaceNode(node) ? ` · ${t('fromWorkspace')} ${nodeWorkspaceName(node)}` : '';
  const sharedText = node.shared_count > 1 ? ` · ${node.shared_count} ${t('uses')}` : '';
  if (node.kind === 'deploymentPipeline') {
    const stageCount = (data.stages || []).length || data.stage_count || 0;
    const workspaceCount = (data.local_workspaces || []).length || data.indexed_workspace_count || 0;
    return `${number(stageCount)} ${t('assignedStages')} · ${number(workspaceCount)} ${t('indexedWorkspaces')}`;
  }
  if (node.kind === 'deploymentStage') {
    return data.local_workspace_name
      ? `${t('detail.stageWorkspace')} · ${data.local_workspace_name}`
      : `${data.workspace_name || ''} · ${t('unassignedStage')}`;
  }
  if (node.kind === 'workspace') {
    const activeTreeLabel = state.filters.itemType === 'all' ? t(`mode.${state.mode}`) : itemTypeLabel(state.filters.itemType);
    return `${data.environment || ''} · ${workspacePlatformLabel(data)} · ${modeCount(data)} ${activeTreeLabel}`;
  }
  if (node.kind === 'item') return `${itemTypeLabel(data.item_type)} · ${data.sources ? data.sources.filter(sourceVisible).length : 0} ${t('sources')}${workspaceText}${sharedText}`;
  if (node.kind === 'report') return `${itemTypeLabel(data.item_type) || t('legend.report')} · ${data.models ? data.models.length : 0} ${t('groups.models')}${workspaceText}${sharedText}`;
  if (node.kind === 'group') {
    const count = asList(data.nodes || data.items).length;
    return data.lineage_group_label ? `${number(count)} ${t('elements')}` : '';
  }
  if (node.kind === 'source') {
    const usageText = data.lineage_usage_label ? `${data.lineage_usage_label} · ` : '';
    const objectCount = Number(data.lineage_object_count || 0) > 0 ? ` · ${number(data.lineage_object_count)} ${t('objects').toLowerCase()}` : '';
    return `${usageText}${sourceTypeLabel(data.source_type)}${data.database ? ` · ${data.database}` : ''}${objectCount}${workspaceText}${sharedText}`;
  }
  if (node.kind === 'object') {
    const usageText = data.lineage_usage_label ? `${data.lineage_usage_label} · ` : '';
    return `${usageText}${objectTypeLabel(data.type) || ''}${data.source_label ? ` · ${data.source_label}` : ''}${workspaceText}${sharedText}`;
  }
  if (node.kind === 'execute') return `${itemTypeLabel(data.item_type) || ''}${workspaceText}${sharedText}`;
  return '';
}

function childrenForNode(node) {
  const data = node.data || {};
  if (node.kind === 'deploymentPipeline') {
    return (data.stages || [])
      .slice()
      .sort((a, b) => Number(a.stage_order || 999) - Number(b.stage_order || 999))
      .map((stage, index) => ({
        id: `${node.id}:stage:${stage.stage_id || index}`,
        kind: 'deploymentStage',
        label: stage.stage_name || `${t('deploymentStage')} ${index + 1}`,
        data: {
          ...stage,
          deployment_pipeline_id: data.deployment_pipeline_id,
          deployment_pipeline_name: data.deployment_pipeline_name
        }
      }));
  }
  if (node.kind === 'deploymentStage') {
    const workspace = data.workspace || (data.local_workspace_name ? workspaceMapByName(currentWorkspaces()).get(data.local_workspace_name) : null);
    return workspace ? [{
      id: `${node.id}:workspace:${workspace.name}`,
      original_id: `workspace:${workspace.name}`,
      kind: 'workspace',
      label: workspace.name,
      data: workspace
    }] : [];
  }
  if (node.kind === 'workspace') {
    return modeItems(data).map((item, index) => ({
      id: `${node.id}:item:${item.qualified_name || index}`,
      kind: kindForItem(item, state.mode === 'pipelines' ? 'pipeline' : 'item'),
      label: item.label,
      data: item
    }));
  }
  if (node.kind === 'item' || node.kind === 'pipeline' || node.kind === 'report' || node.kind === 'execute') {
    const children = [];
    // processLineageGroupsForItem is the single source of truth for "where
    // does this item's data come from" now, for every item kind: it
    // decides on its own, from the actual read/write/execute/reference
    // roles present, whether to show one merged origin group or split them
    // out -- no item-type branching left here. Listed first (before
    // reports/executes below) so the path toward the real source
    // (database/lakehouse/etc.) is always what's immediately in front of the
    // user drilling down, not buried under "who else uses this."
    const originGroups = processLineageGroupsForItem(node);
    if (originGroups) children.push(...originGroups);
    // Skip re-showing "which reports use this model" when we only reached
    // this model by tracing a report's own origin path -- see
    // reached_via_lineage_path in processLineageGroupsForItem. Expanding
    // further from here should always continue toward the real source,
    // never loop back toward reports.
    if (data.reports && data.reports.length && !data.reached_via_lineage_path) {
      children.push({ id: `${node.id}:reports`, kind: 'group', group: 'reports', label: t('groups.reports'), data: { items: data.reports, kind: 'report' } });
    }
    if (data.executes && data.executes.length) {
      children.push({ id: `${node.id}:executes`, kind: 'group', group: 'executes', label: t('groups.executes'), data: { items: data.executes, kind: 'execute' } });
    }
    return children;
  }
  if (node.kind === 'group') {
    if (Array.isArray(node.data.nodes)) return node.data.nodes;
    return asList(node.data.items).map((child, index) => ({
      id: `${node.id}:${node.data.kind}:${index}`,
      kind: node.data.kind === 'item' ? kindForItem(child, 'item') : node.data.kind,
      label: child.label,
      data: child
    }));
  }
  if (node.kind === 'source') {
    return visibleObjectsForSource(data).map((object, index) => ({
      id: `${node.id}:object:${index}`,
      kind: 'object',
      label: object.label,
      data: {
        ...object,
        workspace_name: object.workspace_name || data.workspace_name,
        source_workspace_name: data.workspace_name,
        source_label: data.label,
        source_type: object.source_type || data.source_type
      }
    }));
  }
  return [];
}

function nodeClass(kind) {
  if (kind === 'deploymentPipeline') return 'deployment-pipeline';
  if (kind === 'deploymentStage') return 'deployment-stage';
  if (kind === 'workspace') return 'workspace';
  if (kind === 'source') return 'source';
  if (kind === 'object') return 'object';
  if (kind === 'report') return 'report';
  if (kind === 'pipeline') return 'pipeline';
  if (kind === 'group') return 'group';
  return 'item';
}

function nodeTypeClassFromIcon(iconClass) {
  return {
    'icon-lakehouse': 'type-lakehouse',
    'icon-warehouse': 'type-warehouse',
    'icon-sql': 'type-sql',
    'icon-sharepoint': 'type-sharepoint',
    'icon-file': 'type-file',
    'icon-table': 'type-table',
    'icon-view': 'type-view',
    'icon-procedure': 'type-procedure',
    'icon-databases': 'type-databases',
    'icon-onelake': 'type-lakehouse'
  }[iconClass] || '';
}

function sourceNodeTypeClass(data) {
  return nodeTypeClassFromIcon(iconClassForSourceData(data)) || 'type-source';
}

function objectNodeTypeClass(data) {
  return nodeTypeClassFromIcon(iconClassForObjectData(data)) || 'type-object';
}

function nodeTypeClass(node) {
  const data = node.data || {};
  if (node.kind === 'deploymentPipeline') return 'type-deployment-pipeline';
  if (node.kind === 'deploymentStage') return 'type-deployment-stage';
  if (node.kind === 'group' && data.lineage_group === 'read') return 'type-read-source';
  if (node.kind === 'group' && data.lineage_group === 'write') return 'type-write-target';
  if (node.kind === 'group' && data.lineage_group === 'execute') return 'type-execute-object';
  if (node.kind === 'group' && data.lineage_group === 'reference') return 'type-reference-source';
  if (node.kind === 'source') return sourceNodeTypeClass(data);
  if (node.kind === 'object') return objectNodeTypeClass(data);
  const signature = normalize(`${node.kind} ${data.item_type || ''} ${data.source_type || ''} ${data.type || ''}`);
  if (signature.includes('semantic')) return 'type-semantic';
  if (signature.includes('report')) return 'type-report';
  if (signature.includes('notebook')) return 'type-notebook';
  if (signature.includes('copy')) return 'type-copyjob';
  if (signature.includes('pipeline')) return 'type-pipeline';
  if (signature.includes('lakehouse')) return 'type-lakehouse';
  if (signature.includes('warehouse')) return 'type-warehouse';
  if (signature.includes('sql')) return 'type-sql';
  if (signature.includes('sharepoint')) return 'type-sharepoint';
  if (signature.includes('stored') || signature.includes('procedure') || signature.endsWith(' sp')) return 'type-procedure';
  if (signature.includes('view')) return 'type-view';
  if (signature.includes('table')) return 'type-table';
  return `type-${nodeClass(node.kind)}`;
}

function createTreeNode(node) {
  const children = childrenForNode(node);
  const hasChildren = children.length > 0;
  const isOpen = state.expanded.has(node.id);
  const wrapper = document.createElement('div');
  wrapper.className = 'tree-node';

  const card = document.createElement('button');
  const selectedClass = state.selectedNode && state.selectedNode.id === node.id ? ' selected' : '';
  const crossClass = isCrossWorkspaceNode(node) ? ' cross-workspace' : '';
  const lowEvidenceClass = '';
  const limitedLineageClass = nodeHasLimitedLineage(node) ? ' limited-lineage' : '';
  card.className = `node-card ${nodeClass(node.kind)}${selectedClass}${crossClass}${lowEvidenceClass}${limitedLineageClass}`;
  card.type = 'button';
  const toggle = hasChildren ? (isOpen ? '-' : '+') : '';
  const badge = badgeForNode(node);
  card.innerHTML = `
    <span class="ms-icon ${iconClassForNode(node)}" aria-hidden="true"></span>
    <span class="node-toggle">${escapeHtml(toggle)}</span>
    <span class="node-main"><strong>${escapeHtml(truncate(node.label, 76))}</strong><span>${escapeHtml(truncate(nodeSubtext(node), 96))}</span></span>
    <span class="node-badge">${escapeHtml(truncate(badge, 16))}</span>
  `;
  card.addEventListener('click', event => {
    event.stopPropagation();
    if (hasChildren) {
      if (state.expanded.has(node.id)) state.expanded.delete(node.id);
      else state.expanded.add(node.id);
    }
    selectNode(node);
  });
  wrapper.append(card);

  if (hasChildren && isOpen) {
    const childWrap = document.createElement('div');
    childWrap.className = 'tree-children';
    children.forEach(child => childWrap.append(createTreeNode(child)));
    wrapper.append(childWrap);
  }
  return wrapper;
}

function sourceKey(source) {
  return [
    source.lineage_usage_role,
    source.source_type,
    source.workspace_name,
    source.server,
    source.database,
    source.label,
    source.qualified_name
  ].map(value => normalize(value)).join('|');
}

function objectKey(object) {
  return [
    object.lineage_usage_role,
    object.usage_type,
    object.source_workspace_name,
    object.source_label,
    object.source_qualified_name,
    object.server,
    object.database,
    object.type,
    object.schema,
    object.object_name,
    object.label
  ].map(value => normalize(value)).join('|');
}

function fabricItemKey(item) {
  return [
    item.workspace_name,
    item.item_type,
    item.qualified_name || item.label
  ].map(value => normalize(value)).join('|');
}

function isShareableFabricChild(parent, child) {
  return parent.kind === 'group' && ['item', 'pipeline', 'report', 'execute'].includes(child.kind);
}

function estimateTextWidth(value, charWidth = 7.2) {
  return Math.ceil(text(value).length * charWidth);
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function flowNodeWidth(node) {
  const compactRoot = node.kind === 'workspace' || node.kind === 'deploymentPipeline' || node.kind === 'deploymentStage';
  const labelWidth = estimateTextWidth(node.label, compactRoot ? 6.7 : 7.4);
  const subtextWidth = estimateTextWidth(nodeSubtext(node), 5.8);
  const badgeWidth = node.kind === 'workspace' ? 0 : estimateTextWidth(badgeForNode(node), 6.4);
  const chrome = node.kind === 'workspace' ? 78 : 112 + badgeWidth;
  if (node.kind === 'deploymentPipeline') return clamp(Math.max(labelWidth, subtextWidth) + chrome, 230, 520);
  if (node.kind === 'deploymentStage') return clamp(Math.max(labelWidth, subtextWidth) + chrome, 210, 440);
  if (node.kind === 'workspace') return clamp(Math.max(labelWidth, subtextWidth) + chrome, 190, 420);
  if (node.kind === 'group') return clamp(labelWidth + 104, 176, 300);
  if (node.kind === 'source') return clamp(Math.max(labelWidth, subtextWidth) + chrome, 260, 430);
  if (node.kind === 'object') return clamp(Math.max(labelWidth, subtextWidth) + chrome, 240, 390);
  if (node.kind === 'report') return clamp(Math.max(labelWidth, subtextWidth) + chrome, 230, 430);
  return clamp(Math.max(labelWidth, subtextWidth) + chrome, 230, 460);
}

function estimatedWrappedLines(value, width, charWidth = 7.2) {
  const textValue = text(value);
  if (!textValue) return 1;
  const usableWidth = Math.max(80, width - 110);
  const roughLines = Math.ceil(estimateTextWidth(textValue, charWidth) / usableWidth);
  const hardBreakLines = textValue.split(/[\s/\\._-]+/).some(part => part.length > 42) ? 1 : 0;
  return clamp(roughLines + hardBreakLines, 1, 6);
}

function flowNodeHeight(node) {
  if (node.kind === 'deploymentPipeline' || node.kind === 'deploymentStage') return 44;
  if (node.kind === 'workspace') return 38;
  if (node.kind === 'group') return 44;
  const width = flowNodeWidth(node);
  const labelLines = estimatedWrappedLines(node.label, width, 7.4);
  const subtextLines = estimatedWrappedLines(nodeSubtext(node), width, 5.8);
  const base = node.kind === 'object' ? 42 : 46;
  const extra = Math.max(0, labelLines - 1) * 16 + Math.max(0, subtextLines - 1) * 13;
  if (node.kind === 'source') return clamp(base + extra + 18, 64, 182);
  if (node.kind === 'object') return clamp(base + extra + 16, 56, 170);
  if (node.kind === 'report') return clamp(base + extra + 6, 54, 150);
  return clamp(base + extra + 6, 54, 160);
}

function createFlowCard(node, x, y) {
  const children = childrenForNode(node);
  const hasChildren = children.length > 0;
  const isOpen = state.expanded.has(node.id) || Boolean(node.original_id && state.expanded.has(node.original_id));
  const card = document.createElement('button');
  const selectedClass = state.selectedNode && state.selectedNode.id === node.id ? ' selected' : '';
  const crossClass = isCrossWorkspaceNode(node) ? ' cross-workspace' : '';
  const sharedClass = node.shared_count > 1 ? ' shared-node' : '';
  const rootClass = node.kind === 'workspace' ? ' workspace-root' : (node.kind === 'deploymentPipeline' ? ' deployment-root' : '');
  const lowEvidenceClass = '';
  const limitedLineageClass = nodeHasLimitedLineage(node) ? ' limited-lineage' : '';
  card.className = `node-card flow-card ${nodeClass(node.kind)} ${nodeTypeClass(node)}${rootClass}${selectedClass}${crossClass}${sharedClass}${lowEvidenceClass}${limitedLineageClass}`;
  card.type = 'button';
  card.dataset.nodeId = node.id;
  card.style.left = `${x}px`;
  card.style.top = `${y}px`;
  card.style.width = `${flowNodeWidth(node)}px`;
  card.style.minHeight = `${flowNodeHeight(node)}px`;
  const toggle = hasChildren ? (isOpen ? '-' : '+') : '';
  const badge = badgeForNode(node);
  card.innerHTML = `
    <span class="ms-icon ${iconClassForNode(node)}" aria-hidden="true"></span>
    <span class="node-toggle">${escapeHtml(toggle)}</span>
    <span class="node-main"><strong>${escapeHtml(node.label)}</strong><span>${escapeHtml(nodeSubtext(node))}</span></span>
    <span class="node-badge">${escapeHtml(truncate(badge, 14))}</span>
  `;
  card.setAttribute('aria-label', [node.label, nodeSubtext(node)].filter(Boolean).join(', '));
  if (hasChildren) card.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
  card.addEventListener('click', event => {
    event.stopPropagation();
    if (hasChildren) {
      if (state.expanded.has(node.id)) state.expanded.delete(node.id);
      else state.expanded.add(node.id);
    }
    selectNode(node);
  });
  return card;
}

function semanticSelectedModels() {
  return selectedLineageWorkspaceList()
    .flatMap(workspace =>
      modeItems(workspace)
        .filter(item => item.item_type === 'SemanticModel')
        .map(model => ({ workspace, model }))
    );
}

function semanticPipelineBadges(workspace, model) {
  const deployment = workspace.deployment_pipeline || {};
  const badges = [];
  if (deployment.has_pipeline && deployment.deployment_pipeline_name) {
    badges.push(`${t('semanticFlow.pipeline')}: ${deployment.deployment_pipeline_name}`);
  }
  if (deployment.stage_name) {
    badges.push(`${t('semanticFlow.stage')}: ${deployment.stage_name}`);
  }
  if (normalize(deployment.stage_name).includes('production') || workspace.environment === 'PRO') {
    badges.push(t('semanticFlow.production'));
  }
  const execution = model.execution || {};
  if (execution.latest_status) badges.push(`${t('semanticFlow.refresh')}: ${refreshStatusLabel(execution.latest_status)}`);
  else if (Number(execution.disabled_schedules || 0) > 0) badges.push(t('semanticFlow.disabledSchedule'));
  return badges;
}

function semanticModelObjects(model) {
  return asList(model.sources).flatMap(source => {
    const sourceTitle = planningSourceReadableLabel(source);
    const sourceMeta = planningSourceReadableMeta(source, sourceTitle);
    return asList(source.objects).map(object => ({
      ...object,
      source_label: object.source_label || source.label,
      source_workspace_name: object.source_workspace_name || source.workspace_name,
      source_type: object.source_type || source.source_type,
      database: object.database || source.database,
      server: object.server || source.server,
      __source_title: sourceTitle,
      __source_meta: sourceMeta
    }));
  });
}

function semanticModelTableGroups(model) {
  const d = i18n[state.lang].detail;
  const groups = new Map();
  for (const object of uniqueBy(semanticModelObjects(model), candidate => objectKey(candidate))) {
    const table = object.semantic_table || d.noSemanticTable;
    if (!groups.has(table)) groups.set(table, []);
    groups.get(table).push(object);
  }
  return Array.from(groups.entries())
    .map(([table, objects]) => ({ table, objects }))
    .sort((a, b) => b.objects.length - a.objects.length || a.table.localeCompare(b.table));
}

function semanticModelFootprint(model) {
  const groups = semanticModelTableGroups(model);
  return {
    tableCount: groups.length,
    objectCount: groups.reduce((sum, group) => sum + group.objects.length, 0)
  };
}

function detailSemanticTableRows(model, limit = 28) {
  const d = i18n[state.lang].detail;
  const groups = semanticModelTableGroups(model);
  const visible = groups.slice(0, limit);
  const rows = visible.map(group => {
    const sourceNames = uniqueBy(group.objects, object => `${object.__source_title}|${object.database}|${object.server}`)
      .slice(0, 3)
      .map(object => object.__source_title || object.database || object.server || sourceTypeDisplay(object.source_type))
      .filter(Boolean)
      .join(', ');
    const objectTypes = Array.from(new Set(group.objects
      .map(object => objectTypeLabel(object.type || object.raw_object_type || object.object_type))
      .filter(Boolean)))
      .slice(0, 4)
      .join(', ');
    const value = [
      `${number(group.objects.length)} ${d.physicalObjects}`,
      objectTypes,
      sourceNames
    ].filter(Boolean).join(' · ');
    return row(group.table, value);
  });
  const hidden = groups.length - visible.length;
  if (hidden > 0) rows.push(row(d.hiddenRows, `+ ${number(hidden)}`));
  return rows;
}

function semanticBadgeHtml(badge) {
  const value = normalize(badge);
  const productionValue = normalize(t('semanticFlow.production'));
  const className = value.includes(productionValue) || value.includes('production') || value.includes('produccion')
    ? 'semantic-badge-production'
    : value.includes(normalize(t('semanticFlow.stage'))) || value.includes('stage') || value.includes('etapa')
      ? 'semantic-badge-stage'
      : value.includes(normalize(t('semanticFlow.pipeline'))) || value.includes('pipeline')
        ? 'semantic-badge-pipeline'
        : '';
  return `<i class="${className}">${escapeHtml(badge)}</i>`;
}

function semanticObjectNode(source, object, id) {
  const label = canonicalObjectDisplayName(object, source);
  return {
    id,
    kind: 'object',
    label,
    data: {
      ...object,
      label,
      workspace_name: object.workspace_name || source.workspace_name,
      source_workspace_name: source.workspace_name,
      source_label: source.label,
      source_type: object.source_type || source.source_type
    }
  };
}

function semanticObjectSchema(object) {
  if (isUnresolvedVariableObject(object)) return i18n[state.lang].detail.dynamicVariable;
  const explicit = object.schema || object.schema_name || object.object_schema;
  if (explicit) return explicit;
  const label = text(object.label || object.object_name || object.qualified_name);
  const match = label.match(/^([A-Za-z0-9_$#@-]+)\./);
  return match ? match[1] : t('unknown');
}

function semanticObjectDisplayName(object) {
  return canonicalObjectDisplayName(object);
}

function semanticObjectDetails(sourceNode, objects) {
  const expandKey = `semantic-objects:${sourceNode.id}`;
  const selectedObjectIsInside = state.selectedNode && state.selectedNode.id && state.selectedNode.id.startsWith(`${sourceNode.id}:object:`);
  const details = document.createElement('details');
  details.className = 'semantic-object-more';
  details.open = state.expanded.has(expandKey) || Boolean(selectedObjectIsInside);
  details.addEventListener('toggle', () => {
    if (details.open) state.expanded.add(expandKey);
    else state.expanded.delete(expandKey);
  });
  const summary = document.createElement('summary');
  summary.innerHTML = `<span>${number(objects.length)} ${escapeHtml(t('semanticFlow.sourceObjects').toLowerCase())}</span>`;
  details.append(summary);

  const body = document.createElement('div');
  body.className = 'semantic-object-groups semantic-object-table';

  const header = document.createElement('div');
  header.className = 'semantic-object-row semantic-object-row-header';
  header.innerHTML = `
    <span>${escapeHtml(t('objects'))}</span>
    <strong>${escapeHtml(t('detail.name'))}</strong>
    <span>${escapeHtml(t('detail.database'))}</span>
    <span>${escapeHtml(t('detail.schema'))}</span>
  `;
  body.append(header);

  // Un único listado ordenado por schema y luego por nombre (en vez de una
  // sección <h4> por schema): así el schema puede ser una columna más junto
  // al resto, con un solo encabezado fijo arriba en vez de repetirse por
  // cada grupo.
  const sortedObjects = objects
    .slice()
    .sort((a, b) =>
      semanticObjectSchema(a).localeCompare(semanticObjectSchema(b)) ||
      objectBareName(a).localeCompare(objectBareName(b))
    );
  sortedObjects.forEach((object, objectIndex) => {
    const objectNode = semanticObjectNode(sourceNode.data, object, `${sourceNode.id}:object:${objectIndex}`);
    const objectButton = document.createElement('button');
    objectButton.type = 'button';
    objectButton.className = `semantic-object-row ${nodeTypeClass(objectNode)}`;
    objectButton.title = semanticObjectDisplayName(object);
    objectButton.innerHTML = `
      <span>${escapeHtml(objectTypeLabel(object.type || object.object_type || object.raw_object_type))}</span>
      <strong>${escapeHtml(objectBareName(object))}</strong>
      <span class="semantic-object-origin">${escapeHtml(objectStoreName(object, sourceNode.data) || '—')}</span>
      <span class="semantic-object-schema-cell">${escapeHtml(semanticObjectSchema(object))}</span>
    `;
    objectButton.addEventListener('click', event => {
      event.stopPropagation();
      selectNode(objectNode);
    });
    body.append(objectButton);
  });
  details.append(body);
  return details;
}

function semanticSourceDisplayTitle(sourceNode, source) {
  const label = text(sourceNode.label);
  const sourceType = text(source.source_type);
  const readableSourceType = sourceTypeLabel(sourceType);
  if (/^https?:\/\//i.test(label) && sourceType) return readableSourceType;
  if (source.server && normalize(label) === normalize(source.server) && sourceType) return readableSourceType;
  return label || readableSourceType || t('source');
}

function semanticSourceMeta(source, title) {
  return [sourceTypeLabel(source.source_type), source.server, source.database]
    .filter(Boolean)
    .filter(value => normalize(value) !== normalize(title))
    .join(' · ');
}

function semanticSourceCard(source, workspace, model, sourceIndex) {
  const sourceNode = {
    id: `semantic:${model.qualified_name || model.label}:source:${sourceIndex}`,
    kind: 'source',
    label: source.label || source.database || source.server || sourceTypeDisplay(source.source_type) || t('source'),
    data: {
      ...source,
      workspace_name: source.workspace_name || workspace.name
    }
  };
  const article = document.createElement('article');
  article.className = `semantic-source-card${state.selectedNode && state.selectedNode.id === sourceNode.id ? ' selected' : ''}`;
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `node-card semantic-source-main source ${nodeTypeClass(sourceNode)}`;
  const sourceTitle = semanticSourceDisplayTitle(sourceNode, source);
  const sourceMeta = semanticSourceMeta(source, sourceTitle);
  button.innerHTML = `
    <span class="ms-icon ${iconClassForNode(sourceNode)}" aria-hidden="true"></span>
    <span class="node-main">
      <strong>${escapeHtml(sourceTitle)}</strong>
      <span>${escapeHtml(sourceMeta)}</span>
    </span>
  `;
  button.addEventListener('click', () => selectNode(sourceNode));
  article.append(button);

  const allObjects = uniqueBy(visibleObjectsForSource(source), object => objectKey(object));
  if (allObjects.length) {
    const objectWrap = document.createElement('div');
    objectWrap.className = 'semantic-object-pills';
    objectWrap.append(semanticObjectDetails(sourceNode, allObjects));
    article.append(objectWrap);
  }
  return article;
}

function semanticModelCard(workspace, model) {
  const node = {
    id: `semantic:${model.qualified_name || model.label}:model`,
    kind: 'item',
    label: model.label,
    data: {
      ...model,
      deployment_pipeline: workspace.deployment_pipeline || model.deployment_pipeline
    }
  };
  const button = document.createElement('button');
  button.type = 'button';
  const productionClass = isProductionWorkspace(workspace) ? ' production-model' : '';
  button.className = `node-card semantic-model-card item type-semantic${productionClass}${state.selectedNode && state.selectedNode.id === node.id ? ' selected' : ''}`;
  const badges = semanticPipelineBadges(workspace, model);
  const footprint = semanticModelFootprint(model);
  button.innerHTML = `
    <span class="ms-icon ${iconClassForNode(node)}" aria-hidden="true"></span>
    <span class="node-main">
      <strong>${escapeHtml(model.label)}</strong>
      <span>${escapeHtml([workspace.name, workspace.environment, itemTypeLabel(model.item_type)].filter(Boolean).join(' · '))}</span>
    </span>
    <span class="semantic-model-footprint">
      <i>${number(footprint.tableCount)} ${escapeHtml(i18n[state.lang].detail.semanticTableCount.toLowerCase())}</i>
      <i>${number(footprint.objectCount)} ${escapeHtml(t('semanticFlow.sourceObjects').toLowerCase())}</i>
    </span>
    <span class="semantic-model-badges">${badges.slice(0, 4).map(semanticBadgeHtml).join('')}</span>
  `;
  button.addEventListener('click', () => selectNode(node));
  return button;
}

function semanticReportCard(report, model, reportIndex) {
  const node = {
    id: `semantic:${model.qualified_name || model.label}:report:${reportIndex}`,
    kind: 'report',
    label: report.label,
    data: report
  };
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `node-card semantic-report-card report type-report${state.selectedNode && state.selectedNode.id === node.id ? ' selected' : ''}`;
  button.innerHTML = `
    <span class="ms-icon ${iconClassForNode(node)}" aria-hidden="true"></span>
    <span class="node-main">
      <strong>${escapeHtml(report.label || report.qualified_name)}</strong>
      <span>${escapeHtml([itemTypeLabel(report.item_type), report.workspace_name].filter(Boolean).join(' · '))}</span>
    </span>
  `;
  button.addEventListener('click', () => selectNode(node));
  return button;
}

function semanticEmptyColumn(textValue) {
  const empty = document.createElement('div');
  empty.className = 'semantic-empty';
  empty.textContent = textValue;
  return empty;
}

function semanticPipelineContext(selected) {
  const pipelines = new Map();
  for (const workspace of selected) {
    const deployment = workspace.deployment_pipeline || {};
    if (!deployment.has_pipeline) continue;
    const key = deployment.deployment_pipeline_id || deployment.deployment_pipeline_name || workspace.name;
    if (!pipelines.has(key)) {
      pipelines.set(key, {
        name: deployment.deployment_pipeline_name || t('deploymentPipeline'),
        stages: [],
        workspaces: []
      });
    }
    const entry = pipelines.get(key);
    entry.workspaces.push(workspace);
    if (deployment.stage_name || deployment.stage_order) {
      entry.stages.push({
        stage_name: deployment.stage_name || `${t('deploymentStage')} ${deployment.stage_order || ''}`,
        stage_order: deployment.stage_order || '',
        local_workspace_name: workspace.name,
        workspace
      });
    }
  }
  if (!pipelines.size) return null;
  const wrap = document.createElement('section');
  wrap.className = 'semantic-pipeline-context';
  for (const entry of pipelines.values()) {
    const article = document.createElement('article');
    article.className = 'semantic-pipeline-card';
    const stages = entry.stages.length ? entry.stages : entry.workspaces.map((workspace, index) => ({
      stage_name: workspace.deployment_pipeline && workspace.deployment_pipeline.stage_name || workspace.environment || `${t('deploymentStage')} ${index + 1}`,
      stage_order: index + 1,
      local_workspace_name: workspace.name,
      workspace
    }));
    article.innerHTML = `
      <strong>${escapeHtml(entry.name)}</strong>
      <div class="semantic-pipeline-stages">
        ${stages
          .slice()
          .sort((a, b) => Number(a.stage_order || 999) - Number(b.stage_order || 999))
          .map(stage => stagePillHtml(stage))
          .join('')}
      </div>
    `;
    wrap.append(article);
  }
  return wrap;
}

// Safety net for pathological selections (e.g. every workspace expanded
// at once in "Todos" mode): without a ceiling, the recursive tree layout
// below has no windowing and would materialize one DOM card + one SVG edge
// per visible node with no limit, freezing the tab. This does not affect
// normal usage -- a handful of expanded branches stays far under the cap.
const FLOW_BOARD_NODE_LIMIT = 600;

function renderFlowBoard() {
  const selected = selectedLineageWorkspaceList();
  const roots = selectedRootNodes();
  els.treeStage.innerHTML = '';
  els.treeStage.classList.remove('semantic-stage', 'planning-stage', 'impact-stage');
  if (!roots.length) {
    els.graphTitle.textContent = t('selectWorkspace');
    els.graphSubtitle.textContent = t('graphHint');
    els.treeStage.innerHTML = `<div class="empty-state">${t('empty')}</div>`;
    return;
  }

  els.graphTitle.textContent = roots.length === 1
    ? roots[0].label
    : `${number(roots.length)} ${t('selected')}`;
  // The element/selection counts this used to show ("Todos · N Elementos
  // · 2/N seleccionados") duplicate what the workspace index (left
  // sidebar) already displays per workspace -- removed 2026-07-19 to
  // declutter the diagram header; els.graphSubtitle stays in the DOM
  // (Impact/Planning still set their own, non-redundant text into it).
  els.graphSubtitle.textContent = '';

  const nodes = [];
  const edges = [];
  let flowBoardTruncated = false;
  const nodeById = new Map();
  const sharedSources = new Map();
  const sharedObjects = new Map();
  const sharedFabricItems = new Map();
  const flow = {
    top: 18,
    left: 18,
    workspaceGap: 26,
    childGap: 12,
    nestedGap: 8,
    rootColumnGap: 52,
    columnGap: 44,
    fallbackColumnStep: 520,
    levelWidths: [],
    columns: [18]
  };
  let cursorY = flow.top;
  let maxX = 0;

  function isFlowNodeOpen(node, originalId = '') {
    return state.expanded.has(node.id) || Boolean(originalId && state.expanded.has(originalId));
  }

  function collectFlowWidths(node, level, originalId = '') {
    flow.levelWidths[level] = Math.max(flow.levelWidths[level] || 0, flowNodeWidth(node));
    if (!isFlowNodeOpen(node, originalId)) return;
    for (const child of childrenForNode(node)) {
      collectFlowWidths(child, level + 1, child.original_id || '');
    }
  }

  function buildFlowColumns() {
    let x = flow.left;
    const columns = [];
    const levels = Math.max(1, flow.levelWidths.length);
    for (let level = 0; level < levels; level += 1) {
      columns[level] = x;
      const width = flow.levelWidths[level] || 260;
      const gap = level === 0 ? flow.rootColumnGap : flow.columnGap;
      x += width + gap;
    }
    flow.columns = columns;
  }

  roots.forEach(root => collectFlowWidths(root, 0));
  buildFlowColumns();

  function flowColumnX(level) {
    if (level < flow.columns.length) return flow.columns[level];
    return flow.columns[flow.columns.length - 1] + ((level - flow.columns.length + 1) * flow.fallbackColumnStep);
  }

  function branchGap(level) {
    return level <= 1 ? flow.childGap : flow.nestedGap;
  }

  function addNode(node, x, y) {
    if (!nodeById.has(node.id)) {
      nodeById.set(node.id, { node, x, y, width: flowNodeWidth(node), height: flowNodeHeight(node) });
      nodes.push(nodeById.get(node.id));
      maxX = Math.max(maxX, x + flowNodeWidth(node));
    }
    return nodeById.get(node.id);
  }

  function addEdge(fromId, toId) {
    if (fromId === toId) return;
    if (edges.some(edge => edge.fromId === fromId && edge.toId === toId)) return;
    edges.push({ fromId, toId });
  }

  function materializeChild(parent, child) {
    let childNode = child;
    if (child.kind === 'source') {
      const key = sourceKey(child.data || {});
      if (sharedSources.has(key)) {
        const existing = sharedSources.get(key);
        addEdge(parent.id, existing.id);
        return null;
      }
      childNode = { ...child, id: `source:shared:${sharedSources.size}`, original_id: child.id };
      sharedSources.set(key, childNode);
    }
    if (child.kind === 'object') {
      const key = objectKey(child.data || {});
      if (sharedObjects.has(key)) {
        const existing = sharedObjects.get(key);
        addEdge(parent.id, existing.id);
        return null;
      }
      childNode = { ...child, id: `object:shared:${sharedObjects.size}`, original_id: child.id };
      sharedObjects.set(key, childNode);
    }
    if (isShareableFabricChild(parent, child)) {
      const key = fabricItemKey(child.data || {});
      if (sharedFabricItems.has(key)) {
        const existing = sharedFabricItems.get(key);
        addEdge(parent.id, existing.id);
        return null;
      }
      childNode = { ...child, id: `fabric:shared:${sharedFabricItems.size}`, original_id: child.id };
      sharedFabricItems.set(key, childNode);
    }
    return childNode;
  }

  function layoutBranch(node, level, topY, originalId = '') {
    const width = flowNodeWidth(node);
    const height = flowNodeHeight(node);
    const x = flowColumnX(level);
    const isOpen = isFlowNodeOpen(node, originalId);
    const withinNodeBudget = nodes.length < FLOW_BOARD_NODE_LIMIT;
    if (isOpen && !withinNodeBudget) flowBoardTruncated = true;
    const rawChildren = (isOpen && withinNodeBudget) ? childrenForNode(node) : [];
    const children = [];

    for (const child of rawChildren) {
      const childNode = materializeChild(node, child);
      if (childNode) children.push({ node: childNode, originalId: childNode.original_id || '' });
    }

    if (!children.length) {
      addNode(node, x, topY);
      return { height, centerY: topY + (height / 2) };
    }

    const childLayouts = [];
    let childY = topY;
    for (const child of children) {
      const layout = layoutBranch(child.node, level + 1, childY, child.originalId);
      childLayouts.push({ ...child, layout });
      childY += layout.height + branchGap(level);
    }

    const blockBottom = childY - branchGap(level);
    const blockHeight = Math.max(height, blockBottom - topY);
    const firstCenter = childLayouts[0].layout.centerY;
    const lastCenter = childLayouts[childLayouts.length - 1].layout.centerY;
    const centerY = (firstCenter + lastCenter) / 2;
    const nodeY = Math.max(topY, centerY - (height / 2));
    addNode(node, x, nodeY);

    for (const child of childLayouts) addEdge(node.id, child.node.id);
    maxX = Math.max(maxX, x + width);
    return { height: blockHeight, centerY: nodeY + (height / 2) };
  }

  for (const root of roots) {
    const layout = layoutBranch(root, 0, cursorY);
    cursorY += layout.height + flow.workspaceGap;
  }

  if (flowBoardTruncated) {
    const notice = document.createElement('div');
    notice.className = 'flow-board-truncated-notice';
    notice.textContent = t('flowTruncated');
    els.treeStage.append(notice);
  }

  const boardWidth = Math.max(900, maxX + 48);
  const boardHeight = Math.max(500, cursorY + 28);
  // The per-pipeline stage filter pill bar (createDiagramStageSelector) was
  // removed from the diagram 2026-07-19 -- redundant with the workspace
  // index's own per-stage tiles in the left sidebar, which already select
  // the same thing. The function/toggleStageWorkspaceFilter/
  // state.selectedStageWorkspaces mechanism stays in the code, just never
  // called from here anymore.
  const board = document.createElement('div');
  board.className = 'flow-board';
  board.style.width = `${boardWidth}px`;
  board.style.height = `${boardHeight}px`;

  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.classList.add('flow-edges');
  svg.setAttribute('width', boardWidth);
  svg.setAttribute('height', boardHeight);
  svg.setAttribute('viewBox', `0 0 ${boardWidth} ${boardHeight}`);

  const incomingCounts = new Map();
  for (const edge of edges) {
    incomingCounts.set(edge.toId, (incomingCounts.get(edge.toId) || 0) + 1);
  }
  nodes.forEach(entry => {
    entry.node.incoming_count = incomingCounts.get(entry.node.id) || 0;
    entry.node.shared_count = entry.node.incoming_count > 1 ? entry.node.incoming_count : 0;
  });

  for (const edge of edges) {
    const from = nodeById.get(edge.fromId);
    const to = nodeById.get(edge.toId);
    if (!from || !to) continue;
    const x1 = from.x + from.width;
    const y1 = from.y + from.height / 2;
    const x2 = to.x;
    const y2 = to.y + to.height / 2;
    const curve = Math.max(42, Math.min(120, (x2 - x1) * 0.4));
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', `M ${x1} ${y1} C ${x1 + curve} ${y1}, ${x2 - curve} ${y2}, ${x2} ${y2}`);
    path.setAttribute('pathLength', '1');
    path.setAttribute('class', `flow-edge edge-to-${nodeClass(to.node.kind)} edge-from-${nodeClass(from.node.kind)}${isCrossWorkspaceNode(to.node) ? ' edge-cross' : ''}${(incomingCounts.get(to.node.id) || 0) > 1 ? ' edge-shared-target' : ''}`);
    svg.append(path);
  }

  board.append(svg);
  nodes.forEach(entry => board.append(createFlowCard(entry.node, entry.x, entry.y)));
  els.treeStage.append(board);
  applyTransform();
}

function impactObjectTypeLabel(object) {
  const values = text(object.object_type_values)
    .split(';')
    .map(value => value.trim())
    .filter(Boolean);
  if (!values.length) return t('unknown');
  return values.map(value => objectTypeLabel(value)).join(' · ');
}

function impactPathLabel(value) {
  if (state.lang !== 'es') return value;
  const labels = {
    'source_object -> item': 'objeto origen -> item',
    'source_object -> semantic_model -> report': 'objeto origen -> modelo semántico -> informe'
  };
  return labels[value] || value;
}

function impactItemsByType(items) {
  const groups = new Map();
  for (const item of asList(items)) {
    const type = item.item_type || 'Unknown';
    if (!groups.has(type)) groups.set(type, []);
    groups.get(type).push(item);
  }
  return Array.from(groups.entries())
    .sort((a, b) => b[1].length - a[1].length || itemTypeLabel(a[0]).localeCompare(itemTypeLabel(b[0])));
}

function impactItemPreview(item) {
  const workspace = item.workspace_name ? ` · ${item.workspace_name}` : '';
  return `
    <span class="impact-preview-item">
      <i class="ms-icon ${iconClassForType(item.item_type)}" aria-hidden="true"></i>
      <span><strong>${escapeHtml(item.label || item.qualified_name)}</strong><em>${escapeHtml(itemTypeLabel(item.item_type) + workspace)}</em></span>
    </span>
  `;
}

function impactExpanded(key) {
  return Boolean(key && state.expanded.has(key));
}

function toggleImpactExpansion(key) {
  if (!key) return;
  if (state.expanded.has(key)) state.expanded.delete(key);
  else state.expanded.add(key);
  renderTree();
  renderDetails(state.selectedNode);
  applyLayoutState();
}

function impactGroupPreview(title, items, iconClass, limit = 4, expandKey = '') {
  if (!items || !items.length) return '';
  const isOpen = impactExpanded(expandKey);
  const visible = isOpen ? items : items.slice(0, limit);
  const hidden = items.length - visible.length;
  return `
    <section class="impact-group">
      <h3><i class="ms-icon ${iconClass}" aria-hidden="true"></i>${escapeHtml(title)} <span>${number(items.length)}</span></h3>
      <div class="impact-preview-list">
        ${visible.map(impactItemPreview).join('')}
        ${hidden > 0 ? `<button class="impact-more impact-more-button" type="button" data-expand-key="${escapeHtml(expandKey)}">+ ${number(hidden)} ${escapeHtml(t('impactLabels.hiddenItems'))}</button>` : ''}
        ${isOpen && items.length > limit ? `<button class="impact-more impact-more-button" type="button" data-expand-key="${escapeHtml(expandKey)}">${escapeHtml(t('impactLabels.showLess'))}</button>` : ''}
      </div>
    </section>
  `;
}


// La lista de "objetos coincidentes" vivía aquí como tarjetas sueltas
// (nombre completo, sin columnas) justo encima de la tabla real
// (impactObjectTable, con Tipo/Nombre/Origen/Schema/impacto) más abajo en
// renderImpactView -- dos representaciones de lo mismo, una peor que la
// otra. Este panel ahora es sólo los controles (buscar + contador +
// Limpiar); la tabla real que ya se renderiza justo debajo es el listado
// (2026-07-20).
// La selección explícita de objetos concretos (más allá de lo que ya
// filtra el buscador) se había quitado el 2026-07-20 por creerla redundante
// con la tabla de abajo -- pero sin ella no hay forma de FIJAR varios
// objetos sueltos a la vez (cada búsqueda nueva sustituye a la anterior),
// así que vuelve, ahora en filas con columnas (tipo/nombre/origen/schema,
// sin las cuentas de impacto -- ésas ya están en la tabla grande) en vez de
// las tarjetas de texto libre que tenía antes.
function objectPickRow(object, active = false) {
  const fullName = impactObjectFilterLabel(object);
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `impact-pick-row${active ? ' active' : ''}`;
  button.title = fullName;
  button.innerHTML = `
    <span>${escapeHtml(impactObjectTypeLabel(object))}</span>
    <strong>${escapeHtml(impactObjectBareName(object))}</strong>
    <span>${escapeHtml(impactObjectOrigin(object))}</span>
    <span>${escapeHtml(impactObjectSchema(object))}</span>
  `;
  button.addEventListener('click', event => {
    event.stopPropagation();
    if (state.impactSelectedObjectKeys.has(object.object_key)) state.impactSelectedObjectKeys.delete(object.object_key);
    else state.impactSelectedObjectKeys.add(object.object_key);
    state.filters.impactObjectKey = 'all';
    state.history = [];
    state.selectedNode = null;
    render();
  });
  return button;
}

function sortObjectsByTypeNameOriginSchema(objects) {
  return objects.slice().sort((a, b) =>
    impactObjectTypeLabel(a).localeCompare(impactObjectTypeLabel(b)) ||
    impactObjectBareName(a).localeCompare(impactObjectBareName(b)) ||
    impactObjectOrigin(a).localeCompare(impactObjectOrigin(b)) ||
    impactObjectSchema(a).localeCompare(impactObjectSchema(b))
  );
}

function impactObjectFocusPanel(filteredCount) {
  const objectOptions = impactObjectsForCascade({
    sourceType: state.filters.sourceType,
    database: state.filters.impactDatabase,
    objectType: state.filters.impactObjectType
  });
  const panel = document.createElement('section');
  panel.className = 'impact-focus-panel';

  const label = document.createElement('label');
  label.className = 'impact-focus-search';
  label.innerHTML = `<span>${escapeHtml(t('impactLabels.sourceObject'))}</span>`;
  const input = document.createElement('input');
  input.id = 'impactFocusObjectSearch';
  input.type = 'search';
  input.autocomplete = 'off';
  input.placeholder = t('impactLabels.objectSearchPlaceholder');
  input.value = state.impactObjectSearch;
  input.addEventListener('input', event => {
    const start = event.target.selectionStart;
    const end = event.target.selectionEnd;
    scheduleImpactObjectSearchRender('#impactFocusObjectSearch', event.target.value, start, end);
  });
  label.append(input);

  const meta = document.createElement('div');
  meta.className = 'impact-focus-meta';
  meta.innerHTML = `
    <span>${escapeHtml(t('impactLabels.oneRowPerObject'))}</span>
    <strong>${number(filteredCount)} ${escapeHtml(t('impactLabels.objectSearchResults'))}</strong>
  `;

  const clear = document.createElement('button');
  clear.type = 'button';
  clear.textContent = t('impactLabels.clearObject');
  clear.hidden = !state.impactObjectSearch && state.filters.impactObjectKey === 'all' && !state.impactSelectedObjectKeys.size;
  clear.addEventListener('click', () => {
    clearImpactObjectSearch();
    render();
  });

  panel.append(label, meta, clear);

  const selectedObjects = sortObjectsByTypeNameOriginSchema(
    objectOptions.filter(object => state.impactSelectedObjectKeys.has(object.object_key))
  );
  const query = normalize(state.impactObjectSearch);
  const pickLimit = 5;
  const matches = sortObjectsByTypeNameOriginSchema(
    objectOptions
      .filter(object => !query || impactObjectSearchText(object).includes(query))
      .filter(object => !state.impactSelectedObjectKeys.has(object.object_key))
  ).slice(0, pickLimit);

  if (selectedObjects.length) {
    const selectedWrap = document.createElement('div');
    selectedWrap.className = 'impact-pick-group selected';
    selectedWrap.innerHTML = `<span>${escapeHtml(t('impactLabels.selectedObjects'))}</span>`;
    selectedObjects.forEach(object => selectedWrap.append(objectPickRow(object, true)));
    panel.append(selectedWrap);
  }

  const matchWrap = document.createElement('div');
  matchWrap.className = 'impact-pick-group';
  matchWrap.innerHTML = `<span>${escapeHtml(t('impactLabels.matchingObjects'))}</span>`;
  if (matches.length) {
    matches.forEach(object => matchWrap.append(objectPickRow(object, false)));
  } else {
    const empty = document.createElement('p');
    empty.textContent = t('impactLabels.noImpact');
    matchWrap.append(empty);
  }
  panel.append(matchWrap);

  return panel;
}

function impactCategoryItems(object, category) {
  const directItems = asList(object.direct_items);
  const reports = asList(object.downstream_reports);
  if (category === 'notebooks') return directItems.filter(item => item.item_type === 'Notebook');
  if (category === 'semantic') return directItems.filter(item => item.item_type === 'SemanticModel');
  if (category === 'reports') {
    return uniqueBy([
      ...directItems.filter(item => ['Report', 'PaginatedReport', 'Dashboard', 'KQLDashboard'].includes(item.item_type)),
      ...reports
    ], item => fabricItemKey(item));
  }
  if (category === 'copyjobs') return directItems.filter(item => item.item_type === 'CopyJob');
  if (category === 'pipelines') return directItems.filter(item => item.item_type === 'DataPipeline');
  if (category === 'dataflows') return directItems.filter(item => item.item_type === 'Dataflow');
  return directItems.filter(item =>
    !['Notebook', 'SemanticModel', 'Report', 'PaginatedReport', 'Dashboard', 'KQLDashboard', 'CopyJob', 'DataPipeline', 'Dataflow'].includes(item.item_type)
  );
}

function impactCategoryDefinitions() {
  return [
    { key: 'notebooks', label: t('impactLabels.notebooks') },
    { key: 'semantic', label: t('impactLabels.semanticModels') },
    { key: 'reports', label: t('impactLabels.reports') },
    { key: 'copyjobs', label: t('impactLabels.copyjobs') },
    { key: 'pipelines', label: t('impactLabels.pipelines') },
    { key: 'dataflows', label: t('impactLabels.dataflows') },
    { key: 'other', label: t('impactLabels.otherElements') }
  ];
}

// The impact table always shows every category (notebooks, semantic
// models, reports, copyjobs, pipelines, dataflows, other) no matter which
// mode/section you're currently browsing -- a source table's real-world
// impact doesn't change depending on which tab you happen to have open,
// so filtering columns by state.mode was hiding genuine impact (e.g. a
// table also read by a Notebook or Dataflow, invisible while in Semantic
// Models mode) instead of just reordering emphasis.
function impactVisibleCategories() {
  return impactCategoryDefinitions();
}

// A count-only badge instead of listing every item inline: with 7
// categories now (notebooks/semantic/reports/copyjobs/pipelines/
// dataflows/other), a table wide enough to show full item names in every
// column no longer fits any real viewport -- it forced either horizontal
// scrolling mid-comparison or zooming the whole page out until the text
// was unreadable. The count + hover preview keeps every category visible
// at once at a normal reading size; clicking the badge (see
// openImpactBreakdownModal) opens a full breakdown table of every
// affected item in that category, with an Excel export scoped to it.
function impactCategoryCell(items, category, objectKey) {
  const list = asList(items);
  const count = list.length;
  if (!count) return '<span class="impact-count-badge impact-count-empty" aria-hidden="true">–</span>';
  const previewLimit = 6;
  const names = list.slice(0, previewLimit).map(item => item.label || item.qualified_name).filter(Boolean);
  const hidden = count - names.length;
  const title = hidden > 0 ? `${names.join(', ')}, +${hidden}` : names.join(', ');
  return `<button type="button" class="impact-count-badge impact-count-${escapeHtml(category)}" title="${escapeHtml(title)}" data-impact-object-key="${escapeHtml(objectKey)}" data-impact-category="${escapeHtml(category)}">${number(count)}</button>`;
}

function impactObjectByKey(objectKey) {
  return asList(impactData().objects).find(object => object.object_key === objectKey) || null;
}

function impactBreakdownRowHtml(item) {
  const isDownstreamReport = item.impact_path === 'source_object -> semantic_model -> report';
  return `
    <tr>
      <td>${escapeHtml(itemTypeLabel(item.item_type))}</td>
      <td>${escapeHtml(item.workspace_name || '')}</td>
      <td>${escapeHtml(item.label || item.qualified_name || '')}</td>
      <td>${escapeHtml(isDownstreamReport ? t('impactLabels.downstreamReports') : usageTypeLabel(item.usage_type))}</td>
      <td title="${escapeHtml(item.evidence || '')}">${escapeHtml(confidenceValueLabel(item.confidence))}</td>
    </tr>
  `;
}

// The source object itself doesn't "run" -- what a colleague actually
// wants to know when they ask "when/who last touched this table" is: which
// Fabric-native process (CopyJob/Notebook/Dataflow/Pipeline) WRITES to it,
// and when that process last ran. That's only knowable when the writer is
// itself a scanned Fabric item (usage_type "writes_to" among this object's
// direct_items) -- for a table whose only writer is an external system
// (plain SQL Server, an on-prem job, etc.) there is no such item and this
// honestly says so instead of guessing.
function impactObjectWriters(object) {
  return uniqueBy(
    asList(object && object.direct_items).filter(item => item.usage_type === 'writes_to'),
    item => item.qualified_name
  );
}

function impactWriterRowHtml(item) {
  const d = i18n[state.lang].detail;
  const executionText = impactExecutionLabel(item);
  return `
    <div class="impact-breakdown-writer-row">
      <strong>${escapeHtml(item.label || item.qualified_name)}</strong>
      <span>${escapeHtml(itemTypeLabel(item.item_type))} · ${escapeHtml(item.workspace_name || '')}</span>
      <span>${escapeHtml(d.latestStart)}: ${escapeHtml(executionText || t('impactLabels.noExecutionData'))}</span>
      ${item.default_identity ? `<span>${escapeHtml(d.defaultIdentity)}: ${escapeHtml(item.default_identity)}</span>` : ''}
    </div>
  `;
}

function impactWriterSummaryHtml(object) {
  const writers = impactObjectWriters(object);
  const header = `
    <div class="impact-breakdown-writer-header">
      <strong>${escapeHtml(t('impactLabels.writerTitle'))}</strong>
      <button type="button" class="info-icon-button" data-glossary-term="confidence" aria-label="${escapeHtml(t('glossary.iconLabel'))}">ⓘ</button>
    </div>
    <p class="impact-breakdown-writer-hint">${escapeHtml(t('impactLabels.writerHint'))}</p>
  `;
  if (!writers.length) {
    return `${header}<p class="impact-breakdown-writer-empty">${escapeHtml(t('impactLabels.noWriterDetected'))}</p>`;
  }
  return `${header}<div class="impact-breakdown-writers">${writers.map(impactWriterRowHtml).join('')}</div>`;
}

let impactBreakdownState = null;
// Set by renderDetails() on every render (see planningEvidenceEntries) so
// the button in the detail panel and the modal it opens always agree on
// which node's data to show -- same one-state-object pattern as
// impactBreakdownState above.
let currentPlanningEvidence = { title: '', entries: [] };

function renderPlanningEvidenceModal() {
  if (!els.planningEvidenceModalBody) return;
  const d = i18n[state.lang].detail;
  if (els.planningEvidenceModalTitle) els.planningEvidenceModalTitle.textContent = currentPlanningEvidence.title || d.planningEvidence;
  const rows = currentPlanningEvidence.entries
    .map(entry => `<tr><th>${escapeHtml(entry.label)}</th><td>${escapeHtml(entry.value)}</td></tr>`)
    .join('');
  els.planningEvidenceModalBody.innerHTML = `
    <table class="impact-breakdown-table planning-evidence-table">
      <thead><tr><th>${escapeHtml(d.fieldColumn)}</th><th>${escapeHtml(d.valueColumn)}</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
  `;
}

function renderImpactBreakdownModal(objectKey, category) {
  if (!els.impactBreakdownModal) return;
  const object = impactObjectByKey(objectKey);
  const d = i18n[state.lang].detail;
  const categoryDef = impactCategoryDefinitions().find(entry => entry.key === category);
  const items = object ? impactCategoryItems(object, category) : [];
  const objectLabel = object ? (impactObjectFilterLabel(object) || object.object_key) : '';

  els.impactBreakdownTitle.textContent = `${categoryDef ? categoryDef.label : category} · ${number(items.length)}`;
  els.impactBreakdownSubtitle.textContent = objectLabel;

  const writerBlock = object ? `<div class="impact-breakdown-writer-block">${impactWriterSummaryHtml(object)}</div>` : '';

  if (!items.length) {
    els.impactBreakdownBody.innerHTML = `${writerBlock}<p>${escapeHtml(t('impactLabels.breakdownEmpty'))}</p>`;
    return;
  }

  els.impactBreakdownBody.innerHTML = `
    ${writerBlock}
    <table class="impact-breakdown-table">
      <thead>
        <tr>
          <th>${escapeHtml(d.type)}</th>
          <th>${escapeHtml(d.workspace)}</th>
          <th>${escapeHtml(d.name)}</th>
          <th>${escapeHtml(d.usageType)}</th>
          <th>${escapeHtml(d.confidence)} <button type="button" class="info-icon-button" data-glossary-term="confidence" aria-label="${escapeHtml(t('glossary.iconLabel'))}">ⓘ</button></th>
        </tr>
      </thead>
      <tbody>${items.map(impactBreakdownRowHtml).join('')}</tbody>
    </table>
  `;
}

function toggleImpactBreakdownModal(forceOpen, objectKey, category) {
  if (!els.impactBreakdownModal) return;
  const shouldOpen = typeof forceOpen === 'boolean' ? forceOpen : els.impactBreakdownModal.hidden;
  if (shouldOpen) {
    impactBreakdownState = { objectKey, category };
    renderImpactBreakdownModal(objectKey, category);
    openModal(els.impactBreakdownModal);
  } else {
    els.impactBreakdownModal.hidden = true;
    if (els.modalBackdrop) els.modalBackdrop.hidden = true;
    impactBreakdownState = null;
  }
}

function buildImpactBreakdownExcelHtml(object, category, rows) {
  const d = i18n[state.lang].detail;
  const categoryDef = impactCategoryDefinitions().find(entry => entry.key === category);
  const columns = [
    ['affected_item_type', d.type],
    ['affected_workspace', d.workspace],
    ['affected_item_name', d.name],
    ['usage_type_label', d.usageType],
    ['confidence_label', d.confidence],
    ['last_execution', d.latestStart],
    ['default_identity', d.defaultIdentity],
    ['evidence', d.evidence]
  ];
  const summaryRows = [
    [d.excelGenerated, new Date().toISOString()],
    [state.lang === 'es' ? 'Objeto' : 'Object', impactObjectFilterLabel(object) || object.object_name || ''],
    [state.lang === 'es' ? 'Categoría' : 'Category', categoryDef ? categoryDef.label : category],
    [state.lang === 'es' ? 'Total' : 'Total', rows.length]
  ];
  const writers = impactObjectWriters(object);
  const writerColumns = [
    ['label', d.name],
    ['type', d.type],
    ['workspace', d.workspace],
    ['execution', d.latestStart],
    ['identity', d.defaultIdentity]
  ];
  const writerRows = writers.map(item => ({
    label: item.label || item.qualified_name || '',
    type: itemTypeLabel(item.item_type),
    workspace: item.workspace_name || '',
    execution: impactExecutionLabel(item),
    identity: item.default_identity || ''
  }));
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; }
    h1 { font-size: 18px; }
    h2 { font-size: 14px; margin-top: 18px; }
    table { border-collapse: collapse; width: 100%; }
    th { background: #e8eef7; font-weight: 700; }
    th, td { border: 1px solid #9fb0c5; font-size: 11px; padding: 5px; vertical-align: top; }
  </style>
</head>
<body>
  <h1>${escapeHtml(d.excelImpactList)}</h1>
  <table>
    <tbody>
      ${summaryRows.map(([label, value]) => `<tr><th>${escapeHtml(label)}</th><td>${escapeHtml(value)}</td></tr>`).join('')}
    </tbody>
  </table>
  <h2>${escapeHtml(t('impactLabels.writerTitle'))}</h2>
  <table>
    <thead><tr>${writerColumns.map(([, label]) => `<th>${escapeHtml(label)}</th>`).join('')}</tr></thead>
    <tbody>
      ${writerRows.length
        ? writerRows.map(rowData => `<tr>${writerColumns.map(([key]) => `<td>${escapeHtml(rowData[key])}</td>`).join('')}</tr>`).join('')
        : `<tr><td colspan="${writerColumns.length}">${escapeHtml(t('impactLabels.noWriterDetected'))}</td></tr>`}
    </tbody>
  </table>
  <table>
    <thead><tr>${columns.map(([, label]) => `<th>${escapeHtml(label)}</th>`).join('')}</tr></thead>
    <tbody>
      ${rows.map(rowData => `<tr>${columns.map(([key]) => `<td>${escapeHtml(rowData[key])}</td>`).join('')}</tr>`).join('')}
    </tbody>
  </table>
</body>
</html>`;
}

function downloadImpactBreakdownExcel() {
  if (!impactBreakdownState) return;
  const { objectKey, category } = impactBreakdownState;
  const object = impactObjectByKey(objectKey);
  if (!object) return;
  const rows = impactExcelRows(object, category);
  const content = buildImpactBreakdownExcelHtml(object, category, rows);
  const blob = new Blob([content], { type: 'application/vnd.ms-excel;charset=utf-8' });
  const categoryDef = impactCategoryDefinitions().find(entry => entry.key === category);
  const filenameBase = `${impactObjectFilterLabel(object) || object.object_key}-${categoryDef ? categoryDef.label : category}`;
  downloadBlob(blob, `${safeFilename(filenameBase)}.xls`);
}

function impactObjectTableRow(object, categories = impactVisibleCategories()) {
  const objectLabel = impactObjectFilterLabel(object);
  const node = {
    id: `impact:${object.object_key}`,
    kind: 'impactObject',
    label: objectLabel || object.object_key,
    data: object
  };
  const tr = document.createElement('tr');
  const selectedClass = state.selectedNode && state.selectedNode.id === node.id ? ' selected' : '';
  tr.className = `impact-table-row${selectedClass}`;
  tr.innerHTML = `
    <td class="impact-table-type">${escapeHtml(impactObjectTypeLabel(object))}</td>
    <td class="impact-table-object" title="${escapeHtml(objectLabel)}"><strong>${escapeHtml(impactObjectBareName(object))}</strong></td>
    <td class="impact-table-origin">${escapeHtml(impactObjectOrigin(object))}</td>
    <td class="impact-table-schema">${escapeHtml(impactObjectSchema(object))}</td>
    ${categories.map(category => `<td class="impact-count-cell">${impactCategoryCell(impactCategoryItems(object, category.key), category.key, object.object_key)}</td>`).join('')}
  `;
  tr.addEventListener('click', event => {
    if (event.target.closest('.impact-count-cell')) return;
    selectNode(node);
  });
  return tr;
}

function impactObjectTable(objects) {
  const categories = impactVisibleCategories();
  const wrap = document.createElement('div');
  wrap.className = 'impact-table-wrap';
  const table = document.createElement('table');
  table.className = 'impact-table impact-count-table';
  // Count badges (not full item lists) per column now -- see
  // impactCategoryCell -- so each category only needs to fit its own
  // short header word, not a stack of item names. Comfortably fits all 7
  // categories without horizontal scrolling on an ordinary viewport.
  table.style.minWidth = `${Math.max(720, 420 + categories.length * 88)}px`;
  table.innerHTML = `
    <thead>
      <tr>
        <th>${escapeHtml(t('objects'))}</th>
        <th>${escapeHtml(t('detail.name'))}</th>
        <th>${escapeHtml(t('detail.database'))}</th>
        <th>${escapeHtml(t('detail.schema'))}</th>
        ${categories.map(category => `<th>${escapeHtml(category.label)}</th>`).join('')}
      </tr>
    </thead>
    <tbody></tbody>
  `;
  const tbody = table.querySelector('tbody');
  objects.forEach(object => tbody.append(impactObjectTableRow(object, categories)));
  wrap.append(table);
  return wrap;
}

function renderImpactView() {
  const impact = impactData();
  const objects = filteredImpactObjects();
  const scopeCount = selectedWorkspaceList().length;
  const limit = 24;
  els.treeStage.innerHTML = '';
  els.treeStage.classList.remove('semantic-stage', 'planning-stage');
  els.treeStage.classList.add('impact-stage');
  els.graphTitle.textContent = t('impactTitle');
  els.graphSubtitle.textContent = scopeCount
    ? `${t('impactLabels.selectedScope')}: ${number(scopeCount)} ${t('workspaces')}`
    : t('impactHint');

  if (!impact.objects || !impact.objects.length) {
    els.treeStage.innerHTML = `<div class="empty-state">${t('impactLabels.noImpact')}</div>`;
    return;
  }

  const board = document.createElement('div');
  board.className = 'impact-board';
  board.append(impactObjectFocusPanel(objects.length));

  const list = document.createElement('div');
  list.className = 'impact-list impact-table-list';
  const showAllObjects = impactExpanded('impact-objects:all');
  const visibleObjects = showAllObjects ? objects : objects.slice(0, limit);
  if (visibleObjects.length) list.append(impactObjectTable(visibleObjects));
  if (objects.length > limit) {
    const more = document.createElement('button');
    more.className = 'impact-more impact-more-wide impact-more-button';
    more.type = 'button';
    more.dataset.expandKey = 'impact-objects:all';
    more.textContent = showAllObjects
      ? t('impactLabels.showLess')
      : `+ ${number(objects.length - limit)} ${t('impactLabels.hiddenObjects')}`;
    list.append(more);
  }
  if (!objects.length) {
    list.innerHTML = `<div class="empty-state">${t('impactLabels.noImpact')}</div>`;
  }
  board.append(list);
  board.addEventListener('click', event => {
    const button = event.target.closest('.impact-more-button');
    if (!button) return;
    event.preventDefault();
    event.stopPropagation();
    toggleImpactExpansion(button.dataset.expandKey);
  });
  els.treeStage.append(board);
  applyTransform();
}

function renderTree() {
  if (state.viewMode !== 'planning' && els.planningResetLayoutButton) {
    els.planningResetLayoutButton.hidden = true;
  }
  if (state.viewMode === 'impact') {
    renderImpactView();
    return;
  }
  if (state.viewMode === 'planning') {
    renderPlanningView();
    return;
  }
  // Semantic models used to get their own bespoke 3-column board (Reports |
  // Model | Sources) instead of the same expandable tree every other mode
  // uses. That board only went one level deep into sources and never
  // exposed the table/view objects underneath them, even when real
  // object-level lineage existed for that source -- childrenForNode()
  // already walks source -> object generically for any item kind, so
  // routing semantic models through the normal flow board (like Notebooks/
  // CopyJobs/Pipelines/Todos) gets both a consistent visual style and real
  // drill-down to table/schema level for free.
  renderFlowBoard();
}

function uniqueBy(items, keyFn) {
  const seen = new Set();
  return items.filter(item => {
    const key = keyFn(item);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function planningNodeKey(item) {
  return normalize(item.qualified_name || `${item.workspace_name}|${item.item_type}|${item.label}`);
}

// A notebook's Spark write and a semantic model's SQL-analytics-endpoint
// read of the exact same physical Delta table are tagged with different
// source_type values by the scanner (LakehouseTable/FabricOrSQL for the
// write side, SQL for the read side, since each comes from a different
// discovery path) -- bucket every Fabric-internal storage type together so
// the same table matches regardless of which side observed it. Real
// external systems (SharePoint, Dataverse, AmazonS3, ...) are left as-is;
// those genuinely are different systems, not different views of one table.
const PLANNING_FABRIC_INTERNAL_SOURCE_TYPES = new Set(['sql', 'lakehousetable', 'fabricorsql', 'warehouse', 'fabric']);
function planningNormalizedSourceType(value) {
  const normalized = normalize(value);
  return PLANNING_FABRIC_INTERNAL_SOURCE_TYPES.has(normalized) ? 'fabric_internal' : normalized;
}

// Hostname shapes of Fabric's own SQL surfaces (lakehouse/warehouse SQL
// analytics endpoints, OneLake) as opposed to a genuinely external server
// (<sql-server-host> and the like). The 'sql' source TYPE cannot make
// this distinction -- both a lakehouse endpoint read and an external SQL
// Server read report type SQL -- only the hostname can.
const PLANNING_FABRIC_SQL_HOST_PATTERN = /datawarehouse|fabric\.microsoft\.com|pbidedicated|onelake/i;

let planningWorkspaceNameSetForData = null;
let planningWorkspaceNameSetCache = null;
function planningWorkspaceNameSet() {
  const data = state.data || {};
  if (planningWorkspaceNameSetForData !== data) {
    planningWorkspaceNameSetForData = data;
    planningWorkspaceNameSetCache = new Set((data.workspaces || []).map(workspace => normalize(workspace.name)));
  }
  return planningWorkspaceNameSetCache;
}

// Which workspaces actually OWN a Lakehouse/Warehouse (or its SQLEndpoint)
// with a given name. A notebook that reads a foreign lakehouse through its
// own default-lakehouse mount records the store under the notebook's OWN
// workspace -- a spelling that names a lakehouse the workspace doesn't
// have. When exactly one workspace really owns an item by that name, that
// owner is the store's true home; with several same-named owners (DEV/PRO
// twins) it stays ambiguous and the spelling is kept as recorded.
let planningStoreOwnersForData = null;
let planningStoreOwnersCache = null;
function planningStoreOwnersByName() {
  const data = state.data || {};
  if (planningStoreOwnersForData !== data) {
    planningStoreOwnersForData = data;
    planningStoreOwnersCache = new Map();
    for (const workspace of data.workspaces || []) {
      for (const modeKey of ['lakehouse', 'warehouse', 'sqlendpoint']) {
        for (const item of asList(workspace[modeKey])) {
          const name = normalize(item.label);
          if (!name) continue;
          if (!planningStoreOwnersCache.has(name)) planningStoreOwnersCache.set(name, new Set());
          planningStoreOwnersCache.get(name).add(normalize(workspace.name));
        }
      }
    }
  }
  return planningStoreOwnersCache;
}

function planningResolveStoreOwner(workspaceName, storeName) {
  const owners = planningStoreOwnersByName().get(storeName);
  if (!owners || owners.has(workspaceName) || owners.size !== 1) return workspaceName;
  return owners.values().next().value;
}

// The same physical lakehouse/warehouse is spelled at least four ways in
// real source records: a model's read through the SQL analytics endpoint
// (host resolved back to its owner workspace by the backend as
// fabric_store_workspace), a notebook's write target (server = the
// workspace name, database = "LH_X"), a cross-workspace read (database =
// "OtherWs.LH_X"), and a reference to the Fabric item itself
// (qualified_name "Ws / Lakehouse / LH_X"). All four collapse onto one
// canonical workspace+name identity -- always workspace-qualified, so the
// DEV and PRO twins of a same-named lakehouse stay strictly separate.
// A Lakehouse and its SQLEndpoint item are the same storage, hence the
// sqlendpoint alternative in the item pattern.
function planningFabricStoreIdentity(source) {
  // Only Fabric STORAGE reads/writes get a canonical store identity. An
  // ExternalAPI/SharePoint/connector source often carries the notebook's
  // own workspace in its server field (parser context, not a location) --
  // treating "workspace + SampleLearningPlatform" as a lakehouse identity merged
  // an external API into the Fabric store graph. Seen live 2026-07-17.
  if (planningNormalizedSourceType(source.source_type) !== 'fabric_internal') return '';
  if (source.fabric_store_workspace && source.database) {
    return `store|fabricitem|${normalize(source.fabric_store_workspace)}|${normalize(source.database)}`;
  }
  const workspaceNames = planningWorkspaceNameSet();
  const server = normalize(source.server);
  const database = text(source.database).trim();
  if (server && database && workspaceNames.has(server)) {
    const dot = database.indexOf('.');
    if (dot > 0 && workspaceNames.has(normalize(database.slice(0, dot)))) {
      const dottedWorkspace = normalize(database.slice(0, dot));
      const dottedName = normalize(database.slice(dot + 1));
      return `store|fabricitem|${planningResolveStoreOwner(dottedWorkspace, dottedName)}|${dottedName}`;
    }
    const storeName = normalize(database);
    return `store|fabricitem|${planningResolveStoreOwner(server, storeName)}|${storeName}`;
  }
  const itemMatch = /^(.+?) \/ (lakehouse|warehouse|sqlendpoint) \/ (.+)$/i.exec(text(source.qualified_name).trim());
  if (itemMatch) return `store|fabricitem|${normalize(itemMatch[1])}|${normalize(itemMatch[3])}`;
  return '';
}

function planningObjectDependencyKey(source, object) {
  return [
    planningNormalizedSourceType(object.source_type || source.source_type),
    // object.server is where the explorer-JSON object nodes carry the real
    // hostname (11_build_lineage_explorer_fast.py); source_server only
    // exists on impact-board object shapes. Without it, every external
    // database's dbo.X collapsed onto the same server-less key.
    object.source_server || object.server || source.server,
    object.source_database || object.database || source.database,
    object.schema || object.schema_name,
    object.object_name || object.name || object.label
    // object_type (table/view/native_query_object/...) is deliberately left
    // out of identity -- it's a confidence/resolution-source label for how
    // sure the scanner is about the object's kind, not part of what object
    // it is, and including it made the exact same table fail to match itself
    // whenever the two sides resolved its type with different confidence.
  ].map(value => normalize(value)).join('|');
}

// Server+database naming rarely lines up between how a notebook's Spark
// write records its target lakehouse and how a semantic model's TMDL/M
// query records the SQL analytics endpoint it reads the same lakehouse
// through -- in practice only a tiny fraction of read references in a
// workspace match on the exact key above, while most match on
// schema+object_name alone. A schema+object_name-only key recovers most
// of the real, missed connections; it's real enough to act on but loose
// enough that two unrelated lakehouses with a same-named generic table
// could coincidentally collide, so callers mark edges built from this key
// as 'likely', never 'confirmed' -- see planningDependencyKeysForSource.
function planningLooseObjectDependencyKey(object) {
  const objectName = object.object_name || object.name || object.label;
  return ['name', object.schema || object.schema_name, objectName].map(value => normalize(value)).join('|');
}

// An object name that is still a literal `{template_variable}` was never
// resolved by the scanner to a real table -- matching on it as if it were
// one produces a dependency between whichever items happen to share the
// same *parameter name* in their notebook code (e.g. every notebook that
// calls its destination `{dest_table}`), not items that actually touch the
// same data. isGenericNotebookSourceLabel already recognizes the other
// unresolved-marker text ("Destino pendiente", "Unresolved target", ...);
// this adds the bracket-placeholder shape on top of that.
function isUnresolvedDependencyObjectName(value) {
  const trimmed = text(value).trim();
  if (!trimmed) return true;
  if (/^\{.*\}$/.test(trimmed)) return true;
  return isGenericNotebookSourceLabel(trimmed);
}

// A source whose own label/database is just its connector's type name
// ("FabricOrSQL" pointing at database "FabricOrSQL", "File" pointing at
// database "File", with no server) identifies *a kind of connection*, not
// a specific system -- every notebook that happens to use the same
// generic connector type would otherwise collide on this one broad key,
// even though the real objects underneath (source.objects, matched
// separately below) are genuinely distinct tables. Skip the broad key in
// that case and rely on the per-object keys instead, which is exactly
// what real per-table matching needs anyway.
function isGenericConnectorSource(source) {
  if (source.server) return false;
  const type = normalize(source.source_type);
  if (!type) return false;
  return normalize(source.label) === type || normalize(source.database) === type;
}

// Returns [{key, confidence}] instead of plain strings: a match built from
// the loose schema+object_name fallback is real enough to act on but never
// as trustworthy as a full server+database+schema+object_name match, so it
// carries its own 'likely' ceiling independent of whatever confidence the
// source record itself claims (see buildPlanningGraph's ref.confidence).
function planningDependencyKeysForSource(source) {
  const keys = new Map();
  const addKey = (key, confidence) => {
    if (!key || !key.replace(/\|/g, '')) return;
    const existing = keys.get(key);
    if (!existing || (existing === 'likely' && confidence === 'confirmed')) keys.set(key, confidence);
  };
  const broadKey = sourceKey(source);
  const skipBroadKey = isGenericNotebookSourceLabel(source.label) || isGenericConnectorSource(source);
  if (!skipBroadKey) addKey(`source:${broadKey}`, 'confirmed');
  const canonicalStore = planningFabricStoreIdentity(source);
  for (const object of asList(source.objects)) {
    const rawName = object.object_name || object.name || object.label;
    if (isUnresolvedDependencyObjectName(rawName)) continue;
    const objectServer = text(object.source_server || object.server || source.server).trim();
    const objectDatabase = text(object.source_database || object.database || source.database).trim();
    if (canonicalStore && (!objectDatabase || normalize(objectDatabase) === normalize(source.database))) {
      // The source resolves to a canonical Fabric store: key the table by
      // THAT identity, not by the raw server string. A model's endpoint
      // read and a notebook's write of the same lakehouse table spell the
      // server differently (endpoint host vs workspace name), so their raw
      // full keys could never match even though it is the same physical
      // table -- otherwise every silver-lakehouse loader stays invisible
      // upstream of the models that read it.
      addKey(`object:${canonicalStore}|${normalize(object.schema || object.schema_name)}|${normalize(rawName)}`, 'confirmed');
    } else if (objectServer || objectDatabase) {
      // A "full" key with neither server nor database is really just
      // type+schema+name -- no stronger than the loose fallback below, yet
      // it matched as 'confirmed': exactly how the shared control-framework
      // tables (control.EntityConfig/Status/TableStatus, read+written by
      // every ingestion notebook) fully interconnected large numbers of
      // unrelated notebooks. Anonymous objects participate only via the
      // loose key.
      addKey(`object:${planningObjectDependencyKey(source, object)}`, 'confirmed');
    }
    // The loose schema+name fallback exists to bridge Fabric-internal
    // naming mismatches (a notebook's Spark write vs a model's SQL-
    // analytics-endpoint read of the same Delta table -- see
    // planningLooseObjectDependencyKey). An object carrying a real
    // non-Fabric hostname is a different physical system from any
    // lakehouse: a generic table name ("PRODUCTO", "CLIENTE") shared with
    // one is a coincidence, not lineage. These cross-system name matches
    // alone can pull hundreds of unrelated notebooks into a small
    // workspace's planning canvas and freeze the browser. Across
    // a real system boundary only the full server+database key counts.
    // A server that is a known WORKSPACE name is Fabric-internal too --
    // that is how notebook write targets are recorded. The source TYPE must
    // also be Fabric storage: an ExternalAPI's "users"/"products" endpoints
    // are not lakehouse tables, however identical the names look.
    const objectSourceType = planningNormalizedSourceType(object.source_type || source.source_type);
    if (objectSourceType === 'fabric_internal' &&
        (!objectServer || PLANNING_FABRIC_SQL_HOST_PATTERN.test(objectServer) || planningWorkspaceNameSet().has(normalize(objectServer)))) {
      addKey(`loose:${planningLooseObjectDependencyKey(object)}`, 'likely');
    }
  }
  return Array.from(keys, ([key, confidence]) => ({ key, confidence }));
}

function sourceUsageCounts(source) {
  const counts = { reads: 0, writes: 0, executes: 0, references: 0 };
  for (const object of asList(source.objects)) {
    if (object.usage_type === 'reads_from') counts.reads += 1;
    else if (object.usage_type === 'writes_to') counts.writes += 1;
    else if (object.usage_type === 'executes') counts.executes += 1;
    else counts.references += 1;
  }
  return counts;
}

function sourceEvidenceImpliesWrite(source) {
  return /target fabric item|target item|destination|sink|writes?_to|write/i.test(`${source.evidence || ''} ${source.qualified_name || ''}`);
}

function sourcePlanningUsage(source, item) {
  const copyJobRole = copyJobSourceRole(source, item);
  if (copyJobRole) return copyJobRole;
  const counts = sourceUsageCounts(source);
  if (counts.reads && counts.writes) return 'readWrite';
  if (counts.writes) return 'write';
  if (counts.reads) return 'read';
  if (counts.executes) return 'execute';
  if (sourceEvidenceImpliesWrite(source)) return 'write';
  if (item && item.item_type === 'SemanticModel') return 'read';
  return counts.references ? 'reference' : 'read';
}

function sourceIsFabricStore(source) {
  return source.item_type === 'Lakehouse' ||
    source.item_type === 'Warehouse' ||
    source.item_type === 'SQLEndpoint' ||
    source.item_type === 'SQL Endpoint' ||
    source.source_type === 'Fabric';
}

function planningSourceRoleLabel(source) {
  const role = source.planning_role || source.planning_usage || '';
  if (role === 'output') return state.lang === 'es' ? 'Dato escrito' : 'Written data';
  if (role === 'input') return state.lang === 'es' ? 'Entrada leída' : 'Read input';
  return state.lang === 'es' ? 'Dato referenciado' : 'Referenced data';
}

// Planning simulates a Fabric pipeline canvas, so it must only show items
// that can actually be invoked as a pipeline activity: Notebook/CopyJob/
// Dataflow activities, plus SemanticModel (invoked via a "Refresh semantic
// model" activity, not the model itself). Passive types (Report, Dashboard,
// Lakehouse, Eventstream, UserDataFunction, ...) are excluded -- they
// cannot be a step in a pipeline's execution order.
//
// DataPipeline itself is deliberately excluded too: a pipeline node next to
// the very notebooks/copyjobs it invokes just duplicates the same work
// twice in the diagram. pipeline_activity_dependency_edges already resolves
// the real Succeeded/Failed/Completed order directly between the invoked
// items (see buildPlanningGraph), so the pipeline wrapper node adds nothing
// but clutter.
const PLANNING_INVOKABLE_ITEM_TYPES = ['CopyJob', 'Notebook', 'Dataflow'];

function isPlanningCanvasItem(item) {
  const type = item && item.item_type;
  return type === 'SemanticModel' || PLANNING_INVOKABLE_ITEM_TYPES.includes(type);
}

function planningStageForItem(item) {
  return item && item.item_type === 'SemanticModel' ? 'model' : 'process';
}

function planningKindForItem(item) {
  if (item.item_type === 'DataPipeline') return 'pipeline';
  if (['Report', 'PaginatedReport', 'Dashboard', 'KQLDashboard'].includes(item.item_type)) return 'report';
  return 'item';
}

function planningRiskClasses(data) {
  const planning = data && data.planning ? data.planning : {};
  return [
    planning.critical_path ? ' planning-critical' : '',
    planning.failure_hotspot ? ' planning-failure' : '',
    Number(planning.parallel_candidate_count || 0) > 0 ? ' planning-parallel' : '',
    planning.schedule_review ? ' planning-scheduled' : ''
  ].join('');
}

function planningBadges(data) {
  const planning = data && data.planning ? data.planning : {};
  const execution = data && data.execution ? data.execution : {};
  return [
    planning.critical_path ? `${t('planning.critical')} #${planning.critical_rank || ''}`.trim() : '',
    planning.failure_hotspot ? `${t('planning.failure')} ${planning.failure_rate || ''}`.trim() : '',
    Number(planning.parallel_candidate_count || 0) > 0 ? `${planning.parallel_candidate_count} ${t('planning.parallel')}` : '',
    planning.schedule_review || Number(execution.enabled_schedules || 0) > 0 ? t('planning.scheduled') : ''
  ].filter(Boolean);
}

function planningCardSubtext(node) {
  const data = node.data || {};
  const execution = data.execution || {};
  if (node.kind === 'source') {
    const counts = sourceUsageCounts(data);
    const objectText = asList(data.objects).length ? `${number(asList(data.objects).length)} ${t('objects')}` : '';
    const usageText = [
      counts.reads ? `${number(counts.reads)} ${t('planning.readEdge')}` : '',
      counts.writes ? `${number(counts.writes)} ${t('planning.writeEdge')}` : '',
      counts.references ? `${number(counts.references)} ${t('planning.referenceEdge')}` : ''
    ].filter(Boolean).join(' · ');
    return [
      planningSourceRoleLabel(data),
      sourceTypeDisplay(data.source_type),
      data.database || data.server || '',
      objectText,
      usageText
    ].filter(Boolean).join(' · ');
  }
  const realisticDuration = planningRealisticDurationSeconds(execution);
  return [
    nodeSubtext(node),
    realisticDuration ? `${t('planning.avg')} ${formatDuration(realisticDuration)}` : '',
    execution.failed_runs ? `${execution.failed_runs} ${t('planning.failShort')}` : ''
  ].filter(Boolean).join(' · ');
}

// Sizes the card around the LABEL only, not the subtext: a source node's
// subtext (role · type · database · object count · usage) is often much
// longer and more variable than any label, and estimateTextWidth is only a
// length*avgCharWidth guess, not a real measurement -- sizing the card to
// fit that guessed subtext width on one line let it under-estimate real
// rendered width for some strings, and since CSS's own `max-width: 420px`
// on .planning-card then clamped the card back down anyway, the subtext
// span was left wider than its actual box, spilling text past the card
// border (read live 2026-07-20). Not including it here means the subtext
// simply wraps onto more lines within whatever width the label needs
// instead -- taller cards sometimes, but never overflowing them.
function planningCardWidth(node, subtext, badges) {
  const labelWidth = estimateTextWidth(node.label, 7.4);
  const badgeWidth = badges.reduce((sum, badge) => sum + estimateTextWidth(badge, 5.9) + 18, 0);
  const chrome = 82 + badgeWidth;
  return clamp(Math.ceil(labelWidth + chrome), 260, 420);
}

// Set by renderPlanningCanvas on every render so the drag handler below can
// re-draw edges live without needing every card to carry its own copy of
// the full edge list.
let planningLiveEdges = [];
let planningLiveNodesById = new Map();
// Planning's own independent zoom target -- see the comment in
// renderPlanningCanvas where these get assigned for why it can't share
// els.treeStage's zoom with the other views.
let planningZoomWrapper = null;
let planningZoomCanvas = null;
let planningNaturalSize = { width: 200, height: 200 };

function applyPlanningNodeOffset(button, node) {
  const offset = state.planningNodePositions.get(node.key);
  if (!offset) return;
  button.style.transform = `translate(${offset.dx}px, ${offset.dy}px)`;
  button.classList.add('planning-card-moved');
}

// Free-form dragging: the user asked for the ability to move a card
// anywhere and have the lines follow, then snap back to the computed
// layout with the reset button. Cards stay in their normal grid position
// (base layout untouched) and dragging only adds a CSS transform offset on
// top -- renderPlanningEdges already measures live getBoundingClientRect(),
// so it picks up the transformed position for free once re-invoked.
function attachPlanningCardDrag(button, node) {
  let moved = false;
  let startX = 0;
  let startY = 0;
  let baseOffset = { dx: 0, dy: 0 };
  let redrawQueued = false;

  function queueEdgeRedraw() {
    if (redrawQueued) return;
    redrawQueued = true;
    requestAnimationFrame(() => {
      redrawQueued = false;
      const board = button.closest('.planning-board');
      if (board) renderPlanningEdges(board, planningLiveEdges);
    });
  }

  // Pointer deltas arrive in screen pixels, but the stored offset (and the
  // translate() applied below) needs to be in the same natural, unscaled
  // units everything else in Planning uses -- getCardNaturalRect adds this
  // offset straight onto offsetLeft/Top with no further scaling, since the
  // ambient transform: scale() on .planning-canvas already scales it
  // visually along with everything else once. Without dividing by the
  // current zoom here, a drag at 2x zoom would move a card twice as far
  // (in natural units, hence visually 4x as far) as the mouse actually
  // moved.
  // getCardNaturalRect (used by renderPlanningEdges) reads a card's drag
  // offset from state.planningNodePositions, not from the live CSS
  // transform -- so that map has to be kept current on every pointermove,
  // not just committed once at pointerup. Committing only at the end made
  // the edges track one whole drag gesture behind: mid-drag they still
  // reflected wherever the *previous* drag had left off, and only caught
  // up to where THIS drag actually ended once you started dragging again.
  function onPointerMove(event) {
    const scale = state.view.scale || 1;
    const dx = (event.clientX - startX) / scale;
    const dy = (event.clientY - startY) / scale;
    if (Math.abs(dx) > 3 || Math.abs(dy) > 3) moved = true;
    const next = { dx: baseOffset.dx + dx, dy: baseOffset.dy + dy };
    button.style.transform = `translate(${next.dx}px, ${next.dy}px)`;
    button.classList.add('planning-card-moved', 'planning-card-dragging');
    state.planningNodePositions.set(node.key, next);
    queueEdgeRedraw();
  }

  function onPointerUp() {
    document.removeEventListener('pointermove', onPointerMove);
    document.removeEventListener('pointerup', onPointerUp);
    button.classList.remove('planning-card-dragging');
    if (moved && els.planningResetLayoutButton) els.planningResetLayoutButton.hidden = false;
  }

  button.addEventListener('pointerdown', event => {
    if (event.button !== 0) return;
    moved = false;
    startX = event.clientX;
    startY = event.clientY;
    const existing = state.planningNodePositions.get(node.key);
    baseOffset = existing ? { ...existing } : { dx: 0, dy: 0 };
    document.addEventListener('pointermove', onPointerMove);
    document.addEventListener('pointerup', onPointerUp);
  });

  button.addEventListener('click', event => {
    if (moved) {
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    togglePlanningSelection(node, event);
  });
}

// A card that's already selected deselects on the next click instead of
// staying stuck selected forever, and holding shift/ctrl/cmd adds to or
// removes from the selection instead of replacing it -- a plain click still
// replaces the selection with just that one card, matching how selection
// works everywhere else in the app. `moved` (see attachPlanningCardDrag)
// already guarantees this never fires for an actual drag.
function togglePlanningSelection(node, event) {
  const additive = Boolean(event && (event.shiftKey || event.ctrlKey || event.metaKey));
  const ids = state.planningSelectedIds;
  const index = ids.indexOf(node.id);
  if (additive) {
    if (index === -1) ids.push(node.id);
    else ids.splice(index, 1);
  } else if (index !== -1 && ids.length === 1) {
    ids.length = 0;
  } else {
    ids.length = 0;
    ids.push(node.id);
  }

  if (ids.length) {
    const lastId = ids[ids.length - 1];
    const lastNode = lastId === node.id ? node : (planningLiveNodesById.get(lastId) || node);
    state.selectedNode = lastNode;
    renderDetails(lastNode);
  } else {
    state.selectedNode = null;
    detailNoSelection();
  }
  renderTree();
}

function resetPlanningLayout() {
  state.planningNodePositions.clear();
  if (els.planningResetLayoutButton) els.planningResetLayoutButton.hidden = true;
  renderTree();
}

function planningCard(node) {
  const button = document.createElement('button');
  const selectedClass = state.planningSelectedIds.includes(node.id) ? ' selected' : '';
  button.className = `node-card planning-card ${nodeClass(node.kind || 'item')} ${nodeTypeClass(node)} planning-stage-${node.stage || 'process'}${planningRiskClasses(node.data)}${selectedClass}`;
  button.type = 'button';
  button.dataset.planId = node.id;
  button.dataset.label = node.label || '';
  button.dataset.wave = node.wave || 0;
  const badges = planningBadges(node.data);
  const subtext = planningCardSubtext(node);
  button.style.width = `${planningCardWidth(node, subtext, badges)}px`;
  button.innerHTML = `
    <span class="ms-icon ${iconClassForNode(node)}" aria-hidden="true"></span>
    <span class="node-main"><strong>${escapeHtml(node.label)}</strong><span>${escapeHtml(subtext)}</span></span>
    <span class="planning-badges">${badges.slice(0, 2).map(badge => `<i>${escapeHtml(badge)}</i>`).join('')}</span>
  `;
  button.setAttribute('aria-label', [node.label, subtext, ...badges].filter(Boolean).join(', '));
  applyPlanningNodeOffset(button, node);
  attachPlanningCardDrag(button, node);
  return button;
}

function addPlanningEdge(edges, fromId, toId, type, confidence = 'candidate') {
  if (!fromId || !toId || fromId === toId) return null;
  const existing = edges.find(edge => edge.fromId === fromId && edge.toId === toId && edge.type === type);
  if (existing) {
    // Several per-table matches can land on one drawn edge -- if any of
    // them is confirmed, the edge is.
    if (existing.confidence !== 'confirmed' && confidence === 'confirmed') existing.confidence = 'confirmed';
    return existing;
  }
  const edge = { fromId, toId, type, confidence };
  edges.push(edge);
  return edge;
}

// Most data-dependency edges render as neutral gray, but a table a
// semantic model reads is not optional: if anything upstream of it fails
// to run, the report built on that model goes stale or wrong. Walk
// backward from every writer->SemanticModel edge through the chain of
// write/read edges that feeds it and mark the whole chain, not just the
// last hop, so it reads as green the same way the model's the direct
// source does. This only re-colors inferred data-lineage edges
// ('dependency'/'model') -- the real pipeline Succeeded/Failed/Completed
// edges keep their own, separately-earned meaning.
function markDataEdgesRequiredForModels(edges) {
  const incomingDataEdgesByNode = new Map();
  for (const edge of edges) {
    // Data lineage now hops through store nodes (item -write-> store
    // -read/model-> item), so the backward walk must traverse those hop
    // types too, not just the old direct item->item 'dependency' edges.
    if (!['dependency', 'model', 'read', 'write'].includes(edge.type)) continue;
    if (!incomingDataEdgesByNode.has(edge.toId)) incomingDataEdgesByNode.set(edge.toId, []);
    incomingDataEdgesByNode.get(edge.toId).push(edge);
  }
  const criticalEdges = new Set(edges.filter(edge => edge.type === 'model'));
  const queue = [...criticalEdges];
  const visitedNodes = new Set();
  while (queue.length) {
    const edge = queue.shift();
    if (visitedNodes.has(edge.fromId)) continue;
    visitedNodes.add(edge.fromId);
    for (const upstreamEdge of incomingDataEdgesByNode.get(edge.fromId) || []) {
      if (!criticalEdges.has(upstreamEdge)) {
        criticalEdges.add(upstreamEdge);
        queue.push(upstreamEdge);
      }
    }
  }
  for (const edge of criticalEdges) {
    edge.type = 'dataRequiredForModel';
  }
}

// Notebook A calling notebook B directly (%run / mssparkutils.notebook.run,
// often a shared "Common_Utils"-style helper) is not something a Fabric
// pipeline schedules or orders -- it is implementation detail inside
// whatever invokes A. Only items a real pipeline activity actually invokes
// belong in Planning; otherwise helper notebooks that are never a pipeline
// step of their own show up as if they needed independent scheduling.
// A Notebook/CopyJob/Dataflow belongs on the planning canvas *by itself*
// (i.e. while disconnected from everything else in view) only when it
// actually produces something -- a plain read (a config lookup, a
// credentials file, a parameter list) never feeds anything downstream on
// its own; only a write does. Without this, read-only setup/helper
// notebooks -- "Common_Utils" (%run-included into other notebooks,
// mapping workspace/connection config) or "Credentials" (reading a
// secrets file so other notebooks can authenticate) are real examples
// found in this data -- show up as fully isolated boxes with zero edges:
// pure clutter that looks like an orphaned pipeline step when it is
// really just implementation plumbing nothing here schedules on its own.
// A genuine write is still enough to justify staying even with no
// connections yet (e.g. an ingestion step nothing visible reads from
// yet); notebook_super_lineage_only sources (the %run-inlined footprint
// itself) never count either way, since that footprint already belongs
// to whichever notebook actually called %run.
function planningItemHasRealSources(item) {
  return asList(item && item.sources).some(source => {
    if (source.notebook_super_lineage_only) return false;
    const usage = sourcePlanningUsage(source, item);
    return usage === 'write' || usage === 'readWrite';
  });
}

// planningItemHasRealSources demands a write footprint, which a semantic
// model never has (models only read) -- the seed-model keep rule in
// buildPlanningGraph's pruning pass needs "does this model read anything
// real at all" instead.
function planningSeedModelHasSources(item) {
  return asList(item && item.sources).some(source => !source.notebook_super_lineage_only);
}

// The tenant-wide half of buildPlanningGraph -- deduping every item in the
// tenant and, for each one, computing its dependency keys (source-type
// normalization, regex-based loose-key matching, connector-label checks --
// see planningDependencyKeysForSource) -- does NOT depend on `selected` at
// all, yet buildPlanningGraph used to redo it from scratch on every single
// call: once for the embedded canvas's own render, then AGAIN when the
// planning map popup opens (it calls buildPlanningGraph independently), and
// again on every workspace-selection change while Planning stays open.
// A scope of every DEV workspace plus a large ingestion workspace could
// freeze the embedded canvas and leave the popup showing nothing while
// this ran. Caching the tenant-wide part -- keyed by
// state.data's own identity, which is replaced wholesale on every data
// (re)load, never mutated in place, same invalidation pattern already used
// by planningWorkspaceNameSet/planningStoreOwnersByName above -- turns
// every call after the first into just the cheap, scope-dependent part
// (iterate the pool, look up each item's already-computed entries, run the
// union-find/closure). Output is unchanged; only WHEN the expensive string
// work happens moves, from "every call" to "once per data load."
let planningTenantIndexForData = null;
let planningTenantIndexCache = null;
function planningTenantIndex() {
  if (planningTenantIndexForData === state.data && planningTenantIndexCache) return planningTenantIndexCache;
  const matchPoolItems = uniqueBy(
    (state.data.workspaces || []).flatMap(workspace => asList(workspace.all)),
    item => planningNodeKey(item)
  );
  const entriesByItemKey = new Map();
  for (const item of matchPoolItems) {
    const itemKey = planningNodeKey(item);
    if (!itemKey) continue;
    const entries = [];
    for (const source of asList(item.sources)) {
      if (source.notebook_super_lineage_only) continue;
      const usage = sourcePlanningUsage(source, item);
      for (const { key, confidence: keyConfidence } of planningDependencyKeysForSource(source)) {
        entries.push({
          source,
          usage,
          key,
          confidence: keyConfidence === 'likely' ? 'likely' : (source.confidence || 'confirmed')
        });
      }
    }
    entriesByItemKey.set(itemKey, entries);
  }
  planningTenantIndexForData = state.data;
  planningTenantIndexCache = { matchPoolItems, entriesByItemKey };
  return planningTenantIndexCache;
}

function buildPlanningGraph(selected) {
  const itemMap = new Map();
  const edges = [];
  const allItems = uniqueBy(
    selected.flatMap(workspace => asList(workspace.all)),
    item => planningNodeKey(item)
  );
  // A semantic model's own workspace is often report-only (see e.g. "CRM"/
  // "Sales Dashboards" vs the real production data workspaces
  // "Datamart-CRM_Contoso_Pro"/"Datamart-Sales_Contoso_Pro") -- the
  // CopyJobs/Notebooks that actually feed it live in a completely different
  // workspace the user has no way to know to pre-select. Matching read/write
  // keys only within `selected` therefore came up empty even when a real
  // upstream chain exists. Build the match pool from every workspace
  // instead; the "drop isolated items" pass further down still prunes
  // anything that doesn't end up on a real edge, so this can't flood the
  // canvas with unrelated tenant-wide noise -- it only pulls in items that
  // turn out to genuinely read/write something `selected` also touches.
  const { matchPoolItems, entriesByItemKey } = planningTenantIndex();

  function ensureItem(item, stage = planningStageForItem(item)) {
    if (!isPlanningCanvasItem(item)) return null;
    const key = planningNodeKey(item);
    if (!key) return null;
    if (!itemMap.has(key)) {
      itemMap.set(key, {
        id: `planning:item:${itemMap.size}`,
        key,
        kind: planningKindForItem(item),
        label: item.label,
        data: item,
        stage: stage || planningStageForItem(item)
      });
    }
    const node = itemMap.get(key);
    if (stage === 'model' || stage === 'process') node.stage = stage;
    return node;
  }

  for (const item of allItems) {
    if (isPlanningCanvasItem(item)) ensureItem(item);
  }
  // Captured before matchPoolItems below adds any tenant-wide item pulled in
  // by a real read/write match -- used further down to keep only pool items
  // that actually connect back to what the user selected, instead of
  // letting two unrelated workspaces that coincidentally share a generic
  // object key clutter the canvas with a chain neither seed touches.
  const seedNodeIds = new Set(Array.from(itemMap.values()).map(node => node.id));

  const readRefsByKey = new Map();
  const writeRefsByKey = new Map();
  const addDependencyRef = (map, key, ref) => {
    if (!key || !ref.node) return;
    if (!map.has(key)) map.set(key, []);
    const rows = map.get(key);
    if (!rows.some(row => row.node.id === ref.node.id)) rows.push(ref);
  };

  for (const item of matchPoolItems) {
    const itemNode = ensureItem(item);
    if (!itemNode) continue;
    const entries = entriesByItemKey.get(planningNodeKey(item));
    if (entries) {
      for (const entry of entries) {
        const ref = { item, node: itemNode, source: entry.source, usage: entry.usage, confidence: entry.confidence };
        if (entry.usage === 'write' || entry.usage === 'readWrite') addDependencyRef(writeRefsByKey, entry.key, ref);
        if (entry.usage !== 'write') addDependencyRef(readRefsByKey, entry.key, ref);
      }
    }
    for (const executed of asList(item.executes)) {
      const targetNode = ensureItem(executed);
      if (targetNode) addPlanningEdge(edges, itemNode.id, targetNode.id, 'execute', executed.confidence || 'confirmed');
    }
  }

  // Real Succeeded/Failed/Completed execution order between two invokable
  // items, resolved backend-side from the pipeline's own activity dependsOn
  // chain (see 11_build_lineage_explorer.ps1). Unlike the write/read-derived
  // edges below (which only infer "these happen to touch the same table"),
  // these edges mirror the actual conditional branching a Fabric pipeline
  // canvas would show.
  for (const conditionEdge of asList(state.data && state.data.pipeline_activity_dependency_edges)) {
    const fromNode = itemMap.get(normalize(conditionEdge.from_item_qualified_name));
    const toNode = itemMap.get(normalize(conditionEdge.to_item_qualified_name));
    if (!fromNode || !toNode) continue;
    const edgeType = conditionEdge.condition === 'failed' ? 'controlFlowFailed'
      : conditionEdge.condition === 'succeeded' ? 'controlFlowSucceeded'
      : 'controlFlowCompleted';
    addPlanningEdge(edges, fromNode.id, toNode.id, edgeType, 'confirmed');
  }

  // Data dependencies are drawn THROUGH the data store, Data-Factory-style
  // (user ask, 2026-07-16): external origin -> notebook/copyjob -> lakehouse
  // -> semantic model, left to right, instead of invisible stores and a
  // direct writer->reader edge. Besides matching how a real pipeline canvas
  // reads, this turns each shared table's write*read cross-product (w*r
  // edges, quadratic -- the old shape) into w+r edges through one store
  // node, and it finally SHOWS the origin of models nothing in Fabric
  // feeds (e.g. an external SQL Server database), which previously drew as
  // nothing at all.
  //
  // The same physical store is often recorded with different
  // server/database strings on its write side (a notebook's Spark write)
  // and its read side (a model's SQL-analytics-endpoint query) -- the very
  // mismatch the loose dependency keys exist for. A union-find over source
  // identities, merged per matched key, folds those spellings into one
  // store node instead of drawing two disconnected copies.
  const storeParent = new Map();
  const storeSampleByIdentity = new Map();
  // Canonical Fabric store spellings -- see planningFabricStoreIdentity
  // (top-level; also used for canonical per-table dependency keys).
  function storeIdentityForSource(source) {
    const identity = planningFabricStoreIdentity(source) || [
      'store',
      normalize(source.source_type),
      normalize(source.workspace_name),
      normalize(source.server),
      normalize(source.database),
      normalize(source.label),
      normalize(source.qualified_name)
    ].join('|');
    if (!storeSampleByIdentity.has(identity)) storeSampleByIdentity.set(identity, source);
    if (!storeParent.has(identity)) storeParent.set(identity, identity);
    return identity;
  }
  function storeFind(id) {
    let root = id;
    while (storeParent.get(root) !== root) root = storeParent.get(root);
    let current = id;
    while (storeParent.get(current) !== current) {
      const next = storeParent.get(current);
      storeParent.set(current, root);
      current = next;
    }
    return root;
  }
  const isCanonicalStoreIdentity = identity => identity.startsWith('store|fabricitem|');
  function storeUnion(a, b) {
    const rootA = storeFind(a);
    const rootB = storeFind(b);
    if (rootA === rootB) return;
    // Two distinct canonical stores are genuinely different storage (each
    // workspace-qualified) -- refuse the merge no matter how the request
    // arrives, including transitively through a shared unknown-spelling
    // identity (an unknown that name-matches tables in two lakehouses used
    // to chain them together -- 243 identities collapsed into one
    // mega-store, seen live 2026-07-17). Canonical roots always stay
    // roots, so this invariant holds across any union order.
    const canonicalA = isCanonicalStoreIdentity(rootA);
    const canonicalB = isCanonicalStoreIdentity(rootB);
    if (canonicalA && canonicalB) return;
    if (canonicalA) {
      storeParent.set(rootB, rootA);
      return;
    }
    storeParent.set(rootA, rootB);
  }

  // A loose schema+name key shared by more than this many distinct items is
  // a generic name ("status", "person", "dest_table") or a control-framework
  // table every notebook touches -- not one physical table. Matching on it
  // would also union unrelated stores into one node, so it steps aside and
  // only real full server+database matches connect those items.
  const PLANNING_LOOSE_KEY_HUB_LIMIT = 16;
  const storeEdgeIntents = [];
  const allDependencyKeys = new Set([...writeRefsByKey.keys(), ...readRefsByKey.keys()]);
  for (const key of allDependencyKeys) {
    const writers = writeRefsByKey.get(key) || [];
    const readers = readRefsByKey.get(key) || [];
    if (key.startsWith('loose:') && writers.length + readers.length > PLANNING_LOOSE_KEY_HUB_LIMIT) continue;
    const identities = [];
    for (const ref of [...writers, ...readers]) identities.push(storeIdentityForSource(ref.source));
    // storeUnion itself refuses to merge two distinct canonical stores (see
    // its comment), so plain pairwise unions are safe here for every key
    // kind -- a loose match folds unknown spellings into a canonical store
    // but can never chain two canonical stores together.
    for (let index = 1; index < identities.length; index += 1) storeUnion(identities[0], identities[index]);
    for (const ref of writers) {
      storeEdgeIntents.push({ ref, key, identity: storeIdentityForSource(ref.source), direction: 'write' });
    }
    for (const ref of readers) {
      // readWrite already produces the write edge above; drawing the read
      // direction too would put an impossible item<->store loop on the
      // canvas (same rationale as the old mutual-pair drop).
      if (ref.usage === 'readWrite') continue;
      storeEdgeIntents.push({ ref, key, identity: storeIdentityForSource(ref.source), direction: 'read' });
    }
  }

  const storeNodeByRoot = new Map();
  function ensureStoreNode(identity) {
    const root = storeFind(identity);
    if (storeNodeByRoot.has(root)) return storeNodeByRoot.get(root);
    // Merged spellings of one store: prefer the sample that names a real
    // Fabric item (Lakehouse/Warehouse/SQLEndpoint), then whichever knows
    // its server/database -- that's the label a person recognizes.
    let best = null;
    let bestScore = -1;
    for (const [id, sample] of storeSampleByIdentity.entries()) {
      if (storeFind(id) !== root) continue;
      const isFabricStoreItem = sample.item_type === 'Lakehouse' || sample.item_type === 'Warehouse' || sample.item_type === 'SQLEndpoint';
      const score = (isFabricStoreItem ? 4 : 0) + (sample.server ? 2 : 0) + (sample.database ? 1 : 0);
      if (score > bestScore) {
        best = sample;
        bestScore = score;
      }
    }
    // A canonical Fabric store is drawn as the STORAGE it is, never as the
    // connection that happens to reach it (user ask 2026-07-17: a
    // "LH_..._Nube" cloud-connection name on the card reads as a
    // connection, which belongs in the model's detail panel, not the
    // diagram) -- the database field carries the real lakehouse/warehouse
    // name; a dotted cross-workspace spelling keeps only the item part.
    let label = (best && (best.label || best.database || best.server)) || t('unknown');
    if (isCanonicalStoreIdentity(root) && best && best.database) {
      const database = text(best.database).trim();
      label = database.includes('.') ? database.slice(database.indexOf('.') + 1) : database;
    }
    const node = {
      id: `planning:store:${storeNodeByRoot.size}`,
      key: root,
      kind: 'source',
      label,
      data: best || {},
      stage: 'store'
    };
    storeNodeByRoot.set(root, node);
    itemMap.set(root, node);
    return node;
  }

  // A source whose only identity is a parser placeholder ("Origen
  // pendiente", "Destino pendiente", "Objetos ejecutados", "Archivos", an
  // abfss: fragment...) names NOTHING a person can act on -- as canvas
  // cards they read as noise (user report 2026-07-17). Their object detail
  // stays available in Inspeccion; planning simply does not draw a store
  // card for them.
  function planningStoreSourceIsPlaceholder(source) {
    const database = text(source.database).trim();
    // Garbage database names disqualify even a canonical-looking identity:
    // an abfss: path fragment ANYWHERE in the name (including after a
    // "Workspace." prefix) or a bare NA/notebook is parse residue, not a
    // lakehouse someone can recognize.
    if (/abfss:/i.test(database) || /^(na|notebook)$/i.test(database)) return true;
    if (planningFabricStoreIdentity(source)) return false;
    if (!database) return true;
    return isGenericNotebookSourceLabel(source.label);
  }

  for (const intent of storeEdgeIntents) {
    if (planningStoreSourceIsPlaceholder(intent.ref.source)) continue;
    const storeNode = ensureStoreNode(intent.identity);
    let edge = null;
    if (intent.direction === 'write') {
      edge = addPlanningEdge(edges, intent.ref.node.id, storeNode.id, 'write', intent.ref.confidence);
    } else {
      const edgeType = intent.ref.item.item_type === 'SemanticModel' ? 'model' : 'read';
      edge = addPlanningEdge(edges, storeNode.id, intent.ref.node.id, edgeType, intent.ref.confidence);
    }
    // Which tables justify this edge -- consumed by the table-aware
    // reachability pass below, so only writers of the tables a model
    // actually uses count as its upstream, not every writer of the store.
    if (edge) {
      if (!edge.dependency_keys) edge.dependency_keys = new Set();
      edge.dependency_keys.add(intent.key);
    }
  }

  // Medallion naming bridge: within one workspace, "<LH>_Staging" feeds
  // "<LH>" -- that is what the framework's own NB_Shortcut_Staging_to_
  // Silver notebooks do (OneLake shortcuts: pointers, no data movement, so
  // no runtime log and nothing in the shortcuts API to prove the hop; the
  // sample connector DEV silver was the live case). Drawn as a store->store
  // 'likely' edge only when BOTH canonical stores are already on the
  // canvas; the closure treats crossing it as wholesale mirroring.
  for (const [root, node] of storeNodeByRoot.entries()) {
    const stagingMatch = /^store\|fabricitem\|([^|]+)\|(.+)_staging$/.exec(root);
    if (!stagingMatch) continue;
    const mainNode = storeNodeByRoot.get(`store|fabricitem|${stagingMatch[1]}|${stagingMatch[2]}`);
    if (!mainNode) continue;
    addPlanningEdge(edges, node.id, mainNode.id, 'read', 'likely');
  }

  // The old direct writer->reader cross-product needed two cleanup passes
  // here (dropping mutual A<->B pairs from shared readWrite staging tables,
  // and dropping inferred edges contradicted by real control-flow order).
  // Store-mediated edges make both impossible by construction WITHIN one
  // source record: a readWrite source only draws its write side. But an
  // item can read a store through one source record and write it through
  // ANOTHER (NB_Load_Source_LegacySQL reads the source silver in one
  // query and CREATEs bi_sales into it elsewhere), forming a 2-cycle that stalls the topological wave pass:
  // the store never leaves column 0 despite having writers, drawing the
  // exact leftward arrows the layout must never show. Same collapse rule
  // as readWrite: for ordering, the write relation wins -- drop the read
  // back-edge of any such pair.
  {
    const storeIds = new Set(Array.from(storeNodeByRoot.values()).map(node => node.id));
    const writePairKeys = new Set(
      edges.filter(edge => storeIds.has(edge.toId)).map(edge => `${edge.fromId}|${edge.toId}`)
    );
    const withoutReadBacks = edges.filter(edge =>
      !(storeIds.has(edge.fromId) && writePairKeys.has(`${edge.toId}|${edge.fromId}`))
    );
    edges.length = 0;
    edges.push(...withoutReadBacks);
  }

  markDataEdgesRequiredForModels(edges);

  // Drop items that aren't reachable back to the originally selected scope:
  // nothing connects them to it, and (for anything other than a
  // SemanticModel that IS itself part of the original selection) they have
  // no real source of their own either. Notebooks/CopyJobs with a genuine
  // read/write footprint still stay even when disconnected -- that's what
  // used to make items no literal DataPipeline invokes silently vanish from
  // planning. A SemanticModel is different: showing it here is only useful
  // when it actually depends on something else visible in this selection,
  // so it needs a real edge to stay, not just "it has sources" (every model
  // has sources by definition, so that alone would never prune anything and
  // would leave models with no real link to the current scope cluttering
  // the canvas).
  //
  // Reachability (not just "has any edge") matters now that the read/write
  // match pool spans every workspace, not just the selected ones (see
  // matchPoolItems above). It must be DIRECTIONAL now that data hops
  // through shared store nodes: what belongs on the canvas is the seeds'
  // upstream closure (everything that feeds them, walked backward) plus
  // their downstream closure (everything they feed, walked forward). A
  // plain undirected walk through a store also picks up its *sibling
  // readers* -- with a popular external database that meant every model in
  // the tenant reading it (104 of them, seen live) flooding an 11-item
  // workspace's plan. A sibling reader is neither upstream nor downstream
  // of anything selected, so two one-directional walks exclude it.
  //
  // The walks are also TABLE-AWARE at every store hop (user ask,
  // 2026-07-17): a model takes only SOME of a lakehouse's tables, so of the
  // notebooks/copyjobs writing that lakehouse only the ones producing
  // tables the model actually reads are its upstream -- not every writer of
  // the store. Each store edge carries the dependency keys (tables) that
  // justify it; crossing a store keeps only the far-side edges sharing at
  // least one of the keys that made the store relevant. When the near side
  // has no table detail at all (e.g. a model whose read is only known at
  // connection level), the store falls back to "every writer/reader of this
  // store counts" -- the best truth available rather than nothing.
  const storeNodeIdSet = new Set(Array.from(storeNodeByRoot.values()).map(node => node.id));
  const outgoingEdgesByNode = new Map();
  const incomingEdgesByNode = new Map();
  for (const edge of edges) {
    if (!outgoingEdgesByNode.has(edge.fromId)) outgoingEdgesByNode.set(edge.fromId, []);
    outgoingEdgesByNode.get(edge.fromId).push(edge);
    if (!incomingEdgesByNode.has(edge.toId)) incomingEdgesByNode.set(edge.toId, []);
    incomingEdgesByNode.get(edge.toId).push(edge);
  }
  const edgeHasObjectDetail = edge =>
    Array.from(edge.dependency_keys || []).some(key => !key.startsWith('source:'));

  function tableAwareDirectionalClosure(edgesByNearNode, farNodeOf) {
    const relevant = new Set();
    const storeRelevantKeys = new Map();
    const storeBroadRelevant = new Set();
    const queue = Array.from(seedNodeIds);
    while (queue.length) {
      const currentId = queue.shift();
      if (storeNodeIdSet.has(currentId)) {
        const bucket = storeRelevantKeys.get(currentId);
        for (const edge of edgesByNearNode.get(currentId) || []) {
          const farId = farNodeOf(edge);
          if (storeNodeIdSet.has(farId)) {
            // store->store hop (the staging->silver naming bridge): the far
            // store mirrors this one's tables wholesale, and the two sides
            // spell their table keys under different store identities, so
            // per-table filtering cannot cross the bridge -- the far store
            // becomes broadly relevant instead.
            let changed = !relevant.has(farId);
            if (!storeBroadRelevant.has(farId)) {
              storeBroadRelevant.add(farId);
              changed = true;
            }
            relevant.add(farId);
            if (changed) queue.push(farId);
            continue;
          }
          const keys = Array.from(edge.dependency_keys || []);
          const matches = storeBroadRelevant.has(currentId) || (bucket && keys.some(key => bucket.has(key)));
          if (!matches || relevant.has(farId)) continue;
          relevant.add(farId);
          queue.push(farId);
        }
        continue;
      }
      relevant.add(currentId);
      for (const edge of edgesByNearNode.get(currentId) || []) {
        const farId = farNodeOf(edge);
        if (storeNodeIdSet.has(farId)) {
          if (!storeRelevantKeys.has(farId)) storeRelevantKeys.set(farId, new Set());
          const bucket = storeRelevantKeys.get(farId);
          let changed = !relevant.has(farId);
          for (const key of edge.dependency_keys || []) {
            if (!bucket.has(key)) {
              bucket.add(key);
              changed = true;
            }
          }
          if (!edgeHasObjectDetail(edge) && !storeBroadRelevant.has(farId)) {
            storeBroadRelevant.add(farId);
            changed = true;
          }
          relevant.add(farId);
          // Re-visit the store whenever its relevant-key set grew: a table
          // that just became relevant may unlock writers/readers already
          // skipped on an earlier visit.
          if (changed) queue.push(farId);
        } else if (!relevant.has(farId)) {
          // item->item edge (real pipeline control flow / execute): always
          // a genuine execution-order relation, no table filtering needed.
          relevant.add(farId);
          queue.push(farId);
        }
      }
    }
    return relevant;
  }

  const reachableFromSeed = new Set();
  for (const id of tableAwareDirectionalClosure(incomingEdgesByNode, edge => edge.fromId)) reachableFromSeed.add(id);
  for (const id of tableAwareDirectionalClosure(outgoingEdgesByNode, edge => edge.toId)) reachableFromSeed.add(id);
  for (const [key, node] of Array.from(itemMap.entries())) {
    if (reachableFromSeed.has(node.id)) continue;
    if (seedNodeIds.has(node.id) && node.data.item_type !== 'SemanticModel' && planningItemHasRealSources(node.data)) continue;
    // A SEED model (one living in a workspace the user explicitly selected
    // -- planning never runs without an explicit selection) stays as long
    // as it has any real source, even with no edge: a model whose data
    // comes entirely from an external system (e.g. an AWS SQL Server no
    // Fabric item writes to) has no upstream to draw, but it is still a
    // refreshable unit the user asked to plan -- pruning it rendered a
    // deliberately-selected workspace as a blank canvas. Non-seed models
    // pulled in from the tenant-wide match pool still need a real edge.
    if (seedNodeIds.has(node.id) && node.data.item_type === 'SemanticModel' && planningSeedModelHasSources(node.data)) continue;
    itemMap.delete(key);
  }
  const keptIds = new Set(Array.from(itemMap.values()).map(node => node.id));
  const prunedEdges = edges.filter(edge => keptIds.has(edge.fromId) && keptIds.has(edge.toId));
  edges.length = 0;
  edges.push(...prunedEdges);

  const nodes = Array.from(itemMap.values());
  const nodeById = new Map(nodes.map(node => [node.id, node]));
  // process starts at column 1 so column 0 stays purely "what the
  // notebooks read from" (origins) -- a notebook whose inputs are unknown
  // would otherwise share the origins column (user layout ask 2026-07-17:
  // origins | notebook steps (as many columns as their chains need) |
  // the lakehouse the data lands in | the models).
  const stageMinimum = { process: 1, model: 2 };
  const incoming = new Map(nodes.map(node => [node.id, 0]));
  const outgoing = new Map(nodes.map(node => [node.id, []]));
  for (const edge of edges) {
    incoming.set(edge.toId, (incoming.get(edge.toId) || 0) + 1);
    if (!outgoing.has(edge.fromId)) outgoing.set(edge.fromId, []);
    outgoing.get(edge.fromId).push(edge);
  }
  const wave = new Map(nodes.map(node => [node.id, stageMinimum[node.stage] || 0]));
  const queue = nodes.filter(node => (incoming.get(node.id) || 0) === 0).map(node => node.id);
  const seen = new Set();
  while (queue.length) {
    const id = queue.shift();
    seen.add(id);
    for (const edge of outgoing.get(id) || []) {
      const target = nodeById.get(edge.toId);
      if (!target) continue;
      wave.set(edge.toId, Math.max(wave.get(edge.toId) || 0, (wave.get(id) || 0) + 1, stageMinimum[target.stage] || 0));
      incoming.set(edge.toId, (incoming.get(edge.toId) || 0) - 1);
      if ((incoming.get(edge.toId) || 0) === 0) queue.push(edge.toId);
    }
  }

  // Models always land in the rightmost column, past every process AND
  // every store -- the canvas reads origin -> movers -> storage -> model
  // left to right, with arrows only ever pointing right (waves are
  // topological, so every edge targets a strictly higher wave).
  const maxUpstreamWave = Math.max(0, ...nodes.filter(node => node.stage !== 'model').map(node => wave.get(node.id) || 0));
  for (const node of nodes) {
    if (node.stage === 'model') wave.set(node.id, Math.max(wave.get(node.id) || 1, maxUpstreamWave + 1));
  }
  // Stores that feed ONLY models are the "where the data ends up" column:
  // align them all directly before the models regardless of how short
  // their own chain was (a lakehouse one notebook fills in a single step
  // used to sit columns away from one filled by a three-step chain).
  // Raising a wave can never break the rightward-arrow rule -- their only
  // outgoing edges point at models, which sit one column further still.
  const modelNodeIds = new Set(nodes.filter(node => node.stage === 'model').map(node => node.id));
  for (const node of nodes) {
    if (node.stage !== 'store') continue;
    const outgoingEdges = outgoing.get(node.id) || [];
    if (outgoingEdges.length && outgoingEdges.every(edge => modelNodeIds.has(edge.toId))) {
      wave.set(node.id, Math.max(wave.get(node.id) || 0, maxUpstreamWave));
    }
  }
  nodes.forEach(node => { node.wave = wave.get(node.id) || 0; });

  const columns = Array.from(new Set(nodes.map(node => node.wave))).sort((a, b) => a - b).map(waveId => ({
    wave: waveId,
    title: planningWaveTitle(waveId, nodes.filter(node => node.wave === waveId)),
    nodes: nodes
      .filter(node => node.wave === waveId)
      .sort((a, b) => (planningNodeWeight(b) - planningNodeWeight(a)) || a.label.localeCompare(b.label))
  }));
  return { nodes, edges, columns: minimizePlanningCrossings(columns, edges) };
}

// Sorting each column purely by risk weight (as above) reads fine with a
// handful of nodes, but with dozens of nodes per wave the connector lines
// tangle: two related nodes end up far apart vertically just because one
// has a slightly higher risk score, forcing their edge to cross several
// unrelated ones. This is the standard "barycenter" heuristic from layered
// graph drawing (Sugiyama-style): repeatedly re-sort each column by the
// average vertical position of the nodes it connects to in the neighboring
// column, alternating direction so both upstream and downstream influence
// the final order. A handful of passes is enough to converge in practice;
// this is a heuristic, not an exact minimum-crossing solver.
function minimizePlanningCrossings(columns, edges) {
  if (columns.length < 2) return columns;
  const positionByNodeId = new Map();
  columns.forEach(column => {
    column.nodes.forEach((node, index) => positionByNodeId.set(node.id, index));
  });

  const predecessorsById = new Map();
  const successorsById = new Map();
  for (const edge of edges) {
    if (!predecessorsById.has(edge.toId)) predecessorsById.set(edge.toId, []);
    predecessorsById.get(edge.toId).push(edge.fromId);
    if (!successorsById.has(edge.fromId)) successorsById.set(edge.fromId, []);
    successorsById.get(edge.fromId).push(edge.toId);
  }

  function barycenter(nodeId, neighborMap) {
    const neighbors = neighborMap.get(nodeId) || [];
    const positions = neighbors.map(id => positionByNodeId.get(id)).filter(position => position !== undefined);
    if (!positions.length) return null;
    return positions.reduce((sum, position) => sum + position, 0) / positions.length;
  }

  const PASS_COUNT = 4;
  for (let pass = 0; pass < PASS_COUNT; pass += 1) {
    const goingForward = pass % 2 === 0;
    const neighborMap = goingForward ? predecessorsById : successorsById;
    const orderedColumns = goingForward ? columns : [...columns].reverse();
    for (const column of orderedColumns) {
      const scored = column.nodes.map((node, index) => ({
        node,
        score: barycenter(node.id, neighborMap),
        originalIndex: index
      }));
      scored.sort((a, b) => {
        if (a.score === null && b.score === null) return a.originalIndex - b.originalIndex;
        if (a.score === null) return 1;
        if (b.score === null) return -1;
        return (a.score - b.score) || (a.originalIndex - b.originalIndex);
      });
      column.nodes = scored.map(entry => entry.node);
      column.nodes.forEach((node, index) => positionByNodeId.set(node.id, index));
    }
  }

  reduceAdjacentColumnCrossings(columns, edges);
  return columns;
}

// Barycenter sweeps are a good starting order but can settle into a local
// minimum that still has avoidable crossings between neighboring columns.
// This is a bounded greedy local search on top of it: repeatedly try
// swapping each adjacent pair of nodes within a column and keep the swap
// only if it reduces the crossing count against that column's immediate
// left/right neighbors (the case that is actually visible as tangled
// lines between two adjacent waves -- multi-wave "skip" edges are routed
// on a separate rail already and are not part of this count).
function reduceAdjacentColumnCrossings(columns, edges) {
  // Real waves can have hundreds of nodes (e.g. a "refresh these semantic
  // models" wave). crossingsBetween is O(edges^2); left uncapped, a large
  // column would make this local search itself the thing that freezes the
  // tab. Skip the optimization for columns/edge-sets past a size where it
  // stops being about crossings and starts being about sheer volume.
  const MAX_COLUMN_SIZE_FOR_SWAPS = 60;
  const MAX_RELEVANT_EDGES = 500;

  function crossingsBetween(leftNodes, rightNodes, relevantEdges) {
    if (relevantEdges.length > MAX_RELEVANT_EDGES) return 0;
    const leftPos = new Map(leftNodes.map((node, index) => [node.id, index]));
    const rightPos = new Map(rightNodes.map((node, index) => [node.id, index]));
    const pairs = [];
    for (const edge of relevantEdges) {
      if (leftPos.has(edge.fromId) && rightPos.has(edge.toId)) {
        pairs.push([leftPos.get(edge.fromId), rightPos.get(edge.toId)]);
      }
    }
    let crossings = 0;
    for (let i = 0; i < pairs.length; i += 1) {
      for (let j = i + 1; j < pairs.length; j += 1) {
        if ((pairs[i][0] - pairs[j][0]) * (pairs[i][1] - pairs[j][1]) < 0) crossings += 1;
      }
    }
    return crossings;
  }

  const nodeToColumnIndex = new Map();
  columns.forEach((column, index) => {
    column.nodes.forEach(node => nodeToColumnIndex.set(node.id, index));
  });
  const edgesBetween = (leftIndex, rightIndex) => edges.filter(edge =>
    nodeToColumnIndex.get(edge.fromId) === leftIndex && nodeToColumnIndex.get(edge.toId) === rightIndex
  );

  const SWEEP_COUNT = 3;
  for (let sweep = 0; sweep < SWEEP_COUNT; sweep += 1) {
    let improved = false;
    for (let columnIndex = 0; columnIndex < columns.length; columnIndex += 1) {
      const column = columns[columnIndex];
      if (column.nodes.length > MAX_COLUMN_SIZE_FOR_SWAPS) continue;
      const leftEdges = columnIndex > 0 ? edgesBetween(columnIndex - 1, columnIndex) : [];
      const rightEdges = columnIndex < columns.length - 1 ? edgesBetween(columnIndex, columnIndex + 1) : [];
      for (let i = 0; i < column.nodes.length - 1; i += 1) {
        const before =
          (columnIndex > 0 ? crossingsBetween(columns[columnIndex - 1].nodes, column.nodes, leftEdges) : 0) +
          (columnIndex < columns.length - 1 ? crossingsBetween(column.nodes, columns[columnIndex + 1].nodes, rightEdges) : 0);
        [column.nodes[i], column.nodes[i + 1]] = [column.nodes[i + 1], column.nodes[i]];
        const after =
          (columnIndex > 0 ? crossingsBetween(columns[columnIndex - 1].nodes, column.nodes, leftEdges) : 0) +
          (columnIndex < columns.length - 1 ? crossingsBetween(column.nodes, columns[columnIndex + 1].nodes, rightEdges) : 0);
        if (after < before) {
          improved = true;
        } else {
          [column.nodes[i], column.nodes[i + 1]] = [column.nodes[i + 1], column.nodes[i]];
        }
      }
    }
    if (!improved) break;
  }
}

function planningNodeWeight(node) {
  const planning = node.data && node.data.planning ? node.data.planning : {};
  return (planning.critical_path ? 100 : 0) +
    (planning.failure_hotspot ? 80 : 0) +
    (Number(planning.parallel_candidate_count || 0) * 3) +
    Number(node.data && node.data.execution ? node.data.execution.avg_duration_seconds || 0 : 0) / 1000;
}

function planningWaveTitle(waveId, nodes) {
  const stages = new Set(nodes.map(node => node.stage));
  let label = t('planning.dependentProcesses');
  if (stages.size === 1 && stages.has('process')) label = waveId <= 0 ? t('planning.executableProcesses') : t('planning.dependentProcesses');
  else if (stages.size === 1 && stages.has('model')) label = t('planning.modelRefresh');
  else if (stages.size === 1 && stages.has('store')) label = t('planning.dataStores');
  return `${t('planning.wave')} ${waveId} · ${label}`;
}

function planningEdgeTypeLabel(type) {
  const labels = {
    source: state.lang === 'es' ? 'origen' : 'source',
    read: t('planning.readEdge'),
    write: t('planning.writeEdge'),
    reference: t('planning.referenceEdge'),
    dependency: t('planning.dependency'),
    execute: state.lang === 'es' ? 'ejecución' : 'execution',
    model: state.lang === 'es' ? 'modelo' : 'model',
    report: state.lang === 'es' ? 'informe' : 'report',
    controlFlowSucceeded: state.lang === 'es' ? 'si tiene éxito' : 'on success',
    controlFlowFailed: state.lang === 'es' ? 'si falla' : 'on failure',
    controlFlowCompleted: state.lang === 'es' ? 'siempre (al completar)' : 'always (on completion)',
    dataRequiredForModel: state.lang === 'es' ? 'dato requerido por el informe' : 'data required by the report'
  };
  return labels[type] || type;
}

// Mirrors the color convention of a real Fabric/ADF pipeline canvas: green
// only runs after the upstream activity succeeds, red is an error-handling
// branch that only runs after the upstream activity fails, gray runs
// regardless of outcome. Confirmed via real pipeline dependsOn data (see
// pipeline_activity_dependency_edges), not inferred.
function planningEdgeColor(type) {
  const colors = {
    source: '#0f766e',
    read: '#0f766e',
    write: '#2563eb',
    reference: '#64748b',
    dependency: '#475569',
    execute: '#2563eb',
    model: '#b45309',
    report: '#b45309',
    controlFlowSucceeded: '#16d167',
    controlFlowFailed: '#ff3b30',
    controlFlowCompleted: '#64748b',
    dataRequiredForModel: '#22c55e'
  };
  return colors[type] || '#475569';
}

function appendPlanningEdgeMarkers(svg) {
  const defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
  for (const type of ['source', 'read', 'write', 'reference', 'dependency', 'execute', 'model', 'report', 'controlFlowSucceeded', 'controlFlowFailed', 'controlFlowCompleted', 'dataRequiredForModel']) {
    const marker = document.createElementNS('http://www.w3.org/2000/svg', 'marker');
    marker.setAttribute('id', `planning-arrow-${type}`);
    marker.setAttribute('viewBox', '0 0 10 10');
    marker.setAttribute('refX', '8.5');
    marker.setAttribute('refY', '5');
    marker.setAttribute('markerWidth', '7');
    marker.setAttribute('markerHeight', '7');
    marker.setAttribute('orient', 'auto-start-reverse');
    const arrow = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    arrow.setAttribute('d', 'M 0 0 L 10 5 L 0 10 z');
    arrow.setAttribute('fill', planningEdgeColor(type));
    marker.append(arrow);
    defs.append(marker);
  }
  svg.append(defs);
}

// Card position in *natural*, unscaled canvas-local pixels: offsetLeft/Top/
// Width/Height are plain CSS box-model layout values, never affected by a
// transform on an ancestor (unlike getBoundingClientRect, which reports the
// post-transform painted position). Planning's zoom applies a single
// transform: scale() to .planning-canvas (see renderPlanningCanvas) so that
// cards and the edges SVG -- direct siblings inside it -- are guaranteed to
// scale as one unit; computing edge coordinates from getBoundingClientRect
// here would double-apply that same scale to the SVG's own coordinate
// space, since the SVG is itself inside the scaled element. The manual
// drag offset (a CSS transform: translate(), stored in natural units --
// see attachPlanningCardDrag) isn't part of offsetLeft/Top, so it's added
// back in explicitly.
function getCardNaturalRect(card) {
  const node = planningLiveNodesById.get(card.dataset.planId);
  const offset = node ? state.planningNodePositions.get(node.key) : null;
  const dx = offset ? offset.dx : 0;
  const dy = offset ? offset.dy : 0;
  const left = card.offsetLeft + dx;
  const top = card.offsetTop + dy;
  const width = card.offsetWidth;
  const height = card.offsetHeight;
  return { left, top, right: left + width, bottom: top + height, width, height };
}

function renderPlanningEdges(board, edges) {
  const svg = board.querySelector('.planning-edges');
  if (!svg) return;
  svg.innerHTML = '';
  appendPlanningEdgeMarkers(svg);

  const cards = Array.from(board.querySelectorAll('.planning-card'));
  cards.forEach(card => card.classList.remove('planning-upstream', 'planning-downstream', 'planning-muted'));
  const visible = new Set(cards.map(card => card.dataset.planId));
  const selectedIds = new Set(state.planningSelectedIds.filter(id => visible.has(id)));
  const hasSelection = selectedIds.size > 0;
  const activeNodes = new Set(selectedIds);
  if (hasSelection) {
    for (const edge of edges) {
      if (!visible.has(edge.fromId) || !visible.has(edge.toId)) continue;
      if (selectedIds.has(edge.fromId)) activeNodes.add(edge.toId);
      if (selectedIds.has(edge.toId)) activeNodes.add(edge.fromId);
    }
    cards.forEach(card => {
      const id = card.dataset.planId;
      card.classList.toggle('planning-muted', !activeNodes.has(id));
    });
  }

  // Every edge used to leave/enter a card at a hardcoded side (always the
  // right border outgoing, always the left border incoming), regardless of
  // where the other card actually sat -- once free-form dragging moved a
  // target above, below, or behind its source, the line still had to exit
  // rightward and loop all the way back, reading as "disconnected" even
  // though the coordinates were correct. Ports are now chosen dynamically
  // per edge, per render (including live during drag), from whichever side
  // of the card actually faces the other end. Within a shared (card, side)
  // multiple edges still get their own anchor point spread along that side,
  // ordered by where the other end sits, instead of stacking on one pixel.
  const visibleEdgeList = edges.filter(edge => visible.has(edge.fromId) && visible.has(edge.toId));
  const cardRectById = new Map();
  // Also index the card elements themselves: this function re-runs live on
  // every drag frame and selection click, and the per-edge
  // board.querySelector pair below it used to rescan the whole card DOM
  // twice per edge per render -- thousands of scans a frame on a busy graph.
  const cardElementById = new Map();
  for (const card of cards) {
    cardRectById.set(card.dataset.planId, getCardNaturalRect(card));
    cardElementById.set(card.dataset.planId, card);
  }

  function rectCenter(rect) {
    return { x: (rect.left + rect.right) / 2, y: (rect.top + rect.bottom) / 2 };
  }

  // Horizontal (left/right) ports are the default for the computed
  // left-to-right layout -- a purely geometric "closest side" rule flips
  // most edges to top/bottom the moment a column gets tall (dy dominates
  // dx once a graph has many rows even though it's still a straightforward
  // left-to-right dependency), producing a "hedgehog" of little vertical
  // arrows instead of a readable flow. Once a card has actually been
  // dragged, though, the user has deliberately overridden the computed
  // position, and the whole point is that its connections should now
  // follow it around the contour to wherever makes sense -- so dragged
  // endpoints get the full geometric port choice instead.
  function choosePorts(fromRect, toRect, eitherEndDragged) {
    const from = rectCenter(fromRect);
    const to = rectCenter(toRect);
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    if (eitherEndDragged && Math.abs(dy) > Math.abs(dx) * 0.6) {
      return dy >= 0 ? { exit: 'bottom', entry: 'top' } : { exit: 'top', entry: 'bottom' };
    }
    return dx >= 0 ? { exit: 'right', entry: 'left' } : { exit: 'left', entry: 'right' };
  }

  function pointOnSide(rect, side, fraction) {
    if (side === 'right') return { x: rect.right, y: rect.top + rect.height * fraction };
    if (side === 'left') return { x: rect.left, y: rect.top + rect.height * fraction };
    if (side === 'bottom') return { x: rect.left + rect.width * fraction, y: rect.bottom };
    return { x: rect.left + rect.width * fraction, y: rect.top };
  }

  function sideAxis(side) {
    return side === 'left' || side === 'right' ? 'y' : 'x';
  }

  const preRoutes = visibleEdgeList.map(edge => {
    const from = cardElementById.get(edge.fromId);
    const to = cardElementById.get(edge.toId);
    if (!from || !to) return null;
    const fromRect = cardRectById.get(edge.fromId) || getCardNaturalRect(from);
    const toRect = cardRectById.get(edge.toId) || getCardNaturalRect(to);
    const fromNode = planningLiveNodesById.get(edge.fromId);
    const toNode = planningLiveNodesById.get(edge.toId);
    const eitherEndDragged = Boolean(
      (fromNode && state.planningNodePositions.has(fromNode.key)) ||
      (toNode && state.planningNodePositions.has(toNode.key))
    );
    const ports = choosePorts(fromRect, toRect, eitherEndDragged);
    return { edge, from, to, fromRect, toRect, exitSide: ports.exit, entrySide: ports.entry };
  }).filter(Boolean);

  const outgoingBySide = new Map();
  const incomingBySide = new Map();
  for (const route of preRoutes) {
    const outKey = `${route.edge.fromId}|${route.exitSide}`;
    if (!outgoingBySide.has(outKey)) outgoingBySide.set(outKey, []);
    outgoingBySide.get(outKey).push(route);
    const inKey = `${route.edge.toId}|${route.entrySide}`;
    if (!incomingBySide.has(inKey)) incomingBySide.set(inKey, []);
    incomingBySide.get(inKey).push(route);
  }

  function otherEndPosition(route, side, wantFromEnd) {
    const rect = wantFromEnd ? route.toRect : route.fromRect;
    return sideAxis(side) === 'y' ? rect.top : rect.left;
  }

  function assignAnchorFractions(groupMap, wantFromEnd) {
    const fractionByRoute = new Map();
    for (const group of groupMap.values()) {
      const side = wantFromEnd ? group[0].exitSide : group[0].entrySide;
      const ordered = [...group].sort((a, b) => otherEndPosition(a, side, wantFromEnd) - otherEndPosition(b, side, wantFromEnd));
      ordered.forEach((route, index) => fractionByRoute.set(route, (index + 1) / (ordered.length + 1)));
    }
    return fractionByRoute;
  }

  const outgoingFraction = assignAnchorFractions(outgoingBySide, true);
  const incomingFraction = assignAnchorFractions(incomingBySide, false);

  const routedEdges = preRoutes.map(route => {
    const { edge, from, to, fromRect, toRect, exitSide, entrySide } = route;
    const anchor1 = pointOnSide(fromRect, exitSide, outgoingFraction.get(route) || 0.5);
    const anchor2 = pointOnSide(toRect, entrySide, incomingFraction.get(route) || 0.5);
    const x1 = anchor1.x;
    const y1 = anchor1.y;
    const x2 = anchor2.x;
    const y2 = anchor2.y;
    const fromWave = Number(from.dataset.wave || 0);
    const toWave = Number(to.dataset.wave || fromWave + 1);
    return { edge, from, to, x1, y1, x2, y2, exitSide, entrySide, fromWave, toWave };
  });

  // Cards are draggable and their base layout box does not grow just
  // because a transform visually moved one beyond it -- size the SVG from
  // the real, current endpoint coordinates too, not just where cards
  // started. `overflow: visible` on the SVG (see styles.css) already lets a
  // path render correctly even past these bounds -- including at negative
  // coordinates from a card dragged above/left of the canvas origin -- this
  // sizing is only so scrollable area/hit-testing has a sane, non-clipped
  // footprint to work with.
  //
  // The floor here used to be canvas.scrollWidth/scrollHeight, on the
  // assumption that reflected the drag-oblivious natural layout -- but the
  // SVG this function sizes is ITSELF one of canvas's children, so that
  // "natural size" was actually reading back whatever height THIS function
  // wrote on the PREVIOUS call. renderPlanningEdges reruns on every
  // pointer-move frame during a drag: each call's write became the next
  // call's floor, so the canvas grew a little every single frame with no
  // upper bound -- read live 2026-07-19 as the vertical scrollbar visibly
  // shrinking (the scrollable area silently ballooning) the moment a card
  // was dragged, never settling. Cards' own offsetLeft/offsetTop (via
  // getCardNaturalRect, already used above for edge routing) are plain
  // layout-box values nothing here ever writes to -- using their extent as
  // the floor instead breaks the loop for good.
  let maxRight = 0;
  let maxBottom = 0;
  for (const card of cards) {
    const rect = getCardNaturalRect(card);
    maxRight = Math.max(maxRight, rect.right);
    maxBottom = Math.max(maxBottom, rect.bottom);
  }
  for (const route of routedEdges) {
    maxRight = Math.max(maxRight, route.x1 + 60, route.x2 + 60);
    maxBottom = Math.max(maxBottom, route.y1 + 60, route.y2 + 60);
  }
  const svgWidth = Math.ceil(maxRight);
  const svgHeight = Math.ceil(maxBottom);
  svg.setAttribute('width', svgWidth);
  svg.setAttribute('height', svgHeight);
  svg.setAttribute('viewBox', `0 0 ${svgWidth} ${svgHeight}`);
  planningNaturalSize = { width: svgWidth, height: svgHeight };
  svg.style.width = `${svgWidth}px`;
  svg.style.height = `${svgHeight}px`;

  // Stable draw order (top-to-bottom, left-to-right): with curves the order
  // no longer routes anything, but it keeps the halo overlap effect
  // consistent between renders instead of flickering with edge-array order.
  routedEdges.sort((a, b) =>
    (a.fromWave - b.fromWave) ||
    (a.toWave - b.toWave) ||
    (a.y1 - b.y1) ||
    (a.y2 - b.y2)
  );

  // Curved connectors (user ask 2026-07-18: same look as the planning map
  // popup, brought back into the embedded canvas). One cubic bezier whose
  // control points extend outward along each port's own side, so the curve
  // still leaves/enters perpendicular to the card border for every port
  // combination the drag logic can produce -- and the whole
  // obstacle-avoiding rail router this replaced (per-edge scans over every
  // card rect, re-run each drag frame) is simply gone.
  function bezierPointAt(p0, p1, p2, p3, t) {
    const mt = 1 - t;
    return {
      x: mt * mt * mt * p0.x + 3 * mt * mt * t * p1.x + 3 * mt * t * t * p2.x + t * t * t * p3.x,
      y: mt * mt * mt * p0.y + 3 * mt * mt * t * p1.y + 3 * mt * t * t * p2.y + t * t * t * p3.y
    };
  }

  // Label point sampled near the START of the curve (t=0.18), not its
  // midpoint -- the user wants LEE/ESCRIBE readable right where the line
  // leaves the source card, "centrado dentro de la línea" (2026-07-20).
  // Still taken from the real bezier point (not the straight line between
  // anchors), so it stays glued to the actual drawn curve no matter which
  // side the ports exit/enter from.
  const EDGE_LABEL_T = 0.18;
  function buildCurvedPath(anchor1, side1, anchor2, side2) {
    const distance = Math.hypot(anchor2.x - anchor1.x, anchor2.y - anchor1.y);
    const reach = Math.max(36, Math.min(220, distance / 2));
    const control = (anchor, side) =>
      side === 'right' ? { x: anchor.x + reach, y: anchor.y }
      : side === 'left' ? { x: anchor.x - reach, y: anchor.y }
      : side === 'bottom' ? { x: anchor.x, y: anchor.y + reach }
      : { x: anchor.x, y: anchor.y - reach };
    const c1 = control(anchor1, side1);
    const c2 = control(anchor2, side2);
    return {
      d: `M ${anchor1.x} ${anchor1.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${anchor2.x} ${anchor2.y}`,
      labelPoint: bezierPointAt(anchor1, c1, c2, anchor2, EDGE_LABEL_T)
    };
  }

  for (const route of routedEdges) {
    const { edge, from, to, x1, y1, x2, y2, exitSide, entrySide } = route;
    const isActive = hasSelection && (selectedIds.has(edge.fromId) || selectedIds.has(edge.toId));
    const isMuted = hasSelection && !isActive;
    const curve = buildCurvedPath({ x: x1, y: y1 }, exitSide, { x: x2, y: y2 }, entrySide);
    const d = curve.d;
    const labelX = curve.labelPoint.x;
    const labelY = curve.labelPoint.y;
    const titleText = `${from.dataset.label || edge.fromId} -> ${to.dataset.label || edge.toId} · ${planningEdgeTypeLabel(edge.type)}`;

    // Halo drawn immediately before this edge's own line, in the same
    // per-edge iteration: whichever edge is drawn later naturally paints a
    // soft, blurred gap over anything already on the page at that point,
    // so at every crossing the earlier line reads as passing underneath
    // the later one -- without needing to compute actual line
    // intersections. This also keeps two edges that happen to share the
    // same route from reading as one indistinguishable double-thick line,
    // since each still gets its own halo pass separating it from what was
    // drawn before it.
    const halo = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    halo.setAttribute('d', d);
    halo.setAttribute('class', 'planning-edge-halo');
    svg.append(halo);

    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', d);
    // Same stroke convention as the planning map popup: solid = confirmed
    // evidence, dashed = inferred/likely -- the two canvases must not
    // disagree about how sure a line is. pathLength=1 (which normalizes
    // the path for the draw-in animation's dashoffset trick) only goes on
    // confirmed edges: it would turn the inferred edges' pixel-unit
    // dasharray into nonsense.
    const isConfirmedEdge = edge.confidence === 'confirmed';
    if (isConfirmedEdge) path.setAttribute('pathLength', '1');
    path.setAttribute('marker-end', `url(#planning-arrow-${edge.type})`);
    path.setAttribute('class', `planning-edge planning-edge-${edge.type}${isConfirmedEdge ? '' : ' planning-edge-inferred'}${isActive ? ' planning-edge-active' : ''}${isMuted ? ' planning-edge-muted' : ''}`);
    path.dataset.from = edge.fromId;
    path.dataset.to = edge.toId;
    const title = document.createElementNS('http://www.w3.org/2000/svg', 'title');
    title.textContent = titleText;
    path.append(title);
    svg.append(path);

    for (const [cx, cy, className] of [
      [x1, y1, 'planning-port-dot planning-port-dot-start'],
      [x2, y2, 'planning-port-dot planning-port-dot-end']
    ]) {
      const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      dot.setAttribute('cx', cx);
      dot.setAttribute('cy', cy);
      dot.setAttribute('r', isActive ? '4.5' : '3.3');
      dot.setAttribute('class', `${className} planning-port-dot-${edge.type}${isActive ? ' planning-port-dot-active' : ''}${isMuted ? ' planning-port-dot-muted' : ''}`);
      svg.append(dot);
    }

    if (isActive) {
      from.classList.add('planning-upstream');
      to.classList.add('planning-downstream');
      const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
      label.setAttribute('x', labelX);
      label.setAttribute('y', labelY);
      label.setAttribute('class', 'planning-edge-label');
      label.textContent = planningEdgeTypeLabel(edge.type);
      svg.append(label);
    }
  }
}

function planningSourceReadableLabel(source) {
  const node = {
    kind: 'source',
    label: source.label || source.database || source.server || sourceTypeDisplay(source.source_type) || t('source'),
    data: source
  };
  return semanticSourceDisplayTitle(node, source);
}

function planningSourceReadableMeta(source, title) {
  const meta = semanticSourceMeta(source, title);
  return meta || [sourceTypeDisplay(source.source_type), source.workspace_name, source.database]
    .filter(Boolean)
    .join(' · ');
}

function latestExecutionItem(items) {
  const withStart = asList(items)
    .filter(item => item && item.execution && item.execution.latest_start)
    .slice()
    .sort((a, b) => Date.parse(b.execution.latest_start) - Date.parse(a.execution.latest_start));
  return withStart[0] || null;
}

function buildPlanningWriterMap(selected) {
  const writers = new Map();
  const items = selected.flatMap(workspace => asList(workspace.all));
  for (const item of items) {
    if (item.item_type === 'SemanticModel') continue;
    for (const source of asList(item.sources)) {
      if (source.notebook_super_lineage_only) continue;
      const usage = sourcePlanningUsage(source, item);
      const hasWriteObject = asList(source.objects).some(object => object.usage_type === 'writes_to');
      if (!hasWriteObject && usage !== 'write' && usage !== 'readWrite') continue;
      const key = sourceKey(source);
      if (!writers.has(key)) writers.set(key, []);
      writers.get(key).push(item);
    }
  }
  return writers;
}

function buildPlanningReadiness(selected) {
  const writerMap = buildPlanningWriterMap(selected);
  const groups = new Map();
  for (const workspace of selected) {
    for (const model of asList(workspace.semantic)) {
      const sources = uniqueBy(asList(model.sources).filter(sourceVisible), source => sourceKey(source));
      for (const source of sources) {
        const key = sourceKey(source);
        if (!groups.has(key)) {
          groups.set(key, {
            key,
            id: `planning-readiness:source:${groups.size}`,
            source,
            writers: writerMap.get(key) || [],
            models: new Map(),
            objectCount: 0
          });
        }
        const group = groups.get(key);
        group.objectCount += asList(source.objects).length;
        const modelKey = planningNodeKey(model);
        if (!group.models.has(modelKey)) {
          group.models.set(modelKey, { workspace, model, sourceConfidence: source.confidence });
        }
      }
    }
  }
  const rows = Array.from(groups.values()).map(group => ({
    ...group,
    models: Array.from(group.models.values()).sort((a, b) =>
      (a.workspace.environment || '').localeCompare(b.workspace.environment || '') ||
      a.model.label.localeCompare(b.model.label)
    )
  })).sort((a, b) =>
    b.models.length - a.models.length ||
    planningSourceReadableLabel(a.source).localeCompare(planningSourceReadableLabel(b.source))
  );
  const modelKeys = new Set();
  rows.forEach(row => row.models.forEach(entry => modelKeys.add(planningNodeKey(entry.model))));
  return {
    rows,
    sourceCount: rows.length,
    modelCount: modelKeys.size,
    objectCount: rows.reduce((sum, row) => sum + row.objectCount, 0),
    missingArrivalCount: rows.filter(row => !latestExecutionItem(row.writers)).length
  };
}

function planningReadinessStats(rows) {
  const modelKeys = new Set();
  rows.forEach(row => row.models.forEach(entry => modelKeys.add(planningNodeKey(entry.model))));
  return {
    sourceCount: rows.length,
    modelCount: modelKeys.size,
    objectCount: rows.reduce((sum, row) => sum + row.objectCount, 0),
    missingArrivalCount: rows.filter(row => !latestExecutionItem(row.writers)).length
  };
}

function planningRowSearchText(row) {
  const source = row.source || {};
  const title = planningSourceReadableLabel(source);
  const meta = planningSourceReadableMeta(source, title);
  return normalize([
    title,
    meta,
    source.source_type,
    source.server,
    source.database,
    source.label,
    source.qualified_name,
    ...row.models.flatMap(entry => [entry.model.label, entry.model.qualified_name, entry.workspace.name, entry.workspace.environment])
  ].filter(Boolean).join(' '));
}

function syncPlanningSourceSelection(readiness) {
  const valid = new Set((readiness.rows || []).map(row => row.key));
  state.planningSelectedSources = new Set(Array.from(state.planningSelectedSources).filter(key => valid.has(key)));
}

function filteredPlanningRows(readiness) {
  syncPlanningSourceSelection(readiness);
  const rows = state.filters.sourceType === 'all'
    ? readiness.rows
    : readiness.rows.filter(row => (row.source && row.source.source_type) === state.filters.sourceType);
  const selectedKeys = state.planningSelectedSources;
  const query = normalize(state.planningSourceSearch);
  if (selectedKeys.size) return rows.filter(row => selectedKeys.has(row.key));
  if (query) return rows.filter(row => planningRowSearchText(row).includes(query));
  return rows;
}

function planningSourceChip(row, active = false) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `planning-source-chip${active ? ' active' : ''}`;
  button.dataset.sourceKey = row.key;
  const title = planningSourceReadableLabel(row.source);
  const meta = planningSourceReadableMeta(row.source, title);
  button.innerHTML = `
    <strong>${escapeHtml(title)}</strong>
    <span>${escapeHtml(meta)}</span>
    <i>${number(row.models.length)} ${escapeHtml(t('planning.affectedModels'))} · ${number(row.objectCount)} ${escapeHtml(t('planning.objectCount'))}</i>
  `;
  button.addEventListener('click', event => {
    event.stopPropagation();
    if (state.planningSelectedSources.has(row.key)) state.planningSelectedSources.delete(row.key);
    else state.planningSelectedSources.add(row.key);
    state.planningSourceSearch = '';
    state.history = [];
    state.selectedNode = null;
    render();
  });
  return button;
}

// Fase de limpieza de UI (2026-07-19): este panel de orígenes vivía como un
// bloque fijo dentro del propio lienzo de Planificación -- se traslada al
// panel de Filtro compartido (renderPlanningFilterSources, ver populateFilters)
// para que el botón de filtro sea el único sitio donde acotar qué se ve,
// igual que en Inspección e Impacto.
function renderPlanningFilterSources(readiness) {
  if (!els.planningFilterSources) return;
  els.planningFilterSources.hidden = false;
  els.planningFilterSources.innerHTML = '';

  const rows = state.filters.sourceType === 'all'
    ? readiness.rows
    : readiness.rows.filter(row => (row.source && row.source.source_type) === state.filters.sourceType);

  const heading = document.createElement('div');
  heading.className = 'planning-source-heading';
  heading.innerHTML = `
    <strong>${escapeHtml(t('planning.sourceSelectorTitle'))}</strong>
    <span>${escapeHtml(t('planning.sourceSearchHint'))}</span>
  `;

  const controls = document.createElement('div');
  controls.className = 'planning-source-controls';
  const input = document.createElement('input');
  input.id = 'planningSourceSearch';
  input.type = 'search';
  input.autocomplete = 'off';
  input.placeholder = t('planning.sourceSearchPlaceholder');
  input.value = state.planningSourceSearch;
  input.addEventListener('input', event => {
    const start = event.target.selectionStart;
    const end = event.target.selectionEnd;
    state.planningSourceSearch = event.target.value;
    state.history = [];
    state.selectedNode = null;
    renderPreservingFocus('#planningSourceSearch', start, end);
  });

  const meta = document.createElement('strong');
  meta.textContent = `${number(rows.length)}/${number(readiness.rows.length)} ${t('planning.dataGroups')}`;

  const clear = document.createElement('button');
  clear.type = 'button';
  clear.textContent = t('planning.clearSources');
  clear.hidden = !state.planningSourceSearch && !state.planningSelectedSources.size;
  clear.addEventListener('click', event => {
    event.stopPropagation();
    state.planningSourceSearch = '';
    state.planningSelectedSources = new Set();
    state.history = [];
    state.selectedNode = null;
    render();
  });
  controls.append(input, meta, clear);

  const selectedRows = rows.filter(row => state.planningSelectedSources.has(row.key));
  const selectedWrap = document.createElement('div');
  selectedWrap.className = 'planning-source-chip-group selected';
  if (selectedRows.length) {
    selectedWrap.innerHTML = `<span>${escapeHtml(t('planning.selectedSources'))}</span>`;
    selectedRows.forEach(row => selectedWrap.append(planningSourceChip(row, true)));
  }

  const query = normalize(state.planningSourceSearch);
  const matchRows = (query ? rows.filter(row => planningRowSearchText(row).includes(query)) : rows)
    .filter(row => !state.planningSelectedSources.has(row.key))
    .slice(0, 12);
  const matchWrap = document.createElement('div');
  matchWrap.className = 'planning-source-chip-group';
  matchWrap.innerHTML = `<span>${escapeHtml(t('planning.matchingSources'))}</span>`;
  if (matchRows.length) {
    matchRows.forEach(row => matchWrap.append(planningSourceChip(row, false)));
  } else {
    const empty = document.createElement('p');
    empty.textContent = t('planning.noSourceMatch');
    matchWrap.append(empty);
  }

  els.planningFilterSources.append(heading, controls);
  if (selectedRows.length) els.planningFilterSources.append(selectedWrap);
  els.planningFilterSources.append(matchWrap);
}

function planningScopeWorkspaces(selected) {
  const hasPipelineScope = selected.length > 1 && selected.some(workspace => workspace.deployment_pipeline && workspace.deployment_pipeline.has_pipeline);
  if (!hasPipelineScope) return selected;
  const production = selected.filter(isProductionWorkspace);
  return production.length ? production : selected;
}

// A single corrupted avg_duration_seconds value (e.g. a notebook's
// execution history carrying a stored duration of several weeks while its
// own start/end timestamps show the run actually took minutes, a
// timestamp-parsing bug upstream) is enough to make
// every duration-based planning stat read as nonsense across the entire
// tenant, since critical path and the sum both propagate whatever the
// largest single number is. No real Fabric notebook/pipeline/CopyJob run
// takes longer than a day; treat anything at or past that as bad data and
// drop it from these aggregates rather than let it dominate them.
const PLANNING_MAX_REALISTIC_DURATION_SECONDS = 24 * 60 * 60;
function planningRealisticDurationSeconds(execution) {
  // The backend now computes median_duration_seconds alongside the average
  // (11_build_lineage_explorer) and already excludes 24h+ outliers from
  // both -- prefer the median where a rescan has produced one, since it is
  // not pulled around by whatever single longest/shortest run happened to
  // land in the history window, and keep this cap as a backstop for data
  // from before that fix.
  const median = Number((execution && execution.median_duration_seconds) || 0);
  if (Number.isFinite(median) && median > 0 && median < PLANNING_MAX_REALISTIC_DURATION_SECONDS) return median;
  const value = Number((execution && execution.avg_duration_seconds) || 0);
  if (!Number.isFinite(value) || value <= 0 || value >= PLANNING_MAX_REALISTIC_DURATION_SECONDS) return 0;
  return value;
}

// The flat sum of every node's own average duration overstates real elapsed
// time whenever anything can run in parallel (two independent branches that
// both take 10 minutes finish in 10 minutes total, not 20). The number that
// actually answers "how long until everything is done" is the longest
// duration-weighted path through the dependency graph -- the same "critical
// path" concept construction/project scheduling uses. Nodes carry a `wave`
// (topological level: every edge only ever points to a strictly higher
// wave, see buildPlanningGraph), so a single ascending-wave pass is already
// a valid topological order for this longest-path DP.
function planningCriticalPathSeconds(graph) {
  const durationById = new Map();
  for (const node of graph.nodes) {
    const execution = node.data && node.data.execution ? node.data.execution : {};
    durationById.set(node.id, planningRealisticDurationSeconds(execution));
  }
  const predecessorsById = new Map(graph.nodes.map(node => [node.id, []]));
  for (const edge of graph.edges) {
    if (!predecessorsById.has(edge.toId)) predecessorsById.set(edge.toId, []);
    predecessorsById.get(edge.toId).push(edge.fromId);
  }
  const orderedNodes = [...graph.nodes].sort((a, b) => (a.wave || 0) - (b.wave || 0));
  const finishById = new Map();
  let longest = 0;
  for (const node of orderedNodes) {
    const predecessors = predecessorsById.get(node.id) || [];
    const bestPredecessorFinish = predecessors.reduce(
      (best, predecessorId) => Math.max(best, finishById.get(predecessorId) || 0),
      0
    );
    const finish = bestPredecessorFinish + (durationById.get(node.id) || 0);
    finishById.set(node.id, finish);
    if (finish > longest) longest = finish;
  }
  return longest;
}

function planningGraphStats(graph) {
  const executableNodes = graph.nodes.filter(node => node.stage === 'process' || node.stage === 'model');
  const failed = executableNodes.filter(node => node.data && node.data.execution && Number(node.data.execution.failed_runs || 0) > 0).length;
  const missingDuration = executableNodes.filter(node => {
    const execution = node.data && node.data.execution ? node.data.execution : {};
    return !execution.avg_duration_seconds;
  }).length;
  const controlFlowFailedEdges = graph.edges.filter(edge => edge.type === 'controlFlowFailed').length;
  return {
    nodeCount: graph.nodes.length,
    edgeCount: graph.edges.length,
    criticalPathSeconds: planningCriticalPathSeconds(graph),
    blockerCount: failed + missingDuration,
    failedNodeCount: failed,
    controlFlowFailedEdges
  };
}

function renderPlanningCanvas(graph, readiness, visibleRows, selected, scope) {
  planningLiveEdges = graph.edges;
  planningLiveNodesById = new Map(graph.nodes.map(node => [node.id, node]));
  if (els.planningResetLayoutButton) els.planningResetLayoutButton.hidden = state.planningNodePositions.size === 0;
  const board = document.createElement('div');
  board.className = 'planning-board planning-canvas-board';
  const stats = planningGraphStats(graph);
  const visibleStats = planningReadinessStats(visibleRows);
  const summary = document.createElement('div');
  summary.className = 'planning-summary';
  summary.innerHTML = `
    <strong>${number(scope.length)}/${number(selected.length)} ${escapeHtml(t('workspaces'))}</strong>
    <strong>${number(stats.nodeCount)} ${escapeHtml(t('planning.nodes'))}</strong>
    <strong>${number(stats.edgeCount)} ${escapeHtml(t('planning.dependencies'))}</strong>
    <strong class="planning-critical-duration">${escapeHtml(t('planning.criticalPathDuration'))}: ${escapeHtml(formatDuration(stats.criticalPathSeconds)) || '0s'}</strong>
    <strong>${number(stats.blockerCount)} ${escapeHtml(t('planning.blockerCount'))}</strong>
    ${stats.failedNodeCount ? `<strong class="planning-failed-count">${number(stats.failedNodeCount)} ${escapeHtml(t('planning.failedNodeCount'))}</strong>` : ''}
    <strong>${number(visibleStats.modelCount)} ${escapeHtml(t('planning.affectedModels'))}</strong>
  `;
  board.append(summary);

  if (!graph.nodes.length) {
    const empty = document.createElement('div');
    empty.className = 'empty-state';
    empty.textContent = t('planning.noReadiness');
    board.append(empty);
    els.treeStage.append(board);
    return;
  }

  // Free-floating canvas, no wave/column panels: a real Fabric/Data Factory
  // pipeline canvas doesn't box activities into labeled groups, it just
  // places them left-to-right by dependency and lets the connectors carry
  // the ordering information. The opaque column background was also
  // hiding edges that should have routed behind/between cards. Left-to-
  // right position by wave is kept as the *default* placement only --
  // cards are still freely draggable afterward.
  const canvas = document.createElement('div');
  canvas.className = 'planning-canvas planning-canvas-freeform';
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.classList.add('planning-edges');

  const surface = document.createElement('div');
  surface.className = 'planning-canvas-surface';
  // The SVG has to live *inside* the surface, not as its sibling under
  // .planning-canvas: .planning-canvas has padding-top: 56px, which pushes
  // the surface (a normal-flow child) down by that much -- but an
  // absolutely-positioned inset:0 child ignores its ancestor's padding when
  // resolving its own position, anchoring to the padding box's edge
  // instead. That gave the SVG and the surface two coordinate origins 56px
  // apart, so a path computed to land exactly on a card's border (correct,
  // by the numbers) painted noticeably above every card -- a real,
  // consistent, reproducible offset, not a one-off glitch. Appending the
  // SVG first, before any cards, keeps it painted behind them via plain DOM
  // order with no z-index needed, while sharing the exact same origin.
  surface.append(svg);
  canvas.append(surface);

  // A hand-rolled single-pass barycenter placement was still just stacking
  // crossing-minimized order inside fixed column boxes -- real spacing
  // improved, but the underlying shape was still "columns," not a flow.
  // dagre (vendored: frontend/semantic-lineage/vendor/dagre.min.js, MIT, zero
  // other runtime dependency) runs the actual Sugiyama pipeline this needs:
  // network-simplex rank assignment, iterative median-heuristic crossing
  // reduction, and Brandes-Kopf coordinate assignment -- the same class of
  // algorithm behind every production DAG-pipeline canvas (Airflow, Data
  // Factory, dagre itself powers Mermaid's flowcharts). It only decides the
  // *default* position; cards stay freely draggable afterward exactly as
  // before, and dragged cards keep their own dynamic port routing in
  // renderPlanningEdges regardless of how the rest got placed.
  const MAX_LAYOUT_NODES = 500;
  const prioritizedNodes = graph.nodes.length > MAX_LAYOUT_NODES
    ? [...graph.nodes].sort((a, b) => planningNodeWeight(b) - planningNodeWeight(a)).slice(0, MAX_LAYOUT_NODES)
    : graph.nodes;
  const hiddenNodeCount = graph.nodes.length - prioritizedNodes.length;

  const cardByNodeId = new Map();
  for (const node of prioritizedNodes) {
    const card = planningCard(node);
    card.style.position = 'absolute';
    card.style.visibility = 'hidden';
    surface.append(card);
    cardByNodeId.set(node.id, card);
  }
  let moreEl = null;
  if (hiddenNodeCount > 0) {
    moreEl = document.createElement('div');
    moreEl.className = 'planning-more planning-more-freeform';
    moreEl.style.position = 'absolute';
    moreEl.style.visibility = 'hidden';
    moreEl.textContent = `+ ${number(hiddenNodeCount)} ${t('planning.hidden')}`;
    surface.append(moreEl);
  }

  // Planning gets its own zoom, independent of the shared els.treeStage
  // zoom/pan the other views use. The non-standard CSS `zoom` property
  // (used there) changes an element's *layout* size as it scales, which on
  // a huge absolutely-positioned canvas with a JS-managed scroll position
  // produced a canvas that scrolled to genuinely empty coordinates after a
  // few zoom steps -- cards and edges were each individually positioned
  // correctly, but the viewport ended up looking at a region with neither,
  // reading as "arrows and objects live on two different planes." A plain
  // `transform: scale()` on .planning-canvas itself does not have that
  // failure mode, but transform never changes an element's own layout
  // size -- so the *wrapper* around it needs an explicit natural*scale
  // pixel size for the browser's native scrolling to reach the zoomed
  // extent at all.
  const zoomWrapper = document.createElement('div');
  zoomWrapper.className = 'planning-zoom-wrapper';
  zoomWrapper.style.position = 'relative';
  canvas.style.transformOrigin = '0 0';
  zoomWrapper.append(canvas);
  board.append(zoomWrapper);
  els.treeStage.append(board);
  planningZoomWrapper = zoomWrapper;
  planningZoomCanvas = canvas;

  requestAnimationFrame(() => {
    // Two separate passes, not one write-then-read-then-write-again loop:
    // flipping every card visible first (all writes), THEN reading every
    // rect (all reads) costs one forced synchronous layout for the whole
    // batch. Interleaving them (as this used to) forces one layout PER
    // CARD -- on a large combined selection (hundreds of nodes) that reflow
    // cost alone was enough to read as a frozen/glitching canvas, verified
    // live 2026-07-18.
    for (const node of prioritizedNodes) {
      cardByNodeId.get(node.id).style.visibility = 'visible';
    }
    const sizeByNodeId = new Map();
    for (const node of prioritizedNodes) {
      const rect = cardByNodeId.get(node.id).getBoundingClientRect();
      sizeByNodeId.set(node.id, { width: rect.width, height: rect.height });
    }

    // Invisible TOPOLOGICAL columns (user rule 2026-07-17: arrows must
    // always travel rightward, with as many intermediate columns as
    // dependent notebooks need). graph.columns already carries the wave
    // layering -- every edge points to a strictly higher wave, so a
    // left-to-right column walk can never draw a backward arrow -- plus
    // barycenter crossing-minimized vertical order. Origins with no
    // upstream sit leftmost, models are forced into the rightmost column
    // (see buildPlanningGraph), and a chain like notebook -> staging ->
    // notebook -> silver gets its own intermediate columns instead of
    // folding back. Columns only decide the DEFAULT placement -- cards
    // stay freely draggable exactly as before. (An earlier pure type-lane
    // attempt -- one lane per kind -- drew multi-hop chains backward and
    // was rejected on sight; a dagre pass before that placed cards at
    // freeform coordinates that read as scattered.)
    const columns = graph.columns
      .map(column => ({ wave: column.wave, nodes: column.nodes.filter(node => cardByNodeId.has(node.id)) }))
      .filter(column => column.nodes.length);

    const LANE_GAP = 150;
    // Card height now comes solely from the label (planningCardWidth,
    // 2026-07-20) -- long subtexts wrap onto more lines than before, so a
    // gap sized for the old, wider/shorter cards reads as too tight once a
    // neighbor grows tall. This stacking loop already measures each card's
    // real getBoundingClientRect().height and reserves exactly that much
    // (not a fixed row height), so a taller card DOES push the next one
    // down -- the extra margin here is just breathing room between them.
    const CARD_GAP = 46;
    const MARGIN = 24;
    let laneX = MARGIN;
    let maxBottom = 0;
    columns.forEach((column, columnIndex) => {
      const laneWidth = Math.max(...column.nodes.map(node => sizeByNodeId.get(node.id).width));
      let y = MARGIN;
      for (const node of column.nodes) {
        const size = sizeByNodeId.get(node.id);
        const card = cardByNodeId.get(node.id);
        card.style.left = `${laneX + (laneWidth - size.width) / 2}px`;
        card.style.top = `${y}px`;
        // The rail router sorts/orders edge lanes by wave -- keep it fed
        // with the visual lane order, not the old dependency wave.
        node.wave = columnIndex;
        card.dataset.wave = columnIndex;
        y += size.height + CARD_GAP;
      }
      maxBottom = Math.max(maxBottom, y - CARD_GAP);
      laneX += laneWidth + LANE_GAP;
    });

    const surfaceWidth = Math.max(200, laneX - LANE_GAP + MARGIN);
    let surfaceHeight = Math.max(200, maxBottom + MARGIN);
    if (moreEl) {
      moreEl.style.left = '24px';
      moreEl.style.top = `${surfaceHeight + 12}px`;
      moreEl.style.visibility = 'visible';
      surfaceHeight += 52;
    }
    surface.style.width = `${surfaceWidth}px`;
    surface.style.height = `${surfaceHeight}px`;
    renderPlanningEdges(board, graph.edges);
    fitView();
  });
}

// The quick per-workspace scan button (11/17/21 + the item-lineage steps)
// never re-runs the orchestration analysis (06/07/13/24) that produces
// critical-path/parallel-candidate/schedule-conflict signals -- those only
// get recomputed by a full project refresh. So after someone scans a single
// workspace, its lineage can be newer than the orchestration signals shown
// for it here. Rather than silently showing possibly-stale recommendations,
// say plainly how old the orchestration analysis is.
function planningDataFreshnessNotice() {
  const refresh = (state.data && state.data.refresh) || {};
  const raw = refresh.latest_run_ended_at || refresh.status_generated_at || '';
  if (!raw) return null;
  const parsed = new Date(raw);
  const formatted = Number.isNaN(parsed.getTime()) ? raw : parsed.toLocaleString(state.lang === 'es' ? 'es-ES' : 'en-GB');
  return t('planning.freshnessNotice')(formatted);
}

function renderPlanningView() {
  const selected = selectedWorkspaceListForPlanning();
  els.treeStage.innerHTML = '';
  els.treeStage.classList.remove('semantic-stage', 'impact-stage');
  els.treeStage.classList.add('planning-stage');
  els.graphTitle.textContent = t('planningTitle');
  els.graphSubtitle.textContent = t('planningHint');

  if (!selected.length) {
    els.treeStage.innerHTML = `<div class="empty-state">${t('empty')}</div>`;
    return;
  }

  const scope = planningScopeWorkspaces(selected);
  const readiness = buildPlanningReadiness(scope);
  const visibleRows = filteredPlanningRows(readiness);
  const visibleStats = planningReadinessStats(visibleRows);
  els.graphSubtitle.textContent = `${t('planning.selectedScope')}: ${number(scope.length)} ${t('workspaces')} · ${number(visibleStats.sourceCount)} ${t('planning.dataGroups')} · ${number(visibleStats.modelCount)} ${t('planning.affectedModels')} · ${t('planning.humanOnly')}`;
  const graph = buildPlanningGraph(scope);
  renderPlanningCanvas(graph, readiness, visibleRows, selected, scope);
}

function formatDuration(seconds) {
  if (seconds === undefined || seconds === null || seconds === '') return '';
  const value = Number(seconds);
  if (!Number.isFinite(value)) return text(seconds);
  if (value < 60) return `${Math.round(value)}s`;
  const minutes = Math.floor(value / 60);
  const remaining = Math.round(value % 60);
  if (minutes < 60) return `${minutes}m ${remaining}s`;
  const hours = Math.floor(minutes / 60);
  return `${hours}h ${minutes % 60}m`;
}

function formatAge(hours) {
  if (hours === undefined || hours === null || hours === '') return '';
  const value = Number(hours);
  if (!Number.isFinite(value)) return text(hours);
  if (value < 1) return state.lang === 'es' ? 'menos de 1h' : 'less than 1h';
  if (value < 48) return `${Math.round(value)}h`;
  return `${Math.round(value / 24)}d`;
}

function refreshStatusLabel(status) {
  if (status === 'completed') return t('refresh.completed');
  if (status === 'failed') return t('refresh.failed');
  return t('refresh.unknownStatus');
}

function commandLabel(id) {
  const labels = {
    'local-artifacts': state.lang === 'es' ? 'Artefactos locales' : 'Local artifacts',
    'local-artifacts-visual': state.lang === 'es' ? 'Local + validación visual' : 'Local + visual validation',
    'read-only-inventory': state.lang === 'es' ? 'Inventario read-only' : 'Read-only inventory',
    'full-read-only': state.lang === 'es' ? 'Lectura completa' : 'Full read-only',
    'full-read-only-tmdl': state.lang === 'es' ? 'Lectura completa + TMDL' : 'Full read-only + TMDL'
  };
  return labels[id] || id;
}

function commandHint(id) {
  const hints = {
    'local-artifacts': t('refresh.useLocal'),
    'local-artifacts-visual': t('refresh.useLocalVisual'),
    'read-only-inventory': t('refresh.useInventory'),
    'full-read-only': t('refresh.useFull'),
    'full-read-only-tmdl': t('refresh.useTmdl')
  };
  return hints[id] || '';
}

function artifactLabel(path) {
  const labels = {
    'index/workspaces.csv': state.lang === 'es' ? 'Workspaces' : 'Workspaces',
    'index/items.csv': state.lang === 'es' ? 'Items inventariados' : 'Items',
    'index/dependencies.csv': state.lang === 'es' ? 'Dependencias' : 'Dependencies',
    'index/executions.csv': state.lang === 'es' ? 'Ejecuciones' : 'Executions',
    'graph/nodes.csv': state.lang === 'es' ? 'Nodos del grafo' : 'Graph nodes',
    'graph/edges.csv': state.lang === 'es' ? 'Aristas del grafo' : 'Graph edges',
    'analysis/orchestration_recommendations.csv': state.lang === 'es' ? 'Recomendaciones' : 'Recommendations',
    'frontend/semantic-lineage/data/lineage-explorer.json': state.lang === 'es' ? 'JSON del explorador' : 'Explorer JSON',
    'frontend/semantic-lineage/standalone.html': state.lang === 'es' ? 'HTML standalone' : 'Standalone HTML',
    'analysis/visual-validation/playwright-results.json': 'Playwright',
    'config/source_migration_map.csv': state.lang === 'es' ? 'Mapa migración' : 'Migration map'
  };
  return labels[path] || path;
}

function visualValidationText(refresh) {
  const visual = refresh && refresh.visual_validation ? refresh.visual_validation : null;
  if (!visual) return '';
  return `${visual.expected || 0} ${t('refresh.passed')} · ${visual.unexpected || 0} ${t('refresh.failedCount')} · ${visual.skipped || 0} ${t('refresh.skipped')}`;
}

function artifactRows(refresh) {
  const artifacts = refresh && Array.isArray(refresh.artifacts) ? refresh.artifacts : [];
  return artifacts.map(artifact => {
    if (!artifact.exists) return row(artifactLabel(artifact.path), t('refresh.none'));
    const parts = [
      artifact.modified_at ? `${t('refresh.modified')}: ${artifact.modified_at}` : '',
      artifact.age_hours !== null && artifact.age_hours !== undefined ? `${t('refresh.age')}: ${formatAge(artifact.age_hours)}` : '',
      artifact.lines ? `${number(artifact.lines)} ${t('refresh.lines')}` : ''
    ].filter(Boolean);
    return row(artifactLabel(artifact.path), parts.join(' · '));
  });
}

function showReinvestigate() {
  // Clears the current node selection so anything that re-renders the
  // detail panel based on state.selectedNode (e.g. loadCertificationsAndTags'
  // async refresh, see 2026-08-18 code review finding) doesn't clobber this
  // panel with a stale previously-selected node once its own fetch resolves.
  state.selectedNode = null;
  state.showDetails = true;
  applyLayoutState();
  const refresh = (state.data && state.data.refresh) || {};
  const commands = Array.isArray(refresh.commands) ? refresh.commands : [];
  els.detailTitle.textContent = t('reinvestigateTitle');
  els.detailSubtitle.textContent = t('reinvestigateHint');
  els.detailContent.innerHTML = `
    <h3>${escapeHtml(t('reinvestigateTitle'))}</h3>
    <p>${escapeHtml(t('reinvestigateHint'))}</p>
    ${section(t('refresh.latest'), [
      row(t('refresh.packageGenerated'), refresh.status_generated_at),
      row(t('refresh.runLog'), refresh.latest_run_log),
      row(t('refresh.manifest'), refresh.manifest_path),
      row(t('refresh.mode'), refresh.latest_run_mode),
      row(t('refresh.status'), refreshStatusLabel(refresh.latest_run_status)),
      row(t('refresh.started'), refresh.latest_run_started_at),
      row(t('refresh.ended'), refresh.latest_run_ended_at),
      row(t('refresh.duration'), formatDuration(refresh.latest_run_duration_seconds)),
      row(t('refresh.visual'), visualValidationText(refresh))
    ], true)}
    ${section(t('refresh.commands'), commands.map(command =>
      row(commandLabel(command.id), `${command.command} · ${t('refresh.external')}: ${externalSystemLabel(command.external_systems)}`)
    ), true)}
    ${section(t('refresh.when'), commands.map(command =>
      row(commandLabel(command.id), commandHint(command.id))
    ), false)}
    ${section(t('refresh.artifacts'), artifactRows(refresh), false)}
    ${section(t('refresh.safety'), [
      row(state.lang === 'es' ? 'Ejecución' : 'Execution', t('refresh.safetyText')),
      row(state.lang === 'es' ? 'Aprobación' : 'Approval', state.lang === 'es'
        ? 'Antes de cualquier cambio operacional fuera del repositorio, la última acción debe ser aprobación y ejecución humana.'
        : 'Before any operational change outside the repository, the final action must be human approval and execution.')
    ], true)}
  `;
}

function csvEscape(value) {
  const raw = text(value);
  return /[",\r\n;]/.test(raw) ? `"${raw.replace(/"/g, '""')}"` : raw;
}

function safeFilename(value) {
  return text(value || 'lineage-selection')
    .replace(/[^a-z0-9._-]+/gi, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 120) || 'lineage-selection';
}

function addCsvRow(rows, relation, entity, data = {}) {
  if (!entity && !data) return;
  const isObjectLike = (entity && entity.kind === 'object') || data.object_name || data.object_display_name || data.schema || data.schema_name;
  const label = isObjectLike
    ? canonicalObjectDisplayName(data)
    : (entity && entity.label || data.label || data.object_display_name || data.object_name || data.qualified_name || '');
  rows.push({
    relation,
    entity_type: entity && (entity.kind || entity.item_type || entity.source_type || entity.type) || '',
    workspace_name: data.workspace_name || data.name || '',
    item_type: data.item_type || '',
    label,
    qualified_name: data.qualified_name || data.object_key || '',
    source_type: sourceTypeDisplay(data.source_type) || data.source_server || '',
    database: data.database || data.source_database || '',
    schema: data.schema || data.schema_name || '',
    object_name: data.object_name || data.name || '',
    object_type: data.type || data.object_type || data.raw_object_type || data.object_type_values || '',
    latest_status: data.execution && data.execution.latest_status || '',
    avg_duration_seconds: data.execution && data.execution.avg_duration_seconds || '',
    schedule_enabled_count: data.execution && data.execution.enabled_schedules || ''
  });
}

function selectedNodeCsvRows(node) {
  const rows = [];
  if (!node) return rows;
  const data = node.data || {};
  addCsvRow(rows, 'selected', node, data);

  for (const source of asList(data.sources)) {
    const sourceNode = { kind: 'source', label: source.label || source.database || source.server || sourceTypeDisplay(source.source_type), data: source };
    addCsvRow(rows, 'source', sourceNode, source);
    for (const object of asList(source.objects)) {
      const objectData = {
        ...object,
        workspace_name: object.workspace_name || source.workspace_name,
        source_type: object.source_type || source.source_type,
        database: object.database || source.database,
        source_database: object.source_database || source.database
      };
      const objectNode = { kind: 'object', label: canonicalObjectDisplayName(objectData, source), data: objectData };
      addCsvRow(rows, 'source_object', objectNode, objectData);
    }
  }
  if (node.kind === 'source') {
    for (const object of asList(data.objects)) {
      addCsvRow(rows, 'source_object', { kind: 'object', label: canonicalObjectDisplayName(object, data), data: object }, object);
    }
  }
  for (const item of asList(data.reports)) addCsvRow(rows, 'report', { kind: 'report', label: item.label, data: item }, item);
  for (const item of asList(data.downstream_reports)) addCsvRow(rows, 'downstream_report', { kind: 'report', label: item.label, data: item }, item);
  for (const item of asList(data.models)) addCsvRow(rows, 'semantic_model', { kind: 'item', label: item.label, data: item }, item);
  for (const item of asList(data.executes)) addCsvRow(rows, 'executes', { kind: kindForItem(item, 'item'), label: item.label, data: item }, item);
  for (const item of asList(data.direct_items)) addCsvRow(rows, 'direct_impact', { kind: kindForItem(item, 'item'), label: item.label, data: item }, item);
  if (node.kind === 'workspace') {
    for (const item of asList(data.all).slice(0, 2000)) addCsvRow(rows, 'workspace_item', { kind: kindForItem(item, 'item'), label: item.label, data: item }, item);
  }
  return rows;
}

function lineageExportObjectFiltersApply() {
  return ['semantic', 'notebooks', 'copyjobs', 'pipelines', 'dataflows'].includes(state.mode);
}

function lineageExportObjectVisible(source, object) {
  if (!lineageExportObjectFiltersApply()) return true;
  if (!diagramObjectTypeMatches(object)) return false;
  if (state.diagramObjectSelectionMode === 'none') return false;
  if (state.diagramObjectSelectionMode === 'custom') {
    return state.diagramSelectedObjectKeys.has(diagramObjectKey(source, object));
  }
  return true;
}

function lineageExportVisibleObjectsForSource(source) {
  return asList(source.objects).filter(object => lineageExportObjectVisible(source, object));
}

function lineageExportSourceVisible(source) {
  if (!diagramSourceTypeMatches(source)) return false;
  if (!lineageExportObjectFiltersApply()) return true;
  if (state.filters.diagramStore !== 'all' && diagramStoreKey(source) !== state.filters.diagramStore) return false;
  const objects = asList(source.objects);
  if (!objects.length) {
    return state.filters.diagramObjectType === 'all' && state.diagramObjectSelectionMode === 'all';
  }
  return objects.some(object => lineageExportObjectVisible(source, object));
}

function workspaceDeploymentOrWorkspaceLabel(workspace) {
  const deployment = workspace && workspace.deployment_pipeline ? workspace.deployment_pipeline : {};
  return deployment.has_pipeline
    ? (deployment.deployment_pipeline_name || workspace.name || '')
    : (workspace && workspace.name || '');
}

function workspaceEnvironmentLabel(workspace) {
  const deployment = workspace && workspace.deployment_pipeline ? workspace.deployment_pipeline : {};
  return deployment.stage_name || workspace.stage_name || workspace.environment || '';
}

function lineageDirectionLabel(role) {
  const labels = state.lang === 'es'
    ? { read: 'Origen', write: 'Destino', execute: 'Ejecutado', reference: 'Referencia' }
    : { read: 'Source', write: 'Target', execute: 'Executed', reference: 'Reference' };
  return labels[role] || labels.reference;
}

function lineageObjectTypeForExport(object) {
  return objectTypeLabel(diagramObjectRawType(object));
}

function lineageSourceLabelForExport(source) {
  return planningSourceReadableLabel(source);
}

function lineageExcelBaseRow(workspace, item, source, parentItem = null) {
  const d = i18n[state.lang].detail;
  return {
    dp_or_workspace: workspaceDeploymentOrWorkspaceLabel(workspace),
    environment: workspaceEnvironmentLabel(workspace),
    workspace_name: workspace.name || item.workspace_name || '',
    item_type: itemTypeLabel(item.item_type || ''),
    nb_or_item: item.label || item.qualified_name || '',
    parent_item: parentItem ? (parentItem.label || parentItem.qualified_name || '') : '',
    source_or_target: source ? lineageSourceLabelForExport(source) : '',
    source_type: source ? sourceTypeLabel(source.source_type) : '',
    source_database: source ? (source.database || source.source_database || source.label || '') : '',
    final_object: '',
    object_type: '',
    direction: '',
    qualified_name: item.qualified_name || '',
    generated_at: new Date().toISOString(),
    view: `${els.graphTitle.textContent || ''} · ${els.graphSubtitle.textContent || ''}`,
    selection: state.selectedNode ? state.selectedNode.label : d.inspectedScope
  };
}

function pushLineageExcelObjectRow(rows, workspace, item, source, object, role, parentItem = null) {
  rows.push({
    ...lineageExcelBaseRow(workspace, item, source, parentItem),
    direction: lineageDirectionLabel(role),
    final_object: object ? diagramObjectLabel(object, source) : '',
    object_type: object ? lineageObjectTypeForExport(object) : '',
    source_database: object && (object.database || object.source_database)
      ? (object.database || object.source_database)
      : (source.database || source.source_database || source.label || ''),
    qualified_name: object && object.qualified_name || item.qualified_name || ''
  });
}

function addLineageExcelRowsForItem(rows, workspace, item, options = {}) {
  if (!item) return;
  const visited = options.visited || new Set();
  const selectedWorkspaceNames = options.selectedWorkspaceNames || new Set();
  const workspaceByName = options.workspaceByName || new Map();
  const depth = options.depth || 0;
  const parentItem = options.parentItem || null;
  const key = item.qualified_name || `${workspace.name}|${item.item_type}|${item.label}`;
  if (visited.has(key) || depth > 4) return;
  visited.add(key);

  for (const source of asList(item.sources)) {
    if (!lineageExportSourceVisible(source)) continue;
    const objects = lineageExportVisibleObjectsForSource(source);
    if (objects.length) {
      objects.forEach(object => pushLineageExcelObjectRow(
        rows,
        workspace,
        item,
        source,
        object,
        objectLineageRoleForSource(source, item, object),
        parentItem
      ));
    } else {
      sourceInferredLineageRoles(source, item).forEach(role => pushLineageExcelObjectRow(
        rows,
        workspace,
        item,
        source,
        null,
        role,
        parentItem
      ));
    }
  }

  for (const child of asList(item.executes)) {
    const childWorkspaceName = child.workspace_name || workspace.name;
    if (selectedWorkspaceNames.size && childWorkspaceName && !selectedWorkspaceNames.has(childWorkspaceName)) continue;
    addLineageExcelRowsForItem(rows, workspaceByName.get(childWorkspaceName) || workspace, child, {
      visited,
      selectedWorkspaceNames,
      workspaceByName,
      depth: depth + 1,
      parentItem: item
    });
  }
}

function lineageExcelRows() {
  const selected = selectedLineageWorkspaceList();
  const selectedWorkspaceNames = new Set(selected.map(workspace => workspace.name));
  const workspaceByName = workspaceMapByName(selected);
  const rows = [];
  const visited = new Set();
  selected.forEach(workspace => {
    modeItems(workspace).forEach(item => addLineageExcelRowsForItem(rows, workspace, item, {
      visited,
      selectedWorkspaceNames,
      workspaceByName
    }));
  });
  return uniqueBy(rows, rowData => [
    rowData.dp_or_workspace,
    rowData.environment,
    rowData.workspace_name,
    rowData.item_type,
    rowData.nb_or_item,
    rowData.parent_item,
    rowData.direction,
    rowData.source_or_target,
    rowData.source_database,
    rowData.object_type,
    rowData.final_object,
    rowData.qualified_name
  ].join('|'));
}

function buildLineageExcelHtml() {
  const d = i18n[state.lang].detail;
  const rows = lineageExcelRows();
  const columns = [
    ['dp_or_workspace', d.excelDpOrWorkspace],
    ['environment', d.environment],
    ['workspace_name', d.workspace],
    ['item_type', d.type],
    ['nb_or_item', d.excelNotebookOrItem],
    ['parent_item', d.excelParentItem],
    ['direction', d.excelDirection],
    ['source_or_target', d.excelSourceOrTarget],
    ['source_type', d.sourceType],
    ['source_database', d.database],
    ['object_type', d.type],
    ['final_object', d.excelFinalObject],
    ['qualified_name', d.qualified]
  ];
  const summaryRows = [
    [d.excelGenerated, new Date().toISOString()],
    [d.pdfView, `${els.graphTitle.textContent || ''} · ${els.graphSubtitle.textContent || ''}`],
    [d.pdfSelection, state.selectedNode ? state.selectedNode.label : d.inspectedScope],
    [t('mode.' + state.mode), rows.length],
    [t('workspaces'), selectedLineageWorkspaceList().map(workspace => workspace.name).join(', ')]
  ];
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; }
    h1 { font-size: 18px; }
    h2 { font-size: 14px; margin-top: 18px; }
    table { border-collapse: collapse; width: 100%; }
    th { background: #e8eef7; font-weight: 700; }
    th, td { border: 1px solid #9fb0c5; font-size: 11px; padding: 5px; vertical-align: top; }
  </style>
</head>
<body>
  <h1>${escapeHtml(d.excelLineageList)}</h1>
  <table>
    <tbody>
      ${summaryRows.map(([label, value]) => `<tr><th>${escapeHtml(label)}</th><td>${escapeHtml(value)}</td></tr>`).join('')}
    </tbody>
  </table>
  <h2>${escapeHtml(d.excelFinalObject)}</h2>
  <table>
    <thead><tr>${columns.map(([, label]) => `<th>${escapeHtml(label)}</th>`).join('')}</tr></thead>
    <tbody>
      ${rows.map(rowData => `<tr>${columns.map(([key]) => `<td>${escapeHtml(rowData[key])}</td>`).join('')}</tr>`).join('')}
    </tbody>
  </table>
</body>
</html>`;
}

function downloadLineageExcel() {
  const content = buildLineageExcelHtml();
  const blob = new Blob([content], { type: 'application/vnd.ms-excel;charset=utf-8' });
  downloadBlob(blob, `${safeFilename((state.selectedNode && state.selectedNode.label) || 'lineage-list')}.xls`);
}

function impactItemCategoryLabel(item, downstream = false) {
  if (downstream) return t('impactLabels.downstreamReports');
  if (item.item_type === 'Notebook') return t('impactLabels.notebooks');
  if (item.item_type === 'SemanticModel') return t('impactLabels.semanticModels');
  if (['Report', 'PaginatedReport', 'Dashboard', 'KQLDashboard'].includes(item.item_type)) return t('impactLabels.reports');
  if (item.item_type === 'CopyJob') return t('impactLabels.copyjobs');
  if (item.item_type === 'DataPipeline') return t('impactLabels.pipelines');
  if (item.item_type === 'Dataflow') return t('impactLabels.dataflows');
  return t('impactLabels.otherElements');
}

function usageTypeLabel(value) {
  const d = i18n[state.lang].detail;
  return value ? (d.usageTypeLabels[value] || value) : '';
}

function impactExecutionLabel(item) {
  const execution = (item && item.execution) || {};
  return [
    execution.latest_start || '',
    execution.latest_status ? jobStatusLabel(execution.latest_status) : ''
  ].filter(Boolean).join(' · ');
}

// categoryKey, when given, scopes the rows to one impact-breakdown-modal
// category (see impactCategoryItems) instead of every direct_item/
// downstream_report -- used by downloadImpactBreakdownExcel() for the
// per-badge export. Without it (the general per-object export), every
// category is included, same as before.
function impactExcelRows(data, categoryKey = null) {
  const rows = [];
  const sourceObjectName = impactObjectFilterLabel(data);
  const addImpactRow = (item, scope) => {
    if (!item) return;
    rows.push({
      source_object: sourceObjectName || data.object_display_name || data.object_name || '',
      source_type: sourceTypeDisplay(data.source_type),
      source_server: data.source_server || '',
      source_database: data.source_database || '',
      schema_name: data.schema_name || '',
      object_name: data.object_name || '',
      object_type: impactObjectTypeLabel(data),
      impact_scope: scope,
      impact_category: impactItemCategoryLabel(item, scope === 'downstream_report'),
      affected_workspace: item.workspace_name || '',
      affected_item_type: itemTypeLabel(item.item_type || ''),
      affected_item_name: item.label || '',
      affected_qualified_name: item.qualified_name || '',
      semantic_table: item.semantic_table || '',
      usage_type: item.usage_type || '',
      usage_type_label: usageTypeLabel(item.usage_type),
      confidence_label: confidenceValueLabel(item.confidence),
      last_execution: impactExecutionLabel(item),
      default_identity: item.default_identity || '',
      source_label: item.source_label || '',
      evidence: item.evidence || '',
      impact_path: impactPathLabel(item.impact_path || '')
    });
  };
  if (categoryKey) {
    impactCategoryItems(data, categoryKey).forEach(item =>
      addImpactRow(item, item.impact_path === 'source_object -> semantic_model -> report' ? 'downstream_report' : 'direct_impact')
    );
  } else {
    asList(data.direct_items).forEach(item => addImpactRow(item, 'direct_impact'));
    asList(data.downstream_reports).forEach(item => addImpactRow(item, 'downstream_report'));
  }
  return uniqueBy(rows, rowData => [
    rowData.impact_scope,
    rowData.affected_qualified_name,
    rowData.semantic_table,
    rowData.usage_type,
    rowData.impact_path
  ].join('|'));
}

function buildImpactExcelHtml(node) {
  const data = node && node.data ? node.data : {};
  const d = i18n[state.lang].detail;
  const rows = impactExcelRows(data);
  const columns = [
    ['source_object', state.lang === 'es' ? 'Objeto origen' : 'Source object'],
    ['source_type', d.sourceType],
    ['source_server', d.sourceServer],
    ['source_database', d.database],
    ['schema_name', state.lang === 'es' ? 'Schema' : 'Schema'],
    ['object_name', d.name],
    ['object_type', d.type],
    ['impact_scope', state.lang === 'es' ? 'Alcance impacto' : 'Impact scope'],
    ['impact_category', state.lang === 'es' ? 'Categoria' : 'Category'],
    ['affected_workspace', d.workspace],
    ['affected_item_type', d.type],
    ['affected_item_name', d.name],
    ['affected_qualified_name', d.qualified],
    ['semantic_table', d.semanticTable],
    ['usage_type_label', d.usageType],
    ['confidence_label', d.confidence],
    ['last_execution', d.latestStart],
    ['default_identity', d.defaultIdentity],
    ['source_label', t('source')],
    ['evidence', d.evidence],
    ['impact_path', d.impactPath]
  ];
  const summaryRows = [
    [d.excelGenerated, new Date().toISOString()],
    [d.objectKey, data.object_key || ''],
    [state.lang === 'es' ? 'Objeto' : 'Object', data.object_display_name || data.object_name || ''],
    [t('impactLabels.affectedItems'), data.affected_item_count || 0],
    [t('impactLabels.downstreamReports'), data.downstream_report_count || 0],
    [t('impactLabels.totalImpact'), data.total_impact_count || rows.length]
  ];
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; }
    h1 { font-size: 18px; }
    h2 { font-size: 14px; margin-top: 18px; }
    table { border-collapse: collapse; width: 100%; }
    th { background: #e8eef7; font-weight: 700; }
    th, td { border: 1px solid #9fb0c5; font-size: 11px; padding: 5px; vertical-align: top; }
  </style>
</head>
<body>
  <h1>${escapeHtml(d.excelImpactList)}</h1>
  <table>
    <tbody>
      ${summaryRows.map(([label, value]) => `<tr><th>${escapeHtml(label)}</th><td>${escapeHtml(value)}</td></tr>`).join('')}
    </tbody>
  </table>
  <h2>${escapeHtml(t('impactLabels.directImpact'))}</h2>
  <table>
    <thead><tr>${columns.map(([, label]) => `<th>${escapeHtml(label)}</th>`).join('')}</tr></thead>
    <tbody>
      ${rows.map(rowData => `<tr>${columns.map(([key]) => `<td>${escapeHtml(rowData[key])}</td>`).join('')}</tr>`).join('')}
    </tbody>
  </table>
</body>
</html>`;
}

function downloadImpactExcel(node = state.selectedNode) {
  if (!node || node.kind !== 'impactObject') return;
  const content = buildImpactExcelHtml(node);
  const blob = new Blob([content], { type: 'application/vnd.ms-excel;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `${safeFilename(node.label || 'impact-list')}.xls`;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function plainPdfText(value) {
  return text(value)
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^\x20-\x7e]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function wrapPdfText(value, maxChars = 86) {
  const words = plainPdfText(value).split(/\s+/).filter(Boolean);
  const lines = [];
  let line = '';
  for (const word of words) {
    if (!line) {
      line = word;
      continue;
    }
    if ((line.length + word.length + 1) > maxChars) {
      lines.push(line);
      line = word;
    } else {
      line += ` ${word}`;
    }
  }
  if (line) lines.push(line);
  return lines.length ? lines : [''];
}

function drawWrappedCanvasText(ctx, value, x, y, maxWidth, lineHeight, maxLines = 3) {
  const words = text(value).split(/\s+/).filter(Boolean);
  const lines = [];
  let line = '';
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (ctx.measureText(candidate).width > maxWidth && line) {
      lines.push(line);
      line = word;
      if (lines.length >= maxLines) break;
    } else {
      line = candidate;
    }
  }
  if (line && lines.length < maxLines) lines.push(line);
  lines.forEach((entry, index) => ctx.fillText(entry, x, y + index * lineHeight));
}

function diagramSnapshotElements() {
  const selector = [
    '.planning-card',
    '.planning-readiness-source',
    '.planning-readiness-model',
    '.semantic-model-card',
    '.semantic-source-main',
    '.semantic-report-card',
    '.semantic-object-row',
    '.flow-card',
    '.impact-card',
    '.impact-table tbody tr'
  ].join(',');
  return Array.from(els.treeStage.querySelectorAll(selector)).filter(element => {
    const rect = element.getBoundingClientRect();
    return rect.width > 8 && rect.height > 8;
  });
}

function diagramSnapshotBounds(elements) {
  const rootSelector = [
    '.diagram-stage-selector',
    '.flow-board',
    '.semantic-board',
    '.impact-board',
    '.planning-canvas-board',
    '.planning-canvas',
    '.empty-state'
  ].join(',');
  const roots = Array.from(els.treeStage.querySelectorAll(rootSelector));
  const rects = [...roots, ...elements]
    .map(element => element.getBoundingClientRect())
    .filter(rect => rect.width > 8 && rect.height > 8);
  if (!rects.length) return null;
  return {
    left: Math.min(...rects.map(rect => rect.left)),
    top: Math.min(...rects.map(rect => rect.top)),
    right: Math.max(...rects.map(rect => rect.right)),
    bottom: Math.max(...rects.map(rect => rect.bottom))
  };
}

function snapshotCanvasRatio(cssWidth, cssHeight, options = {}) {
  const compact = Boolean(options.compact);
  if (compact) return 1;
  const maxSide = options.maxSide || 32760;
  const maxPixels = options.maxPixels || 260000000;
  const maxRatio = options.maxRatio || 3;
  return Math.min(
    maxRatio,
    maxSide / Math.max(1, cssWidth),
    maxSide / Math.max(1, cssHeight),
    Math.sqrt(maxPixels / Math.max(1, cssWidth * cssHeight))
  );
}

function createSnapshotCanvas(cssWidth, cssHeight, preferredRatio) {
  let outputRatio = Math.max(0.2, preferredRatio || 1);
  while (outputRatio >= 0.2) {
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.ceil(cssWidth * outputRatio));
    canvas.height = Math.max(1, Math.ceil(cssHeight * outputRatio));
    const ctx = canvas.getContext('2d', { alpha: false });
    if (ctx) return { canvas, ctx, outputRatio };
    outputRatio *= 0.72;
  }
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.ceil(cssWidth));
  canvas.height = Math.max(1, Math.ceil(cssHeight));
  return { canvas, ctx: canvas.getContext('2d'), outputRatio: 1 };
}

function createDiagramSnapshotCanvas(options = {}) {
  const compact = Boolean(options.compact);
  const elements = diagramSnapshotElements();
  const bounds = diagramSnapshotBounds(elements);
  const pad = compact ? 34 : 48;
  const topPad = compact ? 106 : 118;
  const contentWidth = bounds ? Math.max(1, bounds.right - bounds.left) : 900;
  const contentHeight = bounds ? Math.max(1, bounds.bottom - bounds.top) : 420;
  const cssWidth = compact ? 1400 : Math.ceil(contentWidth + pad * 2);
  const cssHeight = compact ? 760 : Math.ceil(contentHeight + topPad + pad);
  const preferredRatio = snapshotCanvasRatio(cssWidth, cssHeight, { compact, ...options });
  const { canvas, ctx, outputRatio } = createSnapshotCanvas(cssWidth, cssHeight, preferredRatio);
  if (!ctx) return canvas;
  ctx.scale(outputRatio, outputRatio);
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, cssWidth, cssHeight);
  ctx.fillStyle = '#17202a';
  ctx.font = compact ? '700 24px Segoe UI, Arial, sans-serif' : '700 28px Segoe UI, Arial, sans-serif';
  ctx.fillText(plainPdfText(els.graphTitle.textContent || t('title')), pad, compact ? 42 : 48);
  ctx.fillStyle = '#647283';
  ctx.font = compact ? '600 15px Segoe UI, Arial, sans-serif' : '600 17px Segoe UI, Arial, sans-serif';
  drawWrappedCanvasText(ctx, els.graphSubtitle.textContent || '', pad, compact ? 68 : 78, cssWidth - pad * 2, compact ? 19 : 22, 3);

  if (!elements.length || !bounds) {
    ctx.fillStyle = '#647283';
    ctx.font = '700 22px Segoe UI, Arial, sans-serif';
    ctx.fillText(plainPdfText(t('empty')), pad, topPad + 44);
    return canvas;
  }

  const rects = elements.map(element => ({
    element,
    rect: element.getBoundingClientRect(),
    text: element.innerText || element.textContent || ''
  }));
  const minX = bounds.left;
  const minY = bounds.top;
  const availableWidth = cssWidth - pad * 2;
  const availableHeight = cssHeight - topPad - pad;
  const layoutScale = compact
    ? Math.min(availableWidth / Math.max(1, contentWidth), availableHeight / Math.max(1, contentHeight), 1.12)
    : 1;
  const toX = x => pad + (x - minX) * layoutScale;
  const toY = y => topPad + (y - minY) * layoutScale;

  const drawSvgPaths = selector => {
    for (const path of Array.from(els.treeStage.querySelectorAll(selector))) {
      const d = path.getAttribute('d');
      if (!d || typeof Path2D === 'undefined') continue;
      const svg = path.ownerSVGElement;
      if (!svg) continue;
      const svgRect = svg.getBoundingClientRect();
      ctx.save();
      ctx.translate(toX(svgRect.left), toY(svgRect.top));
      ctx.scale(layoutScale, layoutScale);
      ctx.strokeStyle = path.classList.contains('planning-edge-model') ? '#b45309' :
        path.classList.contains('planning-edge-execute') ? '#2563eb' :
          path.classList.contains('flow-edge') ? '#64748b' : '#475569';
      ctx.lineWidth = 2.2;
      ctx.globalAlpha = 0.52;
      ctx.stroke(new Path2D(d));
      ctx.restore();
    }
  };
  drawSvgPaths('.flow-edge, .planning-edge');

  for (const { element, rect, text: labelText } of rects) {
    const x = toX(rect.left);
    const y = toY(rect.top);
    const width = Math.max(54, rect.width * layoutScale);
    const height = Math.max(22, rect.height * layoutScale);
    const isSelected = element.classList.contains('selected');
    const className = Array.from(element.classList || []).join(' ');
    const isSemantic = className.includes('semantic') || className.includes('type-semantic');
    const isSource = className.includes('source') || className.includes('lakehouse') || className.includes('sql');
    const border = isSelected ? '#2563eb' : isSemantic ? '#7c3aed' : isSource ? '#0f766e' : '#94a3b8';
    ctx.fillStyle = '#ffffff';
    ctx.strokeStyle = border;
    ctx.lineWidth = isSelected ? 3 : 1.7;
    ctx.beginPath();
    ctx.roundRect(x, y, width, height, 8);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = border;
    ctx.fillRect(x, y, 5, height);
    ctx.fillStyle = '#17202a';
    ctx.font = `${Math.max(10, Math.min(15, 13 * layoutScale))}px Segoe UI, Arial, sans-serif`;
    const textLineLimit = compact ? 3 : 8;
    const compactText = labelText.split('\n').map(part => part.trim()).filter(Boolean).slice(0, textLineLimit).join(' · ');
    const lineHeight = Math.max(12, 14 * layoutScale);
    const maxLines = Math.max(1, Math.min(compact ? 4 : 8, Math.floor((height - 10) / lineHeight)));
    drawWrappedCanvasText(ctx, compactText, x + 12, y + 18, Math.max(48, width - 22), lineHeight, maxLines);
  }
  return canvas;
}

function pdfEscapeString(value) {
  return `(${plainPdfText(value).replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)')})`;
}

function latin1Bytes(value) {
  const bytes = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index += 1) bytes[index] = value.charCodeAt(index) & 0xff;
  return bytes;
}

function concatBytes(parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const output = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function pdfTextLine(textValue, x, y, size = 10, leading = 13) {
  const lines = wrapPdfText(textValue, Math.max(18, Math.floor((540 - x) / (size * 0.48))));
  return lines.map((line, index) =>
    `BT /F1 ${size} Tf 1 0 0 1 ${x.toFixed(2)} ${(y - index * leading).toFixed(2)} Tm ${pdfEscapeString(line)} Tj ET`
  ).join('\n');
}

function jpegBytesFromDataUrl(dataUrl) {
  const base64 = dataUrl.split(',')[1] || '';
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function selectedPdfSummaryRows(node) {
  const data = node && node.data ? node.data : {};
  const csvRows = selectedNodeCsvRows(node);
  const rows = [
    [i18n[state.lang].detail.pdfGenerated, new Date().toISOString()],
    [i18n[state.lang].detail.pdfView, `${els.graphTitle.textContent || ''} · ${els.graphSubtitle.textContent || ''}`],
    [i18n[state.lang].detail.pdfSelection, node ? node.label : t('details')],
    [i18n[state.lang].detail.type, node ? nodeKindLabel(node.kind) : ''],
    [i18n[state.lang].detail.workspace, data.name || data.workspace_name],
    [i18n[state.lang].detail.qualified, data.qualified_name || data.object_key],
    [i18n[state.lang].detail.avgDuration, data.execution && data.execution.avg_duration_seconds ? formatDuration(data.execution.avg_duration_seconds) : ''],
    [i18n[state.lang].detail.latestStatus, data.execution && data.execution.latest_status ? jobStatusLabel(data.execution.latest_status) : '']
  ].filter(entry => entry[1]);
  if (node && node.kind === 'impactObject') {
    const categories = [
      [t('impactLabels.notebooks'), impactCategoryItems(data, 'notebooks')],
      [t('impactLabels.semanticModels'), impactCategoryItems(data, 'semantic')],
      [t('impactLabels.reports'), impactCategoryItems(data, 'reports')],
      [t('impactLabels.copyjobs'), impactCategoryItems(data, 'copyjobs')],
      [t('impactLabels.pipelines'), impactCategoryItems(data, 'pipelines')],
      [t('impactLabels.dataflows'), impactCategoryItems(data, 'dataflows')],
      [t('impactLabels.otherElements'), impactCategoryItems(data, 'other')]
    ];
    rows.push(
      [t('impactLabels.totalImpact'), number(data.total_impact_count || 0)],
      [t('impactLabels.workspaces'), number(data.workspace_count || asList(data.workspaces).length || 0)]
    );
    categories.forEach(([label, items]) => {
      if (!items.length) return;
      const examples = items.slice(0, 5).map(item => item.label || item.qualified_name).filter(Boolean).join(' | ');
      const hidden = items.length > 5 ? ` | + ${number(items.length - 5)}` : '';
      rows.push([label, `${number(items.length)} - ${examples}${hidden}`]);
    });
  }
  const relationRows = csvRows.slice(0, 24).map(rowData => [
    rowData.relation,
    [rowData.label, rowData.workspace_name, rowData.item_type, rowData.object_name].filter(Boolean).join(' · ')
  ]);
  if (csvRows.length > relationRows.length) {
    relationRows.push([i18n[state.lang].detail.pdfAdditionalRows, `+ ${number(csvRows.length - relationRows.length)}`]);
  }
  return [...rows, ...relationRows];
}

function buildSelectionPdf(node, canvas) {
  const pageWidth = 595.28;
  const pageHeight = 841.89;
  const margin = 34;
  const imageMaxWidth = pageWidth - margin * 2;
  const imageMaxHeight = 318;
  const imageScale = Math.min(imageMaxWidth / canvas.width, imageMaxHeight / canvas.height);
  const imageWidth = canvas.width * imageScale;
  const imageHeight = canvas.height * imageScale;
  const imageX = margin;
  const imageY = pageHeight - margin - 72 - imageHeight;
  const jpegData = canvas.toDataURL('image/jpeg', 0.84);
  const imageBytes = jpegBytesFromDataUrl(jpegData);
  const rows = selectedPdfSummaryRows(node);

  const content = [];
  content.push(pdfTextLine(t('title'), margin, pageHeight - margin, 18, 20));
  content.push(pdfTextLine(node ? node.label : t('details'), margin, pageHeight - margin - 25, 12, 15));
  content.push(pdfTextLine(i18n[state.lang].detail.pdfDiagram, margin, pageHeight - margin - 52, 11, 14));
  content.push(`q ${imageWidth.toFixed(2)} 0 0 ${imageHeight.toFixed(2)} ${imageX.toFixed(2)} ${imageY.toFixed(2)} cm /Im0 Do Q`);
  let y = imageY - 26;
  content.push(pdfTextLine(i18n[state.lang].detail.pdfSummary, margin, y, 12, 15));
  y -= 20;
  for (const [label, value] of rows) {
    if (y < margin + 16) break;
    const labelText = plainPdfText(label).slice(0, 28);
    const valueLines = wrapPdfText(value, 76).slice(0, 2);
    content.push(`BT /F1 8.5 Tf 1 0 0 1 ${margin.toFixed(2)} ${y.toFixed(2)} Tm ${pdfEscapeString(labelText)} Tj ET`);
    content.push(`BT /F1 8.5 Tf 1 0 0 1 ${(margin + 112).toFixed(2)} ${y.toFixed(2)} Tm ${pdfEscapeString(valueLines[0] || '')} Tj ET`);
    if (valueLines[1] && y > margin + 30) {
      y -= 10;
      content.push(`BT /F1 8.5 Tf 1 0 0 1 ${(margin + 112).toFixed(2)} ${y.toFixed(2)} Tm ${pdfEscapeString(valueLines[1])} Tj ET`);
    }
    y -= 14;
  }
  const stream = content.join('\n');

  const objects = [
    latin1Bytes('<< /Type /Catalog /Pages 2 0 R >>'),
    latin1Bytes('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    latin1Bytes(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageWidth} ${pageHeight}] /Resources << /Font << /F1 4 0 R >> /XObject << /Im0 5 0 R >> >> /Contents 6 0 R >>`),
    latin1Bytes('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
    concatBytes([
      latin1Bytes(`<< /Type /XObject /Subtype /Image /Width ${canvas.width} /Height ${canvas.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${imageBytes.length} >>\nstream\n`),
      imageBytes,
      latin1Bytes('\nendstream')
    ]),
    latin1Bytes(`<< /Length ${latin1Bytes(stream).length} >>\nstream\n${stream}\nendstream`)
  ];

  const parts = [latin1Bytes('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n')];
  const offsets = [0];
  for (let index = 0; index < objects.length; index += 1) {
    offsets[index + 1] = parts.reduce((sum, part) => sum + part.length, 0);
    parts.push(latin1Bytes(`${index + 1} 0 obj\n`));
    parts.push(objects[index]);
    parts.push(latin1Bytes('\nendobj\n'));
  }
  const xrefOffset = parts.reduce((sum, part) => sum + part.length, 0);
  const xrefRows = ['xref', `0 ${objects.length + 1}`, '0000000000 65535 f '];
  for (let index = 1; index <= objects.length; index += 1) {
    xrefRows.push(`${String(offsets[index]).padStart(10, '0')} 00000 n `);
  }
  parts.push(latin1Bytes(`${xrefRows.join('\n')}\ntrailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`));
  return concatBytes(parts);
}

async function downloadSelectedPdf(node = state.selectedNode) {
  if (!node) return;
  const canvas = createDiagramSnapshotCanvas({ compact: true });
  const pdfBytes = buildSelectionPdf(node, canvas);
  const blob = new Blob([pdfBytes], { type: 'application/pdf' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `${safeFilename(node.label || 'lineage-selection')}.pdf`;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function waitForPaint() {
  return new Promise(resolve => {
    window.requestAnimationFrame(() => window.requestAnimationFrame(resolve));
  });
}

function collectFlowExpansionIds() {
  const ids = new Set(state.expanded);
  const visit = node => {
    if (!node) return;
    const children = childrenForNode(node);
    if (children.length) {
      ids.add(node.id);
      if (node.original_id) ids.add(node.original_id);
    }
    children.forEach(visit);
  };
  selectedRootNodes().forEach(visit);
  return ids;
}

function collectSemanticSnapshotExpansionIds(ids) {
  if (state.viewMode !== 'lineage' || state.mode !== 'semantic') return ids;
  semanticSelectedModels().forEach(({ model }) => {
    asList(model.sources).filter(sourceVisible).forEach((source, sourceIndex) => {
      if (!asList(source.objects).length) return;
      const sourceId = `semantic:${model.qualified_name || model.label}:source:${sourceIndex}`;
      ids.add(`semantic-objects:${sourceId}`);
    });
  });
  return ids;
}

async function createExpandedDiagramSnapshotCanvas(options = {}) {
  const previousExpanded = new Set(state.expanded);
  const snapshot = viewportScrollSnapshot();
  const previousSnapshotExport = state.snapshotExport;
  try {
    state.snapshotExport = true;
    els.treeStage.classList.add('snapshot-export-stage');
    state.view.scale = 1;
    applyTransform();
    const expansionIds = state.viewMode === 'lineage' && state.mode === 'semantic'
      ? new Set(state.expanded)
      : collectFlowExpansionIds();
    state.expanded = collectSemanticSnapshotExpansionIds(expansionIds);
    renderTree();
    state.view.scale = 1;
    applyTransform();
    await waitForPaint();
    els.treeStage.querySelectorAll('details.semantic-object-more').forEach(details => {
      details.open = true;
    });
    await waitForPaint();
    return createDiagramSnapshotCanvas({
      compact: false,
      maxRatio: options.maxRatio || 3,
      maxPixels: options.maxPixels || 260000000,
      maxSide: options.maxSide || 32760
    });
  } finally {
    state.snapshotExport = previousSnapshotExport;
    els.treeStage.classList.remove('snapshot-export-stage');
    state.expanded = previousExpanded;
    renderTree();
    restoreViewportScroll(snapshot);
    applyLayoutState();
  }
}

function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function canvasToBlob(canvas, type = 'image/png', quality) {
  return new Promise(resolve => canvas.toBlob(resolve, type, quality));
}

async function downloadSelectedDiagramPng(node = state.selectedNode) {
  if (!node) return;
  let canvas = await createExpandedDiagramSnapshotCanvas();
  let blob = await canvasToBlob(canvas, 'image/png');
  if (!blob) {
    canvas = await createExpandedDiagramSnapshotCanvas({ maxRatio: 1.5, maxPixels: 140000000, maxSide: 30000 });
    blob = await canvasToBlob(canvas, 'image/png');
  }
  if (!blob) return;
  downloadBlob(blob, `${safeFilename(node.label || 'lineage-diagram')}-diagrama.png`);
}

// El PDF se quitó del todo (2026-07-20, "no sirve") -- sólo PNG/Excel.
// En Inspección/Planificación esas dos opciones viven ahora en su mapa
// (igual que Planificación ya hacía), no en este panel; este generador
// sigue en pie sólo para el panel de detalle de Impacto, que no cambió.
function detailExportHtml(options = {}) {
  const d = i18n[state.lang].detail;
  const impactExcel = Boolean(options.impactExcel);
  const hint = impactExcel ? d.excelExportHint : d.lineageExcelHint;
  return `
    <div class="detail-actions">
      <button id="detailPngExport" class="detail-export-button" type="button">${escapeHtml(d.exportPng)}</button>
      <button id="detailExcelExport" class="detail-export-button" type="button">${escapeHtml(d.exportExcel)}</button>
      <span>${escapeHtml(hint)}</span>
    </div>
  `;
}

function row(label, value, title = '', glossaryTerm = '') {
  if (value === undefined || value === null || value === '') return '';
  const titleAttr = title ? ` title="${escapeHtml(title)}"` : '';
  const infoIcon = glossaryTerm
    ? ` <button type="button" class="info-icon-button" data-glossary-term="${escapeHtml(glossaryTerm)}" aria-label="${escapeHtml(t('glossary.iconLabel'))}">ⓘ</button>`
    : '';
  return `<div><span>${escapeHtml(label)}${infoIcon}</span><p${titleAttr}>${escapeHtml(value)}</p></div>`;
}

// Owner/admin fields arrive as a single "; "-joined string (see
// Convert-AdminsToText in 02_normalize_workspaces.ps1) -- one person per
// line within a single card reads cleaner than either the original inline
// "; "-joined line or a separate bordered card per person. Newlines survive
// escapeHtml() untouched; .detail-grid p renders them via white-space:
// pre-line (see styles.css).
function peopleRows(label, value) {
  const people = text(value).split(';').map(person => person.trim()).filter(Boolean);
  return people.length ? [row(label, people.join('\n'))] : [];
}

function linkRow(label, url, displayText) {
  if (!url) return '';
  return `<div><span>${escapeHtml(label)}</span><p><a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(displayText || url)}</a></p></div>`;
}

// confidence/evidence/notes are computed for every lineage edge and object
// classification but were previously dropped before reaching the UI --
// this surfaces them as a hover tooltip on the existing compact row instead
// of adding more visible rows to lists the user asked to keep compact.
function confidenceValueLabel(value) {
  if (!value) return '';
  return (i18n[state.lang].confidenceLabels && i18n[state.lang].confidenceLabels[value]) || value;
}

function analysisStatusLabel(value) {
  const d = i18n[state.lang].detail;
  if (value === 'analyzed') return d.analysisStatusAnalyzed;
  if (value === 'partial') return d.analysisStatusPartial;
  return text(value);
}

function edgeEvidenceTitle(entry) {
  if (!entry) return '';
  const d = i18n[state.lang].detail;
  const parts = [
    entry.confidence ? `${d.confidence}: ${confidenceValueLabel(entry.confidence)}` : '',
    entry.evidence ? `${d.evidence}: ${entry.evidence}` : '',
    entry.notes ? `${d.analysisNotes}: ${entry.notes}` : ''
  ].filter(Boolean);
  return parts.join('\n');
}

function section(title, rows, open = false) {
  const visible = rows.filter(Boolean);
  if (!visible.length) return '';
  return `<details class="detail-section"${open ? ' open' : ''}><summary>${escapeHtml(title)}</summary><div class="detail-grid">${visible.join('')}</div></details>`;
}

function executionRows(execution) {
  const data = execution || {};
  const d = i18n[state.lang].detail;
  return [
    row(d.schedules, `${data.enabled_schedules || 0} ${t('enabled')} · ${data.disabled_schedules || 0} ${t('disabled')}`),
    row(d.scheduledTime, data.scheduled_times),
    row(d.avgDuration, data.avg_duration_seconds ? formatDuration(data.avg_duration_seconds) : d.noData),
    row(d.runs, data.runs || 0),
    row(d.failures, data.failed_runs || 0),
    row(d.latestStatus, data.latest_status ? jobStatusLabel(data.latest_status) : ''),
    row(d.latestStart, data.latest_start),
    row(d.latestEnd, data.latest_end)
  ];
}

function planningRows(data) {
  const planning = data && data.planning ? data.planning : null;
  const d = i18n[state.lang].detail;
  const yes = t('yes');
  const defaultRecommendation = 'Stabilize before optimizing schedule or parallelism.';
  if (!planning) {
    return [row(d.recommendationHint, recommendationHintLabel(defaultRecommendation))];
  }
  return [
    row(d.criticalPath, planning.critical_path ? `${yes}${planning.critical_rank ? ` #${planning.critical_rank}` : ''}` : ''),
    row(d.failureHotspot, planning.failure_hotspot ? `${yes}${planning.failure_rate ? ` · ${planning.failure_rate}` : ''}` : ''),
    row(d.parallelCandidates, Number(planning.parallel_candidate_count || 0) > 0 ? planning.parallel_candidate_count : ''),
    row(d.orchestrationGroup, planning.orchestration_group ? `${yes}${planning.executes_count ? ` · ${planning.executes_count}` : ''}` : ''),
    row(d.recommendationHint, recommendationHintLabel(planning.recommendation_hint || defaultRecommendation))
  ];
}

// Sustituye a planningRows() + el array inline de planningEvidenceRows que
// vivía en renderDetails(): mismos diez campos (última llegada, ruta
// crítica, punto crítico de fallos...), pero como pares {label, value} en
// crudo en vez de HTML de row() ya renderizado -- así el mismo dato sirve
// tanto para decidir si el botón se muestra como para llenar la tabla del
// popup (2026-07-20: ese bloque ocupaba demasiado sitio siempre abierto
// dentro del panel de detalle; ahora es un botón que abre esto en un popup
// aparte, con columnas Campo/Valor en vez de fila-a-fila apilado).
function planningEvidenceEntries(data) {
  const d = i18n[state.lang].detail;
  const yes = t('yes');
  const defaultRecommendation = 'Stabilize before optimizing schedule or parallelism.';
  const planning = data && data.planning ? data.planning : null;
  const entries = [
    [d.latestArrival, data.planning_arrival_evidence],
    [d.upstreamItem, data.planning_upstream_item],
    [d.affectedModels, data.planning_affected_model_count ? number(data.planning_affected_model_count) : ''],
    [d.objectCount, data.planning_object_count ? number(data.planning_object_count) : ''],
    [t('source'), data.planning_source_label]
  ];
  if (!planning) {
    entries.push([d.recommendationHint, recommendationHintLabel(defaultRecommendation)]);
  } else {
    entries.push(
      [d.criticalPath, planning.critical_path ? `${yes}${planning.critical_rank ? ` #${planning.critical_rank}` : ''}` : ''],
      [d.failureHotspot, planning.failure_hotspot ? `${yes}${planning.failure_rate ? ` · ${planning.failure_rate}` : ''}` : ''],
      [d.parallelCandidates, Number(planning.parallel_candidate_count || 0) > 0 ? planning.parallel_candidate_count : ''],
      [d.orchestrationGroup, planning.orchestration_group ? `${yes}${planning.executes_count ? ` · ${planning.executes_count}` : ''}` : ''],
      [d.recommendationHint, recommendationHintLabel(planning.recommendation_hint || defaultRecommendation)]
    );
  }
  return entries
    .filter(([, value]) => value !== undefined && value !== null && value !== '')
    .map(([label, value]) => ({ label, value: text(value) }));
}

function impactDetailItemRows(items, limit = 20) {
  const list = asList(items);
  const visible = list.slice(0, limit);
  const rows = visible.map(item => {
    const label = [itemTypeLabel(item.item_type), item.workspace_name].filter(Boolean).join(' · ');
    const value = [
      item.label || item.qualified_name,
      item.semantic_table ? `${state.lang === 'es' ? 'Tabla semántica' : 'Semantic table'}: ${item.semantic_table}` : '',
      item.impact_path ? impactPathLabel(item.impact_path) : ''
    ].filter(Boolean).join(' · ');
    return row(label, value);
  });
  const hidden = list.length - visible.length;
  if (hidden > 0) rows.push(row(t('impactLabels.itemPreview'), `+ ${number(hidden)} ${t('impactLabels.hiddenItems')}`));
  return rows;
}

function detailItemRows(items, limit = 16) {
  const d = i18n[state.lang].detail;
  const list = asList(items);
  const visible = list.slice(0, limit);
  const rows = visible.map(item => {
    const label = [
      itemTypeLabel(item.item_type),
      item.workspace_name || item.environment
    ].filter(Boolean).join(' · ') || nodeKindLabel('item');
    const execution = item.execution || {};
    const value = [
      item.label || item.qualified_name,
      item.semantic_table ? `${d.semanticTable}: ${item.semantic_table}` : '',
      execution.latest_start ? `${d.latestStart}: ${execution.latest_start}` : '',
      execution.latest_status ? jobStatusLabel(execution.latest_status) : ''
    ].filter(Boolean).join(' · ');
    return row(label, value, edgeEvidenceTitle(item));
  });
  const hidden = list.length - visible.length;
  if (hidden > 0) rows.push(row(d.hiddenRows, `+ ${number(hidden)}`));
  return rows;
}

const ROLE_RANK = { Admin: 0, Member: 1, Contributor: 2, Viewer: 3 };

// A deployment pipeline groups several workspaces (one per stage/environment).
// Someone's access can differ per stage, so this collapses that into one
// list -- one row per person, keeping their highest-ranked role across every
// stage in the pipeline -- for both the compact list badge and the detail panel.
function mergedRoleAssignmentsForWorkspaces(workspaces) {
  const list = asList(workspaces);
  if (list.length === 1) return asList(list[0] && list[0].role_assignments);
  const byPrincipal = new Map();
  for (const workspace of list) {
    for (const assignment of asList(workspace && workspace.role_assignments)) {
      if (!assignment.principal_id) continue;
      const existing = byPrincipal.get(assignment.principal_id);
      if (!existing || (ROLE_RANK[assignment.role] ?? 9) < (ROLE_RANK[existing.role] ?? 9)) {
        byPrincipal.set(assignment.principal_id, assignment);
      }
    }
  }
  return [...byPrincipal.values()];
}

function bestRoleAssignmentAcrossWorkspaces(workspaces) {
  if (!authState.objectId) return null;
  return mergedRoleAssignmentsForWorkspaces(workspaces).find(entry => entry.principal_id === authState.objectId) || null;
}

function detailRoleAssignmentRows(roleAssignments, limit = 30) {
  const d = i18n[state.lang].detail;
  const list = asList(roleAssignments);
  const sorted = [...list].sort((a, b) => {
    const isYouA = a.principal_id && a.principal_id === authState.objectId;
    const isYouB = b.principal_id && b.principal_id === authState.objectId;
    if (isYouA !== isYouB) return isYouA ? -1 : 1;
    const rankDiff = (ROLE_RANK[a.role] ?? 9) - (ROLE_RANK[b.role] ?? 9);
    if (rankDiff !== 0) return rankDiff;
    return (a.principal_name || '').localeCompare(b.principal_name || '');
  });
  const visible = sorted.slice(0, limit);
  const rows = visible.map(assignment => {
    const isYou = assignment.principal_id && assignment.principal_id === authState.objectId;
    const label = [
      assignment.principal_name,
      isYou ? `(${d.yourRoleBadge})` : ''
    ].filter(Boolean).join(' ');
    return row(label, roleLabel(assignment.role));
  });
  const hidden = sorted.length - visible.length;
  if (hidden > 0) rows.push(row(d.hiddenRows, `+ ${number(hidden)}`));
  return rows;
}

function invocationParameterRows(activities) {
  const d = i18n[state.lang].detail;
  return asList(activities).map(activity => {
    const params = activity && activity.parameters;
    if (!params || typeof params !== 'object') return '';
    const pairs = Object.entries(params).filter(([, value]) => value !== undefined && value !== null && value !== '');
    if (!pairs.length) return '';
    const label = activity.activity_name ? `${d.invocationParameters} (${activity.activity_name})` : d.invocationParameters;
    const value = pairs.map(([key, value]) => `${key}: ${value}`).join(' · ');
    return row(label, value, JSON.stringify(params, null, 2));
  }).filter(Boolean);
}

function detailSourceRows(sources, limit = 12) {
  const d = i18n[state.lang].detail;
  const uniqueSources = uniqueBy(asList(sources), source => sourceKey(source));
  const visible = uniqueSources.slice(0, limit);
  const rows = visible.map(source => {
    const title = planningSourceReadableLabel(source);
    const objectCount = asList(source.objects).length;
    const value = [
      planningSourceReadableMeta(source, title),
      objectCount ? `${number(objectCount)} ${d.objectCount}` : ''
    ].filter(Boolean).join(' · ');
    return row(title, value, edgeEvidenceTitle(source));
  });
  const hidden = uniqueSources.length - visible.length;
  if (hidden > 0) rows.push(row(d.hiddenRows, `+ ${number(hidden)}`));
  return rows;
}

function detailSourceObjectRows(sourcesOrObjects, limit = 28) {
  const d = i18n[state.lang].detail;
  const objects = asList(sourcesOrObjects).flatMap(entry => entry && entry.objects ? asList(entry.objects) : [entry]).filter(Boolean);
  const uniqueObjects = uniqueBy(objects, object => objectKey(object));
  const visible = uniqueObjects.slice(0, limit);
  const rows = visible.map(object => {
    const dynamicVariable = unresolvedVariableName(object);
    const schema = semanticObjectSchema(object);
    const value = [
      dynamicVariable ? '' : objectTypeLabel(object.type || object.object_type || object.raw_object_type),
      semanticObjectDisplayName(object),
      object.semantic_table ? `${d.semanticTable}: ${object.semantic_table}` : ''
    ].filter(Boolean).join(' · ');
    const evidenceTitle = [
      object.object_type_confidence ? `${d.objectTypeConfidence}: ${confidenceValueLabel(object.object_type_confidence)}` : '',
      edgeEvidenceTitle(object)
    ].filter(Boolean).join('\n');
    return row(schema, value, dynamicVariable ? d.dynamicVariableHint(dynamicVariable) : evidenceTitle);
  });
  const hidden = uniqueObjects.length - visible.length;
  if (hidden > 0) rows.push(row(d.hiddenRows, `+ ${number(hidden)}`));
  return rows;
}

function columnTypeDisplay(column) {
  const parts = [text(column.data_type || column.type)];
  const length = Number(column.max_length || 0);
  const precision = Number(column.precision || 0);
  const scale = Number(column.scale || 0);
  if (precision > 0) {
    parts.push(scale > 0 ? `(${precision},${scale})` : `(${precision})`);
  } else if (length > 0 && !['int', 'bigint', 'smallint', 'tinyint', 'bit', 'date', 'datetime', 'datetime2', 'uniqueidentifier'].includes(normalize(column.data_type || column.type))) {
    parts.push(`(${length})`);
  }
  return parts.filter(Boolean).join('');
}

function detailColumnRows(columns, limit = 60) {
  const d = i18n[state.lang].detail;
  const list = asList(columns);
  const visible = list.slice(0, limit);
  const rows = visible.map(column => {
    const flags = [
      column.is_nullable === false || column.is_nullable === 'False' || column.is_nullable === '0' ? '' : d.columnNullable
    ].filter(Boolean).join(' · ');
    return row(column.column_name || column.name, [columnTypeDisplay(column), flags].filter(Boolean).join(' · '));
  });
  const hidden = list.length - visible.length;
  if (hidden > 0) rows.push(row(d.hiddenRows, `+ ${number(hidden)}`));
  return rows;
}

function detailNoSelection() {
  const d = i18n[state.lang].detail;
  const selected = selectedWorkspaceList();
  els.detailTitle.textContent = t('details');
  els.detailSubtitle.textContent = selected.length
    ? `${t('planning.selectedScope')}: ${number(selected.length)} ${t('workspaces')}`
    : t('graphHint');
  els.detailContent.innerHTML = `
    <h3>${escapeHtml(t('details'))}</h3>
    <p>${escapeHtml(d.noSelection)}</p>
    ${selected.length ? section(d.inspectedScope, [
      row(t('workspaces'), selected.map(workspace => workspace.name).join(', '))
    ], true) : ''}
  `;
}

function renderImpactDetails(node) {
  const d = i18n[state.lang].detail;
  const data = node.data || {};
  const objectLabel = impactObjectFilterLabel(data);
  const directItems = asList(data.direct_items);
  const reports = asList(data.downstream_reports);
  const directImpactRows = directItems.length
    ? impactDetailItemRows(directItems, 24)
    : [row(t('impactLabels.noDetectedImpact'), '0')];
  const badges = [
    nodeKindLabel(node.kind),
    sourceTypeDisplay(data.source_type),
    impactObjectTypeLabel(data),
    `${number(data.total_impact_count)} ${t('impactLabels.totalImpact')}`
    // No certification/curated-tags badge here: admin-curated
    // qualified_name entries are item-level ("Workspace / Type / Name"),
    // a different namespace than an impact object's object_key
    // ("source_type|server|db|schema|table") -- they can never match, so
    // a lookup here would always silently be a no-op (2026-08-18 code
    // review finding). renderDetails's item-kind nodes are where this
    // actually applies.
  ].filter(Boolean);
  els.detailTitle.textContent = t('impactTitle');
  els.detailSubtitle.textContent = objectLabel || node.label;
  els.detailContent.innerHTML = `
    <h3>${escapeHtml(objectLabel || node.label)}</h3>
    <div class="badge-row">${badges.map(badge => `<span class="badge">${escapeHtml(badge)}</span>`).join('')}</div>
    ${detailExportHtml({ impactExcel: true })}
    ${section(t('impactLabels.sourceMetadata'), [
      row(d.objectKey, data.object_key),
      row(d.sourceType, sourceTypeDisplay(data.source_type)),
      row(d.sourceServer, data.source_server),
      row(d.database, data.source_database),
      row(d.schema, data.schema_name),
      row(d.table, data.object_name),
      row(d.name, objectLabel || data.object_name),
      row(d.type, impactObjectTypeLabel(data)),
      row(t('impactLabels.sqlEndpoint'), data.sql_endpoint_name),
      row(t('impactLabels.endpointResolution'), data.endpoint_resolution_method)
    ], true)}
    ${section(d.columns, detailColumnRows(data.columns), asList(data.columns).length > 0)}
    ${authState.signedIn && columnProfileParamsForObject(data) ? '<div id="columnProfileSection"></div>' : ''}
    ${section(t('impactLabels.summary'), [
      row(t('impactLabels.affectedItems'), data.affected_item_count),
      row(t('impactLabels.downstreamReports'), data.downstream_report_count),
      row(t('impactLabels.semanticModels'), data.semantic_model_count),
      row(t('impactLabels.notebooks'), data.notebook_count),
      row(t('impactLabels.copyjobs'), data.copyjob_count),
      row(t('impactLabels.pipelines'), data.pipeline_count),
      row(t('impactLabels.dataflows'), data.dataflow_count),
      row(t('impactLabels.workspaces'), data.workspace_count),
      row(t('workspaces'), asList(data.workspaces).join(', '))
    ], true)}
    ${section(t('impactLabels.directImpact'), directImpactRows, true)}
    ${section(t('impactLabels.downstream'), impactDetailItemRows(reports, 20), reports.length > 0)}
  `;
  const columnProfileParams = columnProfileParamsForObject(data);
  if (columnProfileParams) {
    loadColumnProfileSection(columnProfileParams.workspaceName, columnProfileParams.lakehouseName, columnProfileParams.tableName);
  }
}

// --- Comentarios y favoritos por nodo (roadmap Nivel 1, 2026-08-17) -----
// Async, cargado aparte del resto del panel de detalle (que ya está
// disponible en `node.data` sin esperar red): mismo patrón lazy-load-
// after-render que el panel admin usa para sus pestañas de solo lectura.
let nodeCommentsCache = {}; // qualified_name -> array de comentarios
let myFavoritesSet = null; // Set de qualified_name, null = todavía no cargado esta sesión

function formatNodeCommentTimestamp(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleString(state.lang === 'es' ? 'es-ES' : 'en-GB', { dateStyle: 'short', timeStyle: 'short' });
}

function renderNodeCommentsSection(qualifiedName) {
  const es = state.lang === 'es';
  const container = document.getElementById('nodeCommentsSection');
  if (!container) return;
  const comments = nodeCommentsCache[qualifiedName];
  const isFavorite = myFavoritesSet ? myFavoritesSet.has(qualifiedName) : false;
  const favoriteKnown = myFavoritesSet !== null;
  const commentsHtml = comments === undefined
    ? `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`
    : comments.length === 0
      ? `<p class="node-comments-empty">${es ? 'Todavía no hay comentarios.' : 'No comments yet.'}</p>`
      : `<div class="node-comments-list">${comments.map(c => `
        <div class="node-comment-row">
          <div class="node-comment-meta">
            <strong>${escapeHtml(c.author_name || c.author_email)}</strong>
            <span>${formatNodeCommentTimestamp(c.created_at)}</span>
          </div>
          <p class="node-comment-text">${escapeHtml(c.comment_text)}</p>
          ${(authState.userEmail === c.author_email || authState.isAdmin) ? `<button type="button" class="node-comment-delete" data-comment-id="${escapeHtml(c.comment_id)}">${es ? 'Borrar' : 'Delete'}</button>` : ''}
        </div>`).join('')}</div>`;
  container.innerHTML = `
    <details class="detail-section" open>
      <summary>
        ${es ? 'Comentarios y favoritos' : 'Comments & favorites'}
      </summary>
      <div class="node-comments-body">
        <button type="button"
          class="node-favorite-button${isFavorite ? ' active' : ''}"
          data-node-favorite-toggle="${escapeHtml(qualifiedName)}"
          ${favoriteKnown ? '' : 'disabled'}>
          <span aria-hidden="true">${isFavorite ? '★' : '☆'}</span>
          ${isFavorite ? (es ? 'Favorito' : 'Favorited') : (es ? 'Marcar como favorito' : 'Add to favorites')}
        </button>
        ${commentsHtml}
        <div class="node-comment-add">
          <textarea id="nodeCommentInput" rows="2" maxlength="4000" placeholder="${es ? 'Añade un comentario para tu equipo...' : 'Add a comment for your team...'}"></textarea>
          <button type="button" id="nodeCommentSubmit" data-node-comment-submit="${escapeHtml(qualifiedName)}">${es ? 'Comentar' : 'Comment'}</button>
        </div>
      </div>
    </details>`;
}

async function loadNodeCommentsSection(qualifiedName) {
  if (!authState.signedIn) return; // el contenedor ni se pinta sin sesión -- ver renderDetails
  const requests = [];
  if (nodeCommentsCache[qualifiedName] === undefined) {
    requests.push(
      fetch(`${TRIGGER_SERVER_ORIGIN}/api/node-comments?qualified_name=${encodeURIComponent(qualifiedName)}`)
        .then(r => (r.ok ? r.json() : { comments: [] }))
        .then(payload => { nodeCommentsCache[qualifiedName] = payload.comments || []; })
        .catch(() => { nodeCommentsCache[qualifiedName] = []; })
    );
  }
  if (myFavoritesSet === null) {
    requests.push(
      fetch(`${TRIGGER_SERVER_ORIGIN}/api/node-favorites/mine`)
        .then(r => (r.ok ? r.json() : { qualified_names: [] }))
        .then(payload => { myFavoritesSet = new Set(payload.qualified_names || []); })
        .catch(() => { myFavoritesSet = new Set(); })
    );
  }
  if (requests.length) await Promise.all(requests);
  // El usuario puede haber seleccionado otro nodo mientras la petición
  // estaba en vuelo -- solo repintar si seguimos mirando el mismo.
  if (state.selectedNode && (state.selectedNode.data || {}).qualified_name === qualifiedName) {
    renderNodeCommentsSection(qualifiedName);
  }
}

async function submitNodeComment(qualifiedName, button) {
  const input = document.getElementById('nodeCommentInput');
  const text = input ? input.value.trim() : '';
  if (!text) return;
  button.disabled = true;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/node-comments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ qualified_name: qualifiedName, comment_text: text }),
    });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({}));
      window.alert(payload.message || (state.lang === 'es' ? 'No se pudo publicar el comentario.' : 'Could not post the comment.'));
      return;
    }
    delete nodeCommentsCache[qualifiedName]; // fuerza recarga real en vez de empujar la respuesta local
    await loadNodeCommentsSection(qualifiedName);
  } finally {
    button.disabled = false;
  }
}

async function deleteNodeComment(commentId, qualifiedName) {
  const confirmMessage = state.lang === 'es' ? '¿Borrar este comentario?' : 'Delete this comment?';
  if (!window.confirm(confirmMessage)) return;
  try {
    await fetch(`${TRIGGER_SERVER_ORIGIN}/api/node-comments/delete`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ comment_id: commentId }),
    });
  } catch (error) {
    // best-effort -- la recarga de abajo muestra el estado real igualmente
  }
  delete nodeCommentsCache[qualifiedName];
  await loadNodeCommentsSection(qualifiedName);
}

async function toggleNodeFavorite(qualifiedName, button) {
  button.disabled = true;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/node-favorites/toggle`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ qualified_name: qualifiedName }),
    });
    if (!response.ok) return;
    const payload = await response.json();
    if (!myFavoritesSet) myFavoritesSet = new Set();
    if (payload.favorited) myFavoritesSet.add(qualifiedName);
    else myFavoritesSet.delete(qualifiedName);
    renderNodeCommentsSection(qualifiedName);
  } finally {
    button.disabled = false;
  }
}

// --- Perfil y sensibilidad de columnas (roadmap Fase 2, nativo de
// Fabric, 2026-08-18) -- carga async igual que comentarios/favoritos: no
// vive en el JSON estatico, solo cubre las tablas ya perfiladas (los
// Lakehouses donde la SP ya tenia acceso de datos, ver docs/105). Un
// resultado "found: false" es normal y esperado para la inmensa mayoria
// de las tablas, no un error.
let columnProfileCache = {}; // "workspace|lakehouse|table" -> {profile, sensitivity}

const CONTENT_SENSITIVITY_LABELS = {
  email: { es: 'Email', en: 'Email' },
  phone: { es: 'Teléfono', en: 'Phone' },
  national_id: { es: 'Identificación nacional', en: 'National ID' },
  financial: { es: 'Datos financieros', en: 'Financial data' },
};

function contentSensitivityLabel(category) {
  const entry = CONTENT_SENSITIVITY_LABELS[category];
  return entry ? entry[state.lang === 'es' ? 'es' : 'en'] : category;
}

function columnProfileCacheKey(workspaceName, lakehouseName, tableName) {
  return `${workspaceName}|${lakehouseName}|${tableName}`;
}

function renderColumnProfileSection(workspaceName, lakehouseName, tableName) {
  const es = state.lang === 'es';
  const container = document.getElementById('columnProfileSection');
  if (!container) return;
  const key = columnProfileCacheKey(workspaceName, lakehouseName, tableName);
  const cached = columnProfileCache[key];
  if (cached === undefined) {
    container.innerHTML = `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
    return;
  }
  const { profile, sensitivity } = cached;
  if (!profile.found && !sensitivity.found) {
    container.innerHTML = '';
    return;
  }
  const sensitivityByColumn = {};
  (sensitivity.columns || []).forEach(col => { sensitivityByColumn[col.column_name] = col.categories || []; });

  const columns = profile.found ? (profile.columns || []) : (sensitivity.columns || []).map(col => ({ column_name: col.column_name, data_type: col.data_type }));
  const rows = columns.map(col => {
    const cats = sensitivityByColumn[col.column_name] || [];
    const sensitivityBadges = cats
      .map(c => `<span class="badge sensitivity-badge">${escapeHtml(contentSensitivityLabel(c.category))} ${Math.round(c.match_percentage)}%</span>`)
      .join('');
    const statParts = [];
    if (col.null_percentage !== undefined) statParts.push(`${es ? 'nulos' : 'nulls'}: ${col.null_percentage}%`);
    if (col.distinct_count !== undefined && col.distinct_count !== null) statParts.push(`${es ? 'distintos' : 'distinct'}: ${number(col.distinct_count)}`);
    if (col.min_value !== undefined && col.min_value !== null) statParts.push(`min: ${escapeHtml(String(col.min_value))}`);
    if (col.max_value !== undefined && col.max_value !== null) statParts.push(`max: ${escapeHtml(String(col.max_value))}`);
    return `<div class="column-profile-row">
      <div class="column-profile-name">${escapeHtml(col.column_name)}</div>
      ${statParts.length ? `<div class="column-profile-stats">${statParts.join(' · ')}</div>` : ''}
      ${sensitivityBadges ? `<div class="column-profile-sensitivity">${sensitivityBadges}</div>` : ''}
    </div>`;
  }).join('');

  container.innerHTML = `
    <details class="detail-section" open>
      <summary>${es ? 'Perfil de columnas' : 'Column profile'}</summary>
      <p class="admin-field-hint">${es
        ? 'Estadísticas reales sobre una muestra de filas de esta tabla -- solo disponible para las tablas ya perfiladas.'
        : 'Real statistics from a sample of this table\'s rows -- only available for tables already profiled.'}</p>
      <div class="column-profile-list">${rows}</div>
    </details>`;
}

async function loadColumnProfileSection(workspaceName, lakehouseName, tableName) {
  if (!authState.signedIn || !workspaceName || !lakehouseName || !tableName) return;
  const key = columnProfileCacheKey(workspaceName, lakehouseName, tableName);
  if (columnProfileCache[key] === undefined) {
    const params = `workspace_name=${encodeURIComponent(workspaceName)}&lakehouse_name=${encodeURIComponent(lakehouseName)}&table_name=${encodeURIComponent(tableName)}`;
    const emptyResult = { found: false, columns: [] };
    const [profile, sensitivity] = await Promise.all([
      fetch(`${TRIGGER_SERVER_ORIGIN}/api/column-profile?${params}`).then(r => (r.ok ? r.json() : emptyResult)).catch(() => emptyResult),
      fetch(`${TRIGGER_SERVER_ORIGIN}/api/column-sensitivity?${params}`).then(r => (r.ok ? r.json() : emptyResult)).catch(() => emptyResult),
    ]);
    columnProfileCache[key] = { profile, sensitivity };
  }
  renderColumnProfileSection(workspaceName, lakehouseName, tableName);
}

// Fabric-native objects only (source_type "Fabric") -- source_database is
// the Lakehouse name, object_name is the table name (see build_graph_map_
// index.py/NB_Discover_Object_Lineage.py's own object_parts convention).
// Workspace isn't carried directly on every object shape, so this tries
// the most reliable field first and falls back to the aggregated
// workspaces list -- a wrong guess just yields "not profiled" (found:
// false), never wrong data, since the lookup is an exact match.
function columnProfileParamsForObject(data) {
  if (!data || data.source_type !== 'Fabric') return null;
  const workspaceName = data.workspace_name || (asList(data.workspaces)[0] || '');
  // The impact-search shape uses source_database/schema_name; the tree
  // "object" node shape uses database/schema -- same meaning, different
  // field names depending on which JSON payload built this node.
  const lakehouseName = data.source_database || data.database || '';
  const schemaName = data.schema_name || data.schema || '';
  const tableName = schemaName ? `${schemaName}.${data.object_name}` : (data.object_name || '');
  if (!workspaceName || !lakehouseName || !tableName) return null;
  return { workspaceName, lakehouseName, tableName };
}


function renderDetails(node) {
  if (!node) {
    detailNoSelection();
    return;
  }
  if (node.kind === 'impactObject') {
    renderImpactDetails(node);
    return;
  }
  const d = i18n[state.lang].detail;
  const data = node.data || {};
  const crossWorkspace = isCrossWorkspaceNode(node);
  const inspectedWorkspace = selectedWorkspace();
  const badges = [
    nodeKindLabel(node.kind),
    data.item_type ? itemTypeLabel(data.item_type) : '',
    sourceTypeDisplay(data.source_type),
    data.environment,
    crossWorkspace ? t('otherWorkspace') : '',
    data.qualified_name && certificationsByQualifiedName && certificationsByQualifiedName.has(data.qualified_name) ? d.certified : ''
  ].filter(Boolean);
  const migration = data.migration || {};
  const analysis = data.analysis || {};
  const operationRows = executionRows(data.execution);
  const planningEvidence = planningEvidenceEntries(data);
  const relatedSourceRows = detailSourceRows(asList(data.sources));
  const objectRows = node.kind === 'source'
    ? detailSourceObjectRows([data])
    : node.kind === 'object'
      ? detailSourceObjectRows([data], 1)
      : detailSourceObjectRows(asList(data.sources));
  const semanticTableRows = data.item_type === 'SemanticModel' ? detailSemanticTableRows(data) : [];
  const reportRows = detailItemRows(asList(data.reports).length ? asList(data.reports) : asList(data.downstream_reports));
  const modelRows = detailItemRows(asList(data.models));
  const columnRows = node.kind === 'object' ? detailColumnRows(data.columns) : [];
  // A deployment pipeline node covers every stage/environment workspace at
  // once, and a stage node covers the one workspace behind that stage --
  // both get the same "who has access" view as a plain workspace node.
  const roleWorkspaces = node.kind === 'workspace'
    ? [data]
    : node.kind === 'deploymentPipeline'
      ? asList(data.local_workspaces)
      : node.kind === 'deploymentStage'
        ? asList(data.workspace)
        : [];
  const roleAssignmentRows = roleWorkspaces.length ? detailRoleAssignmentRows(mergedRoleAssignmentsForWorkspaces(roleWorkspaces)) : [];
  const yourAssignment = roleWorkspaces.length ? bestRoleAssignmentAcrossWorkspaces(roleWorkspaces) : null;
  const detailType = node.kind === 'workspace'
    ? workspacePlatformLabel(data)
    : node.kind === 'deploymentPipeline'
      ? t('deploymentPipeline')
      : node.kind === 'deploymentStage'
        ? t('deploymentStage')
        : (node.kind === 'object' ? objectTypeLabel(data.type) : (itemTypeLabel(data.item_type) || data.type));
  currentPlanningEvidence = { title: node.label, entries: planningEvidence };
  els.detailTitle.textContent = t('details');
  els.detailSubtitle.textContent = node.label;
  els.detailContent.innerHTML = `
    <h3>${escapeHtml(node.label)}</h3>
    <div class="badge-row">${badges.map(badge => `<span class="badge">${escapeHtml(badge)}</span>`).join('')}</div>
    ${section(d.overview, [
      row(d.workspace, data.name || data.workspace_name),
      row(d.contextWorkspace, crossWorkspace && inspectedWorkspace ? inspectedWorkspace.name : ''),
      row(d.hostedWorkspace, crossWorkspace ? nodeWorkspaceName(node) : ''),
      row(d.environment, data.environment),
      row(t('productionWorkspace'), (node.kind === 'workspace' || data.workspace_name) && isProductionWorkspace(data) ? t('yes') : ''),
      row(d.type, detailType),
      linkRow(
        d.openInFabric,
        node.kind === 'workspace' ? fabricWorkspaceUrl(data.name) : (data.item_type ? fabricItemUrl(data) : ''),
        d.openInFabricText
      ),
      row(d.rawObjectType, node.kind === 'object' ? objectTypeLabel(data.raw_object_type) : ''),
      row(d.objectTypeSource, node.kind === 'object' ? objectTypeSourceLabel(data.object_type_source) : '', '', 'objectTypeSource'),
      row(d.objectTypeConfidence, node.kind === 'object' ? confidenceValueLabel(data.object_type_confidence) : '', '', 'confidence'),
      row(d.analysisStatus, ['item', 'model'].includes(node.kind) ? analysisStatusLabel(analysis.status) : '', '', 'analysisStatus'),
      row(d.lineageQuality, node.kind === 'item' ? lineageQualityLabel(node) : '', '', 'lineageQuality'),
      row(d.capacity, node.kind === 'workspace' ? workspaceCapacityValue(data) : data.capacity_name),
      row(d.capacityId, node.kind === 'workspace' ? data.capacity_id : ''),
      row(d.capacityRegion, node.kind === 'workspace' ? data.capacity_region : ''),
      row(d.description, data.description),
      row(d.sensitivityLabel, data.sensitivity_label),
      row(d.defaultIdentity, data.default_identity),
      row(d.tags, data.tags),
      row(d.curatedTags, curatedTagsDisplayValue(data.qualified_name)),
      row(d.dataProduct, dataProductsDisplayValue(data.qualified_name)),
      row(d.certifiedBy, certifiedByDisplayValue(data.qualified_name)),
      row(d.certifiedNote, (certificationEntryFor(data.qualified_name) || {}).note || ''),
      row(d.devopsRepo, node.kind === 'workspace' ? gitRepoDisplayValue(data.git) : ''),
      row(d.domain, data.domain_name),
      ...peopleRows(d.owner, data.owner),
      ...peopleRows(d.admins, data.admin_principals),
      row(d.yourRole, yourAssignment ? roleLabel(yourAssignment.role) : ''),
      row(d.deploymentPipeline, data.deployment_pipeline_name || (data.deployment_pipeline && data.deployment_pipeline.deployment_pipeline_name)),
      row(d.deploymentStage, data.stage_name || (data.deployment_pipeline && data.deployment_pipeline.stage_name)),
      row(d.stageOrder, data.stage_order || (data.deployment_pipeline && data.deployment_pipeline.stage_order)),
      row(d.stageWorkspace, data.local_workspace_name || data.workspace_name || (data.deployment_pipeline && data.deployment_pipeline.stage_workspace_name)),
      row(d.indexedWorkspaces, data.filtered_workspace_names ? data.filtered_workspace_names.join(', ') : ''),
      row(d.status, data.status || (data.deployment_pipeline && data.deployment_pipeline.status)),
      row(d.sharedUses, node.shared_count > 1 ? `${node.shared_count} ${t('uses')}` : ''),
      row(d.sourceCount, data.sources && data.sources.length ? number(data.sources.length) : ''),
      row(d.objectCount, node.kind === 'source' && data.objects ? number(data.objects.length) : ''),
      row(d.reportCount, data.reports && data.reports.length ? number(data.reports.length) : ''),
      row(d.qualified, data.qualified_name)
    ], true)}
    ${section(d.lineage, [
      row(d.sourceType, sourceTypeDisplay(data.source_type)),
      row(d.server, data.server),
      row(d.database, data.database),
      row(d.schema, node.kind === 'object' ? (data.schema || data.schema_name) : ''),
      row(d.table, node.kind === 'object' ? data.object_name : ''),
      row(d.pipelineActivity, data.activity_name),
      row(d.pipelineActivityType, data.activity_type),
      row(d.invokedItem, data.invoked_item_qualified_name),
      ...invocationParameterRows(data.invocation_activities),
      row(d.qualified, data.qualified_name || data.source_label),
      row(d.migration, migration.fabric_equivalent),
      row(d.migrationStatus, migration.status),
      row(d.confidence, ['source', 'object', 'report', 'model', 'execute'].includes(node.kind) ? confidenceValueLabel(data.confidence) : '', '', 'confidence'),
      row(d.evidence, ['source', 'object', 'report', 'model', 'execute'].includes(node.kind) ? data.evidence : ''),
      row(d.analysisNotes, data.notes || (['item', 'model'].includes(node.kind) ? analysis.notes : ''))
    ], node.kind !== 'workspace')}
    ${section(d.operations, operationRows, operationRows.length > 0)}
    ${planningEvidence.length ? `<div class="detail-actions"><button id="planningEvidenceButton" type="button" class="detail-export-button">${escapeHtml(d.planningEvidenceButton)}</button></div>` : ''}
    ${section(d.semanticTables, semanticTableRows, semanticTableRows.length > 0)}
    ${section(d.relatedSources, relatedSourceRows, node.kind === 'item' && relatedSourceRows.length > 0)}
    ${section(d.sourceObjectsBySchema, objectRows, node.kind === 'source' || node.kind === 'object')}
    ${section(d.columns, columnRows, columnRows.length > 0)}
    ${node.kind === 'object' && authState.signedIn && columnProfileParamsForObject(data) ? '<div id="columnProfileSection"></div>' : ''}
    ${section(d.accessRoles, roleAssignmentRows, false)}
    ${section(d.relatedReports, reportRows, false)}
    ${section(d.relatedModels, modelRows, false)}
    ${data.qualified_name && authState.signedIn ? `<div id="nodeCommentsSection" data-qualified-name="${escapeHtml(data.qualified_name)}"></div>` : ''}
  `;
  if (node.kind === 'object') {
    const columnProfileParams = columnProfileParamsForObject(data);
    if (columnProfileParams) {
      loadColumnProfileSection(columnProfileParams.workspaceName, columnProfileParams.lakehouseName, columnProfileParams.tableName);
    }
  }
  if (data.qualified_name && authState.signedIn) loadNodeCommentsSection(data.qualified_name);
}

function render() {
  renderLabels();
  renderWorkspaceList();
  populateWorkspaceDomainFilter();
  populateFilters();
  renderMetrics();
  renderLegend();
  renderTree();
  renderDetails(state.selectedNode);
  applyLayoutState();
}

function renderPreservingFocus(selector, selectionStart = null, selectionEnd = null) {
  render();
  window.requestAnimationFrame(() => {
    const target = document.querySelector(selector);
    if (!target || target.disabled) return;
    target.focus({ preventScroll: true });
    if (typeof target.setSelectionRange === 'function' && selectionStart !== null) {
      const start = Math.min(selectionStart, target.value.length);
      const end = Math.min(selectionEnd === null ? selectionStart : selectionEnd, target.value.length);
      target.setSelectionRange(start, end);
    }
  });
}

function viewportSize() {
  const rect = els.viewport.getBoundingClientRect();
  return {
    width: Math.max(600, els.viewport.clientWidth || rect.width || 900),
    height: Math.max(520, els.viewport.clientHeight || rect.height || 680)
  };
}

function supportsStageZoom() {
  return typeof CSS !== 'undefined' && typeof CSS.supports === 'function' && CSS.supports('zoom', '1');
}

function applyTransform() {
  const scale = String(state.view.scale);
  if (state.viewMode === 'planning') {
    // Planning zooms its own canvas element directly with transform: scale()
    // (see renderPlanningCanvas/getCardNaturalRect for why) -- keep
    // els.treeStage itself unscaled here so the two mechanisms never
    // compound into a double zoom.
    els.treeStage.style.zoom = '';
    els.treeStage.style.transform = 'none';
    if (planningZoomCanvas) planningZoomCanvas.style.transform = `scale(${scale})`;
    if (planningZoomWrapper) {
      planningZoomWrapper.style.width = `${planningNaturalSize.width * state.view.scale}px`;
      planningZoomWrapper.style.height = `${planningNaturalSize.height * state.view.scale}px`;
    }
    return;
  }
  if (supportsStageZoom()) {
    els.treeStage.style.zoom = scale;
    els.treeStage.style.transform = 'none';
    return;
  }
  els.treeStage.style.zoom = '';
  els.treeStage.style.transform = `scale(${scale})`;
}

function resetViewportScroll() {
  window.requestAnimationFrame(() => {
    els.viewport.scrollTo({ left: 0, top: 0, behavior: 'auto' });
  });
}

function viewportScrollSnapshot() {
  return {
    left: els.viewport.scrollLeft,
    top: els.viewport.scrollTop,
    scale: state.view.scale
  };
}

function restoreViewportScroll(snapshot) {
  if (!snapshot) return;
  window.requestAnimationFrame(() => {
    state.view.scale = snapshot.scale;
    applyTransform();
    els.viewport.scrollTo({
      left: Math.max(0, snapshot.left),
      top: Math.max(0, snapshot.top),
      behavior: 'auto'
    });
  });
}

function isViewportScrollbarEvent(event) {
  const rect = els.viewport.getBoundingClientRect();
  const verticalScrollbar = els.viewport.offsetWidth > els.viewport.clientWidth &&
    event.clientX >= rect.left + els.viewport.clientWidth;
  const horizontalScrollbar = els.viewport.offsetHeight > els.viewport.clientHeight &&
    event.clientY >= rect.top + els.viewport.clientHeight;
  return verticalScrollbar || horizontalScrollbar;
}

function clampFilterPosition(x, y) {
  const viewport = els.viewport.getBoundingClientRect();
  const menu = els.filterMenu.getBoundingClientRect();
  const menuWidth = menu.width || 240;
  const menuHeight = menu.height || 160;
  return {
    x: Math.max(10, Math.min(x, viewport.width - menuWidth - 10)),
    y: Math.max(10, Math.min(y, viewport.height - menuHeight - 10))
  };
}

function applyFilterPosition() {
  if (state.filterPanel.x === null || state.filterPanel.y === null) {
    const viewport = els.viewport.getBoundingClientRect();
    state.filterPanel.x = Math.max(10, viewport.width - 390);
    state.filterPanel.y = 12;
  }
  const next = clampFilterPosition(state.filterPanel.x, state.filterPanel.y);
  state.filterPanel.x = next.x;
  state.filterPanel.y = next.y;
  els.filterMenu.style.left = `${next.x}px`;
  els.filterMenu.style.top = `${next.y}px`;
}

function hideFilterMenu() {
  state.filterPanel.active = false;
  els.filterMenu.hidden = true;
  els.filterButton.classList.remove('filter-open');
}

function toggleFilterMenu() {
  if (!els.filterMenu.hidden) {
    hideFilterMenu();
    return;
  }
  els.filterMenu.hidden = false;
  els.filterButton.classList.add('filter-open');
  populateFilters();
  applyFilterPosition();
}

// Every planning edge's <path d="..."> is computed once, in screen pixels,
// from each card's getBoundingClientRect() at the moment it's drawn (see
// renderPlanningEdges). Changing zoom moves every card without touching
// that already-drawn path -- the SVG just sits there stale while the cards
// slide out from under it, which is exactly what reads as "arrows floating,
// not attached to the boxes" once you zoom or pan. Both zoom(...) and
// fitView() must redraw the edges after the transform actually applies (one
// rAF later, so getBoundingClientRect sees the new post-zoom layout).
//
// A real mouse wheel fires many events per second -- a burst of ticks can
// call zoom() several times before a single rAF has had a chance to run.
// Without coalescing, each call queued its own independent rAF for both the
// scroll adjustment and the edge redraw, and those could interleave out of
// order (an edge redraw for tick 2 painting after the scroll adjustment for
// tick 4 already moved everything), which is exactly what would make edges
// look like they belong to an entirely different, frozen plane from the
// cards. Coalesce into a single pending target, applied and redrawn together
// in one rAF, so only the latest tick in a burst ever actually paints.
let planningViewUpdateQueued = false;
let pendingPlanningScrollTarget = null;

function redrawPlanningEdgesAfterViewChange() {
  if (state.viewMode !== 'planning') return;
  if (planningViewUpdateQueued) return;
  planningViewUpdateQueued = true;
  requestAnimationFrame(() => {
    planningViewUpdateQueued = false;
    const target = pendingPlanningScrollTarget;
    pendingPlanningScrollTarget = null;
    if (target) {
      els.viewport.scrollLeft = Math.max(0, target.worldX * target.nextScale - target.originX);
      els.viewport.scrollTop = Math.max(0, target.worldY * target.nextScale - target.originY);
    }
    const board = els.treeStage.querySelector('.planning-board');
    if (board) renderPlanningEdges(board, planningLiveEdges);
  });
}

function fitView() {
  state.view = { x: 0, y: 0, scale: 1 };
  applyTransform();
  resetViewportScroll();
  pendingPlanningScrollTarget = null;
  redrawPlanningEdgesAfterViewChange();
}

function zoom(multiplier, x = null, y = null) {
  const size = viewportSize();
  const originX = x === null ? size.width / 2 : x;
  const originY = y === null ? size.height / 2 : y;
  const oldScale = state.view.scale;
  const nextScale = Math.max(MIN_ZOOM_SCALE, Math.min(MAX_ZOOM_SCALE, oldScale * multiplier));
  const worldX = (els.viewport.scrollLeft + originX) / oldScale;
  const worldY = (els.viewport.scrollTop + originY) / oldScale;
  state.view.scale = nextScale;
  applyTransform();
  pendingPlanningScrollTarget = { worldX, worldY, originX, originY, nextScale };
  redrawPlanningEdgesAfterViewChange();
}

function notebookSuperConfidence(row) {
  if (!row) return 'unknown';
  if (row.unresolved_variables) return 'likely';
  if (row.confidence === 'parsed') return 'confirmed';
  if (['confirmed', 'likely', 'unknown'].includes(row.confidence)) return row.confidence;
  return 'likely';
}

function notebookSuperUsage(row) {
  if (row.direction === 'write') return 'writes_to';
  if (row.direction === 'execute') return 'executes';
  return 'reads_from';
}

function notebookSuperObjectType(row) {
  if (row.source_type === 'File') return 'file';
  if (row.direction === 'execute') return 'stored_procedure';
  if (row.object_name === '*') return 'schema';
  if (row.source_type === 'LakehouseTable') return 'table';
  return 'table_or_view';
}

function notebookSuperSourceLabel(item, row) {
  if (row.source_database) return row.source_database;
  if (row.direction === 'write') return 'Destino pendiente';
  if (row.direction === 'execute') return 'Objetos ejecutados';
  if (row.source_type === 'File') return 'Archivos';
  return 'Origen pendiente';
}

function buildNotebookSuperSources(item, rows) {
  const groups = new Map();
  for (const row of rows || []) {
    const key = [row.direction, row.source_type, row.source_database].join('|');
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  return Array.from(groups.values()).map(groupRows => {
    const first = groupRows[0] || {};
    const seen = new Set();
    const objects = [];
    for (const row of groupRows) {
      const label = canonicalObjectDisplayName({
        object_display_name: row.object_display_name,
        schema: row.schema_name,
        object_name: row.object_name,
        database: row.source_database,
        source_type: row.source_type
      });
      const key = [row.direction, row.source_type, row.source_database, row.schema_name, row.object_name, row.object_display_name, row.operation].join('|');
      if (seen.has(key)) continue;
      seen.add(key);
      const confidence = notebookSuperConfidence(row);
      objects.push({
        label,
        type: notebookSuperObjectType(row),
        raw_object_type: row.source_type,
        object_type_source: 'notebook_static_parse',
        object_type_confidence: confidence,
        object_type_evidence: state.lang === 'es' ? 'Definición de notebook analizada localmente.' : 'Notebook definition parsed locally.',
        schema: row.schema_name,
        object_name: row.object_name,
        database: row.source_database,
        server: '',
        source_name: row.source_database,
        source_type: row.source_type,
        usage_type: notebookSuperUsage(row),
        confidence,
        evidence: [
          state.lang === 'es' ? 'Análisis estático del código del notebook.' : 'Notebook code static parse.',
          row.evidence,
          row.unresolved_variables ? (state.lang === 'es' ? `Variables sin resolver: ${row.unresolved_variables}` : `Unresolved variables: ${row.unresolved_variables}`) : ''
        ].filter(Boolean).join(' '),
        definition_path: row.definition_path,
        activity_name: row.dataframe,
        activity_type: row.operation,
        evidence_origin: 'notebook_super_lineage'
      });
    }
    const hasLikely = objects.some(object => object.confidence === 'likely');
    const hasUnknown = objects.some(object => object.confidence === 'unknown');
    const label = notebookSuperSourceLabel(item, first);
    return {
      id: `notebook-source:${item.qualified_name}:${first.direction}:${first.source_type}:${first.source_database}`,
      label,
      type: 'source',
      source_type: first.source_type || 'NotebookParse',
      item_type: 'NotebookObjectLineage',
      workspace_name: item.workspace_name,
      qualified_name: `${item.qualified_name} / ${first.direction} / ${label}`,
      server: first.source_database ? item.workspace_name : '',
      database: first.source_database || '',
      confidence: hasUnknown ? 'unknown' : hasLikely ? 'likely' : 'confirmed',
      evidence: `Notebook source/destination objects parsed from downloaded definition. Direction: ${first.direction}.`,
      planning_role: first.direction === 'write' ? 'output' : 'input',
      notebook_super_lineage_only: true,
      objects
    };
  });
}

// Server-side (11_build_lineage_explorer_fast.py) stopped embedding a
// separate "all" node list per workspace 2026-07-11 -- every item was being
// built and serialized TWICE (once in its own type bucket, e.g. "report"/
// "semantic", once again in "all"), a large contributor to an oversized
// lineage-explorer.json after a tenant-wide scan that the browser could no
// longer even load. workspace.all still needs to exist for every
// downstream renderer that reads it (search, mode="all" view, counts...),
// so it's rebuilt here client-side once, right after the data is parsed --
// cheap (array concatenation, no re-fetching/re-building of node objects)
// versus the server writing it out twice on the wire. data.modes is the
// authoritative list of real per-type keys a workspace might have (see
// build script) -- concatenating exactly those, not every array-valued key
// on the workspace object, avoids accidentally sweeping in unrelated
// arrays like role_assignments. Defensive no-op if workspace.all already
// exists (an older cached JSON, or a standalone.html snapshot built before
// this change) or data.modes is missing, so this never produces a worse
// result than what shipped on the wire.
function reconstructWorkspaceAllLists(data) {
  if (!data || !Array.isArray(data.modes) || !Array.isArray(data.workspaces)) return;
  for (const workspace of data.workspaces) {
    if (!workspace || Array.isArray(workspace.all)) continue;
    const combined = [];
    for (const modeKey of data.modes) {
      if (Array.isArray(workspace[modeKey])) combined.push(...workspace[modeKey]);
    }
    combined.sort((a, b) => {
      const typeCompare = String(a.item_type || '').localeCompare(String(b.item_type || ''), undefined, { sensitivity: 'base' });
      if (typeCompare !== 0) return typeCompare;
      return String(a.label || '').localeCompare(String(b.label || ''), undefined, { sensitivity: 'base' });
    });
    workspace.all = combined;
  }
}

// Server-side (11_build_lineage_explorer_fast.py) stopped embedding each
// semantic model's full nested source-object/column catalog inside every
// report/notebook/etc. that uses it 2026-07-11 -- a real semantic model
// with a couple of sizeable SQL sources can carry 400KB+ of columns on its
// own, and the same model easily gets referenced by a dozen+ reports, so
// this was the single biggest contributor (~50%) to an oversized lineage-
// explorer.json after a tenant-wide scan. item.models[] entries are now
// lightweight stubs (label/item_type/workspace_name/environment/
// qualified_name plus the relationship-specific confidence/evidence/notes)
// -- this resolves each one back to the model's own full node (already
// built once, as that model's own entry in its type bucket, e.g.
// workspace.semantic[]) via a qualified_name lookup built once here, so
// every existing renderer that reads model.sources/model.analysis/etc.
// keeps working unchanged. Must run AFTER mergeNotebookSuperLineage, not
// before: mergeNotebookSuperLineage's own recursion into item.models would
// otherwise redundantly re-enrich a full copy of the same model once per
// report that references it, instead of once via the model's own direct
// top-level visit.
function resolveEmbeddedItemReferences(data) {
  if (!data || !Array.isArray(data.modes) || !Array.isArray(data.workspaces)) return;
  const itemsByQualifiedName = new Map();
  for (const workspace of data.workspaces) {
    if (!workspace) continue;
    for (const modeKey of data.modes) {
      for (const item of asList(workspace[modeKey])) {
        if (item && item.qualified_name && !itemsByQualifiedName.has(item.qualified_name)) {
          itemsByQualifiedName.set(item.qualified_name, item);
        }
      }
    }
  }
  for (const workspace of data.workspaces) {
    if (!workspace) continue;
    for (const modeKey of data.modes) {
      for (const item of asList(workspace[modeKey])) {
        if (!item || !Array.isArray(item.models) || !item.models.length) continue;
        item.models = item.models.map(stub => {
          const resolved = stub && stub.qualified_name ? itemsByQualifiedName.get(stub.qualified_name) : null;
          // No match (a cross-tenant or otherwise unresolved reference) --
          // keep the stub as-is rather than dropping the relationship.
          if (!resolved) return stub;
          return { ...resolved, confidence: stub.confidence, evidence: stub.evidence, notes: stub.notes };
        });
      }
    }
  }
}

function mergeNotebookSuperLineage(data, payload) {
  if (!data || !payload || !Array.isArray(payload.objects)) return;
  const rowsByItem = new Map();
  for (const row of payload.objects) {
    if (!row.item_qualified_name) continue;
    if (!rowsByItem.has(row.item_qualified_name)) rowsByItem.set(row.item_qualified_name, []);
    rowsByItem.get(row.item_qualified_name).push(row);
  }
  const flowsByItem = new Map();
  for (const flow of payload.flows || []) {
    if (!flow.item_qualified_name) continue;
    flowsByItem.set(flow.item_qualified_name, (flowsByItem.get(flow.item_qualified_name) || 0) + 1);
  }
  const enrichItem = item => {
    if (!item || item.__notebookSuperLineageMerged) return;
    const rows = rowsByItem.get(item.qualified_name);
    if (rows && rows.length) {
      item.sources = [...asList(item.sources), ...buildNotebookSuperSources(item, rows)];
      item.notebook_super_lineage = {
        object_count: rows.length,
        source_count: rows.filter(row => row.direction === 'read').length,
        destination_count: rows.filter(row => row.direction === 'write').length,
        execute_count: rows.filter(row => row.direction === 'execute').length,
        flow_count: flowsByItem.get(item.qualified_name) || 0
      };
    }
    item.__notebookSuperLineageMerged = true;
    asList(item.executes).forEach(enrichItem);
    asList(item.models).forEach(enrichItem);
    asList(item.reports).forEach(enrichItem);
  };
  for (const workspace of asList(data.workspaces)) {
    for (const mode of ['semantic', 'notebooks', 'copyjobs', 'pipelines', 'dataflows', 'all']) {
      asList(workspace[mode]).forEach(enrichItem);
    }
  }
}

function startScene() {
  if (state.sceneStarted || !els.sceneCanvas) return;
  state.sceneStarted = true;
  const canvas = els.sceneCanvas;
  const ctx = canvas.getContext('2d');
  const particles = Array.from({ length: 120 }, (_, index) => ({
    x: Math.random(),
    y: Math.random(),
    z: Math.random(),
    lane: index % 4,
    speed: 0.0005 + Math.random() * 0.001
  }));
  const colors = ['rgba(15,118,110,', 'rgba(37,99,235,', 'rgba(124,58,237,', 'rgba(180,83,9,'];
  function resize() {
    const rect = canvas.getBoundingClientRect();
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.max(1, Math.floor(rect.width * ratio));
    canvas.height = Math.max(1, Math.floor(rect.height * ratio));
  }
  function frame() {
    resize();
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = 'rgba(15, 118, 110, 0.06)';
    ctx.fillRect(2, 2, 8, 8);
    for (const p of particles) {
      p.x += p.speed;
      if (p.x > 1.04) p.x = -0.04;
      const depth = 0.55 + p.z;
      const x = p.x * canvas.width;
      const y = p.y * canvas.height + Math.sin(Date.now() * 0.00035 + p.z * 7) * 18 * depth;
      const r = 1.2 + depth * 1.8;
      ctx.fillStyle = `${colors[p.lane]}${0.1 + p.z * 0.18})`;
      ctx.fillRect(x, y, r, r);
      ctx.beginPath();
      ctx.strokeStyle = `${colors[p.lane]}0.07)`;
      ctx.moveTo(x, y);
      ctx.lineTo(x + 70 * depth, y + Math.sin(x * 0.005) * 22);
      ctx.stroke();
    }
    window.requestAnimationFrame(frame);
  }
  window.addEventListener('resize', resize);
  frame();
}

const TRIGGER_SERVER_ORIGIN = '';

// ---------------------------------------------------------------------------
// Auth: Microsoft device-code sign-in + admin panel
// ---------------------------------------------------------------------------

const authState = {
  signedIn: false,
  userEmail: '',
  userName: '',
  objectId: '',
  tenantId: '',
  signedInAt: '',
  isAdmin: false,
  canFullScan: false,
  // Only ever what the server reports (/api/auth/me's demo_mode, true when
  // it runs with LINEAGE_DEMO_MODE=1 for the synthetic demo tenant) --
  // never inferred client-side. Deliberately separate from signedIn: demo
  // mode lets init() skip the sign-in gate for the read-only explorer, but
  // everything keyed on signedIn (comments, favourites, column profiles,
  // per-user workspaces, scans) stays off, matching the server, which only
  // widens reads in demo mode.
  demoMode: false,
};
let deviceFlowPollHandle = null;

// Demo mode with nobody signed in. The user badge then doubles as the
// "Demo data" indicator and stays the way into the language/theme/help
// menu, which would otherwise be unreachable without a sign-in.
function isAnonymousDemo() {
  return authState.demoMode && !authState.signedIn;
}

const DEMO_BADGE_TEXT = {
  es: { label: 'Datos de demo', detail: 'Tenant sintético de demo, solo lectura' },
  en: { label: 'Demo data', detail: 'Synthetic demo tenant, read-only' },
};

function renderUserBadgeName() {
  const demoText = DEMO_BADGE_TEXT[state.lang] || DEMO_BADGE_TEXT.es;
  const anonymousDemo = isAnonymousDemo();
  if (els.userBadgeName) els.userBadgeName.textContent = anonymousDemo ? demoText.label : (authState.userName || authState.userEmail);
  if (els.userBadge) els.userBadge.title = anonymousDemo ? demoText.detail : '';
}

function applyAuthVisibility() {
  const anonymousDemo = isAnonymousDemo();
  if (els.userBadge) {
    els.userBadge.hidden = !authState.signedIn && !anonymousDemo;
    els.userBadge.classList.toggle('is-demo', anonymousDemo);
  }
  if (els.profileMenu) els.profileMenu.classList.toggle('is-demo', anonymousDemo);
  renderUserBadgeName();
  // Nothing to show or sign out of without a session.
  if (els.profileMenuProfileButton) els.profileMenuProfileButton.hidden = anonymousDemo;
  if (els.profileMenuSignOutButton) els.profileMenuSignOutButton.hidden = anonymousDemo;
  if (els.profileMenuSignOutDivider) els.profileMenuSignOutDivider.hidden = anonymousDemo;
  if (els.adminButton) els.adminButton.hidden = !authState.isAdmin;
  if (els.governanceButton) els.governanceButton.hidden = !authState.isAdmin;
  if (els.privacyButton) els.privacyButton.hidden = !authState.isAdmin;
  if (!authState.isAdmin && els.adminPanel && !els.adminPanel.hidden) toggleAdminPanel(false);
  if (els.notificationsButton) els.notificationsButton.hidden = !authState.isAdmin;
  if (!authState.isAdmin && els.notificationsPanel && !els.notificationsPanel.hidden) toggleAlertsPanel(false);
  if (authState.isAdmin) {
    refreshAlertsSummary();
  } else {
    alertsSummaryCache = null;
    applyAlertsBadge();
  }
  // The full-scan button predates per-user permissions and was always
  // visible before; now it only shows for emails on full_scan_emails in
  // config/admin_settings.json. setScanRunningUi (already in this file)
  // still separately controls disabling it while a scan is running --
  // this only controls whether it exists in the DOM view at all.
  if (els.fullScanButton) els.fullScanButton.hidden = !authState.canFullScan;
  applyAvatarInitialsOnly();
  if (authState.signedIn) {
    loadProfilePhoto();
  } else {
    if (profilePhotoObjectUrl) URL.revokeObjectURL(profilePhotoObjectUrl);
    profilePhotoObjectUrl = null;
    profilePhotoLoadedForEmail = null;
    profileInfoCache = null;
    profileInfoLoadedForEmail = null;
  }
}

// Entra profile photo (2026-08-18): shown next to the name in the toolbar
// badge + the dropdown header, Teams/tenant-site style. Initials render
// immediately (computeInitials never needs a network round trip) so there's
// no blank avatar flash while /api/me/photo -- proxied through our own
// backend, see graph_profile.py -- is still in flight or turns out to have
// nothing to show (no Graph consent in this tenant, guest account, ...).
let profilePhotoObjectUrl = null;
let profilePhotoLoadedForEmail = null;

function computeInitials(name, email) {
  const source = (name || '').trim() || (email || '').trim();
  if (!source) return '?';
  const parts = source.includes('@') ? [source.split('@')[0]] : source.split(/\s+/).filter(Boolean);
  const letters = parts.slice(0, 2).map(part => part.charAt(0).toUpperCase()).join('');
  return letters || '?';
}

function applyAvatarInitialsOnly() {
  const initials = isAnonymousDemo() ? 'D' : computeInitials(authState.userName, authState.userEmail);
  if (els.userBadgeInitials) els.userBadgeInitials.textContent = initials;
  if (els.profileMenuInitials) els.profileMenuInitials.textContent = initials;
}

// onerror re-hides the <img> (falling back to the initials already
// rendered underneath it, see .user-badge-avatar-img[hidden] etc.) instead
// of leaving a broken-image icon showing -- belt-and-suspenders alongside
// loadProfilePhoto()'s own !response.ok check, for any failure mode that
// check doesn't catch (a corrupt blob, a revoked object URL, ...).
function applyAvatarImage(url) {
  if (els.userBadgeAvatarImg) {
    els.userBadgeAvatarImg.onerror = () => { els.userBadgeAvatarImg.hidden = true; };
    els.userBadgeAvatarImg.src = url;
    els.userBadgeAvatarImg.hidden = false;
  }
  if (els.profileMenuAvatarImg) {
    els.profileMenuAvatarImg.onerror = () => { els.profileMenuAvatarImg.hidden = true; };
    els.profileMenuAvatarImg.src = url;
    els.profileMenuAvatarImg.hidden = false;
  }
}

async function loadProfilePhoto() {
  // Skip once we've already tried (success or not) for this signed-in
  // email -- a fresh sign-in as a different account resets this and tries
  // again, but re-fetching on every applyAuthVisibility() call (which
  // happens on more than just sign-in) would be wasteful.
  if (profilePhotoLoadedForEmail === authState.userEmail) return;
  profilePhotoLoadedForEmail = authState.userEmail;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/me/photo`);
    if (!response.ok) return;
    const blob = await response.blob();
    if (profilePhotoObjectUrl) URL.revokeObjectURL(profilePhotoObjectUrl);
    profilePhotoObjectUrl = URL.createObjectURL(blob);
    applyAvatarImage(profilePhotoObjectUrl);
  } catch (error) {
    // No photo available (not consented in this tenant, none set, offline,
    // ...) -- the initials already rendered above stay as the fallback.
  }
}

// Every control that either needs a signed-in session (scan triggers,
// workspace picking) or real tenant data (large lineage payload) to mean
// anything -- shared by renderLockedShell (locked from page load, before
// sign-in) and bootApp's own loadGateButtons (still locked for the few
// seconds real data takes to fetch/parse AFTER sign-in). One list so the
// two phases can never drift apart on which controls need gating.
function lockableShellControls() {
  return [
    ...els.modeButtons,
    els.selectAllWorkspacesButton,
    els.clearWorkspacesButton,
    els.workspaceSearchToggle,
    els.inspectionButton,
    els.impactButton,
    els.scheduleButton,
    els.filterButton,
    els.localScanWorkspaceSelect,
    els.localScanButton,
    els.scanHistoryButton
  ].filter(Boolean);
}

// 2026-08-24: the app used to be fully gated behind sign-in at the DOM
// level -- nothing in .app-shell even existed on screen (appShell.hidden)
// until a session was confirmed, which meant the ENTIRE page (topbar, mode
// bar, scan panel, workspace list) popped into existence in one frame the
// moment sign-in completed, visibly shifting/reflowing. The actual "don't
// load real data pre-auth" security property never depended on hiding the
// shell -- init() below never fetches the lineage payload or workspace
// list until a session exists, regardless of what's visually shown. So
// the shell chrome now renders from page load, every control that needs
// data or auth locked via lockableShellControls(), and only the one area
// with real tenant-specific content (the diagram itself) shows a sign-in
// prompt -- see the HTML comment above #authGate for where that lives now.
function renderLockedShell() {
  wireLocalScanPanel();
  lockableShellControls().forEach(control => { control.disabled = true; });
  if (els.localScanWorkspaceSelect) {
    els.localScanWorkspaceSelect.innerHTML = `<option value="">${state.lang === 'es' ? 'Inicia sesión para ver tus workspaces' : 'Sign in to see your workspaces'}</option>`;
  }
  if (els.workspaceList) {
    els.workspaceList.innerHTML = `<p class="scan-history-empty">${state.lang === 'es' ? 'Inicia sesión para ver tus workspaces.' : 'Sign in to see your workspaces.'}</p>`;
  }
}

function unlockShellControls() {
  lockableShellControls().forEach(control => { control.disabled = false; });
}

function showAuthGate() {
  if (els.authGate) els.authGate.hidden = false;
}

function hideAuthGate() {
  if (els.authGate) els.authGate.hidden = true;
}

// The gate renders before .app-shell (and its language-switch buttons) is
// ever shown, so it needs its own copy of the ES/EN switch and its own
// small translation table -- not sharing i18n[state.lang] itself, since
// that object assumes state.data already exists in a few other read paths.
const AUTH_GATE_TEXT = {
  es: {
    title: 'Inicia sesión para continuar',
    lede: 'Por seguridad, ni la interfaz ni los datos de linaje se cargan hasta que inicies sesión con tu cuenta Microsoft. Verás únicamente los workspaces a los que tu cuenta tiene acceso.',
    signIn: 'Iniciar sesión con Microsoft',
    hint1: '1. Abre esta página en cualquier pestaña:',
    hint2: '2. Escribe este código:',
    waiting: 'Esperando a que completes el inicio de sesión...',
    cancel: 'Cancelar',
    copyCode: 'Copiar código',
    copied: '¡Copiado!',
  },
  en: {
    title: 'Sign in to continue',
    lede: 'For security, neither the interface nor the lineage data loads until you sign in with your Microsoft account. You will only see the workspaces your account has access to.',
    signIn: 'Sign in with Microsoft',
    hint1: '1. Open this page on any tab:',
    hint2: '2. Enter this code:',
    waiting: 'Waiting for you to complete sign-in...',
    cancel: 'Cancel',
    copyCode: 'Copy code',
    copied: 'Copied!',
  },
};

function applyAuthGateLanguage() {
  const text = AUTH_GATE_TEXT[state.lang] || AUTH_GATE_TEXT.es;
  if (els.authGateLangEsButton) els.authGateLangEsButton.classList.toggle('active', state.lang === 'es');
  if (els.authGateLangEnButton) els.authGateLangEnButton.classList.toggle('active', state.lang === 'en');
  if (els.authGateTitle) els.authGateTitle.textContent = text.title;
  if (els.authGateLede) els.authGateLede.textContent = text.lede;
  if (els.authGateSignInButton) els.authGateSignInButton.textContent = text.signIn;
  if (els.authGateHint1) els.authGateHint1.textContent = text.hint1;
  if (els.authGateHint2) els.authGateHint2.textContent = text.hint2;
  if (els.authGateCancelButton) els.authGateCancelButton.textContent = text.cancel;
  if (els.authGateCopyCodeButton) els.authGateCopyCodeButton.title = text.copyCode;
  // Only overwrite the status message while still waiting -- once a real
  // error/other message has been set (setAuthGateError, or the "done"
  // transition), a language switch shouldn't clobber it.
  if (els.authGateStatusMessage && els.authGateDeviceCode && !els.authGateDeviceCode.hidden) {
    els.authGateStatusMessage.textContent = text.waiting;
  }
}

async function refreshAuthState() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/auth/me`);
    if (response.status === 401) {
      // Still "not signed in" -- the 401 body only adds whether the server
      // runs in demo mode (see authState.demoMode).
      const unauthorizedPayload = await response.json().catch(() => ({}));
      authState.demoMode = Boolean(unauthorizedPayload.demo_mode);
      authState.signedIn = false;
      authState.userEmail = '';
      authState.userName = '';
      authState.objectId = '';
      authState.tenantId = '';
      authState.signedInAt = '';
      authState.isAdmin = false;
      authState.canFullScan = false;
      applyAuthVisibility();
      return;
    }
    if (!response.ok) return;
    const payload = await response.json();
    authState.demoMode = Boolean(payload.demo_mode);
    authState.signedIn = true;
    authState.userEmail = payload.user_email || '';
    authState.userName = payload.user_name || '';
    authState.objectId = payload.object_id || '';
    authState.tenantId = payload.tenant_id || '';
    authState.signedInAt = payload.created_at || '';
    authState.isAdmin = Boolean(payload.is_admin);
    authState.canFullScan = Boolean(payload.can_full_scan);
    applyAuthVisibility();
  } catch (error) {
    // Trigger server not reachable right now; leave the last known state visible.
  }
}

function setAuthGateError(message) {
  if (!els.authGateError) return;
  els.authGateError.textContent = message || '';
  els.authGateError.hidden = !message;
}

async function startSignIn() {
  setAuthGateError('');
  if (els.authGateSignInButton) els.authGateSignInButton.disabled = true;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/auth/device-start`, { method: 'POST' });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (els.authGateSignInButton) els.authGateSignInButton.disabled = false;
      setAuthGateError(payload.message || (state.lang === 'es' ? 'No se pudo iniciar sesión.' : 'Could not start sign-in.'));
      return;
    }
    if (els.authGateVerificationLink) els.authGateVerificationLink.href = payload.verification_uri || '#';
    if (els.authGateUserCode) els.authGateUserCode.textContent = payload.user_code || '';
    if (els.authGateStatusMessage) {
      els.authGateStatusMessage.textContent = state.lang === 'es'
        ? 'Esperando a que completes el inicio de sesión...'
        : 'Waiting for you to complete sign-in...';
    }
    if (els.authGateDeviceCode) els.authGateDeviceCode.hidden = false;
    pollDeviceFlow(payload.flow_id);
  } catch (error) {
    if (els.authGateSignInButton) els.authGateSignInButton.disabled = false;
    setAuthGateError(state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.');
  }
}

async function copyDeviceCode() {
  const code = els.authGateUserCode ? els.authGateUserCode.textContent : '';
  if (!code) return;
  try {
    await navigator.clipboard.writeText(code);
    if (els.authGateCopyCodeButton) {
      const text = AUTH_GATE_TEXT[state.lang] || AUTH_GATE_TEXT.es;
      els.authGateCopyCodeButton.title = text.copied;
      // Restore via applyAuthGateLanguage() (not a captured "original"
      // string) so a language switch during this 1.5s window doesn't
      // revert to the wrong language's resting title.
      setTimeout(applyAuthGateLanguage, 1500);
    }
  } catch (error) {
    // Clipboard API unavailable (very old browser, non-HTTPS context) --
    // the code is already shown in plain text right next to the button.
  }
}

async function pollDeviceFlow(flowId) {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/auth/device-status?flow_id=${encodeURIComponent(flowId)}`);
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      stopDeviceFlowPolling();
      if (els.authGateDeviceCode) els.authGateDeviceCode.hidden = true;
      if (els.authGateSignInButton) els.authGateSignInButton.disabled = false;
      setAuthGateError(payload.message || (state.lang === 'es' ? 'El inicio de sesión falló.' : 'Sign-in failed.'));
      return;
    }
    if (payload.status === 'done') {
      stopDeviceFlowPolling();
      if (els.authGateDeviceCode) els.authGateDeviceCode.hidden = true;
      if (els.authGateSignInButton) els.authGateSignInButton.disabled = false;
      await refreshAuthState();
      await bootApp();
      return;
    }
    // status === 'pending' -- keep polling, same cadence as scan-status
    // polling elsewhere in this file.
    deviceFlowPollHandle = setTimeout(() => pollDeviceFlow(flowId), 3000);
  } catch (error) {
    deviceFlowPollHandle = setTimeout(() => pollDeviceFlow(flowId), 3000);
  }
}

function stopDeviceFlowPolling() {
  if (deviceFlowPollHandle) {
    clearTimeout(deviceFlowPollHandle);
    deviceFlowPollHandle = null;
  }
}

async function cancelSignIn() {
  stopDeviceFlowPolling();
  if (els.authGateDeviceCode) els.authGateDeviceCode.hidden = true;
  if (els.authGateSignInButton) els.authGateSignInButton.disabled = false;
}

async function signOut() {
  try {
    await fetch(`${TRIGGER_SERVER_ORIGIN}/api/auth/logout`, { method: 'POST' });
  } catch (error) {
    // best-effort -- clear local UI state regardless
  }
  // A full reload is the simplest correct way to honor "nothing loads
  // until signed in": the already-fetched lineage data sitting in this
  // page's memory can't be un-fetched, but init() on the next load will
  // hit the gate and never fetch it again until signing back in.
  window.location.reload();
}

// Profile dropdown (2026-08-18 redesign): consolidates what used to be
// separate toolbar icons (account info modal, language switch, theme
// switch, help, admin settings) into one menu anchored under the avatar +
// name badge -- Teams/most-web-apps style, per the user's own request.
// Language/theme/help/admin/sign-out are still the SAME underlying
// buttons/handlers as before (same ids), just relocated into this panel's
// markup instead of sitting loose in the toolbar.
function renderProfileMenu() {
  const es = state.lang === 'es';
  if (isAnonymousDemo()) {
    const demoText = DEMO_BADGE_TEXT[state.lang] || DEMO_BADGE_TEXT.es;
    if (els.profileMenuName) els.profileMenuName.textContent = demoText.label;
    if (els.profileMenuEmail) els.profileMenuEmail.textContent = demoText.detail;
  } else {
    if (els.profileMenuName) els.profileMenuName.textContent = authState.userName || authState.userEmail;
    if (els.profileMenuEmail) els.profileMenuEmail.textContent = authState.userName ? authState.userEmail : '';
  }
  if (els.profileMenuProfileLabel) els.profileMenuProfileLabel.textContent = es ? 'Perfil' : 'Profile';
  if (els.profileMenuAdminLabel) els.profileMenuAdminLabel.textContent = es ? 'Configuración' : 'Settings';
  if (els.profileMenuHelpLabel) els.profileMenuHelpLabel.textContent = es ? 'Ayuda' : 'Help';
  if (els.profileMenuSignOutLabel) els.profileMenuSignOutLabel.textContent = es ? 'Cerrar sesión' : 'Sign out';
}

function toggleProfileMenu(forceOpen) {
  if (!els.profileMenu || !els.userBadge) return;
  const open = forceOpen !== undefined ? forceOpen : els.profileMenu.hidden;
  if (open) {
    renderProfileMenu();
    els.profileMenu.hidden = false;
  } else {
    els.profileMenu.hidden = true;
  }
  els.userBadge.setAttribute('aria-expanded', String(open));
}

// Profile panel (2026-08-18): "Perfil" used to be a collapsible <details>
// tucked inside the dropdown itself; it's now its own destination, same
// pattern as Configuración/Ayuda (a real .modal-panel opened via
// openModal(), which also gives it the grow-from-click animation for
// free). Extended fields (job title, department, tenant NAME not just id,
// ...) come from /api/me/profile, fetched lazily the first time this
// panel opens per sign-in -- not on every page load, same reasoning as
// loadProfilePhoto().
let profileInfoCache = null;
let profileInfoLoadedForEmail = null;

async function loadProfileInfo() {
  if (profileInfoLoadedForEmail === authState.userEmail) return profileInfoCache;
  profileInfoLoadedForEmail = authState.userEmail;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/me/profile`);
    profileInfoCache = response.ok ? await response.json() : null;
  } catch (error) {
    profileInfoCache = null;
  }
  return profileInfoCache;
}

function renderProfilePanel() {
  if (!els.profilePanel) return;
  const es = state.lang === 'es';
  const info = profileInfoCache || {};

  const accountRows = [
    [es ? 'Correo' : 'Email', authState.userEmail],
    [es ? 'Tenant' : 'Tenant', info.tenant_name ? `${info.tenant_name} (${authState.tenantId})` : authState.tenantId],
    [es ? 'Object ID' : 'Object ID', authState.objectId],
    [es ? 'Sesión iniciada' : 'Signed in', authState.signedInAt ? new Date(authState.signedInAt).toLocaleString(es ? 'es-ES' : 'en-GB') : ''],
  ].filter(([, value]) => value);

  const permissionRows = [
    [es ? 'Administrador del panel' : 'Panel admin', authState.isAdmin ? (es ? 'Sí' : 'Yes') : (es ? 'No' : 'No')],
    [es ? 'Puede lanzar escaneo completo' : 'Can trigger full scan', authState.canFullScan ? (es ? 'Sí' : 'Yes') : (es ? 'No' : 'No')],
  ];

  const directoryRows = [
    [es ? 'Cargo' : 'Job title', info.job_title],
    [es ? 'Departamento' : 'Department', info.department],
    [es ? 'Empresa' : 'Company', info.company_name],
    [es ? 'Oficina' : 'Office', info.office_location],
    [es ? 'Teléfono' : 'Phone', info.mobile_phone],
  ].filter(([, value]) => value);

  const section = (title, rows) => rows.length ? `
    <div class="profile-panel-section">
      <h4 class="profile-panel-section-title">${escapeHtml(title)}</h4>
      ${rows.map(([label, value]) => `
        <div class="user-info-row"><span>${escapeHtml(label)}</span><p>${escapeHtml(String(value))}</p></div>
      `).join('')}
    </div>` : '';

  // Photo diagnostic (2026-08-18): the avatar falls back to initials
  // silently everywhere else (correct -- it's a small badge, not the
  // place for an explanation), but here, where the user is specifically
  // looking at their profile, showing WHY there's no photo is more useful
  // than a silent fallback nobody can act on.
  const photoStatusText = {
    no_photo_set: es ? 'Sin foto configurada en Microsoft 365.' : 'No photo set in Microsoft 365.',
    graph_forbidden: es ? 'Microsoft Graph no está autorizado en este tenant para leer la foto (pídeselo a tu administrador).' : "Microsoft Graph isn't authorized in this tenant to read the photo (ask your admin).",
    no_graph_token: es ? 'No se pudo obtener autorización de Microsoft Graph para la foto.' : 'Could not get Microsoft Graph authorization for the photo.',
    network_error: es ? 'No se pudo comprobar la foto ahora mismo.' : "Couldn't check for a photo right now.",
  }[info.photo_status] || (info.photo_status && info.photo_status.startsWith('graph_error_') ? (es ? 'No se pudo comprobar la foto ahora mismo.' : "Couldn't check for a photo right now.") : '');
  const photoNote = (!profilePhotoObjectUrl && photoStatusText)
    ? `<p class="profile-panel-photo-note">${escapeHtml(photoStatusText)}</p>`
    : '';

  els.profilePanel.innerHTML = `
    <div class="scan-history-header">
      <span>${es ? 'Tu perfil' : 'Your profile'}</span>
      <button type="button" class="icon-button" data-close-profile-panel aria-label="${es ? 'Cerrar' : 'Close'}">×</button>
    </div>
    <div class="profile-panel-header">
      <span class="profile-menu-avatar profile-panel-avatar" aria-hidden="true">
        <img id="profilePanelAvatarImg" class="profile-menu-avatar-img" alt="" hidden />
        <span id="profilePanelInitials" class="profile-menu-initials"></span>
      </span>
      <div>
        <p class="profile-menu-name">${escapeHtml(authState.userName || authState.userEmail)}</p>
        <p class="profile-menu-email">${escapeHtml(authState.userEmail)}</p>
        ${photoNote}
      </div>
    </div>
    ${section(es ? 'Cuenta' : 'Account', accountRows)}
    ${section(es ? 'Directorio (Microsoft 365)' : 'Directory (Microsoft 365)', directoryRows)}
    ${section(es ? 'Permisos en este panel' : 'Permissions in this panel', permissionRows)}
  `;
  const closeButton = els.profilePanel.querySelector('[data-close-profile-panel]');
  if (closeButton) closeButton.addEventListener('click', () => toggleProfilePanel(false));
  const avatarImgEl = document.getElementById('profilePanelAvatarImg');
  if (avatarImgEl && profilePhotoObjectUrl) {
    avatarImgEl.onerror = () => { avatarImgEl.hidden = true; };
    avatarImgEl.src = profilePhotoObjectUrl;
    avatarImgEl.hidden = false;
  }
  const initialsEl = document.getElementById('profilePanelInitials');
  if (initialsEl) initialsEl.textContent = computeInitials(authState.userName, authState.userEmail);
}

async function toggleProfilePanel(forceOpen) {
  if (!els.profilePanel || !els.profileMenuProfileButton) return;
  const open = forceOpen !== undefined ? forceOpen : els.profilePanel.hidden;
  if (open) {
    renderProfilePanel();
    openModal(els.profilePanel);
    els.profileMenuProfileButton.setAttribute('aria-expanded', 'true');
    await loadProfileInfo();
    if (!els.profilePanel.hidden) renderProfilePanel();
  } else {
    els.profilePanel.hidden = true;
    if (els.modalBackdrop) els.modalBackdrop.hidden = true;
    els.profileMenuProfileButton.setAttribute('aria-expanded', 'false');
  }
}

function initAuthArea() {
  applyAuthGateLanguage();
  initTheme();
  if (els.authGateLangEsButton) els.authGateLangEsButton.addEventListener('click', () => setLanguage('es'));
  if (els.authGateLangEnButton) els.authGateLangEnButton.addEventListener('click', () => setLanguage('en'));
  if (els.authGateThemeAutoButton) els.authGateThemeAutoButton.addEventListener('click', () => setTheme('auto'));
  if (els.authGateThemeLightButton) els.authGateThemeLightButton.addEventListener('click', () => setTheme('light'));
  if (els.authGateThemeDarkButton) els.authGateThemeDarkButton.addEventListener('click', () => setTheme('dark'));
  if (els.themeAutoButton) els.themeAutoButton.addEventListener('click', () => setTheme('auto'));
  if (els.themeLightButton) els.themeLightButton.addEventListener('click', () => setTheme('light'));
  if (els.themeDarkButton) els.themeDarkButton.addEventListener('click', () => setTheme('dark'));
  if (els.authGateSignInButton) els.authGateSignInButton.addEventListener('click', startSignIn);
  if (els.authGateCancelButton) els.authGateCancelButton.addEventListener('click', cancelSignIn);
  if (els.authGateCopyCodeButton) els.authGateCopyCodeButton.addEventListener('click', copyDeviceCode);
  if (els.adminButton) els.adminButton.addEventListener('click', () => { toggleProfileMenu(false); toggleAdminPanel(); });
  if (els.notificationsButton) els.notificationsButton.addEventListener('click', () => { toggleProfileMenu(false); toggleAlertsPanel(); });
  // Gobernanza is its own isolated top-level panel (2026-08-26), not a
  // section nested inside Configuración -- same "peer to Grafo/Avisos"
  // toolbar placement as before, now opening its own surface directly.
  if (els.governanceButton) els.governanceButton.addEventListener('click', () => {
    toggleProfileMenu(false);
    toggleGovernancePanel(true);
  });
  // Roadmap Fase 5 (2026-08-31): same "own top-level panel, peer to
  // Grafo/Gobernanza" placement as Gobernanza just above.
  if (els.privacyButton) els.privacyButton.addEventListener('click', () => {
    toggleProfileMenu(false);
    togglePrivacyPanel(true);
  });
  if (els.helpButton) els.helpButton.addEventListener('click', () => toggleProfileMenu(false));
  if (els.profileMenuProfileButton) els.profileMenuProfileButton.addEventListener('click', () => { toggleProfileMenu(false); toggleProfilePanel(); });
  if (els.profileMenuSignOutButton) els.profileMenuSignOutButton.addEventListener('click', () => { toggleProfileMenu(false); signOut(); });
  if (els.userBadge) {
    els.userBadge.addEventListener('click', event => {
      event.stopPropagation();
      toggleProfileMenu();
    });
  }
  if (els.profileMenu) els.profileMenu.addEventListener('click', event => event.stopPropagation());
  document.addEventListener('click', () => {
    if (els.profileMenu && !els.profileMenu.hidden) toggleProfileMenu(false);
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && els.profileMenu && !els.profileMenu.hidden) toggleProfileMenu(false);
  });
  if (els.modalBackdrop) els.modalBackdrop.addEventListener('click', closeAllModals);
  // Also wire the tab-switch admin sessions lazy-load: only fetched the
  // first time that tab is actually opened, not on every panel load.
  return refreshAuthState();
}

// ---------------------------------------------------------------------------
// Admin panel
// ---------------------------------------------------------------------------

let adminSettingsCache = null;
let adminActiveTab = 'tenant';
// Governance is its own isolated top-level panel (2026-08-26), not a
// section nested inside Configuración/adminPanel -- separate active-tab
// state so switching tabs in one panel never touches the other's.
let governanceActiveTab = 'overview';
// Plain client-side substring filters for the admin panel's longer lists
// (2026-08-18 audit follow-through) -- no network cost (these lists are
// already loaded), so no debounce; the harder part is that a full
// renderAdminPanel() rebuilds the DOM on every keystroke, which would
// normally drop focus out of the filter input itself -- see
// renderAdminPanelPreservingFocus below.
let adminListFilters = { users: '', sessions: '', access: '', capacity: '', changes: '' };
// Histórico de modificaciones table filters (2026-08-25 redesign) --
// separate from adminListFilters since these are dropdown/chip selections,
// not free-text search (which reuses adminListFilters.changes instead).
let adminChangesWorkspaceFilter = '';
let adminChangesItemTypeFilter = '';
let adminChangesEventTypeFilter = 'all'; // 'all' | 'added' | 'removed' | 'modified'

function renderAdminListFilterInput(key, placeholder) {
  const value = adminListFilters[key] || '';
  return `<input type="text" class="admin-list-filter-input" data-admin-list-filter="${key}" value="${escapeHtml(value)}" placeholder="${escapeHtml(placeholder)}" />`;
}

function matchesAdminListFilter(key, ...haystacks) {
  const needle = (adminListFilters[key] || '').trim().toLowerCase();
  if (!needle) return true;
  return haystacks.some(text => (text || '').toLowerCase().includes(needle));
}

function renderAdminPanelPreservingFocus(selector, selectionStart, selectionEnd) {
  renderAdminPanel();
  window.requestAnimationFrame(() => {
    const target = document.querySelector(selector);
    if (!target || target.disabled) return;
    target.focus({ preventScroll: true });
    if (typeof target.setSelectionRange === 'function' && selectionStart !== null) {
      const start = Math.min(selectionStart, target.value.length);
      const end = Math.min(selectionEnd === null ? selectionStart : selectionEnd, target.value.length);
      target.setSelectionRange(start, end);
    }
  });
}
let adminSessionsCache = null;
let adminSessionHistoryCache = null;
let adminAccessAuditCache = null;
let adminGovernanceScanCache = null;
let adminCapacityInsightCache = null;
// 2026-08-24: live overview (capacity name/SKU/owners/real CU, top items by
// CU) from the Microsoft Fabric Capacity Metrics app's own semantic model
// -- see backend/scripts/lineage_web/capacity_metrics.py's own docstring
// for why this is the only source that has ever had real CU numbers.
let adminCapacityMetricsOverviewCache = null;
let adminChangesDigestCache = null;
let adminSensitivityOverviewCache = null;
let adminContentSensitivityOverviewCache = null;
// Roadmap Fase 1 (2026-08-31): tenant-wide pass/fail rollup of every
// admin-defined data-quality rule, evaluated against dbo.bronze_column_
// profile -- see backend/scripts/lineage_web/data_quality.py.
let adminDataQualityOverviewCache = null;

// Targeted content-sensitivity scan (2026-08-24 Fase 6): tables an admin
// checked in the name-based sensitivity detail modal, kept in a
// module-level Map (not modal-local state) so a selection survives
// closing one category's modal and opening another -- an admin building
// up a selection across "email", "phone", etc. before hitting "Escanear".
// Keyed by workspace+label since that's the only stable identifying pair
// _get_sensitivity_overview's samples carry (see that function's own
// docstring on why this is table-, not column-, granularity).
let sensitivityScanSelection = new Map(); // key -> {workspace_name, table_name}

function sensitivitySelectionKey(workspaceName, tableLabel) {
  return `${workspaceName}::${tableLabel}`;
}
// workspace_name -> the /api/workspace-roles response promise/result --
// shared across the sensitivity detail modal AND a future caller, keyed by
// name (not id, since that's all the sensitivity samples carry) and never
// evicted for the session: role assignments don't change mid-session and
// this is admin-only, low-cardinality data (dozens of distinct workspaces
// per category at most).
const workspaceRolesCache = new Map();
let sensitivityDetailState = null;
let workspaceAccessState = null;
let adminApiKeysCache = null;
let adminRevokedApiKeysCache = null; // audit trail, see auth.py's revoked_api_keys (2026-08-18)
let adminMetricsCache = null;
let adminUsageAnalyticsCache = null;
// 2026-08-25 Analíticas redesign: MCP call analytics (mcp_http_server.py
// usage, see analytics.get_mcp_usage_analytics) and the shared 7/30/90-day
// window both the lineage-usage and MCP sections filter by -- one shared
// value, not two, since "how far back" is the same question for both.
let adminMcpUsageCache = null;
let adminAnalyticsDays = 30;
// The raw key value only ever exists in the creation response -- kept here
// just long enough to show the one-time "copy it now" banner; cleared the
// moment the tab is left/re-rendered from a fresh load so it can't linger
// in memory or get shown again on a later visit.
let adminJustCreatedApiKey = null;
let businessGlossaryCache = null; // Tanda C -- fetched lazily the first time the glossary panel opens, not admin-only (see loadBusinessGlossary)
// Admin panel audit (2026-08-18): certifications/tags were curated in the
// admin panel but only ever surfaced inside the optional Graph Map Mode
// overlay -- a normal user in the default 2D explorer never saw them,
// which reads as "this feature doesn't work" from the admin's side. Same
// "load once, session-gated, cache client-side" pattern as
// businessGlossaryCache just above, except loaded eagerly at boot (see
// bootApp) instead of lazily on first panel open, since these render
// inline inside renderDetails/renderImpactDetails's own synchronous
// template rather than a separate on-demand panel.
let certificationsByQualifiedName = null; // Map<qualified_name, {certified_by, certified_at, note}>
let curatedTagsByQualifiedName = null; // Map<qualified_name, string[]>
// Roadmap Fase 3 (2026-08-31): Map<qualified_name, {name, owner_email}[]> --
// a qualified_name can belong to more than one data product, same as it can
// carry more than one curated tag.
let dataProductsByQualifiedName = null;

async function loadCertificationsAndTags() {
  try {
    const [certResponse, tagsResponse, dataProductsResponse] = await Promise.all([
      fetch(`${TRIGGER_SERVER_ORIGIN}/api/certifications`),
      fetch(`${TRIGGER_SERVER_ORIGIN}/api/tags`),
      fetch(`${TRIGGER_SERVER_ORIGIN}/api/data-products`)
    ]);
    const certPayload = certResponse.ok ? await certResponse.json() : { certifications: [] };
    const tagsPayload = tagsResponse.ok ? await tagsResponse.json() : { tags: [] };
    const dataProductsPayload = dataProductsResponse.ok ? await dataProductsResponse.json() : { data_products: [] };
    certificationsByQualifiedName = new Map(
      (certPayload.certifications || [])
        .filter(entry => entry.qualified_name)
        .map(entry => [entry.qualified_name, entry])
    );
    curatedTagsByQualifiedName = new Map();
    (tagsPayload.tags || []).forEach(entry => {
      if (!entry.qualified_name || !entry.tag) return;
      const list = curatedTagsByQualifiedName.get(entry.qualified_name) || [];
      list.push(entry.tag);
      curatedTagsByQualifiedName.set(entry.qualified_name, list);
    });
    dataProductsByQualifiedName = new Map();
    (dataProductsPayload.data_products || []).forEach(product => {
      (product.linked_qualified_names || []).forEach(qualifiedName => {
        if (!qualifiedName) return;
        const list = dataProductsByQualifiedName.get(qualifiedName) || [];
        list.push(product);
        dataProductsByQualifiedName.set(qualifiedName, list);
      });
    });
  } catch (error) {
    certificationsByQualifiedName = new Map();
    curatedTagsByQualifiedName = new Map();
    dataProductsByQualifiedName = new Map();
  }
  // Re-render whatever's already on screen so a node selected before this
  // (small, fast) fetch resolves picks up its badge/row retroactively,
  // same as loadColumnProfileSection/loadNodeCommentsSection do for their
  // own async sections.
  if (state.selectedNode) renderDetails(state.selectedNode);
}

function certificationEntryFor(qualifiedName) {
  return certificationsByQualifiedName && qualifiedName ? certificationsByQualifiedName.get(qualifiedName) : undefined;
}

function certifiedByDisplayValue(qualifiedName) {
  const entry = certificationEntryFor(qualifiedName);
  if (!entry) return '';
  return [entry.certified_by, entry.certified_at ? formatNodeCommentTimestamp(entry.certified_at) : ''].filter(Boolean).join(' · ');
}

function curatedTagsDisplayValue(qualifiedName) {
  if (!curatedTagsByQualifiedName || !qualifiedName) return '';
  const tags = curatedTagsByQualifiedName.get(qualifiedName);
  return tags && tags.length ? tags.join(', ') : '';
}

function dataProductsDisplayValue(qualifiedName) {
  if (!dataProductsByQualifiedName || !qualifiedName) return '';
  const products = dataProductsByQualifiedName.get(qualifiedName);
  if (!products || !products.length) return '';
  return products.map(p => p.owner_email ? `${p.name} (${p.owner_email})` : p.name).join(', ');
}
let adminLakehouseWorkspaceOptions = null; // [{workspace_name, workspace_id}], from /api/workspaces/mine
let adminLakehouseOptions = []; // [{lakehouse_name, lakehouse_id, sql_endpoint_connection_string}], from the selected workspace
// Sources are shown collapsed by default (just name/type/host) -- opening
// one to edit it is an explicit action, so a panel with a dozen external
// sources doesn't turn into a wall of forms.
let adminExpandedSourceIndexes = new Set();
// Which nav groups are expanded (2026-08-14 redesign) -- 'setup' starts
// open since 'tenant' (its first tab) is the default adminActiveTab; same
// expand/collapse-by-Set + full re-render pattern as
// adminExpandedSourceIndexes above. setAdminActiveTab() below always adds
// the newly-active tab's own group here too, so jumping to a tab inside a
// collapsed group opens it instead of leaving the active tab hidden.
let adminExpandedNavGroups = new Set(['setup']);

function setAdminActiveTab(tabKey) {
  adminActiveTab = tabKey;
  const group = adminTabGroups().find(candidate => candidate.tabs.some(tab => tab.key === tabKey));
  if (group) adminExpandedNavGroups.add(group.key);
}

// Grow-from-click open animation (2026-08-18): a capture-phase listener
// records where the LAST click on the page landed; since every openModal()
// call happens synchronously inside the click handler chain of whatever
// button triggered it (admin gear, help "?", scan history, etc.), reading
// this here is equivalent to threading the originating event through every
// toggleXPanel() call site without actually having to touch any of them.
// One-shot: cleared right after use so a later NON-click-triggered open
// (there are a couple of programmatic ones) doesn't reuse a stale point.
let lastClickOrigin = null;
document.addEventListener('click', event => {
  lastClickOrigin = { x: event.clientX, y: event.clientY };
}, true);

// Shared "mega menu" behavior for the log/admin/account surfaces (see
// .modal-panel/.modal-backdrop in styles.css): only one open at a time,
// each dims and blurs the rest of the page instead of floating over it.
function openModal(panelEl) {
  if (!panelEl) return;
  stackedModals.length = 0; // a top-level "mega menu" surface replaces any nested stack, not layers on it
  document.querySelectorAll('.modal-panel').forEach(el => { if (el !== panelEl) el.hidden = true; });
  panelEl.hidden = false;
  if (els.modalBackdrop) els.modalBackdrop.hidden = false;
  applyModalGrowOrigin(panelEl, lastClickOrigin);
  lastClickOrigin = null;
}

// True modal-over-modal stacking (2026-08-24), distinct from openModal()'s
// "mega menu" behavior above (one top-level surface at a time, replacing
// whatever was open). Used for panels meant to layer ON TOP of a surface
// that's already open -- e.g. the sensitivity detail modal opening over an
// already-open admin panel, or the workspace-access modal opening over
// that. Pushing never hides anything already visible; popping only hides
// the top layer, so whatever is underneath (however many levels) is
// exactly as it was left. closeAllModals() pops one layer at a time while
// this stack is non-empty instead of nuking every .modal-panel at once.
const stackedModals = [];

function pushStackedModal(panelEl) {
  if (!panelEl) return;
  panelEl.hidden = false;
  if (stackedModals[stackedModals.length - 1] === panelEl) return; // already the top layer (e.g. switching category while the modal stays open) -- don't stack a duplicate reference
  if (els.modalBackdrop) els.modalBackdrop.hidden = false;
  stackedModals.push(panelEl);
}

function popStackedModal() {
  const panelEl = stackedModals.pop();
  if (panelEl) panelEl.hidden = true;
  return panelEl;
}

// Scales the panel in from the exact point that was clicked to open it,
// ending at its normal centered size/position -- transform-origin is set
// to the click's position converted into a percentage of the panel's OWN
// (already laid out, since `hidden` was just cleared above) box; that
// percentage is free to fall outside 0-100% (typically does, since the
// trigger button usually isn't anywhere near the centered modal) and
// that's correct -- it's what makes the panel visibly travel from the
// button to its resting place instead of just scaling in place.
function applyModalGrowOrigin(panelEl, origin) {
  panelEl.classList.remove('modal-panel-grow-in');
  if (!origin) {
    panelEl.style.transformOrigin = '';
    return;
  }
  const rect = panelEl.getBoundingClientRect();
  if (!rect.width || !rect.height) {
    panelEl.style.transformOrigin = '';
    return;
  }
  const originX = ((origin.x - rect.left) / rect.width) * 100;
  const originY = ((origin.y - rect.top) / rect.height) * 100;
  panelEl.style.transformOrigin = `${originX}% ${originY}%`;
  void panelEl.offsetWidth;
  panelEl.classList.add('modal-panel-grow-in');
}

// The confidence ⓘ icon inside the impact breakdown modal opens the
// glossary via the same single-modal-at-a-time openModal() as everything
// else, which hides the impact modal underneath it -- fine for every other
// modal (they're independent surfaces), but here it's a nested "explain
// this term" popover, so closing the glossary should return to the impact
// breakdown the user was just looking at instead of leaving them at a
// blank page. Set right before opening the glossary from within the impact
// modal; consumed (and cleared) by restoreImpactModalIfNeeded() on every
// path that can close the glossary (button, backdrop click, Escape).
let impactModalWasOpenBeforeGlossary = false;

function restoreImpactModalIfNeeded() {
  if (!impactModalWasOpenBeforeGlossary) return;
  impactModalWasOpenBeforeGlossary = false;
  if (!impactBreakdownState) return;
  renderImpactBreakdownModal(impactBreakdownState.objectKey, impactBreakdownState.category);
  openModal(els.impactBreakdownModal);
}

function closeAllModals() {
  if (stackedModals.length > 0) {
    popStackedModal();
    return;
  }
  document.querySelectorAll('.modal-panel').forEach(el => { el.hidden = true; });
  if (els.modalBackdrop) els.modalBackdrop.hidden = true;
  if (els.adminButton) els.adminButton.setAttribute('aria-expanded', 'false');
  if (els.profileMenuProfileButton) els.profileMenuProfileButton.setAttribute('aria-expanded', 'false');
  if (els.notificationsButton) els.notificationsButton.setAttribute('aria-expanded', 'false');
  if (els.governanceButton) els.governanceButton.setAttribute('aria-expanded', 'false');
  if (els.profileMenu) els.profileMenu.hidden = true;
  if (els.userBadge) els.userBadge.setAttribute('aria-expanded', 'false');
  // Closing via Escape/backdrop click skipped toggleAdminPanel(false)'s own
  // cleanup entirely -- a just-created raw API key could otherwise sit in
  // the (now merely hidden, not re-rendered) admin panel's DOM until the
  // next time that tab happens to re-render (2026-08-17 security audit).
  // Clearing the node's own text is a second, independent belt-and-
  // suspenders step beyond nulling the JS state below: it takes effect
  // immediately, before whatever re-render eventually clears the state.
  const revealedKeyNode = document.getElementById('adminJustCreatedApiKeyValue');
  if (revealedKeyNode) revealedKeyNode.textContent = '';
  adminJustCreatedApiKey = null;
  restoreImpactModalIfNeeded();
}

document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && els.modalBackdrop && !els.modalBackdrop.hidden) closeAllModals();
});

// Info-icon popover (2026-08-18 admin panel redesign): explanatory text
// that used to sit directly under every field as a permanently-visible
// gray paragraph (.admin-field-hint) now hides behind a small "i" button
// next to the label, shown on click -- decluttering the panel without
// losing the explanation. One shared floating popover element (not one
// per icon) since only one can ever be open at a time; its content is set
// from whichever icon was clicked, read via a data attribute rather than
// re-rendered, so this works the same whether the icon lives in a static
// index.html panel or one rebuilt via innerHTML on every settings change.
let adminInfoPopoverTargetIcon = null;

function adminInfoIconHtml(hintText) {
  if (!hintText) return '';
  const label = state.lang === 'es' ? 'Más información' : 'More info';
  return ` <button type="button" class="admin-info-icon" data-admin-info-text="${escapeHtml(hintText)}" aria-label="${escapeHtml(label)}">i</button>`;
}

function positionAdminInfoPopover(iconEl) {
  if (!els.adminInfoPopover) return;
  const popover = els.adminInfoPopover;
  popover.textContent = iconEl.dataset.adminInfoText || '';
  popover.hidden = false;
  const iconRect = iconEl.getBoundingClientRect();
  const popoverRect = popover.getBoundingClientRect();
  const margin = 8;
  let left = Math.min(iconRect.left, window.innerWidth - popoverRect.width - margin);
  left = Math.max(margin, left);
  let top = iconRect.bottom + margin;
  if (top + popoverRect.height > window.innerHeight - margin) {
    top = iconRect.top - popoverRect.height - margin;
  }
  popover.style.left = `${left}px`;
  popover.style.top = `${top}px`;
}

function closeAdminInfoPopover() {
  if (els.adminInfoPopover) els.adminInfoPopover.hidden = true;
  adminInfoPopoverTargetIcon = null;
}

function toggleAdminInfoPopover(iconEl) {
  if (adminInfoPopoverTargetIcon === iconEl && els.adminInfoPopover && !els.adminInfoPopover.hidden) {
    closeAdminInfoPopover();
    return;
  }
  adminInfoPopoverTargetIcon = iconEl;
  positionAdminInfoPopover(iconEl);
}

document.addEventListener('click', event => {
  const icon = event.target.closest('.admin-info-icon');
  if (icon) {
    event.stopPropagation();
    toggleAdminInfoPopover(icon);
    return;
  }
  if (els.adminInfoPopover && !els.adminInfoPopover.hidden && !event.target.closest('.admin-info-popover')) {
    closeAdminInfoPopover();
  }
});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && els.adminInfoPopover && !els.adminInfoPopover.hidden) closeAdminInfoPopover();
});
if (els.adminPanel) els.adminPanel.addEventListener('scroll', closeAdminInfoPopover, true);
window.addEventListener('resize', closeAdminInfoPopover);

function toggleAdminPanel(forceOpen) {
  if (!els.adminPanel || !els.adminButton) return;
  const open = forceOpen !== undefined ? forceOpen : els.adminPanel.hidden;
  if (open) {
    openModal(els.adminPanel);
    loadAdminSettings();
  } else {
    stackedModals.length = 0; // belt-and-suspenders: any sensitivity detail/access popup left stacked on top closes with it
    if (els.sensitivityDetailModal) els.sensitivityDetailModal.hidden = true;
    if (els.workspaceAccessModal) els.workspaceAccessModal.hidden = true;
    if (els.tenantAdminWorkspacesModal) els.tenantAdminWorkspacesModal.hidden = true;
    if (els.installerWizardModal) els.installerWizardModal.hidden = true;
    if (els.workspaceCreateModal) els.workspaceCreateModal.hidden = true;
    els.adminPanel.hidden = true;
    if (els.modalBackdrop) els.modalBackdrop.hidden = true;
    adminJustCreatedApiKey = null;
  }
  els.adminButton.setAttribute('aria-expanded', String(open));
}

// Alerts / toolbar notifications (2026-08-18): surfaces two genuinely
// actionable things that would otherwise only be discovered by opening the
// admin panel and happening to check the right tab -- external-source
// connections that were assigned AND tested but came back unreachable, and
// content-confirmed sensitive-data hits. Admin-only, same gating as
// adminButton. "Alerts" internally (not "notifications") specifically to
// avoid confusion with the UNRELATED Notificaciones admin tab (SMTP/Teams
// scan-completion emails) -- this is a different concept that happens to
// share the word in Spanish.
//
// Deliberately does NOT surface "pending" external sources (no Fabric
// Connection assigned yet) as an alert (fixed 2026-08-26, user reported it
// as a false alarm -- "orígenes externos tiene configuración... eso es
// mentira"). Assigning a Fabric Connection is optional and only enables the
// "Probar conexión" button; it has zero effect on whether the source is
// discovered during a scan, so flagging its absence here reads as a real
// problem when it isn't one. That same data is already shown accurately,
// with the "doesn't affect the lineage graph" caveat, in the Sources tab's
// own "Pendientes de conexión" card -- see renderExternalSourceConnectionField.
let alertsSummaryCache = null;

async function refreshAlertsSummary() {
  if (!authState.isAdmin) return;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/notifications-summary`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    alertsSummaryCache = await response.json();
  } catch (error) {
    alertsSummaryCache = null;
  }
  applyAlertsBadge();
  if (els.notificationsPanel && !els.notificationsPanel.hidden) renderAlertsPanel();
}

function alertsCount() {
  if (!alertsSummaryCache) return 0;
  // "pending" (no Fabric Connection assigned) is deliberately excluded --
  // see the comment above refreshAlertsSummary for why that isn't a real alert.
  const broken = (alertsSummaryCache.external_sources && alertsSummaryCache.external_sources.broken_count) || 0;
  const flagged = (alertsSummaryCache.sensitivity && alertsSummaryCache.sensitivity.flagged_column_count) || 0;
  return broken + (flagged > 0 ? 1 : 0); // sensitivity counts as ONE alert (a category), not one per column
}

function applyAlertsBadge() {
  if (!els.notificationsBadge) return;
  const count = alertsCount();
  if (count > 0) {
    els.notificationsBadge.textContent = count > 99 ? '99+' : String(count);
    els.notificationsBadge.hidden = false;
  } else {
    els.notificationsBadge.hidden = true;
  }
}

function jumpToAdminTab(tabKey, sourceIndex) {
  toggleAlertsPanel(false);
  if (typeof sourceIndex === 'number') adminExpandedSourceIndexes.add(sourceIndex);
  setAdminActiveTab(tabKey);
  toggleAdminPanel(true);
}

function renderAlertsPanel() {
  if (!els.notificationsPanel) return;
  const es = state.lang === 'es';
  const data = alertsSummaryCache;
  const broken = (data && data.external_sources && data.external_sources.broken) || [];
  const sensitivity = (data && data.sensitivity) || {};

  const sourceItem = (item, subtitle) => `
    <button type="button" class="notifications-item" data-jump-tab="sources" data-jump-source-index="${item.index}">
      <svg class="notifications-item-icon" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false"><path d="M12 3l9 16H3L12 3Z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><path d="M12 10v4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="12" cy="17" r="0.9" fill="currentColor"/></svg>
      <span class="notifications-item-text">
        <span class="notifications-item-title">${escapeHtml(item.identifier)}</span>
        <span class="notifications-item-subtitle">${subtitle}${item.type ? ` · ${escapeHtml(item.type)}` : ''}</span>
      </span>
      <span class="notifications-item-chevron" aria-hidden="true">›</span>
    </button>`;

  const hasAnyAlert = broken.length > 0 || sensitivity.flagged_column_count > 0;

  const brokenCard = broken.length ? `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Conexión asignada pero sin acceso' : 'Connection assigned but not reachable'}</h4>
      ${broken.map(item => sourceItem(item, es ? 'Conexión asignada pero el gateway no llegó al origen' : "Connection assigned but the gateway couldn't reach it")).join('')}
    </div>` : '';

  const sensitivityCard = sensitivity.flagged_column_count > 0 ? `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Datos sensibles detectados' : 'Sensitive data detected'}</h4>
      <button type="button" class="notifications-item" data-jump-tab="sensitivity">
        <svg class="notifications-item-icon" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false"><rect x="4" y="10" width="16" height="10" rx="1.6" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M8 10V7a4 4 0 0 1 8 0v3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>
        <span class="notifications-item-text">
          <span class="notifications-item-title">${es ? `${sensitivity.flagged_column_count} columnas con datos sensibles confirmados` : `${sensitivity.flagged_column_count} columns with confirmed sensitive data`}</span>
          <span class="notifications-item-subtitle">${es ? `En ${sensitivity.checked_table_count || 0} tablas revisadas por contenido -- considera restringir el acceso o enmascarar esas columnas` : `Across ${sensitivity.checked_table_count || 0} content-checked tables -- consider restricting access or masking those columns`}</span>
        </span>
        <span class="notifications-item-chevron" aria-hidden="true">›</span>
      </button>
    </div>` : '';

  const emptyState = hasAnyAlert ? '' : `<div class="notifications-empty">${es ? 'Sin avisos por ahora. Aquí solo aparecen problemas reales: conexiones que fallaron al probarlas o datos sensibles confirmados.' : 'No alerts right now. This only shows real problems: connections that failed a real test, or confirmed sensitive data.'}</div>`;

  els.notificationsPanel.innerHTML = `
    <div class="scan-history-header">
      <span>${es ? 'Avisos' : 'Alerts'}</span>
      <button type="button" class="icon-button" data-close-notifications-panel aria-label="${es ? 'Cerrar' : 'Close'}">×</button>
    </div>
    ${brokenCard}
    ${sensitivityCard}
    ${emptyState}
  `;
  const closeButton = els.notificationsPanel.querySelector('[data-close-notifications-panel]');
  if (closeButton) closeButton.addEventListener('click', () => toggleAlertsPanel(false));
  els.notificationsPanel.querySelectorAll('[data-jump-tab]').forEach(button => {
    button.addEventListener('click', () => {
      const sourceIndex = button.dataset.jumpSourceIndex !== undefined ? Number(button.dataset.jumpSourceIndex) : undefined;
      jumpToAdminTab(button.dataset.jumpTab, sourceIndex);
    });
  });
}

function toggleAlertsPanel(forceOpen) {
  if (!els.notificationsPanel || !els.notificationsButton) return;
  const open = forceOpen !== undefined ? forceOpen : els.notificationsPanel.hidden;
  if (open) {
    renderAlertsPanel();
    openModal(els.notificationsPanel);
  } else {
    els.notificationsPanel.hidden = true;
    if (els.modalBackdrop) els.modalBackdrop.hidden = true;
  }
  els.notificationsButton.setAttribute('aria-expanded', String(open));
}

async function loadAdminSettings() {
  if (!els.adminPanel) return;
  els.adminPanel.innerHTML = state.lang === 'es' ? 'Cargando...' : 'Loading...';
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/settings`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminSettingsCache = await response.json();
    renderAdminPanel();
    loadActiveAdminTabData();
  } catch (error) {
    els.adminPanel.innerHTML = `<div class="scan-history-empty">${state.lang === 'es' ? 'No se pudo cargar la configuración.' : 'Could not load settings.'}</div>`;
  }
}

async function saveAdminSettings() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/settings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(adminSettingsCache),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      window.alert(payload.message || (state.lang === 'es' ? 'No se pudo guardar.' : 'Could not save.'));
      return false;
    }
    adminSettingsCache = payload;
    renderAdminPanel();
    // Any save can change what's "pending" (a connection just got
    // assigned to a source, a source just got added/removed, ...) --
    // refreshing here covers every save button without special-casing
    // which tab actually touched external_sources.
    refreshAlertsSummary();
    return true;
  } catch (error) {
    window.alert(state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.');
    return false;
  }
}

// Grouped nav (2026-08-14 redesign): the panel grew to 16 tabs one at a
// time (Tanda A/B/C etc), each just appended to one flat, wrapping row --
// fine at 8 tabs, unreadable at 16. Grouping by "what kind of thing is
// this" (setup vs who-can-access vs read-only insight vs curated content)
// is the same taxonomy the tabs already implicitly fell into; this just
// makes it visible as a sidebar instead of a fact you had to infer.
function adminTabGroups() {
  const es = state.lang === 'es';
  return [
    {
      key: 'setup',
      label: es ? 'Configuración' : 'Setup',
      tabs: [
        { key: 'tenant', label: es ? 'Tenant y autenticación' : 'Tenant & auth' },
        { key: 'lakehouse', label: es ? 'Almacén de escritura' : 'Write storage' },
        { key: 'pipeline', label: es ? 'Escaneo en Fabric' : 'Fabric-native scan' },
        { key: 'onelake', label: es ? 'Datos del explorador (OneLake)' : 'Explorer data (OneLake)' },
        { key: 'sources', label: es ? 'Orígenes externos' : 'External sources' },
        { key: 'notifications', label: es ? 'Notificaciones' : 'Notifications' },
      ],
    },
    {
      key: 'permissions',
      label: es ? 'Acceso' : 'Access',
      tabs: [
        { key: 'users', label: es ? 'Usuarios permitidos' : 'Allowed users' },
        { key: 'sessions', label: es ? 'Sesiones activas' : 'Active sessions' },
        { key: 'apikeys', label: 'API keys' },
      ],
    },
    {
      key: 'insights',
      label: es ? 'Información' : 'Insights',
      tabs: [
        { key: 'capacity', label: es ? 'Capacidad' : 'Capacity' },
        { key: 'changes', label: es ? 'Histórico de modificaciones' : 'Modification history' },
        { key: 'metrics', label: es ? 'Analíticas' : 'Analytics' },
      ],
    },
    {
      key: 'content',
      label: es ? 'Contenido' : 'Content',
      tabs: [
        { key: 'certifications', label: es ? 'Certificaciones' : 'Certifications' },
        { key: 'glossary', label: es ? 'Glosario de negocio' : 'Business glossary' },
        { key: 'tags', label: es ? 'Etiquetas' : 'Tags' },
        { key: 'dataquality', label: es ? 'Calidad de datos' : 'Data quality' },
        { key: 'sensitivitycategories', label: es ? 'Clasificadores de sensibilidad' : 'Sensitivity classifiers' },
        { key: 'dataproducts', label: es ? 'Productos de datos' : 'Data products' },
        { key: 'privacysystems', label: es ? 'Sistemas de privacidad' : 'Privacy systems' },
      ],
    },
  ];
}

// "Usuarios permitidos" (2026-08-24 Fase 3): one hand-maintained table
// instead of two separate blind email lists -- email, full name, Entra job
// title, and three permission checkboxes (admin panel / trigger full scan /
// install-and-register workspaces, the last one not enforced anywhere yet,
// see constants.py's DEFAULT_ADMIN_SETTINGS "install_emails" comment).
// admin_emails/full_scan_emails/install_emails are derived from this table
// (see deriveAllowlistsFromUsers) purely so the ~10 existing
// _email_in_allowlist() call sites on the backend keep working unchanged.
function renderAdminUsersTab() {
  const es = state.lang === 'es';
  const users = (adminSettingsCache.users || []).filter(u => matchesAdminListFilter('users', u.email, u.full_name, u.job_title));
  const rowsHtml = users.length ? `
    <div class="admin-embedded-table-scroll">
      <table class="impact-breakdown-table admin-users-table">
        <thead><tr>
          <th>Email</th>
          <th>${es ? 'Nombre completo' : 'Full name'}</th>
          <th>${es ? 'Puesto (Entra)' : 'Job title (Entra)'}</th>
          <th>${es ? 'Panel admin' : 'Admin panel'}</th>
          <th>${es ? 'Lanzar escaneo' : 'Trigger scan'}</th>
          <th>${es ? 'Instalar / dar de alta' : 'Install / register'}</th>
          <th></th>
        </tr></thead>
        <tbody>${users.map(u => `
          <tr>
            <td>${escapeHtml(u.email)}</td>
            <td><input type="text" class="admin-users-inline-input" data-user-field-email="${escapeHtml(u.email)}" data-user-field="full_name" value="${escapeHtml(u.full_name || '')}" placeholder="${es ? 'nombre completo' : 'full name'}" /></td>
            <td><input type="text" class="admin-users-inline-input" data-user-field-email="${escapeHtml(u.email)}" data-user-field="job_title" value="${escapeHtml(u.job_title || '')}" placeholder="${es ? 'puesto' : 'job title'}" /></td>
            <td><input type="checkbox" data-user-perm-email="${escapeHtml(u.email)}" data-user-perm="is_admin" ${u.is_admin ? 'checked' : ''} /></td>
            <td><input type="checkbox" data-user-perm-email="${escapeHtml(u.email)}" data-user-perm="can_full_scan" ${u.can_full_scan ? 'checked' : ''} /></td>
            <td><input type="checkbox" data-user-perm-email="${escapeHtml(u.email)}" data-user-perm="can_install" ${u.can_install ? 'checked' : ''} /></td>
            <td><button type="button" data-remove-user="${escapeHtml(u.email)}">×</button></td>
          </tr>`).join('')}</tbody>
      </table>
    </div>` : `<div class="scan-history-empty">${es ? 'Vacío.' : 'Empty.'}</div>`;
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Usuarios permitidos' : 'Allowed users'}${adminInfoIconHtml(es
        ? 'Cada fila es una persona añadida a mano. El nombre y el puesto se rellenan solos si la eliges buscando por nombre (directorio de Entra), o los escribes tú -- siempre editables. Los tres check deciden si puede ver el panel de administración, lanzar un escaneo completo, o (más adelante) instalar y dar de alta workspaces.'
        : 'Each row is a person added by hand. Name and job title fill in automatically when picked from the name search (Entra directory), or type them yourself -- always editable. The three checkboxes decide whether they can see the admin panel, trigger a full scan, or (later) install and register workspaces.')}</h4>
      ${rowsHtml}
      ${renderAdminUserSearchRow('users', 'adminAddUser')}
    </div>
  `;
}

// Tenant directory search (2026-08-18): the add-row input doubles as a
// typeahead over /api/admin/tenant-users -- picking a real person avoids
// typos in a hand-typed email, but the plain input still works exactly as
// before (Añadir button, Enter) if this tenant hasn't consented the Graph
// permission the search needs, so nothing regresses for that case.
function renderAdminUserSearchRow(listKey, inputId) {
  return `
    <div class="admin-add-row admin-user-search-row">
      <input type="email" id="${inputId}" placeholder="${state.lang === 'es' ? 'nombre@dominio.com o busca por nombre' : 'name@yourdomain.com or search by name'}" autocomplete="off" data-user-search-list="${listKey}" />
      <button type="button" data-add-email="${listKey}">${state.lang === 'es' ? 'Añadir' : 'Add'}</button>
    </div>
    <div id="${inputId}Results" class="admin-user-search-results" hidden></div>`;
}

// admin_emails/full_scan_emails/install_emails still exist in
// admin_settings.json (see constants.py) purely because ~10 backend call
// sites read them as flat lists -- recomputed here from the users table
// every time it changes so those call sites never see stale data.
function deriveAllowlistsFromUsers() {
  const users = adminSettingsCache.users || [];
  adminSettingsCache.admin_emails = users.filter(u => u.is_admin).map(u => u.email);
  adminSettingsCache.full_scan_emails = users.filter(u => u.can_full_scan).map(u => u.email);
  adminSettingsCache.install_emails = users.filter(u => u.can_install).map(u => u.email);
}

function addUserRow(rawEmail, fullName, jobTitle) {
  const email = (rawEmail || '').trim();
  if (!email) return;
  const normalized = email.toLowerCase();
  const users = adminSettingsCache.users || [];
  const existing = users.find(u => (u.email || '').trim().toLowerCase() === normalized);
  if (existing) {
    if (fullName && !existing.full_name) existing.full_name = fullName;
    if (jobTitle && !existing.job_title) existing.job_title = jobTitle;
  } else {
    adminSettingsCache.users = [...users, {
      email, full_name: fullName || '', job_title: jobTitle || '',
      is_admin: false, can_full_scan: false, can_install: false,
    }];
  }
  deriveAllowlistsFromUsers();
  saveAdminSettings();
}

function removeUserRow(email) {
  adminSettingsCache.users = (adminSettingsCache.users || []).filter(u => u.email !== email);
  deriveAllowlistsFromUsers();
  saveAdminSettings();
}

function updateUserField(email, field, value) {
  const user = (adminSettingsCache.users || []).find(u => u.email === email);
  if (!user) return;
  user[field] = value;
  if (field === 'is_admin' || field === 'can_full_scan' || field === 'can_install') deriveAllowlistsFromUsers();
  saveAdminSettings();
}

let adminUserSearchDebounceHandle = null;
async function scheduleAdminUserSearch(listKey, inputId, query) {
  if (adminUserSearchDebounceHandle) clearTimeout(adminUserSearchDebounceHandle);
  const resultsEl = document.getElementById(`${inputId}Results`);
  if (!query || query.trim().length < 2) {
    if (resultsEl) resultsEl.hidden = true;
    return;
  }
  adminUserSearchDebounceHandle = setTimeout(async () => {
    try {
      const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/tenant-users?q=${encodeURIComponent(query)}`);
      const payload = response.ok ? await response.json() : { users: [] };
      renderAdminUserSearchResults(listKey, inputId, payload.users || []);
    } catch (error) {
      renderAdminUserSearchResults(listKey, inputId, []);
    }
  }, 300);
}

function renderAdminUserSearchResults(listKey, inputId, users) {
  const resultsEl = document.getElementById(`${inputId}Results`);
  if (!resultsEl) return;
  if (!users.length) {
    resultsEl.hidden = true;
    resultsEl.innerHTML = '';
    return;
  }
  resultsEl.hidden = false;
  resultsEl.innerHTML = users.map(user => `
    <button type="button" class="admin-user-search-result" data-user-search-pick="${escapeHtml(user.email)}" data-user-search-list="${listKey}" data-user-search-name="${escapeHtml(user.display_name || '')}" data-user-search-job-title="${escapeHtml(user.job_title || '')}">
      <span class="admin-user-search-result-name">${escapeHtml(user.display_name || user.email)}</span>
      <span class="admin-user-search-result-email">${escapeHtml(user.email)}${user.job_title ? ` · ${escapeHtml(user.job_title)}` : ''}</span>
    </button>`).join('');
}

document.addEventListener('click', event => {
  if (event.target.closest('.admin-user-search-row, .admin-user-search-results')) return;
  document.querySelectorAll('.admin-user-search-results').forEach(el => { el.hidden = true; });
});

// The ~15 most common relational/analytical engines an external (non-
// Fabric) source might be, each with the connection fields it actually
// needs -- not every engine is host/port/user/password, so the form
// redraws per selected type instead of forcing one shape on all of them.
// See scripts/66_test_external_source_connection.ps1 for which of these
// have a real connection test today vs. "not testable from this server
// yet" (Snowflake/BigQuery/SQLite need their own connector, not installed
// here).
const EXTERNAL_SOURCE_TYPES = [
  { value: 'sql_server', label: 'Microsoft SQL Server', fields: ['host', 'port', 'database', 'auth_mode', 'user', 'password_ref'] },
  { value: 'azure_sql', label: 'Azure SQL Database', fields: ['host', 'port', 'database', 'auth_mode', 'user', 'password_ref'] },
  { value: 'azure_synapse', label: 'Azure Synapse Analytics', fields: ['host', 'port', 'database', 'auth_mode', 'user', 'password_ref'] },
  { value: 'postgresql', label: 'PostgreSQL', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'mysql', label: 'MySQL', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'mariadb', label: 'MariaDB', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'oracle', label: 'Oracle Database', fields: ['host', 'port', 'service_name', 'user', 'password_ref'] },
  { value: 'ibm_db2', label: 'IBM Db2', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'sap_hana', label: 'SAP HANA', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'teradata', label: 'Teradata', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'vertica', label: 'Vertica', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'amazon_redshift', label: 'Amazon Redshift', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'snowflake', label: 'Snowflake', fields: ['account', 'warehouse', 'database', 'schema', 'user', 'password_ref'] },
  { value: 'google_bigquery', label: 'Google BigQuery', fields: ['project_id', 'dataset', 'service_account_key_ref'] },
  { value: 'sqlite', label: 'SQLite', fields: ['file_path'] },
  { value: 'sybase_ase', label: 'SAP ASE / Sybase', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'informix', label: 'IBM Informix', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'clickhouse', label: 'ClickHouse', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'firebird', label: 'Firebird', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'progress_openedge', label: 'Progress OpenEdge', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'databricks_sql', label: 'Databricks SQL Warehouse', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'presto_trino', label: 'Presto / Trino', fields: ['host', 'port', 'database', 'user', 'password_ref'] },
  { value: 'sharepoint', label: 'SharePoint', fields: ['site_url'], group: 'files' },
];

// Mirrors scripts/66_test_external_source_connection.ps1's own
// $NotYetTestableEngines list exactly -- these 3 engines need their own
// connector (not installed here), so "Probar conexión" always reports
// "not yet supported" for them. Flagged in the type dropdown itself
// (2026-08-18 admin-panel audit finding) instead of only after a wasted
// click on Test.
const NOT_YET_TESTABLE_SOURCE_TYPES = new Set(['snowflake', 'google_bigquery', 'sqlite']);

// "database" (host/port/user/contraseña o token) vs "files" (sin puerto ni
// credenciales de base de datos -- otro modelo de conexión entero). Sólo
// SharePoint por ahora tiene group:'files' explícito; el resto son bases
// de datos por definición, así que ese es el valor por defecto.
function externalSourceTypeGroup(typeConfig) {
  return (typeConfig && typeConfig.group) || 'database';
}

const EXTERNAL_SOURCE_TYPE_GROUP_LABEL = {
  database: { es: 'Bases de datos', en: 'Databases' },
  files: { es: 'Archivos y sitios', en: 'Files and sites' },
};

const EXTERNAL_SOURCE_FIELD_META = {
  host: { es: 'Host', en: 'Host' },
  port: { es: 'Puerto', en: 'Port' },
  database: { es: 'Base de datos', en: 'Database' },
  service_name: { es: 'Service name / SID', en: 'Service name / SID' },
  user: { es: 'Usuario', en: 'User' },
  password_ref: { es: 'Variable de entorno con la contraseña', en: 'Password env var name', placeholder: 'MY_SOURCE_PASSWORD' },
  account: { es: 'Identificador de cuenta', en: 'Account identifier', placeholder: 'xy12345.eu-west-1' },
  warehouse: { es: 'Warehouse', en: 'Warehouse' },
  schema: { es: 'Schema', en: 'Schema' },
  project_id: { es: 'Project ID', en: 'Project ID' },
  dataset: { es: 'Dataset', en: 'Dataset' },
  service_account_key_ref: { es: 'Variable de entorno con la ruta a la clave de servicio', en: 'Service account key path env var', placeholder: 'MY_BQ_KEY_PATH' },
  file_path: { es: 'Ruta del fichero', en: 'File path', placeholder: 'C:\\data\\mi_base.sqlite' },
  site_url: { es: 'URL del sitio', en: 'Site URL', placeholder: 'https://tuempresa.sharepoint.com/sites/MiSitio' },
};

function externalSourceFieldLabel(key) {
  const meta = EXTERNAL_SOURCE_FIELD_META[key];
  if (!meta) return key;
  return state.lang === 'es' ? meta.es : meta.en;
}

// 2026-08-18, admin-panel completeness pass: none of the four admin-
// curated lists (certifications/tags/glossary/external sources) rejected
// an empty required field or a duplicate entry before saving -- an empty
// row (e.g. added then never filled in) or a copy-pasted duplicate saved
// silently. keyFn returning null means "never dedupe this entry" (used
// for glossary/sources below where an entry missing its identifying
// field was already filtered out by validFn first).
function _dedupeKeepingLast(list, keyFn) {
  const lastIndexByKey = new Map();
  list.forEach((entry, index) => {
    const key = keyFn(entry);
    if (key !== null) lastIndexByKey.set(key, index);
  });
  return list.filter((entry, index) => {
    const key = keyFn(entry);
    return key === null || lastIndexByKey.get(key) === index;
  });
}

function cleanCertificationsBeforeSave() {
  const withNames = (adminSettingsCache.certified_items || []).filter(entry => (entry.qualified_name || '').trim());
  adminSettingsCache.certified_items = _dedupeKeepingLast(withNames, entry => entry.qualified_name.trim().toLowerCase());
}

function cleanTagsBeforeSave() {
  const withFields = (adminSettingsCache.tags || []).filter(entry => (entry.qualified_name || '').trim() && (entry.tag || '').trim());
  adminSettingsCache.tags = _dedupeKeepingLast(withFields, entry => `${entry.qualified_name.trim().toLowerCase()}|${entry.tag.trim().toLowerCase()}`);
}

function cleanCustomSensitivityCategoriesBeforeSave() {
  const withFields = (adminSettingsCache.custom_sensitivity_categories || []).filter(entry =>
    (entry.key || '').trim() && (entry.patterns || []).length > 0
  );
  // Dedup by key -- unlike data-quality rules, two custom categories
  // sharing a key would be genuinely ambiguous (which one's label/risk
  // wins?), not two legitimate independent facts.
  adminSettingsCache.custom_sensitivity_categories = _dedupeKeepingLast(withFields, entry => entry.key.trim().toLowerCase());
}

function cleanDataQualityRulesBeforeSave() {
  // No dedup-by-target here unlike tags/certifications above -- several
  // rules legitimately targeting the same table/column (e.g. a
  // null_percentage_max AND a distinct_count_min on the same column) is
  // the normal case, not a duplicate to collapse.
  adminSettingsCache.data_quality_rules = (adminSettingsCache.data_quality_rules || []).filter(entry =>
    (entry.table_name || '').trim() && entry.threshold !== '' && entry.threshold !== null && entry.threshold !== undefined && !Number.isNaN(Number(entry.threshold))
  );
}

function cleanGlossaryBeforeSave() {
  // A term needs at least ONE language filled in (the render layer
  // already falls back ES<->EN at display time) -- reject only the
  // genuinely-empty case.
  const withATerm = (adminSettingsCache.business_glossary || []).filter(entry => (entry.term_es || '').trim() || (entry.term_en || '').trim());
  adminSettingsCache.business_glossary = _dedupeKeepingLast(withATerm, entry => `${(entry.term_es || '').trim().toLowerCase()}|${(entry.term_en || '').trim().toLowerCase()}`);
}

function cleanDataProductsBeforeSave() {
  const withNames = (adminSettingsCache.data_products || []).filter(entry => (entry.name || '').trim());
  adminSettingsCache.data_products = _dedupeKeepingLast(withNames, entry => entry.name.trim().toLowerCase());
}

function cleanPrivacyExternalSystemsBeforeSave() {
  // No dedup-by-category here -- several systems legitimately hold the
  // same category of data (e.g. both "Control de acceso físico" and
  // "App de terceros de reconocimiento facial" could both be biometric),
  // same reasoning data_quality_rules already applies for its own no-dedup.
  adminSettingsCache.privacy_external_systems = (adminSettingsCache.privacy_external_systems || []).filter(entry =>
    (entry.category || '').trim() && (entry.system_name || '').trim()
  );
}

function cleanExternalSourcesBeforeSave() {
  const withNames = (adminSettingsCache.external_sources || []).filter(entry => (entry.name || '').trim());
  adminSettingsCache.external_sources = _dedupeKeepingLast(withNames, entry => entry.name.trim().toLowerCase());
}

// Fabric connection assignment (2026-08-18): an external source can never
// actually be read during a scan without a real gateway-backed Fabric
// Connection -- registering host/port/credentials here alone documents
// intent, it doesn't make anything reachable. adminFabricConnectionsCache
// is fetched once (tenant-wide, not per-workspace like the Lakehouse/
// Pipeline pickers) the first time the Sources tab opens; not filtered by
// EXTERNAL_SOURCE_TYPES since Fabric's own connector type strings don't
// reliably map onto this project's own type labels -- shown as context
// instead so a human can match by path/host, not silently hidden.
let adminFabricConnectionsCache = null;

async function loadAdminFabricConnections() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/fabric-connections`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    adminFabricConnectionsCache = payload.connections || [];
  } catch (error) {
    adminFabricConnectionsCache = [];
  }
  if (adminActiveTab === 'sources') renderAdminPanel();
}

function computePendingExternalSources() {
  const sources = adminSettingsCache.external_sources || [];
  return sources
    .map((source, index) => ({ source, index }))
    .filter(({ source }) => !source.fabric_connection_id);
}

// Detected-but-not-configured external hosts (2026-08-24 Fase 4): distinct
// non-Fabric servers the LAST completed scan actually found referenced by
// real dependencies (see backend external_sources._get_detected_external_
// origins), so "Añadir origen" starts from "here's what to configure"
// instead of a blank form with no hostname to type. null = not fetched
// yet, {found:false} = fetched but no Warehouse/no scan data, otherwise
// {found:true, origins:[...]}.
let adminDetectedExternalSourcesCache = null;

async function loadDetectedExternalSources() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/detected-external-sources`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminDetectedExternalSourcesCache = await response.json();
  } catch (error) {
    adminDetectedExternalSourcesCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  if (adminActiveTab === 'sources') renderAdminPanel();
}

// A detected source_type is one of NB_Build_Graph_Map.py's broad
// SOURCE_TYPE_LAYER buckets ("SQL", "ExternalAPI", "File", ...), not a
// specific engine -- can't tell Postgres from SQL Server from just "SQL",
// so this only picks a reasonable STARTING point for the type dropdown;
// the admin still confirms/changes it. Anything not in this map falls
// back to 'sql_server', the most common real case so far.
const DETECTED_SOURCE_TYPE_DEFAULT = { SQL: 'sql_server', File: 'sqlite' };

function isExternalSourceHostAlreadyConfigured(host) {
  const needle = (host || '').trim().toLowerCase();
  if (!needle) return false;
  return (adminSettingsCache.external_sources || []).some(source => (source.host || source.account || '').trim().toLowerCase() === needle);
}

function renderDetectedExternalSourcesCard() {
  const es = state.lang === 'es';
  const data = adminDetectedExternalSourcesCache;
  const label = es ? 'Detectados en el último escaneo' : 'Detected in the last scan';
  const hint = es
    ? 'Servidores externos (no Fabric) que aparecen en las dependencias del último escaneo completo. Si no se ha escaneado todavía, esta lista sale vacía.'
    : "External (non-Fabric) servers that show up in the last full scan's dependencies. If nothing has been scanned yet, this list is empty.";
  if (data === null) {
    return `<div class="admin-card"><h4 class="admin-card-title">${label}</h4><div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div></div>`;
  }
  if (!data.found) {
    return `<div class="admin-card"><h4 class="admin-card-title">${label}${adminInfoIconHtml(hint)}</h4><div class="scan-history-empty">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</div></div>`;
  }
  const unconfigured = data.origins.filter(origin => !isExternalSourceHostAlreadyConfigured(origin.host));
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${label}${adminInfoIconHtml(hint)}</h4>
      ${unconfigured.length ? `<div class="admin-list">${unconfigured.map(origin => `
        <div class="admin-list-row">
          <span>${escapeHtml(origin.host)} <span class="admin-session-row-email">[${escapeHtml(origin.source_type)}${origin.databases.length ? ` · ${escapeHtml(origin.databases.slice(0, 3).join(', '))}${origin.databases.length > 3 ? '…' : ''}` : ''}]</span></span>
          <button type="button" class="admin-button-secondary" data-configure-detected-source="${escapeHtml(origin.host)}" data-detected-source-type="${escapeHtml(origin.source_type)}">${es ? 'Configurar' : 'Configure'}</button>
        </div>`).join('')}</div>` : `<div class="scan-history-empty">${data.origin_count ? (es ? 'Todos los detectados ya están configurados.' : 'Everything detected is already configured.') : (es ? 'Nada detectado todavía.' : 'Nothing detected yet.')}</div>`}
    </div>`;
}

function renderExternalSourceConnectionField(source, index) {
  const es = state.lang === 'es';
  const options = adminFabricConnectionsCache;
  const loading = options === null;
  const assignedNotInList = source.fabric_connection_id && !loading && !options.some(c => c.connection_id === source.fabric_connection_id);
  return `
    <div class="admin-field">
      <label>${es ? 'Conexión de Fabric (gateway)' : 'Fabric connection (gateway)'}${adminInfoIconHtml(es
        ? 'Esto NO hace que el origen se descubra ni se lea durante un escaneo -- eso ya pasa solo, a partir de lo que los propios items de Fabric reportan leer o escribir (ver "Detectados en el último escaneo" arriba). Esta conexión solo sirve para el botón "Probar conexión (vía Fabric)" de más abajo: comprobar, a través de un gateway de Fabric (on-premises o de red virtual), que el origen es alcanzable de verdad. Es opcional -- puedes dejarlo "Sin asignar" y el origen sigue apareciendo en el linaje igual.'
        : 'This does NOT make the source get discovered or read during a scan -- that already happens on its own, from what Fabric items themselves report reading or writing (see "Detected in the last scan" above). This connection only powers the "Test connection (via Fabric)" button further down: checking, through a Fabric gateway (on-premises or virtual network), that the source is actually reachable. It\'s optional -- leaving it "Not assigned" doesn\'t stop the source from showing up in the lineage graph.')}</label>
      <select data-source-connection-index="${index}" ${loading || !options.length ? 'disabled' : ''}>
        <option value="">${loading ? (es ? 'Cargando conexiones...' : 'Loading connections...') : (es ? 'Sin asignar' : 'Not assigned')}</option>
        ${(options || []).map(c => `<option value="${escapeHtml(c.connection_id)}" data-connection-name="${escapeHtml(c.connection_name)}" ${source.fabric_connection_id === c.connection_id ? 'selected' : ''}>${escapeHtml(c.connection_name)} (${escapeHtml(c.connectivity_type)}${c.connection_type ? ' · ' + escapeHtml(c.connection_type) : ''})</option>`).join('')}
      </select>
      ${!loading && !options.length ? `<p class="admin-field-hint">${es
        ? 'No se encontraron conexiones (o este tenant no ha concedido el permiso de Fabric necesario) -- puedes seguir sin asignar una por ahora.'
        : "No connections found (or this tenant hasn't granted the Fabric permission this needs) -- you can leave this unassigned for now."}</p>` : ''}
      ${assignedNotInList ? `<p class="admin-field-hint">${es
        ? `Asignada: ${escapeHtml(source.fabric_connection_name || source.fabric_connection_id)} (no aparece en la lista actual).`
        : `Assigned: ${escapeHtml(source.fabric_connection_name || source.fabric_connection_id)} (not in the current list).`}</p>` : ''}
      ${source.fabric_connection_id ? `
      <div class="admin-fabric-connection-test-row">
        <button type="button" class="admin-button-secondary" data-test-fabric-connection="${index}" data-connection-id="${escapeHtml(source.fabric_connection_id)}">${es ? 'Probar conexión (vía Fabric)' : 'Test connection (via Fabric)'}</button>
        <span class="admin-test-result" data-test-result="fabric-connection-${index}"></span>
        ${source.fabric_connection_last_test_status ? `<span class="badge admin-source-test-badge${source.fabric_connection_last_test_status === 'Online' ? '' : ' is-fail'}">${source.fabric_connection_last_test_status === 'Online' ? 'Online' : 'Offline'} · ${escapeHtml(formatAdminSessionTimestamp(source.fabric_connection_last_test_at))}</span>` : ''}
      </div>
      ${source.fabric_connection_last_test_status === 'Offline' && source.fabric_connection_last_test_message ? `<p class="admin-field-hint">${escapeHtml(source.fabric_connection_last_test_message)}</p>` : ''}
      <p class="admin-field-hint">${es
        ? 'Esta prueba puede tardar hasta un minuto -- le pide al gateway que compruebe el acceso de verdad, no es instantánea como las de arriba.'
        : "This test can take up to a minute -- it asks the gateway to actually check access, it's not instant like the ones above."}</p>` : ''}
    </div>`;
}

function renderPendingExternalSourcesCard() {
  const es = state.lang === 'es';
  const pending = computePendingExternalSources();
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Pendientes de conexión' : 'Pending connection'}${adminInfoIconHtml(es
        ? 'Orígenes sin una Conexión de Fabric asignada todavía -- no se puede comprobar si son alcanzables (botón "Probar conexión") hasta que asignes una. No afecta a si aparecen en el linaje: eso se detecta solo durante el escaneo, sin depender de esto. Se actualiza al momento según vayas asignando conexiones arriba, aunque no hayas pulsado "Guardar todo" todavía.'
        : 'Sources with no Fabric Connection assigned yet -- reachability can\'t be checked (the "Test connection" button) until you assign one. Doesn\'t affect whether they show up in the lineage graph: that\'s detected on its own during a scan, independent of this. Updates live as you assign connections above, even before you press "Save all".')}</h4>
      ${pending.length ? `<div class="admin-list">${pending.map(({ source, index }) => `
        <div class="admin-list-row">
          <span>${escapeHtml(source.name || _externalSourceIdentifierForDisplay(source))} <span class="admin-session-row-email">[${escapeHtml(source.type || '')}]</span></span>
          <button type="button" class="admin-button-secondary" data-expand-source="${index}">${es ? 'Configurar' : 'Configure'}</button>
        </div>`).join('')}</div>` : `<div class="scan-history-empty">${es ? 'Todos los orígenes tienen una conexión asignada.' : 'Every source has a connection assigned.'}</div>`}
    </div>`;
}

function _externalSourceIdentifierForDisplay(source) {
  return source.host || source.account || source.project_id || source.file_path || source.site_url || (state.lang === 'es' ? '(sin nombre)' : '(unnamed)');
}

// A ready-to-use env var name (2026-08-25) -- the field itself only ever
// stores a NAME, never the secret, but asking a non-technical admin to
// also invent that name from scratch was one confusion too many ("no sé
// cómo va eso de la variable de la contraseña" report). Derived from
// whatever the admin already typed as the source's name/host, so it reads
// as "this source's password", not a random token.
function suggestEnvVarName(source, field) {
  const base = (source.name || source.host || source.account || 'source').toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'SOURCE';
  const suffix = field === 'service_account_key_ref' ? 'KEY_PATH' : 'PASSWORD';
  return `EXTSRC_${base}_${suffix}`;
}

// password_ref/service_account_key_ref (2026-08-25 rework): a plain text
// input with the same label as every other field read as "type the secret
// here", which is exactly backwards -- this field is a POINTER (an env var
// name), the secret itself only ever lives in the server's own .env, never
// in this form or in admin_settings.json (same "env var, never a file"
// rule as the SMTP password and the Lakehouse service-principal secret).
// A dedicated block spells that out in place instead of relying on the
// info-icon popover alone, plus a one-click suggested name so the admin
// doesn't also have to invent one.
function renderSecretRefField(source, index, field) {
  const es = state.lang === 'es';
  const meta = EXTERNAL_SOURCE_FIELD_META[field] || {};
  const isKey = field === 'service_account_key_ref';
  const hint = es
    ? `Aquí NO va la contraseña -- va el NOMBRE de una variable de entorno. La ${isKey ? 'ruta real de la clave' : 'contraseña real'} se escribe aparte, en el servidor (archivo .env o variables de entorno del contenedor), nunca en este formulario. Ej.: si aquí pones ${suggestEnvVarName(source, field)}, alguien con acceso al servidor añade la línea "${suggestEnvVarName(source, field)}=${isKey ? 'C:\\ruta\\clave.json' : 'tu_contraseña_real'}" a ese .env y reinicia el servidor.`
    : `This is NOT the password -- it's the NAME of an environment variable. The real ${isKey ? 'key path' : 'password'} is set separately, on the server itself (.env file or container environment variables), never in this form. E.g. if you put ${suggestEnvVarName(source, field)} here, someone with server access adds the line "${suggestEnvVarName(source, field)}=${isKey ? 'C:\\path\\key.json' : 'your_real_password'}" to that .env and restarts the server.`;
  return `
    <div class="admin-field">
      <label>${externalSourceFieldLabel(field)}</label>
      <div class="admin-secret-ref-row">
        <input type="text" data-source-field="${field}" data-source-index="${index}" value="${escapeHtml(source[field] || '')}" placeholder="${escapeHtml(meta.placeholder || '')}" />
        <button type="button" class="admin-button-secondary" data-suggest-secret-ref="${field}" data-suggest-secret-ref-index="${index}">${es ? 'Sugerir nombre' : 'Suggest name'}</button>
      </div>
      <p class="admin-field-hint">${escapeHtml(hint)}</p>
    </div>`;
}

function renderExternalSourceRow(source, index) {
  const es = state.lang === 'es';
  const typeConfig = EXTERNAL_SOURCE_TYPES.find(candidate => candidate.value === source.type) || EXTERNAL_SOURCE_TYPES[0];
  const expanded = adminExpandedSourceIndexes.has(index);
  const summaryBits = [typeConfig.label, source.host || source.account || source.project_id || source.file_path || source.site_url || '']
    .filter(Boolean)
    .join(' · ');
  const statusDot = externalSourceStatusDotHtml(source);

  if (!expanded) {
    return `
    <div class="admin-external-source-row collapsed" data-source-index="${index}">
      <button type="button" class="admin-external-source-summary" data-expand-source="${index}">
        <span class="admin-external-source-chevron" aria-hidden="true">›</span>
        ${statusDot}
        <span class="admin-external-source-summary-text">
          <strong>${escapeHtml(source.name || (es ? '(sin nombre)' : '(unnamed)'))}</strong>
          <span>${escapeHtml(summaryBits)}</span>
        </span>
      </button>
      <button type="button" class="admin-list-row-remove" data-remove-source="${index}" title="${es ? 'Borrar' : 'Delete'}">×</button>
    </div>`;
  }

  const fieldsHtml = typeConfig.fields.map(field => {
    if (field === 'auth_mode') {
      return `<div class="admin-field"><label>${state.lang === 'es' ? 'Autenticación' : 'Authentication'}</label>
        <select data-source-field="auth_mode" data-source-index="${index}">
          <option value="sql_auth" ${source.auth_mode !== 'aad_token' ? 'selected' : ''}>${state.lang === 'es' ? 'Usuario y contraseña' : 'Username and password'}</option>
          <option value="aad_token" ${source.auth_mode === 'aad_token' ? 'selected' : ''}>${state.lang === 'es' ? 'Token de Azure AD' : 'Azure AD token'}</option>
        </select>
      </div>`;
    }
    if (field === 'password_ref' || field === 'service_account_key_ref') {
      return renderSecretRefField(source, index, field);
    }
    const meta = EXTERNAL_SOURCE_FIELD_META[field] || {};
    return `<div class="admin-field"><label>${externalSourceFieldLabel(field)}</label><input type="text" data-source-field="${field}" data-source-index="${index}" value="${escapeHtml(source[field] || '')}" placeholder="${escapeHtml(meta.placeholder || '')}" /></div>`;
  }).join('');

  return `
  <div class="admin-external-source-row" data-source-index="${index}">
    <div class="admin-external-source-row-header">
      <button type="button" class="admin-external-source-summary" data-expand-source="${index}">
        <span class="admin-external-source-chevron admin-external-source-chevron-open" aria-hidden="true">›</span>
        <strong>${escapeHtml(source.name || (state.lang === 'es' ? '(sin nombre)' : '(unnamed)'))}</strong>
      </button>
      <button type="button" class="admin-list-row-remove" data-remove-source="${index}" title="${state.lang === 'es' ? 'Borrar' : 'Delete'}">×</button>
    </div>
    <div class="admin-field"><label>${state.lang === 'es' ? 'Nombre' : 'Name'}</label><input type="text" data-source-field="name" data-source-index="${index}" value="${escapeHtml(source.name || '')}" /></div>
    <div class="admin-field"><label>${state.lang === 'es' ? 'Tipo de origen' : 'Source type'}</label>
      <select data-source-type-index="${index}">
        ${EXTERNAL_SOURCE_TYPES.map(candidate => `<option value="${candidate.value}" ${source.type === candidate.value ? 'selected' : ''}>${escapeHtml(candidate.label)}${NOT_YET_TESTABLE_SOURCE_TYPES.has(candidate.value) ? (es ? ' (no testeable aún)' : ' (not yet testable)') : ''}</option>`).join('')}
      </select>
      ${NOT_YET_TESTABLE_SOURCE_TYPES.has(typeConfig.value) ? `<p class="admin-field-hint">${es
        ? 'Este motor necesita su propio conector, todavía no instalado en el servidor -- "Probar conexión" siempre dirá que no es compatible.'
        : "This engine needs its own connector, not yet installed on the server -- \"Test connection\" will always report it's not supported."}</p>` : ''}
    </div>
    ${renderExternalSourceConnectionField(source, index)}
    ${fieldsHtml}
    <div class="admin-field"><label>${state.lang === 'es' ? 'Notas' : 'Notes'}</label><input type="text" data-source-field="notes" data-source-index="${index}" value="${escapeHtml(source.notes || '')}" /></div>
    <div class="admin-fabric-connection-test-row">
      <button type="button" class="admin-button-secondary" data-test-source="${index}">${state.lang === 'es' ? 'Probar conexión' : 'Test connection'}</button>
      ${statusDot}
      ${source.last_test_at ? `<span class="admin-session-row-email">${escapeHtml(formatAdminSessionTimestamp(source.last_test_at))}</span>` : ''}
    </div>
    <span class="admin-test-result" data-test-result="${index}">${source.last_test_message ? escapeHtml(source.last_test_message) : ''}</span>
  </div>`;
}

// Green/red status dot for a source row (2026-08-24 Fase 4) -- replaces
// the old session-only text badge AND the separate "Conexión asignada
// pero sin acceso" summary card the sensitivity audit found confusing:
// one glance here now answers "can this actually be reached", persisted
// (source.last_test_ok/last_test_at, written by the backend on a
// successful save-eligible test -- see external_sources._persist_
// external_source_test_result) instead of resetting on every reload.
// Grey/unknown until the source has been tested at least once.
function externalSourceStatusDotHtml(source) {
  const es = state.lang === 'es';
  if (source.last_test_ok === undefined || source.last_test_ok === null) {
    return `<span class="admin-source-status-dot is-unknown" title="${es ? 'Sin probar todavía' : 'Not tested yet'}"></span>`;
  }
  const label = source.last_test_ok ? (es ? 'Conecta' : 'Connects') : (es ? 'No conecta' : "Can't connect");
  const when = source.last_test_at ? ` · ${formatAdminSessionTimestamp(source.last_test_at)}` : '';
  return `<span class="admin-source-status-dot ${source.last_test_ok ? 'is-ok' : 'is-fail'}" title="${escapeHtml(label + when)}"></span>`;
}

// Agrupados por tipo en desplegables (2026-07-20) -- con más de 20 tipos de
// origen ya registrados, una lista plana se vuelve difícil de escanear. El
// grupo (database/files, ver externalSourceTypeGroup) importa más aquí que
// el tipo exacto: es la primera pregunta al buscar un origen concreto.
function renderExternalSourceRows() {
  const sources = adminSettingsCache.external_sources || [];
  if (!sources.length) {
    return `<div class="scan-history-empty">${state.lang === 'es' ? 'Sin orígenes externos configurados.' : 'No external sources configured.'}</div>`;
  }
  const groups = new Map();
  sources.forEach((source, index) => {
    const typeConfig = EXTERNAL_SOURCE_TYPES.find(candidate => candidate.value === source.type) || EXTERNAL_SOURCE_TYPES[0];
    const groupKey = externalSourceTypeGroup(typeConfig);
    if (!groups.has(groupKey)) groups.set(groupKey, []);
    groups.get(groupKey).push(index);
  });
  const groupOrder = ['database', 'files'].filter(key => groups.has(key));
  return groupOrder.map(groupKey => {
    const indexes = groups.get(groupKey);
    const groupLabelMeta = EXTERNAL_SOURCE_TYPE_GROUP_LABEL[groupKey] || { es: groupKey, en: groupKey };
    const groupLabel = state.lang === 'es' ? groupLabelMeta.es : groupLabelMeta.en;
    const rowsHtml = indexes.map(index => renderExternalSourceRow(sources[index], index)).join('');
    return `
    <details class="admin-external-source-group" open>
      <summary>${escapeHtml(groupLabel)} <span class="admin-external-source-group-count">${number(indexes.length)}</span></summary>
      <div class="admin-external-source-group-body">${rowsHtml}</div>
    </details>`;
  }).join('');
}

function formatAdminSessionTimestamp(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return date.toLocaleString(state.lang === 'es' ? 'es-ES' : 'en-GB', { dateStyle: 'short', timeStyle: 'short' });
}

function renderAdminSessionRows() {
  if (adminSessionsCache === null) {
    return `<div class="scan-history-empty">${state.lang === 'es' ? 'Cargando sesiones...' : 'Loading sessions...'}</div>`;
  }
  if (!adminSessionsCache.length) {
    return `<div class="scan-history-empty">${state.lang === 'es' ? 'Nadie ha iniciado sesión todavía.' : 'Nobody has signed in yet.'}</div>`;
  }
  const filtered = adminSessionsCache.filter(session => matchesAdminListFilter('sessions', session.user_name, session.user_email));
  if (!filtered.length) {
    return `<div class="scan-history-empty">${state.lang === 'es' ? 'Ninguna sesión coincide con el filtro.' : 'No session matches the filter.'}</div>`;
  }
  return `<div class="admin-list">${filtered.map(session => `
    <div class="admin-session-row">
      <div class="admin-session-row-main">
        <strong>${escapeHtml(session.user_name || session.user_email)}</strong>
        <span class="admin-session-row-email">${escapeHtml(session.user_email)}</span>
        ${session.is_fabric_tenant_admin ? `<span class="badge admin-tenant-admin-badge">${state.lang === 'es' ? 'Fabric Tenant Admin' : 'Fabric Tenant Admin'}</span>` : ''}
      </div>
      <div class="admin-session-row-meta">
        <span>${state.lang === 'es' ? 'Workspaces con acceso' : 'Accessible workspaces'}: ${session.accessible_workspace_count === null ? (state.lang === 'es' ? 'desconocido' : 'unknown') : session.accessible_workspace_count}</span>
        <span>${state.lang === 'es' ? 'Última actividad' : 'Last active'}: ${escapeHtml(formatAdminSessionTimestamp(session.last_seen_at))}</span>
        <span>${state.lang === 'es' ? 'Inició sesión' : 'Signed in'}: ${escapeHtml(formatAdminSessionTimestamp(session.created_at))}</span>
        ${session.object_id ? `<span class="admin-session-row-id">object id: ${escapeHtml(session.object_id)}</span>` : ''}
      </div>
      <button type="button" class="admin-list-row-remove" data-revoke-session="${escapeHtml(session.user_email)}">${state.lang === 'es' ? 'Cerrar sesión' : 'Sign out'}</button>
    </div>`).join('')}</div>`;
}

async function loadAdminSessions() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/sessions`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    adminSessionsCache = payload.sessions || [];
  } catch (error) {
    adminSessionsCache = [];
  }
  if (adminActiveTab === 'sessions') renderAdminPanel();
}

// Session history (2026-08-18): a bounded, process-lifetime log of ended
// sessions (signed out / revoked / expired) -- loaded alongside the active
// list so opening the history <details> never shows a loading flicker.
const ADMIN_SESSION_END_REASON_LABELS = {
  es: { signed_out: 'Cerró sesión', revoked_by_admin: 'Revocada por un admin', expired: 'Expiró' },
  en: { signed_out: 'Signed out', revoked_by_admin: 'Revoked by an admin', expired: 'Expired' },
};

async function loadAdminSessionHistory() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/session-history`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    adminSessionHistoryCache = payload.sessions || [];
  } catch (error) {
    adminSessionHistoryCache = [];
  }
  if (adminActiveTab === 'sessions') renderAdminPanel();
}

function renderAdminSessionHistoryRows() {
  if (adminSessionHistoryCache === null) {
    return `<div class="scan-history-empty">${state.lang === 'es' ? 'Cargando historial...' : 'Loading history...'}</div>`;
  }
  const filtered = adminSessionHistoryCache.filter(session => matchesAdminListFilter('sessions', session.user_name, session.user_email));
  if (!filtered.length) {
    return `<div class="scan-history-empty">${state.lang === 'es' ? 'Sin sesiones terminadas todavía.' : 'No ended sessions yet.'}</div>`;
  }
  const labels = ADMIN_SESSION_END_REASON_LABELS[state.lang] || ADMIN_SESSION_END_REASON_LABELS.es;
  return `<div class="admin-list">${filtered.map(session => `
    <div class="admin-session-row admin-session-history-row">
      <div class="admin-session-row-main">
        <strong>${escapeHtml(session.user_name || session.user_email)}</strong>
        <span class="admin-session-row-email">${escapeHtml(session.user_email)}</span>
        <span class="badge admin-session-end-reason-badge is-${escapeHtml(session.end_reason || '')}">${escapeHtml(labels[session.end_reason] || session.end_reason || '')}</span>
      </div>
      <div class="admin-session-row-meta">
        <span>${state.lang === 'es' ? 'Terminó' : 'Ended'}: ${escapeHtml(formatAdminSessionTimestamp(session.ended_at))}</span>
        <span>${state.lang === 'es' ? 'Inició sesión' : 'Signed in'}: ${escapeHtml(formatAdminSessionTimestamp(session.created_at))}</span>
        ${session.ip_address ? `<span>IP: ${escapeHtml(session.ip_address)}</span>` : ''}
        ${session.user_agent ? `<span title="${escapeHtml(session.user_agent)}">${escapeHtml(summarizeUserAgent(session.user_agent))}</span>` : ''}
      </div>
    </div>`).join('')}</div>`;
}

// Just enough to say "Chrome on Windows" / "Safari on iPhone" at a glance
// (2026-08-24) -- the full string is still in the title tooltip for anyone
// who wants the exact UA. Deliberately not a real UA-parsing library: this
// is a "who signed in, roughly from what" hint for an admin audit log, not
// analytics.
function summarizeUserAgent(userAgent) {
  const ua = userAgent || '';
  let os = '';
  if (/windows/i.test(ua)) os = 'Windows';
  else if (/iphone|ipad/i.test(ua)) os = 'iOS';
  else if (/mac os/i.test(ua)) os = 'macOS';
  else if (/android/i.test(ua)) os = 'Android';
  else if (/linux/i.test(ua)) os = 'Linux';
  let browser = '';
  if (/edg\//i.test(ua)) browser = 'Edge';
  else if (/chrome\//i.test(ua)) browser = 'Chrome';
  else if (/firefox\//i.test(ua)) browser = 'Firefox';
  else if (/safari\//i.test(ua)) browser = 'Safari';
  if (!browser && !os) return ua.slice(0, 40);
  return [browser, os].filter(Boolean).join(' / ');
}

async function revokeAdminSession(email) {
  const confirmMessage = state.lang === 'es'
    ? `¿Cerrar la sesión de ${email}? Tendrá que iniciar sesión de nuevo para volver a escanear o ver el panel de administración.`
    : `Sign out ${email}? They will need to sign in again to scan or see the admin panel.`;
  if (!window.confirm(confirmMessage)) return;
  try {
    await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/sessions/revoke`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email }),
    });
  } catch (error) {
    // best-effort -- reload below shows whatever the actual current state is
  }
  adminSessionsCache = null;
  renderAdminPanel();
  loadAdminSessions();
}

// --- API keys (2026-08-14 redesign): the backend has always had full
// create/list/revoke support (handler.py's /api/admin/api-keys*, used
// today by pasting a raw key into a Fabric pipeline's Web activity header
// by hand) but no admin-panel tab ever called it. Same lazy-load-on-
// first-open pattern as sessions/access/capacity/etc.

function apiKeyScopeLabel(scope) {
  const es = state.lang === 'es';
  if (scope === 'read_only') return es ? 'Solo lectura' : 'Read-only';
  return es ? 'Completo (lectura + escaneos)' : 'Full (read + scan control)';
}

// A value with no timezone offset (e.g. "2026-12-31T23:59:59", only
// reachable by posting raw JSON directly to POST /api/admin/api-keys,
// bypassing the date picker which always appends "+00:00") is treated as
// UTC here, matching auth.py's _api_key_expired exactly -- JS's Date
// constructor instead defaults a naive string to LOCAL time, which would
// silently disagree with the backend's own expiry check by the local UTC
// offset (2026-08-18 code review finding).
function _apiKeyExpiryAsUtcDate(iso) {
  if (!iso) return null;
  const hasTimezone = /Z$|[+-]\d{2}:\d{2}$/.test(iso);
  const date = new Date(hasTimezone ? iso : `${iso}Z`);
  return Number.isNaN(date.getTime()) ? null : date;
}

function apiKeyIsExpired(expiresAt) {
  const date = _apiKeyExpiryAsUtcDate(expiresAt);
  return date !== null && date.getTime() <= Date.now();
}

// Date-only, read from the UTC components -- createAdminApiKey stores
// expires_at as UTC end-of-day for whatever date the picker showed, so
// formatting it back through the browser's LOCAL timezone (as
// formatAdminSessionTimestamp does for real instants like created_at)
// would shift the displayed date by a day for anyone east of UTC (an
// admin in Madrid picking 31/12/2026 must not see "01/01/2027, 00:59").
function formatApiKeyExpiryDate(iso) {
  const date = _apiKeyExpiryAsUtcDate(iso);
  return date === null ? (iso || '') : date.toISOString().slice(0, 10);
}

function renderAdminApiKeysTab() {
  const es = state.lang === 'es';
  const revealBanner = adminJustCreatedApiKey ? `
    <div class="admin-key-reveal">
      <p class="admin-key-reveal-title">${es ? 'Copia esta clave ahora -- no se volverá a mostrar' : "Copy this key now -- it won't be shown again"}</p>
      <div class="admin-key-reveal-row">
        <code id="adminJustCreatedApiKeyValue">${escapeHtml(adminJustCreatedApiKey.key)}</code>
        <button type="button" data-copy-api-key="1">${es ? 'Copiar' : 'Copy'}</button>
      </div>
      <p class="admin-field-hint">${es
        ? `Nombre: ${escapeHtml(adminJustCreatedApiKey.name)}. Pégala en la cabecera X-Api-Key de quien la vaya a usar (por ejemplo, una actividad Web de un pipeline de Fabric, o un agente MCP).`
        : `Name: ${escapeHtml(adminJustCreatedApiKey.name)}. Paste it into the X-Api-Key header of whatever will use it (e.g. a Fabric pipeline Web activity, or an MCP agent).`}</p>
    </div>` : '';
  if (adminApiKeysCache === null) {
    return `${revealBanner}<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const rowsHtml = adminApiKeysCache.length ? adminApiKeysCache.map(entry => {
    const expired = apiKeyIsExpired(entry.expires_at);
    return `
    <div class="admin-session-row">
      <div class="admin-session-row-main">
        <strong>${escapeHtml(entry.name)}</strong>
        <span class="admin-session-row-email">${escapeHtml(entry.key_preview)}</span>
        <span class="badge admin-api-key-scope-badge${entry.scope === 'read_only' ? ' is-read-only' : ''}">${escapeHtml(apiKeyScopeLabel(entry.scope))}</span>
        ${expired ? `<span class="badge admin-api-key-expired-badge">${es ? 'Caducada' : 'Expired'}</span>` : ''}
      </div>
      ${entry.description ? `<p class="admin-field-hint admin-api-key-description">${escapeHtml(entry.description)}</p>` : ''}
      <div class="admin-session-row-meta">
        <span>${es ? 'Creada' : 'Created'}: ${escapeHtml(formatAdminSessionTimestamp(entry.created_at))}${entry.created_by ? ` · ${es ? 'por' : 'by'} ${escapeHtml(entry.created_by)}` : ''}</span>
        ${entry.expires_at ? `<span>${es ? 'Caduca' : 'Expires'}: ${escapeHtml(formatApiKeyExpiryDate(entry.expires_at))}</span>` : ''}
        <span>${es ? 'Último uso' : 'Last used'}: ${entry.last_used_at ? escapeHtml(formatAdminSessionTimestamp(entry.last_used_at)) : (es ? 'nunca en esta ejecución del servidor' : 'never this server run')}</span>
      </div>
      <button type="button" class="admin-list-row-remove" data-revoke-api-key="${escapeHtml(entry.name)}">${es ? 'Revocar' : 'Revoke'}</button>
    </div>`;
  }).join('') : `<div class="scan-history-empty">${es ? 'Sin API keys todavía.' : 'No API keys yet.'}</div>`;
  const revokedHtml = (adminRevokedApiKeysCache && adminRevokedApiKeysCache.length) ? `
    <details class="admin-workspace-access-group">
      <summary>${es ? 'Revocadas recientemente' : 'Recently revoked'} <span class="admin-session-row-email">(${adminRevokedApiKeysCache.length})</span></summary>
      <div class="admin-list">${adminRevokedApiKeysCache.slice().reverse().map(entry => `
        <div class="admin-list-row">
          <span><strong>${escapeHtml(entry.name)}</strong> <span class="admin-session-row-email">${escapeHtml(entry.key_preview)}</span></span>
          <span class="admin-session-row-email">${escapeHtml(formatAdminSessionTimestamp(entry.revoked_at))}${entry.revoked_by ? ` · ${es ? 'por' : 'by'} ${escapeHtml(entry.revoked_by)}` : ''}</span>
        </div>`).join('')}</div>
    </details>` : '';
  const mcpBaseUrl = window.location.origin;
  const mcpUrl = `${mcpBaseUrl}/mcp`;
  return `
    ${revealBanner}
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Conectar un agente MCP' : 'Connect an MCP agent'}${adminInfoIconHtml(es
        ? 'MCP (Model Context Protocol) es el protocolo que usan Claude, ChatGPT y otros agentes para llamar herramientas de un servidor externo. Este proyecto ya expone uno propio, real y en marcha -- ni instalación ni repositorio, solo una URL y una clave.'
        : "MCP (Model Context Protocol) is the protocol Claude, ChatGPT, and other agents use to call tools on an external server. This project already exposes its own, real and running -- no install, no repo checkout, just a URL and a key.")}</h4>
      <p class="admin-field-hint">${es
        ? 'Deja que un agente pregunte directamente sobre el linaje: workspaces, dependencias, impacto de un objeto, estado de escaneos, roles de acceso, historial de ejecuciones y más -- sin copiar/pegar nada desde este visor.'
        : "Lets an agent ask directly about the lineage catalog: workspaces, dependencies, an object's impact, scan status, access roles, run history, and more -- without copying/pasting anything out of this viewer."}</p>
      <div class="admin-field"><label>URL</label>
        <div class="admin-key-reveal-row"><code>${escapeHtml(mcpUrl)}</code></div>
      </div>
      <p class="admin-field-hint">${es
        ? 'Añade esta URL como servidor MCP remoto en Claude, ChatGPT o cualquier otro agente compatible, con esta cabecera (crea una clave abajo si no tienes una):'
        : 'Add this URL as a remote MCP server in Claude, ChatGPT, or any other compatible agent, with this header (create a key below if you don\'t have one yet):'}</p>
      <pre class="admin-code-block">Authorization: Bearer &lt;tu-api-key&gt;</pre>
      <details class="admin-help-details">
        <summary class="admin-help-summary">${es ? 'Pasos concretos por proveedor (Claude, ChatGPT, Cursor, Windsurf, Copilot...)' : 'Exact steps per provider (Claude, ChatGPT, Cursor, Windsurf, Copilot...)'}</summary>
        <p class="admin-field-hint">${es
          ? 'La pantalla exacta de cada producto cambia con el tiempo -- lo único estable es "URL + cabecera Authorization". Detalle actualizado en docs/110_mcp_remote_setup.md, incluyendo:'
          : "Each product's exact screen changes over time -- the only stable part is \"URL + Authorization header\". Up-to-date detail in docs/110_mcp_remote_setup.md, including:"}</p>
        <pre class="admin-code-block">claude mcp add --transport http fabric-lineage ${escapeHtml(mcpUrl)} --header "Authorization: Bearer &lt;tu-api-key&gt;"</pre>
        <p class="admin-field-hint">${es ? '(Claude Code -- para Claude Desktop/claude.ai, Cursor, Windsurf, ChatGPT y Copilot, ver el documento.)' : '(Claude Code -- for Claude Desktop/claude.ai, Cursor, Windsurf, ChatGPT, and Copilot, see the doc.)'}</p>
      </details>
      <details class="admin-help-details">
        <summary class="admin-help-summary">${es ? '¿Tu cliente solo soporta procesos locales (stdio), no una URL?' : "Your client only supports local processes (stdio), not a URL?"}</summary>
        <p class="admin-field-hint">${es
          ? 'Descarga este script y regístralo como un servidor MCP local -- llama a la API de este mismo servidor por HTTP, así que tampoco necesita el repositorio ni acceso a Fabric.'
          : "Download this script and register it as a local MCP server -- it calls this same server's API over HTTP, so it doesn't need the repo or Fabric access either."}</p>
        <div><a href="/mcp_server_remote.py" download="mcp_server_remote.py" class="admin-button-secondary admin-download-link">${es ? '⬇ Descargar mcp_server_remote.py' : '⬇ Download mcp_server_remote.py'}</a></div>
        <pre class="admin-code-block">pip install mcp
claude mcp add fabric-lineage -- python3 mcp_server_remote.py --base-url ${escapeHtml(mcpBaseUrl)}</pre>
        <p class="admin-field-hint">${es
          ? 'Con este script, cada herramienta pide la clave como argumento -- pásasela al agente en la conversación cuando la pida.'
          : 'With this script, every tool asks for the key as an argument -- give it to the agent in the conversation when it asks.'}</p>
      </details>
    </div>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Claves existentes' : 'Existing keys'}${adminInfoIconHtml(es
        ? 'Para llamar a la API desde fuera de esta web (por ejemplo, desde un pipeline de Fabric o un agente MCP) con la cabecera X-Api-Key en vez de una sesión de usuario.'
        : 'For calling the API from outside this website (e.g. from a Fabric pipeline or an MCP agent) with the X-Api-Key header instead of a user session.')}</h4>
      ${rowsHtml}
      ${revokedHtml}
    </div>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Crear una clave nueva' : 'Create a new key'}</h4>
      <div class="admin-field"><label>${es ? 'Nombre' : 'Name'}</label><input type="text" id="adminAddApiKeyName" placeholder="${es ? 'ej. "Pipeline nocturno"' : 'e.g. "Nightly pipeline"'}" /></div>
      <div class="admin-field"><label>${es ? 'Descripción' : 'Description'}</label><input type="text" id="adminAddApiKeyDescription" placeholder="${es ? 'Para qué agente o integración es' : 'Which agent/integration this is for'}" /></div>
      <div class="admin-field">
        <label>${es ? 'Alcance' : 'Scope'}</label>
        <select id="adminAddApiKeyScope">
          <option value="read_only">${es ? 'Solo lectura (recomendado para agentes)' : 'Read-only (recommended for agents)'}</option>
          <option value="full">${es ? 'Completo (lectura + escaneos)' : 'Full (read + scan control)'}</option>
        </select>
      </div>
      <div class="admin-field"><label>${es ? 'Caduca el (opcional)' : 'Expires on (optional)'}</label><input type="date" id="adminAddApiKeyExpiresAt" /></div>
      <button type="button" class="admin-save-button" data-create-api-key="1">${es ? '+ Crear' : '+ Create'}</button>
      <span class="admin-test-result" data-test-result="api-key-create"></span>
    </div>
  `;
}

async function loadAdminApiKeys() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/api-keys`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    adminApiKeysCache = payload.api_keys || [];
    adminRevokedApiKeysCache = payload.revoked_api_keys || [];
  } catch (error) {
    adminApiKeysCache = [];
    adminRevokedApiKeysCache = [];
  }
  if (adminActiveTab === 'apikeys') renderAdminPanel();
}

async function createAdminApiKey() {
  const nameInput = document.getElementById('adminAddApiKeyName');
  const name = nameInput ? nameInput.value.trim() : '';
  const description = (document.getElementById('adminAddApiKeyDescription') || {}).value || '';
  const scope = (document.getElementById('adminAddApiKeyScope') || {}).value || 'read_only';
  const expiresAtDate = (document.getElementById('adminAddApiKeyExpiresAt') || {}).value || '';
  // <input type="date"> gives "YYYY-MM-DD" -- normalize to a real ISO
  // timestamp (end of that day, UTC) so it compares cleanly against
  // _now_iso() on the backend (_api_key_expired).
  const expiresAt = expiresAtDate ? `${expiresAtDate}T23:59:59+00:00` : '';
  const resultEl = els.adminPanel.querySelector('[data-test-result="api-key-create"]');
  if (!name) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'Ponle un nombre primero.' : 'Give it a name first.'; resultEl.className = 'admin-test-result fail'; }
    return;
  }
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/api-keys`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, description: description.trim(), scope, expires_at: expiresAt }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (resultEl) { resultEl.textContent = payload.message || (state.lang === 'es' ? 'No se pudo crear.' : 'Could not create.'); resultEl.className = 'admin-test-result fail'; }
      return;
    }
    adminJustCreatedApiKey = payload;
    adminApiKeysCache = null;
    renderAdminPanel();
    loadAdminApiKeys();
  } catch (error) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

async function revokeAdminApiKey(name) {
  const confirmMessage = state.lang === 'es'
    ? `¿Revocar la API key "${name}"? Cualquier cosa que la use dejará de funcionar de inmediato.`
    : `Revoke the "${name}" API key? Anything using it will stop working immediately.`;
  if (!window.confirm(confirmMessage)) return;
  try {
    await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/api-keys/revoke`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name }),
    });
  } catch (error) {
    // best-effort -- reload below shows whatever the actual current state is
  }
  adminApiKeysCache = null;
  renderAdminPanel();
  loadAdminApiKeys();
}

// 2026-08-18, admin-panel completeness pass: nothing in this tab showed
// whether "Copiar datos ahora" (or the auto-upload-after-scan setting)
// was actually succeeding -- an admin had to leave the panel and dig
// through general scan history. Reuses the existing /api/history route
// (already public/session-gated, no new backend needed) filtered to the
// same WAREHOUSE_UPLOAD_LABEL scan_manager.py already records real
// uploads under.
let adminWarehouseUploadHistoryCache = null; // undefined-until-loaded via null sentinel, same convention as the other admin caches

async function loadAdminWarehouseUploadHistory() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/history?workspace=${encodeURIComponent('__warehouse_upload__')}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    adminWarehouseUploadHistoryCache = payload.runs || [];
  } catch (error) {
    adminWarehouseUploadHistoryCache = [];
  }
  if (adminActiveTab === 'lakehouse') renderAdminPanel();
}

function renderLastWarehouseUploadLine() {
  const es = state.lang === 'es';
  if (adminWarehouseUploadHistoryCache === null) return es ? 'Cargando última copia...' : 'Loading last copy...';
  const lastSuccess = adminWarehouseUploadHistoryCache.find(run => run.status === 'succeeded');
  if (!lastSuccess) return es ? 'Todavía no se ha copiado nada con éxito.' : "Nothing has copied successfully yet.";
  return es
    ? `Última copia exitosa: ${escapeHtml(formatAdminSessionTimestamp(lastSuccess.ended_at))}`
    : `Last successful copy: ${escapeHtml(formatAdminSessionTimestamp(lastSuccess.ended_at))}`;
}

async function loadAdminLakehouseWorkspaces() {
  const select = document.getElementById('adminLhWorkspaceSelect');
  if (!select) return;
  // renderAdminPanel() replaces the whole tab's innerHTML every time the
  // admin panel (re)opens, so a brand new <select> showing only the static
  // "Cargando workspaces..." placeholder exists here even on a second visit
  // -- unlike the other admin tabs (sessions/access/capacity/...), which
  // read their cache straight from the synchronous render template, this
  // select is only ever populated from here. Only skip the network
  // request when already cached (2026-07-21: reopening the admin panel a
  // second time left the dropdown stuck on the loading placeholder forever,
  // because the caller only invoked this function once per page session);
  // still always repopulate the DOM below.
  if (adminLakehouseWorkspaceOptions === null) {
    select.disabled = true;
    try {
      const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/workspaces/mine`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      adminLakehouseWorkspaceOptions = payload.workspaces || [];
    } catch (error) {
      adminLakehouseWorkspaceOptions = [];
    }
  }
  const savedWorkspaceId = (adminSettingsCache.lakehouse || {}).workspace_id || '';
  select.disabled = false;
  select.innerHTML = `<option value="">${state.lang === 'es' ? 'Elige un workspace...' : 'Choose a workspace...'}</option>`
    + adminLakehouseWorkspaceOptions.map(workspace =>
      `<option value="${escapeHtml(workspace.workspace_id)}" ${workspace.workspace_id === savedWorkspaceId ? 'selected' : ''}>${escapeHtml(workspace.workspace_name)}</option>`
    ).join('');
  if (savedWorkspaceId && adminLakehouseWorkspaceOptions.some(w => w.workspace_id === savedWorkspaceId)) {
    await loadAdminLakehouseOptions(savedWorkspaceId);
  }
}

async function loadAdminLakehouseOptions(workspaceId) {
  const select = document.getElementById('adminLhLakehouseSelect');
  const itemTypeSelect = document.getElementById('adminLhItemType');
  const itemLabel = document.getElementById('adminLhItemLabel');
  const itemType = (itemTypeSelect && itemTypeSelect.value) || 'Lakehouse';
  if (itemLabel) itemLabel.textContent = itemType;
  if (!select) return;
  if (!workspaceId) {
    select.innerHTML = `<option value="">${state.lang === 'es' ? 'Elige un workspace primero' : 'Choose a workspace first'}</option>`;
    select.disabled = true;
    return;
  }
  select.disabled = true;
  select.innerHTML = `<option value="">${state.lang === 'es' ? 'Cargando...' : 'Loading...'}</option>`;
  // Same picker either way (see fabric_api._fetch_warehouses_in_workspace),
  // just a different endpoint/path segment depending on which item type is
  // selected above.
  const endpoint = itemType === 'Warehouse' ? 'warehouses' : 'lakehouses';
  let loadErrorMessage = '';
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/workspaces/${encodeURIComponent(workspaceId)}/${endpoint}`);
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      // Surfaced instead of silently showing an empty list -- an empty
      // dropdown and "the Fabric API call actually failed" used to look
      // identical, which is exactly what a real "I don't see my Warehouse"
      // report (2026-07-20) turned out to be masking.
      loadErrorMessage = payload.message || `HTTP ${response.status}`;
      adminLakehouseOptions = [];
    } else {
      adminLakehouseOptions = payload[endpoint] || [];
    }
  } catch (error) {
    loadErrorMessage = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.';
    adminLakehouseOptions = [];
  }
  const savedLakehouseId = (adminSettingsCache.lakehouse || {}).lakehouse_id || '';
  select.disabled = false;
  const emptyLabel = loadErrorMessage
    ? `${state.lang === 'es' ? 'Error' : 'Error'}: ${loadErrorMessage}`
    : adminLakehouseOptions.length === 0
      ? (state.lang === 'es' ? `Sin ${itemType} en este workspace` : `No ${itemType} in this workspace`)
      : itemType === 'Warehouse'
        ? (state.lang === 'es' ? 'Elige un Warehouse...' : 'Choose a Warehouse...')
        : (state.lang === 'es' ? 'Elige un Lakehouse...' : 'Choose a Lakehouse...');
  select.innerHTML = `<option value="">${escapeHtml(emptyLabel)}</option>`
    + adminLakehouseOptions.map(item =>
      `<option value="${escapeHtml(item.lakehouse_id)}" ${item.lakehouse_id === savedLakehouseId ? 'selected' : ''}>${escapeHtml(item.lakehouse_name)}</option>`
    ).join('');
  const preselected = adminLakehouseOptions.find(l => l.lakehouse_id === savedLakehouseId);
  if (preselected) {
    const sqlEndpointInput = document.getElementById('adminLhSqlEndpoint');
    if (sqlEndpointInput && preselected.sql_endpoint_connection_string) {
      sqlEndpointInput.value = preselected.sql_endpoint_connection_string;
    }
  }
}

// 2026-08-18, admin-panel completeness pass: same live-picker UX as the
// Lakehouse tab's own loadAdminLakehouseWorkspaces/loadAdminLakehouseOptions
// pair above, for the Fabric-pipeline tab -- reuses the SAME cached
// adminLakehouseWorkspaceOptions (one /api/workspaces/mine fetch serves
// both tabs) rather than a second, redundant one.
let adminPipelineOptions = []; // [{pipeline_name, pipeline_id}], from the selected workspace

async function loadAdminPipelineWorkspaces() {
  const select = document.getElementById('adminPipelineWorkspaceSelect');
  if (!select) return;
  if (adminLakehouseWorkspaceOptions === null) {
    select.disabled = true;
    try {
      const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/workspaces/mine`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      adminLakehouseWorkspaceOptions = payload.workspaces || [];
    } catch (error) {
      adminLakehouseWorkspaceOptions = [];
    }
  }
  const savedWorkspaceId = (adminSettingsCache.discovery_pipeline || {}).workspace_id || '';
  select.disabled = false;
  select.innerHTML = `<option value="">${state.lang === 'es' ? 'Elige un workspace...' : 'Choose a workspace...'}</option>`
    + adminLakehouseWorkspaceOptions.map(workspace =>
      `<option value="${escapeHtml(workspace.workspace_id)}" ${workspace.workspace_id === savedWorkspaceId ? 'selected' : ''}>${escapeHtml(workspace.workspace_name)}</option>`
    ).join('');
  if (savedWorkspaceId && adminLakehouseWorkspaceOptions.some(w => w.workspace_id === savedWorkspaceId)) {
    await loadAdminPipelineOptions(savedWorkspaceId);
  }
}

async function loadAdminPipelineOptions(workspaceId) {
  const select = document.getElementById('adminPipelineItemSelect');
  if (!select) return;
  if (!workspaceId) {
    adminPipelineOptions = [];
    select.innerHTML = `<option value="">${state.lang === 'es' ? 'Elige un workspace primero' : 'Choose a workspace first'}</option>`;
    select.disabled = true;
    return;
  }
  select.disabled = true;
  select.innerHTML = `<option value="">${state.lang === 'es' ? 'Cargando...' : 'Loading...'}</option>`;
  let loadErrorMessage = '';
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/workspaces/${encodeURIComponent(workspaceId)}/pipelines`);
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      loadErrorMessage = payload.message || `HTTP ${response.status}`;
      adminPipelineOptions = [];
    } else {
      adminPipelineOptions = payload.pipelines || [];
    }
  } catch (error) {
    loadErrorMessage = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.';
    adminPipelineOptions = [];
  }
  const savedPipelineId = (adminSettingsCache.discovery_pipeline || {}).pipeline_item_id || '';
  select.disabled = false;
  const emptyLabel = loadErrorMessage
    ? `${state.lang === 'es' ? 'Error' : 'Error'}: ${loadErrorMessage}`
    : adminPipelineOptions.length === 0
      ? (state.lang === 'es' ? 'Sin Data Pipelines en este workspace' : 'No Data Pipelines in this workspace')
      : (state.lang === 'es' ? 'Elige un Data Pipeline...' : 'Choose a Data Pipeline...');
  select.innerHTML = `<option value="">${escapeHtml(emptyLabel)}</option>`
    + adminPipelineOptions.map(item =>
      `<option value="${escapeHtml(item.pipeline_id)}" ${item.pipeline_id === savedPipelineId ? 'selected' : ''}>${escapeHtml(item.pipeline_name)}</option>`
    ).join('');
}

function renderAdminPanel() {
  if (!els.adminPanel || !adminSettingsCache) return;
  const groups = adminTabGroups();
  const lakehouse = adminSettingsCache.lakehouse || {};
  els.adminPanel.innerHTML = `
    <div class="scan-history-header">
      <h3>${state.lang === 'es' ? 'Panel de administración' : 'Admin panel'}</h3>
      <button type="button" class="icon-button" data-close-modal aria-label="${state.lang === 'es' ? 'Cerrar' : 'Close'}">×</button>
    </div>
    <div class="admin-panel-body">
      <nav class="admin-nav" aria-label="${state.lang === 'es' ? 'Secciones' : 'Sections'}">
        ${groups.map(group => {
          const expanded = adminExpandedNavGroups.has(group.key);
          return `
          <div class="admin-nav-group">
            <button type="button" class="admin-nav-group-header" data-toggle-nav-group="${group.key}" aria-expanded="${expanded}">
              <span class="admin-nav-group-chevron${expanded ? ' admin-nav-group-chevron-open' : ''}" aria-hidden="true">›</span>
              ${group.icon ? `<span class="admin-nav-group-icon" aria-hidden="true">${group.icon}</span>` : ''}
              <span class="admin-nav-group-title">${group.label}</span>
            </button>
            ${expanded ? `<div class="admin-nav-group-body">
              ${group.tabs.map(tab => `<button type="button" class="admin-nav-tab${adminActiveTab === tab.key ? ' active' : ''}" data-admin-tab="${tab.key}">${tab.label}</button>`).join('')}
            </div>` : ''}
          </div>`;
        }).join('')}
      </nav>
      <div class="admin-tab-panels">
    <datalist id="qualifiedNameSuggestions"></datalist>
    <div class="admin-tab-panel${adminActiveTab === 'tenant' ? ' active' : ''}" data-admin-tab-panel="tenant">
      <div class="admin-card">
        <h4 class="admin-card-title">${state.lang === 'es' ? 'Conexión al tenant' : 'Tenant connection'}</h4>
        <div class="admin-field"><label>Tenant ID</label><input type="text" id="adminTenantId" value="${escapeHtml(adminSettingsCache.tenant_id || '')}" /></div>
        <div class="admin-field"><label>Entra Client ID${adminInfoIconHtml(state.lang === 'es' ? 'Vacío = usa el cliente público de Azure CLI, que ya funciona para casi todos los tenants. Solo hace falta esto si tu organización requiere un registro de aplicación Entra propio.' : "Empty = uses the Azure CLI public client, which already works for almost every tenant. Only needed if your organization requires its own Entra app registration.")}</label><input type="text" id="adminClientId" value="${escapeHtml(adminSettingsCache.entra_client_id || '')}" placeholder="${state.lang === 'es' ? 'Vacío = usa el cliente público de Azure CLI' : 'Empty = uses the Azure CLI public client'}" /></div>
        <button type="button" class="admin-save-button" data-admin-save="tenant">${state.lang === 'es' ? 'Guardar' : 'Save'}</button>
      </div>
      <div class="admin-card">
        <h4 class="admin-card-title">${state.lang === 'es' ? 'Permisos para Gobernanza (Scanner API)' : 'Permissions for Governance (Scanner API)'}${adminInfoIconHtml(state.lang === 'es'
          ? 'La pestaña Gobernanza > "RLS, etiquetas y endorsement" necesita permisos que el resto de este proyecto no usa. Nada de esto lo puede conceder la propia app -- lo tiene que revisar alguien con acceso al Admin Portal de Fabric/Power BI y a Microsoft Entra.'
          : 'The Governance > "RLS, tags & endorsement" tab needs permissions the rest of this project doesn\'t use. None of this can be granted by the app itself -- someone with access to the Fabric/Power BI Admin Portal and Microsoft Entra needs to check it.')}</h4>
        <ul class="admin-permissions-checklist">
          <li>
            <strong>${state.lang === 'es' ? 'Rol de Microsoft Entra' : 'Microsoft Entra role'}:</strong>
            ${state.lang === 'es'
              ? 'la cuenta que ejecuta el escaneo necesita el rol <em>"Power BI Administrator"</em> -- distinto de "Fabric Administrator" (ese ya lo usa el resto del proyecto y no basta aquí).'
              : 'the account running the scan needs the <em>"Power BI Administrator"</em> Entra role -- different from "Fabric Administrator" (already used by the rest of this project, and not enough here).'}
          </li>
          <li>
            <strong>Admin Portal:</strong>
            ${state.lang === 'es'
              ? 'Tenant settings → Admin API settings -- confirmar que no hay un grupo de seguridad restringiendo quién puede llamar a las Admin APIs.'
              : 'Tenant settings → Admin API settings -- confirm no security group is restricting who can call Admin APIs.'}
          </li>
          <li>
            <strong>${state.lang === 'es' ? 'Opcional (esquema detallado de modelos)' : 'Optional (detailed model schema)'}:</strong>
            ${state.lang === 'es'
              ? '"Enhance admin APIs responses with detailed metadata" y "...with DAX and mashup expressions" en la misma sección, solo si se quiere <code>-IncludeDatasetSchema</code>.'
              : '"Enhance admin APIs responses with detailed metadata" and "...with DAX and mashup expressions" in the same section, only needed for <code>-IncludeDatasetSchema</code>.'}
          </li>
          <li>
            <strong>Microsoft Graph:</strong>
            ${state.lang === 'es'
              ? 'permiso delegado <code>InformationProtectionPolicy.Read</code> (con consentimiento de administrador) para resolver el nombre de la etiqueta de sensibilidad -- sin esto, el escaneo funciona igual pero muestra el GUID en vez del nombre.'
              : 'delegated <code>InformationProtectionPolicy.Read</code> permission (with admin consent) to resolve the sensitivity label\'s name -- without this, the scan still works but shows the GUID instead of the name.'}
          </li>
        </ul>
        <p class="admin-field-hint">${state.lang === 'es'
          ? 'Una vez revisado, ejecuta <code>pwsh -File backend/scripts/73_discover_governance_scan.ps1</code> -- el diagnóstico en Gobernanza > "RLS, etiquetas y endorsement" confirma exactamente qué quedó desbloqueado.'
          : 'Once reviewed, run <code>pwsh -File backend/scripts/73_discover_governance_scan.ps1</code> -- the diagnosis under Governance > "RLS, tags & endorsement" confirms exactly what got unblocked.'}</p>
      </div>
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'lakehouse' ? ' active' : ''}" data-admin-tab-panel="lakehouse">
      <div class="admin-card">
        <h4 class="admin-card-title">${state.lang === 'es' ? 'Elemento de escritura' : 'Write-target item'}${adminInfoIconHtml(state.lang === 'es'
          ? 'Un Lakehouse de Fabric sólo deja LEER por SQL -- para escribir hace falta un Warehouse (o cualquier elemento de Fabric con SQL de lectura/escritura). Elige por nombre: el workspace ID y el ID del elemento se resuelven solos a partir de tu propio acceso a Fabric.'
          : "A Fabric Lakehouse's SQL endpoint is read-only -- writing needs a Warehouse (or any Fabric item with a read-write SQL endpoint). Pick by name: the workspace ID and item ID are resolved automatically from your own Fabric access.")}</h4>
        <div class="admin-field">
          <label>${state.lang === 'es' ? 'Tipo de elemento' : 'Item type'}</label>
          <select id="adminLhItemType">
            <option value="Warehouse" ${(lakehouse.item_type || 'Lakehouse') === 'Warehouse' ? 'selected' : ''}>Warehouse (${state.lang === 'es' ? 'lectura/escritura' : 'read/write'})</option>
            <option value="Lakehouse" ${(lakehouse.item_type || 'Lakehouse') === 'Lakehouse' ? 'selected' : ''}>Lakehouse (${state.lang === 'es' ? 'solo lectura por SQL' : 'SQL read-only'})</option>
          </select>
        </div>
        <div class="admin-field">
          <label>Workspace</label>
          <select id="adminLhWorkspaceSelect">
            <option value="">${state.lang === 'es' ? 'Cargando workspaces...' : 'Loading workspaces...'}</option>
          </select>
        </div>
        <div class="admin-field">
          <label id="adminLhItemLabel">${(lakehouse.item_type || 'Lakehouse') === 'Warehouse' ? 'Warehouse' : 'Lakehouse'}</label>
          <select id="adminLhLakehouseSelect" disabled>
            <option value="">${state.lang === 'es' ? 'Elige un workspace primero' : 'Choose a workspace first'}</option>
          </select>
        </div>
        <div class="admin-field"><label>${state.lang === 'es' ? 'Capacidad' : 'Capacity'}</label><input type="text" id="adminLhCapacity" value="${escapeHtml(lakehouse.capacity_name || '')}" /></div>
        <div class="admin-field"><label>SQL endpoint</label><input type="text" id="adminLhSqlEndpoint" value="${escapeHtml(lakehouse.sql_endpoint_connection_string || '')}" /></div>
      </div>
      <div class="admin-card">
        <h4 class="admin-card-title">${state.lang === 'es' ? 'Autenticación de la conexión' : 'Connection authentication'}${adminInfoIconHtml(state.lang === 'es'
          ? 'La cuenta de servicio es la que hace falta para que los escaneos automáticos escriban aquí siempre, sin que nadie tenga que estar conectado -- pensado para usar este almacén como base de datos permanente.'
          : "The service principal is what lets automated scans always write here, with nobody needing to be signed in -- meant for using this store as a permanent database.")}</h4>
        <div class="admin-field">
          <label>${state.lang === 'es' ? 'Método' : 'Method'}</label>
          <select id="adminLhAuthMode">
            <option value="service_principal" ${(lakehouse.auth_mode || 'user_session') === 'service_principal' ? 'selected' : ''}>${state.lang === 'es' ? 'Cuenta de servicio (permanente, recomendado)' : 'Service principal (permanent, recommended)'}</option>
            <option value="user_session" ${(lakehouse.auth_mode || 'user_session') === 'user_session' ? 'selected' : ''}>${state.lang === 'es' ? 'Sesión de quien pulsa el botón (deja de funcionar si nadie está conectado)' : "Whoever clicks the button's own session (stops working once nobody is signed in)"}</option>
          </select>
        </div>
        <div id="adminLhSpFields" ${(lakehouse.auth_mode || 'user_session') === 'service_principal' ? '' : 'hidden'}>
          <div class="admin-field"><label>${state.lang === 'es' ? 'Tenant ID (vacío = el de arriba)' : 'Tenant ID (blank = the one above)'}</label><input type="text" id="adminLhSpTenantId" value="${escapeHtml(lakehouse.sp_tenant_id || '')}" /></div>
          <div class="admin-field"><label>${state.lang === 'es' ? 'Client ID (App registration)' : 'Client ID (App registration)'}</label><input type="text" id="adminLhSpClientId" value="${escapeHtml(lakehouse.sp_client_id || '')}" /></div>
          <div class="admin-field">
            <label>${state.lang === 'es' ? 'Client secret (nombre de variable de entorno)' : 'Client secret (environment variable name)'}${adminInfoIconHtml(state.lang === 'es'
              ? 'El secreto real va en el .env del servidor con este nombre, nunca aquí -- igual que las contraseñas de orígenes externos.'
              : "The real secret lives in the server's .env under this name, never here -- same convention as external sources' passwords.")}</label>
            <input type="text" id="adminLhSpClientSecretRef" value="${escapeHtml(lakehouse.sp_client_secret_ref || '')}" placeholder="WAREHOUSE_SP_CLIENT_SECRET" />
          </div>
        </div>
        <button type="button" class="admin-save-button" data-admin-save="lakehouse">${state.lang === 'es' ? 'Guardar' : 'Save'}</button>
        <button type="button" class="admin-button-secondary" data-test-lakehouse="1">${state.lang === 'es' ? 'Probar conexión' : 'Test connection'}</button>
        <span class="admin-test-result" data-test-result="lakehouse"></span>
      </div>
      <div class="admin-card">
        <h4 class="admin-card-title">${state.lang === 'es' ? 'Subida manual' : 'Manual upload'}${adminInfoIconHtml(state.lang === 'es'
          ? 'Sube ahora, de una vez, todo lo que ya está escaneado en local (workspaces, items, dependencias, ejecuciones y demás) a las tablas Bronze del elemento de arriba.'
          : "Upload everything already scanned locally (workspaces, items, dependencies, executions, and more) to the item above's Bronze tables, right now, in one go.")}</h4>
        <p class="admin-field-hint">${renderLastWarehouseUploadLine()}</p>
        <button type="button" class="admin-button-secondary" data-warehouse-upload="1">${state.lang === 'es' ? 'Copiar datos ahora' : 'Copy data now'}</button>
        <span class="admin-test-result" data-test-result="warehouse-upload"></span>
        <div id="adminWarehouseUploadProgress" class="scan-progress-wrap" hidden>
          <div class="scan-progress-bar">
            <div id="adminWarehouseUploadFill" class="scan-progress-fill"></div>
            <span id="adminWarehouseUploadText" class="scan-progress-text"></span>
          </div>
          <span id="adminWarehouseUploadStep" class="scan-progress-step"></span>
        </div>
      </div>
    </div>
    ${renderAdminDiscoveryPipelineTab()}
    ${renderAdminOneLakeDataTab()}
    <div class="admin-tab-panel${adminActiveTab === 'users' ? ' active' : ''}" data-admin-tab-panel="users">
      ${renderAdminListFilterInput('users', state.lang === 'es' ? 'Filtrar por email, nombre o puesto...' : 'Filter by email, name, or job title...')}
      ${renderAdminUsersTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'sessions' ? ' active' : ''}" data-admin-tab-panel="sessions">
      ${renderAdminListFilterInput('sessions', state.lang === 'es' ? 'Filtrar por nombre o email...' : 'Filter by name or email...')}
      <div class="admin-card">
        <h4 class="admin-card-title">${state.lang === 'es' ? 'Sesiones activas' : 'Active sessions'}</h4>
        ${renderAdminSessionRows()}
      </div>
      <details class="admin-card admin-session-history-details">
        <summary class="admin-card-title admin-session-history-summary">${state.lang === 'es' ? 'Historial (sesiones terminadas)' : 'History (ended sessions)'}</summary>
        ${renderAdminSessionHistoryRows()}
      </details>
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'apikeys' ? ' active' : ''}" data-admin-tab-panel="apikeys">
      ${renderAdminApiKeysTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'sources' ? ' active' : ''}" data-admin-tab-panel="sources">
      ${renderDetectedExternalSourcesCard()}
      ${renderExternalSourceRows()}
      <button type="button" class="admin-save-button" data-add-source="1">${state.lang === 'es' ? '+ Añadir origen' : '+ Add source'}</button>
      <button type="button" class="admin-save-button" data-admin-save="sources">${state.lang === 'es' ? 'Guardar todo' : 'Save all'}</button>
      ${renderPendingExternalSourcesCard()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'notifications' ? ' active' : ''}" data-admin-tab-panel="notifications">
      ${renderNotificationsTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'capacity' ? ' active' : ''}" data-admin-tab-panel="capacity">
      ${renderAdminCapacityInsightTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'changes' ? ' active' : ''}" data-admin-tab-panel="changes">
      ${renderAdminChangesDigestTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'metrics' ? ' active' : ''}" data-admin-tab-panel="metrics">
      ${renderAdminMetricsTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'certifications' ? ' active' : ''}" data-admin-tab-panel="certifications">
      ${renderAdminCertificationsTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'glossary' ? ' active' : ''}" data-admin-tab-panel="glossary">
      ${renderAdminGlossaryTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'tags' ? ' active' : ''}" data-admin-tab-panel="tags">
      ${renderAdminTagsTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'dataquality' ? ' active' : ''}" data-admin-tab-panel="dataquality">
      ${renderAdminDataQualityTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'sensitivitycategories' ? ' active' : ''}" data-admin-tab-panel="sensitivitycategories">
      ${renderAdminSensitivityCategoriesTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'dataproducts' ? ' active' : ''}" data-admin-tab-panel="dataproducts">
      ${renderAdminDataProductsTab()}
    </div>
    <div class="admin-tab-panel${adminActiveTab === 'privacysystems' ? ' active' : ''}" data-admin-tab-panel="privacysystems">
      ${renderAdminPrivacySystemsTab()}
    </div>
      </div>
    </div>
  `;
  wireAdminPanelEvents();
}

function renderAdminDiscoveryPipelineTab() {
  const es = state.lang === 'es';
  const pipeline = adminSettingsCache.discovery_pipeline || {};
  return `
    <div class="admin-tab-panel${adminActiveTab === 'pipeline' ? ' active' : ''}" data-admin-tab-panel="pipeline">
      <div class="admin-card">
        <h4 class="admin-card-title">${es ? 'Cómo se escanea' : 'How scans run'}${adminInfoIconHtml(es
          ? 'Todo escaneo corre dentro de Fabric (un Data Pipeline existente, con sus propios notebooks) -- este servidor no necesita PowerShell/az-cli para nada. Requiere haber creado el pipeline en Fabric primero (ver docs/101_medallion_lakehouse_provisioning.md).'
          : "Every scan runs inside Fabric (an existing Data Pipeline, with its own notebooks) -- this server needs no PowerShell/az-cli at all. Requires the pipeline to already exist in Fabric (see docs/101_medallion_lakehouse_provisioning.md).")}</h4>
        <div class="admin-field">
          <label>${es ? 'Modo' : 'Mode'}</label>
          <div class="admin-field-static-value">Fabric / Pipeline</div>
        </div>
        <div id="adminPipelineFields">
          <div class="admin-field">
            <label>Workspace</label>
            <select id="adminPipelineWorkspaceSelect">
              <option value="">${es ? 'Cargando workspaces...' : 'Loading workspaces...'}</option>
            </select>
          </div>
          <div class="admin-field">
            <label>${es ? 'Data Pipeline' : 'Data Pipeline'}${adminInfoIconHtml(es
              ? 'Se elige por nombre, igual que en Almacén de escritura -- ya no hace falta copiar IDs de la URL de Fabric a mano.'
              : "Picked by name, same as Write storage -- no more copying ids out of Fabric's URL by hand.")}</label>
            <select id="adminPipelineItemSelect" disabled>
              <option value="">${es ? 'Elige un workspace primero' : 'Choose a workspace first'}</option>
            </select>
          </div>
        </div>
      </div>
      <div id="adminPipelineSpCard" class="admin-card">
        <h4 class="admin-card-title">${es ? 'Cuenta de servicio (opcional)' : 'Service principal (optional)'}${adminInfoIconHtml(es
          ? 'Opcional desde 2026-07-24: con solo el workspace y el ID del pipeline rellenos, un escaneo lanzado por alguien con sesión iniciada usa su propio inicio de sesión (el mismo mecanismo de "Iniciar sesión con Microsoft") -- no hace falta registrar ninguna app en Entra. Solo rellena esto si además quieres poder disparar el pipeline sin que nadie tenga sesión iniciada.'
          : 'Optional (2026-07-24): with just the workspace and pipeline id filled in, a scan started by a signed-in user uses their own sign-in (the same "Sign in with Microsoft" mechanism) -- no Entra app registration needed. Only fill this in if you also want to be able to trigger the pipeline with nobody signed in at all.')}</h4>
        <div class="admin-field"><label>${es ? 'Tenant ID (vacío = el de arriba)' : 'Tenant ID (blank = the one above)'}</label><input type="text" id="adminPipelineSpTenantId" value="${escapeHtml(pipeline.sp_tenant_id || '')}" /></div>
        <div class="admin-field"><label>${es ? 'Client ID (App registration)' : 'Client ID (App registration)'}</label><input type="text" id="adminPipelineSpClientId" value="${escapeHtml(pipeline.sp_client_id || '')}" /></div>
        <div class="admin-field">
          <label>${es ? 'Client secret (nombre de variable de entorno)' : 'Client secret (environment variable name)'}${adminInfoIconHtml(es
            ? 'El secreto real va en el .env del servidor con este nombre, nunca aquí. Puede ser la misma cuenta de servicio que el Almacén de escritura, o una distinta.'
            : "The real secret lives in the server's .env under this name, never here. Can be the same service principal as Write storage, or a different one.")}</label>
          <input type="text" id="adminPipelineSpClientSecretRef" value="${escapeHtml(pipeline.sp_client_secret_ref || '')}" placeholder="DISCOVERY_PIPELINE_SP_CLIENT_SECRET" />
        </div>
      </div>
      <button type="button" class="admin-save-button" data-admin-save="discovery-pipeline">${es ? 'Guardar' : 'Save'}</button>
      <button type="button" class="admin-button-secondary" data-test-discovery-pipeline="1">${es ? 'Probar conexión' : 'Test connection'}</button>
      <span class="admin-test-result" data-test-result="discovery-pipeline"></span>
      <div class="admin-card">
        <h4 class="admin-card-title">${es ? 'Dar de alta un workspace nuevo' : 'Register a new workspace'}${adminInfoIconHtml(es
          ? 'Crea un workspace (y opcionalmente lo asigna a una capacidad) para usarlo aquí arriba -- no hace falta salir al portal de Fabric.'
          : "Creates a workspace (and optionally assigns it to a capacity) to use above -- no need to leave for the Fabric portal.")}</h4>
        <button type="button" class="admin-button-secondary" data-open-workspace-create="pipeline">${es ? '+ Nuevo workspace' : '+ New workspace'}</button>
      </div>
      <div class="admin-card">
        <h4 class="admin-card-title">${es ? 'Instalar en otro tenant / workspace' : 'Install into another tenant / workspace'}${adminInfoIconHtml(es
          ? 'Asistente paso a paso: crea el workspace, el almacén de escritura y despliega todos los notebooks de este proyecto en OTRO tenant (con su propia cuenta de servicio, obligatoria) para usar la herramienta de forma independiente ahí.'
          : "Step-by-step wizard: creates the workspace, the write-storage item, and deploys every one of this project's notebooks into ANOTHER tenant (with its own, mandatory service principal) to run this tool independently there.")}</h4>
        <button type="button" class="admin-button-secondary" data-open-installer-wizard="1">${es ? 'Instalar en otro tenant...' : 'Install into another tenant...'}</button>
      </div>
    </div>
  `;
}

function renderAdminOneLakeDataTab() {
  const es = state.lang === 'es';
  const onelake = adminSettingsCache.onelake_data || {};
  return `
    <div class="admin-tab-panel${adminActiveTab === 'onelake' ? ' active' : ''}" data-admin-tab-panel="onelake">
      <div class="admin-card">
        <h4 class="admin-card-title">${es ? 'Ubicación de los datos' : 'Data location'}${adminInfoIconHtml(es
          ? 'Los JSON grandes del explorador (linaje, impacto por objeto, código de notebook, mapa de grafo) siempre se sirven en vivo desde el área Files de un Lakehouse de Fabric -- requiere un Lakehouse real (no un Warehouse, que no tiene área de Files). Ver docs/105_fabric_native_discovery_setup.md.'
          : "The explorer's big JSON files (lineage, object impact, notebook code, graph map) are always served live from a Fabric Lakehouse's Files area -- requires a real Lakehouse (not a Warehouse, which has no Files area). See docs/105_fabric_native_discovery_setup.md.")}</h4>
        <div class="admin-field">
          <label>Workspace</label>
          <input type="text" id="adminOneLakeWorkspaceName" value="${escapeHtml(onelake.workspace_name || '')}" placeholder="${es ? 'nombre real del workspace (obligatorio)' : 'real workspace name (required)'}" required />
        </div>
        <div class="admin-field">
          <label>Lakehouse${adminInfoIconHtml(es
            ? 'Tiene que ser un Lakehouse de verdad -- si tu almacén de escritura habitual es un Warehouse, este tiene que ser un elemento distinto (aunque puede vivir en el mismo workspace).'
            : "Has to be a real Lakehouse -- if your usual write storage is a Warehouse, this needs to be a different item (though it can live in the same workspace).")}</label>
          <input type="text" id="adminOneLakeLakehouseName" value="${escapeHtml(onelake.lakehouse_name || '')}" placeholder="${es ? 'nombre real del Lakehouse (obligatorio)' : 'real Lakehouse name (required)'}" required />
        </div>
      </div>
      <div id="adminOneLakeSpCard" class="admin-card">
        <h4 class="admin-card-title">${es ? 'Autenticación' : 'Authentication'}</h4>
        <div class="admin-field"><label>${es ? 'Tenant ID (vacío = el de arriba)' : 'Tenant ID (blank = the one above)'}</label><input type="text" id="adminOneLakeSpTenantId" value="${escapeHtml(onelake.sp_tenant_id || '')}" /></div>
        <div class="admin-field"><label>${es ? 'Client ID (App registration)' : 'Client ID (App registration)'}</label><input type="text" id="adminOneLakeSpClientId" value="${escapeHtml(onelake.sp_client_id || '')}" /></div>
        <div class="admin-field">
          <label>${es ? 'Client secret (nombre de variable de entorno)' : 'Client secret (environment variable name)'}${adminInfoIconHtml(es
            ? 'El secreto real va en el .env del servidor con este nombre, nunca aquí. Solo necesita permiso de LECTURA sobre este Lakehouse -- quien publica los datos (script 72) usa su propia sesión, no esta cuenta.'
            : "The real secret lives in the server's .env under this name, never here. Only needs READ access to this Lakehouse -- whoever publishes the data (script 72) uses their own session, not this account.")}</label>
          <input type="text" id="adminOneLakeSpClientSecretRef" value="${escapeHtml(onelake.sp_client_secret_ref || '')}" placeholder="ONELAKE_DATA_SP_CLIENT_SECRET" />
        </div>
      </div>
      <button type="button" class="admin-save-button" data-admin-save="onelake-data">${es ? 'Guardar' : 'Save'}</button>
      <button type="button" class="admin-button-secondary" data-test-onelake="1">${es ? 'Probar conexión' : 'Test connection'}</button>
      <span class="admin-test-result" data-test-result="onelake"></span>
      <div class="admin-card">
        <h4 class="admin-card-title">${es ? 'Dar de alta un workspace nuevo' : 'Register a new workspace'}${adminInfoIconHtml(es
          ? 'Crea un workspace y un Lakehouse para usarlos aquí arriba -- no hace falta salir al portal de Fabric.'
          : "Creates a workspace and a Lakehouse to use above -- no need to leave for the Fabric portal.")}</h4>
        <button type="button" class="admin-button-secondary" data-open-workspace-create="onelake">${es ? '+ Nuevo workspace / Lakehouse' : '+ New workspace / Lakehouse'}</button>
      </div>
      <div class="admin-card">
        <h4 class="admin-card-title">${es ? 'Publicación manual' : 'Manual publish'}${adminInfoIconHtml(es
          ? 'Publica ahora, de una vez, los 5 JSON ya construidos localmente al Lakehouse de arriba (usa lo que ya esté guardado, no el formulario sin guardar).'
          : "Publish the 5 already-locally-built JSON files to the Lakehouse above, right now, in one go (uses what's already saved, not the unsaved form).")}</h4>
        <button type="button" class="admin-button-secondary" data-onelake-publish="1">${es ? 'Publicar datos ahora' : 'Publish data now'}</button>
        <span class="admin-test-result" data-test-result="onelake-publish"></span>
        <div id="adminOneLakePublishProgress" class="scan-progress-wrap" hidden>
          <div class="scan-progress-bar">
            <div id="adminOneLakePublishFill" class="scan-progress-fill"></div>
            <span id="adminOneLakePublishText" class="scan-progress-text"></span>
          </div>
          <span id="adminOneLakePublishStep" class="scan-progress-step"></span>
        </div>
      </div>
    </div>
  `;
}

// "Dar de alta un workspace" popup (Fase 5, 2026-08-24) -- a lighter-
// weight sibling of the full installer wizard below: creates a workspace
// (and optionally one Lakehouse/Warehouse inside it) via the SAME `fab`
// CLI mechanism, reusing the shared /api/admin/installer/status poll loop
// since the backend runs both through the same one-at-a-time
// _installer_state. context is 'pipeline' or 'onelake' -- only changes
// which tab's fields get pre-filled/updated on success, not the API call
// itself.
let workspaceCreateState = null; // { context, phase: 'form'|'running'|'done', workspaceName, itemName }

function toggleWorkspaceCreateModal(forceOpen, context) {
  if (!els.workspaceCreateModal) return;
  const shouldOpen = typeof forceOpen === 'boolean' ? forceOpen : els.workspaceCreateModal.hidden;
  if (shouldOpen) {
    workspaceCreateState = { context, phase: 'form' };
    renderWorkspaceCreateModal();
    pushStackedModal(els.workspaceCreateModal);
  } else {
    if (stackedModals[stackedModals.length - 1] === els.workspaceCreateModal) popStackedModal();
    else els.workspaceCreateModal.hidden = true;
    workspaceCreateState = null;
  }
}

function renderWorkspaceCreateModal() {
  if (!els.workspaceCreateModal || !workspaceCreateState) return;
  const es = state.lang === 'es';
  const { context, phase } = workspaceCreateState;
  const isOneLake = context === 'onelake';
  const sectionSettings = (isOneLake ? adminSettingsCache.onelake_data : adminSettingsCache.discovery_pipeline) || {};

  if (phase === 'form') {
    els.workspaceCreateBody.innerHTML = `
      <div class="admin-field"><label>Tenant ID</label><input type="text" id="wsCreateTenantId" value="${escapeHtml(sectionSettings.sp_tenant_id || adminSettingsCache.tenant_id || '')}" /></div>
      <div class="admin-field"><label>Client ID (App registration)</label><input type="text" id="wsCreateClientId" value="${escapeHtml(sectionSettings.sp_client_id || '')}" /></div>
      <div class="admin-field"><label>${es ? 'Client secret' : 'Client secret'}${adminInfoIconHtml(es
        ? 'Solo se usa una vez, para crear el workspace -- nunca se guarda.'
        : "Used once, just to create the workspace -- never saved.")}</label><input type="password" id="wsCreateClientSecret" autocomplete="off" /></div>
      <div class="admin-field"><label>${es ? 'Nombre del workspace' : 'Workspace name'}</label><input type="text" id="wsCreateWorkspaceName" placeholder="${es ? 'obligatorio' : 'required'}" required /></div>
      <div class="admin-field"><label>${es ? 'Capacidad (opcional)' : 'Capacity (optional)'}</label><input type="text" id="wsCreateCapacityName" /></div>
      ${isOneLake ? `
      <div class="admin-field"><label>${es ? 'Nombre del Lakehouse' : 'Lakehouse name'}</label><input type="text" id="wsCreateItemName" placeholder="${es ? 'obligatorio' : 'required'}" required /></div>
      ` : `
      <div class="admin-field admin-field-checkbox">
        <label><input type="checkbox" id="wsCreateWantsItem" /> ${es ? 'Crear también un Lakehouse/Warehouse en este workspace' : 'Also create a Lakehouse/Warehouse in this workspace'}</label>
      </div>
      <div id="wsCreateItemFields" hidden>
        <div class="admin-field"><label>${es ? 'Tipo' : 'Type'}</label>
          <select id="wsCreateItemType"><option value="Lakehouse">Lakehouse</option><option value="Warehouse">Warehouse</option></select>
        </div>
        <div class="admin-field"><label>${es ? 'Nombre' : 'Name'}</label><input type="text" id="wsCreateItemName" /></div>
      </div>
      `}
      <button type="button" class="admin-save-button" data-workspace-create-submit="1">${es ? 'Crear' : 'Create'}</button>
    `;
    const wantsItemCheckbox = document.getElementById('wsCreateWantsItem');
    if (wantsItemCheckbox) {
      wantsItemCheckbox.addEventListener('change', () => {
        document.getElementById('wsCreateItemFields').hidden = !wantsItemCheckbox.checked;
      });
    }
  } else {
    const log = (installerStatusCache && installerStatusCache.log) || [];
    els.workspaceCreateBody.innerHTML = `
      <p class="admin-field-hint">${phase === 'running' ? (es ? 'Creando...' : 'Creating...') : (es ? 'Terminado.' : 'Finished.')}</p>
      <div class="admin-list">${log.map(entry => `
        <div class="admin-list-row">
          <span>${entry.ok ? '✓' : '✗'} ${escapeHtml(entry.step)}</span>
          <span>${escapeHtml(entry.message)}</span>
        </div>`).join('')}</div>
      ${phase === 'done' && installerStatusCache && installerStatusCache.status === 'succeeded' ? `
        <button type="button" class="admin-save-button" data-workspace-create-apply="1">${es ? 'Usar este workspace en el formulario' : 'Use this workspace in the form'}</button>
      ` : ''}
    `;
  }
}

async function submitWorkspaceCreate() {
  const context = workspaceCreateState.context;
  const isOneLake = context === 'onelake';
  const workspaceName = document.getElementById('wsCreateWorkspaceName').value.trim();
  if (!workspaceName) return;
  const itemName = isOneLake
    ? document.getElementById('wsCreateItemName').value.trim()
    : (document.getElementById('wsCreateWantsItem').checked ? document.getElementById('wsCreateItemName').value.trim() : '');
  const itemType = isOneLake ? 'Lakehouse' : (document.getElementById('wsCreateItemType') ? document.getElementById('wsCreateItemType').value : 'Lakehouse');
  const payload = {
    tenant_id: document.getElementById('wsCreateTenantId').value.trim(),
    client_id: document.getElementById('wsCreateClientId').value.trim(),
    client_secret: document.getElementById('wsCreateClientSecret').value,
    workspace_name: workspaceName,
    capacity_name: document.getElementById('wsCreateCapacityName').value.trim(),
    item_type: itemType,
    item_name: itemName,
  };
  workspaceCreateState.phase = 'running';
  workspaceCreateState.workspaceName = workspaceName;
  workspaceCreateState.itemName = itemName;
  renderWorkspaceCreateModal();
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/create-workspace`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
    });
    if (!response.ok) {
      const errPayload = await response.json().catch(() => ({}));
      installerStatusCache = { status: 'failed', log: [{ step: 'error', message: errPayload.message || `HTTP ${response.status}`, ok: false }] };
      workspaceCreateState.phase = 'done';
      renderWorkspaceCreateModal();
      return;
    }
    pollWorkspaceCreateStatus();
  } catch (error) {
    installerStatusCache = { status: 'failed', log: [{ step: 'error', message: state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.', ok: false }] };
    workspaceCreateState.phase = 'done';
    renderWorkspaceCreateModal();
  }
}

async function pollWorkspaceCreateStatus() {
  if (!workspaceCreateState || workspaceCreateState.phase !== 'running') return;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/installer/status`);
    installerStatusCache = await response.json();
  } catch (error) {
    installerStatusCache = { status: 'failed', log: [{ step: 'error', message: 'No se pudo conectar con el servidor.', ok: false }] };
  }
  if (!workspaceCreateState || workspaceCreateState.phase !== 'running') return;
  if (installerStatusCache.status === 'running') {
    renderWorkspaceCreateModal();
    setTimeout(pollWorkspaceCreateStatus, 1500);
  } else {
    workspaceCreateState.phase = 'done';
    renderWorkspaceCreateModal();
  }
}

function applyWorkspaceCreateResult() {
  const { context, workspaceName, itemName } = workspaceCreateState;
  if (context === 'pipeline') {
    const select = document.getElementById('adminPipelineWorkspaceSelect');
    if (select) {
      const option = document.createElement('option');
      option.value = workspaceName;
      option.textContent = workspaceName;
      option.selected = true;
      select.appendChild(option);
    }
  } else {
    adminSettingsCache.onelake_data = adminSettingsCache.onelake_data || {};
    adminSettingsCache.onelake_data.workspace_name = workspaceName;
    if (itemName) adminSettingsCache.onelake_data.lakehouse_name = itemName;
    renderAdminPanel();
  }
  toggleWorkspaceCreateModal(false);
}

let installerStatusCache = null;

// Full multi-tenant installer wizard (Fase 5, 2026-08-24) -- provisions a
// workspace + write-storage item + every fabric_notebooks/NB_*.py into
// ANOTHER tenant, via the same /api/admin/installer/* endpoints (backend:
// installer.py, over the `fab` CLI with an isolated auth session, see its
// own module docstring for why). Does NOT create the Data Pipeline --
// this project treats that as a manual step even for its own tenant (see
// docs/105_fabric_native_discovery_setup.md); the final step shows the
// exact manual activity order instead of guessing a pipeline-content.json
// nobody here can test.
const INSTALLER_WIZARD_STEPS = ['tenant', 'workspace', 'storage', 'onelake', 'notebooks', 'review', 'install'];
let installerWizardStepIndex = 0;
let installerWizardConfig = {
  tenantId: '', clientId: '', clientSecret: '',
  workspaceName: '', capacityName: '',
  itemType: 'Warehouse', warehouseName: '', lakehouseName: '',
  notebookNames: [], variableOverrides: {},
};
let installerNotebooksCache = null; // { notebooks: [{name, is_core}], variables: {...}, manual_pipeline_step, pipeline_order }

function toggleInstallerWizardModal(forceOpen) {
  if (!els.installerWizardModal) return;
  const shouldOpen = typeof forceOpen === 'boolean' ? forceOpen : els.installerWizardModal.hidden;
  if (shouldOpen) {
    installerWizardStepIndex = 0;
    installerWizardConfig = {
      tenantId: '', clientId: '', clientSecret: '',
      workspaceName: '', capacityName: '',
      itemType: 'Warehouse', warehouseName: '', lakehouseName: '',
      notebookNames: [], variableOverrides: {},
    };
    installerNotebooksCache = null;
    renderInstallerWizardModal();
    pushStackedModal(els.installerWizardModal);
    loadInstallerNotebooks();
  } else {
    if (stackedModals[stackedModals.length - 1] === els.installerWizardModal) popStackedModal();
    else els.installerWizardModal.hidden = true;
  }
}

async function loadInstallerNotebooks() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/installer/notebooks`);
    installerNotebooksCache = await response.json();
    installerWizardConfig.notebookNames = installerNotebooksCache.notebooks.filter(n => n.is_core).map(n => n.name);
  } catch (error) {
    installerNotebooksCache = { notebooks: [], variables: {}, manual_pipeline_step: {}, pipeline_order: [] };
  }
  if (!els.installerWizardModal.hidden) renderInstallerWizardModal();
}

function installerWizardStepValid(stepKey) {
  const c = installerWizardConfig;
  if (stepKey === 'tenant') return Boolean(c.tenantId.trim() && c.clientId.trim() && c.clientSecret.trim());
  if (stepKey === 'workspace') return Boolean(c.workspaceName.trim());
  if (stepKey === 'storage') return Boolean((c.itemType === 'Warehouse' ? c.warehouseName : c.lakehouseName || c.warehouseName).trim());
  return true;
}

function installerWizardNext() {
  const stepKey = INSTALLER_WIZARD_STEPS[installerWizardStepIndex];
  if (!installerWizardStepValid(stepKey)) {
    window.alert(state.lang === 'es'
      ? 'Rellena los campos obligatorios de este paso antes de continuar.'
      : 'Fill in this step\'s required fields before continuing.');
    return;
  }
  if (installerWizardStepIndex < INSTALLER_WIZARD_STEPS.length - 1) installerWizardStepIndex += 1;
  renderInstallerWizardModal();
}

function installerWizardBack() {
  if (installerWizardStepIndex > 0) installerWizardStepIndex -= 1;
  renderInstallerWizardModal();
}

function renderInstallerWizardModal() {
  if (!els.installerWizardModal) return;
  const es = state.lang === 'es';
  const stepKey = INSTALLER_WIZARD_STEPS[installerWizardStepIndex];
  const stepLabels = {
    tenant: es ? 'Tenant y cuenta de servicio' : 'Tenant & service principal',
    workspace: 'Workspace',
    storage: es ? 'Almacén de escritura' : 'Write storage',
    onelake: es ? 'Datos del explorador (OneLake)' : 'Explorer data (OneLake)',
    notebooks: es ? 'Notebooks y variables' : 'Notebooks & variables',
    review: es ? 'Revisión' : 'Review',
    install: es ? 'Instalar' : 'Install',
  };
  const nav = `<div class="installer-wizard-steps">${INSTALLER_WIZARD_STEPS.map((key, index) => `
    <span class="installer-wizard-step${index === installerWizardStepIndex ? ' active' : ''}${index < installerWizardStepIndex ? ' done' : ''}">${index + 1}. ${stepLabels[key]}</span>
  `).join('')}</div>`;

  let content = '';
  if (stepKey === 'tenant') content = renderInstallerStepTenant();
  else if (stepKey === 'workspace') content = renderInstallerStepWorkspace();
  else if (stepKey === 'storage') content = renderInstallerStepStorage();
  else if (stepKey === 'onelake') content = renderInstallerStepOneLake();
  else if (stepKey === 'notebooks') content = renderInstallerStepNotebooks();
  else if (stepKey === 'review') content = renderInstallerStepReview();
  else if (stepKey === 'install') content = renderInstallerStepInstall();

  const isInstallStep = stepKey === 'install';
  const nextLabel = stepKey === 'review' ? (es ? 'Ir a instalar' : 'Go to install') : (es ? 'Siguiente' : 'Next');
  const navButtons = isInstallStep ? '' : `
    <div class="installer-wizard-nav">
      ${installerWizardStepIndex > 0 ? `<button type="button" class="admin-button-secondary" data-installer-back="1">${es ? 'Atrás' : 'Back'}</button>` : ''}
      <button type="button" class="admin-save-button" data-installer-next="1">${nextLabel}</button>
    </div>`;

  els.installerWizardBody.innerHTML = `${nav}<div class="installer-wizard-step-body">${content}</div>${navButtons}`;
}

function renderInstallerStepTenant() {
  const es = state.lang === 'es';
  const c = installerWizardConfig;
  return `
    <p class="admin-field-hint">${es
      ? 'Obligatorio: sin una cuenta de servicio del tenant destino, este asistente no puede crear nada ahí. Se usa una sola vez, para esta instalación -- nunca se guarda en el servidor.'
      : "Mandatory: without a service principal for the target tenant, this wizard can't create anything there. Used once, for this install only -- never saved on the server."}</p>
    <div class="admin-field"><label>Tenant ID</label><input type="text" data-installer-field="tenantId" value="${escapeHtml(c.tenantId)}" required /></div>
    <div class="admin-field"><label>Client ID (App registration)</label><input type="text" data-installer-field="clientId" value="${escapeHtml(c.clientId)}" required /></div>
    <div class="admin-field"><label>Client secret</label><input type="password" data-installer-field="clientSecret" value="${escapeHtml(c.clientSecret)}" autocomplete="off" required /></div>
  `;
}

function renderInstallerStepWorkspace() {
  const es = state.lang === 'es';
  const c = installerWizardConfig;
  return `
    <div class="admin-field"><label>${es ? 'Nombre del workspace nuevo' : 'New workspace name'}</label><input type="text" data-installer-field="workspaceName" value="${escapeHtml(c.workspaceName)}" required /></div>
    <div class="admin-field"><label>${es ? 'Capacidad (opcional, debe soportar Spark/DirectLake)' : 'Capacity (optional, needs Spark/DirectLake support)'}</label><input type="text" data-installer-field="capacityName" value="${escapeHtml(c.capacityName)}" /></div>
  `;
}

function renderInstallerStepStorage() {
  const es = state.lang === 'es';
  const c = installerWizardConfig;
  return `
    <div class="admin-field"><label>${es ? 'Tipo' : 'Type'}</label>
      <select data-installer-field="itemType">
        <option value="Warehouse" ${c.itemType === 'Warehouse' ? 'selected' : ''}>Warehouse</option>
        <option value="Lakehouse" ${c.itemType === 'Lakehouse' ? 'selected' : ''}>Lakehouse</option>
      </select>
    </div>
    ${c.itemType === 'Warehouse' ? `
    <div class="admin-field"><label>${es ? 'Nombre del Warehouse' : 'Warehouse name'}</label><input type="text" data-installer-field="warehouseName" value="${escapeHtml(c.warehouseName)}" required /></div>
    ` : `
    <div class="admin-field"><label>${es ? 'Nombre del Lakehouse (almacén de escritura)' : 'Lakehouse name (write storage)'}</label><input type="text" data-installer-field="lakehouseName" value="${escapeHtml(c.lakehouseName)}" required /></div>
    `}
  `;
}

function renderInstallerStepOneLake() {
  const es = state.lang === 'es';
  const c = installerWizardConfig;
  const needsSeparateLakehouse = c.itemType === 'Warehouse';
  return `
    <p class="admin-field-hint">${es
      ? 'Los JSON del explorador (linaje, mapa de grafo...) siempre se sirven desde el área Files de un Lakehouse real.'
      : "The explorer's JSON files (lineage, graph map...) are always served from a real Lakehouse's Files area."}</p>
    ${needsSeparateLakehouse ? `
    <div class="admin-field"><label>${es ? 'Nombre del Lakehouse de OneLake' : 'OneLake Lakehouse name'}</label><input type="text" data-installer-field="lakehouseName" value="${escapeHtml(c.lakehouseName)}" required /></div>
    ` : `<p class="admin-field-hint">${es ? `Se reutiliza el Lakehouse del paso anterior ('${escapeHtml(c.lakehouseName)}').` : `Reusing the Lakehouse from the previous step ('${escapeHtml(c.lakehouseName)}').`}</p>`}
  `;
}

function renderInstallerStepNotebooks() {
  const es = state.lang === 'es';
  const c = installerWizardConfig;
  if (!installerNotebooksCache) return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  const defaultOverrides = {
    SP_TENANT_ID: c.tenantId, SP_CLIENT_ID: c.clientId,
    ONELAKE_WORKSPACE_NAME: c.workspaceName, ONELAKE_LAKEHOUSE_NAME: c.lakehouseName || c.warehouseName,
    WAREHOUSE_SQL_ENDPOINT: c.variableOverrides.WAREHOUSE_SQL_ENDPOINT || '', WAREHOUSE_DATABASE_NAME: c.warehouseName,
  };
  const variables = installerNotebooksCache.variables || {};
  const variableRows = Object.keys(variables).map(name => {
    const value = c.variableOverrides[name] !== undefined ? c.variableOverrides[name] : (defaultOverrides[name] || '');
    if (c.variableOverrides[name] === undefined) c.variableOverrides[name] = value;
    return `<div class="admin-field"><label>${escapeHtml(name)}${adminInfoIconHtml(es
      ? `Aparece en ${variables[name].notebook_count} notebook(s). Ejemplo actual: ${escapeHtml(variables[name].example_value)}`
      : `Appears in ${variables[name].notebook_count} notebook(s). Current example: ${escapeHtml(variables[name].example_value)}`)}</label>
      <input type="text" data-installer-variable="${escapeHtml(name)}" value="${escapeHtml(value)}" /></div>`;
  }).join('');
  const notebookRows = (installerNotebooksCache.notebooks || []).map(nb => `
    <label class="admin-field-checkbox admin-installer-notebook-row">
      <input type="checkbox" data-installer-toggle-notebook="${escapeHtml(nb.name)}" ${c.notebookNames.includes(nb.name) ? 'checked' : ''} />
      ${escapeHtml(nb.name)} ${nb.is_core ? '' : `<span class="admin-session-row-email">(${es ? 'opcional' : 'optional'})</span>`}
    </label>`).join('');
  return `
    <h4 class="admin-card-title">${es ? 'Variables por tenant' : 'Per-tenant variables'}</h4>
    ${variableRows}
    <h4 class="admin-card-title">${es ? 'Notebooks a desplegar' : 'Notebooks to deploy'} (${c.notebookNames.length}/${(installerNotebooksCache.notebooks || []).length})</h4>
    <div class="admin-installer-notebook-list">${notebookRows}</div>
  `;
}

function renderInstallerStepReview() {
  const es = state.lang === 'es';
  const c = installerWizardConfig;
  return `
    <div class="admin-list">
      <div class="admin-list-row"><span>Tenant</span><span>${escapeHtml(c.tenantId)}</span></div>
      <div class="admin-list-row"><span>Workspace</span><span>${escapeHtml(c.workspaceName)}${c.capacityName ? ` (${escapeHtml(c.capacityName)})` : ''}</span></div>
      <div class="admin-list-row"><span>${es ? 'Almacén de escritura' : 'Write storage'}</span><span>${escapeHtml(c.itemType)} '${escapeHtml(c.itemType === 'Warehouse' ? c.warehouseName : c.lakehouseName)}'</span></div>
      <div class="admin-list-row"><span>OneLake</span><span>${escapeHtml(c.lakehouseName || c.warehouseName)}</span></div>
      <div class="admin-list-row"><span>${es ? 'Notebooks' : 'Notebooks'}</span><span>${c.notebookNames.length}</span></div>
    </div>
    <p class="admin-field-hint">${es
      ? 'Al instalar, este asistente NO crea el Data Pipeline (paso manual, ver instrucciones al terminar).'
      : 'Installing does NOT create the Data Pipeline (manual step, instructions shown once it finishes).'}</p>
  `;
}

function renderInstallerStepInstall() {
  const es = state.lang === 'es';
  const status = installerStatusCache;
  if (!status || status.status === 'idle') {
    return `<button type="button" class="admin-save-button" data-installer-start="1">${es ? 'Instalar' : 'Install'}</button>`;
  }
  const total = installerWizardConfig.notebookNames.length + 3; // auth + workspace + storage, roughly, plus one entry per notebook
  const doneCount = (status.log || []).length;
  const percent = Math.min(100, Math.round((doneCount / Math.max(total, 1)) * 100));
  const finished = status.status !== 'running';
  const manual = (installerNotebooksCache && installerNotebooksCache.manual_pipeline_step) || {};
  const order = (installerNotebooksCache && installerNotebooksCache.pipeline_order) || [];
  return `
    <div class="scan-progress-wrap">
      <div class="scan-progress-bar"><div class="scan-progress-fill" style="width:${percent}%"></div><span class="scan-progress-text">${percent}%</span></div>
      <span class="scan-progress-step">${escapeHtml(status.message || '')}</span>
    </div>
    <div class="admin-list">${(status.log || []).map(entry => `
      <div class="admin-list-row"><span>${entry.ok ? '✓' : '✗'} ${escapeHtml(entry.step)}</span><span>${escapeHtml(entry.message)}</span></div>`).join('')}</div>
    ${finished && status.status === 'succeeded' ? `
      <div class="admin-card">
        <h4 class="admin-card-title">${es ? 'Siguiente paso manual: el Data Pipeline' : 'Next manual step: the Data Pipeline'}</h4>
        <p class="admin-field-hint">${escapeHtml((manual.es && es ? manual.es : manual.en) || '')}</p>
        <ol>${order.map(name => `<li>${escapeHtml(name)}</li>`).join('')}</ol>
      </div>
    ` : ''}
    ${finished && status.status === 'failed' ? `<p class="admin-test-result fail">${es ? 'La instalación falló -- revisa el detalle arriba.' : 'The install failed -- see the detail above.'}</p>` : ''}
  `;
}

async function submitInstallerWizard() {
  const c = installerWizardConfig;
  const payload = {
    tenant_id: c.tenantId, client_id: c.clientId, client_secret: c.clientSecret,
    workspace_name: c.workspaceName, capacity_name: c.capacityName,
    item_type: c.itemType, warehouse_name: c.warehouseName, lakehouse_name: c.lakehouseName || c.warehouseName,
    variable_overrides: c.variableOverrides, notebook_names: c.notebookNames,
  };
  installerStatusCache = { status: 'running', log: [], message: '' };
  renderInstallerWizardModal();
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/installer/start`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
    });
    if (!response.ok) {
      const errPayload = await response.json().catch(() => ({}));
      installerStatusCache = { status: 'failed', log: [{ step: 'error', message: errPayload.message || `HTTP ${response.status}`, ok: false }] };
      renderInstallerWizardModal();
      return;
    }
    pollInstallerWizardStatus();
  } catch (error) {
    installerStatusCache = { status: 'failed', log: [{ step: 'error', message: state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.', ok: false }] };
    renderInstallerWizardModal();
  }
}

async function pollInstallerWizardStatus() {
  if (!els.installerWizardModal || els.installerWizardModal.hidden) return;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/installer/status`);
    installerStatusCache = await response.json();
  } catch (error) {
    installerStatusCache = { status: 'failed', log: [{ step: 'error', message: 'No se pudo conectar con el servidor.', ok: false }] };
  }
  if (els.installerWizardModal.hidden) return;
  renderInstallerWizardModal();
  if (installerStatusCache.status === 'running') setTimeout(pollInstallerWizardStatus, 1500);
}

function currentAdminSubscriber() {
  const notif = adminSettingsCache.notifications || {};
  const email = (authState.userEmail || '').trim().toLowerCase();
  return (notif.subscribers || []).find(s => (s.email || '').trim().toLowerCase() === email) || null;
}

function renderNotificationsTab() {
  const es = state.lang === 'es';
  const notif = adminSettingsCache.notifications || {};
  const mine = currentAdminSubscriber() || { language: state.lang, notify_succeeded: false, notify_failed: false, notify_cancelled: false };
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Servidor de correo (SMTP)' : 'Mail server (SMTP)'}${adminInfoIconHtml(es
        ? 'Compartido para toda la herramienta. Cada admin decide por separado, en la tarjeta de abajo, si quiere recibir avisos.'
        : 'Shared across the whole tool. Each admin decides separately, in the card below, whether they want to receive notifications.')}</h4>
      <div class="admin-field"><label>Host</label><input type="text" id="adminSmtpHost" value="${escapeHtml(notif.smtp_host || '')}" placeholder="smtp.office365.com" /></div>
      <div class="admin-field"><label>Port</label><input type="number" id="adminSmtpPort" value="${escapeHtml(String(notif.smtp_port || 587))}" /></div>
      <div class="admin-field admin-field-checkbox">
        <label><input type="checkbox" id="adminSmtpUseTls" ${notif.smtp_use_tls !== false ? 'checked' : ''} /> ${es ? 'Usar STARTTLS' : 'Use STARTTLS'}</label>
      </div>
      <div class="admin-field"><label>${es ? 'Usuario' : 'User'}</label><input type="text" id="adminSmtpUser" value="${escapeHtml(notif.smtp_user || '')}" /></div>
      <div class="admin-field">
        <label>${es ? 'Variable de entorno con la contraseña' : 'Password env var name'}${adminInfoIconHtml(es ? 'Nunca la contraseña en sí -- solo el nombre de la variable de entorno donde vive.' : 'Never the password itself -- only the name of the environment variable it lives in.')}</label>
        <input type="text" id="adminSmtpPasswordRef" value="${escapeHtml(notif.smtp_password_ref || '')}" placeholder="SMTP_PASSWORD" />
      </div>
      <div class="admin-field"><label>${es ? 'Remitente' : 'From address'}</label><input type="text" id="adminSmtpFrom" value="${escapeHtml(notif.from_address || '')}" placeholder="${es ? 'fabric-lineage@tuempresa.com' : 'fabric-lineage@yourcompany.com'}" /></div>
      <button type="button" class="admin-save-button" data-admin-save="notifications-smtp">${es ? 'Guardar' : 'Save'}</button>
    </div>

    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Mi suscripción por email' : 'My email subscription'}${adminInfoIconHtml(es
        ? `Solo para tu cuenta (${escapeHtml(authState.userEmail || '')}). Por ahora no hay gestión de listas de otras personas -- cada admin activa la suya desde aquí.`
        : `Only for your own account (${escapeHtml(authState.userEmail || '')}). There is no management of other people's lists yet -- every admin turns theirs on from here.`)}</h4>
      <div class="admin-field admin-field-checkbox">
        <label><input type="checkbox" id="adminNotifySucceeded" ${mine.notify_succeeded ? 'checked' : ''} /> ${es ? 'Avisarme cuando un escaneo se complete correctamente' : 'Notify me when a scan completes successfully'}</label>
      </div>
      <div class="admin-field admin-field-checkbox">
        <label><input type="checkbox" id="adminNotifyFailed" ${mine.notify_failed ? 'checked' : ''} /> ${es ? 'Avisarme cuando un escaneo falle' : 'Notify me when a scan fails'}</label>
      </div>
      <div class="admin-field admin-field-checkbox">
        <label><input type="checkbox" id="adminNotifyCancelled" ${mine.notify_cancelled ? 'checked' : ''} /> ${es ? 'Avisarme cuando un escaneo se detenga' : 'Notify me when a scan is stopped'}</label>
      </div>
      <div class="admin-field">
        <label>${es ? 'Idioma del correo' : 'Email language'}</label>
        <select id="adminNotifyLanguage">
          <option value="es" ${mine.language === 'es' ? 'selected' : ''}>Español</option>
          <option value="en" ${mine.language === 'en' ? 'selected' : ''}>English</option>
        </select>
      </div>
      <button type="button" class="admin-save-button" data-admin-save="notifications-subscription">${es ? 'Guardar mi suscripción' : 'Save my subscription'}</button>
      <button type="button" class="admin-button-secondary" data-test-notification="1">${es ? 'Enviar email de prueba' : 'Send test email'}</button>
      <span class="admin-test-result" data-test-result="notifications"></span>
    </div>

    <div class="admin-card">
      <h4 class="admin-card-title">Microsoft Teams${adminInfoIconHtml(es
        ? 'Compartido para toda la herramienta, como el correo -- un único canal de Teams recibe el aviso, no es por persona. Crea un conector de webhook entrante en el canal que quieras usar y pega aquí la URL.'
        : 'Shared across the whole tool, like email -- a single Teams channel gets the notification, not per person. Create an incoming webhook connector on the channel you want to use and paste its URL here.')}</h4>
      <div class="admin-field">
        <label>${es ? 'URL del webhook' : 'Webhook URL'}</label>
        <input type="text" id="adminTeamsWebhookUrl" value="${escapeHtml(notif.teams_webhook_url || '')}" placeholder="https://.../webhook/..." />
      </div>
      <div class="admin-field">
        <label>${es ? 'Idioma del mensaje' : 'Message language'}</label>
        <select id="adminTeamsLanguage">
          <option value="es" ${(notif.teams_language || 'es') === 'es' ? 'selected' : ''}>Español</option>
          <option value="en" ${notif.teams_language === 'en' ? 'selected' : ''}>English</option>
        </select>
      </div>
      <div class="admin-field admin-field-checkbox">
        <label><input type="checkbox" id="adminTeamsNotifySucceeded" ${notif.teams_notify_succeeded ? 'checked' : ''} /> ${es ? 'Avisar cuando un escaneo se complete correctamente' : 'Notify when a scan completes successfully'}</label>
      </div>
      <div class="admin-field admin-field-checkbox">
        <label><input type="checkbox" id="adminTeamsNotifyFailed" ${notif.teams_notify_failed ? 'checked' : ''} /> ${es ? 'Avisar cuando un escaneo falle' : 'Notify when a scan fails'}</label>
      </div>
      <div class="admin-field admin-field-checkbox">
        <label><input type="checkbox" id="adminTeamsNotifyCancelled" ${notif.teams_notify_cancelled ? 'checked' : ''} /> ${es ? 'Avisar cuando un escaneo se detenga' : 'Notify when a scan is stopped'}</label>
      </div>
      <button type="button" class="admin-save-button" data-admin-save="notifications-teams">${es ? 'Guardar' : 'Save'}</button>
      <button type="button" class="admin-button-secondary" data-test-teams-notification="1">${es ? 'Enviar aviso de prueba' : 'Send test notification'}</button>
      <span class="admin-test-result" data-test-result="notifications-teams"></span>
    </div>
  `;
}

// --- Purview-inspired admin tabs (Tanda A, 2026-07-09) -------------------
// All three follow the exact lazy-load-on-first-open pattern already used
// for the "sessions" tab: null cache -> fetch on tab click -> re-render.

function renderAdminAccessAuditTab() {
  const es = state.lang === 'es';
  if (adminAccessAuditCache === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminAccessAuditCache;
  if (!data.found) {
    return `<div class="scan-history-empty">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</div>`;
  }
  const filteredAdmins = data.tenant_wide_admins.filter(entry => matchesAdminListFilter('access', entry.principal_name, entry.principal_email));
  const filteredWorkspaces = data.by_workspace.filter(ws =>
    matchesAdminListFilter('access', ws.workspace_name) || ws.assignments.some(a => matchesAdminListFilter('access', a.principal_name, a.principal_email))
  );
  return `
    ${renderAdminListFilterInput('access', es ? 'Filtrar por principal o workspace...' : 'Filter by principal or workspace...')}
    <p class="admin-field-hint">${es
      ? `${data.workspace_count} workspaces · ${data.assignment_count} asignaciones de rol.`
      : `${data.workspace_count} workspaces · ${data.assignment_count} role assignments.`}</p>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Administradores en todo el tenant' : 'Tenant-wide admins'}${adminInfoIconHtml(es
        ? 'Quién es Admin en más workspaces a la vez -- útil para ver quién tiene, en la práctica, las llaves de todo. Clica una fila para ver en qué workspaces exactamente y con qué rol.'
        : 'Who is Admin in the most workspaces at once -- useful to see who effectively holds the keys to everything. Click a row to see exactly which workspaces and with what role.')}</h4>
      <div class="admin-list">${filteredAdmins.map(entry => `
        <div class="admin-list-row admin-list-row-clickable" data-tenant-admin-workspaces="${escapeHtml(entry.principal_name)}">
          <span><strong>${escapeHtml(entry.principal_name)}</strong> <span class="admin-session-row-email">${entry.principal_email ? `${escapeHtml(entry.principal_email)} · ` : ''}(${escapeHtml(entry.principal_type)})</span></span>
          <span>${entry.admin_workspace_count} ${es ? 'workspaces' : 'workspaces'}</span>
        </div>`).join('')}</div>
      ${!adminListFilters.access && data.tenant_wide_admin_total_count > data.tenant_wide_admins.length ? `<p class="admin-field-hint">${es
        ? `y ${data.tenant_wide_admin_total_count - data.tenant_wide_admins.length} más`
        : `and ${data.tenant_wide_admin_total_count - data.tenant_wide_admins.length} more`}</p>` : ''}
    </div>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Usuarios por workspace' : 'Users by workspace'}</h4>
      ${filteredWorkspaces.map(ws => `
        <details class="admin-workspace-access-group" data-workspace-group="${escapeHtml(ws.workspace_name)}" ${adminWorkspaceGroupsExpanded.has(ws.workspace_name) ? 'open' : ''}>
          <summary>${escapeHtml(ws.workspace_name)} <span class="admin-session-row-email">(${ws.assignments.length})</span></summary>
          <div class="admin-embedded-table-scroll">
            <table class="impact-breakdown-table">
              <thead><tr>
                <th>${es ? 'Usuario' : 'User'}</th>
                <th>${es ? 'Correo' : 'Email'}</th>
                <th>${es ? 'Puesto' : 'Job title'}</th>
                <th>${es ? 'Rol' : 'Role'}</th>
              </tr></thead>
              <tbody>${ws.assignments.map(a => {
                const email = (a.principal_email || '').trim().toLowerCase();
                const profile = email ? adminUserProfilesCache[email] : null;
                const jobTitleText = (profile && profile.job_title) || '—';
                return `
                <tr>
                  <td>${escapeHtml(a.principal_name)} <span class="admin-session-row-email">(${escapeHtml(a.principal_type)})</span></td>
                  <td>${escapeHtml(a.principal_email || '—')}</td>
                  <td>${escapeHtml(jobTitleText)}</td>
                  <td>${escapeHtml(a.role)}</td>
                </tr>`;
              }).join('')}</tbody>
            </table>
          </div>
        </details>`).join('')}
    </div>
  `;
}

// Job titles for "Usuarios por workspace" are fetched lazily, one workspace
// group at a time, only once it's expanded -- fetching every workspace's
// every user up front would mean one Graph round-trip per person tenant-
// wide before the tab even finishes its first render. adminUserProfilesCache
// holds a resolved {display_name, job_title, department} or `null` (looked
// up, Graph had nothing) once an email has ever been requested, so a group
// re-opened later never re-fetches. adminWorkspaceGroupsExpanded survives
// across renderAdminPanel() re-renders (native <details> state doesn't) so
// the fetch's own re-render doesn't visually collapse the group the admin
// just opened.
let adminWorkspaceGroupsExpanded = new Set();
let adminUserProfilesCache = {};
let adminUserProfilesFetching = new Set();

async function maybeFetchWorkspaceUserProfiles(workspaceName) {
  const data = adminAccessAuditCache;
  if (!data || !data.found) return;
  const ws = data.by_workspace.find(w => w.workspace_name === workspaceName);
  if (!ws) return;
  const emails = [...new Set(ws.assignments.map(a => (a.principal_email || '').trim().toLowerCase()).filter(Boolean))]
    .filter(email => !(email in adminUserProfilesCache) && !adminUserProfilesFetching.has(email));
  if (!emails.length) return;
  emails.forEach(email => adminUserProfilesFetching.add(email));
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/user-profiles?emails=${encodeURIComponent(emails.join(','))}`);
    const payload = response.ok ? await response.json() : { profiles: {} };
    emails.forEach(email => { adminUserProfilesCache[email] = (payload.profiles || {})[email] || null; });
  } catch (error) {
    emails.forEach(email => { adminUserProfilesCache[email] = null; });
  } finally {
    emails.forEach(email => adminUserProfilesFetching.delete(email));
  }
  renderGovernancePanelIfOpen();
}

let tenantAdminWorkspacesState = null;

function renderTenantAdminWorkspacesModal(principalName) {
  if (!els.tenantAdminWorkspacesModal) return;
  const es = state.lang === 'es';
  const entry = ((adminAccessAuditCache && adminAccessAuditCache.tenant_wide_admins) || []).find(a => a.principal_name === principalName);
  els.tenantAdminWorkspacesTitle.textContent = principalName;
  if (!entry) {
    els.tenantAdminWorkspacesSubtitle.textContent = '';
    els.tenantAdminWorkspacesBody.innerHTML = `<p>${escapeHtml(es ? 'Sin datos.' : 'No data.')}</p>`;
    return;
  }
  els.tenantAdminWorkspacesSubtitle.textContent = es
    ? `${entry.principal_email ? `${entry.principal_email} · ` : ''}Admin en ${entry.admin_workspace_count} workspaces`
    : `${entry.principal_email ? `${entry.principal_email} · ` : ''}Admin in ${entry.admin_workspace_count} workspaces`;
  els.tenantAdminWorkspacesBody.innerHTML = `
    <table class="impact-breakdown-table">
      <thead><tr><th>Workspace</th><th>${es ? 'Rol' : 'Role'}</th></tr></thead>
      <tbody>${entry.workspaces.map(w => `
        <tr><td>${escapeHtml(w.workspace_name)}</td><td>${escapeHtml(w.role)}</td></tr>`).join('')}</tbody>
    </table>
  `;
}

function toggleTenantAdminWorkspacesModal(forceOpen, principalName) {
  if (!els.tenantAdminWorkspacesModal) return;
  const shouldOpen = typeof forceOpen === 'boolean' ? forceOpen : els.tenantAdminWorkspacesModal.hidden;
  if (shouldOpen) {
    tenantAdminWorkspacesState = { principalName };
    renderTenantAdminWorkspacesModal(principalName);
    pushStackedModal(els.tenantAdminWorkspacesModal);
  } else {
    if (stackedModals[stackedModals.length - 1] === els.tenantAdminWorkspacesModal) popStackedModal();
    else els.tenantAdminWorkspacesModal.hidden = true; // defensive fallback, shouldn't happen
    tenantAdminWorkspacesState = null;
  }
}

async function loadAdminAccessAudit() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/access-audit`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminAccessAuditCache = await response.json();
  } catch (error) {
    adminAccessAuditCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  renderGovernancePanelIfOpen();
}

async function loadAdminGovernanceScan() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/governance-scan`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminGovernanceScanCache = await response.json();
  } catch (error) {
    adminGovernanceScanCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  renderGovernancePanelIfOpen();
}

// Scanner API diagnosis (2026-08-26) -- status/blocked/error per check, each
// with a concrete fix (see scripts/73_discover_governance_scan.ps1's own
// Add-GovernanceStatus calls). Shown prominently, not buried in a tooltip:
// per the explicit ask that led to this, a blocked capability should read
// as "here's exactly what to go fix", not a silently empty table.
function renderGovernanceStatusList(statusRows) {
  const es = state.lang === 'es';
  if (!statusRows.length) return '';
  const badgeClassByStatus = { ok: 'is-added', blocked: 'is-modified', error: 'is-removed', skipped: '' };
  return `<div class="admin-list admin-governance-status-list">${statusRows.map(row => `
    <div class="admin-list-row admin-governance-status-row">
      <div class="admin-governance-status-row-main">
        <span class="admin-change-type-chip ${badgeClassByStatus[row.status] || ''}">${escapeHtml((row.status || '').toUpperCase())}</span>
        <span class="admin-governance-status-check">${escapeHtml(row.check || '')}</span>
      </div>
      <p class="admin-field-hint admin-governance-status-detail">${escapeHtml(row.detail || '')}</p>
      ${row.fix ? `<p class="admin-field-hint admin-governance-status-fix"><strong>${es ? 'Cómo arreglarlo: ' : 'How to fix: '}</strong>${escapeHtml(row.fix)}</p>` : ''}
    </div>`).join('')}</div>`;
}

// Governance panel tabs (2026-08-26 split -- was one combined tab; RLS/CLS/
// DDM, sensitivity labels, tags, and endorsement each need "su propia
// pestaña e interfaz válida para sus propias configuraciones" per explicit
// request, not one long scroll). Every one of these shares the same
// "not scanned yet" empty state, hence this one helper instead of five
// near-identical copies.
function renderGovernanceNotScannedCard(titleEs, titleEn) {
  const es = state.lang === 'es';
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? titleEs : titleEn}</h4>
      <div class="scan-history-empty">${es ? 'El escaneo de gobernanza no se ha ejecutado todavía.' : 'The governance scan has not run yet.'}</div>
      <p class="admin-field-hint">${es
        ? 'Ejecuta <code>backend/scripts/73_discover_governance_scan.ps1</code> -- ver la pestaña Resumen para el diagnóstico exacto y qué permisos hacen falta.'
        : 'Run <code>backend/scripts/73_discover_governance_scan.ps1</code> -- see the Overview tab for the exact diagnosis and which permissions are needed.'}</p>
    </div>`;
}

function renderGovernanceEmptySection(es) {
  return `<div class="scan-history-empty">${es ? 'Sin datos todavía -- ver el diagnóstico en Resumen.' : 'No data yet -- see the diagnosis under Overview.'}</div>`;
}

function renderGovernanceOverviewTab() {
  const es = state.lang === 'es';
  if (adminGovernanceScanCache === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminGovernanceScanCache;
  if (!data.found) {
    return renderGovernanceNotScannedCard('Resumen de gobernanza', 'Governance overview');
  }

  const access = adminAccessAuditCache;
  const sqlSecurity = data.sql_security || { scanned: false, column_security: [], row_level_security: [] };
  const rlsModelCount = (data.rls_by_dataset || []).length;
  const counts = data.counts || {};

  const metricCard = (value, labelEs, labelEn) => `
    <div class="admin-governance-metric">
      <strong>${number(value)}</strong>
      <span>${es ? labelEs : labelEn}</span>
    </div>`;

  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'De un vistazo' : 'At a glance'}</h4>
      <div class="admin-governance-metrics-grid">
        ${metricCard(access && access.found ? access.tenant_wide_admin_total_count : 0, 'Admins de workspace (tenant)', 'Tenant-wide workspace admins')}
        ${metricCard(rlsModelCount, 'Modelos con RLS', 'Models with RLS')}
        ${metricCard(sqlSecurity.row_level_security.length, 'Políticas RLS (SQL)', 'RLS policies (SQL)')}
        ${metricCard(sqlSecurity.column_security.length, 'Columnas con CLS/DDM', 'Columns with CLS/DDM')}
        ${metricCard(counts.sensitivity_labels || 0, 'Elementos con etiqueta', 'Labeled items')}
        ${metricCard(counts.endorsement || 0, 'Elementos con endorsement', 'Endorsed items')}
        ${metricCard(counts.tags || 0, 'Etiquetas de Fabric aplicadas', 'Fabric tags applied')}
      </div>
      <p class="admin-field-hint">${es ? 'Último escaneo' : 'Last scanned'}: ${escapeHtml(formatAdminSessionTimestamp(data.last_scanned_at))}</p>
    </div>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Diagnóstico del escaneo' : 'Scan diagnosis'}${adminInfoIconHtml(es
        ? 'Cada capacidad de este panel depende de una API distinta, con su propio permiso. Esto muestra exactamente cuál funciona, cuál está bloqueada, y qué hacer para desbloquearla.'
        : 'Each capability in this panel depends on a different API, with its own permission. This shows exactly what works, what\'s blocked, and what to do to unblock it.')}</h4>
      ${renderGovernanceStatusList(data.status || [])}
    </div>
  `;
}

function renderGovernanceRlsTab() {
  const es = state.lang === 'es';
  if (adminGovernanceScanCache === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminGovernanceScanCache;
  if (!data.found) {
    return renderGovernanceNotScannedCard('RLS, CLS y DDM', 'RLS, CLS & DDM');
  }
  const rlsDatasets = data.rls_by_dataset || [];
  const sqlSecurity = data.sql_security || { scanned: false, column_security: [], row_level_security: [] };

  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'RLS de modelos semánticos (DAX)' : 'Semantic model RLS (DAX)'}${adminInfoIconHtml(es
        ? 'Nombre del rol, expresión DAX del filtro, y a quién está asignado -- por modelo semántico. Solo la Scanner API expone esto sin tener que ser owner de cada modelo.'
        : 'Role name, DAX filter expression, and who it\'s assigned to -- per semantic model. Only the Scanner API exposes this without being the owner of every model.')}</h4>
      ${rlsDatasets.length ? rlsDatasets.map(dataset => `
        <div class="admin-governance-rls-dataset">
          <strong>${escapeHtml(dataset.qualified_name)}</strong>
          ${dataset.roles.map(role => `
            <div class="admin-embedded-table-scroll">
              <table class="impact-breakdown-table">
                <thead><tr><th>${es ? 'Rol' : 'Role'}</th><th>${es ? 'Tabla' : 'Table'}</th><th>${es ? 'Filtro (DAX)' : 'Filter (DAX)'}</th><th>${es ? 'Miembro' : 'Member'}</th></tr></thead>
                <tbody>${role.entries.map(entry => `
                  <tr>
                    <td>${escapeHtml(role.role_name)}</td>
                    <td>${escapeHtml(entry.table_name)}</td>
                    <td><code>${escapeHtml(entry.filter_expression)}</code></td>
                    <td>${escapeHtml(entry.member_name)}${entry.member_type ? ` <span class="admin-session-row-email">[${escapeHtml(entry.member_type)}]</span>` : ''}</td>
                  </tr>`).join('')}</tbody>
              </table>
            </div>`).join('')}
        </div>`).join('') : renderGovernanceEmptySection(es)}
    </div>

    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'RLS a nivel SQL (Warehouse / Lakehouse)' : 'SQL-level RLS (Warehouse / Lakehouse)'}${adminInfoIconHtml(es
        ? 'Políticas CREATE SECURITY POLICY (sys.security_predicates), por objeto -- descubierto por NB_Extract_SQL_Endpoint_Catalog.py, independiente de la Scanner API.'
        : 'CREATE SECURITY POLICY policies (sys.security_predicates), per object -- discovered by NB_Extract_SQL_Endpoint_Catalog.py, independent of the Scanner API.')}</h4>
      ${sqlSecurity.row_level_security.length ? `
        <div class="admin-embedded-table-scroll">
          <table class="impact-breakdown-table">
            <thead><tr><th>${es ? 'Workspace' : 'Workspace'}</th><th>${es ? 'Objeto' : 'Object'}</th><th>${es ? 'Política' : 'Policy'}</th><th>${es ? 'Tipo de predicado' : 'Predicate type'}</th></tr></thead>
            <tbody>${sqlSecurity.row_level_security.map(row => `
              <tr><td>${escapeHtml(row.workspace_name)}</td><td>${escapeHtml(row.schema_name)}.${escapeHtml(row.object_name)}</td><td>${escapeHtml(row.policy_name)}</td><td>${escapeHtml(row.predicate_type)}</td></tr>`).join('')}</tbody>
          </table>
        </div>` : `<div class="scan-history-empty">${es
          ? (sqlSecurity.scanned ? 'Escaneado -- sin políticas RLS encontradas.' : 'Sin escanear todavía (NB_Extract_SQL_Endpoint_Catalog.py) -- distinto del escaneo de gobernanza de arriba.')
          : (sqlSecurity.scanned ? 'Scanned -- no RLS policies found.' : 'Not scanned yet (NB_Extract_SQL_Endpoint_Catalog.py) -- separate from the governance scan above.')}</div>`}
    </div>

    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'CLS y DDM a nivel de columna' : 'Column-level CLS & DDM'}${adminInfoIconHtml(es
        ? 'DDM (enmascarado dinámico, sys.masked_columns) y CLS (GRANT/DENY por columna, sys.column_permissions), por columna.'
        : 'DDM (dynamic data masking, sys.masked_columns) and CLS (per-column GRANT/DENY, sys.column_permissions), per column.')}</h4>
      ${sqlSecurity.column_security.length ? `
        <div class="admin-embedded-table-scroll">
          <table class="impact-breakdown-table">
            <thead><tr><th>${es ? 'Workspace' : 'Workspace'}</th><th>${es ? 'Objeto' : 'Object'}</th><th>${es ? 'Columna' : 'Column'}</th><th>${es ? 'Tipo' : 'Type'}</th><th>${es ? 'Detalle' : 'Detail'}</th></tr></thead>
            <tbody>${sqlSecurity.column_security.map(row => `
              <tr><td>${escapeHtml(row.workspace_name)}</td><td>${escapeHtml(row.schema_name)}.${escapeHtml(row.object_name)}</td><td>${escapeHtml(row.column_name)}</td><td>${escapeHtml((row.security_type || '').toUpperCase())}</td><td>${escapeHtml(row.detail)}</td></tr>`).join('')}</tbody>
          </table>
        </div>` : `<div class="scan-history-empty">${es
          ? (sqlSecurity.scanned ? 'Escaneado -- sin CLS/DDM encontrado.' : 'Sin escanear todavía (NB_Extract_SQL_Endpoint_Catalog.py) -- distinto del escaneo de gobernanza de arriba.')
          : (sqlSecurity.scanned ? 'Scanned -- no CLS/DDM found.' : 'Not scanned yet (NB_Extract_SQL_Endpoint_Catalog.py) -- separate from the governance scan above.')}</div>`}
    </div>
  `;
}

function renderGovernanceSensitivityLabelsTab() {
  const es = state.lang === 'es';
  if (adminGovernanceScanCache === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminGovernanceScanCache;
  if (!data.found) {
    return renderGovernanceNotScannedCard('Etiquetas de sensibilidad', 'Sensitivity labels');
  }
  const sensitivityRows = data.sensitivity_labels || [];
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Etiquetas de sensibilidad (Microsoft Purview Information Protection)' : 'Sensitivity labels (Microsoft Purview Information Protection)'}${adminInfoIconHtml(es
        ? 'La etiqueta oficial aplicada al elemento (Público/Confidencial/etc., según la taxonomía de tu organización) -- distinto de "Sensibilidad detectada", que es la clasificación propia de este proyecto por nombre/contenido de columna.'
        : 'The official label applied to the item (Public/Confidential/etc., per your organization\'s taxonomy) -- distinct from "Detected sensitivity", this project\'s own column name/content classification.')}</h4>
      ${sensitivityRows.length ? `
        <div class="admin-embedded-table-scroll">
          <table class="impact-breakdown-table">
            <thead><tr><th>${es ? 'Elemento' : 'Item'}</th><th>${es ? 'Tipo' : 'Type'}</th><th>${es ? 'Etiqueta' : 'Label'}</th></tr></thead>
            <tbody>${sensitivityRows.map(row => `
              <tr>
                <td>${escapeHtml(row.qualified_name)}</td>
                <td>${escapeHtml(row.item_type)}</td>
                <td>${escapeHtml(row.sensitivity_label_name) || `<span class="admin-session-row-email">${escapeHtml(row.sensitivity_label_id)}</span>`}</td>
              </tr>`).join('')}</tbody>
          </table>
        </div>` : renderGovernanceEmptySection(es)}
    </div>
  `;
}

function renderGovernanceFabricTagsTab() {
  const es = state.lang === 'es';
  if (adminGovernanceScanCache === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminGovernanceScanCache;
  if (!data.found) {
    return renderGovernanceNotScannedCard('Etiquetas de Fabric', 'Fabric tags');
  }
  const tagRows = data.tags || [];
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Etiquetas nativas de Fabric' : 'Native Fabric tags'}${adminInfoIconHtml(es
        ? 'Tags de Fabric aplicados de verdad a cada elemento (Scanner API) -- distinto de "Etiquetas" en Contenido, que es una lista curada a mano por este proyecto.'
        : 'Tags actually applied to each item in Fabric (Scanner API) -- distinct from "Tags" under Content, this project\'s own hand-curated list.')}</h4>
      ${tagRows.length ? `
        <div class="admin-embedded-table-scroll">
          <table class="impact-breakdown-table">
            <thead><tr><th>${es ? 'Elemento' : 'Item'}</th><th>${es ? 'Tipo' : 'Type'}</th><th>Tag</th></tr></thead>
            <tbody>${tagRows.map(row => `<tr><td>${escapeHtml(row.qualified_name)}</td><td>${escapeHtml(row.item_type)}</td><td>${escapeHtml(row.tag_name)}</td></tr>`).join('')}</tbody>
          </table>
        </div>` : renderGovernanceEmptySection(es)}
    </div>
  `;
}

function renderGovernanceEndorsementTab() {
  const es = state.lang === 'es';
  if (adminGovernanceScanCache === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminGovernanceScanCache;
  if (!data.found) {
    return renderGovernanceNotScannedCard('Endorsement', 'Endorsement');
  }
  const endorsementRows = data.endorsement || [];
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Endorsement (Promoted / Certified / Master Data)' : 'Endorsement (Promoted / Certified / Master Data)'}${adminInfoIconHtml(es
        ? 'Estado real de endorsement en Fabric -- distinto de "Certificaciones" en Contenido, que es una lista curada a mano por este proyecto.'
        : 'Real endorsement status in Fabric -- distinct from "Certifications" under Content, this project\'s own hand-curated list.')}</h4>
      ${endorsementRows.length ? `
        <div class="admin-embedded-table-scroll">
          <table class="impact-breakdown-table">
            <thead><tr><th>${es ? 'Elemento' : 'Item'}</th><th>${es ? 'Tipo' : 'Type'}</th><th>Endorsement</th><th>${es ? 'Certificado por' : 'Certified by'}</th></tr></thead>
            <tbody>${endorsementRows.map(row => `
              <tr><td>${escapeHtml(row.qualified_name)}</td><td>${escapeHtml(row.item_type)}</td><td>${escapeHtml(row.endorsement)}</td><td>${escapeHtml(row.certified_by)}</td></tr>`).join('')}</tbody>
          </table>
        </div>` : renderGovernanceEmptySection(es)}
    </div>
  `;
}

// ---------------------------------------------------------------------------
// Governance panel -- its own isolated top-level surface (2026-08-26), not
// a section nested inside Configuración/adminPanel. Flat tab list (no
// collapsible groups): 7 tabs is small enough that a Configuración-style
// grouped sidebar would just be indirection for no benefit here, and this
// panel is meant to read as a focused Purview-style tool, not another
// corner of the general settings surface.
// ---------------------------------------------------------------------------
function governanceTabs() {
  const es = state.lang === 'es';
  return [
    { key: 'overview', label: es ? 'Resumen' : 'Overview' },
    { key: 'access', label: es ? 'Accesos a workspaces' : 'Workspace access' },
    { key: 'rls', label: es ? 'RLS, CLS y DDM' : 'RLS, CLS & DDM' },
    { key: 'sensitivity', label: es ? 'Sensibilidad detectada' : 'Detected sensitivity' },
    { key: 'sensitivity-labels', label: es ? 'Etiquetas de sensibilidad' : 'Sensitivity labels' },
    { key: 'fabric-tags', label: es ? 'Etiquetas de Fabric' : 'Fabric tags' },
    { key: 'endorsement', label: es ? 'Endorsement' : 'Endorsement' },
  ];
}

function governanceTabPanelHtml(tabKey) {
  switch (tabKey) {
    case 'overview': return renderGovernanceOverviewTab();
    case 'access': return renderAdminAccessAuditTab();
    case 'rls': return renderGovernanceRlsTab();
    case 'sensitivity': return renderAdminSensitivityOverviewTab();
    case 'sensitivity-labels': return renderGovernanceSensitivityLabelsTab();
    case 'fabric-tags': return renderGovernanceFabricTagsTab();
    case 'endorsement': return renderGovernanceEndorsementTab();
    default: return '';
  }
}

function renderGovernancePanel() {
  if (!els.governancePanel) return;
  const es = state.lang === 'es';
  const tabs = governanceTabs();
  els.governancePanel.innerHTML = `
    <div class="scan-history-header">
      <h3><span class="governance-button-icon" aria-hidden="true">♟️</span> ${es ? 'Gobernanza' : 'Governance'}</h3>
      <button type="button" class="icon-button" data-close-modal aria-label="${es ? 'Cerrar' : 'Close'}">×</button>
    </div>
    <div class="admin-panel-body">
      <nav class="admin-nav" aria-label="${es ? 'Secciones' : 'Sections'}">
        <div class="admin-nav-group-body admin-nav-group-body-flat">
          ${tabs.map(tab => `<button type="button" class="admin-nav-tab${governanceActiveTab === tab.key ? ' active' : ''}" data-governance-tab="${tab.key}">${tab.label}</button>`).join('')}
        </div>
      </nav>
      <div class="admin-tab-panels">
        ${tabs.map(tab => `
        <div class="admin-tab-panel${governanceActiveTab === tab.key ? ' active' : ''}" data-governance-tab-panel="${tab.key}">
          ${governanceTabPanelHtml(tab.key)}
        </div>`).join('')}
      </div>
    </div>
  `;
  wireGovernancePanelEvents();
}

function renderGovernancePanelIfOpen() {
  if (els.governancePanel && !els.governancePanel.hidden) renderGovernancePanel();
}

// Roadmap Fase 5 (2026-08-31): "Privacidad" panel -- data-subject-rights/
// privacy locator for GDPR/FERPA/CCPA requests (a single request can
// combine access, objection and biometric data). Deliberately
// its OWN top-level modal (not a Governance tab) per explicit request --
// its own toolbar button, its own animated padlock icon. Reuses
// openModal()/#modalBackdrop the same way governancePanel/adminPanel do,
// NOT graph-map.js's independent full-screen overlay system -- this is a
// data table, not a visual diagram, same category as Gobernanza.
//
// IMPORTANT SCOPE, said plainly in the panel's own hint text too: this is
// a LOCATOR, not a personal-data puller. It shows WHICH Fabric tables
// might contain a given kind of sensitive data (by column-name pattern),
// never a specific person's actual row -- this project has never
// read/indexed row-level personal data, by design. Most of what a real
// rights request touches (biometric access control, a CRM, a marketing
// platform, payment systems) very likely lives entirely outside
// this Fabric tenant -- this can only ever cover the Fabric-hosted slice.
let privacyCoverageMapCache = null;
let privacySearchFilter = '';
let privacyRiskFilter = '';
// Roadmap Fase 6 (2026-08-31): "framework" (browse by RGPD/FERPA/CCPA,
// like a settings menu -- the default) vs "alltables" (Fase 5's original
// flat, deduplicated-per-object view). Two different, both useful,
// questions -- "what do we have under GDPR" vs "give me every flagged
// table once, sorted by risk" -- not one replacing the other.
let privacyActiveTab = 'framework';
let privacyFrameworkMapCache = null;
let privacySelectedFramework = null; // which framework is showing in the right-hand pane, survives re-render

// 2026-09-01: surfaces the REAL server-side reason (handler.py's new
// try/except around both routes below returns {error, message} on a
// genuine failure) instead of a bare "No se pudo cargar" -- a live report
// the day this shipped had no way to tell "backend threw" from "network
// down" from "not signed in" without opening devtools.
async function fetchPrivacyMap(path) {
  const es = state.lang === 'es';
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}${path}`);
    const payload = await response.json().catch(() => null);
    if (!response.ok) {
      const detail = (payload && (payload.message || payload.error)) || `HTTP ${response.status}`;
      return { found: false, reason: `${es ? 'No se pudo cargar' : 'Could not load'} (${response.status}): ${detail}` };
    }
    return payload || { found: false, reason: es ? 'Respuesta vacía del servidor.' : 'Empty server response.' };
  } catch (error) {
    return { found: false, reason: `${es ? 'No se pudo conectar con el servidor' : 'Could not reach the server'}: ${error.message || error}` };
  }
}

async function loadPrivacyCoverageMap() {
  privacyCoverageMapCache = await fetchPrivacyMap('/api/admin/privacy-coverage-map');
  renderPrivacyPanelIfOpen();
}

async function loadPrivacyFrameworkMap() {
  privacyFrameworkMapCache = await fetchPrivacyMap('/api/admin/privacy-framework-map');
  renderPrivacyPanelIfOpen();
}

// Only the ACTIVE tab's data loads eagerly -- both routes classify every
// column in dbo.bronze_object_column_catalog against all 22+ categories
// (very large on big tenants), so firing both at once on open doubled
// that work for no reason and made the panel more likely to time out
// (real report, 2026-09-01). loadActiveAdminTabData() elsewhere already
// establishes this same "only fetch what's actually visible" convention.
function loadActivePrivacyTabData() {
  if (privacyActiveTab === 'framework' && privacyFrameworkMapCache === null) loadPrivacyFrameworkMap();
  if (privacyActiveTab === 'alltables' && privacyCoverageMapCache === null) loadPrivacyCoverageMap();
}

function togglePrivacyPanel(forceOpen) {
  if (!els.privacyPanel) return;
  const open = forceOpen !== undefined ? forceOpen : els.privacyPanel.hidden;
  if (open) {
    openModal(els.privacyPanel);
    renderPrivacyPanel();
    loadActivePrivacyTabData();
  } else {
    els.privacyPanel.hidden = true;
    if (els.modalBackdrop) els.modalBackdrop.hidden = true;
  }
  if (els.privacyButton) els.privacyButton.setAttribute('aria-expanded', String(open));
}

function renderPrivacyPanelIfOpen() {
  if (els.privacyPanel && !els.privacyPanel.hidden) renderPrivacyPanel();
}

function privacyRiskBadgeHtml(risk, es) {
  const labels = { low: es ? 'Bajo' : 'Low', medium: es ? 'Medio' : 'Medium', high: es ? 'Alto' : 'High', very_high: es ? 'Muy alto' : 'Very high' };
  return `<span class="privacy-risk-badge privacy-risk-badge-${risk || 'low'}">${escapeHtml(labels[risk] || risk || '')}</span>`;
}

function privacyFilteredObjects() {
  const data = privacyCoverageMapCache;
  if (!data || !data.found) return [];
  const needle = privacySearchFilter.trim().toLowerCase();
  return data.objects.filter(obj => {
    if (privacyRiskFilter && obj.max_risk !== privacyRiskFilter) return false;
    if (!needle) return true;
    const haystack = [obj.label, obj.workspace_name, obj.source_database, ...obj.categories.map(c => c.label_es), ...obj.categories.map(c => c.label_en)]
      .filter(Boolean).join(' ').toLowerCase();
    return haystack.includes(needle);
  });
}

function renderPrivacyAllTablesView() {
  const es = state.lang === 'es';
  const data = privacyCoverageMapCache;
  if (!data) return `<p class="admin-field-hint">${es ? 'Cargando...' : 'Loading...'}</p>`;
  if (!data.found) return `<p class="admin-field-hint">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</p>`;

  const filtered = privacyFilteredObjects();
  const riskOptions = ['very_high', 'high', 'medium', 'low'];
  return `
    <div class="admin-quality-summary">
      <div class="admin-quality-stat admin-quality-stat-fail"><span class="n">${number(data.flagged_object_count)}</span><span class="label">${es ? 'Tablas con datos sensibles' : 'Tables with sensitive data'}</span></div>
      <div class="admin-quality-stat"><span class="n">${number(data.category_counts.length)}</span><span class="label">${es ? 'Categorías detectadas' : 'Categories detected'}</span></div>
      <div class="admin-quality-stat"><span class="n">${number(data.total_object_count)}</span><span class="label">${es ? 'Objetos catalogados' : 'Objects catalogued'}</span></div>
    </div>
    <div class="privacy-filter-row">
      <input type="search" id="privacySearchInput" placeholder="${es ? 'Buscar tabla, workspace o categoría...' : 'Search table, workspace, or category...'}" value="${escapeHtml(privacySearchFilter)}" />
      <select id="privacyRiskSelect">
        <option value="">${es ? 'Todos los riesgos' : 'All risk levels'}</option>
        ${riskOptions.map(r => `<option value="${r}" ${privacyRiskFilter === r ? 'selected' : ''}>${escapeHtml((es ? { very_high: 'Muy alto', high: 'Alto', medium: 'Medio', low: 'Bajo' } : { very_high: 'Very high', high: 'High', medium: 'Medium', low: 'Low' })[r])}</option>`).join('')}
      </select>
    </div>
    <div class="admin-embedded-table-scroll"><table class="admin-quality-table privacy-coverage-table">
      <thead><tr>
        <th>${es ? 'Workspace' : 'Workspace'}</th>
        <th>${es ? 'Tabla / objeto' : 'Table / object'}</th>
        <th>${es ? 'Categorías detectadas' : 'Detected categories'}</th>
        <th>${es ? 'Riesgo máximo' : 'Max risk'}</th>
      </tr></thead>
      <tbody>${filtered.map(obj => `
        <tr>
          <td>${obj.workspace_name ? escapeHtml(obj.workspace_name) : `<span class="admin-field-hint">${es ? 'sin resolver' : 'unresolved'}</span>`}</td>
          <td>${escapeHtml(obj.label)}</td>
          <td>${obj.categories.map(c => `<span class="privacy-category-chip">${escapeHtml(es ? c.label_es : c.label_en)}</span>`).join(' ')}</td>
          <td>${privacyRiskBadgeHtml(obj.max_risk, es)}</td>
        </tr>`).join('') || `<tr><td colspan="4"><span class="admin-field-hint">${es ? 'Ningún resultado con este filtro.' : 'No results for this filter.'}</span></td></tr>`}</tbody>
    </table></div>
  `;
}

function privacySystemRowHtml(system, es) {
  const owner = [system.owner_name, system.owner_email].filter(Boolean).join(' · ');
  return `
    <li class="privacy-external-system-row">
      <span class="privacy-external-system-name">${escapeHtml(system.system_name || '')}</span>
      <span class="privacy-external-system-badge ${system.in_fabric ? 'privacy-external-system-badge-in' : 'privacy-external-system-badge-out'}">${system.in_fabric ? (es ? 'En Fabric' : 'In Fabric') : (es ? 'Fuera de Fabric' : 'Outside Fabric')}</span>
      ${owner ? `<span class="privacy-external-system-owner">${escapeHtml(owner)}</span>` : ''}
      ${system.notes ? `<span class="privacy-external-system-notes">${escapeHtml(system.notes)}</span>` : ''}
    </li>
  `;
}

// Roadmap Fase 6 (2026-08-31): "browse like a settings menu" view --
// <details>/<summary> native disclosure widgets, one per legal framework,
// each expanding to its categories. No custom JS accordion state needed
// beyond remembering which ones were open across a re-render
// (privacyExpandedFrameworks), since <details> already tracks its own
// open/closed natively.
function renderPrivacyFrameworkDetail(framework, es) {
  return `
    <p class="admin-field-hint privacy-framework-description">${escapeHtml(es ? framework.description_es : framework.description_en)}</p>
    <div class="admin-list">${framework.categories.map(category => `
      <div class="privacy-framework-category-row">
        <div class="privacy-framework-category-header">
          <span>${escapeHtml(es ? category.label_es : category.label_en)}</span>
          ${privacyRiskBadgeHtml(category.risk, es)}
          <span class="admin-field-hint">${number(category.object_count)} ${es ? 'tablas en Fabric' : 'tables in Fabric'}</span>
        </div>
        ${category.objects.length ? `<ul class="privacy-framework-object-list">${category.objects.map(obj => `
          <li>${escapeHtml(obj.label)}${obj.workspace_name ? ` <span class="admin-field-hint">(${escapeHtml(obj.workspace_name)})</span>` : ''}</li>
        `).join('')}</ul>` : ''}
        ${category.external_systems.length ? `<ul class="privacy-external-system-list">${category.external_systems.map(sys => privacySystemRowHtml(sys, es)).join('')}</ul>` : ''}
        ${!category.objects.length && !category.external_systems.length ? `<p class="admin-field-hint">${es ? 'Nada localizado ni registrado todavía.' : 'Nothing located or logged yet.'}</p>` : ''}
      </div>
    `).join('')}</div>
  `;
}

// Roadmap Fase 6 follow-up (2026-09-01, real feedback: "las normativas
// deberían ordenarse en un índice a la izquierda como en el resto de
// secciones como configuración o gobernanza"): a real two-column nav +
// content layout, reusing .admin-nav/.admin-nav-tab/.admin-tab-panels
// verbatim -- the exact same primitives renderAdminPanel()/
// renderGovernancePanel() already use for their own left-hand section
// index, not a one-off accordion. One framework's categories shown at a
// time (privacySelectedFramework), same "pick a section, see its content"
// model as those two panels, instead of Fase 6's original all-expanded
// <details> stack.
function renderPrivacyFrameworkView() {
  const es = state.lang === 'es';
  const data = privacyFrameworkMapCache;
  if (!data) return `<p class="admin-field-hint">${es ? 'Cargando...' : 'Loading...'}</p>`;
  if (!data.found) return `<p class="admin-field-hint">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</p>`;
  if (!data.frameworks.length) return `<p class="admin-field-hint">${es ? 'Nada que mostrar todavía.' : 'Nothing to show yet.'}</p>`;

  if (!privacySelectedFramework || !data.frameworks.some(fw => fw.framework === privacySelectedFramework)) {
    privacySelectedFramework = data.frameworks[0].framework;
  }
  const selected = data.frameworks.find(fw => fw.framework === privacySelectedFramework);

  return `
    <div class="privacy-framework-layout">
      <nav class="admin-nav" aria-label="${es ? 'Normativas' : 'Frameworks'}">
        <div class="admin-nav-group-body admin-nav-group-body-flat">
          ${data.frameworks.map(fw => `
            <button type="button" class="admin-nav-tab${privacySelectedFramework === fw.framework ? ' active' : ''}" data-privacy-framework-nav="${fw.framework}">
              <span>${escapeHtml(es ? fw.label_es : fw.label_en)}</span>
              <span class="privacy-framework-nav-count">${number(fw.total_object_count)}</span>
            </button>
          `).join('')}
        </div>
      </nav>
      <div class="admin-tab-panels">
        <div class="admin-tab-panel active">
          ${selected ? renderPrivacyFrameworkDetail(selected, es) : ''}
        </div>
      </div>
    </div>
  `;
}

function renderPrivacyPanel() {
  if (!els.privacyPanel) return;
  const es = state.lang === 'es';

  els.privacyPanel.innerHTML = `
    <div class="scan-history-header">
      <h3>${es ? 'Privacidad' : 'Privacy'}</h3>
      <button type="button" class="icon-button" data-close-modal aria-label="${es ? 'Cerrar' : 'Close'}">×</button>
    </div>
    <div class="admin-panel-body">
      <div class="privacy-panel-content">
        <p class="admin-field-hint">${es
          ? 'Localizador de datos personales dentro de Fabric -- muestra en qué tablas hay columnas de un tipo sensible (email, biométrico, expediente académico, disciplinario, financiero, familiares, etc.), sin repetir la misma tabla por cada categoría. <strong>No es un buscador de "los datos de esta persona"</strong>: esta herramienta nunca ha leído filas reales, solo nombres de columna. La mayoría de lo que pide una solicitud RGPD/FERPA/CCPA real (acceso biométrico, CRM, marketing) probablemente vive fuera de este tenant de Fabric.'
          : 'Personal-data locator within Fabric -- shows which tables have columns of a sensitive type (email, biometric, academic record, disciplinary, financial, family/guardian data, etc.), without repeating the same table once per category. <strong>Not a "this person\'s data" search</strong>: this tool has never read real rows, only column names. Most of what a real GDPR/FERPA/CCPA request touches (biometric access, a CRM, marketing) likely lives outside this Fabric tenant.'}</p>
        <div class="privacy-tab-row">
          <button type="button" class="admin-nav-tab${privacyActiveTab === 'framework' ? ' active' : ''}" data-privacy-tab="framework">${es ? 'Por normativa' : 'By framework'}</button>
          <button type="button" class="admin-nav-tab${privacyActiveTab === 'alltables' ? ' active' : ''}" data-privacy-tab="alltables">${es ? 'Todas las tablas' : 'All tables'}</button>
        </div>
        ${privacyActiveTab === 'framework' ? renderPrivacyFrameworkView() : renderPrivacyAllTablesView()}
      </div>
    </div>
  `;
  wirePrivacyPanelEvents();
}

function wirePrivacyPanelEvents() {
  if (!els.privacyPanel) return;
  const closeButton = els.privacyPanel.querySelector('[data-close-modal]');
  if (closeButton) closeButton.addEventListener('click', () => togglePrivacyPanel(false));

  els.privacyPanel.querySelectorAll('[data-privacy-tab]').forEach(button => {
    button.addEventListener('click', () => {
      privacyActiveTab = button.dataset.privacyTab;
      renderPrivacyPanel();
      loadActivePrivacyTabData();
    });
  });

  els.privacyPanel.querySelectorAll('[data-privacy-framework-nav]').forEach(button => {
    button.addEventListener('click', () => {
      privacySelectedFramework = button.dataset.privacyFrameworkNav;
      renderPrivacyPanel();
    });
  });

  const searchInput = document.getElementById('privacySearchInput');
  if (searchInput) {
    searchInput.addEventListener('input', () => {
      privacySearchFilter = searchInput.value;
      const start = searchInput.selectionStart;
      const end = searchInput.selectionEnd;
      renderPrivacyPanel();
      const restored = document.getElementById('privacySearchInput');
      if (restored) {
        restored.focus();
        restored.setSelectionRange(start, end);
      }
    });
  }

  const riskSelect = document.getElementById('privacyRiskSelect');
  if (riskSelect) {
    riskSelect.addEventListener('change', () => {
      privacyRiskFilter = riskSelect.value;
      renderPrivacyPanel();
    });
  }
}

function loadGovernancePanelData() {
  if (adminAccessAuditCache === null) loadAdminAccessAudit();
  if (adminGovernanceScanCache === null) loadAdminGovernanceScan();
  if (adminSensitivityOverviewCache === null) loadAdminSensitivityOverview();
  if (adminContentSensitivityOverviewCache === null) loadAdminContentSensitivityOverview();
}

function toggleGovernancePanel(forceOpen) {
  if (!els.governancePanel) return;
  const open = forceOpen !== undefined ? forceOpen : els.governancePanel.hidden;
  if (open) {
    openModal(els.governancePanel);
    renderGovernancePanel();
    loadGovernancePanelData();
  } else {
    els.governancePanel.hidden = true;
    if (els.modalBackdrop) els.modalBackdrop.hidden = true;
  }
  if (els.governanceButton) els.governanceButton.setAttribute('aria-expanded', String(open));
}

function wireGovernancePanelEvents() {
  if (!els.governancePanel) return;
  const closeButton = els.governancePanel.querySelector('[data-close-modal]');
  if (closeButton) closeButton.addEventListener('click', () => toggleGovernancePanel(false));
  els.governancePanel.querySelectorAll('[data-governance-tab]').forEach(button => {
    button.addEventListener('click', () => {
      governanceActiveTab = button.dataset.governanceTab;
      renderGovernancePanel();
    });
  });
  // Same "Accesos a workspaces" interaction as before, just re-wired here
  // now that its markup renders inside #governancePanel instead of
  // #adminPanel (see the identical block in wireAdminPanelEvents).
  els.governancePanel.querySelectorAll('[data-workspace-group]').forEach(details => {
    details.addEventListener('toggle', () => {
      const name = details.dataset.workspaceGroup;
      if (details.open) {
        adminWorkspaceGroupsExpanded.add(name);
        maybeFetchWorkspaceUserProfiles(name);
      } else {
        adminWorkspaceGroupsExpanded.delete(name);
      }
    });
  });
}

// SKU prefix -> capacity type, per Microsoft's own naming convention
// (F=Fabric, P=Premium, A=Embedded/Azure, PP=Premium Per-user, FT=Trial).
// No "type" field exists on the API response itself (see docs/109's
// sibling investigation into this same endpoint) -- this is the same
// inference Microsoft's own admin portal UI does from the SKU string.
function capacitySkuTypeLabel(sku, es) {
  const s = (sku || '').toUpperCase();
  if (!s) return es ? 'Desconocido' : 'Unknown';
  if (s.startsWith('FT')) return es ? 'Fabric (prueba)' : 'Fabric (trial)';
  if (s.startsWith('F')) return 'Fabric';
  if (s.startsWith('PP')) return 'Premium Per-User';
  if (s.startsWith('P')) return 'Premium';
  if (s.startsWith('A')) return 'Embedded';
  return s;
}

function renderAdminCapacityMetricsConfigCard() {
  const es = state.lang === 'es';
  const cm = adminSettingsCache.capacity_metrics || {};
  const authMode = cm.auth_mode || 'user_session';
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Conexión a Fabric Capacity Metrics' : 'Fabric Capacity Metrics connection'}${adminInfoIconHtml(es
        ? 'El consumo real de CU solo lo expone la app "Microsoft Fabric Capacity Metrics" (un modelo semántico de Power BI, no una REST API). Conecta aquí al workspace/modelo semántico de esa app -- si ya está instalada en el tenant, no hace falta instalar nada nuevo.'
        : 'Real CU consumption is only exposed by the "Microsoft Fabric Capacity Metrics" app (a Power BI semantic model, not a REST API). Connect here to that app\'s workspace/semantic model -- if it\'s already installed in the tenant, nothing new needs installing.')}</h4>
      <div class="admin-field"><label>${es ? 'Nombre del workspace' : 'Workspace name'}</label><input type="text" id="adminCmWorkspaceName" value="${escapeHtml(cm.workspace_name || '')}" placeholder="Capacity Metrics" /></div>
      <div class="admin-field"><label>Workspace ID</label><input type="text" id="adminCmWorkspaceId" value="${escapeHtml(cm.workspace_id || '')}" /></div>
      <div class="admin-field"><label>${es ? 'Nombre del modelo semántico' : 'Semantic model name'}</label><input type="text" id="adminCmDatasetName" value="${escapeHtml(cm.dataset_name || '')}" placeholder="Fabric Capacity Metrics" /></div>
      <div class="admin-field"><label>Dataset ID</label><input type="text" id="adminCmDatasetId" value="${escapeHtml(cm.dataset_id || '')}" /></div>
      <div class="admin-field">
        <label>${es ? 'Método de autenticación' : 'Authentication method'}</label>
        <select id="adminCmAuthMode">
          <option value="service_principal" ${authMode === 'service_principal' ? 'selected' : ''}>${es ? 'Cuenta de servicio (permanente, recomendado)' : 'Service principal (permanent, recommended)'}</option>
          <option value="user_session" ${authMode === 'user_session' ? 'selected' : ''}>${es ? 'Sesión de quien pulsa el botón (deja de funcionar si nadie está conectado)' : "Whoever clicks the button's own session (stops working once nobody is signed in)"}</option>
        </select>
      </div>
      <div id="adminCmSpFields" ${authMode === 'service_principal' ? '' : 'hidden'}>
        <div class="admin-field"><label>${es ? 'Tenant ID (vacío = el de arriba)' : 'Tenant ID (blank = the one above)'}</label><input type="text" id="adminCmSpTenantId" value="${escapeHtml(cm.sp_tenant_id || '')}" /></div>
        <div class="admin-field"><label>Client ID</label><input type="text" id="adminCmSpClientId" value="${escapeHtml(cm.sp_client_id || '')}" /></div>
        <div class="admin-field">
          <label>${es ? 'Client secret (nombre de variable de entorno)' : 'Client secret (environment variable name)'}</label>
          <input type="text" id="adminCmSpClientSecretRef" value="${escapeHtml(cm.sp_client_secret_ref || '')}" placeholder="CAPACITY_METRICS_SP_CLIENT_SECRET" />
        </div>
      </div>
      <button type="button" class="admin-save-button" data-admin-save="capacity-metrics">${es ? 'Guardar' : 'Save'}</button>
      <button type="button" class="admin-button-secondary" data-test-capacity-metrics="1">${es ? 'Probar conexión' : 'Test connection'}</button>
      <button type="button" class="admin-button-secondary" data-discover-capacity-metrics="1">${es ? 'Detectar automáticamente' : 'Auto-detect'}</button>
      <span class="admin-test-result" data-test-result="capacity-metrics"></span>
      <p id="adminCmDiscoverResult" class="admin-field-hint"></p>
      <details class="admin-help-details">
        <summary class="admin-help-summary">${es ? '¿No está instalada todavía? Cómo instalarla' : 'Not installed yet? How to install it'}</summary>
        <ol class="admin-help-steps">
          <li>${es ? 'En Fabric, arriba a la derecha, abre "Apps" (o "Obtener apps") y busca "Microsoft Fabric Capacity Metrics".' : 'In Fabric, top-right, open "Apps" (or "Get apps") and search for "Microsoft Fabric Capacity Metrics".'}</li>
          <li>${es ? 'Pulsa "Obtener ahora" e instálala -- solo un administrador de Fabric/capacidad puede hacer este paso, y solo hace falta una vez por tenant.' : 'Click "Get it now" and install it -- only a Fabric/capacity admin can do this step, and it only needs doing once per tenant.'}</li>
          <li>${es ? 'Durante la configuración, elige qué capacidad(es) F/P monitorizar. Se crea un workspace (normalmente llamado "Capacity Metrics") con un informe y un modelo semántico, ambos normalmente llamados "Fabric Capacity Metrics".' : 'During setup, pick which F/P capacity(ies) to monitor. This creates a workspace (usually named "Capacity Metrics") with a report and a semantic model, both usually named "Fabric Capacity Metrics".'}</li>
          <li>${es ? 'En ese workspace, en "Administrar acceso", añade como Colaborador la cuenta de servicio que ya usa este proyecto -- o simplemente inicia sesión aquí con una cuenta que ya tenga acceso.' : "In that workspace's \"Manage access\", add this project's own service principal as a Contributor -- or just sign in here with an account that already has access."}</li>
          <li>${es ? 'Vuelve a esta pestaña y pulsa "Detectar automáticamente", o rellena el workspace y el modelo semántico a mano con sus nombres/IDs.' : 'Come back to this tab and click "Auto-detect", or fill in the workspace and semantic model by hand with their names/ids.'}</li>
        </ol>
      </details>
    </div>`;
}

function renderAdminCapacityMetricsDataSections() {
  const es = state.lang === 'es';
  const cm = adminSettingsCache.capacity_metrics || {};
  const configured = !!(cm.workspace_id && cm.dataset_id);
  if (!configured) return '';
  const overview = adminCapacityMetricsOverviewCache;
  if (overview === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando datos de consumo de CU...' : 'Loading CU consumption data...'}</div>`;
  }
  if (!overview.found) {
    return `<div class="scan-history-empty">${escapeHtml(overview.reason || (es ? 'Sin datos de consumo disponibles.' : 'No consumption data available.'))}</div>`;
  }
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Top consumo de CU por elemento' : 'Top CU consumers by item'}${adminInfoIconHtml(es
        ? 'CU (s) real consumido en la ventana que mantiene el modelo de la app (normalmente los últimos ~14 días), agregado por elemento.'
        : "Real CU (s) consumed over the window the app's model keeps (usually the last ~14 days), aggregated per item.")}</h4>
      <div class="admin-embedded-table-scroll">
        <table class="impact-breakdown-table">
          <thead><tr>
            <th>${es ? 'Capacidad' : 'Capacity'}</th>
            <th>Workspace</th>
            <th>${es ? 'Elemento' : 'Item'}</th>
            <th>${es ? 'Tipo' : 'Type'}</th>
            <th>CU (s)</th>
            <th>${es ? 'Operaciones' : 'Operations'}</th>
            <th>${es ? 'Limitación (min)' : 'Throttling (min)'}</th>
          </tr></thead>
          <tbody>${(overview.top_items || []).map(item => `
            <tr>
              <td>${escapeHtml(item.capacity_name)}</td>
              <td>${escapeHtml(item.workspace_name)}</td>
              <td><strong>${escapeHtml(item.item_name)}</strong></td>
              <td>${escapeHtml(item.item_kind)}</td>
              <td>${number(Math.round(item.cu_seconds || 0))}</td>
              <td>${number(item.operations || 0)}</td>
              <td>${item.throttling_minutes ? number(Math.round(item.throttling_minutes)) : '0'}</td>
            </tr>`).join('')}</tbody>
        </table>
      </div>
    </div>
    ${(overview.recent_users || []).length ? `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Usuarios activos recientes' : 'Recent active users'}${adminInfoIconHtml(es
        ? 'Identidades que aparecen en el historial de operaciones reciente de este modelo -- puede incluir cuentas de servicio o ids sin resolver, no solo personas.'
        : "Identities appearing in this model's recent operation history -- can include service accounts or unresolved ids, not just people.")}</h4>
      <div class="admin-chip-list">${overview.recent_users.map(u => `<span class="admin-chip">${escapeHtml(u)}</span>`).join('')}</div>
    </div>` : ''}
  `;
}

function renderAdminCapacityInsightTab() {
  const es = state.lang === 'es';
  const configCard = renderAdminCapacityMetricsConfigCard();
  // The live Capacity Metrics data (config card + top-items/CU/recent-users
  // cards below) is independent of any local scan -- it reads straight from
  // the app's own semantic model -- so it must render regardless of whether
  // the OLDER, scan-derived table right below it (bronze_workspaces/items/
  // executions) has anything yet. A 2026-08-24 bug returned early here
  // whenever that older table had no data, which silently hid the new
  // section too even though it had nothing to do with scanning.
  const capacityMetricsSections = renderAdminCapacityMetricsDataSections();
  if (adminCapacityInsightCache === null) {
    return `${configCard}${capacityMetricsSections}<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminCapacityInsightCache;
  if (!data.found) {
    return `${configCard}${capacityMetricsSections}<div class="scan-history-empty">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</div>`;
  }
  const filteredCapacities = data.capacities.filter(c => matchesAdminListFilter('capacity', c.capacity_label));
  const cuHint = es
    ? 'Consumo real de CU (Capacity Units), leído en vivo del modelo semántico de la app "Microsoft Fabric Capacity Metrics" (tarjeta de conexión arriba). "No disponible" significa que esa capacidad no aparece en el modelo conectado, o que la conexión no está configurada todavía.'
    : 'Real CU (Capacity Unit) consumption, read live from the "Microsoft Fabric Capacity Metrics" app\'s own semantic model (connection card above). "Not available" means that capacity doesn\'t appear in the connected model, or the connection isn\'t configured yet.';
  return `
    ${configCard}
    ${renderAdminListFilterInput('capacity', es ? 'Filtrar por capacidad...' : 'Filter by capacity...')}
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Todas las capacidades del tenant' : 'Every capacity in the tenant'}${adminInfoIconHtml(data.capacities_resolved_live
        ? (es
          ? 'Nombres reales resueltos en vivo desde la API de Fabric. Incluye toda capacidad del tenant, aunque no tenga ningún workspace escaneado todavía (0 en ese caso).'
          : "Real names resolved live from the Fabric API. Includes every capacity in the tenant, even ones with no scanned workspace yet (0 in that case).")
        : (es
          ? 'No se pudieron resolver nombres reales ahora mismo (sesión sin token de Fabric, o Capacity.Read.All no concedido en este tenant) -- se agrupa por ID, y solo aparecen capacidades con al menos un workspace ya escaneado.'
          : "Couldn't resolve real names right now (no Fabric token on this session, or Capacity.Read.All not granted in this tenant) -- grouped by id instead, and only capacities with at least one already-scanned workspace show up."))}</h4>
      <div class="admin-embedded-table-scroll">
        <table class="impact-breakdown-table">
          <thead><tr>
            <th>${es ? 'Nombre' : 'Name'}</th>
            <th>ID</th>
            <th>${es ? 'Tipo' : 'Type'}</th>
            <th>${es ? 'Región' : 'Region'}</th>
            <th>${es ? 'Estado' : 'State'}</th>
            <th>Workspaces</th>
            <th>${es ? 'Elementos' : 'Items'}</th>
            <th>${es ? 'Ejecuciones' : 'Runs'}</th>
            <th>${es ? 'Fallos totales' : 'Total failures'}</th>
            <th title="${escapeHtml(cuHint)}">CU (s) ⓘ</th>
          </tr></thead>
          <tbody>${filteredCapacities.map(c => `
            <tr>
              <td><strong>${escapeHtml(c.capacity_label)}</strong></td>
              <td>${escapeHtml(c.capacity_id || '—')}</td>
              <td>${escapeHtml(capacitySkuTypeLabel(c.sku, es))}</td>
              <td>${escapeHtml(c.region || '—')}</td>
              <td>${c.state === 'Inactive' ? (es ? 'Inactiva' : 'Inactive') : (c.state ? escapeHtml(c.state) : '—')}</td>
              <td>${number(c.workspace_count)}</td>
              <td>${number(c.item_count)}</td>
              <td>${number(c.execution_count)}</td>
              <td>${c.failed_count ? `${number(c.failed_count)} (${c.execution_count > 0 ? Math.round((c.failed_count / c.execution_count) * 100) : 0}%)` : '0'}</td>
              <td class="${c.cu_seconds !== undefined ? '' : 'sensitivity-security-undetected'}">${c.cu_seconds !== undefined ? number(Math.round(c.cu_seconds)) : (es ? 'No disponible' : 'Not available')}</td>
            </tr>`).join('')}</tbody>
        </table>
      </div>
    </div>
    ${capacityMetricsSections}
  `;
}

async function loadAdminCapacityInsight() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/capacity-insight`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminCapacityInsightCache = await response.json();
  } catch (error) {
    adminCapacityInsightCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  if (adminActiveTab === 'capacity') renderAdminPanel();
}

async function loadAdminDataQualityOverview() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/data-quality-overview`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminDataQualityOverviewCache = await response.json();
  } catch (error) {
    adminDataQualityOverviewCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  if (adminActiveTab === 'dataquality') renderAdminPanel();
}

async function loadAdminCapacityMetricsOverview() {
  const cm = adminSettingsCache.capacity_metrics || {};
  if (!cm.workspace_id || !cm.dataset_id) {
    adminCapacityMetricsOverviewCache = { found: false, reason: 'not_configured' };
    return;
  }
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/capacity-metrics-overview`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminCapacityMetricsOverviewCache = await response.json();
  } catch (error) {
    adminCapacityMetricsOverviewCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  if (adminActiveTab === 'capacity') renderAdminPanel();
}

const CHANGE_EVENT_LABELS = {
  added: { es: '+ Añadido', en: '+ Added' },
  removed: { es: '− Eliminado', en: '− Removed' },
  modified: { es: '~ Modificado', en: '~ Modified' },
};

function renderAdminChangesDigestTab() {
  const es = state.lang === 'es';
  if (adminChangesDigestCache === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminChangesDigestCache;
  if (!data.found) {
    return `<div class="scan-history-empty">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</div>`;
  }
  const dependencies = data.dependencies || { added_count: 0, removed_count: 0, modified_count: 0, changes: [] };
  const hasDependencyChanges = dependencies.added_count || dependencies.removed_count || dependencies.modified_count;
  const availableScans = data.available_scans || [];
  const isRange = Boolean(data.date_from || data.date_to);
  // 2026-08-18: pick any past scan from the dropdown, not just always the
  // latest one -- every row was already sitting in the same table, this
  // just exposes the ability to look back. 2026-08-24: date-range mode
  // (below) covers "everything since X" -- this picker stays for "just
  // this one specific scan", the two are independent, not mutually
  // exclusive UI, so both stay visible.
  const scanCounts = data.available_scan_counts || {};
  const scanPickerHtml = availableScans.length > 1 ? `
    <div class="admin-field">
      <label>${es ? 'Un escaneo concreto' : 'One specific scan'}</label>
      <select id="adminChangesScanPicker">
        ${availableScans.map(scan => {
          const count = scanCounts[scan];
          const countLabel = typeof count === 'number' ? ` — ${count} ${es ? 'cambios' : 'changes'}` : '';
          return `<option value="${escapeHtml(scan)}" ${!isRange && scan === data.scan_started_at ? 'selected' : ''}>${escapeHtml(formatAdminSessionTimestamp(scan))}${scan === data.latest_scan_started_at ? ` (${es ? 'último' : 'latest'})` : ''}${countLabel}</option>`;
        }).join('')}
      </select>
    </div>` : '';
  // Date-range filter (2026-08-24): aggregates every scan whose event_date
  // falls in [from, to] into one digest instead of showing just one scan.
  // "Desde el primer escaneo completo" prefills `from` with that scan's
  // own date and leaves `to` empty (= up to the most recent).
  const rangeFilterHtml = `
    <div class="admin-card admin-changes-range-filter">
      <h4 class="admin-card-title">${es ? 'Histórico por rango de fechas' : 'History by date range'}</h4>
      <div class="admin-field">
        <label>${es ? 'Desde' : 'From'}</label>
        <input type="date" id="adminChangesDateFrom" value="${escapeHtml(data.date_from || '')}" />
      </div>
      <div class="admin-field">
        <label>${es ? 'Hasta' : 'To'}</label>
        <input type="date" id="adminChangesDateTo" value="${escapeHtml(data.date_to || '')}" />
      </div>
      <button type="button" class="admin-button-secondary" data-changes-apply-range="1">${es ? 'Aplicar' : 'Apply'}</button>
      ${data.first_full_scan_started_at ? `<button type="button" class="admin-button-secondary" data-changes-since-first-full="${escapeHtml(data.first_full_scan_started_at)}">${es ? 'Desde el primer escaneo completo' : 'Since the first full scan'}</button>` : ''}
      ${isRange ? `<button type="button" class="admin-button-secondary" data-changes-clear-range="1">${es ? 'Volver al último escaneo' : 'Back to latest scan'}</button>` : ''}
    </div>`;
  // Grouped by workspace (2026-08-18), most-changed workspace first, each
  // collapsed by default -- a flat list of every changed item across every
  // workspace in one scan was long enough that "which workspace is this
  // even in" took real scanning to answer.
  const scansIncluded = data.scans_included || [];
  const scansIncludedHtml = scansIncluded.length ? `
    <div class="admin-list">${scansIncluded.map(s => `
      <div class="admin-list-row">
        <span>${escapeHtml(formatAdminSessionTimestamp(s.scan_started_at))}</span>
        <span class="admin-session-row-email">${escapeHtml(s.triggered_by_email || (es ? '(automático / sin sesión)' : '(automatic / no session)'))}</span>
      </div>`).join('')}</div>` : '';

  // Filter bar: text search (adminListFilters.changes, same generic
  // mechanism every other tab's search box already uses) + workspace/
  // item-type dropdowns (options derived from THIS result set, so a
  // workspace with zero changes right now never appears as a dead option)
  // + change-type chips (2026-08-25 redesign, replacing the old per-
  // workspace <details> accordion with a real filterable table).
  const workspaceOptions = [...new Set(data.changes.map(c => c.workspace_name).filter(Boolean))].sort((a, b) => a.localeCompare(b));
  const itemTypeOptions = [...new Set(data.changes.map(c => c.item_type).filter(Boolean))].sort((a, b) => a.localeCompare(b));
  if (adminChangesWorkspaceFilter && !workspaceOptions.includes(adminChangesWorkspaceFilter)) adminChangesWorkspaceFilter = '';
  if (adminChangesItemTypeFilter && !itemTypeOptions.includes(adminChangesItemTypeFilter)) adminChangesItemTypeFilter = '';

  const searchNeedle = (adminListFilters.changes || '').trim().toLowerCase();
  const filteredChanges = data.changes.filter(c =>
    (adminChangesEventTypeFilter === 'all' || c.event_type === adminChangesEventTypeFilter) &&
    (!adminChangesWorkspaceFilter || c.workspace_name === adminChangesWorkspaceFilter) &&
    (!adminChangesItemTypeFilter || c.item_type === adminChangesItemTypeFilter) &&
    (!searchNeedle || `${c.item_name} ${c.workspace_name}`.toLowerCase().includes(searchNeedle))
  ).sort((a, b) => (b.event_date || '').localeCompare(a.event_date || '') || (a.workspace_name || '').localeCompare(b.workspace_name || ''));

  const eventTypeChips = ['all', 'added', 'removed', 'modified'];
  const eventTypeChipLabel = { all: es ? 'Todos' : 'All', ...Object.fromEntries(Object.entries(CHANGE_EVENT_LABELS).map(([k, v]) => [k, v[state.lang]])) };

  return `
    ${rangeFilterHtml}
    ${scanPickerHtml}
    <div class="admin-changes-summary-pills">
      <span class="admin-count-pill is-created">${number(data.added_count)} <em>${es ? 'creados' : 'created'}</em></span>
      <span class="admin-count-pill is-removed">${number(data.removed_count)} <em>${es ? 'eliminados' : 'removed'}</em></span>
      <span class="admin-count-pill is-modified">${number(data.modified_count)} <em>${es ? 'modificados' : 'modified'}</em></span>
      <span class="admin-field-hint admin-changes-summary-context">${isRange
        ? (es
            ? `Entre ${data.date_from ? escapeHtml(data.date_from) : 'el principio'} y ${data.date_to ? escapeHtml(data.date_to) : 'hoy'} · ${scansIncluded.length} escaneo${scansIncluded.length === 1 ? '' : 's'}`
            : `Between ${data.date_from ? escapeHtml(data.date_from) : 'the start'} and ${data.date_to ? escapeHtml(data.date_to) : 'today'} · ${scansIncluded.length} scan${scansIncluded.length === 1 ? '' : 's'}`)
        : (es
            ? `Escaneo del ${escapeHtml(formatAdminSessionTimestamp(data.scan_started_at))} · ${escapeHtml((scansIncluded[0] && scansIncluded[0].triggered_by_email) || 'automático')}`
            : `Scan from ${escapeHtml(formatAdminSessionTimestamp(data.scan_started_at))} · ${escapeHtml((scansIncluded[0] && scansIncluded[0].triggered_by_email) || 'automatic')}`)}</span>
    </div>
    ${isRange && scansIncludedHtml ? `
    <details class="admin-help-details">
      <summary class="admin-help-summary">${es ? 'Escaneos incluidos' : 'Scans included'} <span class="admin-session-row-email">(${scansIncluded.length})</span></summary>
      ${scansIncludedHtml}
    </details>` : ''}
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Elementos modificados' : 'Modified items'}</h4>
      <div class="admin-changes-filter-bar">
        ${renderAdminListFilterInput('changes', es ? 'Buscar elemento o workspace...' : 'Search item or workspace...')}
        <select id="adminChangesWorkspaceFilter" aria-label="${es ? 'Filtrar por workspace' : 'Filter by workspace'}">
          <option value="">${es ? 'Todos los workspaces' : 'All workspaces'}</option>
          ${workspaceOptions.map(w => `<option value="${escapeHtml(w)}" ${w === adminChangesWorkspaceFilter ? 'selected' : ''}>${escapeHtml(w)}</option>`).join('')}
        </select>
        <select id="adminChangesItemTypeFilter" aria-label="${es ? 'Filtrar por tipo' : 'Filter by type'}">
          <option value="">${es ? 'Todos los tipos' : 'All types'}</option>
          ${itemTypeOptions.map(t => `<option value="${escapeHtml(t)}" ${t === adminChangesItemTypeFilter ? 'selected' : ''}>${escapeHtml(t)}</option>`).join('')}
        </select>
        <div class="admin-metrics-filter-row" role="group" aria-label="${es ? 'Filtrar por tipo de cambio' : 'Filter by change type'}">
          ${eventTypeChips.map(cls => `<button type="button" class="admin-metrics-filter-button${adminChangesEventTypeFilter === cls ? ' active' : ''}" data-changes-event-filter="${cls}">${escapeHtml(eventTypeChipLabel[cls])}</button>`).join('')}
        </div>
      </div>
      <div class="admin-embedded-table-scroll">
        <table class="impact-breakdown-table admin-changes-table">
          <thead><tr>
            <th>${es ? 'Workspace' : 'Workspace'}</th>
            <th>${es ? 'Elemento' : 'Item'}</th>
            <th>${es ? 'Tipo' : 'Type'}</th>
            <th>${es ? 'Cambio' : 'Change'}</th>
            <th>${es ? 'Fecha' : 'Date'}</th>
          </tr></thead>
          <tbody>${filteredChanges.length ? filteredChanges.map(c => `
            <tr>
              <td>${escapeHtml(c.workspace_name || '—')}</td>
              <td><strong>${escapeHtml(c.item_name)}</strong>${c.scope_label ? ` <span class="admin-session-row-email">${escapeHtml(c.scope_label)}</span>` : ''}</td>
              <td>${escapeHtml(c.item_type || '—')}</td>
              <td><span class="admin-change-type-chip is-${escapeHtml(c.event_type)}">${escapeHtml((CHANGE_EVENT_LABELS[c.event_type] || { [state.lang]: c.event_type })[state.lang])}</span></td>
              <td>${escapeHtml(c.event_date || '—')}</td>
            </tr>`).join('') : `<tr><td colspan="5"><div class="scan-history-empty">${es ? 'Ningún cambio coincide con los filtros.' : 'No changes match the current filters.'}</div></td></tr>`}</tbody>
        </table>
      </div>
      <p class="admin-field-hint">${es
        ? `Mostrando ${number(filteredChanges.length)} de ${number(data.changes.length)} cargados${data.total_count > data.changes.length ? ` (${number(data.total_count - data.changes.length)} más no cargados -- acota el rango de fechas)` : ''}.`
        : `Showing ${number(filteredChanges.length)} of ${number(data.changes.length)} loaded${data.total_count > data.changes.length ? ` (${number(data.total_count - data.changes.length)} more not loaded -- narrow the date range)` : ''}.`}</p>
    </div>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Dependencias (relaciones entre elementos)' : 'Dependencies (relationships between items)'}${adminInfoIconHtml(es
        ? `${dependencies.added_count} añadidas, ${dependencies.removed_count} eliminadas, ${dependencies.modified_count} modificadas -- mismo escaneo que arriba.`
        : `${dependencies.added_count} added, ${dependencies.removed_count} removed, ${dependencies.modified_count} modified -- same scan as above.`)}</h4>
      ${hasDependencyChanges ? `
      <div class="admin-embedded-table-scroll">
        <table class="impact-breakdown-table admin-changes-table">
          <thead><tr>
            <th>${es ? 'Cambio' : 'Change'}</th>
            <th>${es ? 'Relación' : 'Relationship'}</th>
            <th>${es ? 'Tipo' : 'Type'}</th>
          </tr></thead>
          <tbody>${dependencies.changes.map(c => `
            <tr>
              <td><span class="admin-change-type-chip is-${escapeHtml(c.event_type)}">${escapeHtml((CHANGE_EVENT_LABELS[c.event_type] || { [state.lang]: c.event_type })[state.lang])}</span></td>
              <td class="admin-dependency-change-edge">${escapeHtml(c.from_qualified_name)} <span aria-hidden="true">→</span> ${escapeHtml(c.to_qualified_name)}</td>
              <td>${escapeHtml(c.relationship_type)}${c.scope_label ? ` <span class="admin-session-row-email">· ${escapeHtml(c.scope_label)}</span>` : ''}</td>
            </tr>`).join('')}</tbody>
        </table>
      </div>` : `<div class="scan-history-empty">${es ? 'Sin cambios de dependencias en este escaneo.' : 'No dependency changes in this scan.'}</div>`}
      ${(dependencies.total_count || 0) > dependencies.changes.length ? `<p class="admin-field-hint">${es
        ? `${dependencies.total_count - dependencies.changes.length} cambios más no mostrados`
        : `${dependencies.total_count - dependencies.changes.length} more changes not shown`}</p>` : ''}
    </div>
  `;
}

async function loadAdminChangesDigest(scanStartedAt, dateFrom, dateTo) {
  try {
    const params = new URLSearchParams();
    if (dateFrom) params.set('from', dateFrom);
    if (dateTo) params.set('to', dateTo);
    if (!dateFrom && !dateTo && scanStartedAt) params.set('scan', scanStartedAt);
    const qs = params.toString();
    const url = `${TRIGGER_SERVER_ORIGIN}/api/admin/changes-digest${qs ? `?${qs}` : ''}`;
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminChangesDigestCache = await response.json();
  } catch (error) {
    adminChangesDigestCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  if (adminActiveTab === 'changes') renderAdminPanel();
}

// Purview-style classification chips (2026-08-18): sensitivity categories
// as a grid of colored tiles (dot + label + count badge), same visual
// language Purview's own classification/info-type views use, instead of
// plain text inside a generic disclosure -- each category gets a stable
// color from this rotation (by position, since categories are already in
// a fixed, backend-defined order every render).
const ADMIN_SENSITIVITY_CATEGORY_COLOR_TOKENS = ['blue', 'teal', 'violet', 'amber', 'red', 'green'];

function adminSensitivityCategoryColor(index) {
  return `var(--${ADMIN_SENSITIVITY_CATEGORY_COLOR_TOKENS[index % ADMIN_SENSITIVITY_CATEGORY_COLOR_TOKENS.length]})`;
}

// Redesigned 2026-08-25 (explicit admin-panel request): one rich, dynamic
// TABLE instead of a category-pill grid opening a modal per click -- every
// row here already passed NB_Discover_Column_Sensitivity.py's name-based
// pre-filter (Paso 0, see that notebook's own comment), so this is no
// longer "confirmed vs unconfirmed", it's "here's exactly what checking
// each flagged column's real content found", with risk/recommendation and
// up to 20 real example values per column (see that notebook's "CAMBIO DE
// POLÍTICA DE PRIVACIDAD" comment for why real values are shown now,
// admin-only, click-to-reveal rather than always on screen).
const SENSITIVITY_RISK_ORDER = { very_high: 3, high: 2, medium: 1, low: 0 };

function renderContentSensitivityOverviewSection() {
  const es = state.lang === 'es';
  if (adminContentSensitivityOverviewCache === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminContentSensitivityOverviewCache;
  if (!data.found) {
    return `<div class="scan-history-empty">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</div>`;
  }
  const rows = data.categories.flatMap((cat, catIndex) => cat.samples.map(sample => ({ cat, catIndex, sample })));
  rows.sort((a, b) => {
    const riskDiff = (SENSITIVITY_RISK_ORDER[b.cat.risk] ?? -1) - (SENSITIVITY_RISK_ORDER[a.cat.risk] ?? -1);
    if (riskDiff !== 0) return riskDiff;
    return (b.sample.match_percentage ?? -1) - (a.sample.match_percentage ?? -1);
  });
  return `
    <p class="admin-field-hint">${es
      ? `${data.flagged_column_count} columnas revisadas por contenido real en ${data.checked_table_count} tablas -- cada una ya pasó primero el filtro por nombre de columna, así que esto solo muestrea lo que ya parecía sospechoso. Alcance limitado a Lakehouses Fabric-nativas ya perfiladas, no todo el tenant.`
      : `${data.flagged_column_count} columns reviewed by real content across ${data.checked_table_count} tables -- each one already passed the column-name filter first, so only what already looked suspicious gets sampled. Scoped to already-profiled Fabric-native Lakehouses, not the whole tenant.`}</p>
    ${rows.length ? `
    <div class="admin-embedded-table-scroll">
      <table class="impact-breakdown-table admin-sensitivity-content-table">
        <thead><tr>
          <th>${es ? 'Categoría' : 'Category'}</th>
          <th>${es ? 'Tabla / columna' : 'Table / column'}</th>
          <th>${es ? 'Contenido real' : 'Real content'}</th>
          <th>${es ? 'Riesgo' : 'Risk'}</th>
          <th title="Dynamic Data Masking / Row-Level Security / Column-Level Security">DDM / RLS / CLS</th>
          <th>${es ? 'Acceso' : 'Access'}</th>
          <th></th>
        </tr></thead>
        <tbody>${rows.map(({ cat, catIndex, sample }, index) => {
          const rowId = `admin-sensitivity-row-${index}`;
          const matchCell = sample.has_content_pattern
            ? `<span class="admin-sensitivity-match-pill ${sample.match_percentage > 0 ? 'is-hit' : 'is-clean'}">${sample.match_percentage}%</span>`
            : `<span class="admin-sensitivity-match-pill is-unverifiable">${es ? 'ver ejemplos' : 'see examples'}</span>`;
          const exampleCount = (sample.sample_values || []).length;
          return `
          <tr>
            <td><span class="admin-sensitivity-row-category" style="--cat-color: ${adminSensitivityCategoryColor(catIndex)}"><span class="admin-sensitivity-category-dot"></span>${escapeHtml(es ? cat.label_es : cat.label_en)}</span></td>
            <td>
              <div>${escapeHtml(sample.table_name)}.<strong>${escapeHtml(sample.column_name)}</strong></div>
              <span class="admin-session-row-email">${escapeHtml(sample.workspace_name)} / ${escapeHtml(sample.lakehouse_name)}</span>
            </td>
            <td>${matchCell}</td>
            <td><span class="admin-sensitivity-risk-pill risk-${escapeHtml(cat.risk || 'medium')}">${escapeHtml(es ? cat.risk_label_es : cat.risk_label_en)}</span></td>
            <td>${sensitivitySecurityCellHtml(sample, es)}</td>
            <td>${sensitivityAccessCellHtml(sample.workspace_name, es)}</td>
            <td><button type="button" class="admin-button-secondary" data-toggle-sensitivity-samples="${rowId}">${es ? `Ver ${exampleCount} ejemplos` : `See ${exampleCount} examples`}</button></td>
          </tr>
          <tr class="admin-sensitivity-detail-row" id="${rowId}" hidden>
            <td colspan="7">
              <p class="admin-field-hint"><strong>${es ? 'Recomendación' : 'Recommendation'}:</strong> ${escapeHtml(es ? cat.recommendation_es : cat.recommendation_en)}</p>
              ${exampleCount ? `
              <p class="admin-field-hint">${es
                ? `Ejemplos reales, muestra de ${sample.sample_size} filas -- solo visible para administradores.`
                : `Real examples, sampled from ${sample.sample_size} rows -- admin-only.`}</p>
              <div class="admin-sensitivity-sample-chips">${(sample.sample_values || []).map(v => `<span class="admin-sensitivity-sample-chip">${escapeHtml(v)}</span>`).join('')}</div>
              ` : `<p class="admin-field-hint">${es ? 'Sin ejemplos guardados todavía -- vuelve a escanear esta tabla.' : 'No examples stored yet -- re-scan this table.'}</p>`}
            </td>
          </tr>`;
        }).join('')}</tbody>
      </table>
    </div>` : `<div class="scan-history-empty">${es ? 'Sin columnas revisadas todavía.' : 'No columns reviewed yet.'}</div>`}
  `;
}

function renderAdminSensitivityOverviewTab() {
  const es = state.lang === 'es';
  if (adminSensitivityOverviewCache === null) {
    return `<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminSensitivityOverviewCache;
  const nameBasedSection = !data.found ? `<div class="scan-history-empty">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</div>` : `
    <p class="admin-field-hint">${es
      ? `${data.flagged_object_count} de ${data.total_object_count} tablas/vistas catalogadas tienen columnas que coinciden con un patrón de dato sensible (email, DNI, etc.) -- por nombre de columna, no por contenido real: revísalas, no las trates como confirmadas.`
      : `${data.flagged_object_count} of ${data.total_object_count} catalogued tables/views have columns matching a sensitive-data pattern (email, national ID, etc.) -- by column name, not real content: review these, don't treat them as confirmed.`}</p>
    <div class="admin-sensitivity-categories">
      ${data.categories.map((cat, index) => `
      <button type="button" class="admin-sensitivity-category" style="--cat-color: ${adminSensitivityCategoryColor(index)}"
        data-sensitivity-section="name" data-sensitivity-category="${escapeHtml(cat.category)}">
        <span class="admin-sensitivity-category-summary">
          <span class="admin-sensitivity-category-dot"></span>
          <span class="admin-sensitivity-category-label">${escapeHtml(es ? cat.label_es : cat.label_en)}</span>
          <span class="admin-sensitivity-category-count">${cat.object_count}</span>
        </span>
      </button>`).join('')}
    </div>
  `;
  // Two distinct signals, clearly labeled (2026-08-18, roadmap Fase 2
  // follow-through): the original name-pattern heuristic above (any
  // catalogued object, tenant-wide, unconfirmed) and the newer content-
  // verified one below (Fabric-native Lakehouse tables only, but each hit
  // is a real regex match against sampled cell values) -- until this was
  // added, an admin here had no way to know the more precise signal even
  // existed (it only showed up per-object in the main detail panel).
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Por nombre de columna (fuera de alcance del escaneo de contenido, o pendiente)' : 'By column name (outside content-scan reach, or pending)'}${adminInfoIconHtml(es
        ? 'Tenant-wide, por patrón de nombre -- el escaneo de contenido real de abajo solo puede alcanzar los Lakehouses donde la cuenta de servicio ya tiene rol de datos. Marca tablas aquí y pulsa "Escanear contenido" para intentar confirmarlas por contenido real la próxima vez que se pueda.'
        : "Tenant-wide, by name pattern -- the real-content scan below can only reach Lakehouses the service principal already has a data role in. Check tables here and click \"Scan content\" to try confirming them by real content next time it's reachable.")}</h4>
      ${nameBasedSection}
      ${sensitivityScanSelection.size ? `
      <div class="admin-fabric-connection-test-row">
        <button type="button" class="admin-save-button" data-sensitivity-scan-selected="1">${es
          ? `Escanear contenido de las ${sensitivityScanSelection.size} seleccionadas`
          : `Scan content for the ${sensitivityScanSelection.size} selected`}</button>
        <button type="button" class="admin-button-secondary" data-sensitivity-clear-selection="1">${es ? 'Limpiar selección' : 'Clear selection'}</button>
        <span class="admin-test-result" data-test-result="sensitivity-scan-selected"></span>
      </div>` : ''}
    </div>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Contenido real, columna por columna' : 'Real content, column by column'}</h4>
      ${renderContentSensitivityOverviewSection()}
    </div>
  `;
}

async function triggerSensitivityScanSelected() {
  const resultEl = document.querySelector('[data-test-result="sensitivity-scan-selected"]');
  if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'Lanzando...' : 'Starting...'; resultEl.className = 'admin-test-result'; }
  const columns = Array.from(sensitivityScanSelection.values()).map(entry => ({
    workspace_name: entry.workspace_name, table_name: entry.table_name,
  }));
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/sensitivity/scan-selected`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ columns }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (resultEl) { resultEl.textContent = payload.message || `HTTP ${response.status}`; resultEl.className = 'admin-test-result fail'; }
      return;
    }
    if (resultEl) {
      resultEl.textContent = state.lang === 'es' ? 'Escaneo lanzado en Fabric.' : 'Scan started in Fabric.';
      resultEl.className = 'admin-test-result ok';
    }
    sensitivityScanSelection.clear();
    renderGovernancePanelIfOpen();
  } catch (error) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

function sensitivityCategoryLookup(section, categoryKey) {
  const cache = section === 'content' ? adminContentSensitivityOverviewCache : adminSensitivityOverviewCache;
  if (!cache || !cache.found) return null;
  return cache.categories.find(entry => entry.category === categoryKey) || null;
}

// Keyed by workspace_name (all the sensitivity samples carry), not id --
// caches the fetch PROMISE, not just the resolved value, so opening the
// same category modal twice in a row (or two categories that share a
// workspace) never fires a second request for a name already in flight.
async function fetchWorkspaceRoles(workspaceName) {
  if (!workspaceName) return { found: false, assignment_count: 0, assignments: [] };
  if (workspaceRolesCache.has(workspaceName)) return workspaceRolesCache.get(workspaceName);
  const promise = fetch(`${TRIGGER_SERVER_ORIGIN}/api/workspace-roles?workspace_name=${encodeURIComponent(workspaceName)}`)
    .then(response => { if (!response.ok) throw new Error(`HTTP ${response.status}`); return response.json(); })
    .catch(() => ({ found: false, assignment_count: 0, assignments: [] }));
  workspaceRolesCache.set(workspaceName, promise);
  return promise;
}

// Resolves every "Personas con acceso" button under containerEl in
// parallel, one fetch per DISTINCT workspace (a category's rows routinely
// repeat the same handful of workspaces across dozens of tables).
async function resolveSensitivityAccessCounts(containerEl) {
  if (!containerEl) return;
  const buttons = Array.from(containerEl.querySelectorAll('[data-workspace-access]'));
  const uniqueNames = Array.from(new Set(buttons.map(btn => btn.dataset.workspaceAccess).filter(Boolean)));
  await Promise.all(uniqueNames.map(async name => {
    const result = await fetchWorkspaceRoles(name);
    const count = result && result.found ? result.assignment_count : 0;
    buttons.filter(btn => btn.dataset.workspaceAccess === name).forEach(btn => {
      btn.textContent = number(count);
      btn.classList.toggle('impact-count-empty', count === 0);
      btn.disabled = count === 0;
    });
  }));
}

// Real DDM (sys.masked_columns), RLS (sys.security_predicates), and CLS
// (sys.column_permissions) findings from NB_Extract_SQL_Endpoint_Catalog
// (2026-08-24) -- see purview_insights._get_column_security_lookup. Only
// covers Lakehouse/Warehouse/SQLDatabase objects whose SQL endpoint has
// actually been scanned; security_scanned distinguishes "checked, found
// nothing" from "never checked" so an unscanned object never silently
// reads as confirmed-clean.
function sensitivitySecurityCellHtml(sample, es) {
  if (!sample.security_scanned) {
    const hint = es ? 'DDM/RLS/CLS aún no se ha escaneado para este tenant.' : "DDM/RLS/CLS hasn't been scanned for this tenant yet.";
    return `<span class="sensitivity-security-undetected" title="${escapeHtml(hint)}">${escapeHtml(es ? 'Sin comprobar' : 'Not checked')}</span>`;
  }
  const flags = [];
  if (sample.security_ddm) flags.push('DDM');
  if (sample.security_rls) flags.push('RLS');
  if (sample.security_cls) flags.push('CLS');
  if (!flags.length) {
    return `<span class="sensitivity-security-clean">${escapeHtml(es ? 'Sin protección detectada' : 'No protection detected')}</span>`;
  }
  return `<span class="sensitivity-security-flagged" title="${escapeHtml(sample.security_detail || '')}">${escapeHtml(flags.join(' + '))}</span>`;
}

// Shared by both sections now that _get_sensitivity_overview also resolves
// workspace_name when the object is a confirmed Fabric-internal one (see
// build_graph_map_index.py's workspace_name field, 2026-08-24) -- most
// "por nombre de columna" objects still won't have one (genuinely external,
// or Fabric-internal but not yet catalog-confirmed), so an empty/unresolved
// workspace shows a plain dash instead of a dead button.
function sensitivityAccessCellHtml(workspaceName, es) {
  if (!workspaceName) {
    const hint = es ? 'Sin workspace de Fabric confirmado para este objeto.' : 'No confirmed Fabric workspace for this object.';
    return `<span class="sensitivity-security-undetected" title="${escapeHtml(hint)}">—</span>`;
  }
  return `<button type="button" class="impact-count-badge" data-workspace-access="${escapeHtml(workspaceName)}" disabled>…</button>`;
}

function renderSensitivityDetailModal(section, categoryKey) {
  if (!els.sensitivityDetailModal) return;
  const es = state.lang === 'es';
  const cat = sensitivityCategoryLookup(section, categoryKey);
  if (!cat) {
    els.sensitivityDetailTitle.textContent = categoryKey;
    els.sensitivityDetailSubtitle.textContent = '';
    els.sensitivityDetailBody.innerHTML = `<p>${escapeHtml(es ? 'Sin datos.' : 'No data.')}</p>`;
    return;
  }
  const label = es ? cat.label_es : cat.label_en;

  if (section === 'name') {
    els.sensitivityDetailTitle.textContent = `${label} · ${number(cat.object_count)}`;
    els.sensitivityDetailSubtitle.textContent = es
      ? 'Por nombre de columna, sin confirmar -- puede incluir objetos externos y objetos internos de Fabric aún sin workspace confirmado. Marca cuáles escanear por contenido real (Fase 6).'
      : "By column name, unconfirmed -- may include external objects and internal Fabric objects not yet confirmed to a workspace. Check which ones to scan by real content (Fase 6).";
    els.sensitivityDetailBody.innerHTML = `
      <table class="impact-breakdown-table">
        <thead><tr>
          <th></th>
          <th>${es ? 'Objeto' : 'Object'}</th>
          <th>${es ? 'Servidor origen' : 'Source server'}</th>
          <th>${es ? 'Base de datos' : 'Database'}</th>
          <th>${es ? 'Personas con acceso' : 'People with access'}</th>
        </tr></thead>
        <tbody>${cat.samples.map(s => `
          <tr>
            <td><input type="checkbox" data-sensitivity-select-table="1" data-workspace-name="${escapeHtml(s.workspace_name)}" data-table-label="${escapeHtml(s.label)}" ${sensitivityScanSelection.has(sensitivitySelectionKey(s.workspace_name, s.label)) ? 'checked' : ''} /></td>
            <td>${escapeHtml(s.label)}</td>
            <td>${escapeHtml(s.source_server)}</td>
            <td>${escapeHtml(s.source_database)}</td>
            <td>${sensitivityAccessCellHtml(s.workspace_name, es)}</td>
          </tr>`).join('')}</tbody>
      </table>
    `;
    resolveSensitivityAccessCounts(els.sensitivityDetailBody);
    return;
  }

  els.sensitivityDetailTitle.textContent = `${label} · ${number(cat.column_count)}`;
  els.sensitivityDetailSubtitle.textContent = `${cat.table_count} ${es ? 'tablas' : 'tables'}`;
  const ddmHint = es
    ? 'DDM = Dynamic Data Masking, RLS = seguridad a nivel de fila, CLS = permisos a nivel de columna -- todos consultados en vivo contra el SQL endpoint (sys.masked_columns / sys.security_predicates / sys.column_permissions).'
    : 'DDM = Dynamic Data Masking, RLS = row-level security, CLS = column-level permissions -- all queried live against the SQL endpoint (sys.masked_columns / sys.security_predicates / sys.column_permissions).';
  els.sensitivityDetailBody.innerHTML = `
    <table class="impact-breakdown-table">
      <thead><tr>
        <th>${es ? 'Tabla' : 'Table'}</th>
        <th>${es ? 'Columna' : 'Column'}</th>
        <th>Lakehouse / Warehouse</th>
        <th>${es ? '% coincidencia' : '% match'}</th>
        <th title="${escapeHtml(ddmHint)}">${es ? 'DDM / seguridad' : 'DDM / security'} ⓘ</th>
        <th>${es ? 'Personas con acceso' : 'People with access'}</th>
      </tr></thead>
      <tbody>${cat.samples.map(s => `
        <tr>
          <td>${escapeHtml(s.table_name)}</td>
          <td>${escapeHtml(s.column_name)}</td>
          <td>${escapeHtml(s.lakehouse_name)}</td>
          <td>${s.match_percentage}%</td>
          <td>${sensitivitySecurityCellHtml(s, es)}</td>
          <td>${sensitivityAccessCellHtml(s.workspace_name, es)}</td>
        </tr>`).join('')}</tbody>
    </table>
  `;
  resolveSensitivityAccessCounts(els.sensitivityDetailBody);
}

function toggleSensitivityDetailModal(forceOpen, section, categoryKey) {
  if (!els.sensitivityDetailModal) return;
  const shouldOpen = typeof forceOpen === 'boolean' ? forceOpen : els.sensitivityDetailModal.hidden;
  if (shouldOpen) {
    sensitivityDetailState = { section, categoryKey };
    renderSensitivityDetailModal(section, categoryKey);
    pushStackedModal(els.sensitivityDetailModal);
  } else {
    if (stackedModals[stackedModals.length - 1] === els.sensitivityDetailModal) popStackedModal();
    else els.sensitivityDetailModal.hidden = true; // defensive fallback, shouldn't happen (its own close button is covered while workspaceAccessModal sits on top)
    sensitivityDetailState = null;
  }
}

async function renderWorkspaceAccessModal(workspaceName) {
  if (!els.workspaceAccessModal) return;
  const es = state.lang === 'es';
  els.workspaceAccessTitle.textContent = workspaceName;
  els.workspaceAccessSubtitle.textContent = es ? 'Cargando...' : 'Loading...';
  els.workspaceAccessBody.innerHTML = '';
  const result = await fetchWorkspaceRoles(workspaceName);
  if (!workspaceAccessState || workspaceAccessState.workspaceName !== workspaceName) return; // closed/replaced while awaiting
  if (!result || !result.found) {
    els.workspaceAccessSubtitle.textContent = '';
    els.workspaceAccessBody.innerHTML = `<p>${escapeHtml(es ? 'Sin datos de acceso para este workspace.' : 'No access data for this workspace.')}</p>`;
    return;
  }
  els.workspaceAccessSubtitle.textContent = es
    ? `${number(result.assignment_count)} personas/entidades con acceso`
    : `${number(result.assignment_count)} people/entities with access`;
  els.workspaceAccessBody.innerHTML = `
    <table class="impact-breakdown-table">
      <thead><tr>
        <th>${es ? 'Nombre' : 'Name'}</th>
        <th>${es ? 'Correo' : 'Email'}</th>
        <th>${es ? 'Tipo' : 'Type'}</th>
        <th>${es ? 'Rol' : 'Role'}</th>
      </tr></thead>
      <tbody>${result.assignments.map(a => `
        <tr>
          <td>${escapeHtml(a.principal_name)}</td>
          <td>${escapeHtml(a.principal_email)}</td>
          <td>${escapeHtml(a.principal_type)}</td>
          <td>${escapeHtml(a.role)}</td>
        </tr>`).join('')}</tbody>
    </table>
  `;
}

function toggleWorkspaceAccessModal(forceOpen, workspaceName) {
  if (!els.workspaceAccessModal) return;
  const shouldOpen = typeof forceOpen === 'boolean' ? forceOpen : els.workspaceAccessModal.hidden;
  if (shouldOpen) {
    workspaceAccessState = { workspaceName };
    renderWorkspaceAccessModal(workspaceName);
    pushStackedModal(els.workspaceAccessModal);
  } else {
    if (stackedModals[stackedModals.length - 1] === els.workspaceAccessModal) popStackedModal();
    else els.workspaceAccessModal.hidden = true; // defensive fallback, shouldn't happen
    workspaceAccessState = null;
  }
}

// 5000 (the backend's own max, see handler.py's _parse_sensitivity_sample_limit)
// instead of the endpoints' lightweight default of 15 -- the detail modal
// (see toggleSensitivityDetailModal) needs every real hit, not just enough
// to preview the category, and re-fetching per click would mean re-reading
// the same bronze table/CSV on every single pill click for no reason.
const SENSITIVITY_DETAIL_SAMPLE_LIMIT = 5000;

async function loadAdminSensitivityOverview() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/sensitivity-overview?sample_limit=${SENSITIVITY_DETAIL_SAMPLE_LIMIT}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminSensitivityOverviewCache = await response.json();
  } catch (error) {
    adminSensitivityOverviewCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  renderGovernancePanelIfOpen();
}

async function loadAdminContentSensitivityOverview() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/content-sensitivity-overview?sample_limit=${SENSITIVITY_DETAIL_SAMPLE_LIMIT}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminContentSensitivityOverviewCache = await response.json();
  } catch (error) {
    adminContentSensitivityOverviewCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  renderGovernancePanelIfOpen();
}

// --- Server metrics (2026-08-14 redesign): in-memory request counts by
// (method, path, status_code), reset on server restart -- same
// lazy-load-on-first-open pattern as the tabs above. Backend already
// existed (observability.py) with no UI at all until now.

// 2026-08-18, admin-panel completeness pass: the thinnest of the Insights
// tabs -- raw counts with no error-rate rollup and no way to isolate
// errors beyond eyeballing the row coloring. Both additions are pure
// client-side derivations of data already in adminMetricsCache, no new
// backend route needed.
let adminMetricsStatusFilter = 'all'; // 'all' | '2xx' | '3xx' | '4xx' | '5xx'

// Status-class donut (2026-08-18): built as a conic-gradient rather than
// SVG/canvas -- no library, no extra request, and the color stops are
// trivial to compute from the same status-class counts the filter buttons
// already group by. True slice-growth animation doesn't interpolate
// reliably across browsers for conic-gradient, so the "animated" part is
// an honest fade+scale reveal of the whole donut instead (see the
// .admin-metrics-donut-in CSS animation) rather than a fake data claim.
const ADMIN_METRICS_STATUS_COLORS = { '2xx': 'var(--green)', '3xx': 'var(--muted)', '4xx': 'var(--amber)', '5xx': 'var(--red)' };

function buildAdminMetricsDonutGradient(countsByClass, total) {
  if (!total) return 'var(--panel-soft)';
  let cumulative = 0;
  const stops = [];
  ['2xx', '3xx', '4xx', '5xx'].forEach(cls => {
    const count = countsByClass[cls] || 0;
    if (!count) return;
    const startDeg = (cumulative / total) * 360;
    cumulative += count;
    const endDeg = (cumulative / total) * 360;
    stops.push(`${ADMIN_METRICS_STATUS_COLORS[cls]} ${startDeg}deg ${endDeg}deg`);
  });
  return stops.length ? `conic-gradient(${stops.join(', ')})` : 'var(--panel-soft)';
}

// Reusable interactive time-series bar chart (2026-08-25 Analíticas
// redesign) -- pure CSS/HTML, no charting library: each bar's height is a
// percentage of the series max, and carries a data-tooltip the CSS hover
// rule (.admin-bar-chart-bar[data-tooltip]:hover::after) renders as a
// floating label -- the exact value on hover, without canvas/SVG or a
// mouse-tracking JS handler. Used for every day-by-day series on this
// tab (lineage usage, MCP calls) so they all look and behave the same.
function renderBarChart(series, opts = {}) {
  const es = state.lang === 'es';
  if (!series.length) return `<div class="scan-history-empty">${opts.emptyText || (es ? 'Sin datos.' : 'No data.')}</div>`;
  const max = Math.max(1, ...series.map(d => d.value));
  const formatValue = opts.formatValue || number;
  const tickFormat = opts.tickFormat || (label => label);
  // Every bar always renders (and keeps its hover tooltip with the exact
  // value) -- only the TICK LABEL below wide charts is thinned to every
  // Nth one, otherwise a 90-day window overlaps into an unreadable smear.
  // ~12 visible labels fits comfortably at this chart's typical width.
  const maxVisibleTicks = 12;
  const tickStep = Math.max(1, Math.ceil(series.length / maxVisibleTicks));
  return `
    <div class="admin-bar-chart" role="img" aria-label="${escapeHtml(opts.ariaLabel || '')}">
      ${series.map((d, i) => `
        <div class="admin-bar-chart-col">
          <div class="admin-bar-chart-bar" style="height: ${Math.max(3, Math.round((d.value / max) * 100))}%" data-tooltip="${escapeHtml(d.label)}: ${escapeHtml(formatValue(d.value))}"></div>
          <span class="admin-bar-chart-tick">${(i % tickStep === 0 || i === series.length - 1) ? escapeHtml(tickFormat(d.label)) : ''}</span>
        </div>`).join('')}
    </div>`;
}

// Horizontal ranked-bar row (name always fully readable, bar communicates
// relative magnitude) -- same .admin-capacity-bar-track/-fill pattern the
// pre-existing "top items"/capacity tabs already use, reused here for
// every "top N by count" list on this tab instead of inventing a second
// visual language for the same kind of data.
function renderRankedBarRows(rows, opts = {}) {
  const es = state.lang === 'es';
  if (!rows.length) return `<div class="scan-history-empty">${opts.emptyText || (es ? 'Sin datos.' : 'No data.')}</div>`;
  const max = Math.max(1, ...rows.map(r => r.value));
  return `<div class="admin-list">${rows.map(r => `
    <div class="admin-list-row admin-ranked-row">
      <span class="admin-metrics-row-path">
        <span class="admin-metrics-row-path-text">${escapeHtml(r.label)}${r.sublabel ? ` <span class="admin-session-row-email">${escapeHtml(r.sublabel)}</span>` : ''}</span>
        <span class="admin-capacity-bar-track"><span class="admin-capacity-bar-fill" style="width: ${Math.round((r.value / max) * 100)}%"></span></span>
      </span>
      <span class="admin-metrics-row-count">${number(r.value)}</span>
    </div>`).join('')}</div>`;
}

const ANALYTICS_DAY_WINDOWS = [7, 30, 90];

function renderAnalyticsDaysFilter() {
  const es = state.lang === 'es';
  return `<div class="admin-metrics-filter-row" role="group" aria-label="${es ? 'Ventana de tiempo' : 'Time window'}">
    ${ANALYTICS_DAY_WINDOWS.map(d => `<button type="button" class="admin-metrics-filter-button${adminAnalyticsDays === d ? ' active' : ''}" data-analytics-days="${d}">${es ? `${d} días` : `${d} days`}</button>`).join('')}
  </div>`;
}

// Lineage-USAGE analytics (2026-08-24 Fase 6) -- what the tab's own name
// ("Analíticas", renamed from "Métricas del servidor" in Fase 1) actually
// promised: real usage of the explorer itself, not just server-request
// plumbing (see renderAdminMetricsTab below for that, kept as a secondary
// card). Backed by bronze_usage_events (analytics.py), a permanent
// Warehouse table -- unlike the request counter, this survives a restart/
// redeploy, so it's the only place on this tab with any TIME dimension.
function formatShortDayTick(day) {
  // "2026-08-25" -> "25 ago" (es) / "Aug 25" (en) -- full ISO dates as
  // x-axis labels for a 90-day chart would either overlap illegibly or
  // need rotation; a short day+month reads fine at chart width.
  const parts = (day || '').split('-');
  if (parts.length !== 3) return day;
  const monthNamesEs = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
  const monthNamesEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const monthIndex = parseInt(parts[1], 10) - 1;
  const dayNum = parseInt(parts[2], 10);
  const monthName = (state.lang === 'es' ? monthNamesEs : monthNamesEn)[monthIndex] || parts[1];
  return state.lang === 'es' ? `${dayNum} ${monthName}` : `${monthName} ${dayNum}`;
}

function renderUsageAnalyticsSection() {
  const es = state.lang === 'es';
  if (adminUsageAnalyticsCache === null) {
    return `<div class="admin-card"><h4 class="admin-card-title">${es ? 'Uso del linaje' : 'Lineage usage'}</h4><div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div></div>`;
  }
  const data = adminUsageAnalyticsCache;
  if (!data.found) {
    return `<div class="admin-card"><h4 class="admin-card-title">${es ? 'Uso del linaje' : 'Lineage usage'}</h4><div class="scan-history-empty">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</div></div>`;
  }
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Uso del linaje' : 'Lineage usage'}${adminInfoIconHtml(es
        ? 'Cada vez que alguien abre el detalle de un elemento en el explorador se registra un evento, con quién y cuándo -- permanente en el Warehouse, sobrevive a un reinicio o redeploy (a diferencia del resumen de peticiones de abajo).'
        : "Every time someone opens an item's detail panel in the explorer, an event is recorded, with who and when -- permanent in the Warehouse, survives a restart or redeploy (unlike the request summary below).")}</h4>
      ${renderAnalyticsDaysFilter()}
      <p class="admin-field-hint">${es
        ? `${number(data.total_event_count)} eventos registrados · ${number(data.unique_user_count)} usuarios distintos.`
        : `${number(data.total_event_count)} events recorded · ${number(data.unique_user_count)} distinct users.`}</p>
      ${renderBarChart(data.daily_series.map(d => ({ label: d.day, value: d.count })), {
        ariaLabel: es ? 'Eventos por día' : 'Events per day',
        tickFormat: formatShortDayTick,
        emptyText: es ? 'Sin eventos en esta ventana.' : 'No events in this window.',
      })}
    </div>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Elementos más vistos' : 'Most viewed items'}</h4>
      <div class="admin-embedded-table-scroll">
        <table class="impact-breakdown-table">
          <thead><tr><th>${es ? 'Elemento' : 'Item'}</th><th>${es ? 'Tipo' : 'Type'}</th><th>${es ? 'Vistas' : 'Views'}</th></tr></thead>
          <tbody>${data.top_items.length ? data.top_items.map(item => {
            const maxItemViews = Math.max(1, ...data.top_items.map(i => i.view_count));
            return `
            <tr>
              <td><strong>${escapeHtml(item.qualified_name)}</strong></td>
              <td>${escapeHtml(item.item_type || '—')}</td>
              <td>
                <span class="admin-metrics-row-path">
                  <span class="admin-capacity-bar-track"><span class="admin-capacity-bar-fill" style="width: ${Math.round((item.view_count / maxItemViews) * 100)}%"></span></span>
                  <span class="admin-metrics-row-count">${number(item.view_count)}</span>
                </span>
              </td>
            </tr>`;
          }).join('') : `<tr><td colspan="3"><div class="scan-history-empty">${es ? 'Sin vistas registradas todavía.' : 'No views recorded yet.'}</div></td></tr>`}</tbody>
        </table>
      </div>
    </div>
  `;
}

async function loadAdminUsageAnalytics() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/usage-analytics?days=${adminAnalyticsDays}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminUsageAnalyticsCache = await response.json();
  } catch (error) {
    adminUsageAnalyticsCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  if (adminActiveTab === 'metrics') renderAdminPanel();
}

// Peticiones MCP (2026-08-25) -- usage of the remote MCP server
// (backend/scripts/mcp_http_server.py), same bronze_usage_events table
// and permanence guarantee as the lineage-usage section above, filtered
// to mcp_tool_call rows server-side (analytics.get_mcp_usage_analytics).
function renderMcpUsageSection() {
  const es = state.lang === 'es';
  if (adminMcpUsageCache === null) {
    return `<div class="admin-card"><h4 class="admin-card-title">${es ? 'Peticiones MCP' : 'MCP requests'}</h4><div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div></div>`;
  }
  const data = adminMcpUsageCache;
  if (!data.found) {
    return `<div class="admin-card"><h4 class="admin-card-title">${es ? 'Peticiones MCP' : 'MCP requests'}${adminInfoIconHtml(es
      ? 'Cada llamada a una herramienta del servidor MCP remoto (pestaña API keys) queda registrada aquí, con qué clave la hizo -- ver docs/110_mcp_remote_setup.md.'
      : "Every call to a tool on the remote MCP server (API keys tab) is recorded here, with which key made it -- see docs/110_mcp_remote_setup.md.")}</h4><div class="scan-history-empty">${escapeHtml(data.reason || (es ? 'Sin datos.' : 'No data.'))}</div></div>`;
  }
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Peticiones MCP' : 'MCP requests'}${adminInfoIconHtml(es
        ? 'Cada llamada a una herramienta del servidor MCP remoto (pestaña API keys) queda registrada aquí, con qué clave la hizo.'
        : 'Every call to a tool on the remote MCP server (API keys tab) is recorded here, with which key made it.')}</h4>
      ${renderAnalyticsDaysFilter()}
      <p class="admin-field-hint">${es
        ? `${number(data.total_call_count)} llamadas registradas · ${number(data.unique_caller_count)} agente${data.unique_caller_count === 1 ? '' : 's'}/clave${data.unique_caller_count === 1 ? '' : 's'} distintos.`
        : `${number(data.total_call_count)} calls recorded · ${number(data.unique_caller_count)} distinct agent${data.unique_caller_count === 1 ? '' : 's'}/key${data.unique_caller_count === 1 ? '' : 's'}.`}</p>
      ${renderBarChart(data.daily_series.map(d => ({ label: d.day, value: d.count })), {
        ariaLabel: es ? 'Llamadas MCP por día' : 'MCP calls per day',
        tickFormat: formatShortDayTick,
        emptyText: es ? 'Sin llamadas en esta ventana.' : 'No calls in this window.',
      })}
    </div>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Herramientas más llamadas' : 'Most-called tools'}</h4>
      ${renderRankedBarRows(data.calls_by_tool.map(t => ({ label: t.tool_name, value: t.call_count })), {
        emptyText: es ? 'Sin llamadas todavía.' : 'No calls yet.',
      })}
    </div>
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Por agente / clave' : 'By agent / key'}${adminInfoIconHtml(es
        ? 'Un agente MCP no tiene sesión de usuario -- se identifica por el nombre de la API key con la que se conectó.'
        : "An MCP agent has no user session -- it's identified by the name of the API key it connected with.")}</h4>
      ${renderRankedBarRows(data.calls_by_caller.map(c => ({ label: c.caller, value: c.call_count })), {
        emptyText: es ? 'Sin llamadas todavía.' : 'No calls yet.',
      })}
    </div>
  `;
}

async function loadAdminMcpUsage() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/mcp-usage-analytics?days=${adminAnalyticsDays}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminMcpUsageCache = await response.json();
  } catch (error) {
    adminMcpUsageCache = { found: false, reason: state.lang === 'es' ? 'No se pudo cargar.' : 'Could not load.' };
  }
  if (adminActiveTab === 'metrics') renderAdminPanel();
}

// Conexiones externas (2026-08-25) -- purely a client-side rollup of
// adminSettingsCache.external_sources, already fully loaded for the
// Sources tab (fabric_connection_last_test_status/_at, set by "Probar
// conexión (vía Fabric)" there) -- no new backend route needed, this tab
// just gives that same data a summary view instead of duplicating a read.
function renderExternalConnectionsSection() {
  const es = state.lang === 'es';
  const sources = adminSettingsCache.external_sources || [];
  if (!sources.length) {
    return `<div class="admin-card"><h4 class="admin-card-title">${es ? 'Conexiones externas' : 'External connections'}</h4><div class="scan-history-empty">${es ? 'Sin orígenes externos configurados todavía -- pestaña "Orígenes externos".' : 'No external sources configured yet -- "External sources" tab.'}</div></div>`;
  }
  const statusOf = s => s.fabric_connection_last_test_status === 'Online' ? 'online' : (s.fabric_connection_last_test_status === 'Offline' ? 'offline' : 'untested');
  const counts = { online: 0, offline: 0, untested: 0 };
  sources.forEach(s => { counts[statusOf(s)] += 1; });
  return `
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Conexiones externas' : 'External connections'}${adminInfoIconHtml(es
        ? 'Estado de la última prueba de conexión (vía gateway de Fabric) de cada origen externo configurado en la pestaña "Orígenes externos".'
        : 'Last connection-test status (via the Fabric gateway) for each external source configured on the "External sources" tab.')}</h4>
      <div class="admin-changes-summary-pills">
        <span class="admin-count-pill is-created">${number(counts.online)} <em>Online</em></span>
        <span class="admin-count-pill is-removed">${number(counts.offline)} <em>Offline</em></span>
        <span class="admin-count-pill is-modified">${number(counts.untested)} <em>${es ? 'sin probar' : 'untested'}</em></span>
      </div>
      <div class="admin-embedded-table-scroll">
        <table class="impact-breakdown-table">
          <thead><tr>
            <th>${es ? 'Origen' : 'Source'}</th>
            <th>${es ? 'Tipo' : 'Type'}</th>
            <th>${es ? 'Host / cuenta' : 'Host / account'}</th>
            <th>${es ? 'Estado' : 'Status'}</th>
            <th>${es ? 'Última prueba' : 'Last tested'}</th>
          </tr></thead>
          <tbody>${sources.map(s => {
            const status = statusOf(s);
            const typeConfig = EXTERNAL_SOURCE_TYPES.find(c => c.value === s.type);
            return `
            <tr>
              <td><strong>${escapeHtml(s.name || _externalSourceIdentifierForDisplay(s))}</strong></td>
              <td>${escapeHtml((typeConfig && typeConfig.label) || s.type || '—')}</td>
              <td>${escapeHtml(s.host || s.account || s.project_id || s.file_path || s.site_url || '—')}</td>
              <td><span class="admin-change-type-chip is-${status === 'online' ? 'added' : (status === 'offline' ? 'removed' : 'modified')}">${status === 'online' ? 'Online' : (status === 'offline' ? 'Offline' : (es ? 'Sin probar' : 'Untested'))}</span></td>
              <td>${s.fabric_connection_last_test_at ? escapeHtml(formatAdminSessionTimestamp(s.fabric_connection_last_test_at)) : '—'}</td>
            </tr>`;
          }).join('')}</tbody>
        </table>
      </div>
    </div>
  `;
}

function renderAdminMetricsTab() {
  const es = state.lang === 'es';
  const usageSection = renderUsageAnalyticsSection();
  const mcpSection = renderMcpUsageSection();
  const externalSection = renderExternalConnectionsSection();
  const upperSections = `${usageSection}${mcpSection}${externalSection}`;
  if (adminMetricsCache === null) {
    return `${upperSections}<div class="scan-history-empty">${es ? 'Cargando...' : 'Loading...'}</div>`;
  }
  const data = adminMetricsCache;
  if (!data.routes || !data.routes.length) {
    return `${upperSections}<div class="scan-history-empty">${es ? 'Sin tráfico registrado todavía en esta ejecución del servidor.' : 'No traffic recorded yet in this server run.'}</div>`;
  }
  const total = data.routes.reduce((sum, row) => sum + row.count, 0);
  const countsByClass = { '2xx': 0, '3xx': 0, '4xx': 0, '5xx': 0 };
  data.routes.forEach(row => {
    const cls = `${String(row.status_code)[0]}xx`;
    if (cls in countsByClass) countsByClass[cls] += row.count;
  });
  const errorCount = countsByClass['4xx'] + countsByClass['5xx'];
  const errorRate = total > 0 ? Math.round((errorCount / total) * 1000) / 10 : 0;
  const statusClasses = ['all', '2xx', '3xx', '4xx', '5xx'];
  const maxRowCount = Math.max(1, ...data.routes.map(row => row.count));
  const visibleRows = adminMetricsStatusFilter === 'all'
    ? data.routes
    : data.routes.filter(row => `${String(row.status_code)[0]}xx` === adminMetricsStatusFilter);
  return `
    ${upperSections}
    <div class="admin-card">
      <h4 class="admin-card-title">${es ? 'Resumen' : 'Summary'}${adminInfoIconHtml(es
        ? 'Cuenta las peticiones HTTP que ha recibido este servidor desde la última vez que arrancó -- no es un histórico permanente, se reinicia con el proceso.'
        : "Counts HTTP requests this server has received since it last started -- not a permanent history, resets with the process.")}</h4>
      <div class="admin-metrics-donut-wrap">
        <div class="admin-metrics-donut admin-metrics-donut-in" style="background: ${buildAdminMetricsDonutGradient(countsByClass, total)}">
          <div class="admin-metrics-donut-hole">
            <strong>${number(total)}</strong>
            <span>${es ? 'peticiones' : 'requests'}</span>
          </div>
        </div>
        <div class="admin-metrics-donut-legend">
          ${['2xx', '3xx', '4xx', '5xx'].filter(cls => countsByClass[cls] > 0).map(cls => `
            <div class="admin-metrics-donut-legend-item">
              <span class="admin-metrics-donut-legend-swatch admin-metrics-status-${cls}"></span>
              <span>${cls}</span>
              <strong>${number(countsByClass[cls])}</strong>
              <span class="admin-session-row-email">(${Math.round((countsByClass[cls] / total) * 1000) / 10}%)</span>
            </div>`).join('')}
          <p class="admin-field-hint">${es
            ? `Desde ${escapeHtml(formatAdminSessionTimestamp(data.since))} · ${errorRate}% 4xx/5xx.`
            : `Since ${escapeHtml(formatAdminSessionTimestamp(data.since))} · ${errorRate}% 4xx/5xx.`}</p>
        </div>
      </div>
    </div>
    <details class="admin-card admin-metrics-routes-details">
      <summary class="admin-card-title admin-metrics-routes-summary">${es ? 'Todas las rutas' : 'All routes'} <span class="admin-session-row-email">(${data.routes.length})</span></summary>
      <div class="admin-metrics-filter-row" role="group" aria-label="${es ? 'Filtrar por estado' : 'Filter by status'}">
        ${statusClasses.map(cls => `<button type="button" class="admin-metrics-filter-button${adminMetricsStatusFilter === cls ? ' active' : ''}" data-metrics-filter="${cls}">${cls === 'all' ? (es ? 'Todos' : 'All') : cls}</button>`).join('')}
      </div>
      <div class="admin-list">${visibleRows.map(row => `
        <div class="admin-list-row admin-metrics-row">
          <span class="admin-metrics-row-method">${escapeHtml(row.method)}</span>
          <span class="admin-metrics-row-path">
            <span class="admin-metrics-row-path-text">${escapeHtml(row.path)}</span>
            <span class="admin-capacity-bar-track"><span class="admin-capacity-bar-fill" style="width: ${Math.round((row.count / maxRowCount) * 100)}%"></span></span>
          </span>
          <span class="admin-metrics-row-status admin-metrics-status-${String(row.status_code)[0]}xx">${row.status_code}</span>
          <span class="admin-metrics-row-count">${number(row.count)}</span>
        </div>`).join('')}</div>
    </details>
  `;
}

async function loadAdminMetrics() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/metrics`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    adminMetricsCache = await response.json();
  } catch (error) {
    adminMetricsCache = { since: '', routes: [] };
  }
  if (adminActiveTab === 'metrics') renderAdminPanel();
}

// --- Tanda C (2026-07-09): certifications + business glossary -----------
// Both are admin-curated lists living directly on adminSettingsCache
// (config/admin_settings.json's certified_items/business_glossary) --
// edited in place and saved via the existing /api/admin/settings POST,
// the same pattern the "sources" tab already uses for external_sources.

function renderAdminCertificationsTab() {
  const es = state.lang === 'es';
  const items = adminSettingsCache.certified_items || [];
  return `
    <p class="admin-field-hint">${es
      ? 'Marca un item como fuente oficial/certificada -- se ve como un anillo dorado en el mapa de dependencias, además de en su panel de detalle. Útil cuando hay informes duplicados y no está claro cuál es el bueno.'
      : "Mark an item as an official/certified source -- shows as a gold ring in the dependency map, plus in its own detail panel. Useful when there are duplicate reports and it's unclear which one is the real one."}</p>
    <div class="admin-list">${items.map((entry, index) => `
      <div class="admin-list-row admin-certification-row" data-cert-index="${index}">
        <input type="text" data-cert-field="qualified_name" data-cert-index="${index}" value="${escapeHtml(entry.qualified_name || '')}" placeholder="${es ? 'Workspace / Tipo / Nombre' : 'Workspace / Type / Name'}" list="qualifiedNameSuggestions" autocomplete="off" data-qualified-name-autocomplete="1" />
        <input type="text" data-cert-field="note" data-cert-index="${index}" value="${escapeHtml(entry.note || '')}" placeholder="${es ? 'Nota (opcional)' : 'Note (optional)'}" />
        <button type="button" class="admin-list-row-remove" data-remove-cert="${index}">×</button>
      </div>`).join('')}</div>
    <button type="button" class="admin-save-button" data-add-cert="1">${es ? '+ Añadir certificación' : '+ Add certification'}</button>
    <button type="button" class="admin-save-button" data-admin-save="certifications">${es ? 'Guardar' : 'Save'}</button>
  `;
}

function renderAdminGlossaryTab() {
  const es = state.lang === 'es';
  const terms = adminSettingsCache.business_glossary || [];
  return `
    <p class="admin-field-hint">${es
      ? 'Términos de negocio reales (no los conceptos técnicos de la herramienta, que viven en el otro glosario) enlazados a los activos que los representan. Visible para cualquier usuario con sesión iniciada, en el panel "Qué significa esto".'
      : "Real business terms (not the tool's own technical concepts, which live in the other glossary) linked to the assets that represent them. Visible to any signed-in user, in the \"What does this mean\" panel."}</p>
    <div class="admin-list">${terms.map((entry, index) => `
      <div class="admin-glossary-entry-row" data-glossary-index="${index}">
        <div class="admin-field"><label>${es ? 'Término (ES)' : 'Term (ES)'}</label><input type="text" data-glossary-field="term_es" data-glossary-index="${index}" value="${escapeHtml(entry.term_es || '')}" /></div>
        <div class="admin-field"><label>${es ? 'Término (EN)' : 'Term (EN)'}</label><input type="text" data-glossary-field="term_en" data-glossary-index="${index}" value="${escapeHtml(entry.term_en || '')}" /></div>
        <div class="admin-field"><label>${es ? 'Definición (ES)' : 'Definition (ES)'}</label><textarea data-glossary-field="definition_es" data-glossary-index="${index}" rows="2">${escapeHtml(entry.definition_es || '')}</textarea></div>
        <div class="admin-field"><label>${es ? 'Definición (EN)' : 'Definition (EN)'}</label><textarea data-glossary-field="definition_en" data-glossary-index="${index}" rows="2">${escapeHtml(entry.definition_en || '')}</textarea></div>
        <div class="admin-field">
          <label>${es ? 'Activos enlazados' : 'Linked assets'}</label>
          <div class="admin-chip-list">${(entry.linked_qualified_names || []).map((name, chipIndex) => `
            <span class="admin-chip">${escapeHtml(name)}<button type="button" class="admin-chip-remove" data-remove-glossary-asset="${index}" data-remove-glossary-asset-chip="${chipIndex}" aria-label="${es ? 'Quitar' : 'Remove'}">×</button></span>
          `).join('') || `<span class="admin-field-hint">${es ? 'Ninguno todavía.' : 'None yet.'}</span>`}</div>
          <div class="admin-chip-add-row">
            <input type="text" data-glossary-asset-input="${index}" list="qualifiedNameSuggestions" autocomplete="off" data-qualified-name-autocomplete="1" placeholder="${es ? 'Workspace / Tipo / Nombre' : 'Workspace / Type / Name'}" />
            <button type="button" data-add-glossary-asset="${index}">${es ? '+ Añadir' : '+ Add'}</button>
          </div>
        </div>
        <button type="button" class="admin-list-row-remove" data-remove-glossary="${index}">${es ? 'Borrar término' : 'Delete term'}</button>
      </div>`).join('')}</div>
    <button type="button" class="admin-save-button" data-add-glossary="1">${es ? '+ Añadir término' : '+ Add term'}</button>
    <button type="button" class="admin-save-button" data-admin-save="business_glossary">${es ? 'Guardar' : 'Save'}</button>
  `;
}

// Roadmap Fase 2 (2026-08-17): free-form tags, same admin-curated-list
// pattern as certifications just above -- a plain qualified_name+tag pair
// an admin edits by hand, baked into the graph map's node data by
// build_graph_map_index.py/onelake_data.py the same way certified_items is.
function renderAdminTagsTab() {
  const es = state.lang === 'es';
  const items = adminSettingsCache.tags || [];
  return `
    <p class="admin-field-hint">${es
      ? 'Etiqueta libre por item (ej. "Finanzas", "Deprecado", "Revisar") -- se ve en el mapa de dependencias y es buscable ahí. Un mismo item puede tener varias etiquetas.'
      : 'A free-form tag on an item (e.g. "Finance", "Deprecated", "Needs review") -- shown in the dependency map and searchable there. The same item can have several tags.'}</p>
    <div class="admin-list">${items.map((entry, index) => `
      <div class="admin-list-row admin-tag-row" data-tag-index="${index}">
        <input type="text" data-tag-field="qualified_name" data-tag-index="${index}" value="${escapeHtml(entry.qualified_name || '')}" placeholder="${es ? 'Workspace / Tipo / Nombre' : 'Workspace / Type / Name'}" list="qualifiedNameSuggestions" autocomplete="off" data-qualified-name-autocomplete="1" />
        <input type="text" data-tag-field="tag" data-tag-index="${index}" value="${escapeHtml(entry.tag || '')}" placeholder="${es ? 'Etiqueta' : 'Tag'}" />
        <button type="button" class="admin-list-row-remove" data-remove-tag="${index}">×</button>
      </div>`).join('')}</div>
    <button type="button" class="admin-save-button" data-add-tag="1">${es ? '+ Añadir etiqueta' : '+ Add tag'}</button>
    <button type="button" class="admin-save-button" data-admin-save="tags">${es ? 'Guardar' : 'Save'}</button>
  `;
}

// Roadmap Fase 1 (2026-08-31, Purview-parity push): mirrors backend/
// scripts/lineage_web/data_quality.py's RULE_TYPES -- 3 fixed entries,
// unlikely to grow, so a hand-kept mirror is simpler than a round trip
// just to fetch this dict.
const DATA_QUALITY_RULE_TYPES = {
  null_percentage_max: { es: '% de nulos como máximo', en: 'Null % at most', scope: 'column' },
  distinct_count_min: { es: 'Valores distintos como mínimo', en: 'Distinct values at least', scope: 'column' },
  row_count_min: { es: 'Filas como mínimo', en: 'Rows at least', scope: 'table' },
};

function dataQualityRuleTypeLabel(key) {
  const meta = DATA_QUALITY_RULE_TYPES[key];
  if (!meta) return key;
  return state.lang === 'es' ? meta.es : meta.en;
}

function dataQualityStatusBadgeHtml(status, es) {
  const labels = {
    passed: es ? 'Cumple' : 'Passed',
    failed: es ? 'Falla' : 'Failed',
    not_profiled: es ? 'Sin perfilar' : 'Not profiled',
    invalid_rule: es ? 'Regla inválida' : 'Invalid rule',
  };
  return `<span class="admin-quality-badge admin-quality-badge-${status}">${escapeHtml(labels[status] || status)}</span>`;
}

// Same admin-curated-list pattern as certifications/tags/glossary above --
// the one difference: this list also drives a live tenant-wide pass/fail
// evaluation (adminDataQualityOverviewCache, loaded by
// loadAdminDataQualityOverview()) rendered above the editable rule list,
// since "what does this rule set currently say" is the whole point of
// defining rules in the first place, not just storing them.
function renderAdminDataQualityTab() {
  const es = state.lang === 'es';
  const rules = adminSettingsCache.data_quality_rules || [];
  const overview = adminDataQualityOverviewCache;

  const summaryHtml = !overview
    ? `<p class="admin-field-hint">${es ? 'Cargando...' : 'Loading...'}</p>`
    : !overview.found
      ? `<p class="admin-field-hint">${escapeHtml(overview.reason || (es ? 'Sin datos.' : 'No data.'))}</p>`
      : `
        <div class="admin-quality-summary">
          <div class="admin-quality-stat admin-quality-stat-pass"><span class="n">${overview.passed_count}</span><span class="label">${es ? 'Cumplen' : 'Passed'}</span></div>
          <div class="admin-quality-stat admin-quality-stat-fail"><span class="n">${overview.failed_count}</span><span class="label">${es ? 'Fallan' : 'Failed'}</span></div>
          <div class="admin-quality-stat admin-quality-stat-gap"><span class="n">${overview.not_profiled_count}</span><span class="label">${es ? 'Sin perfilar' : 'Not profiled'}</span></div>
          <div class="admin-quality-stat"><span class="n">${overview.pass_rate === null || overview.pass_rate === undefined ? '—' : overview.pass_rate + '%'}</span><span class="label">${es ? 'Tasa de éxito' : 'Pass rate'}</span></div>
        </div>
        <div class="admin-embedded-table-scroll"><table class="admin-quality-table">
          <thead><tr>
            <th>${es ? 'Regla' : 'Rule'}</th>
            <th>${es ? 'Objetivo' : 'Target'}</th>
            <th>${es ? 'Umbral' : 'Threshold'}</th>
            <th>${es ? 'Valor real' : 'Actual'}</th>
            <th>${es ? 'Estado' : 'Status'}</th>
          </tr></thead>
          <tbody>${overview.rules.map(r => `
            <tr>
              <td>${escapeHtml(dataQualityRuleTypeLabel(r.rule_type))}</td>
              <td>${escapeHtml([r.workspace_name, r.lakehouse_name, r.table_name, r.column_name].filter(Boolean).join(' / '))}</td>
              <td>${escapeHtml(String(r.threshold))}</td>
              <td>${r.actual_value === null || r.actual_value === undefined ? '—' : escapeHtml(String(r.actual_value))}</td>
              <td>${dataQualityStatusBadgeHtml(r.status, es)}</td>
            </tr>`).join('')}</tbody>
        </table></div>
      `;

  return `
    <p class="admin-field-hint">${es
      ? 'Reglas de calidad al estilo Purview, evaluadas contra los datos que el perfilado de columnas ya recoge (NB_Discover_Column_Profile.py) -- sin nuevo escaneo. "Sin perfilar" significa que esa tabla/columna aún no se ha perfilado, no cuenta como fallo.'
      : 'Purview-style quality rules, evaluated against data column profiling already collects (NB_Discover_Column_Profile.py) -- no new scan. "Not profiled" means that table/column hasn\'t been profiled yet, it does not count as a failure.'}</p>
    ${summaryHtml}
    <div class="admin-list">${rules.map((rule, index) => `
      <div class="admin-list-row admin-quality-rule-row" data-quality-rule-index="${index}">
        <select data-quality-field="rule_type" data-quality-rule-index="${index}">
          ${Object.keys(DATA_QUALITY_RULE_TYPES).map(key => `<option value="${key}" ${rule.rule_type === key ? 'selected' : ''}>${escapeHtml(dataQualityRuleTypeLabel(key))}</option>`).join('')}
        </select>
        <input type="text" data-quality-field="workspace_name" data-quality-rule-index="${index}" value="${escapeHtml(rule.workspace_name || '')}" placeholder="Workspace" list="qualifiedNameSuggestions" />
        <input type="text" data-quality-field="lakehouse_name" data-quality-rule-index="${index}" value="${escapeHtml(rule.lakehouse_name || '')}" placeholder="Lakehouse" />
        <input type="text" data-quality-field="table_name" data-quality-rule-index="${index}" value="${escapeHtml(rule.table_name || '')}" placeholder="${es ? 'Tabla (dbo.Tabla)' : 'Table (dbo.Table)'}" />
        <input type="text" data-quality-field="column_name" data-quality-rule-index="${index}" value="${escapeHtml(rule.column_name || '')}" placeholder="${es ? 'Columna (vacío = toda la tabla)' : 'Column (empty = whole table)'}" />
        <input type="number" step="any" data-quality-field="threshold" data-quality-rule-index="${index}" value="${rule.threshold === undefined || rule.threshold === null ? '' : rule.threshold}" placeholder="${es ? 'Umbral' : 'Threshold'}" />
        <input type="text" data-quality-field="note" data-quality-rule-index="${index}" value="${escapeHtml(rule.note || '')}" placeholder="${es ? 'Nota (opcional)' : 'Note (optional)'}" />
        <button type="button" class="admin-list-row-remove" data-remove-quality-rule="${index}">×</button>
      </div>`).join('')}</div>
    <button type="button" class="admin-save-button" data-add-quality-rule="1">${es ? '+ Añadir regla' : '+ Add rule'}</button>
    <button type="button" class="admin-save-button" data-admin-save="data_quality_rules">${es ? 'Guardar' : 'Save'}</button>
  `;
}

// Roadmap Fase 2 (2026-08-31, same Purview-parity push): mirrors
// backend/scripts/lineage_web/sensitivity_classifier.py's RISK_LABELS --
// 4 fixed entries, unlikely to grow, same hand-kept-mirror reasoning as
// DATA_QUALITY_RULE_TYPES above.
const SENSITIVITY_RISK_LABELS = {
  low: { es: 'Bajo', en: 'Low' },
  medium: { es: 'Medio', en: 'Medium' },
  high: { es: 'Alto', en: 'High' },
  very_high: { es: 'Muy alto', en: 'Very high' },
};

// Custom sensitivity categories an admin adds on top of the 9 built into
// sensitivity_classifier.py -- same admin-curated-list pattern as
// certifications/tags/data_quality_rules above, rendered as stacked-field
// cards (reusing .admin-glossary-entry-row) rather than one dense row,
// since there are 7 meaningful fields here including two free-text
// recommendations. Applies immediately to the Governance panel's by-NAME
// sensitivity detection (no rescan needed, see sensitivity_classifier.py's
// own docstring) -- content-based detection does NOT use these yet, which
// the hint text below says plainly rather than silently overpromising.
function renderAdminSensitivityCategoriesTab() {
  const es = state.lang === 'es';
  const items = adminSettingsCache.custom_sensitivity_categories || [];
  return `
    <p class="admin-field-hint">${es
      ? 'Categorías de sensibilidad propias, añadidas a las 9 ya incluidas (email, teléfono, DNI, datos financieros...). Aplican al instante a la detección "por nombre" del panel de Gobernanza -- no hace falta reescanear. La detección "por contenido" no las usa todavía (necesitaría actualizar el notebook de escaneo y volver a escanear).'
      : 'Custom sensitivity categories, added on top of the 9 already built in (email, phone, national ID, financial data...). Apply immediately to the Governance panel\'s by-NAME detection -- no rescan needed. Content-based detection doesn\'t use them yet (would need updating the scan notebook and rescanning).'}</p>
    <div class="admin-list">${items.map((entry, index) => `
      <div class="admin-glossary-entry-row" data-sens-category-index="${index}">
        <div class="admin-field"><label>${es ? 'Clave (única, sin espacios, distinta de las 9 ya usadas)' : 'Key (unique, no spaces, different from the 9 already used)'}</label><input type="text" data-sens-category-field="key" data-sens-category-index="${index}" value="${escapeHtml(entry.key || '')}" placeholder="${es ? 'ej. id_interno' : 'e.g. internal_id'}" /></div>
        <div class="admin-field"><label>${es ? 'Etiqueta (ES)' : 'Label (ES)'}</label><input type="text" data-sens-category-field="label_es" data-sens-category-index="${index}" value="${escapeHtml(entry.label_es || '')}" /></div>
        <div class="admin-field"><label>${es ? 'Etiqueta (EN)' : 'Label (EN)'}</label><input type="text" data-sens-category-field="label_en" data-sens-category-index="${index}" value="${escapeHtml(entry.label_en || '')}" /></div>
        <div class="admin-field"><label>${es ? 'Patrones (expresiones regulares, separadas por coma)' : 'Patterns (regular expressions, comma-separated)'}</label><input type="text" data-sens-category-field="patterns" data-sens-category-index="${index}" value="${escapeHtml((entry.patterns || []).join(', '))}" placeholder="\\bid_interno\\b, internal_ref" /></div>
        <div class="admin-field"><label>${es ? 'Riesgo' : 'Risk'}</label>
          <select data-sens-category-field="risk" data-sens-category-index="${index}">
            ${Object.keys(SENSITIVITY_RISK_LABELS).map(key => `<option value="${key}" ${(entry.risk || 'medium') === key ? 'selected' : ''}>${escapeHtml(SENSITIVITY_RISK_LABELS[key][state.lang === 'es' ? 'es' : 'en'])}</option>`).join('')}
          </select>
        </div>
        <div class="admin-field"><label>${es ? 'Recomendación (ES)' : 'Recommendation (ES)'}</label><textarea data-sens-category-field="recommendation_es" data-sens-category-index="${index}" rows="2">${escapeHtml(entry.recommendation_es || '')}</textarea></div>
        <div class="admin-field"><label>${es ? 'Recomendación (EN)' : 'Recommendation (EN)'}</label><textarea data-sens-category-field="recommendation_en" data-sens-category-index="${index}" rows="2">${escapeHtml(entry.recommendation_en || '')}</textarea></div>
        <button type="button" class="admin-list-row-remove" data-remove-sens-category="${index}">${es ? 'Borrar categoría' : 'Delete category'}</button>
      </div>`).join('')}</div>
    <button type="button" class="admin-save-button" data-add-sens-category="1">${es ? '+ Añadir categoría' : '+ Add category'}</button>
    <button type="button" class="admin-save-button" data-admin-save="custom_sensitivity_categories">${es ? 'Guardar' : 'Save'}</button>
  `;
}

// Roadmap Fase 3 (2026-08-31, same Purview-parity push): Purview's
// Unified Catalog groups assets into "data products" with an owner and a
// description -- named "data products" (not "domains") on purpose here,
// since Fabric's own native per-workspace "Domain" field (data.domain_name,
// shown as the "Dominio" row above) is a different, already-real, already-
// scanned concept; reusing that word for this admin-curated grouping would
// collide with it. Closest existing precedent is the business glossary
// just above -- same linked_qualified_names chip-list shape, same card
// layout, adapted field names.
function renderAdminDataProductsTab() {
  const es = state.lang === 'es';
  const products = adminSettingsCache.data_products || [];
  return `
    <p class="admin-field-hint">${es
      ? 'Agrupa items bajo un producto de datos con un dueño, cruzando workspaces -- ej. "Ventas Regionales" con varios informes/notebooks de distintos workspaces. Se ve en el panel de detalle de cada item enlazado.'
      : 'Groups items under a data product with an owner, cutting across workspaces -- e.g. "Regional Sales" spanning several reports/notebooks in different workspaces. Shown in the detail panel of every linked item.'}</p>
    <div class="admin-list">${products.map((entry, index) => `
      <div class="admin-glossary-entry-row" data-data-product-index="${index}">
        <div class="admin-field"><label>${es ? 'Nombre' : 'Name'}</label><input type="text" data-data-product-field="name" data-data-product-index="${index}" value="${escapeHtml(entry.name || '')}" /></div>
        <div class="admin-field"><label>${es ? 'Dueño (email)' : 'Owner (email)'}</label><input type="text" data-data-product-field="owner_email" data-data-product-index="${index}" value="${escapeHtml(entry.owner_email || '')}" placeholder="nombre@dominio.com" /></div>
        <div class="admin-field"><label>${es ? 'Descripción (ES)' : 'Description (ES)'}</label><textarea data-data-product-field="description_es" data-data-product-index="${index}" rows="2">${escapeHtml(entry.description_es || '')}</textarea></div>
        <div class="admin-field"><label>${es ? 'Descripción (EN)' : 'Description (EN)'}</label><textarea data-data-product-field="description_en" data-data-product-index="${index}" rows="2">${escapeHtml(entry.description_en || '')}</textarea></div>
        <div class="admin-field">
          <label>${es ? 'Activos enlazados' : 'Linked assets'}</label>
          <div class="admin-chip-list">${(entry.linked_qualified_names || []).map((name, chipIndex) => `
            <span class="admin-chip">${escapeHtml(name)}<button type="button" class="admin-chip-remove" data-remove-data-product-asset="${index}" data-remove-data-product-asset-chip="${chipIndex}" aria-label="${es ? 'Quitar' : 'Remove'}">×</button></span>
          `).join('') || `<span class="admin-field-hint">${es ? 'Ninguno todavía.' : 'None yet.'}</span>`}</div>
          <div class="admin-chip-add-row">
            <input type="text" data-data-product-asset-input="${index}" list="qualifiedNameSuggestions" autocomplete="off" data-qualified-name-autocomplete="1" placeholder="${es ? 'Workspace / Tipo / Nombre' : 'Workspace / Type / Name'}" />
            <button type="button" data-add-data-product-asset="${index}">${es ? '+ Añadir' : '+ Add'}</button>
          </div>
        </div>
        <button type="button" class="admin-list-row-remove" data-remove-data-product="${index}">${es ? 'Borrar producto de datos' : 'Delete data product'}</button>
      </div>`).join('')}</div>
    <button type="button" class="admin-save-button" data-add-data-product="1">${es ? '+ Añadir producto de datos' : '+ Add data product'}</button>
    <button type="button" class="admin-save-button" data-admin-save="data_products">${es ? 'Guardar' : 'Save'}</button>
  `;
}

// Roadmap Fase 6 (2026-08-31): mirrors backend/scripts/lineage_web/
// sensitivity_classifier.py's own SENSITIVITY_CATEGORIES es/en labels --
// 22 fixed entries, same hand-kept-mirror reasoning as DATA_QUALITY_
// RULE_TYPES/SENSITIVITY_RISK_LABELS above (a real round trip just to
// list category names in a <select> would be overkill for a set this
// stable). Keep in sync by hand if that Python dict's labels ever change.
const PRIVACY_CATEGORY_LABELS = {
  email: { es: 'Email', en: 'Email' },
  phone: { es: 'Teléfono', en: 'Phone' },
  national_id: { es: 'Identificación nacional', en: 'National ID' },
  person_name: { es: 'Nombre / apellidos', en: 'Person name' },
  address: { es: 'Dirección postal', en: 'Postal address' },
  birth_date: { es: 'Fecha de nacimiento', en: 'Birth date' },
  financial: { es: 'Datos financieros', en: 'Financial data' },
  health: { es: 'Datos de salud', en: 'Health data' },
  gender: { es: 'Género', en: 'Gender' },
  image_media: { es: 'Imagen / fotografía', en: 'Image / photo' },
  voice_recording: { es: 'Grabación de voz', en: 'Voice recording' },
  biometric: { es: 'Dato biométrico', en: 'Biometric data' },
  employment: { es: 'Situación laboral', en: 'Employment' },
  insurance: { es: 'Seguro', en: 'Insurance' },
  academic_record: { es: 'Expediente académico', en: 'Academic record' },
  marketing_consent: { es: 'Consentimiento de marketing', en: 'Marketing consent' },
  guardian_family: { es: 'Datos de familiares / tutores', en: 'Guardian / family data' },
  disciplinary_record: { es: 'Expediente disciplinario', en: 'Disciplinary record' },
  ai_processing_flag: { es: 'Uso en procesamiento de IA', en: 'AI processing flag' },
  third_party_sharing: { es: 'Compartición con terceros', en: 'Third-party sharing' },
  special_category_belief: { es: 'Categoría especial (creencias/origen)', en: 'Special category (beliefs/origin)' },
  technical_access: { es: 'Acceso técnico (IP/dispositivo)', en: 'Technical access (IP/device)' },
};

function privacyCategoryOptionsHtml(selectedKey, es) {
  // Built-in 22 first, then whatever custom categories exist -- a custom
  // category is just as valid a target for a "known external system"
  // entry as a built-in one.
  const customEntries = (adminSettingsCache.custom_sensitivity_categories || [])
    .map(entry => [entry.key, { es: entry.label_es || entry.key, en: entry.label_en || entry.label_es || entry.key }]);
  const allEntries = [...Object.entries(PRIVACY_CATEGORY_LABELS), ...customEntries];
  return allEntries.map(([key, labels]) =>
    `<option value="${key}" ${selectedKey === key ? 'selected' : ''}>${escapeHtml(labels[es ? 'es' : 'en'] || key)}</option>`
  ).join('');
}

// Roadmap Fase 6 (2026-08-31, follow-up to Fase 5's privacy locator):
// admin-maintained "known systems" per sensitivity category -- most of a
// real data-subject-rights request touches systems entirely OUTSIDE
// Fabric (biometric access control, a CRM, a marketing platform), which
// no automated scan here can ever reach. Plain hand-maintained checklist,
// same admin-curated-list pattern as everything else on this page --
// shown back to staff inside the Privacidad panel itself (renderPrivacy
// PanelFrameworkView), not just editable here.
function renderAdminPrivacySystemsTab() {
  const es = state.lang === 'es';
  const systems = adminSettingsCache.privacy_external_systems || [];
  return `
    <p class="admin-field-hint">${es
      ? 'Por cada categoría de dato sensible, qué sistemas (dentro o fuera de Fabric) es sabido que la contienen, y quién es responsable. Sin conexión automática a esos sistemas -- es un listado que mantiene una persona, pensado para cuando llega una solicitud real de derechos (RGPD/FERPA/CCPA) y hay que saber por dónde empezar a mirar.'
      : 'For each sensitive-data category, which systems (inside or outside Fabric) are known to hold it, and who\'s responsible. No automated connection to those systems -- a plain checklist a person maintains, meant for when a real rights request (GDPR/FERPA/CCPA) comes in and someone needs to know where to start looking.'}</p>
    <div class="admin-list">${systems.map((entry, index) => `
      <div class="admin-glossary-entry-row" data-privacy-system-index="${index}">
        <div class="admin-field"><label>${es ? 'Categoría de dato' : 'Data category'}</label>
          <select data-privacy-system-field="category" data-privacy-system-index="${index}">${privacyCategoryOptionsHtml(entry.category, es)}</select>
        </div>
        <div class="admin-field"><label>${es ? 'Sistema' : 'System'}</label><input type="text" data-privacy-system-field="system_name" data-privacy-system-index="${index}" value="${escapeHtml(entry.system_name || '')}" placeholder="${es ? 'ej. Control de acceso físico' : 'e.g. Physical access control'}" /></div>
        <div class="admin-field">
          <label><input type="checkbox" data-privacy-system-field="in_fabric" data-privacy-system-index="${index}" ${entry.in_fabric ? 'checked' : ''} /> ${es ? 'Vive dentro de Fabric' : 'Lives inside Fabric'}</label>
        </div>
        <div class="admin-field"><label>${es ? 'Responsable (nombre)' : 'Owner (name)'}</label><input type="text" data-privacy-system-field="owner_name" data-privacy-system-index="${index}" value="${escapeHtml(entry.owner_name || '')}" /></div>
        <div class="admin-field"><label>${es ? 'Responsable (email)' : 'Owner (email)'}</label><input type="text" data-privacy-system-field="owner_email" data-privacy-system-index="${index}" value="${escapeHtml(entry.owner_email || '')}" placeholder="nombre@dominio.com" /></div>
        <div class="admin-field"><label>${es ? 'Notas' : 'Notes'}</label><textarea data-privacy-system-field="notes" data-privacy-system-index="${index}" rows="2">${escapeHtml(entry.notes || '')}</textarea></div>
        <button type="button" class="admin-list-row-remove" data-remove-privacy-system="${index}">${es ? 'Borrar sistema' : 'Delete system'}</button>
      </div>`).join('')}</div>
    <button type="button" class="admin-save-button" data-add-privacy-system="1">${es ? '+ Añadir sistema' : '+ Add system'}</button>
    <button type="button" class="admin-save-button" data-admin-save="privacy_external_systems">${es ? 'Guardar' : 'Save'}</button>
  `;
}

// Shared by both the tab-click handler and loadAdminSettings() (opening
// the panel while the LAST-visited tab, e.g. "lakehouse", is still
// adminActiveTab from before -- no click event fires in that case, so
// without this the tab renders active but its data never loads at all;
// real report, 2026-07-21: reopening the admin panel a second time on the
// write-target tab left the workspace picker permanently empty).
function loadActiveAdminTabData() {
  if (adminActiveTab === 'sessions' && adminSessionsCache === null) loadAdminSessions();
  if (adminActiveTab === 'sessions' && adminSessionHistoryCache === null) loadAdminSessionHistory();
  if (adminActiveTab === 'lakehouse') loadAdminLakehouseWorkspaces();
  if (adminActiveTab === 'lakehouse' && adminWarehouseUploadHistoryCache === null) loadAdminWarehouseUploadHistory();
  if (adminActiveTab === 'pipeline') loadAdminPipelineWorkspaces();
  if (adminActiveTab === 'apikeys' && adminApiKeysCache === null) loadAdminApiKeys();
  if (adminActiveTab === 'capacity' && adminCapacityInsightCache === null) loadAdminCapacityInsight();
  if (adminActiveTab === 'capacity' && adminCapacityMetricsOverviewCache === null) loadAdminCapacityMetricsOverview();
  if (adminActiveTab === 'changes' && adminChangesDigestCache === null) loadAdminChangesDigest();
  if (adminActiveTab === 'metrics' && adminMetricsCache === null) loadAdminMetrics();
  if (adminActiveTab === 'metrics' && adminUsageAnalyticsCache === null) loadAdminUsageAnalytics();
  if (adminActiveTab === 'metrics' && adminMcpUsageCache === null) loadAdminMcpUsage();
  if (adminActiveTab === 'sources' && adminFabricConnectionsCache === null) loadAdminFabricConnections();
  if (adminActiveTab === 'sources' && adminDetectedExternalSourcesCache === null) loadDetectedExternalSources();
  if (adminActiveTab === 'dataquality' && adminDataQualityOverviewCache === null) loadAdminDataQualityOverview();
}

// Roadmap Fase 2 audit follow-through (2026-08-18): qualified_name fields
// in Certifications/Tags were plain free text with no link to the real
// catalog -- a typo silently certified/tagged nothing, with no feedback.
// A shared <datalist> (rendered once per renderAdminPanel() call, see
// "qualifiedNameSuggestions" in that function) backs every input with
// data-qualified-name-autocomplete, populated from the same /api/items
// search the rest of the app already uses -- debounced so typing doesn't
// fire a request per keystroke.
let qualifiedNameAutocompleteTimer = null;
const QUALIFIED_NAME_AUTOCOMPLETE_DEBOUNCE_MS = 250;

async function updateQualifiedNameSuggestions(query) {
  const datalist = document.getElementById('qualifiedNameSuggestions');
  if (!datalist) return;
  const trimmed = (query || '').trim();
  if (trimmed.length < 2) {
    datalist.innerHTML = '';
    return;
  }
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/items?query=${encodeURIComponent(trimmed)}&limit=15`);
    if (!response.ok) return;
    const payload = await response.json();
    datalist.innerHTML = (payload.items || []).map(item => `<option value="${escapeHtml(item.qualified_name)}"></option>`).join('');
  } catch (error) {
    // best-effort -- a failed suggestion fetch just means no autocomplete
    // this keystroke, not a hard error worth surfacing to the admin.
  }
}

function scheduleQualifiedNameSuggestions(query) {
  if (qualifiedNameAutocompleteTimer) window.clearTimeout(qualifiedNameAutocompleteTimer);
  qualifiedNameAutocompleteTimer = window.setTimeout(() => {
    qualifiedNameAutocompleteTimer = null;
    updateQualifiedNameSuggestions(query);
  }, QUALIFIED_NAME_AUTOCOMPLETE_DEBOUNCE_MS);
}

function wireAdminPanelEvents() {
  const closeButton = els.adminPanel.querySelector('[data-close-modal]');
  if (closeButton) closeButton.addEventListener('click', () => toggleAdminPanel(false));
  els.adminPanel.querySelectorAll('[data-qualified-name-autocomplete]').forEach(input => {
    input.addEventListener('input', () => scheduleQualifiedNameSuggestions(input.value));
  });
  els.adminPanel.querySelectorAll('[data-admin-list-filter]').forEach(input => {
    input.addEventListener('input', () => {
      const key = input.dataset.adminListFilter;
      adminListFilters[key] = input.value;
      renderAdminPanelPreservingFocus(`[data-admin-list-filter="${key}"]`, input.selectionStart, input.selectionEnd);
    });
  });
  els.adminPanel.querySelectorAll('[data-metrics-filter]').forEach(button => {
    button.addEventListener('click', () => {
      adminMetricsStatusFilter = button.dataset.metricsFilter;
      renderAdminPanel();
    });
  });
  els.adminPanel.querySelectorAll('[data-analytics-days]').forEach(button => {
    button.addEventListener('click', () => {
      const days = Number(button.dataset.analyticsDays);
      if (days === adminAnalyticsDays) return;
      adminAnalyticsDays = days;
      adminUsageAnalyticsCache = null;
      adminMcpUsageCache = null;
      renderAdminPanel();
      loadAdminUsageAnalytics();
      loadAdminMcpUsage();
    });
  });
  els.adminPanel.querySelectorAll('[data-changes-event-filter]').forEach(button => {
    button.addEventListener('click', () => {
      adminChangesEventTypeFilter = button.dataset.changesEventFilter;
      renderAdminPanel();
    });
  });
  const changesWorkspaceFilter = document.getElementById('adminChangesWorkspaceFilter');
  if (changesWorkspaceFilter) changesWorkspaceFilter.addEventListener('change', () => {
    adminChangesWorkspaceFilter = changesWorkspaceFilter.value;
    renderAdminPanel();
  });
  const changesItemTypeFilter = document.getElementById('adminChangesItemTypeFilter');
  if (changesItemTypeFilter) changesItemTypeFilter.addEventListener('change', () => {
    adminChangesItemTypeFilter = changesItemTypeFilter.value;
    renderAdminPanel();
  });
  const changesScanPicker = document.getElementById('adminChangesScanPicker');
  if (changesScanPicker) changesScanPicker.addEventListener('change', () => {
    adminChangesDigestCache = null;
    renderAdminPanel();
    loadAdminChangesDigest(changesScanPicker.value);
  });
  const changesApplyRangeButton = els.adminPanel.querySelector('[data-changes-apply-range]');
  if (changesApplyRangeButton) changesApplyRangeButton.addEventListener('click', () => {
    const from = document.getElementById('adminChangesDateFrom').value;
    const to = document.getElementById('adminChangesDateTo').value;
    adminChangesDigestCache = null;
    renderAdminPanel();
    loadAdminChangesDigest(null, from, to);
  });
  const changesSinceFirstFullButton = els.adminPanel.querySelector('[data-changes-since-first-full]');
  if (changesSinceFirstFullButton) changesSinceFirstFullButton.addEventListener('click', () => {
    const firstFullScanDate = (changesSinceFirstFullButton.dataset.changesSinceFirstFull || '').slice(0, 10);
    adminChangesDigestCache = null;
    renderAdminPanel();
    loadAdminChangesDigest(null, firstFullScanDate, null);
  });
  const changesClearRangeButton = els.adminPanel.querySelector('[data-changes-clear-range]');
  if (changesClearRangeButton) changesClearRangeButton.addEventListener('click', () => {
    adminChangesDigestCache = null;
    renderAdminPanel();
    loadAdminChangesDigest();
  });
  const gotoUsersTabButton = els.adminPanel.querySelector('[data-goto-users-tab]');
  if (gotoUsersTabButton) gotoUsersTabButton.addEventListener('click', () => {
    adminExpandedNavGroups.add('permissions');
    setAdminActiveTab('users');
    renderAdminPanel();
    loadActiveAdminTabData();
  });
  els.adminPanel.querySelectorAll('[data-admin-tab]').forEach(button => {
    button.addEventListener('click', () => {
      // The one-time key-reveal banner is only relevant right after
      // creating a key on the apikeys tab itself -- leaving the tab (even
      // to come straight back) means it's already been shown once.
      if (button.dataset.adminTab !== 'apikeys') adminJustCreatedApiKey = null;
      setAdminActiveTab(button.dataset.adminTab);
      renderAdminPanel();
      loadActiveAdminTabData();
    });
  });

  els.adminPanel.querySelectorAll('[data-toggle-nav-group]').forEach(button => {
    button.addEventListener('click', () => {
      const key = button.dataset.toggleNavGroup;
      if (adminExpandedNavGroups.has(key)) adminExpandedNavGroups.delete(key);
      else adminExpandedNavGroups.add(key);
      renderAdminPanel();
    });
  });

  const createApiKeyButton = els.adminPanel.querySelector('[data-create-api-key]');
  if (createApiKeyButton) createApiKeyButton.addEventListener('click', createAdminApiKey);
  els.adminPanel.querySelectorAll('[data-revoke-api-key]').forEach(button => {
    button.addEventListener('click', () => revokeAdminApiKey(button.dataset.revokeApiKey));
  });
  const copyApiKeyButton = els.adminPanel.querySelector('[data-copy-api-key]');
  if (copyApiKeyButton) copyApiKeyButton.addEventListener('click', async () => {
    if (!adminJustCreatedApiKey) return;
    try {
      await navigator.clipboard.writeText(adminJustCreatedApiKey.key);
      copyApiKeyButton.textContent = state.lang === 'es' ? 'Copiada' : 'Copied';
    } catch (error) {
      // Clipboard API can be unavailable (non-HTTPS, permissions) -- the
      // key is still selectable/visible in the <code> element either way.
    }
  });

  els.adminPanel.querySelectorAll('[data-revoke-session]').forEach(button => {
    button.addEventListener('click', () => revokeAdminSession(button.dataset.revokeSession));
  });

  const tenantSave = els.adminPanel.querySelector('[data-admin-save="tenant"]');
  if (tenantSave) tenantSave.addEventListener('click', () => {
    adminSettingsCache.tenant_id = document.getElementById('adminTenantId').value.trim();
    adminSettingsCache.entra_client_id = document.getElementById('adminClientId').value.trim();
    saveAdminSettings();
  });

  const lhItemTypeSelect = document.getElementById('adminLhItemType');
  if (lhItemTypeSelect) lhItemTypeSelect.addEventListener('change', () => {
    const lhWorkspaceSelectForType = document.getElementById('adminLhWorkspaceSelect');
    loadAdminLakehouseOptions(lhWorkspaceSelectForType ? lhWorkspaceSelectForType.value : '');
  });

  const lhWorkspaceSelect = document.getElementById('adminLhWorkspaceSelect');
  if (lhWorkspaceSelect) lhWorkspaceSelect.addEventListener('change', () => {
    loadAdminLakehouseOptions(lhWorkspaceSelect.value);
    // Fabric's own workspace-list API doesn't return a human capacity
    // name, only its id (see purview_insights.py's _capacity_label
    // comment) -- prefill with that id (real data, better than a blank
    // field) unless the admin already typed something of their own
    // (2026-08-18 admin-panel audit finding: capacity was the one field
    // left fully manual next to two others that resolve themselves).
    const capacityInput = document.getElementById('adminLhCapacity');
    const workspaceOption = (adminLakehouseWorkspaceOptions || []).find(w => w.workspace_id === lhWorkspaceSelect.value);
    if (capacityInput && !capacityInput.value.trim() && workspaceOption && workspaceOption.capacity_id) {
      capacityInput.value = workspaceOption.capacity_id;
    }
  });

  const lhLakehouseSelect = document.getElementById('adminLhLakehouseSelect');
  if (lhLakehouseSelect) lhLakehouseSelect.addEventListener('change', () => {
    const picked = adminLakehouseOptions.find(l => l.lakehouse_id === lhLakehouseSelect.value);
    const sqlEndpointInput = document.getElementById('adminLhSqlEndpoint');
    if (picked && sqlEndpointInput) sqlEndpointInput.value = picked.sql_endpoint_connection_string || '';
  });

  const lhAuthModeSelect = document.getElementById('adminLhAuthMode');
  if (lhAuthModeSelect) lhAuthModeSelect.addEventListener('change', () => {
    const spFields = document.getElementById('adminLhSpFields');
    if (spFields) spFields.hidden = lhAuthModeSelect.value !== 'service_principal';
  });

  const pipelineWorkspaceSelect = document.getElementById('adminPipelineWorkspaceSelect');
  if (pipelineWorkspaceSelect) pipelineWorkspaceSelect.addEventListener('change', () => loadAdminPipelineOptions(pipelineWorkspaceSelect.value));

  const pipelineSave = els.adminPanel.querySelector('[data-admin-save="discovery-pipeline"]');
  if (pipelineSave) pipelineSave.addEventListener('click', () => {
    const pipelineItemSelect = document.getElementById('adminPipelineItemSelect');
    const workspaceOption = (adminLakehouseWorkspaceOptions || []).find(w => w.workspace_id === (pipelineWorkspaceSelect && pipelineWorkspaceSelect.value));
    const pipelineOption = adminPipelineOptions.find(p => p.pipeline_id === (pipelineItemSelect && pipelineItemSelect.value));
    adminSettingsCache.discovery_pipeline = {
      mode: 'fabric_pipeline', // 2026-08-24: the only mode now, see Fase 1 cleanup
      workspace_id: pipelineWorkspaceSelect ? pipelineWorkspaceSelect.value : '',
      workspace_name: workspaceOption ? workspaceOption.workspace_name : (adminSettingsCache.discovery_pipeline || {}).workspace_name || '',
      pipeline_item_id: pipelineItemSelect ? pipelineItemSelect.value : '',
      pipeline_name: pipelineOption ? pipelineOption.pipeline_name : (adminSettingsCache.discovery_pipeline || {}).pipeline_name || '',
      sp_tenant_id: document.getElementById('adminPipelineSpTenantId').value.trim(),
      sp_client_id: document.getElementById('adminPipelineSpClientId').value.trim(),
      sp_client_secret_ref: document.getElementById('adminPipelineSpClientSecretRef').value.trim(),
    };
    saveAdminSettings();
  });

  const pipelineTest = els.adminPanel.querySelector('[data-test-discovery-pipeline]');
  if (pipelineTest) pipelineTest.addEventListener('click', testDiscoveryPipelineConnection);

  const oneLakeSave = els.adminPanel.querySelector('[data-admin-save="onelake-data"]');
  if (oneLakeSave) oneLakeSave.addEventListener('click', () => {
    const es = state.lang === 'es';
    const workspaceName = document.getElementById('adminOneLakeWorkspaceName').value.trim();
    const lakehouseName = document.getElementById('adminOneLakeLakehouseName').value.trim();
    const oneLakeResult = els.adminPanel.querySelector('[data-test-result="onelake"]');
    if (!workspaceName || !lakehouseName) {
      if (oneLakeResult) {
        oneLakeResult.textContent = es ? 'Workspace y Lakehouse son obligatorios.' : 'Workspace and Lakehouse are required.';
        oneLakeResult.className = 'admin-test-result fail';
      }
      return;
    }
    // 2026-08-24: no local-disk mode anymore -- always onelake, and the
    // auto-publish-after-a-LOCAL-full-scan setting is moot now that local
    // scans aren't how this project runs (see Fase 1 cleanup).
    adminSettingsCache.onelake_data = {
      mode: 'onelake',
      workspace_name: workspaceName,
      lakehouse_name: lakehouseName,
      auto_publish_after_scan: false,
      sp_tenant_id: document.getElementById('adminOneLakeSpTenantId').value.trim(),
      sp_client_id: document.getElementById('adminOneLakeSpClientId').value.trim(),
      sp_client_secret_ref: document.getElementById('adminOneLakeSpClientSecretRef').value.trim(),
    };
    saveAdminSettings();
  });

  const oneLakeTest = els.adminPanel.querySelector('[data-test-onelake]');
  if (oneLakeTest) oneLakeTest.addEventListener('click', testOneLakeConnection);

  const oneLakePublishButton = els.adminPanel.querySelector('[data-onelake-publish]');
  if (oneLakePublishButton) oneLakePublishButton.addEventListener('click', triggerOneLakePublishNow);

  const lakehouseSave = els.adminPanel.querySelector('[data-admin-save="lakehouse"]');
  if (lakehouseSave) lakehouseSave.addEventListener('click', () => {
    const workspaceId = lhWorkspaceSelect ? lhWorkspaceSelect.value : '';
    const lakehouseId = lhLakehouseSelect ? lhLakehouseSelect.value : '';
    const workspaceOption = (adminLakehouseWorkspaceOptions || []).find(w => w.workspace_id === workspaceId);
    const lakehouseOption = adminLakehouseOptions.find(l => l.lakehouse_id === lakehouseId);
    adminSettingsCache.lakehouse = {
      workspace_name: workspaceOption ? workspaceOption.workspace_name : (adminSettingsCache.lakehouse || {}).workspace_name || '',
      workspace_id: workspaceId,
      lakehouse_name: lakehouseOption ? lakehouseOption.lakehouse_name : (adminSettingsCache.lakehouse || {}).lakehouse_name || '',
      lakehouse_id: lakehouseId,
      capacity_name: document.getElementById('adminLhCapacity').value.trim(),
      sql_endpoint_connection_string: document.getElementById('adminLhSqlEndpoint').value.trim(),
      item_type: (lhItemTypeSelect && lhItemTypeSelect.value) || 'Lakehouse',
      // 2026-08-24: no local-CSV mode, no "behavior" section to toggle these
      // -- this project doesn't run local scans/local-CSV copies anymore,
      // so there's nothing for "copy after scan" to do; reads always come
      // straight from the warehouse.
      auto_upload_after_scan: false,
      auth_mode: (lhAuthModeSelect && lhAuthModeSelect.value) || 'user_session',
      sp_tenant_id: document.getElementById('adminLhSpTenantId').value.trim(),
      sp_client_id: document.getElementById('adminLhSpClientId').value.trim(),
      sp_client_secret_ref: document.getElementById('adminLhSpClientSecretRef').value.trim(),
      web_read_mode: 'warehouse',
    };
    saveAdminSettings();
  });

  const lakehouseTest = els.adminPanel.querySelector('[data-test-lakehouse]');
  if (lakehouseTest) lakehouseTest.addEventListener('click', testLakehouseConnection);

  const cmAuthModeSelect = document.getElementById('adminCmAuthMode');
  if (cmAuthModeSelect) cmAuthModeSelect.addEventListener('change', () => {
    const spFields = document.getElementById('adminCmSpFields');
    if (spFields) spFields.hidden = cmAuthModeSelect.value !== 'service_principal';
  });

  const cmSave = els.adminPanel.querySelector('[data-admin-save="capacity-metrics"]');
  if (cmSave) cmSave.addEventListener('click', () => {
    adminSettingsCache.capacity_metrics = {
      workspace_name: document.getElementById('adminCmWorkspaceName').value.trim(),
      workspace_id: document.getElementById('adminCmWorkspaceId').value.trim(),
      dataset_name: document.getElementById('adminCmDatasetName').value.trim(),
      dataset_id: document.getElementById('adminCmDatasetId').value.trim(),
      auth_mode: (cmAuthModeSelect && cmAuthModeSelect.value) || 'user_session',
      sp_tenant_id: document.getElementById('adminCmSpTenantId').value.trim(),
      sp_client_id: document.getElementById('adminCmSpClientId').value.trim(),
      sp_client_secret_ref: document.getElementById('adminCmSpClientSecretRef').value.trim(),
    };
    adminCapacityMetricsOverviewCache = null;
    saveAdminSettings();
  });

  const cmTest = els.adminPanel.querySelector('[data-test-capacity-metrics]');
  if (cmTest) cmTest.addEventListener('click', testCapacityMetricsConnection);

  const cmDiscover = els.adminPanel.querySelector('[data-discover-capacity-metrics]');
  if (cmDiscover) cmDiscover.addEventListener('click', discoverCapacityMetricsInstallation);

  const warehouseUploadButton = els.adminPanel.querySelector('[data-warehouse-upload]');
  if (warehouseUploadButton) warehouseUploadButton.addEventListener('click', triggerWarehouseUploadNow);

  const notifSmtpSave = els.adminPanel.querySelector('[data-admin-save="notifications-smtp"]');
  if (notifSmtpSave) notifSmtpSave.addEventListener('click', () => {
    adminSettingsCache.notifications = {
      ...(adminSettingsCache.notifications || {}),
      smtp_host: document.getElementById('adminSmtpHost').value.trim(),
      smtp_port: Number(document.getElementById('adminSmtpPort').value) || 587,
      smtp_use_tls: document.getElementById('adminSmtpUseTls').checked,
      smtp_user: document.getElementById('adminSmtpUser').value.trim(),
      smtp_password_ref: document.getElementById('adminSmtpPasswordRef').value.trim(),
      from_address: document.getElementById('adminSmtpFrom').value.trim(),
    };
    saveAdminSettings();
  });

  const notifSubscriptionSave = els.adminPanel.querySelector('[data-admin-save="notifications-subscription"]');
  if (notifSubscriptionSave) notifSubscriptionSave.addEventListener('click', () => {
    // Deliberately scoped to the SIGNED-IN admin's own row only -- there is
    // no UI here to add or edit anyone else's subscription, by design.
    const email = (authState.userEmail || '').trim();
    if (!email) return;
    const notif = { ...(adminSettingsCache.notifications || {}) };
    const subscribers = [...(notif.subscribers || [])];
    const existingIndex = subscribers.findIndex(s => (s.email || '').trim().toLowerCase() === email.toLowerCase());
    const entry = {
      email,
      language: document.getElementById('adminNotifyLanguage').value === 'en' ? 'en' : 'es',
      notify_succeeded: document.getElementById('adminNotifySucceeded').checked,
      notify_failed: document.getElementById('adminNotifyFailed').checked,
      notify_cancelled: document.getElementById('adminNotifyCancelled').checked,
    };
    if (existingIndex >= 0) subscribers[existingIndex] = entry;
    else subscribers.push(entry);
    notif.subscribers = subscribers;
    adminSettingsCache.notifications = notif;
    saveAdminSettings();
  });

  const notifTest = els.adminPanel.querySelector('[data-test-notification]');
  if (notifTest) notifTest.addEventListener('click', async () => {
    const resultEl = els.adminPanel.querySelector('[data-test-result="notifications"]');
    const es = state.lang === 'es';
    if (resultEl) { resultEl.textContent = es ? 'Enviando...' : 'Sending...'; resultEl.className = 'admin-test-result'; }
    try {
      // 2026-08-18: sends the form's current (possibly unsaved) SMTP
      // values, not just ?language= -- previously this always tested
      // whatever was last SAVED, so editing the host and clicking "Send
      // test email" without saving first silently tested the old host.
      const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/notifications/test`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          language: document.getElementById('adminNotifyLanguage').value,
          smtp_host: document.getElementById('adminSmtpHost').value.trim(),
          smtp_port: Number(document.getElementById('adminSmtpPort').value) || 587,
          smtp_use_tls: document.getElementById('adminSmtpUseTls').checked,
          smtp_user: document.getElementById('adminSmtpUser').value.trim(),
          smtp_password_ref: document.getElementById('adminSmtpPasswordRef').value.trim(),
          from_address: document.getElementById('adminSmtpFrom').value.trim(),
        }),
      });
      const payload = await response.json().catch(() => ({}));
      if (resultEl) {
        resultEl.textContent = payload.ok ? (es ? 'Enviado.' : 'Sent.') : (payload.message || (es ? 'No se pudo enviar.' : 'Could not send.'));
        resultEl.className = `admin-test-result ${payload.ok ? 'ok' : 'fail'}`;
      }
    } catch (error) {
      if (resultEl) { resultEl.textContent = es ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
    }
  });

  const notifTeamsSave = els.adminPanel.querySelector('[data-admin-save="notifications-teams"]');
  if (notifTeamsSave) notifTeamsSave.addEventListener('click', () => {
    adminSettingsCache.notifications = {
      ...(adminSettingsCache.notifications || {}),
      teams_webhook_url: document.getElementById('adminTeamsWebhookUrl').value.trim(),
      teams_language: document.getElementById('adminTeamsLanguage').value === 'en' ? 'en' : 'es',
      teams_notify_succeeded: document.getElementById('adminTeamsNotifySucceeded').checked,
      teams_notify_failed: document.getElementById('adminTeamsNotifyFailed').checked,
      teams_notify_cancelled: document.getElementById('adminTeamsNotifyCancelled').checked,
    };
    saveAdminSettings();
  });

  const notifTeamsTest = els.adminPanel.querySelector('[data-test-teams-notification]');
  if (notifTeamsTest) notifTeamsTest.addEventListener('click', async () => {
    const resultEl = els.adminPanel.querySelector('[data-test-result="notifications-teams"]');
    const es = state.lang === 'es';
    if (resultEl) { resultEl.textContent = es ? 'Enviando...' : 'Sending...'; resultEl.className = 'admin-test-result'; }
    try {
      // 2026-08-18: same "test the unsaved form" fix as the SMTP test above.
      const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/notifications/test-teams`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          language: document.getElementById('adminTeamsLanguage').value,
          teams_webhook_url: document.getElementById('adminTeamsWebhookUrl').value.trim(),
        }),
      });
      const payload = await response.json().catch(() => ({}));
      if (resultEl) {
        resultEl.textContent = payload.ok ? (es ? 'Enviado.' : 'Sent.') : (payload.message || (es ? 'No se pudo enviar.' : 'Could not send.'));
        resultEl.className = `admin-test-result ${payload.ok ? 'ok' : 'fail'}`;
      }
    } catch (error) {
      if (resultEl) { resultEl.textContent = es ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
    }
  });

  els.adminPanel.querySelectorAll('[data-remove-user]').forEach(button => {
    button.addEventListener('click', () => {
      const email = button.dataset.removeUser;
      const confirmMessage = state.lang === 'es'
        ? `¿Quitar a ${email} de la lista de usuarios permitidos? Se guarda de inmediato.`
        : `Remove ${email} from the allowed users list? This saves immediately.`;
      if (!window.confirm(confirmMessage)) return;
      removeUserRow(email);
    });
  });

  els.adminPanel.querySelectorAll('[data-user-field]').forEach(input => {
    input.addEventListener('change', () => updateUserField(input.dataset.userFieldEmail, input.dataset.userField, input.value.trim()));
  });
  els.adminPanel.querySelectorAll('[data-user-perm]').forEach(input => {
    input.addEventListener('change', () => updateUserField(input.dataset.userPermEmail, input.dataset.userPerm, input.checked));
  });

  els.adminPanel.querySelectorAll('[data-add-email]').forEach(button => {
    button.addEventListener('click', () => {
      const listKey = button.dataset.addEmail;
      const inputId = listKey === 'users' ? 'adminAddUser' : listKey === 'admin_emails' ? 'adminAddAdminEmail' : 'adminAddFullScanEmail';
      addUserRow(document.getElementById(inputId).value, '', '');
    });
  });

  els.adminPanel.querySelectorAll('[data-user-search-list]').forEach(input => {
    input.addEventListener('input', () => scheduleAdminUserSearch(input.dataset.userSearchList, input.id, input.value));
  });
  els.adminPanel.querySelectorAll('.admin-user-search-results').forEach(container => {
    container.addEventListener('click', event => {
      const pick = event.target.closest('[data-user-search-pick]');
      if (!pick) return;
      addUserRow(pick.dataset.userSearchPick, pick.dataset.userSearchName, pick.dataset.userSearchJobTitle);
      container.hidden = true;
      container.innerHTML = '';
    });
  });

  els.adminPanel.querySelectorAll('[data-workspace-group]').forEach(details => {
    details.addEventListener('toggle', () => {
      const name = details.dataset.workspaceGroup;
      if (details.open) {
        adminWorkspaceGroupsExpanded.add(name);
        maybeFetchWorkspaceUserProfiles(name);
      } else {
        adminWorkspaceGroupsExpanded.delete(name);
      }
    });
  });

  els.adminPanel.querySelectorAll('[data-source-field]').forEach(input => {
    input.addEventListener('change', () => {
      const index = Number(input.dataset.sourceIndex);
      const field = input.dataset.sourceField;
      adminSettingsCache.external_sources[index][field] = input.value.trim();
    });
  });

  // A source's TYPE decides which fields even apply (Snowflake has no
  // "port", BigQuery has no "host") -- changing it re-renders the row so
  // the form always matches the selected engine instead of showing every
  // field for every type.
  els.adminPanel.querySelectorAll('[data-source-type-index]').forEach(select => {
    select.addEventListener('change', () => {
      const index = Number(select.dataset.sourceTypeIndex);
      adminSettingsCache.external_sources[index].type = select.value;
      // A test result for the OLD engine type doesn't mean anything once
      // switched to a different one.
      delete adminSettingsCache.external_sources[index].last_test_ok;
      delete adminSettingsCache.external_sources[index].last_test_at;
      delete adminSettingsCache.external_sources[index].last_test_message;
      renderAdminPanel();
    });
  });

  els.adminPanel.querySelectorAll('[data-source-connection-index]').forEach(select => {
    select.addEventListener('change', () => {
      const index = Number(select.dataset.sourceConnectionIndex);
      const option = select.selectedOptions[0];
      adminSettingsCache.external_sources[index].fabric_connection_id = select.value || '';
      adminSettingsCache.external_sources[index].fabric_connection_name = select.value ? (option ? option.dataset.connectionName || option.textContent : '') : '';
      // The "Pendientes de conexión" card reads straight off
      // adminSettingsCache, so re-rendering here (not waiting for
      // "Guardar todo") is what makes assigning a connection visibly move
      // that source out of "pending" immediately. The toolbar badge only
      // reflects SAVED state though (see saveAdminSettings) -- an
      // unsaved assignment isn't durable yet.
      renderAdminPanel();
    });
  });

  els.adminPanel.querySelectorAll('[data-expand-source]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.expandSource);
      if (adminExpandedSourceIndexes.has(index)) {
        adminExpandedSourceIndexes.delete(index);
      } else {
        adminExpandedSourceIndexes.add(index);
      }
      renderAdminPanel();
    });
  });

  els.adminPanel.querySelectorAll('[data-remove-source]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removeSource);
      const sourceName = (adminSettingsCache.external_sources[index] || {}).name || (state.lang === 'es' ? 'sin nombre' : 'unnamed');
      const confirmMessage = state.lang === 'es'
        ? `¿Borrar el origen externo "${sourceName}"? Se pierde su configuración de conexión y se guarda de inmediato.`
        : `Delete the external source "${sourceName}"? Its connection config is lost and this saves immediately.`;
      if (!window.confirm(confirmMessage)) return;
      adminSettingsCache.external_sources.splice(index, 1);
      // Indexes above the removed row all shift down by one -- rebuild the
      // expanded set instead of leaving it pointing at the wrong rows.
      adminExpandedSourceIndexes = new Set(
        Array.from(adminExpandedSourceIndexes)
          .filter(i => i !== index)
          .map(i => (i > index ? i - 1 : i))
      );
      saveAdminSettings();
    });
  });

  const addSourceButton = els.adminPanel.querySelector('[data-add-source]');
  if (addSourceButton) addSourceButton.addEventListener('click', () => {
    adminSettingsCache.external_sources = adminSettingsCache.external_sources || [];
    adminSettingsCache.external_sources.push({ name: '', type: 'sql_server', auth_mode: 'sql_auth', notes: '' });
    adminExpandedSourceIndexes.add(adminSettingsCache.external_sources.length - 1);
    renderAdminPanel();
  });

  els.adminPanel.querySelectorAll('[data-configure-detected-source]').forEach(button => {
    button.addEventListener('click', () => {
      const host = button.dataset.configureDetectedSource;
      const detectedType = button.dataset.detectedSourceType;
      adminSettingsCache.external_sources = adminSettingsCache.external_sources || [];
      adminSettingsCache.external_sources.push({
        name: host, type: DETECTED_SOURCE_TYPE_DEFAULT[detectedType] || 'sql_server',
        auth_mode: 'sql_auth', host, notes: '',
      });
      adminExpandedSourceIndexes.add(adminSettingsCache.external_sources.length - 1);
      renderAdminPanel();
    });
  });

  const sourcesSave = els.adminPanel.querySelector('[data-admin-save="sources"]');
  if (sourcesSave) sourcesSave.addEventListener('click', async () => {
    cleanExternalSourcesBeforeSave();
    const ok = await saveAdminSettings();
    // "Guardar todo" means every row's edits are now durable -- a row you
    // expanded to configure (via "Configurar" on a detected source, or by
    // hand) has nothing left to do here, so leaving it expanded after a
    // successful save just makes the admin hunt for the collapse chevron
    // themselves. Left expanded on a FAILED save so
    // whatever they were mid-editing stays visible to retry.
    if (ok) {
      adminExpandedSourceIndexes = new Set();
      renderAdminPanel();
    }
  });

  els.adminPanel.querySelectorAll('[data-test-source]').forEach(button => {
    button.addEventListener('click', () => testExternalSourceConnection(Number(button.dataset.testSource)));
  });

  els.adminPanel.querySelectorAll('[data-suggest-secret-ref]').forEach(button => {
    button.addEventListener('click', () => {
      const field = button.dataset.suggestSecretRef;
      const index = Number(button.dataset.suggestSecretRefIndex);
      const source = adminSettingsCache.external_sources[index];
      if (!source) return;
      source[field] = suggestEnvVarName(source, field);
      renderAdminPanel();
    });
  });

  els.adminPanel.querySelectorAll('[data-test-fabric-connection]').forEach(button => {
    button.addEventListener('click', () => testFabricConnectionForSource(Number(button.dataset.testFabricConnection), button.dataset.connectionId));
  });

  // --- Tanda C: certifications ---
  const addCertButton = els.adminPanel.querySelector('[data-add-cert]');
  if (addCertButton) addCertButton.addEventListener('click', () => {
    adminSettingsCache.certified_items = adminSettingsCache.certified_items || [];
    adminSettingsCache.certified_items.push({ qualified_name: '', certified_by: authState.userEmail || '', certified_at: new Date().toISOString(), note: '' });
    renderAdminPanel();
  });
  els.adminPanel.querySelectorAll('[data-cert-field]').forEach(input => {
    input.addEventListener('change', () => {
      const index = Number(input.dataset.certIndex);
      adminSettingsCache.certified_items[index][input.dataset.certField] = input.value.trim();
    });
  });
  els.adminPanel.querySelectorAll('[data-remove-cert]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removeCert);
      const target = (adminSettingsCache.certified_items[index] || {}).qualified_name || (state.lang === 'es' ? 'sin nombre' : 'unnamed');
      const confirmMessage = state.lang === 'es'
        ? `¿Quitar la certificación de "${target}"? Recuerda pulsar Guardar para que se aplique.`
        : `Remove the certification on "${target}"? Remember to click Save to apply it.`;
      if (!window.confirm(confirmMessage)) return;
      adminSettingsCache.certified_items.splice(index, 1);
      renderAdminPanel();
    });
  });
  const certSave = els.adminPanel.querySelector('[data-admin-save="certifications"]');
  if (certSave) certSave.addEventListener('click', () => { cleanCertificationsBeforeSave(); saveAdminSettings(); });

  // --- Tanda C: business glossary ---
  const addGlossaryButton = els.adminPanel.querySelector('[data-add-glossary]');
  if (addGlossaryButton) addGlossaryButton.addEventListener('click', () => {
    adminSettingsCache.business_glossary = adminSettingsCache.business_glossary || [];
    adminSettingsCache.business_glossary.push({ term_es: '', term_en: '', definition_es: '', definition_en: '', linked_qualified_names: [] });
    renderAdminPanel();
  });
  els.adminPanel.querySelectorAll('[data-glossary-field]').forEach(input => {
    input.addEventListener('change', () => {
      const index = Number(input.dataset.glossaryIndex);
      const field = input.dataset.glossaryField;
      adminSettingsCache.business_glossary[index][field] = input.value.trim();
    });
  });
  // Linked assets (2026-08-18: chip list + autocomplete input instead of
  // a free-text "one per line" textarea, same reasoning as certifications/
  // tags' own qualified_name fields -- a typo used to silently link
  // nothing, with zero feedback).
  const addGlossaryAsset = (index) => {
    const input = els.adminPanel.querySelector(`[data-glossary-asset-input="${index}"]`);
    if (!input) return;
    const value = input.value.trim();
    if (!value) return;
    const entry = adminSettingsCache.business_glossary[index];
    entry.linked_qualified_names = entry.linked_qualified_names || [];
    if (!entry.linked_qualified_names.includes(value)) entry.linked_qualified_names.push(value);
    renderAdminPanel();
  };
  els.adminPanel.querySelectorAll('[data-add-glossary-asset]').forEach(button => {
    button.addEventListener('click', () => addGlossaryAsset(Number(button.dataset.addGlossaryAsset)));
  });
  els.adminPanel.querySelectorAll('[data-glossary-asset-input]').forEach(input => {
    input.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter') return;
      event.preventDefault();
      addGlossaryAsset(Number(input.dataset.glossaryAssetInput));
    });
  });
  els.adminPanel.querySelectorAll('[data-remove-glossary-asset]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removeGlossaryAsset);
      const chipIndex = Number(button.dataset.removeGlossaryAssetChip);
      adminSettingsCache.business_glossary[index].linked_qualified_names.splice(chipIndex, 1);
      renderAdminPanel();
    });
  });
  els.adminPanel.querySelectorAll('[data-remove-glossary]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removeGlossary);
      const entry = adminSettingsCache.business_glossary[index] || {};
      const term = entry.term_es || entry.term_en || (state.lang === 'es' ? 'sin nombre' : 'unnamed');
      const confirmMessage = state.lang === 'es'
        ? `¿Borrar el término "${term}" del glosario? Recuerda pulsar Guardar para que se aplique.`
        : `Delete the term "${term}" from the glossary? Remember to click Save to apply it.`;
      if (!window.confirm(confirmMessage)) return;
      adminSettingsCache.business_glossary.splice(index, 1);
      renderAdminPanel();
    });
  });
  const glossarySave = els.adminPanel.querySelector('[data-admin-save="business_glossary"]');
  if (glossarySave) glossarySave.addEventListener('click', () => { cleanGlossaryBeforeSave(); saveAdminSettings(); });

  // --- Roadmap Fase 2: free-form tags ---
  const addTagButton = els.adminPanel.querySelector('[data-add-tag]');
  if (addTagButton) addTagButton.addEventListener('click', () => {
    adminSettingsCache.tags = adminSettingsCache.tags || [];
    adminSettingsCache.tags.push({ qualified_name: '', tag: '', tagged_by: authState.userEmail || '', tagged_at: new Date().toISOString() });
    renderAdminPanel();
  });
  els.adminPanel.querySelectorAll('[data-tag-field]').forEach(input => {
    input.addEventListener('change', () => {
      const index = Number(input.dataset.tagIndex);
      adminSettingsCache.tags[index][input.dataset.tagField] = input.value.trim();
    });
  });
  els.adminPanel.querySelectorAll('[data-remove-tag]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removeTag);
      const entry = adminSettingsCache.tags[index] || {};
      const label = entry.tag && entry.qualified_name ? `"${entry.tag}" – ${entry.qualified_name}` : (state.lang === 'es' ? 'esta etiqueta' : 'this tag');
      const confirmMessage = state.lang === 'es'
        ? `¿Quitar ${label}? Recuerda pulsar Guardar para que se aplique.`
        : `Remove ${label}? Remember to click Save to apply it.`;
      if (!window.confirm(confirmMessage)) return;
      adminSettingsCache.tags.splice(index, 1);
      renderAdminPanel();
    });
  });
  const tagsSave = els.adminPanel.querySelector('[data-admin-save="tags"]');
  if (tagsSave) tagsSave.addEventListener('click', () => { cleanTagsBeforeSave(); saveAdminSettings(); });

  // --- Roadmap Fase 1 (2026-08-31): data-quality rules ---
  const addQualityRuleButton = els.adminPanel.querySelector('[data-add-quality-rule]');
  if (addQualityRuleButton) addQualityRuleButton.addEventListener('click', () => {
    adminSettingsCache.data_quality_rules = adminSettingsCache.data_quality_rules || [];
    const id = (window.crypto && window.crypto.randomUUID) ? window.crypto.randomUUID() : `rule-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    adminSettingsCache.data_quality_rules.push({
      id, rule_type: 'null_percentage_max', workspace_name: '', lakehouse_name: '', table_name: '', column_name: '',
      threshold: '', created_by: authState.userEmail || '', created_at: new Date().toISOString(), note: '',
    });
    renderAdminPanel();
  });
  els.adminPanel.querySelectorAll('[data-quality-field]').forEach(input => {
    const eventName = input.tagName === 'SELECT' ? 'change' : 'change';
    input.addEventListener(eventName, () => {
      const index = Number(input.dataset.qualityRuleIndex);
      const field = input.dataset.qualityField;
      const rule = adminSettingsCache.data_quality_rules[index];
      if (!rule) return;
      rule[field] = field === 'threshold' ? (input.value === '' ? '' : Number(input.value)) : input.value.trim();
    });
  });
  els.adminPanel.querySelectorAll('[data-remove-quality-rule]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removeQualityRule);
      const rule = adminSettingsCache.data_quality_rules[index] || {};
      const target = [rule.table_name, rule.column_name].filter(Boolean).join(' / ') || (state.lang === 'es' ? 'esta regla' : 'this rule');
      const confirmMessage = state.lang === 'es'
        ? `¿Quitar la regla de calidad sobre "${target}"? Recuerda pulsar Guardar para que se aplique.`
        : `Remove the quality rule on "${target}"? Remember to click Save to apply it.`;
      if (!window.confirm(confirmMessage)) return;
      adminSettingsCache.data_quality_rules.splice(index, 1);
      renderAdminPanel();
    });
  });
  const qualityRulesSave = els.adminPanel.querySelector('[data-admin-save="data_quality_rules"]');
  if (qualityRulesSave) qualityRulesSave.addEventListener('click', async () => {
    cleanDataQualityRulesBeforeSave();
    await saveAdminSettings();
    // The evaluated overview is a function of the rule set -- reload it
    // so the pass/fail table above reflects whatever just changed instead
    // of showing a stale evaluation until the tab is left and reopened.
    adminDataQualityOverviewCache = null;
    loadAdminDataQualityOverview();
  });

  // --- Roadmap Fase 2 (2026-08-31): custom sensitivity categories ---
  const addSensCategoryButton = els.adminPanel.querySelector('[data-add-sens-category]');
  if (addSensCategoryButton) addSensCategoryButton.addEventListener('click', () => {
    adminSettingsCache.custom_sensitivity_categories = adminSettingsCache.custom_sensitivity_categories || [];
    adminSettingsCache.custom_sensitivity_categories.push({
      key: '', label_es: '', label_en: '', patterns: [], risk: 'medium',
      recommendation_es: '', recommendation_en: '',
      created_by: authState.userEmail || '', created_at: new Date().toISOString(),
    });
    renderAdminPanel();
  });
  els.adminPanel.querySelectorAll('[data-sens-category-field]').forEach(input => {
    input.addEventListener('change', () => {
      const index = Number(input.dataset.sensCategoryIndex);
      const field = input.dataset.sensCategoryField;
      const entry = adminSettingsCache.custom_sensitivity_categories[index];
      if (!entry) return;
      if (field === 'patterns') {
        entry.patterns = input.value.split(',').map(p => p.trim()).filter(Boolean);
      } else if (field === 'key') {
        // No spaces, casefold-normalized at compare time on the backend
        // anyway -- trimming here just keeps what the admin sees in sync
        // with what will actually be compared against the 9 built-in keys.
        entry.key = input.value.trim().replace(/\s+/g, '_');
      } else {
        entry[field] = input.value.trim();
      }
    });
  });
  els.adminPanel.querySelectorAll('[data-remove-sens-category]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removeSensCategory);
      const entry = adminSettingsCache.custom_sensitivity_categories[index] || {};
      const target = entry.label_es || entry.key || (state.lang === 'es' ? 'esta categoría' : 'this category');
      const confirmMessage = state.lang === 'es'
        ? `¿Borrar la categoría de sensibilidad "${target}"? Recuerda pulsar Guardar para que se aplique.`
        : `Delete the sensitivity category "${target}"? Remember to click Save to apply it.`;
      if (!window.confirm(confirmMessage)) return;
      adminSettingsCache.custom_sensitivity_categories.splice(index, 1);
      renderAdminPanel();
    });
  });
  const sensCategoriesSave = els.adminPanel.querySelector('[data-admin-save="custom_sensitivity_categories"]');
  if (sensCategoriesSave) sensCategoriesSave.addEventListener('click', () => {
    cleanCustomSensitivityCategoriesBeforeSave();
    saveAdminSettings();
  });

  // --- Roadmap Fase 3 (2026-08-31): data products ---
  const addDataProductButton = els.adminPanel.querySelector('[data-add-data-product]');
  if (addDataProductButton) addDataProductButton.addEventListener('click', () => {
    adminSettingsCache.data_products = adminSettingsCache.data_products || [];
    adminSettingsCache.data_products.push({
      id: (window.crypto && window.crypto.randomUUID) ? window.crypto.randomUUID() : `product-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      name: '', owner_email: '', description_es: '', description_en: '', linked_qualified_names: [],
      created_by: authState.userEmail || '', created_at: new Date().toISOString(),
    });
    renderAdminPanel();
  });
  els.adminPanel.querySelectorAll('[data-data-product-field]').forEach(input => {
    input.addEventListener('change', () => {
      const index = Number(input.dataset.dataProductIndex);
      const field = input.dataset.dataProductField;
      const entry = adminSettingsCache.data_products[index];
      if (!entry) return;
      entry[field] = input.value.trim();
    });
  });
  const addDataProductAsset = (index) => {
    const input = els.adminPanel.querySelector(`[data-data-product-asset-input="${index}"]`);
    if (!input) return;
    const value = input.value.trim();
    if (!value) return;
    const entry = adminSettingsCache.data_products[index];
    entry.linked_qualified_names = entry.linked_qualified_names || [];
    if (!entry.linked_qualified_names.includes(value)) entry.linked_qualified_names.push(value);
    renderAdminPanel();
  };
  els.adminPanel.querySelectorAll('[data-add-data-product-asset]').forEach(button => {
    button.addEventListener('click', () => addDataProductAsset(Number(button.dataset.addDataProductAsset)));
  });
  els.adminPanel.querySelectorAll('[data-data-product-asset-input]').forEach(input => {
    input.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter') return;
      event.preventDefault();
      addDataProductAsset(Number(input.dataset.dataProductAssetInput));
    });
  });
  els.adminPanel.querySelectorAll('[data-remove-data-product-asset]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removeDataProductAsset);
      const chipIndex = Number(button.dataset.removeDataProductAssetChip);
      adminSettingsCache.data_products[index].linked_qualified_names.splice(chipIndex, 1);
      renderAdminPanel();
    });
  });
  els.adminPanel.querySelectorAll('[data-remove-data-product]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removeDataProduct);
      const entry = adminSettingsCache.data_products[index] || {};
      const target = entry.name || (state.lang === 'es' ? 'este producto de datos' : 'this data product');
      const confirmMessage = state.lang === 'es'
        ? `¿Borrar el producto de datos "${target}"? Recuerda pulsar Guardar para que se aplique.`
        : `Delete the data product "${target}"? Remember to click Save to apply it.`;
      if (!window.confirm(confirmMessage)) return;
      adminSettingsCache.data_products.splice(index, 1);
      renderAdminPanel();
    });
  });
  const dataProductsSave = els.adminPanel.querySelector('[data-admin-save="data_products"]');
  if (dataProductsSave) dataProductsSave.addEventListener('click', async () => {
    cleanDataProductsBeforeSave();
    await saveAdminSettings();
    // The detail-panel badge (dataProductsByQualifiedName) is built from
    // the last loadCertificationsAndTags() fetch -- reload it so a newly
    // linked asset shows its data product without needing a full page
    // refresh, same reasoning as the data-quality overview reload above.
    loadCertificationsAndTags();
  });

  // --- Roadmap Fase 6 (2026-08-31): privacy external systems ---
  const addPrivacySystemButton = els.adminPanel.querySelector('[data-add-privacy-system]');
  if (addPrivacySystemButton) addPrivacySystemButton.addEventListener('click', () => {
    adminSettingsCache.privacy_external_systems = adminSettingsCache.privacy_external_systems || [];
    adminSettingsCache.privacy_external_systems.push({
      id: (window.crypto && window.crypto.randomUUID) ? window.crypto.randomUUID() : `privsys-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      category: 'biometric', system_name: '', in_fabric: false, owner_name: '', owner_email: '', notes: '',
      created_by: authState.userEmail || '', created_at: new Date().toISOString(),
    });
    renderAdminPanel();
  });
  els.adminPanel.querySelectorAll('[data-privacy-system-field]').forEach(input => {
    input.addEventListener('change', () => {
      const index = Number(input.dataset.privacySystemIndex);
      const field = input.dataset.privacySystemField;
      const entry = adminSettingsCache.privacy_external_systems[index];
      if (!entry) return;
      entry[field] = field === 'in_fabric' ? input.checked : input.value.trim();
    });
  });
  els.adminPanel.querySelectorAll('[data-remove-privacy-system]').forEach(button => {
    button.addEventListener('click', () => {
      const index = Number(button.dataset.removePrivacySystem);
      const entry = adminSettingsCache.privacy_external_systems[index] || {};
      const target = entry.system_name || (state.lang === 'es' ? 'este sistema' : 'this system');
      const confirmMessage = state.lang === 'es'
        ? `¿Borrar "${target}" de la lista de sistemas? Recuerda pulsar Guardar para que se aplique.`
        : `Delete "${target}" from the systems list? Remember to click Save to apply it.`;
      if (!window.confirm(confirmMessage)) return;
      adminSettingsCache.privacy_external_systems.splice(index, 1);
      renderAdminPanel();
    });
  });
  const privacySystemsSave = els.adminPanel.querySelector('[data-admin-save="privacy_external_systems"]');
  if (privacySystemsSave) privacySystemsSave.addEventListener('click', async () => {
    cleanPrivacyExternalSystemsBeforeSave();
    await saveAdminSettings();
    // The Privacidad panel's "por normativa" view embeds these systems --
    // reload it so a newly logged system shows up without a full refresh,
    // same reasoning as the data-quality/data-products reloads above.
    if (privacyFrameworkMapCache !== null) loadPrivacyFrameworkMap();
  });
}

async function testExternalSourceConnection(index) {
  const resultEl = els.adminPanel.querySelector(`[data-test-result="${index}"]`);
  if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'Probando...' : 'Testing...'; resultEl.className = 'admin-test-result'; }
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/external-sources/test`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ index, source: adminSettingsCache.external_sources[index] }),
    });
    const payload = await response.json().catch(() => ({}));
    // The backend persists this onto the SAVED (disk) copy of this row
    // when it still recognizes it as the same source (see external_
    // sources._persist_external_source_test_result) -- mirroring the same
    // fields onto the in-memory row here means the status dot survives a
    // reload without a second fetch, and (for a brand-new unsaved row the
    // backend couldn't match) still shows correctly until the next real
    // save, consistent with everything else in this list only persisting
    // on "Guardar todo".
    const source = adminSettingsCache.external_sources[index];
    if (source) {
      source.last_test_ok = Boolean(payload.ok);
      source.last_test_at = new Date().toISOString();
      source.last_test_message = payload.ok ? '' : (payload.message || '');
    }
    if (resultEl) {
      resultEl.textContent = payload.ok ? (state.lang === 'es' ? 'Conecta correctamente.' : 'Connected successfully.') : (payload.message || (state.lang === 'es' ? 'Fallo de conexión.' : 'Connection failed.'));
      resultEl.className = `admin-test-result ${payload.ok ? 'ok' : 'fail'}`;
    }
    renderAdminPanel();
  } catch (error) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

// Tests THROUGH the assigned gateway (2026-08-18) -- see handler.py's
// /api/admin/fabric-connections/test docstring for why this is a
// genuinely different check from testExternalSourceConnection above (that
// one connects directly from this server, which can never reach an
// on-premises source; this one asks the gateway itself). Can take up to a
// minute -- a real Fabric long-running operation, not instant like the
// tests above -- so the button disables and the wording says so up front
// rather than looking frozen.
async function testFabricConnectionForSource(index, connectionId) {
  const es = state.lang === 'es';
  const resultEl = els.adminPanel.querySelector(`[data-test-result="fabric-connection-${index}"]`);
  const button = els.adminPanel.querySelector(`[data-test-fabric-connection="${index}"]`);
  if (button) button.disabled = true;
  if (resultEl) {
    resultEl.textContent = es ? 'Probando (puede tardar hasta 1 minuto)...' : 'Testing (can take up to a minute)...';
    resultEl.className = 'admin-test-result';
  }
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/fabric-connections/test`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ connection_id: connectionId, source_index: index }),
    });
    const payload = await response.json().catch(() => ({}));
    const source = adminSettingsCache.external_sources && adminSettingsCache.external_sources[index];
    if (source) {
      source.fabric_connection_last_test_status = payload.status || null;
      source.fabric_connection_last_test_at = new Date().toISOString();
      source.fabric_connection_last_test_message = payload.message || '';
    }
    if (!payload.status) {
      window.alert(payload.message || (es ? 'No se pudo completar la prueba.' : 'Could not complete the test.'));
    }
    renderAdminPanel();
    refreshAlertsSummary();
  } catch (error) {
    if (button) button.disabled = false;
    if (resultEl) { resultEl.textContent = es ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

async function testLakehouseConnection() {
  const resultEl = els.adminPanel.querySelector('[data-test-result="lakehouse"]');
  if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'Probando...' : 'Testing...'; resultEl.className = 'admin-test-result'; }
  // Tests whatever is currently selected/typed in the form, not only what
  // was last saved -- so you can check a connection before committing it.
  const workspaceSelect = document.getElementById('adminLhWorkspaceSelect');
  const lakehouseSelect = document.getElementById('adminLhLakehouseSelect');
  const workspaceOption = (adminLakehouseWorkspaceOptions || []).find(w => w.workspace_id === (workspaceSelect && workspaceSelect.value));
  const lakehouseOption = adminLakehouseOptions.find(l => l.lakehouse_id === (lakehouseSelect && lakehouseSelect.value));
  const authModeSelect = document.getElementById('adminLhAuthMode');
  const lakehouse = {
    workspace_name: workspaceOption ? workspaceOption.workspace_name : '',
    workspace_id: workspaceSelect ? workspaceSelect.value : '',
    lakehouse_name: lakehouseOption ? lakehouseOption.lakehouse_name : '',
    lakehouse_id: lakehouseSelect ? lakehouseSelect.value : '',
    capacity_name: document.getElementById('adminLhCapacity').value.trim(),
    sql_endpoint_connection_string: document.getElementById('adminLhSqlEndpoint').value.trim(),
    auth_mode: (authModeSelect && authModeSelect.value) || 'user_session',
    sp_tenant_id: document.getElementById('adminLhSpTenantId').value.trim(),
    sp_client_id: document.getElementById('adminLhSpClientId').value.trim(),
    sp_client_secret_ref: document.getElementById('adminLhSpClientSecretRef').value.trim(),
  };
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/lakehouse/test`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(lakehouse),
    });
    const payload = await response.json().catch(() => ({}));
    if (resultEl) {
      resultEl.textContent = payload.ok ? (state.lang === 'es' ? 'Conecta correctamente.' : 'Connected successfully.') : (payload.message || (state.lang === 'es' ? 'Fallo de conexión.' : 'Connection failed.'));
      resultEl.className = `admin-test-result ${payload.ok ? 'ok' : 'fail'}`;
    }
  } catch (error) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

async function testCapacityMetricsConnection() {
  const resultEl = els.adminPanel.querySelector('[data-test-result="capacity-metrics"]');
  if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'Probando...' : 'Testing...'; resultEl.className = 'admin-test-result'; }
  // Same "test the form, not just what's saved" philosophy as the other
  // connection tests -- reads straight off the inputs, not adminSettingsCache.
  const authModeSelect = document.getElementById('adminCmAuthMode');
  const config = {
    workspace_id: document.getElementById('adminCmWorkspaceId').value.trim(),
    dataset_id: document.getElementById('adminCmDatasetId').value.trim(),
    auth_mode: (authModeSelect && authModeSelect.value) || 'user_session',
    sp_tenant_id: document.getElementById('adminCmSpTenantId').value.trim(),
    sp_client_id: document.getElementById('adminCmSpClientId').value.trim(),
    sp_client_secret_ref: document.getElementById('adminCmSpClientSecretRef').value.trim(),
  };
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/capacity-metrics/test`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(config),
    });
    const payload = await response.json().catch(() => ({}));
    if (resultEl) {
      resultEl.textContent = payload.ok ? (payload.message || (state.lang === 'es' ? 'Conecta correctamente.' : 'Connected successfully.')) : (payload.message || (state.lang === 'es' ? 'Fallo de conexión.' : 'Connection failed.'));
      resultEl.className = `admin-test-result ${payload.ok ? 'ok' : 'fail'}`;
    }
  } catch (error) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

async function discoverCapacityMetricsInstallation() {
  const es = state.lang === 'es';
  const resultEl = document.getElementById('adminCmDiscoverResult');
  if (resultEl) resultEl.textContent = es ? 'Buscando entre tus workspaces...' : 'Searching your workspaces...';
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/capacity-metrics/discover`);
    const payload = await response.json().catch(() => ({}));
    if (!payload.found) {
      if (resultEl) resultEl.textContent = payload.reason || (es ? 'No se encontró ninguna instalación.' : 'No installation found.');
      return;
    }
    document.getElementById('adminCmWorkspaceName').value = payload.workspace_name || '';
    document.getElementById('adminCmWorkspaceId').value = payload.workspace_id || '';
    document.getElementById('adminCmDatasetName').value = payload.dataset_name || '';
    document.getElementById('adminCmDatasetId').value = payload.dataset_id || '';
    if (resultEl) resultEl.textContent = es
      ? `Encontrado: "${payload.workspace_name}" / "${payload.dataset_name}". Revisa los campos y pulsa Guardar.`
      : `Found: "${payload.workspace_name}" / "${payload.dataset_name}". Review the fields and click Save.`;
  } catch (error) {
    if (resultEl) resultEl.textContent = es ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.';
  }
}

async function testDiscoveryPipelineConnection() {
  const resultEl = els.adminPanel.querySelector('[data-test-result="discovery-pipeline"]');
  if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'Probando...' : 'Testing...'; resultEl.className = 'admin-test-result'; }
  // Same "test the form, not just what's saved" philosophy as
  // testLakehouseConnection -- this only reads the pipeline item's own
  // metadata, it never starts a real run.
  const pipeline = {
    workspace_id: (document.getElementById('adminPipelineWorkspaceSelect') || {}).value || '',
    pipeline_item_id: (document.getElementById('adminPipelineItemSelect') || {}).value || '',
    sp_tenant_id: document.getElementById('adminPipelineSpTenantId').value.trim(),
    sp_client_id: document.getElementById('adminPipelineSpClientId').value.trim(),
    sp_client_secret_ref: document.getElementById('adminPipelineSpClientSecretRef').value.trim(),
  };
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/discovery-pipeline/test`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(pipeline),
    });
    const payload = await response.json().catch(() => ({}));
    if (resultEl) {
      resultEl.textContent = payload.ok ? (payload.message || (state.lang === 'es' ? 'Conecta correctamente.' : 'Connected successfully.')) : (payload.message || (state.lang === 'es' ? 'Fallo de conexión.' : 'Connection failed.'));
      resultEl.className = `admin-test-result ${payload.ok ? 'ok' : 'fail'}`;
    }
  } catch (error) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

// Same "test the form, not just what's saved" philosophy as
// testLakehouseConnection/testDiscoveryPipelineConnection (2026-08-18 --
// this was the one Setup tab with a credential but no safe test action,
// only a real "Publicar datos ahora").
async function testOneLakeConnection() {
  const resultEl = els.adminPanel.querySelector('[data-test-result="onelake"]');
  if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'Probando...' : 'Testing...'; resultEl.className = 'admin-test-result'; }
  const onelake = {
    workspace_name: document.getElementById('adminOneLakeWorkspaceName').value.trim(),
    lakehouse_name: document.getElementById('adminOneLakeLakehouseName').value.trim(),
    sp_tenant_id: document.getElementById('adminOneLakeSpTenantId').value.trim(),
    sp_client_id: document.getElementById('adminOneLakeSpClientId').value.trim(),
    sp_client_secret_ref: document.getElementById('adminOneLakeSpClientSecretRef').value.trim(),
  };
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/onelake/test`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(onelake),
    });
    const payload = await response.json().catch(() => ({}));
    if (resultEl) {
      resultEl.textContent = payload.ok ? (payload.message || (state.lang === 'es' ? 'Conecta correctamente.' : 'Connected successfully.')) : (payload.message || (state.lang === 'es' ? 'Fallo de conexión.' : 'Connection failed.'));
      resultEl.className = `admin-test-result ${payload.ok ? 'ok' : 'fail'}`;
    }
  } catch (error) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

// Uses whatever is already SAVED (config/lakehouse_target.json on disk),
// not the possibly-unsaved form state -- unlike testLakehouseConnection
// (a quick, harmless read), this actually writes real tables, so "save
// first, then copy" is the safer default rather than silently copying to
// wherever the form happens to say right now.
async function triggerWarehouseUploadNow() {
  const resultEl = els.adminPanel.querySelector('[data-test-result="warehouse-upload"]');
  if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'Iniciando...' : 'Starting...'; resultEl.className = 'admin-test-result'; }
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/warehouse-upload`, { method: 'POST' });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (resultEl) {
        resultEl.textContent = payload.message || (state.lang === 'es' ? 'No se pudo iniciar la copia.' : 'Could not start the copy.');
        resultEl.className = 'admin-test-result fail';
      }
      return;
    }
    if (payload.status === 'queued') {
      if (resultEl) {
        resultEl.textContent = state.lang === 'es' ? `En cola (posición ${payload.position}).` : `Queued (position ${payload.position}).`;
        resultEl.className = 'admin-test-result';
      }
      return;
    }
    if (resultEl) {
      resultEl.textContent = state.lang === 'es' ? 'Copiando...' : 'Copying...';
      resultEl.className = 'admin-test-result';
    }
    pollLocalScanStatus();
  } catch (error) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

async function triggerOneLakePublishNow() {
  const resultEl = els.adminPanel.querySelector('[data-test-result="onelake-publish"]');
  if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'Iniciando...' : 'Starting...'; resultEl.className = 'admin-test-result'; }
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/admin/onelake-publish`, { method: 'POST' });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (resultEl) {
        resultEl.textContent = payload.message || (state.lang === 'es' ? 'No se pudo iniciar la publicación.' : 'Could not start the publish.');
        resultEl.className = 'admin-test-result fail';
      }
      return;
    }
    if (payload.status === 'queued') {
      if (resultEl) {
        resultEl.textContent = state.lang === 'es' ? `En cola (posición ${payload.position}).` : `Queued (position ${payload.position}).`;
        resultEl.className = 'admin-test-result';
      }
      return;
    }
    if (resultEl) {
      resultEl.textContent = state.lang === 'es' ? 'Publicando...' : 'Publishing...';
      resultEl.className = 'admin-test-result';
    }
    pollLocalScanStatus();
  } catch (error) {
    if (resultEl) { resultEl.textContent = state.lang === 'es' ? 'No se pudo conectar con el servidor.' : 'Could not reach the server.'; resultEl.className = 'admin-test-result fail'; }
  }
}

const LOCAL_SCAN_STATUS_TEXT = {
  es: {
    unreachable: 'No se pudo conectar con el servidor de escaneo.',
    loadError: 'No se pudo cargar la lista de workspaces.',
    selectWorkspace: 'Elige un workspace antes de escanear.',
    starting: 'Iniciando escaneo...',
    azSessionInvalid: 'Sesión de az expirada o ausente. Ejecuta "az login" y vuelve a intentarlo.',
    alreadyRunning: workspace => `Ya hay un escaneo en curso para "${workspace}".`,
    notFound: 'Ese workspace no existe en el índice local.',
    genericError: 'No se pudo iniciar el escaneo.',
    signInRequired: 'Inicia sesión con tu cuenta Microsoft para lanzar un escaneo.',
    notPermittedStop: 'Solo quien inició este escaneo, o un admin, puede detenerlo.',
    tooManyFlows: 'Demasiados intentos de inicio de sesión seguidos. Espera un momento y vuelve a intentarlo.',
    noAccessibleWorkspaces: 'Tu cuenta no tiene acceso a ningún workspace de Fabric.',
    workspaceDiscoveryFailed: 'No se pudo comprobar a qué workspaces tienes acceso.',
    running: (workspace, seconds) => `Escaneando "${workspace}" (${seconds}s)...`,
    runningTenantWide: count => `Escaneando TODO el tenant como Fabric Administrator (${count} workspaces)...`,
    succeeded: (workspace, seconds) => `Escaneo de "${workspace}" completado en ${seconds}s.`,
    failed: (workspace, message) => `Escaneo de "${workspace}" falló: ${message}`,
    cancelled: (workspace, seconds) => `Escaneo de "${workspace}" detenido tras ${seconds}s.`,
    stopping: 'Deteniendo escaneo...',
    stopError: 'No se pudo detener el escaneo.',
    noScanRunning: 'No hay ningún escaneo en curso.',
    queued: (workspace, position) => `En cola para escanear "${workspace}" (posición ${position}).`,
    queueHeading: 'Esperando en la cola',
    queueRow: (position, label, who) => `${position}. ${label}${who ? ` — ${who}` : ''}`,
    queueFull: 'La cola de escaneos está llena. Inténtalo de nuevo cuando terminen los que ya esperan.',
    noHistory: 'Sin escaneos previos registrados para este workspace.',
    lastRun: (seconds, when, status) => `Última vez: ${seconds}s el ${when}${status !== 'succeeded' ? ` (${status})` : ''}`,
    diffChanges: 'Cambios',
    diffNoChanges: 'sin cambios',
    diffByType: 'Cambios por tipo',
    diffViewSamples: 'Ver ejemplos',
    diffHideSamples: 'Ocultar ejemplos',
    diffLoadingSamples: 'Cargando ejemplos...',
    diffSamplesError: 'No se pudieron cargar los ejemplos.',
    diffAddedSample: 'Añadidos',
    diffRemovedSample: 'Eliminados',
    diffModifiedSample: 'Modificados',
    diffSignInForSamples: 'Inicia sesión para ver los ejemplos.'
  },
  en: {
    unreachable: 'Could not reach the scan server.',
    loadError: 'Could not load the workspace list.',
    selectWorkspace: 'Choose a workspace before scanning.',
    starting: 'Starting scan...',
    azSessionInvalid: 'Azure CLI session expired or missing. Run "az login" and try again.',
    alreadyRunning: workspace => `A scan is already running for "${workspace}".`,
    notFound: 'That workspace does not exist in the local index.',
    genericError: 'Could not start the scan.',
    signInRequired: 'Sign in with your Microsoft account to start a scan.',
    notPermittedStop: 'Only the person who started this scan, or an admin, can stop it.',
    tooManyFlows: 'Too many sign-in attempts in a row. Wait a moment and try again.',
    noAccessibleWorkspaces: 'Your account has no accessible Fabric workspaces.',
    workspaceDiscoveryFailed: 'Could not check which workspaces you have access to.',
    running: (workspace, seconds) => `Scanning "${workspace}" (${seconds}s)...`,
    runningTenantWide: count => `Scanning the WHOLE tenant as a Fabric Administrator (${count} workspaces)...`,
    succeeded: (workspace, seconds) => `Scan of "${workspace}" finished in ${seconds}s.`,
    failed: (workspace, message) => `Scan of "${workspace}" failed: ${message}`,
    cancelled: (workspace, seconds) => `Scan of "${workspace}" stopped after ${seconds}s.`,
    stopping: 'Stopping scan...',
    stopError: 'Could not stop the scan.',
    noScanRunning: 'No scan is currently running.',
    queued: (workspace, position) => `Queued to scan "${workspace}" (position ${position}).`,
    queueHeading: 'Waiting in the queue',
    queueRow: (position, label, who) => `${position}. ${label}${who ? ` — ${who}` : ''}`,
    queueFull: 'The scan queue is full. Try again once the requests already waiting finish.',
    noHistory: 'No previous scans recorded for this workspace.',
    lastRun: (seconds, when, status) => `Last run: ${seconds}s on ${when}${status !== 'succeeded' ? ` (${status})` : ''}`,
    diffChanges: 'Changes',
    diffNoChanges: 'no changes',
    diffByType: 'Changes by type',
    diffViewSamples: 'View samples',
    diffHideSamples: 'Hide samples',
    diffLoadingSamples: 'Loading samples...',
    diffSamplesError: 'Could not load the samples.',
    diffAddedSample: 'Added',
    diffRemovedSample: 'Removed',
    diffModifiedSample: 'Modified',
    diffSignInForSamples: 'Sign in to view samples.'
  }
};
let localScanPollHandle = null;
let localScanPanelWired = false;
let localScanLastKnownStatus = null;
// The queue_id this browser tab's own most recent queued request got back
// (see triggerLocalScan/triggerFullScan) -- lets pollLocalScanStatus keep
// showing "queued, position N" for THIS request specifically (with a live
// position as entries ahead of it start/finish) instead of the server-wide
// status immediately overwriting it on the very next 4s poll tick.
let myQueuedEntryId = null;

function localScanText() {
  return LOCAL_SCAN_STATUS_TEXT[state.lang] || LOCAL_SCAN_STATUS_TEXT.es;
}

function setLocalScanControlsDisabled(disabled) {
  if (els.localScanWorkspaceSelect) els.localScanWorkspaceSelect.disabled = disabled;
  if (els.localScanButton) els.localScanButton.disabled = disabled;
  if (els.fullScanButton) els.fullScanButton.disabled = disabled;
}

// Single place that reconciles every "a scan is running" visual cue: the
// panel's own highlighted background (so it stands out from the rest of
// the toolbar while it is actually doing something for potentially
// several hours), the stop button showing up in place of the idle
// controls, and the progress bar. Called from every poll tick, not just on
// transitions, so a page refresh mid-scan still renders the right state
// immediately instead of waiting for the next status change.
function setScanRunningUi(isRunning) {
  // Controls used to be disabled for the whole server-wide duration of
  // "a scan is running" -- with the scan queue (Tanda 10), a second/third
  // request while one is already running is now a normal, encouraged
  // action (it just waits its turn) rather than something to block, so
  // only the brief in-flight moment of an individual submit disables them
  // (see triggerLocalScan/triggerFullScan's own setLocalScanControlsDisabled
  // calls), not this server-wide status.
  if (els.localScanPanel) els.localScanPanel.classList.toggle('is-scanning', isRunning);
  if (els.stopScanButton) {
    els.stopScanButton.hidden = !isRunning;
    els.stopScanButton.disabled = false;
  }
  if (els.scanProgressWrap) els.scanProgressWrap.hidden = !isRunning;
  if (!isRunning) {
    // Reset the bar itself, not just hide it -- otherwise the next scan
    // (whichever workspace, started by whoever) would briefly flash
    // whatever percentage this one ended at (e.g. a stop mid-way through)
    // before the first real progress update overwrites it.
    if (els.scanProgressFill) els.scanProgressFill.style.width = '0%';
    if (els.scanProgressText) els.scanProgressText.textContent = '';
    if (els.scanProgressStep) els.scanProgressStep.textContent = '';
  }
}

function formatScanProgress(progress, elapsedSeconds) {
  if (!progress || !progress.total_steps) return null;
  const fraction = progress.total_steps > 0 ? Math.min(1, progress.completed_steps / progress.total_steps) : 0;
  const percent = Math.round(fraction * 1000) / 10;
  return {
    percent,
    text: `${percent.toLocaleString(state.lang === 'es' ? 'es-ES' : 'en-GB', { minimumFractionDigits: 1, maximumFractionDigits: 1 })}%(${elapsedSeconds}s)`,
    stepName: progress.current_step_name || ''
  };
}

// Sentinel the trigger server stores in the same "workspace" field a
// per-workspace scan uses (see FULL_SCAN_LABEL in lineage_web_server.py) --
// never a real workspace name, so it can share every status/history/error
// code path below and only needs swapping for a readable label at display
// time.
const FULL_SCAN_LABEL = '__full_scan__';
const EXECUTIONS_SCAN_LABEL = '__production_executions__';
const WAREHOUSE_UPLOAD_LABEL = '__warehouse_upload__';
const ONELAKE_PUBLISH_LABEL = '__onelake_publish__';

function localScanDisplayName(workspace) {
  if (workspace === FULL_SCAN_LABEL) return state.lang === 'es' ? 'Escaneo completo' : 'Full scan';
  if (workspace === EXECUTIONS_SCAN_LABEL) return state.lang === 'es' ? 'Ejecuciones de producción' : 'Production executions';
  if (workspace === WAREHOUSE_UPLOAD_LABEL) return state.lang === 'es' ? 'Copia al almacén de escritura' : 'Copy to write storage';
  if (workspace === ONELAKE_PUBLISH_LABEL) return state.lang === 'es' ? 'Publicación de datos web en OneLake' : 'Web data publish to OneLake';
  return workspace;
}

// history.csv is written by PowerShell's Export-Csv, which stringifies
// [math]::Round(...) using whatever decimal separator the OS locale uses --
// on a machine set to a comma-decimal locale that is "103,815", not
// "103.815". Number("103,815") is NaN in JS, so every duration silently
// read as 0 without this: swap a lone decimal comma for a period before
// parsing (these are plain seconds values, never thousands-grouped, so
// there is no ambiguity to worry about).
function parseCsvNumber(value) {
  if (value === null || value === undefined || value === '') return 0;
  const normalized = String(value).replace(',', '.');
  const parsed = Number(normalized);
  return Number.isFinite(parsed) ? parsed : 0;
}

async function fetchLocalScanWorkspaces() {
  // 2026-08-24: the select is now visible (locked) from page load rather
  // than hidden until sign-in -- start it empty with a loading placeholder
  // instead of whatever it last showed, so it's never mistaken for "these
  // are your workspaces" while the real list is still in flight.
  const select = els.localScanWorkspaceSelect;
  if (select) {
    select.disabled = true;
    select.innerHTML = `<option value="">${state.lang === 'es' ? 'Cargando workspaces...' : 'Loading workspaces...'}</option>`;
  }
  try {
    let names;

    // Signed in: the dropdown is ONLY the workspaces THIS person actually
    // has Fabric access to as Admin/Member/Contributor (queried with their
    // own token, min_role=contributor -- 2026-08-24) -- never the full
    // previously-indexed tenant list, which can include workspaces a
    // colleague found that this person was never granted access to, and
    // never a Viewer-only workspace, which isn't this person's to scan.
    // This is what makes "you can only scan what you can act on" true for
    // single-workspace scans too, not just the full-scan button.
    if (authState.signedIn) {
      const mineResponse = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/workspaces/mine?min_role=contributor`);
      if (!mineResponse.ok) throw new Error(`HTTP ${mineResponse.status}`);
      const minePayload = await mineResponse.json();
      names = new Set((minePayload.workspaces || []).map(workspace => workspace.workspace_name));
    } else {
      const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/workspaces`);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      names = new Set((payload.workspaces || []).map(workspace => workspace.workspace_name));
    }

    if (!select) return;
    select.innerHTML = '';
    if (names.size === 0) {
      const option = document.createElement('option');
      option.value = '';
      option.textContent = authState.signedIn
        ? (state.lang === 'es' ? 'Sin workspaces donde seas colaborador o admin' : 'No workspaces where you are a contributor or admin')
        : (state.lang === 'es' ? 'Sin workspaces' : 'No workspaces');
      select.appendChild(option);
    }
    Array.from(names).sort((a, b) => a.localeCompare(b)).forEach(name => {
      const option = document.createElement('option');
      option.value = name;
      option.textContent = name;
      select.appendChild(option);
    });
    select.disabled = false;
    // So nobody assumes they're looking at the whole tenant -- only shown
    // once signed in, since the anonymous list is the full indexed set,
    // not a personal access boundary.
    if (els.localScanAccessHint) {
      if (authState.signedIn) {
        els.localScanAccessHint.hidden = false;
        els.localScanAccessHint.textContent = state.lang === 'es'
          ? `Lista de workspaces: ${names.size}`
          : `Workspace list: ${names.size}`;
      } else {
        els.localScanAccessHint.hidden = true;
      }
    }
    updateLocalScanHint();
  } catch (error) {
    setLocalScanControlsDisabled(true);
    if (els.localScanStatus) els.localScanStatus.textContent = localScanText().unreachable;
  }
}

async function updateLocalScanHint() {
  const text = localScanText();
  const workspace = els.localScanWorkspaceSelect ? els.localScanWorkspaceSelect.value : '';
  if (!els.localScanHint || !workspace) return;

  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/history?workspace=${encodeURIComponent(workspace)}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    const lastRun = (payload.runs || [])[0];
    if (!lastRun) {
      els.localScanHint.textContent = text.noHistory;
      return;
    }
    const seconds = Math.round(parseCsvNumber(lastRun.duration_seconds));
    const when = lastRun.started_at ? new Date(lastRun.started_at).toLocaleString(state.lang === 'es' ? 'es-ES' : 'en-GB') : '';
    els.localScanHint.textContent = text.lastRun(seconds, when, lastRun.status);
  } catch (error) {
    els.localScanHint.textContent = '';
  }
}

async function triggerLocalScan() {
  const text = localScanText();
  const workspace = els.localScanWorkspaceSelect ? els.localScanWorkspaceSelect.value : '';
  if (!workspace) {
    if (els.localScanStatus) els.localScanStatus.textContent = text.selectWorkspace;
    return;
  }

  setLocalScanControlsDisabled(true);
  if (els.localScanStatus) els.localScanStatus.textContent = text.starting;

  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/scan`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ workspace })
    });
    const payload = await response.json().catch(() => ({}));

    if (response.status === 202 && payload.status === 'queued') {
      myQueuedEntryId = payload.queue_id || null;
      if (els.localScanStatus) els.localScanStatus.textContent = text.queued(workspace, payload.position);
      setLocalScanControlsDisabled(false);
      return;
    }
    if (response.status === 202) {
      if (els.localScanStatus) els.localScanStatus.textContent = text.running(workspace, 0);
      setLocalScanControlsDisabled(false);
      return;
    }
    if (response.status === 401 && payload.error === 'sign_in_required') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.signInRequired;
    } else if (response.status === 429 && payload.error === 'queue_full') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.queueFull;
    } else if (response.status === 409 && payload.error === 'az_session_invalid') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.azSessionInvalid;
    } else if (response.status === 409 && payload.error === 'scan_already_running') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.alreadyRunning(localScanDisplayName(payload.current_workspace) || workspace);
    } else if (response.status === 404) {
      if (els.localScanStatus) els.localScanStatus.textContent = text.notFound;
    } else {
      if (els.localScanStatus) els.localScanStatus.textContent = payload.message || text.genericError;
    }
    setLocalScanControlsDisabled(false);
  } catch (error) {
    if (els.localScanStatus) els.localScanStatus.textContent = text.unreachable;
    setLocalScanControlsDisabled(false);
  }
}

async function triggerFullScan() {
  const text = localScanText();
  const confirmMessage = state.lang === 'es'
    ? 'Esto reescanea contra Fabric real (varias horas) todo el tenant si eres Fabric Administrator, o si no los workspaces a los que tengas acceso. ¿Continuar?'
    : 'This re-scans against real Fabric (several hours) the whole tenant if you are a Fabric Administrator, or otherwise just the workspaces you have access to. Continue?';
  if (!window.confirm(confirmMessage)) return;

  setLocalScanControlsDisabled(true);
  if (els.localScanStatus) els.localScanStatus.textContent = text.starting;

  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/scan-full`, { method: 'POST' });
    const payload = await response.json().catch(() => ({}));

    if (response.status === 202 && payload.status === 'queued') {
      myQueuedEntryId = payload.queue_id || null;
      if (els.localScanStatus) els.localScanStatus.textContent = text.queued(localScanDisplayName(FULL_SCAN_LABEL), payload.position);
      setLocalScanControlsDisabled(false);
      return;
    }
    if (response.status === 202) {
      const label = payload.is_tenant_admin_scan
        ? text.runningTenantWide(payload.workspace_count || 0)
        : text.running(localScanDisplayName(FULL_SCAN_LABEL), 0);
      if (els.localScanStatus) els.localScanStatus.textContent = label;
      setLocalScanControlsDisabled(false);
      return;
    }
    if (response.status === 401 && payload.error === 'sign_in_required') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.signInRequired;
    } else if (response.status === 429 && payload.error === 'queue_full') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.queueFull;
    } else if (response.status === 409 && payload.error === 'az_session_invalid') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.azSessionInvalid;
    } else if (response.status === 409 && payload.error === 'scan_already_running') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.alreadyRunning(localScanDisplayName(payload.current_workspace) || '');
    } else if (response.status === 502 && payload.error === 'workspace_discovery_failed') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.workspaceDiscoveryFailed;
    } else if (response.status === 403 && payload.error === 'no_accessible_workspaces') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.noAccessibleWorkspaces;
    } else {
      if (els.localScanStatus) els.localScanStatus.textContent = payload.message || text.genericError;
    }
    setLocalScanControlsDisabled(false);
  } catch (error) {
    if (els.localScanStatus) els.localScanStatus.textContent = text.unreachable;
    setLocalScanControlsDisabled(false);
  }
}

function renderScanQueue(queue) {
  if (!els.localScanQueue) return;
  if (!queue || !queue.length) {
    els.localScanQueue.hidden = true;
    els.localScanQueue.innerHTML = '';
    return;
  }
  const text = localScanText();
  const rows = queue
    .map(entry => `<div class="local-scan-queue-row">${escapeHtml(text.queueRow(entry.position, localScanDisplayName(entry.workspace), entry.requested_by_email || ''))}</div>`)
    .join('');
  els.localScanQueue.innerHTML = `<div class="local-scan-queue-heading">${escapeHtml(text.queueHeading)}</div>${rows}`;
  els.localScanQueue.hidden = false;
}

async function pollLocalScanStatus() {
  const text = localScanText();
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/status`);
    if (!response.ok) return;
    const payload = await response.json();
    const queue = payload.queue || [];
    renderScanQueue(queue);

    // This tab's own queued request (if any) keeps its dedicated message
    // -- with a live position -- instead of the server-wide status below
    // overwriting it while it's still just waiting its turn.
    if (myQueuedEntryId) {
      const mine = queue.find(entry => entry.queue_id === myQueuedEntryId);
      if (mine) {
        if (els.localScanStatus) els.localScanStatus.textContent = text.queued(localScanDisplayName(mine.workspace), mine.position);
        localScanLastKnownStatus = payload.status;
        return;
      }
      // No longer queued -- either it just started (the server-wide status
      // below now reflects it, since only one scan runs at a time) or it
      // was dropped (e.g. session expired while waiting, recorded to
      // history as a failure) -- either way, fall through to the normal
      // status rendering below.
      myQueuedEntryId = null;
    }

    const displayName = localScanDisplayName(payload.workspace);
    const isRunning = payload.status === 'running';
    setScanRunningUi(isRunning);

    if (isRunning) {
      const startedAt = payload.started_at ? new Date(payload.started_at).getTime() : Date.now();
      const elapsedSeconds = Math.max(0, Math.round((Date.now() - startedAt) / 1000));
      if (els.localScanStatus) {
        els.localScanStatus.textContent = payload.is_tenant_admin_scan
          ? text.runningTenantWide(payload.workspace_count || 0)
          : text.running(displayName, elapsedSeconds);
      }

      const progress = formatScanProgress(payload.progress, elapsedSeconds);
      if (els.scanProgressFill && els.scanProgressText && els.scanProgressStep) {
        if (progress) {
          els.scanProgressFill.style.width = `${progress.percent}%`;
          els.scanProgressText.textContent = progress.text;
          els.scanProgressStep.textContent = progress.stepName;
        } else {
          // No progress.json yet (step just started, or this run predates
          // the progress-tracking steps) -- keep the bar visible but
          // empty rather than showing a stale or misleading percentage.
          els.scanProgressFill.style.width = '0%';
          els.scanProgressText.textContent = `${elapsedSeconds}s`;
          els.scanProgressStep.textContent = '';
        }
      }
      // Same bar, same formatScanProgress() output, just also mirrored into
      // the admin panel's write-target tab (elements only exist once that
      // tab has actually been rendered, hence the plain getElementById
      // instead of the els object -- see renderAdminPanel) -- so "Copiar
      // datos ahora" shows percentage/step/time without a second polling
      // loop of its own.
      if (payload.workspace === WAREHOUSE_UPLOAD_LABEL) {
        const wrap = document.getElementById('adminWarehouseUploadProgress');
        const fill = document.getElementById('adminWarehouseUploadFill');
        const textEl = document.getElementById('adminWarehouseUploadText');
        const stepEl = document.getElementById('adminWarehouseUploadStep');
        if (wrap) wrap.hidden = false;
        if (fill && textEl && stepEl) {
          if (progress) {
            fill.style.width = `${progress.percent}%`;
            textEl.textContent = progress.text;
            stepEl.textContent = progress.stepName;
          } else {
            fill.style.width = '0%';
            textEl.textContent = `${elapsedSeconds}s`;
            stepEl.textContent = '';
          }
        }
      }
      if (payload.workspace === ONELAKE_PUBLISH_LABEL) {
        const wrap = document.getElementById('adminOneLakePublishProgress');
        const fill = document.getElementById('adminOneLakePublishFill');
        const textEl = document.getElementById('adminOneLakePublishText');
        const stepEl = document.getElementById('adminOneLakePublishStep');
        if (wrap) wrap.hidden = false;
        if (fill && textEl && stepEl) {
          if (progress) {
            fill.style.width = `${progress.percent}%`;
            textEl.textContent = progress.text;
            stepEl.textContent = progress.stepName;
          } else {
            fill.style.width = '0%';
            textEl.textContent = `${elapsedSeconds}s`;
            stepEl.textContent = '';
          }
        }
      }
    } else if (payload.status === 'succeeded') {
      if (els.localScanStatus) {
        els.localScanStatus.textContent = text.succeeded(displayName, Math.round(payload.duration_seconds || 0));
      }
    } else if (payload.status === 'failed') {
      if (els.localScanStatus) {
        els.localScanStatus.textContent = text.failed(displayName, payload.last_error || '');
      }
    } else if (payload.status === 'cancelled') {
      if (els.localScanStatus) {
        els.localScanStatus.textContent = text.cancelled(displayName, Math.round(payload.duration_seconds || 0));
      }
    }
    if (!isRunning && payload.workspace === WAREHOUSE_UPLOAD_LABEL) {
      const wrap = document.getElementById('adminWarehouseUploadProgress');
      if (wrap) wrap.hidden = true;
      const resultEl = document.querySelector('[data-test-result="warehouse-upload"]');
      if (resultEl && payload.status !== 'running') {
        resultEl.textContent = payload.status === 'succeeded'
          ? (state.lang === 'es' ? `Copiado correctamente (${Math.round(payload.duration_seconds || 0)}s).` : `Copied successfully (${Math.round(payload.duration_seconds || 0)}s).`)
          : payload.status === 'failed'
            ? (state.lang === 'es' ? `Fallo al copiar: ${payload.last_error || ''}` : `Copy failed: ${payload.last_error || ''}`)
            : '';
        resultEl.className = `admin-test-result ${payload.status === 'succeeded' ? 'ok' : payload.status === 'failed' ? 'fail' : ''}`;
      }
    }
    if (!isRunning && payload.workspace === ONELAKE_PUBLISH_LABEL) {
      const wrap = document.getElementById('adminOneLakePublishProgress');
      if (wrap) wrap.hidden = true;
      const resultEl = document.querySelector('[data-test-result="onelake-publish"]');
      if (resultEl && payload.status !== 'running') {
        resultEl.textContent = payload.status === 'succeeded'
          ? (state.lang === 'es' ? `Publicado correctamente (${Math.round(payload.duration_seconds || 0)}s).` : `Published successfully (${Math.round(payload.duration_seconds || 0)}s).`)
          : payload.status === 'failed'
            ? (state.lang === 'es' ? `Fallo al publicar: ${payload.last_error || ''}` : `Publish failed: ${payload.last_error || ''}`)
            : '';
        resultEl.className = `admin-test-result ${payload.status === 'succeeded' ? 'ok' : payload.status === 'failed' ? 'fail' : ''}`;
      }
    }

    const justFinished = localScanLastKnownStatus === 'running' && !isRunning;
    localScanLastKnownStatus = payload.status;
    if (justFinished) {
      updateLocalScanHint();
    }
  } catch (error) {
    // Trigger server not reachable right now; leave the last known status visible.
  }
}

async function triggerStopScan() {
  const text = localScanText();
  if (els.stopScanButton) els.stopScanButton.disabled = true;
  if (els.localScanStatus) els.localScanStatus.textContent = text.stopping;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/scan-stop`, { method: 'POST' });
    const payload = await response.json().catch(() => ({}));
    if (response.status === 409 && payload.error === 'no_scan_running') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.noScanRunning;
    } else if (response.status === 401 && payload.error === 'sign_in_required') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.signInRequired;
    } else if (response.status === 403 && payload.error === 'not_permitted') {
      if (els.localScanStatus) els.localScanStatus.textContent = text.notPermittedStop;
    } else if (!response.ok) {
      if (els.localScanStatus) els.localScanStatus.textContent = payload.message || text.stopError;
    }
  } catch (error) {
    if (els.localScanStatus) els.localScanStatus.textContent = text.unreachable;
  }
  if (els.stopScanButton) els.stopScanButton.disabled = false;
}

function scanHistoryStatusLabel(status) {
  if (status === 'succeeded') return state.lang === 'es' ? 'Correcto' : 'Succeeded';
  if (status === 'failed') return state.lang === 'es' ? 'Falló' : 'Failed';
  if (status === 'cancelled') return state.lang === 'es' ? 'Detenido' : 'Stopped';
  return status || (state.lang === 'es' ? 'Desconocido' : 'Unknown');
}

let scanHistoryRunsCache = [];
let scanHistoryExpandedKeys = new Set();
const scanHistoryDiffDetailCache = new Map();

function scanHistoryRunKey(run) {
  return `${run.workspace_name || ''}|${run.started_at || ''}`;
}

// Compact "+3 -1 ~2" summary for the history table row itself -- this is
// the "todos los elementos modificados en ese escaneo contabilizados por
// tipo" headline the log was missing, before anyone expands a row.
function scanDiffSummaryHtml(run) {
  const d = localScanText();
  const added = Number(run.diff_added || 0);
  const removed = Number(run.diff_removed || 0);
  const modified = Number(run.diff_modified || 0);
  if (!run.diff_added && !run.diff_removed && !run.diff_modified) return '';
  const parts = [];
  if (added) parts.push(`<span class="scan-diff-added">+${number(added)}</span>`);
  if (removed) parts.push(`<span class="scan-diff-removed">-${number(removed)}</span>`);
  if (modified) parts.push(`<span class="scan-diff-modified">~${number(modified)}</span>`);
  return parts.length ? parts.join(' ') : `<span class="scan-diff-none">${escapeHtml(d.diffNoChanges)}</span>`;
}

function parseDiffByType(run) {
  if (!run.diff_by_type_json) return {};
  try {
    return JSON.parse(run.diff_by_type_json) || {};
  } catch (error) {
    return {};
  }
}

// The expanded detail row's per-type breakdown table -- one row per item
// type that changed, each column only shown if at least one bucket has a
// nonzero total across every type (avoids three near-empty columns for a
// run that, say, only ever adds items).
function scanDiffByTypeTableHtml(run) {
  const d = localScanText();
  const byType = parseDiffByType(run);
  const types = Object.keys(byType).sort((a, b) => itemTypeLabel(a).localeCompare(itemTypeLabel(b)));
  if (!types.length) return '';
  const rows = types.map(type => {
    const counts = byType[type] || {};
    return `<tr>
      <td>${escapeHtml(itemTypeLabel(type))}</td>
      <td>${counts.added ? `<span class="scan-diff-added">+${number(counts.added)}</span>` : ''}</td>
      <td>${counts.removed ? `<span class="scan-diff-removed">-${number(counts.removed)}</span>` : ''}</td>
      <td>${counts.modified ? `<span class="scan-diff-modified">~${number(counts.modified)}</span>` : ''}</td>
    </tr>`;
  }).join('');
  const headLabels = state.lang === 'es' ? ['Tipo', 'Añadidos', 'Eliminados', 'Modificados'] : ['Type', 'Added', 'Removed', 'Modified'];
  return `<table class="scan-diff-by-type-table"><thead><tr>${headLabels.map(label => `<th>${escapeHtml(label)}</th>`).join('')}</tr></thead><tbody>${rows}</tbody></table>`;
}

function scanDiffSampleListHtml(label, items) {
  if (!items || !items.length) return '';
  const rows = items.map(item => `<li>${escapeHtml(itemTypeLabel(item.item_type))} · ${escapeHtml(item.item_name)} <span class="scan-diff-sample-workspace">(${escapeHtml(item.workspace_name)})</span></li>`).join('');
  return `<div class="scan-diff-sample-group"><h5>${escapeHtml(label)}</h5><ul class="scan-diff-sample-list">${rows}</ul></div>`;
}

async function loadScanDiffSamples(container, diffPath) {
  const d = localScanText();
  if (!authState.signedIn) {
    container.innerHTML = `<div class="scan-diff-samples-error">${escapeHtml(d.diffSignInForSamples)}</div>`;
    return;
  }
  if (scanHistoryDiffDetailCache.has(diffPath)) {
    container.innerHTML = scanHistoryDiffDetailCache.get(diffPath);
    return;
  }
  container.innerHTML = `<div class="scan-diff-samples-loading">${escapeHtml(d.diffLoadingSamples)}</div>`;
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/history/diff?path=${encodeURIComponent(diffPath)}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const detail = await response.json();
    const html = [
      scanDiffSampleListHtml(d.diffAddedSample, detail.added_sample),
      scanDiffSampleListHtml(d.diffRemovedSample, detail.removed_sample),
      scanDiffSampleListHtml(d.diffModifiedSample, detail.modified_sample)
    ].filter(Boolean).join('') || `<div class="scan-history-empty">${escapeHtml(d.diffNoChanges)}</div>`;
    scanHistoryDiffDetailCache.set(diffPath, html);
    container.innerHTML = html;
  } catch (error) {
    container.innerHTML = `<div class="scan-diff-samples-error">${escapeHtml(d.diffSamplesError)}</div>`;
  }
}

function renderScanHistoryTable(runs) {
  const d = localScanText();
  if (!runs.length) {
    els.scanHistoryBody.innerHTML = `<div class="scan-history-empty">${state.lang === 'es' ? 'Todavía no hay escaneos registrados.' : 'No scans recorded yet.'}</div>`;
    return;
  }
  const rows = runs.map(run => {
    const key = scanHistoryRunKey(run);
    const name = escapeHtml(localScanDisplayName(run.workspace_name) || '');
    const when = run.started_at ? new Date(run.started_at).toLocaleString(state.lang === 'es' ? 'es-ES' : 'en-GB') : '';
    const seconds = Math.round(parseCsvNumber(run.duration_seconds));
    const status = (run.status || '').toLowerCase();
    const detail = escapeHtml(run.failed_step ? `${run.failed_step}: ${run.error || ''}` : (run.error || ''));
    const who = escapeHtml(run.triggered_by_email || (state.lang === 'es' ? 'anónimo' : 'anonymous'));
    const diffSummary = scanDiffSummaryHtml(run);
    const hasDiff = Boolean(run.diff_added || run.diff_removed || run.diff_modified || run.diff_by_type_json);
    const expanded = scanHistoryExpandedKeys.has(key);
    // Only the button itself is a toggle target -- it used to also live
    // inside a <tr data-diff-toggle>, so a click bubbled into BOTH
    // listeners and toggled the Set twice, silently cancelling itself out.
    const mainRow = `<tr class="scan-history-row${hasDiff ? ' has-diff' : ''}">
      <td>${name}</td>
      <td>${who}</td>
      <td>${escapeHtml(when)}</td>
      <td>${seconds}s</td>
      <td><span class="scan-history-status ${escapeHtml(status)}">${escapeHtml(scanHistoryStatusLabel(status))}</span></td>
      <td>${detail}</td>
      <td>${hasDiff ? `<button type="button" class="scan-diff-toggle-button" data-diff-toggle="${escapeHtml(key)}">${diffSummary || escapeHtml(d.diffNoChanges)}</button>` : (diffSummary || '')}</td>
    </tr>`;
    if (!hasDiff) return mainRow;
    const byTypeTable = scanDiffByTypeTableHtml(run) || `<div class="scan-history-empty">${escapeHtml(d.diffNoChanges)}</div>`;
    const detailRow = `<tr class="scan-diff-detail-row" data-diff-detail="${escapeHtml(key)}"${expanded ? '' : ' hidden'}>
      <td colspan="7">
        <div class="scan-diff-detail">
          <h4>${escapeHtml(d.diffByType)}</h4>
          ${byTypeTable}
          ${run.diff_path ? `<button type="button" class="scan-diff-samples-button" data-diff-samples="${escapeHtml(run.diff_path)}">${escapeHtml(d.diffViewSamples)}</button><div class="scan-diff-samples" data-diff-samples-container="${escapeHtml(run.diff_path)}"></div>` : ''}
        </div>
      </td>
    </tr>`;
    return mainRow + detailRow;
  }).join('');
  const headLabels = state.lang === 'es'
    ? ['Alcance', 'Quién', 'Inicio', 'Duración', 'Estado', 'Detalle', d.diffChanges]
    : ['Scope', 'Who', 'Started', 'Duration', 'Status', 'Detail', d.diffChanges];
  els.scanHistoryBody.innerHTML = `<table class="scan-history-table"><thead><tr>${headLabels.map(label => `<th>${escapeHtml(label)}</th>`).join('')}</tr></thead><tbody>${rows}</tbody></table>`;

  els.scanHistoryBody.querySelectorAll('[data-diff-toggle]').forEach(el => {
    el.addEventListener('click', () => {
      const key = el.dataset.diffToggle;
      if (scanHistoryExpandedKeys.has(key)) scanHistoryExpandedKeys.delete(key);
      else scanHistoryExpandedKeys.add(key);
      renderScanHistoryTable(scanHistoryRunsCache);
    });
  });
  els.scanHistoryBody.querySelectorAll('[data-diff-samples]').forEach(button => {
    button.addEventListener('click', () => {
      const path = button.dataset.diffSamples;
      const container = els.scanHistoryBody.querySelector(`[data-diff-samples-container="${CSS.escape(path)}"]`);
      const showing = button.classList.toggle('expanded');
      if (!showing) {
        if (container) container.innerHTML = '';
        button.textContent = localScanText().diffViewSamples;
        return;
      }
      button.textContent = localScanText().diffHideSamples;
      if (container) loadScanDiffSamples(container, path);
    });
  });
}

async function renderScanHistory() {
  if (!els.scanHistoryBody) return;
  els.scanHistoryBody.textContent = state.lang === 'es' ? 'Cargando...' : 'Loading...';
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/history`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    scanHistoryRunsCache = payload.runs || [];
    renderScanHistoryTable(scanHistoryRunsCache);
  } catch (error) {
    els.scanHistoryBody.innerHTML = `<div class="scan-history-empty">${localScanText().unreachable}</div>`;
  }
}

function toggleScanHistoryPanel(forceOpen) {
  if (!els.scanHistoryPanel) return;
  const open = forceOpen !== undefined ? forceOpen : els.scanHistoryPanel.hidden;
  if (open) {
    openModal(els.scanHistoryPanel);
    renderScanHistory();
  } else {
    els.scanHistoryPanel.hidden = true;
    if (els.modalBackdrop) els.modalBackdrop.hidden = true;
  }
}

// 2026-08-24: split out of the old initLocalScanPanel so the panel's
// listeners can be wired at page load (the panel itself is now always in
// the DOM, not hidden until sign-in -- see renderLockedShell) without
// firing any request before a session exists. Safe to call once, before
// auth resolves -- addEventListener on an element that's merely disabled
// is a no-op until it's re-enabled, same as any other disabled control.
function wireLocalScanPanel() {
  if (!els.localScanPanel || localScanPanelWired) return;
  localScanPanelWired = true;

  if (els.localScanButton) {
    els.localScanButton.addEventListener('click', triggerLocalScan);
  }
  if (els.fullScanButton) {
    els.fullScanButton.addEventListener('click', triggerFullScan);
  }
  if (els.stopScanButton) {
    els.stopScanButton.addEventListener('click', triggerStopScan);
  }
  if (els.scanHistoryButton) {
    els.scanHistoryButton.addEventListener('click', () => toggleScanHistoryPanel());
  }
  if (els.scanHistoryCloseButton) {
    els.scanHistoryCloseButton.addEventListener('click', () => toggleScanHistoryPanel(false));
  }
  if (els.localScanWorkspaceSelect) {
    els.localScanWorkspaceSelect.addEventListener('change', updateLocalScanHint);
  }
}

function initLocalScanPanel() {
  if (!els.localScanPanel) return;

  wireLocalScanPanel();
  fetchLocalScanWorkspaces();
  pollLocalScanStatus();

  if (localScanPollHandle) clearInterval(localScanPollHandle);
  localScanPollHandle = setInterval(pollLocalScanStatus, 4000);
}

const LOADING_FILES = [
  { key: 'data', url: './data/lineage-explorer.json', required: true },
  { key: 'impact', url: './data/object-impact.json', required: false },
  { key: 'notebookSuperLineage', url: './data/notebook-super-lineage.json', required: false }
];

function renderLoadingProgress() {
  if (!els.treeStage) return;
  const loading = i18n[state.lang].loading;
  els.treeStage.innerHTML = `
    <div class="loading-progress">
      <div class="loading-progress-title">${escapeHtml(loading.title)}</div>
      <div class="loading-progress-files">
        ${LOADING_FILES.map(file => `
          <div class="loading-progress-file" data-loading-key="${file.key}">
            <div class="loading-progress-file-row">
              <span>${escapeHtml(loading.file[file.key] || file.key)}</span>
              <span class="loading-progress-file-pct">0%</span>
            </div>
            <div class="loading-progress-bar"><div class="loading-progress-bar-fill"></div></div>
          </div>
        `).join('')}
      </div>
    </div>
  `;
}

function updateLoadingProgress(key, loaded, total, parsing) {
  if (!els.treeStage) return;
  const row = els.treeStage.querySelector(`[data-loading-key="${key}"]`);
  if (!row) return;
  const fill = row.querySelector('.loading-progress-bar-fill');
  const pct = row.querySelector('.loading-progress-file-pct');
  const loading = i18n[state.lang].loading;
  if (parsing || !total) {
    fill.classList.add('indeterminate');
    if (pct) pct.textContent = parsing ? loading.parsing : '';
  } else {
    fill.classList.remove('indeterminate');
    const ratio = Math.min(100, Math.round((loaded / total) * 100));
    fill.style.width = `${ratio}%`;
    if (pct) pct.textContent = loading.downloading(ratio);
  }
}

function loadLineageDataViaWorker() {
  return new Promise((resolve, reject) => {
    let worker;
    try {
      worker = new Worker('./data-loader-worker.js');
    } catch (error) {
      reject(error);
      return;
    }
    const results = {};
    let settled = false;
    worker.onmessage = event => {
      const message = event.data || {};
      if (message.type === 'progress') {
        updateLoadingProgress(message.key, message.loaded, message.total, false);
      } else if (message.type === 'parsing') {
        updateLoadingProgress(message.key, 0, 0, true);
      } else if (message.type === 'data') {
        results[message.key] = message.data;
      } else if (message.type === 'error') {
        settled = true;
        worker.terminate();
        reject(new Error(message.message));
      } else if (message.type === 'complete') {
        settled = true;
        worker.terminate();
        resolve(results);
      }
    };
    worker.onerror = error => {
      if (settled) return;
      settled = true;
      worker.terminate();
      reject(error);
    };
    worker.postMessage({ urls: LOADING_FILES });
  });
}

async function loadLineageDataOnMainThread() {
  if (els.treeStage) {
    els.treeStage.innerHTML = `<div class="empty-state">${escapeHtml(i18n[state.lang].loading.fallback)}</div>`;
  }
  // The required file's response can be a non-JSON error body (401 "Sign
  // in required...", a proxy timeout page, etc.) -- checking response.ok
  // and reading the body as text first (instead of handing a possibly-
  // non-JSON response straight to .json()) turns that into a real,
  // readable error message instead of a bare "Unexpected end of JSON
  // input"/"Unexpected token" thrown from deep inside JSON.parse with no
  // context (confirmed live 2026-08-18: this exact path is what a
  // stuck "Cargando (modo compatibilidad)..." screen was silently
  // failing on, with nothing surfaced to the user).
  const dataResponse = await fetch('./data/lineage-explorer.json');
  const dataText = await dataResponse.text();
  if (!dataResponse.ok) {
    throw new Error(`HTTP ${dataResponse.status} loading lineage-explorer.json: ${dataText.slice(0, 200) || dataResponse.statusText}`);
  }
  let data;
  try {
    data = JSON.parse(dataText);
  } catch (error) {
    throw new Error(`lineage-explorer.json response was not valid JSON (${dataText.length} bytes received): ${error.message}`);
  }
  const impact = await fetch('./data/object-impact.json')
    .then(response => response.ok ? response.json() : null)
    .catch(() => null);
  const notebookSuperLineage = await fetch('./data/notebook-super-lineage.json')
    .then(response => response.ok ? response.json() : null)
    .catch(() => null);
  return { data, impact, notebookSuperLineage };
}

// Access is fully gated on sign-in: init() checks whether a valid session
// cookie already exists, and the large lineage payload (see
// LOADING_FILES) is never fetched until that check (or a fresh
// device-code sign-in via pollDeviceFlow) confirms authState.signedIn --
// see docs/102_admin_panel_and_user_auth.md. The shell itself (topbar,
// mode bar, scan panel, workspace list) is no longer part of that gate
// (2026-08-24) -- it renders locked from the very first frame instead
// (see renderLockedShell), so nothing pops into existence and shifts the
// page around at the moment sign-in completes. The one exception is a
// server started with LINEAGE_DEMO_MODE=1 for the synthetic demo tenant
// (backend/scripts/generate_demo_data.py): /api/auth/me then reports
// demo_mode, the server already serves reads without a session, and the
// app boots straight into the read-only explorer with no gate. The
// server, not this check, is the security boundary either way.
async function init() {
  // The standalone export (scripts/10_build_semantic_lineage_standalone.ps1)
  // embeds this exact same app.js inline with its data pre-loaded onto
  // `window` and no server behind it at all -- there is nothing to sign
  // into, so the gate only applies to the live, server-backed app where
  // these globals are never set ahead of time.
  const isStandalone = Boolean(window.LINEAGE_EXPLORER_DATA || window.SEMANTIC_LINEAGE_DATA);
  renderLockedShell();
  await initAuthArea();
  if (!isStandalone && !authState.signedIn && !authState.demoMode) {
    showAuthGate();
    return;
  }
  await bootApp();
}

async function bootApp() {
  hideAuthGate();

  let data = window.LINEAGE_EXPLORER_DATA || window.SEMANTIC_LINEAGE_DATA;
  let impact = window.OBJECT_IMPACT_DATA;
  let notebookSuperLineage = window.NOTEBOOK_SUPER_LINEAGE_DATA;

  // The progress bar/skeleton added for the Worker-based load (unlike the
  // old static "Cargando..." text) makes the page look alive well before
  // state.data actually exists, which invites clicking mode/workspace
  // buttons early -- those handlers read state.data and would throw.
  // Stay locked (renderLockedShell already disabled everything) for the
  // ~1-10s the big JSON takes to fetch and parse.
  if (!data) {
    let results;
    if (typeof Worker !== 'undefined') {
      renderLoadingProgress();
      try {
        results = await loadLineageDataViaWorker();
      } catch (error) {
        results = await loadLineageDataOnMainThread();
      }
    } else {
      results = await loadLineageDataOnMainThread();
    }
    data = results.data;
    impact = results.impact;
    notebookSuperLineage = results.notebookSuperLineage;
  }

  reconstructWorkspaceAllLists(data);
  mergeNotebookSuperLineage(data, notebookSuperLineage);
  resolveEmbeddedItemReferences(data);
  state.data = data;
  state.impact = impact;
  if (state.data && impact) state.data.impact = impact;
  if (authState.signedIn) loadCertificationsAndTags(); // fire-and-forget, see its own comment
  unlockShellControls();
  setMode('all');
  if (state.sceneEnabled) startScene();
  initLocalScanPanel();
  openHelpPanelOnFirstVisit();
}

const HELP_SEEN_STORAGE_KEY = 'lineageExplorerHelpSeen';

// A colleague opening the shared link cold has no context: no login screen,
// no product tour, nothing but the diagram itself. Surface the existing
// help panel once automatically instead of relying on someone noticing the
// small "?" button first.
function openHelpPanelOnFirstVisit() {
  try {
    if (window.localStorage.getItem(HELP_SEEN_STORAGE_KEY)) return;
    window.localStorage.setItem(HELP_SEEN_STORAGE_KEY, '1');
  } catch (error) {
    // Storage unavailable (private mode, disabled cookies, etc.) -- skip
    // the "only once" tracking rather than failing to load the page.
    return;
  }
  toggleHelpPanel(true);
}

function renderHelpPanel() {
  if (!els.helpPanel) return;
  const help = i18n[state.lang].help;
  const refresh = (state.data && state.data.refresh) || {};
  // Use this JSON file's own modified_at (from the artifact freshness list),
  // not refresh.latest_run_ended_at: that field only reflects the last full
  // 99_refresh_lineage_project.ps1 run, while the data actually being shown
  // is refreshed much more often via per-workspace scans that never touch
  // that manifest.
  const artifacts = Array.isArray(refresh.artifacts) ? refresh.artifacts : [];
  const selfArtifact = artifacts.find(a => typeof a.path === 'string' && a.path.endsWith('lineage-explorer.json'));
  const lastUpdatedRaw = (selfArtifact && selfArtifact.modified_at) || refresh.latest_run_ended_at || refresh.status_generated_at || '';
  let lastUpdatedText = help.lastUpdatedUnknown;
  if (lastUpdatedRaw) {
    const parsed = new Date(lastUpdatedRaw);
    const formatted = Number.isNaN(parsed.getTime())
      ? lastUpdatedRaw
      : parsed.toLocaleString(state.lang === 'es' ? 'es-ES' : 'en-GB');
    lastUpdatedText = help.lastUpdated(formatted);
  }
  els.helpPanel.innerHTML = `
    <div class="scan-history-header">
      <h3>${escapeHtml(help.title)}</h3>
      <button type="button" class="icon-button" data-close-modal aria-label="${state.lang === 'es' ? 'Cerrar' : 'Close'}">×</button>
    </div>
    <ul>${help.items.map(item => `<li>${escapeHtml(item)}</li>`).join('')}</ul>
    <p class="help-last-updated">${escapeHtml(lastUpdatedText)}</p>
  `;
  const closeButton = els.helpPanel.querySelector('[data-close-modal]');
  if (closeButton) closeButton.addEventListener('click', () => toggleHelpPanel(false));
}

function toggleHelpPanel(forceOpen) {
  if (!els.helpPanel || !els.helpButton) return;
  const shouldOpen = typeof forceOpen === 'boolean' ? forceOpen : els.helpPanel.hidden;
  if (shouldOpen) {
    renderHelpPanel();
    openModal(els.helpPanel);
  } else {
    els.helpPanel.hidden = true;
    if (els.modalBackdrop) els.modalBackdrop.hidden = true;
  }
  els.helpButton.setAttribute('aria-expanded', String(shouldOpen));
}

// Every inline info icon next to a classification label (see row()'s
// glossaryTerm param) opens this same shared panel, scrolled/highlighted to
// the specific term that was clicked -- one glossary, many entry points,
// same blurred-backdrop modal behavior as the header help button.
// Tanda C (2026-07-09): jumps the main search box to one qualified_name,
// the same way typing it by hand would -- reused so a business glossary
// term's linked assets are one click away from "here's the actual data".
function searchForQualifiedName(qualifiedName) {
  state.search = qualifiedName;
  state.history = [];
  state.selectedNode = null;
  if (els.searchInput) els.searchInput.value = qualifiedName;
  if (state.viewMode === 'impact') {
    scheduleImpactSearchRender('#searchInput', qualifiedName.length, qualifiedName.length);
  } else {
    render();
  }
  toggleGlossaryPanel(false);
}

async function loadBusinessGlossary() {
  try {
    const response = await fetch(`${TRIGGER_SERVER_ORIGIN}/api/business-glossary`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    businessGlossaryCache = payload.terms || [];
  } catch (error) {
    businessGlossaryCache = [];
  }
  if (els.glossaryPanel && !els.glossaryPanel.hidden) renderGlossaryPanel();
}

function renderBusinessGlossarySection() {
  const es = state.lang === 'es';
  if (!businessGlossaryCache || !businessGlossaryCache.length) return '';
  return `
    <h4 class="glossary-section-title">${es ? 'Glosario de negocio' : 'Business glossary'}</h4>
    ${businessGlossaryCache.map(entry => `
      <div class="glossary-term glossary-term-business">
        <h4>${escapeHtml(es ? (entry.term_es || entry.term_en) : (entry.term_en || entry.term_es))}</h4>
        <p>${escapeHtml(es ? (entry.definition_es || entry.definition_en) : (entry.definition_en || entry.definition_es))}</p>
        ${(entry.linked_qualified_names || []).length ? `
          <div class="glossary-linked-assets">
            ${entry.linked_qualified_names.map(name => `<button type="button" class="glossary-linked-asset" data-glossary-search="${escapeHtml(name)}">${escapeHtml(name)}</button>`).join('')}
          </div>` : ''}
      </div>
    `).join('')}
    <h4 class="glossary-section-title">${es ? 'Conceptos de la herramienta' : 'Tool concepts'}</h4>
  `;
}

function renderGlossaryPanel(highlightTerm) {
  if (!els.glossaryPanel) return;
  const glossary = i18n[state.lang].glossary;
  if (els.glossaryTitle) els.glossaryTitle.textContent = glossary.title;
  const entries = Object.entries(glossary.terms);
  els.glossaryBody.innerHTML = renderBusinessGlossarySection() + entries.map(([key, entry]) => `
    <div class="glossary-term${key === highlightTerm ? ' is-highlighted' : ''}" data-glossary-entry="${escapeHtml(key)}">
      <h4>${escapeHtml(entry.label)}</h4>
      <p>${escapeHtml(entry.text)}</p>
    </div>
  `).join('');
  els.glossaryBody.querySelectorAll('[data-glossary-search]').forEach(button => {
    button.addEventListener('click', () => searchForQualifiedName(button.dataset.glossarySearch));
  });
}

function toggleGlossaryPanel(forceOpen, highlightTerm = '') {
  if (!els.glossaryPanel) return;
  const shouldOpen = typeof forceOpen === 'boolean' ? forceOpen : els.glossaryPanel.hidden;
  if (shouldOpen) {
    renderGlossaryPanel(highlightTerm);
    openModal(els.glossaryPanel);
    if (businessGlossaryCache === null) loadBusinessGlossary();
    if (highlightTerm) {
      const target = els.glossaryBody.querySelector(`[data-glossary-entry="${highlightTerm}"]`);
      if (target) target.scrollIntoView({ block: 'nearest' });
    }
  } else {
    els.glossaryPanel.hidden = true;
    if (els.modalBackdrop) els.modalBackdrop.hidden = true;
    restoreImpactModalIfNeeded();
  }
}

if (els.glossaryCloseButton) {
  els.glossaryCloseButton.addEventListener('click', () => toggleGlossaryPanel(false));
}

if (els.helpButton) {
  els.helpButton.addEventListener('click', () => toggleHelpPanel());
}

els.langEsButton.addEventListener('click', () => setLanguage('es'));
els.langEnButton.addEventListener('click', () => setLanguage('en'));
if (els.reinvestigateButton) els.reinvestigateButton.addEventListener('click', showReinvestigate);
els.searchInput.addEventListener('input', event => {
  const start = event.target.selectionStart;
  const end = event.target.selectionEnd;
  state.search = event.target.value;
  state.history = [];
  state.selectedNode = null;
  state.planningSourceSearch = '';
  state.planningSelectedSources = new Set();
  if (state.viewMode === 'impact') {
    scheduleImpactSearchRender('#searchInput', start, end);
    return;
  }
  render();
});
els.resetButton.addEventListener('click', resetAll);
els.focusButton.addEventListener('click', () => {
  state.focusMode = !state.focusMode;
  applyLayoutState();
});
els.detailsToggleButton.addEventListener('click', () => {
  state.showDetails = !state.showDetails;
  applyLayoutState();
});
els.inspectionButton.addEventListener('click', () => setDiagramViewMode('lineage'));
els.impactButton.addEventListener('click', () => setDiagramViewMode('impact'));
els.scheduleButton.addEventListener('click', () => setDiagramViewMode('planning'));
// Mode buttons themselves are rebuilt on every renderModeBar() call (the
// set of modes is data-driven), so their click handlers are wired there
// instead of once here. The overflow toggle/menu container elements are
// static, though (only their contents get rebuilt), so those are safe to
// wire exactly once, the same way every other static button in this file
// is.
if (els.modeOverflowToggle) {
  els.modeOverflowToggle.addEventListener('click', event => {
    event.stopPropagation();
    const opening = els.modeOverflowMenu.hidden;
    els.modeOverflowMenu.hidden = !opening;
    els.modeOverflowToggle.setAttribute('aria-expanded', String(opening));
  });
}
if (els.modeOverflowMenu) {
  els.modeOverflowMenu.addEventListener('click', event => event.stopPropagation());
}
document.addEventListener('click', () => {
  if (els.modeOverflowMenu && !els.modeOverflowMenu.hidden) {
    els.modeOverflowMenu.hidden = true;
    if (els.modeOverflowToggle) els.modeOverflowToggle.setAttribute('aria-expanded', 'false');
  }
});
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && els.modeOverflowMenu && !els.modeOverflowMenu.hidden) {
    els.modeOverflowMenu.hidden = true;
    if (els.modeOverflowToggle) els.modeOverflowToggle.setAttribute('aria-expanded', 'false');
  }
});
els.selectAllWorkspacesButton.addEventListener('click', selectAllWorkspaces);
els.clearWorkspacesButton.addEventListener('click', clearWorkspaceSelection);
if (els.workspaceSearchToggle) {
  els.workspaceSearchToggle.addEventListener('click', event => {
    event.stopPropagation();
    toggleWorkspaceSearchPanel();
  });
}
if (els.workspaceSearchInput) {
  els.workspaceSearchInput.addEventListener('input', event => {
    state.workspaceSearchQuery = event.target.value;
    renderWorkspaceSearchResults();
  });
}
if (els.workspaceSearchResults) {
  els.workspaceSearchResults.addEventListener('change', event => {
    const checkbox = event.target.closest('[data-workspace-search-key]');
    if (!checkbox) return;
    const key = checkbox.dataset.workspaceSearchKey;
    const entry = currentIndexEntries().find(candidate => candidate.key === key);
    if (!entry) return;
    applyIndexEntrySelection(entry, true);
    render();
  });
}
if (els.workspaceSearchPanel) {
  els.workspaceSearchPanel.addEventListener('click', event => event.stopPropagation());
}
document.addEventListener('click', event => {
  if (!workspaceSearchPanelOpen()) return;
  if (event.target.closest('.workspace-search-filter')) return;
  closeWorkspaceSearchPanel();
});
els.workspaceEnvironmentButtons.forEach(button => {
  button.addEventListener('click', () => toggleWorkspaceEnvironmentFilter(button.dataset.workspaceEnvFilter));
});
if (els.workspaceDomainFilter) {
  els.workspaceDomainFilter.addEventListener('change', () => setWorkspaceDomainFilter(els.workspaceDomainFilter.value));
}
els.filterButton.addEventListener('click', toggleFilterMenu);
els.filterMenu.addEventListener('pointerdown', event => {
  event.stopPropagation();
  if (event.target.closest('select, input, button')) return;
  state.filterPanel.active = true;
  state.filterPanel.x0 = event.clientX;
  state.filterPanel.y0 = event.clientY;
  els.filterMenu.setPointerCapture(event.pointerId);
});
els.filterMenu.addEventListener('pointermove', event => {
  if (!state.filterPanel.active) return;
  state.filterPanel.x += event.clientX - state.filterPanel.x0;
  state.filterPanel.y += event.clientY - state.filterPanel.y0;
  state.filterPanel.x0 = event.clientX;
  state.filterPanel.y0 = event.clientY;
  applyFilterPosition();
});
function stopFilterDrag(event) {
  state.filterPanel.active = false;
  if (event && event.pointerId !== undefined) {
    try { els.filterMenu.releasePointerCapture(event.pointerId); } catch { /* no-op */ }
  }
}
els.filterMenu.addEventListener('pointerup', stopFilterDrag);
els.filterMenu.addEventListener('pointerleave', stopFilterDrag);
els.filterMenu.addEventListener('click', event => event.stopPropagation());
els.sourceTypeFilter.addEventListener('change', event => {
  state.filters.sourceType = event.target.value;
  state.history = [];
  state.selectedNode = null;
  state.planningSourceSearch = '';
  state.planningSelectedSources = new Set();
  if (state.viewMode === 'impact') {
    state.filters.impactDatabase = 'all';
    state.filters.impactObjectType = 'all';
    clearImpactObjectSearch();
  } else if (supportsDiagramObjectFilters()) {
    state.filters.diagramStore = 'all';
    state.filters.diagramObjectType = 'all';
    clearDiagramObjectSelection('all');
  }
  render();
});
els.confidenceFilter.addEventListener('change', event => {
  if (state.viewMode === 'impact') {
    state.filters.impactDatabase = event.target.value;
    state.filters.impactObjectType = 'all';
    clearImpactObjectSearch();
    render();
    return;
  }
  if (supportsDiagramObjectFilters()) {
    state.filters.diagramStore = event.target.value;
    state.filters.diagramObjectType = 'all';
    clearDiagramObjectSelection('all');
    state.history = [];
    state.selectedNode = null;
    render();
    return;
  }
  state.filters.confidence = event.target.value;
  state.history = [];
  state.selectedNode = null;
  render();
});
els.itemTypeFilter.addEventListener('change', event => {
  if (state.viewMode === 'impact') {
    state.filters.impactObjectType = event.target.value;
    clearImpactObjectSearch();
    render();
    return;
  }
  if (supportsDiagramObjectFilters()) {
    state.filters.diagramObjectType = event.target.value;
    clearDiagramObjectSelection('all');
    state.history = [];
    state.selectedNode = null;
    render();
    return;
  }
  state.filters.itemType = event.target.value;
  state.history = [];
  state.selectedNode = null;
  keepValidWorkspaceSelection(true);
  render();
});
els.objectFilter.addEventListener('change', event => {
  state.filters.impactObjectKey = event.target.value;
  state.impactSelectedObjectKeys = new Set();
  state.impactObjectSearch = '';
  state.history = [];
  state.selectedNode = null;
  render();
});
if (els.impactObjectSearch) {
  els.impactObjectSearch.addEventListener('input', event => {
    const start = event.target.selectionStart;
    const end = event.target.selectionEnd;
    scheduleImpactObjectSearchRender('#impactObjectSearch', event.target.value, start, end);
  });
}
if (els.impactObjectClear) {
  els.impactObjectClear.addEventListener('click', event => {
    event.preventDefault();
    clearImpactObjectSearch();
    render();
  });
}
if (els.diagramObjectChecklist) {
  els.diagramObjectChecklist.addEventListener('change', event => {
    const target = event.target;
    if (!(target instanceof HTMLInputElement)) return;
    const options = diagramObjectOptionsForFilter();
    const optionKeys = options.map(option => option.key);
    if (target.matches('[data-diagram-object-all]')) {
      clearDiagramObjectSelection(target.checked ? 'all' : 'none');
    } else {
      if (state.diagramObjectSelectionMode === 'all') {
        state.diagramSelectedObjectKeys = new Set(optionKeys);
      } else if (state.diagramObjectSelectionMode !== 'custom') {
        state.diagramSelectedObjectKeys = new Set();
      }
      state.diagramObjectSelectionMode = 'custom';
      const key = target.dataset.diagramObjectKey;
      if (key) {
        if (target.checked) state.diagramSelectedObjectKeys.add(key);
        else state.diagramSelectedObjectKeys.delete(key);
      }
      if (state.diagramSelectedObjectKeys.size === optionKeys.length && optionKeys.length > 0) {
        clearDiagramObjectSelection('all');
      } else if (!state.diagramSelectedObjectKeys.size) {
        state.diagramObjectSelectionMode = 'none';
      }
    }
    state.history = [];
    state.selectedNode = null;
    render();
  });
}
els.detailContent.addEventListener('click', event => {
  const infoIcon = event.target.closest('.info-icon-button');
  if (infoIcon) {
    event.preventDefault();
    toggleGlossaryPanel(true, infoIcon.dataset.glossaryTerm);
    return;
  }
  const excelButton = event.target.closest('#detailExcelExport');
  if (excelButton) {
    event.preventDefault();
    excelButton.disabled = true;
    Promise.resolve(state.selectedNode && state.selectedNode.kind === 'impactObject'
      ? downloadImpactExcel()
      : downloadLineageExcel())
      .finally(() => {
        excelButton.disabled = false;
      });
    return;
  }
  const pngButton = event.target.closest('#detailPngExport');
  if (pngButton) {
    event.preventDefault();
    pngButton.disabled = true;
    Promise.resolve(downloadSelectedDiagramPng())
      .finally(() => {
        pngButton.disabled = false;
      });
    return;
  }
  const favoriteButton = event.target.closest('[data-node-favorite-toggle]');
  if (favoriteButton) {
    event.preventDefault();
    toggleNodeFavorite(favoriteButton.dataset.nodeFavoriteToggle, favoriteButton);
    return;
  }
  const commentSubmitButton = event.target.closest('[data-node-comment-submit]');
  if (commentSubmitButton) {
    event.preventDefault();
    submitNodeComment(commentSubmitButton.dataset.nodeCommentSubmit, commentSubmitButton);
    return;
  }
  const commentDeleteButton = event.target.closest('.node-comment-delete');
  if (commentDeleteButton) {
    event.preventDefault();
    const container = document.getElementById('nodeCommentsSection');
    deleteNodeComment(commentDeleteButton.dataset.commentId, container ? container.dataset.qualifiedName : '');
    return;
  }
  const planningEvidenceButton = event.target.closest('#planningEvidenceButton');
  if (!planningEvidenceButton) return;
  event.preventDefault();
  renderPlanningEvidenceModal();
  openModal(els.planningEvidenceModal);
});
if (els.planningEvidenceModalCloseButton) {
  els.planningEvidenceModalCloseButton.addEventListener('click', closeAllModals);
}
els.treeStage.addEventListener('click', event => {
  const badge = event.target.closest('.impact-count-badge[data-impact-object-key]');
  if (!badge) return;
  event.preventDefault();
  toggleImpactBreakdownModal(true, badge.dataset.impactObjectKey, badge.dataset.impactCategory);
});
if (els.impactBreakdownCloseButton) {
  els.impactBreakdownCloseButton.addEventListener('click', () => toggleImpactBreakdownModal(false));
}
if (els.impactBreakdownExcelButton) {
  els.impactBreakdownExcelButton.addEventListener('click', downloadImpactBreakdownExcel);
}
if (els.impactBreakdownModal) {
  els.impactBreakdownModal.addEventListener('click', event => {
    const infoIcon = event.target.closest('.info-icon-button');
    if (!infoIcon) return;
    event.preventDefault();
    impactModalWasOpenBeforeGlossary = true;
    toggleGlossaryPanel(true, infoIcon.dataset.glossaryTerm);
  });
}
if (els.adminPanel) {
  els.adminPanel.addEventListener('click', event => {
    const pill = event.target.closest('.admin-sensitivity-category[data-sensitivity-category]');
    if (!pill) return;
    event.preventDefault();
    toggleSensitivityDetailModal(true, pill.dataset.sensitivitySection, pill.dataset.sensitivityCategory);
  });
}
// "Sensibilidad detectada" now renders inside #governancePanel (2026-08-26)
// -- same delegated click needed there too.
if (els.governancePanel) {
  els.governancePanel.addEventListener('click', event => {
    const pill = event.target.closest('.admin-sensitivity-category[data-sensitivity-category]');
    if (!pill) return;
    event.preventDefault();
    toggleSensitivityDetailModal(true, pill.dataset.sensitivitySection, pill.dataset.sensitivityCategory);
  });
}
if (els.sensitivityDetailCloseButton) {
  els.sensitivityDetailCloseButton.addEventListener('click', () => toggleSensitivityDetailModal(false));
}
if (els.sensitivityDetailModal) {
  els.sensitivityDetailModal.addEventListener('click', event => {
    const badge = event.target.closest('[data-workspace-access]:not(:disabled)');
    if (!badge) return;
    event.preventDefault();
    toggleWorkspaceAccessModal(true, badge.dataset.workspaceAccess);
  });
  els.sensitivityDetailModal.addEventListener('change', event => {
    const checkbox = event.target.closest('[data-sensitivity-select-table]');
    if (!checkbox) return;
    const workspaceName = checkbox.dataset.workspaceName;
    const tableLabel = checkbox.dataset.tableLabel;
    const key = sensitivitySelectionKey(workspaceName, tableLabel);
    if (checkbox.checked) sensitivityScanSelection.set(key, { workspace_name: workspaceName, table_name: tableLabel });
    else sensitivityScanSelection.delete(key);
    // Updates the "Escanear seleccionadas" button on the MAIN sensitivity
    // tab card (behind this modal, now inside #governancePanel -- 2026-08-26)
    // immediately -- this stacked modal lives outside whichever panel is
    // open (see pushStackedModal), so re-rendering it is safe while the
    // modal stays open, same pattern renderExternalSourceConnectionField's
    // own comment documents for live-updating "Pendientes de conexión".
    renderGovernancePanelIfOpen();
  });
}
if (els.workspaceAccessCloseButton) {
  els.workspaceAccessCloseButton.addEventListener('click', () => toggleWorkspaceAccessModal(false));
}
if (els.adminPanel) {
  els.adminPanel.addEventListener('click', event => {
    const row = event.target.closest('[data-tenant-admin-workspaces]');
    if (!row) return;
    event.preventDefault();
    toggleTenantAdminWorkspacesModal(true, row.dataset.tenantAdminWorkspaces);
  });
}
// "Accesos a workspaces" now renders inside #governancePanel (2026-08-26),
// not #adminPanel -- same delegated click needed there too, set up once
// here rather than re-bound on every renderGovernancePanel() call.
if (els.governancePanel) {
  els.governancePanel.addEventListener('click', event => {
    const row = event.target.closest('[data-tenant-admin-workspaces]');
    if (!row) return;
    event.preventDefault();
    toggleTenantAdminWorkspacesModal(true, row.dataset.tenantAdminWorkspaces);
  });
}
if (els.tenantAdminWorkspacesCloseButton) {
  els.tenantAdminWorkspacesCloseButton.addEventListener('click', () => toggleTenantAdminWorkspacesModal(false));
}
if (els.adminPanel) {
  els.adminPanel.addEventListener('click', event => {
    const openButton = event.target.closest('[data-open-workspace-create]');
    if (openButton) { toggleWorkspaceCreateModal(true, openButton.dataset.openWorkspaceCreate); return; }
    const wizardButton = event.target.closest('[data-open-installer-wizard]');
    if (wizardButton) { toggleInstallerWizardModal(true); return; }
  });
}
// Sensitivity-selection interactions (scan-selected/clear/toggle-samples)
// now live inside #governancePanel's "Sensibilidad detectada" tab
// (2026-08-26) -- moved out of the shared #adminPanel delegated handler
// above into their own, since that tab isn't part of #adminPanel anymore.
if (els.governancePanel) {
  els.governancePanel.addEventListener('click', event => {
    const scanSelectedButton = event.target.closest('[data-sensitivity-scan-selected]');
    if (scanSelectedButton) { triggerSensitivityScanSelected(); return; }
    const clearSelectionButton = event.target.closest('[data-sensitivity-clear-selection]');
    if (clearSelectionButton) { sensitivityScanSelection.clear(); renderGovernancePanelIfOpen(); return; }
    const toggleSamplesButton = event.target.closest('[data-toggle-sensitivity-samples]');
    if (toggleSamplesButton) {
      const target = document.getElementById(toggleSamplesButton.dataset.toggleSensitivitySamples);
      if (target) target.hidden = !target.hidden;
    }
  });
}
if (els.workspaceCreateCloseButton) {
  els.workspaceCreateCloseButton.addEventListener('click', () => toggleWorkspaceCreateModal(false));
}
if (els.workspaceCreateBody) {
  els.workspaceCreateBody.addEventListener('click', event => {
    if (event.target.closest('[data-workspace-create-submit]')) { submitWorkspaceCreate(); return; }
    if (event.target.closest('[data-workspace-create-apply]')) { applyWorkspaceCreateResult(); }
  });
}
if (els.installerWizardCloseButton) {
  els.installerWizardCloseButton.addEventListener('click', () => toggleInstallerWizardModal(false));
}
if (els.installerWizardBody) {
  els.installerWizardBody.addEventListener('click', event => {
    const back = event.target.closest('[data-installer-back]');
    if (back) { installerWizardBack(); return; }
    const next = event.target.closest('[data-installer-next]');
    if (next) { installerWizardNext(); return; }
    const start = event.target.closest('[data-installer-start]');
    if (start) { submitInstallerWizard(); return; }
    const toggleNotebook = event.target.closest('[data-installer-toggle-notebook]');
    if (toggleNotebook) {
      const name = toggleNotebook.dataset.installerToggleNotebook;
      if (installerWizardConfig.notebookNames.includes(name)) {
        installerWizardConfig.notebookNames = installerWizardConfig.notebookNames.filter(n => n !== name);
      } else {
        installerWizardConfig.notebookNames.push(name);
      }
      renderInstallerWizardModal();
    }
  });
  els.installerWizardBody.addEventListener('change', event => {
    const field = event.target.closest('[data-installer-field]');
    if (field) {
      installerWizardConfig[field.dataset.installerField] = field.value;
      // itemType flips which name field (Warehouse vs Lakehouse) this
      // step shows -- needs an immediate re-render, unlike a plain text
      // field where nothing else on screen depends on the new value.
      if (field.dataset.installerField === 'itemType') renderInstallerWizardModal();
      return;
    }
    const varField = event.target.closest('[data-installer-variable]');
    if (varField) installerWizardConfig.variableOverrides[varField.dataset.installerVariable] = varField.value;
  });
}
els.zoomOutButton.addEventListener('click', () => zoom(0.8));
els.zoomInButton.addEventListener('click', () => zoom(1.2));
els.fitButton.addEventListener('click', fitView);
if (els.planningResetLayoutButton) els.planningResetLayoutButton.addEventListener('click', resetPlanningLayout);
if (els.sceneToggleButton) {
  els.sceneToggleButton.addEventListener('click', () => {
    state.sceneEnabled = !state.sceneEnabled;
    applyLayoutState();
  });
}
els.viewport.addEventListener('wheel', event => {
  if (event.target.closest('.filter-menu')) return;
  // Everywhere else, wheel scrolls and Ctrl/Cmd+wheel zooms (the usual
  // browser/map convention). Inside the planning canvas AND the Inspection
  // tree (viewMode "lineage" -- semantic/notebooks/copyjobs/pipelines),
  // plain wheel also zooms, matching how both are actually navigated: by
  // dragging to pan (see the pointerdown/pointermove handlers below, which
  // work in every mode already), not by scrolling a document.
  const overPannableCanvas = Boolean(event.target.closest('.planning-canvas'))
    || (state.viewMode === 'lineage' && Boolean(event.target.closest('.tree-stage')));
  if (!event.ctrlKey && !event.metaKey && !overPannableCanvas) return;
  event.preventDefault();
  const rect = els.viewport.getBoundingClientRect();
  zoom(event.deltaY > 0 ? 0.9 : 1.1, event.clientX - rect.left, event.clientY - rect.top);
}, { passive: false });
els.viewport.addEventListener('pointerdown', event => {
  if (event.target.closest('.node-card, .diagram-stage-selector, .impact-board, .planning-source-selector, .semantic-object-more, .semantic-object-pill, .semantic-object-row') || event.target.closest('.filter-menu')) return;
  if (isViewportScrollbarEvent(event)) return;
  state.drag.active = true;
  state.drag.x = event.clientX;
  state.drag.y = event.clientY;
  state.drag.scrollLeft = els.viewport.scrollLeft;
  state.drag.scrollTop = els.viewport.scrollTop;
  els.viewport.classList.add('dragging');
  els.viewport.setPointerCapture(event.pointerId);
});
els.viewport.addEventListener('pointermove', event => {
  if (!state.drag.active) return;
  const deltaX = event.clientX - state.drag.x;
  const deltaY = event.clientY - state.drag.y;
  els.viewport.scrollLeft = Math.max(0, state.drag.scrollLeft - deltaX);
  els.viewport.scrollTop = Math.max(0, state.drag.scrollTop - deltaY);
});
function stopDrag(event) {
  state.drag.active = false;
  els.viewport.classList.remove('dragging');
  if (event && event.pointerId !== undefined) {
    try { els.viewport.releasePointerCapture(event.pointerId); } catch { /* no-op */ }
  }
}
els.viewport.addEventListener('pointerup', stopDrag);
els.viewport.addEventListener('pointerleave', stopDrag);
window.addEventListener('resize', () => {
  if (!els.filterMenu.hidden) applyFilterPosition();
});

init().catch(error => {
  // If the auth gate is still showing (2026-08-24: now an overlay scoped
  // to the diagram area, not the whole shell -- see the HTML comment
  // above #authGate), the failure happened before/during the auth check
  // itself -- writing into els.treeStage would be invisible underneath
  // it, so surface it in the gate instead.
  const runtimeErrorPrefix = state.lang === 'es' ? 'Error en tiempo de ejecución' : 'Runtime error';
  if (els.authGate && !els.authGate.hidden) {
    setAuthGateError(`${runtimeErrorPrefix}: ${error.message}`);
  } else {
    els.treeStage.innerHTML = `<div class="empty-state">${escapeHtml(runtimeErrorPrefix)}: ${escapeHtml(error.message)}</div>`;
  }
});

// ---------------------------------------------------------------------------
// Planning map popup: the planning diagram in its own fullscreen window with
// Excel-style object filters, wheel/drag/arrow-key navigation, PNG export and
// an Excel export shaped for feeding a scheduling agent.
// ---------------------------------------------------------------------------

const planningMapEls = {
  view: document.getElementById('planningMapView'),
  viewport: document.getElementById('planningMapViewport'),
  surface: document.getElementById('planningMapSurface'),
  typeButton: document.getElementById('planningMapTypeFilterButton'),
  typePanel: document.getElementById('planningMapTypeFilterPanel'),
  nameButton: document.getElementById('planningMapNameFilterButton'),
  namePanel: document.getElementById('planningMapNameFilterPanel'),
  zoomIn: document.getElementById('planningMapZoomInButton'),
  zoomOut: document.getElementById('planningMapZoomOutButton'),
  fit: document.getElementById('planningMapFitButton'),
  png: document.getElementById('planningMapPngButton'),
  excel: document.getElementById('planningMapExcelButton'),
  close: document.getElementById('planningMapCloseButton'),
  launch: document.getElementById('planningMapButton')
};

const planningMapState = {
  open: false,
  nodes: [],
  edges: [],
  selectedTypes: new Set(),
  selectedNames: new Set(),
  nameSearch: '',
  typeSearch: '',
  scale: 1,
  tx: 0,
  ty: 0,
  layout: new Map(),
  surfaceWidth: 0,
  surfaceHeight: 0,
  visibleNodes: [],
  visibleEdges: [],
  renderedNodes: [],
  renderedEdges: []
};

function planningMapNodeTypeLabel(node) {
  if (node.kind === 'source') {
    if ((node.key || '').startsWith('store|fabricitem|')) {
      return 'Lakehouse / Warehouse';
    }
    return sourceTypeDisplay(node.data && node.data.source_type) || (state.lang === 'es' ? 'Origen externo' : 'External origin');
  }
  return (node.data && node.data.item_type) || 'Item';
}

// Type/name checkbox filtering only -- NOT capped. This is what Excel
// exports (the user's whole point is a complete object list for a
// scheduling agent; truncating it silently would defeat that).
function planningMapFiltered() {
  const nodes = planningMapState.nodes.filter(node =>
    planningMapState.selectedTypes.has(planningMapNodeTypeLabel(node)) &&
    planningMapState.selectedNames.has(node.label || ''));
  const ids = new Set(nodes.map(node => node.id));
  const edges = planningMapState.edges.filter(edge => ids.has(edge.fromId) && ids.has(edge.toId));
  return { nodes, edges };
}

function renderPlanningMapFilterPanel(panel, values, selectedSet, searchValue, onSearch, onChange) {
  panel.innerHTML = '';
  const search = document.createElement('input');
  search.type = 'search';
  search.className = 'planning-map-filter-search';
  search.placeholder = state.lang === 'es' ? 'Buscar...' : 'Search...';
  search.value = searchValue;
  search.addEventListener('input', () => onSearch(search.value));
  panel.append(search);

  const query = normalize(searchValue);
  const shown = values.filter(value => !query || normalize(value).includes(query));

  const allLabel = document.createElement('label');
  allLabel.className = 'planning-map-filter-all';
  const allBox = document.createElement('input');
  allBox.type = 'checkbox';
  allBox.checked = shown.length > 0 && shown.every(value => selectedSet.has(value));
  allBox.addEventListener('change', () => {
    for (const value of shown) {
      if (allBox.checked) selectedSet.add(value);
      else selectedSet.delete(value);
    }
    onChange();
  });
  allLabel.append(allBox, document.createTextNode(state.lang === 'es' ? '(Seleccionar todo)' : '(Select all)'));
  panel.append(allLabel);

  for (const value of shown) {
    const label = document.createElement('label');
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.checked = selectedSet.has(value);
    box.addEventListener('change', () => {
      if (box.checked) selectedSet.add(value);
      else selectedSet.delete(value);
      onChange();
    });
    label.append(box, document.createTextNode(value));
    panel.append(label);
  }
}

function refreshPlanningMapFilters() {
  const typeValues = Array.from(new Set(planningMapState.nodes.map(planningMapNodeTypeLabel))).sort((a, b) => a.localeCompare(b));
  const nameValues = Array.from(new Set(planningMapState.nodes.map(node => node.label || ''))).sort((a, b) => a.localeCompare(b));
  renderPlanningMapFilterPanel(
    planningMapEls.typePanel, typeValues, planningMapState.selectedTypes, planningMapState.typeSearch,
    value => { planningMapState.typeSearch = value; refreshPlanningMapFilters(); },
    () => { refreshPlanningMapFilters(); renderPlanningMapDiagram(); }
  );
  renderPlanningMapFilterPanel(
    planningMapEls.namePanel, nameValues, planningMapState.selectedNames, planningMapState.nameSearch,
    value => { planningMapState.nameSearch = value; refreshPlanningMapFilters(); },
    () => { refreshPlanningMapFilters(); renderPlanningMapDiagram(); }
  );
}

function applyPlanningMapTransform() {
  planningMapEls.surface.style.transform =
    'translate(' + planningMapState.tx + 'px, ' + planningMapState.ty + 'px) scale(' + planningMapState.scale + ')';
}

// Rendering a huge combined selection (e.g. every DEV workspace plus a
// large ingestion workspace, hundreds of nodes) as raw absolutely-
// positioned cards is workable, but only if the DOM work is bounded and
// batched. Above this many cards, only the highest-weight ones (critical
// path / failure hotspots / parallel candidates -- same ranking the
// embedded canvas uses) get drawn; the rest stay in the Excel export (which
// reads the UNCAPPED filtered set, not this one) and the "+N ocultos" note.
const PLANNING_MAP_MAX_RENDER_NODES = 500;

function renderPlanningMapDiagram() {
  const filtered = planningMapFiltered();
  // Uncapped -- Excel's dependency list must never be silently truncated.
  planningMapState.visibleNodes = filtered.nodes;
  planningMapState.visibleEdges = filtered.edges;

  const nodes = filtered.nodes.length > PLANNING_MAP_MAX_RENDER_NODES
    ? [...filtered.nodes].sort((a, b) => planningNodeWeight(b) - planningNodeWeight(a)).slice(0, PLANNING_MAP_MAX_RENDER_NODES)
    : filtered.nodes;
  const hiddenCount = filtered.nodes.length - nodes.length;
  const renderIds = new Set(nodes.map(node => node.id));
  const edges = filtered.edges.filter(edge => renderIds.has(edge.fromId) && renderIds.has(edge.toId));
  // What actually got drawn -- PNG and the live drag redraw both read this,
  // not the uncapped set above.
  planningMapState.renderedNodes = nodes;
  planningMapState.renderedEdges = edges;

  const surface = planningMapEls.surface;
  surface.style.transform = 'none';
  surface.innerHTML = '';

  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  appendPlanningEdgeMarkers(svg);
  surface.append(svg);

  // Same invisible topological columns as the embedded canvas: node.wave was
  // computed by buildPlanningGraph, so arrows always travel rightward here too.
  const byWave = new Map();
  for (const node of nodes) {
    if (!byWave.has(node.wave)) byWave.set(node.wave, []);
    byWave.get(node.wave).push(node);
  }
  const columns = Array.from(byWave.entries()).sort((a, b) => a[0] - b[0])
    .map(entry => ({ wave: entry[0], title: '', nodes: entry[1] }));
  minimizePlanningCrossings(columns, edges);

  // Build every card up front, all at once, with no style READ in between --
  // interleaving a write (append/position) with a read (offsetWidth) forces
  // a synchronous layout on EVERY iteration ("layout thrashing"). Batching
  // all the writes here, then all the reads in the next loop, then all the
  // position writes in the loop after that, costs at most 2 forced layouts
  // total regardless of node count instead of one per node/column -- this
  // (plus the render cap above) is what fixed the popup going blank on a
  // large combined selection, verified live 2026-07-18.
  const cardByNodeId = new Map();
  for (const column of columns) {
    for (const node of column.nodes) {
      const card = document.createElement('div');
      card.className = 'planning-map-card';
      card.innerHTML =
        '<span class="ms-icon ' + iconClassForNode(node) + '" aria-hidden="true"></span>' +
        '<span><strong>' + escapeHtml(node.label || '') + '</strong>' +
        '<span class="planning-map-sub">' + escapeHtml(planningMapNodeTypeLabel(node)) + '</span></span>';
      surface.append(card);
      cardByNodeId.set(node.id, card);
      attachPlanningMapCardDrag(card, node.id);
    }
  }

  // Pass 1 -- READ every card's natural size, no writes in between (a
  // single forced layout covers the whole batch instead of one per column).
  const sizeByNodeId = new Map();
  for (const column of columns) {
    for (const node of column.nodes) {
      const card = cardByNodeId.get(node.id);
      sizeByNodeId.set(node.id, { width: card.offsetWidth, height: card.offsetHeight });
    }
  }

  // Pass 2 -- compute positions from the sizes read above and WRITE them,
  // no reads in between.
  const LANE_GAP = 120;
  const CARD_GAP = 26;
  const MARGIN = 30;
  planningMapState.layout = new Map();
  let laneX = MARGIN;
  let maxBottom = 0;
  for (const column of columns) {
    const laneWidth = Math.max(0, ...column.nodes.map(node => sizeByNodeId.get(node.id).width));
    let y = MARGIN;
    for (const node of column.nodes) {
      const size = sizeByNodeId.get(node.id);
      const card = cardByNodeId.get(node.id);
      const x = laneX + (laneWidth - size.width) / 2;
      card.style.left = x + 'px';
      card.style.top = y + 'px';
      planningMapState.layout.set(node.id, { x: x, y: y, width: size.width, height: size.height });
      y += size.height + CARD_GAP;
    }
    maxBottom = Math.max(maxBottom, y - CARD_GAP);
    laneX += laneWidth + LANE_GAP;
  }
  planningMapState.surfaceWidth = Math.max(240, laneX - LANE_GAP + MARGIN);
  planningMapState.surfaceHeight = Math.max(240, maxBottom + MARGIN);
  surface.style.width = planningMapState.surfaceWidth + 'px';
  surface.style.height = planningMapState.surfaceHeight + 'px';
  svg.setAttribute('width', planningMapState.surfaceWidth);
  svg.setAttribute('height', planningMapState.surfaceHeight);
  svg.setAttribute('viewBox', '0 0 ' + planningMapState.surfaceWidth + ' ' + planningMapState.surfaceHeight);

  drawPlanningMapEdges(svg);
  planningMapState.svg = svg;
  renderPlanningMapLegend(hiddenCount);
  applyPlanningMapTransform();
}

// Redraws every edge from the current layout -- called on full render AND
// live while a card is being dragged, so the curves follow the card instead
// of getting orphaned. Marker defs are kept; only paths are replaced.
function drawPlanningMapEdges(svg) {
  for (const path of Array.from(svg.querySelectorAll('path[data-map-edge]'))) path.remove();
  for (const edge of planningMapState.renderedEdges) {
    const from = planningMapState.layout.get(edge.fromId);
    const to = planningMapState.layout.get(edge.toId);
    if (!from || !to) continue;
    const x1 = from.x + from.width;
    const y1 = from.y + from.height / 2;
    const x2 = to.x;
    const y2 = to.y + to.height / 2;
    const bend = Math.max(30, (x2 - x1) / 2);
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('data-map-edge', '1');
    path.setAttribute('d', 'M ' + x1 + ' ' + y1 + ' C ' + (x1 + bend) + ' ' + y1 + ', ' + (x2 - bend) + ' ' + y2 + ', ' + x2 + ' ' + y2);
    path.setAttribute('fill', 'none');
    path.setAttribute('stroke', planningEdgeColor(edge.type));
    path.setAttribute('stroke-width', edge.confidence === 'confirmed' ? '1.8' : '1.2');
    if (edge.confidence !== 'confirmed') path.setAttribute('stroke-dasharray', '5 4');
    path.setAttribute('marker-end', 'url(#planning-arrow-' + edge.type + ')');
    svg.append(path);
  }
}

// The legend lives in the viewport (not the zoomed surface) and only lists
// what the CURRENT diagram actually contains: the edge types present, plus
// the one stroke-style rule (solid = confirmed evidence, dashed = inferred).
function renderPlanningMapLegend(hiddenCount) {
  let legend = planningMapEls.viewport.querySelector('.planning-map-legend');
  if (!legend) {
    legend = document.createElement('div');
    legend.className = 'planning-map-legend';
    planningMapEls.viewport.append(legend);
  }
  const typesPresent = Array.from(new Set(planningMapState.renderedEdges.map(edge => edge.type)));
  const lineSample = (color, dashed) =>
    '<svg width="26" height="8" aria-hidden="true"><line x1="1" y1="4" x2="25" y2="4" stroke="' + color + '" stroke-width="2"' +
    (dashed ? ' stroke-dasharray="5 4"' : '') + ' /></svg>';
  const rows = typesPresent.map(type =>
    '<span class="planning-map-legend-row">' + lineSample(planningEdgeColor(type), false) + ' ' +
    escapeHtml(planningEdgeTypeLabel(type)) + '</span>');
  rows.push('<span class="planning-map-legend-row">' + lineSample('#64748b', false) + ' ' +
    escapeHtml(state.lang === 'es' ? 'continua = confirmado' : 'solid = confirmed') + '</span>');
  rows.push('<span class="planning-map-legend-row">' + lineSample('#64748b', true) + ' ' +
    escapeHtml(state.lang === 'es' ? 'punteada = inferido (probable)' : 'dashed = inferred (likely)') + '</span>');
  if (hiddenCount > 0) {
    rows.push('<span class="planning-map-legend-row planning-map-legend-hidden">' +
      escapeHtml(state.lang === 'es'
        ? `+ ${number(hiddenCount)} ocultos por límite visual (Excel los incluye igualmente)`
        : `+ ${number(hiddenCount)} hidden by the visual limit (Excel still includes them)`) +
      '</span>');
  }
  legend.innerHTML = rows.join('');
}

// Hold-click on a card moves the card itself (the viewport pan only starts
// on empty background thanks to stopPropagation here); edges are redrawn
// live from the updated layout on every move, so the curves follow the card
// instead of getting orphaned. Pointer deltas are divided by the current
// zoom so a drag at 2x moves the card exactly as far as the mouse did.
function attachPlanningMapCardDrag(card, nodeId) {
  card.addEventListener('pointerdown', event => {
    if (event.button !== 0) return;
    event.stopPropagation();
    const startX = event.clientX;
    const startY = event.clientY;
    const base = planningMapState.layout.get(nodeId);
    if (!base) return;
    const baseX = base.x;
    const baseY = base.y;
    card.classList.add('dragging');
    card.setPointerCapture(event.pointerId);
    const onMove = moveEvent => {
      const box = planningMapState.layout.get(nodeId);
      if (!box) return;
      box.x = baseX + (moveEvent.clientX - startX) / planningMapState.scale;
      box.y = baseY + (moveEvent.clientY - startY) / planningMapState.scale;
      card.style.left = box.x + 'px';
      card.style.top = box.y + 'px';
      if (planningMapState.svg) drawPlanningMapEdges(planningMapState.svg);
    };
    const onUp = () => {
      card.classList.remove('dragging');
      card.removeEventListener('pointermove', onMove);
      card.removeEventListener('pointerup', onUp);
    };
    card.addEventListener('pointermove', onMove);
    card.addEventListener('pointerup', onUp);
  });
}

function planningMapFit() {
  const viewport = planningMapEls.viewport;
  const scale = Math.min(
    viewport.clientWidth / planningMapState.surfaceWidth,
    viewport.clientHeight / planningMapState.surfaceHeight,
    1.6
  );
  planningMapState.scale = Math.max(0.05, scale * 0.96);
  planningMapState.tx = (viewport.clientWidth - planningMapState.surfaceWidth * planningMapState.scale) / 2;
  planningMapState.ty = (viewport.clientHeight - planningMapState.surfaceHeight * planningMapState.scale) / 2;
  applyPlanningMapTransform();
}

function planningMapZoomAt(clientX, clientY, factor) {
  const rect = planningMapEls.viewport.getBoundingClientRect();
  const px = clientX - rect.left;
  const py = clientY - rect.top;
  const nextScale = Math.min(4, Math.max(0.05, planningMapState.scale * factor));
  const applied = nextScale / planningMapState.scale;
  planningMapState.tx = px - (px - planningMapState.tx) * applied;
  planningMapState.ty = py - (py - planningMapState.ty) * applied;
  planningMapState.scale = nextScale;
  applyPlanningMapTransform();
}

function planningMapZoomCenter(factor) {
  const rect = planningMapEls.viewport.getBoundingClientRect();
  planningMapZoomAt(rect.left + rect.width / 2, rect.top + rect.height / 2, factor);
}

// The popup's static chrome lives in index.html in Spanish; set it from the
// current language whenever the popup opens or the language changes.
function renderPlanningMapLabels() {
  const es = state.lang === 'es';
  const title = es ? 'Mapa de planificación' : 'Planning map';
  const titleEl = document.getElementById('planningMapTitle');
  if (titleEl) titleEl.textContent = title;
  if (planningMapEls.view) planningMapEls.view.setAttribute('aria-label', title);
  if (planningMapEls.typeButton) planningMapEls.typeButton.textContent = es ? 'Tipo de objeto ▾' : 'Object type ▾';
  if (planningMapEls.nameButton) planningMapEls.nameButton.textContent = es ? 'Nombre de objeto ▾' : 'Object name ▾';
  const titles = [
    [planningMapEls.zoomOut, 'Alejar', 'Zoom out'],
    [planningMapEls.zoomIn, 'Acercar', 'Zoom in'],
    [planningMapEls.fit, 'Encajar', 'Fit'],
    [planningMapEls.png, 'Descargar PNG', 'Download PNG'],
    [planningMapEls.excel, 'Descargar Excel', 'Download Excel'],
    [planningMapEls.close, 'Cerrar', 'Close'],
  ];
  titles.forEach(([button, esTitle, enTitle]) => {
    if (button) button.title = es ? esTitle : enTitle;
  });
}

function openPlanningMap() {
  const selected = selectedWorkspaceListForPlanning();
  if (!selected.length) return;
  renderPlanningMapLabels();
  // For a large combined selection, building the graph + laying out
  // hundreds of cards is real synchronous work (seconds, not milliseconds)
  // -- e.g. every DEV workspace plus a large ingestion workspace. Making the view visible and painting a
  // loading message BEFORE that work starts (double requestAnimationFrame:
  // the first guarantees the browser has had a chance to paint what this
  // task just wrote, the second then runs the heavy part) turns "the popup
  // opened and then froze with nothing in it" into "it opened, said it's
  // loading, then filled in" -- same total wall-clock time, very different
  // read as broken vs. working.
  planningMapState.open = true;
  planningMapEls.view.hidden = false;
  planningMapEls.surface.innerHTML = '';
  planningMapEls.surface.style.transform = 'none';
  const loading = document.createElement('div');
  loading.className = 'planning-map-loading';
  loading.textContent = state.lang === 'es' ? 'Generando el mapa…' : 'Building the map…';
  planningMapEls.surface.append(loading);

  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      if (!planningMapState.open) return; // closed while waiting to paint
      const scope = planningScopeWorkspaces(selected);
      const graph = buildPlanningGraph(scope);
      planningMapState.nodes = graph.nodes;
      planningMapState.edges = graph.edges;
      planningMapState.selectedTypes = new Set(graph.nodes.map(planningMapNodeTypeLabel));
      planningMapState.selectedNames = new Set(graph.nodes.map(node => node.label || ''));
      planningMapState.nameSearch = '';
      planningMapState.typeSearch = '';
      refreshPlanningMapFilters();
      renderPlanningMapDiagram();
      planningMapFit();
      planningMapEls.viewport.focus();
    });
  });
}

function closePlanningMap() {
  planningMapState.open = false;
  planningMapEls.view.hidden = true;
  planningMapEls.typePanel.hidden = true;
  planningMapEls.namePanel.hidden = true;
}

function downloadPlanningMapPng() {
  // What actually got drawn (post render-cap), not the uncapped Excel set --
  // the PNG must match what is on screen.
  const visibleNodes = planningMapState.renderedNodes;
  const visibleEdges = planningMapState.renderedEdges;
  const layout = planningMapState.layout;
  if (!visibleNodes.length) return;
  const SCALE = 2;
  const canvas = document.createElement('canvas');
  canvas.width = planningMapState.surfaceWidth * SCALE;
  canvas.height = planningMapState.surfaceHeight * SCALE;
  const ctx = canvas.getContext('2d');
  ctx.scale(SCALE, SCALE);
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, planningMapState.surfaceWidth, planningMapState.surfaceHeight);

  for (const edge of visibleEdges) {
    const from = layout.get(edge.fromId);
    const to = layout.get(edge.toId);
    if (!from || !to) continue;
    const x1 = from.x + from.width;
    const y1 = from.y + from.height / 2;
    const x2 = to.x;
    const y2 = to.y + to.height / 2;
    const bend = Math.max(30, (x2 - x1) / 2);
    ctx.strokeStyle = planningEdgeColor(edge.type);
    ctx.lineWidth = edge.confidence === 'confirmed' ? 1.8 : 1.2;
    ctx.setLineDash(edge.confidence === 'confirmed' ? [] : [5, 4]);
    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.bezierCurveTo(x1 + bend, y1, x2 - bend, y2, x2, y2);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = planningEdgeColor(edge.type);
    ctx.beginPath();
    ctx.moveTo(x2, y2);
    ctx.lineTo(x2 - 7, y2 - 3.2);
    ctx.lineTo(x2 - 7, y2 + 3.2);
    ctx.closePath();
    ctx.fill();
  }

  for (const node of visibleNodes) {
    const box = layout.get(node.id);
    if (!box) continue;
    ctx.fillStyle = node.kind === 'source'
      ? '#eef6f4'
      : (node.data && node.data.item_type === 'SemanticModel' ? '#fdf6ec' : '#f2f5fb');
    ctx.strokeStyle = '#64748b';
    ctx.lineWidth = 1;
    ctx.beginPath();
    if (typeof ctx.roundRect === 'function') {
      ctx.roundRect(box.x, box.y, box.width, box.height, 9);
    } else {
      ctx.rect(box.x, box.y, box.width, box.height);
    }
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = '#0f172a';
    ctx.font = 'bold 11px system-ui, sans-serif';
    ctx.fillText(node.label || '', box.x + 10, box.y + box.height / 2 - 2, box.width - 20);
    ctx.fillStyle = '#64748b';
    ctx.font = '9.5px system-ui, sans-serif';
    ctx.fillText(planningMapNodeTypeLabel(node), box.x + 10, box.y + box.height / 2 + 11, box.width - 20);
  }

  canvas.toBlob(blob => {
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'planificacion-mapa.png';
    document.body.append(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }, 'image/png');
}

function downloadPlanningMapExcel() {
  const visibleNodes = planningMapState.visibleNodes;
  if (!visibleNodes.length) return;
  const nodeById = new Map(planningMapState.nodes.map(node => [node.id, node]));
  const upstream = new Map();
  const downstream = new Map();
  // Dependencies come from the FULL graph, not the visual filter: the
  // filter narrows which objects go in the list, but each listed object's
  // real dependencies stay complete -- that is what a scheduling agent
  // needs to order executions safely.
  for (const edge of planningMapState.edges) {
    if (!upstream.has(edge.toId)) upstream.set(edge.toId, []);
    upstream.get(edge.toId).push(edge.fromId);
    if (!downstream.has(edge.fromId)) downstream.set(edge.fromId, []);
    downstream.get(edge.fromId).push(edge.toId);
  }
  const refName = id => {
    const node = nodeById.get(id);
    if (!node) return '';
    return (node.data && node.data.qualified_name) || node.label || '';
  };
  const joinRefs = (map, id) => Array.from(new Set((map.get(id) || []).map(refName).filter(Boolean))).join('; ');

  const headers = state.lang === 'es'
    ? ['Tipo', 'Nombre', 'Workspace', 'Nombre calificado', 'Depende de', 'Dependientes',
       'Duración media (s)', 'Duración mediana (s)', 'Ejecuciones', 'Correctas', 'Fallidas',
       'Horas programadas', 'Frecuencia', 'Última ejecución', 'Último estado']
    : ['Type', 'Name', 'Workspace', 'Qualified name', 'Depends on', 'Dependents',
       'Avg duration (s)', 'Median duration (s)', 'Runs', 'Completed', 'Failed',
       'Scheduled times', 'Frequency', 'Latest run', 'Latest status'];
  const rows = visibleNodes.map(node => {
    const data = node.data || {};
    const execution = data.execution || {};
    return [
      planningMapNodeTypeLabel(node),
      node.label || '',
      data.workspace_name || '',
      data.qualified_name || '',
      joinRefs(upstream, node.id),
      joinRefs(downstream, node.id),
      planningRealisticDurationSeconds(execution) || '',
      execution.median_duration_seconds || '',
      execution.runs || '',
      execution.completed_runs || '',
      execution.failed_runs || '',
      execution.scheduled_times || '',
      execution.schedule_frequency || '',
      execution.latest_start || '',
      execution.latest_status || ''
    ];
  });

  const content = '<html xmlns:x="urn:schemas-microsoft-com:office:excel">' +
    '<head><meta charset="utf-8" /></head><body><table border="1">' +
    '<thead><tr>' + headers.map(header => '<th>' + escapeHtml(header) + '</th>').join('') + '</tr></thead>' +
    '<tbody>' + rows.map(row => '<tr>' + row.map(cell => '<td>' + escapeHtml(String(cell)) + '</td>').join('') + '</tr>').join('') + '</tbody>' +
    '</table></body></html>';
  const blob = new Blob([content], { type: 'application/vnd.ms-excel;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = 'planificacion-objetos.xls';
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

if (planningMapEls.view && planningMapEls.launch) {
  planningMapEls.launch.addEventListener('click', () => {
    if (state.viewMode === 'lineage') {
      toggleInspectionMap();
      return;
    }
    openPlanningMap();
  });
  planningMapEls.close.addEventListener('click', closePlanningMap);
  planningMapEls.zoomIn.addEventListener('click', () => planningMapZoomCenter(1.25));
  planningMapEls.zoomOut.addEventListener('click', () => planningMapZoomCenter(0.8));
  planningMapEls.fit.addEventListener('click', planningMapFit);
  planningMapEls.png.addEventListener('click', downloadPlanningMapPng);
  planningMapEls.excel.addEventListener('click', downloadPlanningMapExcel);

  const togglePlanningMapPanel = (panel, other, button) => {
    panel.hidden = !panel.hidden;
    other.hidden = true;
    button.setAttribute('aria-expanded', panel.hidden ? 'false' : 'true');
  };
  planningMapEls.typeButton.addEventListener('click', event => {
    event.stopPropagation();
    togglePlanningMapPanel(planningMapEls.typePanel, planningMapEls.namePanel, planningMapEls.typeButton);
  });
  planningMapEls.nameButton.addEventListener('click', event => {
    event.stopPropagation();
    togglePlanningMapPanel(planningMapEls.namePanel, planningMapEls.typePanel, planningMapEls.nameButton);
  });
  planningMapEls.typePanel.addEventListener('click', event => event.stopPropagation());
  planningMapEls.namePanel.addEventListener('click', event => event.stopPropagation());
  planningMapEls.view.addEventListener('click', () => {
    planningMapEls.typePanel.hidden = true;
    planningMapEls.namePanel.hidden = true;
  });

  planningMapEls.viewport.addEventListener('wheel', event => {
    event.preventDefault();
    planningMapZoomAt(event.clientX, event.clientY, event.deltaY < 0 ? 1.12 : 0.9);
  }, { passive: false });

  let mapDragging = false;
  let mapDragStartX = 0;
  let mapDragStartY = 0;
  let mapDragBaseTx = 0;
  let mapDragBaseTy = 0;
  planningMapEls.viewport.addEventListener('pointerdown', event => {
    if (event.button !== 0) return;
    mapDragging = true;
    mapDragStartX = event.clientX;
    mapDragStartY = event.clientY;
    mapDragBaseTx = planningMapState.tx;
    mapDragBaseTy = planningMapState.ty;
    planningMapEls.viewport.classList.add('dragging');
    planningMapEls.viewport.setPointerCapture(event.pointerId);
  });
  planningMapEls.viewport.addEventListener('pointermove', event => {
    if (!mapDragging) return;
    planningMapState.tx = mapDragBaseTx + (event.clientX - mapDragStartX);
    planningMapState.ty = mapDragBaseTy + (event.clientY - mapDragStartY);
    applyPlanningMapTransform();
  });
  planningMapEls.viewport.addEventListener('pointerup', () => {
    mapDragging = false;
    planningMapEls.viewport.classList.remove('dragging');
  });

  document.addEventListener('keydown', event => {
    if (!planningMapState.open) return;
    const PAN = 80;
    if (event.key === 'Escape') {
      closePlanningMap();
    } else if (event.key === 'ArrowLeft') {
      planningMapState.tx += PAN;
    } else if (event.key === 'ArrowRight') {
      planningMapState.tx -= PAN;
    } else if (event.key === 'ArrowUp') {
      planningMapState.ty += PAN;
    } else if (event.key === 'ArrowDown') {
      planningMapState.ty -= PAN;
    } else {
      return;
    }
    event.preventDefault();
    applyPlanningMapTransform();
  });
}

if (els.inspectionMapCloseButton) {
  els.inspectionMapCloseButton.addEventListener('click', closeInspectionMap);
}
if (els.inspectionMapPngButton) {
  els.inspectionMapPngButton.addEventListener('click', () => {
    els.inspectionMapPngButton.disabled = true;
    Promise.resolve(downloadSelectedDiagramPng())
      .finally(() => { els.inspectionMapPngButton.disabled = false; });
  });
}
if (els.inspectionMapExcelButton) {
  els.inspectionMapExcelButton.addEventListener('click', () => {
    els.inspectionMapExcelButton.disabled = true;
    Promise.resolve(downloadLineageExcel())
      .finally(() => { els.inspectionMapExcelButton.disabled = false; });
  });
}
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && inspectionMapIsOpen()) closeInspectionMap();
});
