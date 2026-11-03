// Graph Map Mode -- rendering, interactions, and view state (Fase G, then
// Tanda 8: rewritten onto a WebGL 3D engine after live profiling proved
// the original Cytoscape.js canvas 2D renderer averaged under 1 FPS (every
// single frame over 1 second) panning/zooming a graph of a few thousand
// nodes,
// and that Cytoscape's own documented performance flags (hideEdgesOnViewport,
// textureOnViewport, motionBlur, pixelRatio) made no measurable difference --
// the bottleneck was structural, not a tuning problem. `3d-force-graph`
// (vendor/3d-force-graph.min.js, Three.js/WebGL under the hood) renders the
// same real dataset at a locked 60 FPS with real GPU acceleration, verified
// live the same way (Playwright + real frame timing), before this rewrite
// started.
//
// Self-contained on purpose: this file owns the whole feature (button
// wiring, showing/hiding the rest of the app's main view, the graph engine
// instance, and all of Graph Map Mode's own UI) so app.js -- already large
// before this feature existed -- doesn't grow with it. The one exception is
// a single hook app.js's setLanguage() calls into GraphMap.onLanguageChange
// so this view's own text stays in sync with the app's existing ES/EN
// switch while it's open; see app.js for that one line.
//
// `state`/`els` from app.js are intentionally NOT read here for anything
// beyond the current language -- Graph Map Mode keeps its own selection/
// view state entirely separate from the rest of the app.
(function () {
  'use strict';

  var TEXT = {
    es: {
      buttonTitle: 'Modo mapa de grafo',
      buttonLabel: 'Grafo',
      title: 'Mapa de dependencias',
      closeLabel: 'Cerrar',
      loading: 'Cargando el grafo de dependencias...',
      loadError: 'No se pudo cargar el grafo. Reconstruye el índice con backend/scripts/build_graph_map_index.py.',
      searchPlaceholder: 'Buscar por nombre...',
      searchEmpty: 'Sin resultados.',
      searchHint: 'Escribe para buscar un workspace, item u objeto.',
      searchMore: function (count) { return 'y ' + count + ' más -- afina la búsqueda'; },
      detailType: 'Tipo',
      detailWorkspace: 'Workspace',
      detailPath: 'Ruta',
      detailDescription: 'Descripción',
      detailUpstreamCount: 'entradas upstream',
      detailDownstreamCount: 'salidas downstream',
      detailViewUpstream: 'Ver upstream',
      detailViewDownstream: 'Ver downstream',
      detailViewBoth: 'Ver ambos',
      detailCopyPath: 'Copiar ruta',
      detailCopyDone: 'Copiado',
      detailOpenFabric: 'Abrir en Fabric',
      detailDepsTitle: 'Dependencias directas',
      detailConsumersTitle: 'Consumidores directos',
      detailListEmpty: 'Ninguno.',
      detailListMore: function (count) { return 'y ' + count + ' más'; },
      detailCloseLabel: 'Cerrar detalle',
      viewModeLabel: 'Vista',
      viewModeBoth: 'Upstream + downstream',
      viewModeUpstream: 'Solo upstream',
      viewModeDownstream: 'Solo downstream',
      viewModeNeighbors: 'Vecinos directos',
      viewModeFull: 'Grafo completo',
      filterButton: 'Filtro',
      filterAll: 'Todos',
      filterNone: 'Ninguno',
      legendTitle: 'Leyenda',
      resetButton: 'Reset',
      fitButton: 'Ajustar',
      exportJsonButton: 'Exportar JSON',
      exportPngButton: 'Exportar PNG',
      breadcrumbRoot: 'Inicio',
      loadingObjects: 'Cargando objetos...',
      focusedEmpty: 'Sin detalle de objetos para este elemento.',
      objectsShown: function (count, label) { return 'Mostrando ' + count + ' objeto(s) de "' + label + '" en el mapa'; },
      detailViewObjects: 'Mostrar objetos en el mapa',
      detailSourceType: 'Tipo de origen',
      detailSourceServer: 'Servidor',
      detailSourceDatabase: 'Base de datos',
      detailColumnCount: 'Columnas',
      detailItemCount: 'elementos',
      detailMembersTitle: 'Elementos del workspace',
      detailExecStatus: 'Último estado',
      detailExecLastRun: 'Última ejecución',
      detailExecRunCount: 'Ejecuciones',
      detailExecFailedSuffix: 'fallidas',
      detailSensitivity: 'Posibles datos sensibles',
      detailCertified: 'Fuente certificada',
      detailCertifiedDefault: 'Marcada como fuente oficial por un administrador.',
      detailTags: 'Etiquetas',
    },
    en: {
      buttonTitle: 'Graph Map Mode',
      buttonLabel: 'Graph',
      title: 'Dependency map',
      closeLabel: 'Close',
      loading: 'Loading the dependency graph...',
      loadError: 'Could not load the graph. Rebuild the index with backend/scripts/build_graph_map_index.py.',
      searchPlaceholder: 'Search by name...',
      searchEmpty: 'No results.',
      searchHint: 'Type to search a workspace, item, or object.',
      searchMore: function (count) { return 'and ' + count + ' more -- narrow your search'; },
      detailType: 'Type',
      detailWorkspace: 'Workspace',
      detailPath: 'Path',
      detailDescription: 'Description',
      detailUpstreamCount: 'upstream inputs',
      detailDownstreamCount: 'downstream outputs',
      detailViewUpstream: 'View upstream',
      detailViewDownstream: 'View downstream',
      detailViewBoth: 'View both',
      detailCopyPath: 'Copy path',
      detailCopyDone: 'Copied',
      detailOpenFabric: 'Open in Fabric',
      detailDepsTitle: 'Direct dependencies',
      detailConsumersTitle: 'Direct consumers',
      detailListEmpty: 'None.',
      detailListMore: function (count) { return 'and ' + count + ' more'; },
      detailCloseLabel: 'Close detail',
      viewModeLabel: 'View',
      viewModeBoth: 'Upstream + downstream',
      viewModeUpstream: 'Upstream only',
      viewModeDownstream: 'Downstream only',
      viewModeNeighbors: 'Direct neighbors',
      viewModeFull: 'Full graph',
      filterButton: 'Filter',
      filterAll: 'All',
      filterNone: 'None',
      legendTitle: 'Legend',
      resetButton: 'Reset',
      fitButton: 'Fit',
      exportJsonButton: 'Export JSON',
      exportPngButton: 'Export PNG',
      breadcrumbRoot: 'Start',
      loadingObjects: 'Loading objects...',
      focusedEmpty: 'No object-level detail for this item.',
      objectsShown: function (count, label) { return 'Showing ' + count + ' object(s) from "' + label + '" on the map'; },
      detailViewObjects: 'Show objects on the map',
      detailSourceType: 'Source type',
      detailSourceServer: 'Server',
      detailSourceDatabase: 'Database',
      detailColumnCount: 'Columns',
      detailItemCount: 'items',
      detailMembersTitle: 'Workspace items',
      detailExecStatus: 'Last status',
      detailExecLastRun: 'Last run',
      detailExecRunCount: 'Runs',
      detailExecFailedSuffix: 'failed',
      detailSensitivity: 'Potentially sensitive data',
      detailCertified: 'Certified source',
      detailCertifiedDefault: 'Marked as an official source by an admin.',
      detailTags: 'Tags',
    },
  };

  var BREADCRUMB_LIMIT = 8;

  var VIEW_MODES = ['both', 'upstream', 'downstream', 'neighbors', 'full'];

  var DETAIL_LIST_LIMIT = 12;

  var SEARCH_RESULT_LIMIT = 40;

  // H.7 (2026-07-08) / Tanda 8 (2026-07-08, 3D rewrite): one entry per real
  // node_type. `shape` is kept in the data (not just color) for a future
  // pass that vendors Three.js directly to render distinct 3D geometries
  // per type -- ForceGraph3D's UMD build doesn't expose `window.THREE`
  // itself, so custom-geometry nodeThreeObject() needs that separate
  // vendoring decision made first (not bundled into this rewrite). Color
  // alone already gives every type a distinct, legend-backed identity.
  var NODE_TYPE_META = {
    Workspace: { shape: 'round-rectangle', color: '#8b93a5', es: 'Workspace', en: 'Workspace' },
    SemanticModel: { shape: 'hexagon', color: '#8b5cf6', es: 'Modelo semántico', en: 'Semantic model' },
    Report: { shape: 'tag', color: '#f5a742', es: 'Informe', en: 'Report' },
    PaginatedReport: { shape: 'round-tag', color: '#e0c341', es: 'Informe paginado', en: 'Paginated report' },
    Dashboard: { shape: 'diamond', color: '#ff8a65', es: 'Panel', en: 'Dashboard' },
    KQLDashboard: { shape: 'round-diamond', color: '#f4511e', es: 'Panel KQL', en: 'KQL dashboard' },
    SQLEndpoint: { shape: 'rhomboid', color: '#4fd6a4', es: 'Endpoint SQL', en: 'SQL endpoint' },
    Lakehouse: { shape: 'barrel', color: '#14b8a6', es: 'Lakehouse', en: 'Lakehouse' },
    Warehouse: { shape: 'cut-rectangle', color: '#0ea5e9', es: 'Warehouse', en: 'Warehouse' },
    VariableLibrary: { shape: 'round-pentagon', color: '#a3e635', es: 'Biblioteca de variables', en: 'Variable library' },
    Environment: { shape: 'pentagon', color: '#65a30d', es: 'Entorno', en: 'Environment' },
    DataPipeline: { shape: 'vee', color: '#4f9dff', es: 'Pipeline de datos', en: 'Data pipeline' },
    CopyJob: { shape: 'concave-hexagon', color: '#6366f1', es: 'Trabajo de copia', en: 'Copy job' },
    Dataflow: { shape: 'bottom-round-rectangle', color: '#818cf8', es: 'Dataflow', en: 'Dataflow' },
    Notebook: { shape: 'rectangle', color: '#f472b6', es: 'Notebook', en: 'Notebook' },
    Eventstream: { shape: 'star', color: '#fb7185', es: 'Eventstream', en: 'Eventstream' },
    KQLQueryset: { shape: 'octagon', color: '#eab308', es: 'Consultas KQL', en: 'KQL queryset' },
    Reflex: { shape: 'round-octagon', color: '#c084fc', es: 'Reflex', en: 'Reflex' },
    GraphQLApi: { shape: 'triangle', color: '#22d3ee', es: 'API GraphQL', en: 'GraphQL API' },
    UserDataFunction: { shape: 'round-triangle', color: '#2dd4bf', es: 'Función de usuario', en: 'User data function' },
    DataAgent: { shape: 'heptagon', color: '#e879f9', es: 'Agente de datos', en: 'Data agent' },
    // G/portal-1 (2026-07-09): a real, non-Fabric connection (external SQL
    // Server, SharePoint/file, external API) that one or more items read
    // from directly -- see build_external_origin_graph. Rendered as a
    // "portal" ring (nodeThreeObjectFor special-case, slowly spinning) on
    // purpose: it's the one node type meant to visually read as "outside",
    // never inside a workspace atmosphere -- it never carries a `parent`.
    ExternalOrigin: { shape: 'portal', color: '#c026d3', es: 'Origen externo', en: 'External origin' },
  };
  // Object-level nodes (id starts "object::", G.8) carry no node_type from
  // a Fabric type catalog -- keyed by source_type instead (see
  // build_graph_map_index.py's build_object_graph).
  var SOURCE_TYPE_META = {
    SQL: { shape: 'round-rectangle', color: '#fb923c', es: 'Tabla SQL externa', en: 'External SQL table' },
    File: { shape: 'rectangle', color: '#a8a29e', es: 'Archivo', en: 'File' },
    ExternalAPI: { shape: 'triangle', color: '#facc15', es: 'API externa', en: 'External API' },
    NotebookStaticData: { shape: 'round-triangle', color: '#d946ef', es: 'Dato estático de notebook', en: 'Notebook static data' },
    Fabric: { shape: 'ellipse', color: '#38bdf8', es: 'Tabla Fabric', en: 'Fabric table' },
    FabricOrSQL: { shape: 'ellipse', color: '#0891b2', es: 'Tabla Fabric/SQL', en: 'Fabric/SQL table' },
    // Every other real external system (generalized
    // is_external_origin_source_type in build_graph_map_index.py -- see
    // its own comment): only used to color the ExternalOrigin PORTAL node
    // itself (typeMetaFor keeps the portal ring shape for every one of
    // these, see below) -- `shape` here is unused for that path, only
    // `color`/`es`/`en`. CommonDataService and Cds are the same real
    // system (Dataverse) under two different literal strings Fabric
    // itself reports for it -- same color for both, on purpose.
    SharePoint: { shape: 'round-rectangle', color: '#0ea55f', es: 'SharePoint', en: 'SharePoint' },
    CommonDataService: { shape: 'round-rectangle', color: '#8b5cf6', es: 'Dataverse', en: 'Dataverse' },
    Cds: { shape: 'round-rectangle', color: '#8b5cf6', es: 'Dataverse', en: 'Dataverse' },
    MicrosoftOutlook: { shape: 'round-rectangle', color: '#2563eb', es: 'Outlook', en: 'Outlook' },
    AmazonS3: { shape: 'round-rectangle', color: '#c2410c', es: 'Amazon S3', en: 'Amazon S3' },
    AmazonRedshift: { shape: 'round-rectangle', color: '#dc2626', es: 'Amazon Redshift', en: 'Amazon Redshift' },
    AzureDataLakeStorage: { shape: 'round-rectangle', color: '#0369a1', es: 'Azure Data Lake Storage', en: 'Azure Data Lake Storage' },
    Odbc: { shape: 'round-rectangle', color: '#64748b', es: 'Conexión ODBC', en: 'ODBC connection' },
    OData: { shape: 'round-rectangle', color: '#7c8ba1', es: 'Conexión OData', en: 'OData connection' },
    Web: { shape: 'round-rectangle', color: '#14b8a6', es: 'Origen web', en: 'Web source' },
    Folder: { shape: 'round-rectangle', color: '#78716c', es: 'Carpeta', en: 'Folder' },
    AnalysisServices: { shape: 'round-rectangle', color: '#a21caf', es: 'Analysis Services externo', en: 'External Analysis Services' },
    PowerBIDatasets: { shape: 'round-rectangle', color: '#f2c811', es: 'Dataset de Power BI externo', en: 'External Power BI dataset' },
  };
  var DEFAULT_TYPE_META = { shape: 'ellipse', color: '#4f9dff', es: 'Otro', en: 'Other' };

  // Mirrors backend/scripts/lineage_web/sensitivity_classifier.py's
  // SENSITIVITY_CATEGORIES es/en labels -- kept as a small separate lookup
  // (not merged into NODE_TYPE_META) since it labels a *property* objects
  // can carry, not a distinct node type of its own.
  var SENSITIVITY_CATEGORY_LABELS = {
    email: { es: 'Email', en: 'Email' },
    phone: { es: 'Teléfono', en: 'Phone' },
    national_id: { es: 'Identificación nacional', en: 'National ID' },
    person_name: { es: 'Nombre / apellidos', en: 'Person name' },
    address: { es: 'Dirección postal', en: 'Postal address' },
    birth_date: { es: 'Fecha de nacimiento', en: 'Birth date' },
    financial: { es: 'Datos financieros', en: 'Financial data' },
    health: { es: 'Datos de salud', en: 'Health data' },
    gender: { es: 'Género', en: 'Gender' },
  };

  function sensitivityCategoryLabel(key) {
    var meta = SENSITIVITY_CATEGORY_LABELS[key];
    return meta ? meta[currentLang()] : key;
  }

  function isObjectId(id) {
    return id.indexOf('object::') === 0;
  }

  function typeMetaFor(d) {
    if (isObjectId(d.id)) {
      return SOURCE_TYPE_META[d.source_type] || DEFAULT_TYPE_META;
    }
    if (d.node_type === 'ExternalOrigin') {
      // Same portal ring SHAPE for every external origin (requested
      // explicitly) but a distinct COLOR per real source system (SQL,
      // SharePoint, Dataverse, ...) instead of one fixed purple for all
      // of them -- SOURCE_TYPE_META's `shape` is ignored here on purpose.
      var base = NODE_TYPE_META.ExternalOrigin;
      var sourceMeta = SOURCE_TYPE_META[d.source_type];
      return sourceMeta ? { shape: base.shape, color: sourceMeta.color, es: sourceMeta.es, en: sourceMeta.en } : base;
    }
    return NODE_TYPE_META[d.node_type] || DEFAULT_TYPE_META;
  }

  function nodeColorFor(d) {
    return typeMetaFor(d).color;
  }

  function typeLabel(d) {
    var meta = typeMetaFor(d);
    return meta[currentLang()] || d.node_type || d.source_type || '';
  }

  // Per-tier floor so the ordinal hierarchy (workspace > storage > item)
  // build_graph_map_index.py already establishes via `size` still holds
  // even after Tanda 8 folds real connectivity ("influence") into the
  // final value -- direct user feedback was that H.4's count-only sizing
  // didn't *read* as influence. sqrt(1 + degree) keeps one very highly
  // connected item from visually swallowing the graph the way a linear
  // multiplier would.
  function nodeVal(d) {
    var degree = (adjacency && (
      (adjacency.outgoing[d.id] || []).length + (adjacency.incoming[d.id] || []).length
    )) || 0;
    var base = Math.max(4, (d.size || 14) / 6);
    return base * Math.sqrt(1 + degree);
  }

  // Tanda 8 deferred item: distinct 3D geometry per type, not just color.
  // `3d-force-graph`'s UMD build never exposes its own internal Three.js
  // copy as a global, so index.html loads a second, separate Three.js as a
  // native ES module and bridges it to `window.THREE` for this classic
  // script to use -- see the comment there. Every function below checks
  // `window.THREE` defensively and falls back to the library's own default
  // sphere (nodeThreeObject returning undefined) if it's ever missing, so a
  // load-order hiccup degrades gracefully instead of throwing.
  //
  // Providing nodeThreeObject makes the library skip its own nodeColor/
  // nodeVal handling entirely for these nodes (confirmed against the
  // library's own docs, not assumed) -- so size is applied once, as a mesh
  // scale, right here, and color/opacity for the click-to-highlight system
  // (previously just a nodeColor(fn) accessor re-evaluated via refresh())
  // now has to directly mutate each node's own material afterward instead;
  // see applyNodeMeshHighlight() and meshByNodeId below.
  var THREE_GEOMETRY_CACHE = {}; // shape -> shared THREE.BufferGeometry (same geometry instance reused across every node of that shape -- only material differs per node)
  var meshByNodeId = {}; // node id -> the THREE.Mesh nodeThreeObject() built for it, so highlight changes can mutate its material directly

  function threeGeometryFor(shape) {
    if (THREE_GEOMETRY_CACHE[shape]) return THREE_GEOMETRY_CACHE[shape];
    var THREE = window.THREE;
    var geo;
    switch (shape) {
      case 'round-rectangle': geo = new THREE.BoxGeometry(1.7, 1.15, 1.15); break; // Workspace
      case 'rectangle': geo = new THREE.BoxGeometry(1.5, 1, 0.55); break; // Notebook
      case 'bottom-round-rectangle': geo = new THREE.CapsuleGeometry(0.55, 0.7, 4, 8); break; // Dataflow
      case 'cut-rectangle': geo = new THREE.DodecahedronGeometry(0.85); break; // Warehouse
      case 'hexagon': geo = new THREE.CylinderGeometry(0.9, 0.9, 0.7, 6); break; // SemanticModel
      case 'concave-hexagon': geo = new THREE.TorusGeometry(0.6, 0.28, 8, 6); break; // CopyJob
      case 'tag': case 'round-tag': geo = new THREE.ConeGeometry(0.85, 1.3, 4); break; // Report, PaginatedReport
      case 'diamond': geo = new THREE.OctahedronGeometry(0.95); break; // Dashboard
      case 'round-diamond': geo = new THREE.IcosahedronGeometry(0.9); break; // KQLDashboard
      case 'rhomboid': geo = new THREE.CylinderGeometry(0.85, 0.85, 0.85, 4); break; // SQLEndpoint
      case 'barrel': geo = new THREE.CylinderGeometry(0.75, 0.75, 1.3, 16); break; // Lakehouse
      case 'round-pentagon': geo = new THREE.CylinderGeometry(0.85, 0.85, 0.7, 5); break; // VariableLibrary
      case 'pentagon': geo = new THREE.ConeGeometry(0.9, 1.2, 5); break; // Environment
      case 'vee': geo = new THREE.ConeGeometry(0.85, 1.4, 3); break; // DataPipeline
      case 'star': geo = new THREE.TetrahedronGeometry(1.0); break; // Eventstream
      case 'octagon': geo = new THREE.CylinderGeometry(0.85, 0.85, 0.7, 8); break; // KQLQueryset
      case 'round-octagon': geo = new THREE.SphereGeometry(0.85, 16, 12); break; // Reflex
      case 'triangle': geo = new THREE.ConeGeometry(0.9, 1.1, 3); break; // GraphQLApi
      case 'round-triangle': geo = new THREE.TetrahedronGeometry(0.85); break; // UserDataFunction
      case 'heptagon': geo = new THREE.CylinderGeometry(0.85, 0.85, 0.7, 7); break; // DataAgent
      case 'portal': geo = new THREE.TorusGeometry(0.8, 0.32, 10, 24); break; // ExternalOrigin -- a ring, not a solid
      case 'ellipse': default: geo = new THREE.SphereGeometry(0.85, 16, 12); break; // Fabric/FabricOrSQL/default
    }
    THREE_GEOMETRY_CACHE[shape] = geo;
    return geo;
  }

  // Workspaces are no longer rendered as their own visible shape -- a
  // translucent "atmosphere" sphere enclosing the workspace's real items
  // (buildWorkspaceAtmospheres, computed once positions settle) plays that
  // role instead, so a workspace reads as the volume of space its items
  // occupy rather than a dot floating among them. The node itself still
  // exists in the graph (d3-force-3d needs it as the anchor the synthetic
  // parent links pull items toward) and stays clickable -- just invisible:
  // opacity 0 keeps it part of the normal raycast/click pipeline without
  // drawing anything.
  function workspaceAnchorMeshFor(d) {
    var THREE = window.THREE;
    var geometry = threeGeometryFor('ellipse');
    var material = new THREE.MeshBasicMaterial({ transparent: true, opacity: 0, depthWrite: false });
    var mesh = new THREE.Mesh(geometry, material);
    var scale = Math.cbrt(Math.max(0.6, nodeVal(d))) * 2.4;
    mesh.scale.set(scale, scale, scale);
    meshByNodeId[d.id] = mesh;
    return mesh;
  }

  var portalMeshes = []; // ExternalOrigin meshes -- rotated a little every frame, see onEngineTick in createGraph

  // "A portal in space": requested explicitly for non-Fabric origins (SQL
  // Server, SharePoint/files, external APIs) -- MeshBasicMaterial (unlit)
  // instead of the MeshLambertMaterial every other node uses makes the ring
  // read as self-illuminated/glowing against the shaded regular nodes
  // around it, and it's rotated continuously (see onEngineTick) instead of
  // sitting static. Sized with a floor above a typical item's scale ("a
  // bit bigger than the rest") on top of the same degree-based scaling
  // every other node gets, so a portal feeding many items still reads as
  // busier than one feeding just one or two.
  function externalOriginMeshFor(d) {
    var THREE = window.THREE;
    var geometry = threeGeometryFor('portal');
    var material = new THREE.MeshBasicMaterial({
      color: nodeColorAccessor(d),
      opacity: nodeOpacityFor(d),
      transparent: true,
    });
    var mesh = new THREE.Mesh(geometry, material);
    var scale = Math.max(9, Math.cbrt(Math.max(0.6, nodeVal(d))) * 4);
    mesh.scale.set(scale, scale, scale);
    mesh.rotation.x = Math.random() * Math.PI;
    mesh.rotation.y = Math.random() * Math.PI;
    meshByNodeId[d.id] = mesh;
    portalMeshes.push(mesh);
    return mesh;
  }

  // Purview-inspired health/freshness signal (Tanda A, 2026-07-09): a soft
  // colored glow (MeshLambertMaterial's own `emissive`, not a separate
  // object -- one property, no extra geometry/draw call) on items whose
  // last real run failed or that haven't run in 30+ days (see
  // build_graph_map_index.py's STALE_AFTER_DAYS). `emissive` never changes
  // for a node's whole session, so it's set once at mesh creation and
  // doesn't need to be touched again by applyNodeMeshHighlight -- that
  // function only ever mutates .color/.opacity, both untouched here.
  function healthMetaFor(d) {
    if (!d.exec_run_count) return null;
    if (d.exec_last_status === 'Failed') return { color: 0xef4444, es: 'Último intento falló', en: 'Last run failed' };
    if (d.exec_is_stale) return { color: 0xf5a742, es: 'Sin ejecutarse hace más de 30 días', en: "Hasn't run in 30+ days" };
    return null;
  }

  // Tanda B (2026-07-09): same glow mechanism as healthMetaFor, for objects
  // sensitivity_classifier.py flagged by column-name pattern (email/DNI/
  // card/etc.) -- a pink/magenta glow distinct from health's red/amber so
  // the two signals never look alike, even though items and objects rarely
  // carry both fields at once in practice (health is per-item, sensitivity
  // is per-object).
  function sensitivityMetaFor(d) {
    if (!d.sensitivity_categories || !d.sensitivity_categories.length) return null;
    return { color: 0xf472b6, es: 'Posibles datos sensibles', en: 'Potentially sensitive data' };
  }

  // Tanda C (Purview-inspired, 2026-07-09): a certified/official-source
  // badge (config/admin_settings.json's certified_items, admin-curated) is
  // a *positive* signal, unlike health/sensitivity's warning glow -- reusing
  // the same emissive channel for it would either fight or silently lose to
  // a real warning on the same node. Instead: a thin gold rim around the
  // node, the classic single-pass Three.js outline trick (the same
  // geometry, scaled up ~15% and rendered back-face-only so only the part
  // poking out past the real mesh is visible). Only certified nodes pay for
  // this extra mesh -- expected to be a small, deliberately curated list.
  function certifiedOutlineMeshFor(geometry, scale) {
    var THREE = window.THREE;
    var material = new THREE.MeshBasicMaterial({ color: 0xfbbf24, side: THREE.BackSide, transparent: true, opacity: 0.9 });
    var outline = new THREE.Mesh(geometry, material);
    var outlineScale = scale * 1.18;
    outline.scale.set(outlineScale, outlineScale, outlineScale);
    return outline;
  }

  function nodeThreeObjectFor(d) {
    if (!window.THREE) return undefined; // graceful fallback to the library's own default sphere
    if (d.node_type === 'Workspace') return workspaceAnchorMeshFor(d);
    if (d.node_type === 'ExternalOrigin') return externalOriginMeshFor(d);
    var geometry = threeGeometryFor(typeMetaFor(d).shape);
    var glow = sensitivityMetaFor(d) || healthMetaFor(d);
    var material = new window.THREE.MeshLambertMaterial({
      color: nodeColorAccessor(d),
      opacity: nodeOpacityFor(d),
      transparent: true,
      emissive: glow ? glow.color : 0x000000,
      emissiveIntensity: glow ? 0.55 : 0,
    });
    var mesh = new window.THREE.Mesh(geometry, material);
    // Volume-ish (cube-root) scaling so a given `val` reads as roughly the
    // same visual size as the library's own default sphere-radius-from-val
    // behavior did before this custom geometry replaced it.
    // Matches three-forcegraph's own default-sphere formula exactly
    // (radius = cbrt(val) * nodeRelSize, nodeRelSize defaults to 4) so
    // custom-shaped nodes read as the same size the plain spheres did
    // before this shape-per-type change, not ~4x smaller.
    var scale = Math.cbrt(Math.max(0.6, nodeVal(d))) * 4;
    mesh.scale.set(scale, scale, scale);
    // meshByNodeId always points at the inner mesh specifically (not the
    // group below), so applyNodeMeshHighlight's material mutations keep
    // working exactly as before regardless of whether this node is
    // certified -- the gold outline, when present, is a plain sibling that
    // is never itself highlighted/dimmed.
    meshByNodeId[d.id] = mesh;
    if (d.is_certified) {
      var group = new window.THREE.Group();
      group.add(certifiedOutlineMeshFor(geometry, scale));
      group.add(mesh);
      return group;
    }
    return mesh;
  }

  // Called after highlightState changes (selectNode/clearSelection) for
  // every node whose color/opacity may need updating -- the equivalent of
  // what graph.refresh() + the nodeColor/nodeOpacity accessors used to do
  // automatically, before nodeThreeObject made those accessors inert.
  function applyNodeMeshHighlight(d) {
    var mesh = meshByNodeId[d.id];
    if (!mesh || !mesh.material) return;
    mesh.material.color.set(nodeColorAccessor(d));
    mesh.material.opacity = nodeOpacityFor(d);
  }

  function refreshAllNodeMeshHighlights() {
    if (!graph) return;
    graph.graphData().nodes.forEach(applyNodeMeshHighlight);
  }

  // Workspace bounding volumes: NOT rendered (an earlier pass drew these as
  // visible translucent spheres -- with many workspaces the overlapping
  // spheres cluttered the view badly, so that visual was dropped). Still computed once
  // physics settles (onEngineStop, see createGraph), purely as plain
  // {x, y, z, radius} data -- centerOnWorkspaceAtmosphere uses it to frame
  // the camera on a workspace's whole item cluster on selection, instead
  // of just the (invisible) workspace anchor point alone.
  var atmosphereByWorkspaceId = {};

  function childrenOf(workspaceId) {
    var ids = [];
    for (var id in nodesById) {
      if (Object.prototype.hasOwnProperty.call(nodesById, id) && nodesById[id].parent === workspaceId) ids.push(id);
    }
    return ids;
  }

  function buildWorkspaceAtmospheres() {
    if (!graph) return;
    atmosphereByWorkspaceId = {};

    var childrenByWorkspace = {};
    graph.graphData().nodes.forEach(function (n) {
      if (n.node_type === 'Workspace' || isObjectId(n.id) || !n.parent) return;
      if (typeof n.x !== 'number') return;
      (childrenByWorkspace[n.parent] = childrenByWorkspace[n.parent] || []).push(n);
    });

    Object.keys(childrenByWorkspace).forEach(function (workspaceId) {
      var children = childrenByWorkspace[workspaceId];
      var cx = 0, cy = 0, cz = 0;
      children.forEach(function (n) { cx += n.x; cy += n.y; cz += n.z; });
      cx /= children.length; cy /= children.length; cz /= children.length;
      var maxDist = 0;
      children.forEach(function (n) {
        var dx = n.x - cx, dy = n.y - cy, dz = n.z - cz;
        var dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
        if (dist > maxDist) maxDist = dist;
      });
      var radius = Math.max(16, maxDist * 1.2 + 10);
      atmosphereByWorkspaceId[workspaceId] = { x: cx, y: cy, z: cz, radius: radius };
    });
  }

  var button = null;
  var buttonLabelEl = null;
  var closeButton = null;
  var view = null;
  var backdropEl = null;
  var canvas = null; // outer container: sizing + overlay children (legend/tooltip/banner/empty-state)
  var engineEl = null; // inner container ForceGraph3D exclusively owns -- see .graph-map-engine in graph-map.css
  var titleEl = null;
  var searchInput = null;
  var searchResultsEl = null;
  var detailEl = null;
  var viewModeSelect = null;
  var filterButton = null;
  var filterPanelEl = null;
  var legendEl = null;
  var graph = null; // ForceGraph3D instance (Tanda 8; was `cy`, the Cytoscape instance)
  var isOpen = false;
  var loadState = 'idle'; // idle | loading | loaded | error
  var adjacency = null; // built once per load (GraphMapData.buildAdjacency) -- selection never rescans edges
  var selectedNodeId = null;
  var allNodesById = null; // every item-level node (connected or not) -- the search index's full catalog
  var nodesById = null; // id -> the live ForceGraph3D node object currently in graphData (has x/y/z once simulated)
  var defaultViewMode = 'both';
  var activeNodeTypes = null; // Set of node_type values currently visible (all, until filtered)
  var allNodeTypeCounts = null; // node_type -> count, from the loaded graph's own summary
  var resetButton = null;
  var fitButton = null;
  var exportJsonButton = null;
  var exportPngButton = null;
  var breadcrumbsEl = null;
  var breadcrumbTrail = []; // node ids, most-recent last, capped to BREADCRUMB_LIMIT
  var tooltipEl = null;
  // highlightState[id] = 'selected' | 'upstream' | 'downstream' | undefined.
  // Cytoscape used CSS classes for this; ForceGraph3D has no per-node
  // class system, so node/link color+opacity are plain accessor functions
  // reading this map, re-evaluated on every graph.refresh() call.
  var highlightState = {};
  var highlightActive = false; // whether *any* selection is active (drives the "dim everything else" mode)
  var dimOthers = true; // false only for view mode 'full' -- highlight in context, don't dim the rest
  var lastNodeClickAt = 0;
  var lastNodeClickId = null;
  var DOUBLE_CLICK_MS = 380;

  function currentLang() {
    // `state` is app.js's top-level `const state = {...}` -- not a
    // `window` property (classic-script `const`/`let` never are), but
    // still directly readable here as a bare identifier because both
    // files are non-module classic scripts sharing one global scope.
    // The typeof guard just protects against load-order changes.
    return typeof state !== 'undefined' && state.lang === 'en' ? 'en' : 'es';
  }

  function text(key) {
    return TEXT[currentLang()][key];
  }

  function otherMainSections() {
    return [
      document.querySelector('.modebar'),
      document.querySelector('.metrics'),
      document.getElementById('workspaceShell'),
    ].filter(Boolean);
  }

  function statusMessage(key) {
    statusMessageText(text(key));
  }

  // For TEXT entries that are functions (take arguments) rather than plain
  // strings -- e.g. objectsShown(count, label) -- callers resolve the
  // function themselves and pass the final string here.
  function statusMessageText(message) {
    if (!canvas) return;
    var existing = canvas.querySelector('.graph-map-empty-state');
    if (!existing) {
      existing = document.createElement('div');
      existing.className = 'graph-map-empty-state';
      canvas.appendChild(existing);
    }
    existing.hidden = false;
    existing.textContent = message;
  }

  function hideStatusMessage() {
    var existing = canvas && canvas.querySelector('.graph-map-empty-state');
    if (existing) existing.hidden = true;
  }

  // --- Color/opacity accessors driving all visual state (selection,
  // dimming, type filter) -- plain functions re-evaluated by ForceGraph3D
  // on refresh(), replacing Cytoscape's CSS-class-toggle approach. ---

  function nodeColorAccessor(d) {
    var h = highlightState[d.id];
    if (h === 'selected') return '#ffffff';
    if (h === 'upstream') return '#f5a742';
    if (h === 'downstream') return '#4fd6a4';
    return nodeColorFor(d);
  }

  function nodeOpacityFor(d) {
    if (!highlightActive || !dimOthers) return 0.92;
    return highlightState[d.id] ? 0.98 : 0.06;
  }

  // True for a real (non-synthetic, non-object-level) edge whose two ends
  // sit in different workspaces -- exactly the "this connection crosses a
  // workspace boundary" case requested explicitly, now that a workspace
  // reads as an atmosphere sphere rather than a node: these are the edges
  // that visibly poke through two different spheres, so they get their own
  // distinct, brighter treatment instead of blending into the same neutral
  // gray every other edge uses.
  function isCrossWorkspaceLink(l) {
    var d = l.__data || {};
    if (d.__synthetic) return false;
    var sourceId = typeof l.source === 'object' ? l.source.id : l.source;
    var targetId = typeof l.target === 'object' ? l.target.id : l.target;
    if (isObjectId(sourceId) || isObjectId(targetId)) return false;
    var sourceNode = nodesById && nodesById[sourceId];
    var targetNode = nodesById && nodesById[targetId];
    if (!sourceNode || !targetNode) return false;
    var sw = sourceNode.workspace_name;
    var tw = targetNode.workspace_name;
    return !!sw && !!tw && sw !== tw;
  }

  function linkColorAccessor(l) {
    var d = l.__data || {};
    if (d.__synthetic) return 'rgba(90,105,135,0.16)';
    var sourceId = typeof l.source === 'object' ? l.source.id : l.source;
    var targetId = typeof l.target === 'object' ? l.target.id : l.target;
    var sourceState = highlightState[sourceId];
    var targetState = highlightState[targetId];
    if (sourceState === 'selected' && targetState === 'upstream') return '#f5a742';
    if (targetState === 'selected' && sourceState === 'upstream') return '#f5a742';
    if (sourceState === 'selected' && targetState === 'downstream') return '#4fd6a4';
    if (targetState === 'selected' && sourceState === 'downstream') return '#4fd6a4';
    if (sourceState === 'upstream' && targetState === 'upstream') return '#f5a742';
    if (sourceState === 'downstream' && targetState === 'downstream') return '#4fd6a4';
    if (d.relationship_type === 'external_feed') return '#e879f9';
    if (isCrossWorkspaceLink(l)) return '#e5edff';
    return d.relationship_type === 'implied_data_usage' ? 'rgba(150,160,185,0.35)' : 'rgba(120,132,158,0.55)';
  }

  function linkOpacityFor(l) {
    var d = l.__data || {};
    if (d.__synthetic) return 0.15;
    if (!highlightActive || !dimOthers) return (d.relationship_type === 'external_feed' || isCrossWorkspaceLink(l)) ? 0.75 : 0.55;
    var sourceId = typeof l.source === 'object' ? l.source.id : l.source;
    var targetId = typeof l.target === 'object' ? l.target.id : l.target;
    return (highlightState[sourceId] && highlightState[targetId]) ? 0.95 : 0.03;
  }

  // Arrowheads are real 3D cone geometry (see linkDirectionalArrowLength in
  // createGraph) -- Tanda 8 measured rendering one on every link at once as
  // the single biggest cost in this whole view (~40 FPS on their own), so
  // this stays keyed to "actively highlighted" specifically, not to
  // linkWidthFor's own >1 check -- cross-workspace links are now *also*
  // drawn a bit wider by default (below), and with hundreds of them on a
  // large tenant, tying arrows to width too would silently bring
  // that cost back for all of them at once, all the time.
  function isLinkHighlighted(l) {
    var d = l.__data || {};
    if (d.__synthetic) return false;
    var sourceId = typeof l.source === 'object' ? l.source.id : l.source;
    var targetId = typeof l.target === 'object' ? l.target.id : l.target;
    return !!(highlightState[sourceId] && highlightState[targetId]);
  }

  function linkWidthFor(l) {
    var d = l.__data || {};
    if (d.__synthetic) return 0.4;
    if (isLinkHighlighted(l)) return 2.2;
    return (d.relationship_type === 'external_feed' || isCrossWorkspaceLink(l)) ? 1.6 : 1;
  }

  function nodeVisibilityFor(d) {
    if (isObjectId(d.id)) return true; // object-level nodes aren't part of the item-type filter's domain
    return !activeNodeTypes || activeNodeTypes.has(d.node_type);
  }

  function linkVisibilityFor(l) {
    var d = l.__data || {};
    var sourceId = typeof l.source === 'object' ? l.source.id : l.source;
    var targetId = typeof l.target === 'object' ? l.target.id : l.target;
    var sourceNode = nodesById && nodesById[sourceId];
    var targetNode = nodesById && nodesById[targetId];
    if (sourceNode && !nodeVisibilityFor(sourceNode)) return false;
    if (targetNode && !nodeVisibilityFor(targetNode)) return false;
    return true;
  }

  var GRAPH_MAP_BG_BY_THEME = { dark: '#0b0f16', light: '#eef2f8' };

  // Mirrors the same data-theme + prefers-color-scheme resolution graph-map.css
  // itself uses for its CSS variables, so the WebGL canvas background (which
  // CSS can't reach -- it's drawn by Three.js, not styled) stays in sync with
  // the rest of the view's chrome instead of always looking dark.
  function currentGraphMapTheme() {
    var explicit = document.documentElement.getAttribute('data-theme');
    if (explicit === 'light' || explicit === 'dark') return explicit;
    var systemLight = window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches;
    return systemLight ? 'light' : 'dark';
  }

  function graphMapBackgroundColor() {
    return GRAPH_MAP_BG_BY_THEME[currentGraphMapTheme()] || GRAPH_MAP_BG_BY_THEME.dark;
  }

  function createGraph(nodes, links) {
    graph = window.ForceGraph3D()(engineEl)
      .backgroundColor(graphMapBackgroundColor())
      .nodeId('id')
      .nodeVal(nodeVal)
      .nodeColor(nodeColorAccessor)
      .nodeOpacity(0.92)
      .nodeResolution(10)
      .nodeThreeObject(nodeThreeObjectFor)
      .nodeLabel(function () { return ''; }) // custom tooltip (showTooltip) replaces the library's default hover label
      .nodeVisibility(nodeVisibilityFor)
      .linkSource('source')
      .linkTarget('target')
      .linkColor(linkColorAccessor)
      .linkOpacity(0.55)
      .linkWidth(linkWidthFor)
      .linkVisibility(linkVisibilityFor)
      // Arrowheads are real 3D cone geometry per link, not a cheap 2D
      // stroke -- measured live (2026-07-08) that rendering one on every
      // link (~5,100 once the synthetic clustering links below are added)
      // alone dropped a locked 60 FPS to ~23 FPS, dominating every other
      // cost in this file combined. Only rendering them on the handful of
      // links actually highlighted after a click (linkWidthFor already
      // marks those the same way) keeps the idle/panning view at full
      // speed and still shows real direction exactly when it matters --
      // the moving particles below (linkDirectionalParticles) already
      // carry the same directionality cue for the highlighted set too, so
      // nothing is lost, just no longer paid for on the other ~5,000 links.
      .linkDirectionalArrowLength(function (l) { return isLinkHighlighted(l) ? 4 : 0; })
      .linkDirectionalArrowRelPos(1)
      .linkDirectionalParticles(0)
      .linkDirectionalParticleWidth(1.6)
      .linkDirectionalParticleColor(function () { return '#ffffff'; })
      // Without an explicit cooldown, d3-force-3d keeps re-simulating in
      // the background well after the layout has visually settled --
      // measured that this alone dropped real interaction from a locked
      // 60 FPS down to roughly a fifth of that on a graph of a few thousand
      // nodes, competing with rendering for every frame. Let
      // the user watch it settle for a few seconds (part of the "feels
      // alive" 3D effect that was asked for), then stop for good --
      // interaction afterward pays only rendering cost, not physics too.
      .cooldownTime(4000)
      // Workspace atmospheres (see buildWorkspaceAtmospheres) need real,
      // settled item positions to compute a sensible enclosing sphere --
      // onEngineStop fires once cooldownTime's simulation actually stops,
      // exactly the same moment interaction becomes cheap again.
      .onEngineStop(buildWorkspaceAtmospheres)
      .onNodeClick(handleNodeClick)
      .onNodeHover(function (node) {
        if (node) showTooltip(node); else hideTooltip();
      })
      .onBackgroundClick(clearSelection);

    graph.graphData({ nodes: nodes, links: links });
    rebuildNodesById();

    // d3-force-3d charge is tuned down from its (very strong, built for
    // much smaller graphs) default -- at hundreds of nodes the default repulsion
    // makes the whole graph balloon out to the point where related items
    // and their workspace drift apart instead of clustering, fighting the
    // synthetic parent links added below. linkStrength stays default;
    // only charge (repulsion) needed taming to get a legible cluster shape.
    if (typeof graph.d3Force === 'function') {
      var chargeForce = graph.d3Force('charge');
      if (chargeForce && typeof chargeForce.strength === 'function') chargeForce.strength(-40);
    }

    if (canvas) {
      var rect = canvas.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) graph.width(rect.width).height(rect.height);
    }

    setupCursorCenteredZoom();
    spinPortals();
  }

  // Runs independently of 3d-force-graph's own physics engine tick (which
  // stops firing once cooldownTime ends, see createGraph) -- the portal
  // rings still need to keep spinning long after the layout has settled,
  // and the library's own renderer already redraws every frame regardless
  // of physics state (camera controls need that), so mutating .rotation
  // here is picked up by the next paint for free without this loop having
  // to trigger a render itself.
  var portalSpinStarted = false;
  function spinPortals() {
    if (portalSpinStarted) return;
    portalSpinStarted = true;
    function tick() {
      for (var i = 0; i < portalMeshes.length; i++) {
        portalMeshes[i].rotation.x += 0.006;
        portalMeshes[i].rotation.y += 0.011;
      }
      requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }

  // Default TrackballControls zoom (mouse wheel) always dollies straight
  // toward/away from its fixed `target` -- scrolling in never gets you
  // closer to whatever cluster the cursor happens to be over, only to
  // whatever the target happened to be centered on when the view opened.
  // Requested explicitly: wheel-zoom should feel like "diving in" toward
  // the point under the cursor, letting the user steer into one cluster at
  // a time, the same way map/CAD tools with cursor-anchored zoom behave.
  // Left-drag-to-look-around and right-drag-to-pan are untouched --
  // TrackballControls already provides both by default, nothing in this
  // function changes that.
  function setupCursorCenteredZoom() {
    if (!window.THREE || !graph) return;
    var controls = typeof graph.controls === 'function' ? graph.controls() : null;
    var camera = typeof graph.camera === 'function' ? graph.camera() : null;
    var renderer = typeof graph.renderer === 'function' ? graph.renderer() : null;
    if (!controls || !camera || !renderer || !renderer.domElement) return;

    // TrackballControls' own wheel handling always targets its fixed
    // `.target` -- disabling it (it exposes this exact flag) leaves rotate
    // (left-drag) and pan (right-drag) untouched and makes the listener
    // below the only thing that reacts to wheel events.
    controls.noZoom = true;

    var raycaster = new window.THREE.Raycaster();
    var pointerNdc = new window.THREE.Vector2();

    function focusPointUnderCursor(clientX, clientY) {
      var rect = renderer.domElement.getBoundingClientRect();
      pointerNdc.x = ((clientX - rect.left) / rect.width) * 2 - 1;
      pointerNdc.y = -((clientY - rect.top) / rect.height) * 2 + 1;
      raycaster.setFromCamera(pointerNdc, camera);

      // Prefer an actual node under the cursor (precise "dive into this
      // node") over the generic depth-plane fallback below.
      var meshes = [];
      for (var id in meshByNodeId) if (Object.prototype.hasOwnProperty.call(meshByNodeId, id)) meshes.push(meshByNodeId[id]);
      if (meshes.length) {
        var hits = raycaster.intersectObjects(meshes, false);
        if (hits.length) return hits[0].point;
      }

      // Empty space: intersect a plane at the target's depth, facing the
      // camera, so scrolling while pointing off to one side still steers
      // the view that way instead of doing nothing.
      var forward = new window.THREE.Vector3();
      camera.getWorldDirection(forward);
      var plane = new window.THREE.Plane().setFromNormalAndCoplanarPoint(forward, controls.target);
      var point = new window.THREE.Vector3();
      var hit = raycaster.ray.intersectPlane(plane, point);
      return hit || controls.target.clone();
    }

    renderer.domElement.addEventListener('wheel', function (event) {
      event.preventDefault();
      var focus = focusPointUnderCursor(event.clientX, event.clientY);
      // deltaY > 0 (scroll down) zooms out -- factor > 1 moves camera/target
      // away from focus; deltaY < 0 (scroll in/up) zooms in, factor < 1
      // moves both toward focus. Exponential (not linear) so the zoom feels
      // consistent whether the camera is far out or already close in.
      var factor = Math.pow(0.9, -event.deltaY / 100);
      camera.position.sub(focus).multiplyScalar(factor).add(focus);
      controls.target.sub(focus).multiplyScalar(factor).add(focus);
    }, { passive: false });
  }

  function rebuildNodesById() {
    nodesById = {};
    if (!graph) return;
    graph.graphData().nodes.forEach(function (n) { nodesById[n.id] = n; });
  }

  // Tap-vs-double-tap: ForceGraph3D has no built-in double-click event, so
  // this tracks consecutive clicks on the same node within DOUBLE_CLICK_MS
  // -- mirrors Cytoscape's 'tap'/'dbltap' split (single = select, double =
  // drill into object-level detail, G.8).
  function handleNodeClick(node) {
    if (!node) return;
    var now = Date.now();
    var isDouble = lastNodeClickId === node.id && (now - lastNodeClickAt) < DOUBLE_CLICK_MS;
    lastNodeClickAt = now;
    lastNodeClickId = node.id;
    if (isDouble) {
      lastNodeClickAt = 0; // consume -- a third rapid click starts a fresh pair, not another double
      // A Workspace atmosphere sphere isn't an item -- it has no entry in
      // by_item_id (built server-side only from item-level edges), so
      // showObjectsForItem() would always resolve to zero results after a
      // real (slow, tens of MB) fetch. Same type check selectNode() already does
      // for single-click; double-click on a workspace should drill into its
      // item breakdown instead, same as single-click does.
      var meta = nodesById[node.id];
      if (meta && meta.node_type === 'Workspace') {
        selectWorkspaceNode(node.id);
      } else if (!isObjectId(node.id)) {
        showObjectsForItem(node.id);
      }
      return;
    }
    selectNode(node.id);
  }

  // H.2-era hover tooltip, ported as-is (positions next to the node's
  // current *screen* projection, not a continuous mousemove listener).
  function showTooltip(node) {
    if (!tooltipEl || !graph) return;
    var pos = typeof graph.graph2ScreenCoords === 'function'
      ? graph.graph2ScreenCoords(node.x, node.y, node.z)
      : null;
    if (!pos) return;
    var subtitle = typeLabel(node);
    if (node.workspace_name) subtitle += ' · ' + node.workspace_name;
    tooltipEl.innerHTML = '';
    var name = document.createElement('strong');
    name.textContent = node.label || node.id;
    var sub = document.createElement('span');
    sub.textContent = subtitle;
    tooltipEl.appendChild(name);
    tooltipEl.appendChild(sub);
    tooltipEl.style.left = (pos.x + 14) + 'px';
    tooltipEl.style.top = (pos.y + 14) + 'px';
    tooltipEl.hidden = false;
  }

  function hideTooltip() {
    if (tooltipEl) tooltipEl.hidden = true;
  }

  // Tanda 8 deferred item: direct user feedback was "no veo ninguna tabla
  // ya sea de fabric u otro origen, vista o sp" -- G.8's original design
  // only ever surfaced object-level nodes in a separate "focused" canvas
  // that hid the rest of the graph, which technically answered "can I see
  // this item's tables" but not "I want to see tables in the main map."
  // Loading the FULL object graph into the main view isn't an option --
  // merging thousands of object nodes and edges in drops the same
  // GPU-accelerated 60 FPS to single digits, unusable. Almost every
  // referenced object is typically shared by multiple items too (the vast
  // majority have 2+ consumers), so there's no "long tail
  // of rarely-used objects" to trim down to a small always-on default
  // either. The fix: objects are revealed progressively, ADDED directly
  // into the same always-visible main graph (never hiding anything, no
  // separate "focused mode" to enter/exit) one item at a time, on click --
  // exactly the same GraphMapData.getObjectEdgesForItem() O(1) lookup G.8
  // already built, just merged in place instead of swapped in.
  function resetView() {
    clearMergedObjects();
    clearSelection();
    breadcrumbTrail = [];
    renderBreadcrumbs();
    renderLegend(); // clearMergedObjects() changes what's on screen -- the legend's own counts must follow
    fitView();
  }

  // Strips every previously-added object-level node/link back out, restoring
  // the original connected-item-only graph -- object ids always start with
  // "object::" (isObjectId), so no separate bookkeeping Set is needed to
  // know what to remove.
  function clearMergedObjects() {
    if (!graph) return;
    var data = graph.graphData();
    if (!data.nodes.some(function (n) { return isObjectId(n.id); })) return; // nothing to clear
    var survivingNodes = data.nodes.filter(function (n) { return !isObjectId(n.id); });
    var survivingLinks = data.links.filter(function (l) {
      var sourceId = typeof l.source === 'object' ? l.source.id : l.source;
      var targetId = typeof l.target === 'object' ? l.target.id : l.target;
      return !isObjectId(sourceId) && !isObjectId(targetId);
    });
    graph.graphData({ nodes: survivingNodes, links: survivingLinks });
    rebuildNodesById();
    adjacency = window.GraphMapData.buildAdjacency(survivingLinks.map(function (l) { return { data: l.__data }; }));
  }

  // Fetches one item's object-level lineage (tables/columns/files feeding
  // it or fed by it, plus downstream reports) via GraphMapData's by_item_id
  // index -- O(1) regardless of the object graph's total edge count -- and
  // merges the ones not already on screen directly into the main graph.
  function showObjectsForItem(itemId) {
    if (!graph || !window.GraphMapData) return;
    var itemNode = nodesById[itemId];
    if (!itemNode) return;

    statusMessage('loadingObjects');
    window.GraphMapData.getObjectEdgesForItem(itemId)
      .then(function (result) {
        hideStatusMessage();
        if (result.nodes.length === 0) {
          statusMessage('focusedEmpty');
          setTimeout(hideStatusMessage, 1800);
          return;
        }

        var data = graph.graphData();
        var existingIds = {};
        data.nodes.forEach(function (n) { existingIds[n.id] = true; });

        var newNodes = result.nodes
          .filter(function (n) { return !existingIds[n.data.id]; })
          .map(flattenNode);
        // Edges can still be new even when both endpoints already exist
        // (e.g. a second item sharing an object another click already
        // added) -- dedupe by id, not by endpoint presence.
        var existingLinkIds = {};
        data.links.forEach(function (l) { if (l.__data) existingLinkIds[l.__data.id] = true; });
        var newLinks = result.edges
          .filter(function (e) { return !existingLinkIds[e.data.id]; })
          .map(flattenLink);

        graph.graphData({ nodes: data.nodes.concat(newNodes), links: data.links.concat(newLinks) });
        rebuildNodesById();

        // Rebuild adjacency including the object-level edges just added, so
        // selecting an object node computes correct upstream/downstream
        // instead of stale item-only adjacency. buildAdjacency (graph-map-
        // data.js) expects Cytoscape-shaped {data: {...}} elements, not the
        // flat objects ForceGraph3D itself works with -- re-wrap __data
        // (the original flat payload) back into that shape.
        adjacency = window.GraphMapData.buildAdjacency(graph.graphData().links.map(function (l) { return { data: l.__data }; }));

        selectNode(itemId, { center: false, mode: 'both' });
        pushBreadcrumb(itemId);
        renderLegend();
        statusMessageText(text('objectsShown')(newNodes.length, itemNode.label));
        setTimeout(hideStatusMessage, 2400);
        buildWorkspaceAtmospheres(); // object nodes don't move their parent item, but cheap to keep in sync
        setTimeout(function () { fitView(); }, 600); // let the new nodes settle briefly before framing them
      })
      .catch(function (error) {
        hideStatusMessage();
        // eslint-disable-next-line no-console
        console.error('[GraphMap] fallo cargando el detalle de objetos:', error);
      });
  }

  function fitView() {
    if (!graph) return;
    graph.zoomToFit(400, 60, function (d) { return nodeVisibilityFor(d); });
  }

  function triggerDownload(filename, href) {
    var link = document.createElement('a');
    link.href = href;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  }

  function exportJson() {
    if (!graph) return;
    var data = graph.graphData();
    var visibleNodes = data.nodes.filter(nodeVisibilityFor);
    var visibleLinks = data.links.filter(linkVisibilityFor);
    var payload = {
      exported_at: new Date().toISOString(),
      selected_node_id: selectedNodeId,
      view_mode: defaultViewMode,
      nodes: visibleNodes.map(function (n) { return n.__data; }),
      edges: visibleLinks.map(function (l) { return l.__data; }),
    };
    var blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
    triggerDownload('graph-map-view.json', URL.createObjectURL(blob));
  }

  function exportPng() {
    if (!graph || typeof graph.renderer !== 'function') return;
    var rendererDomEl = graph.renderer().domElement;
    triggerDownload('graph-map-view.png', rendererDomEl.toDataURL('image/png'));
  }

  function pushBreadcrumb(nodeId) {
    if (breadcrumbTrail[breadcrumbTrail.length - 1] === nodeId) return;
    breadcrumbTrail.push(nodeId);
    if (breadcrumbTrail.length > BREADCRUMB_LIMIT) {
      breadcrumbTrail = breadcrumbTrail.slice(breadcrumbTrail.length - BREADCRUMB_LIMIT);
    }
    renderBreadcrumbs();
  }

  function renderBreadcrumbs() {
    if (!breadcrumbsEl) return;
    if (breadcrumbTrail.length === 0) {
      breadcrumbsEl.hidden = true;
      return;
    }
    breadcrumbsEl.hidden = false;
    breadcrumbsEl.innerHTML = '';
    breadcrumbTrail.forEach(function (nodeId, index) {
      if (index > 0) {
        var sep = document.createElement('span');
        sep.className = 'graph-map-breadcrumb-sep';
        sep.textContent = '›';
        breadcrumbsEl.appendChild(sep);
      }
      var crumb = document.createElement('button');
      crumb.type = 'button';
      var node = nodesById ? nodesById[nodeId] : null;
      crumb.textContent = node ? node.label : nodeId;
      crumb.addEventListener('click', function () {
        breadcrumbTrail = breadcrumbTrail.slice(0, index + 1);
        selectFromSearch(nodeId);
      });
      breadcrumbsEl.appendChild(crumb);
    });
  }

  // Workspaces carry no real dependency edges of their own (only the
  // synthetic parent links items use for clustering, deliberately excluded
  // from `adjacency` -- see loadAndRender) -- upstream/downstream traversal
  // is meaningless for them. Selecting one instead highlights every item
  // that belongs to it, the same way upstream/downstream highlighting
  // works for a regular item -- selecting a workspace still means "show
  // everything inside it," just without a visible sphere marking where
  // "inside" is.
  function selectWorkspaceNode(nodeId, options) {
    var center = !options || options.center !== false;
    selectedNodeId = nodeId;
    var childIds = childrenOf(nodeId);

    highlightState = {};
    highlightState[nodeId] = 'selected';
    childIds.forEach(function (id) { highlightState[id] = 'downstream'; });
    highlightActive = true;
    dimOthers = true;
    graph.refresh();
    refreshAllNodeMeshHighlights();
    graph.linkDirectionalParticles(0);

    if (center) centerOnWorkspaceAtmosphere(nodeId);
    renderWorkspaceDetailPanel(nodeId, childIds);
    pushBreadcrumb(nodeId);
  }

  function centerOnWorkspaceAtmosphere(nodeId) {
    var atmosphere = atmosphereByWorkspaceId[nodeId];
    if (!atmosphere) { centerOnNode(nodeId); return; }
    var distance = atmosphere.radius * 2.4;
    var currentPos = graph.cameraPosition();
    var vector = { x: atmosphere.x - currentPos.x, y: atmosphere.y - currentPos.y, z: atmosphere.z - currentPos.z };
    var length = Math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z) || 1;
    var ratio = 1 - distance / length;
    graph.cameraPosition(
      { x: currentPos.x + vector.x * ratio, y: currentPos.y + vector.y * ratio, z: currentPos.z + vector.z * ratio },
      { x: atmosphere.x, y: atmosphere.y, z: atmosphere.z },
      600
    );
  }

  function selectNode(nodeId, options) {
    if (!graph || !adjacency || !nodesById[nodeId]) return;
    if (nodesById[nodeId].node_type === 'Workspace') { selectWorkspaceNode(nodeId, options); return; }
    var center = !options || options.center !== false;
    var mode = (options && options.mode) || defaultViewMode;
    selectedNodeId = nodeId;

    var fullUpstream = window.GraphMapData.traverse(adjacency, nodeId, 'upstream');
    var fullDownstream = window.GraphMapData.traverse(adjacency, nodeId, 'downstream');

    var upstream = fullUpstream;
    var downstream = fullDownstream;
    if (mode === 'neighbors') {
      upstream = {
        nodes: (adjacency.outgoing[nodeId] || []).map(function (l) { return l.nodeId; }),
        edges: (adjacency.outgoing[nodeId] || []).map(function (l) { return l.edgeId; }),
      };
      downstream = {
        nodes: (adjacency.incoming[nodeId] || []).map(function (l) { return l.nodeId; }),
        edges: (adjacency.incoming[nodeId] || []).map(function (l) { return l.edgeId; }),
      };
    }

    highlightState = {};
    highlightState[nodeId] = 'selected';
    if (mode === 'both' || mode === 'upstream' || mode === 'neighbors' || mode === 'full') {
      upstream.nodes.forEach(function (id) { highlightState[id] = 'upstream'; });
    }
    if (mode === 'both' || mode === 'downstream' || mode === 'neighbors' || mode === 'full') {
      downstream.nodes.forEach(function (id) { highlightState[id] = 'downstream'; });
    }
    highlightActive = true;
    dimOthers = mode !== 'full';
    graph.refresh(); // still needed: link accessors (color/opacity/width) are unaffected by nodeThreeObject and do re-evaluate here
    refreshAllNodeMeshHighlights(); // nodeColor/nodeOpacity, in contrast, are inert once nodeThreeObject is set -- mutate each node's own mesh material directly instead
    startParticleFlow(nodeId, upstream, downstream, mode);

    if (center) centerOnNode(nodeId);

    renderDetailPanel(nodeId, fullUpstream, fullDownstream);
    pushBreadcrumb(nodeId);
  }

  // Replaces G.9's manual dash-offset "illuminated streets" animation --
  // linkDirectionalParticles is 3d-force-graph's own built-in equivalent
  // (small spheres flowing source->target along a link), no interval/timer
  // to manage or self-stop ourselves.
  function startParticleFlow(nodeId, upstream, downstream, mode) {
    if (!graph) return;
    var activeEdgeIds = {};
    if (mode === 'both' || mode === 'upstream' || mode === 'neighbors' || mode === 'full') {
      upstream.edges.forEach(function (id) { activeEdgeIds[id] = true; });
    }
    if (mode === 'both' || mode === 'downstream' || mode === 'neighbors' || mode === 'full') {
      downstream.edges.forEach(function (id) { activeEdgeIds[id] = true; });
    }
    graph.linkDirectionalParticles(function (l) {
      var d = l.__data || {};
      return activeEdgeIds[d.id] ? 2 : 0;
    });
  }

  function centerOnNode(nodeId) {
    var node = nodesById[nodeId];
    if (!node || typeof node.x !== 'number') return;
    var distance = 220;
    var currentPos = graph.cameraPosition();
    var vector = { x: node.x - currentPos.x, y: node.y - currentPos.y, z: node.z - currentPos.z };
    var length = Math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z) || 1;
    var ratio = 1 - distance / length;
    graph.cameraPosition(
      { x: currentPos.x + vector.x * ratio, y: currentPos.y + vector.y * ratio, z: currentPos.z + vector.z * ratio },
      node,
      600
    );
  }

  function clearSelection() {
    if (!graph) return;
    selectedNodeId = null;
    highlightState = {};
    highlightActive = false;
    graph.linkDirectionalParticles(0);
    graph.refresh();
    refreshAllNodeMeshHighlights();
    hideDetailPanel();
  }

  function hideDetailPanel() {
    if (detailEl) detailEl.hidden = true;
  }

  function fabricUrl(node) {
    var workspaceId = node.workspace_technical_id;
    var itemId = node.technical_id;
    if (!workspaceId || !itemId) return null;
    return 'https://app.fabric.microsoft.com/groups/' + workspaceId + '/items/' + itemId + '?experience=fabric-developer';
  }

  function renderDetailList(container, ids, emptyText) {
    container.innerHTML = '';
    if (ids.length === 0) {
      var empty = document.createElement('li');
      empty.textContent = emptyText;
      container.appendChild(empty);
      return;
    }
    ids.slice(0, DETAIL_LIST_LIMIT).forEach(function (id) {
      var node = nodesById[id];
      if (!node) return;
      var li = document.createElement('li');
      li.textContent = node.label + '  [' + node.node_type + ']';
      container.appendChild(li);
    });
    if (ids.length > DETAIL_LIST_LIMIT) {
      var more = document.createElement('li');
      more.className = 'graph-map-detail-list-more';
      more.textContent = text('detailListMore')(ids.length - DETAIL_LIST_LIMIT);
      container.appendChild(more);
    }
  }

  function renderWorkspaceDetailPanel(nodeId, childIds) {
    if (!detailEl || !nodesById[nodeId]) return;
    var d = nodesById[nodeId];

    detailEl.innerHTML = '';
    detailEl.hidden = false;

    var header = document.createElement('div');
    header.className = 'graph-map-detail-header';
    var name = document.createElement('h3');
    name.textContent = d.label;
    var close = document.createElement('button');
    close.type = 'button';
    close.className = 'icon-button';
    close.setAttribute('aria-label', text('detailCloseLabel'));
    close.textContent = '×';
    close.addEventListener('click', clearSelection);
    header.appendChild(name);
    header.appendChild(close);
    detailEl.appendChild(header);

    var badge = document.createElement('span');
    badge.className = 'graph-map-detail-type-badge';
    badge.textContent = d.node_type || '';
    detailEl.appendChild(badge);

    var counts = document.createElement('div');
    counts.className = 'graph-map-detail-counts';
    var span = document.createElement('span');
    var strong = document.createElement('strong');
    strong.textContent = String(childIds.length);
    span.appendChild(strong);
    span.appendChild(document.createTextNode(' ' + text('detailItemCount')));
    counts.appendChild(span);
    detailEl.appendChild(counts);

    var actions = document.createElement('div');
    actions.className = 'graph-map-detail-actions';
    var copyBtn = document.createElement('button');
    copyBtn.type = 'button';
    copyBtn.textContent = text('detailCopyPath');
    copyBtn.addEventListener('click', function () {
      var restore = copyBtn.textContent;
      navigator.clipboard.writeText(d.id).then(function () {
        copyBtn.textContent = text('detailCopyDone');
        setTimeout(function () {
          copyBtn.textContent = restore;
        }, 1200);
      });
    });
    actions.appendChild(copyBtn);
    detailEl.appendChild(actions);

    var membersSection = document.createElement('div');
    membersSection.className = 'graph-map-detail-list';
    var membersTitle = document.createElement('h4');
    membersTitle.textContent = text('detailMembersTitle');
    var membersList = document.createElement('ul');
    renderDetailList(membersList, childIds, text('detailListEmpty'));
    membersSection.appendChild(membersTitle);
    membersSection.appendChild(membersList);
    detailEl.appendChild(membersSection);
  }

  function renderDetailPanel(nodeId, upstream, downstream) {
    if (!detailEl || !nodesById[nodeId]) return;
    var d = nodesById[nodeId];

    detailEl.innerHTML = '';
    detailEl.hidden = false;

    var header = document.createElement('div');
    header.className = 'graph-map-detail-header';
    var name = document.createElement('h3');
    name.textContent = d.label;
    var close = document.createElement('button');
    close.type = 'button';
    close.className = 'icon-button';
    close.setAttribute('aria-label', text('detailCloseLabel'));
    close.textContent = '×';
    close.addEventListener('click', clearSelection);
    header.appendChild(name);
    header.appendChild(close);
    detailEl.appendChild(header);

    var badge = document.createElement('span');
    badge.className = 'graph-map-detail-type-badge';
    badge.textContent = d.node_type || '';
    detailEl.appendChild(badge);

    var fields = document.createElement('dl');
    fields.className = 'graph-map-detail-fields';
    function field(labelKey, value) {
      if (!value) return;
      var dt = document.createElement('dt');
      dt.textContent = text(labelKey);
      var dd = document.createElement('dd');
      dd.textContent = value;
      fields.appendChild(dt);
      fields.appendChild(dd);
    }
    var isObjectNode = isObjectId(d.id);
    if (isObjectNode || d.node_type === 'ExternalOrigin') {
      field('detailSourceType', d.source_type);
      field('detailSourceServer', d.source_server);
      field('detailSourceDatabase', d.source_database);
      field('detailColumnCount', d.column_count ? String(d.column_count) : '');
      if (d.sensitivity_categories && d.sensitivity_categories.length) {
        field('detailSensitivity', d.sensitivity_categories.map(sensitivityCategoryLabel).join(', '));
      }
    } else {
      field('detailWorkspace', d.workspace_name);
      field('detailPath', d.id);
      field('detailDescription', d.description);
      if (d.is_certified) {
        field('detailCertified', d.certified_note || text('detailCertifiedDefault'));
      }
      if (d.tags && d.tags.length) {
        field('detailTags', d.tags.join(', '));
      }
      if (d.exec_run_count) {
        field('detailExecStatus', d.exec_last_status);
        field('detailExecLastRun', d.exec_latest_start_time);
        field('detailExecRunCount', d.exec_run_count + (d.exec_failed_count ? ' (' + d.exec_failed_count + ' ' + text('detailExecFailedSuffix') + ')' : ''));
      }
    }
    detailEl.appendChild(fields);

    var counts = document.createElement('div');
    counts.className = 'graph-map-detail-counts';
    function countBlock(count, labelKey) {
      var span = document.createElement('span');
      var strong = document.createElement('strong');
      strong.textContent = String(count);
      span.appendChild(strong);
      span.appendChild(document.createTextNode(' ' + text(labelKey)));
      return span;
    }
    counts.appendChild(countBlock(upstream.nodes.length, 'detailUpstreamCount'));
    counts.appendChild(countBlock(downstream.nodes.length, 'detailDownstreamCount'));
    detailEl.appendChild(counts);

    var actions = document.createElement('div');
    actions.className = 'graph-map-detail-actions';

    var upstreamBtn = document.createElement('button');
    upstreamBtn.type = 'button';
    upstreamBtn.textContent = text('detailViewUpstream');
    upstreamBtn.addEventListener('click', function () {
      selectNode(nodeId, { center: false, mode: 'upstream' });
    });
    actions.appendChild(upstreamBtn);

    var downstreamBtn = document.createElement('button');
    downstreamBtn.type = 'button';
    downstreamBtn.textContent = text('detailViewDownstream');
    downstreamBtn.addEventListener('click', function () {
      selectNode(nodeId, { center: false, mode: 'downstream' });
    });
    actions.appendChild(downstreamBtn);

    var bothBtn = document.createElement('button');
    bothBtn.type = 'button';
    bothBtn.textContent = text('detailViewBoth');
    bothBtn.addEventListener('click', function () {
      selectNode(nodeId, { center: false, mode: 'both' });
    });
    actions.appendChild(bothBtn);

    if (!isObjectNode && d.node_type !== 'ExternalOrigin') {
      var objectsBtn = document.createElement('button');
      objectsBtn.type = 'button';
      objectsBtn.textContent = text('detailViewObjects');
      objectsBtn.addEventListener('click', function () {
        showObjectsForItem(nodeId);
      });
      actions.appendChild(objectsBtn);
    }

    var copyBtn = document.createElement('button');
    copyBtn.type = 'button';
    copyBtn.textContent = text('detailCopyPath');
    copyBtn.addEventListener('click', function () {
      var restore = copyBtn.textContent;
      navigator.clipboard.writeText(d.id).then(function () {
        copyBtn.textContent = text('detailCopyDone');
        setTimeout(function () {
          copyBtn.textContent = restore;
        }, 1200);
      });
    });
    actions.appendChild(copyBtn);

    var fabricHref = fabricUrl(d);
    if (fabricHref) {
      var fabricLink = document.createElement('a');
      fabricLink.href = fabricHref;
      fabricLink.target = '_blank';
      fabricLink.rel = 'noopener';
      fabricLink.textContent = text('detailOpenFabric');
      actions.appendChild(fabricLink);
    }
    detailEl.appendChild(actions);

    var depsSection = document.createElement('div');
    depsSection.className = 'graph-map-detail-list';
    var depsTitle = document.createElement('h4');
    depsTitle.textContent = text('detailDepsTitle');
    var depsList = document.createElement('ul');
    var directDeps = (adjacency.outgoing[nodeId] || []).map(function (l) { return l.nodeId; });
    renderDetailList(depsList, directDeps, text('detailListEmpty'));
    depsSection.appendChild(depsTitle);
    depsSection.appendChild(depsList);
    detailEl.appendChild(depsSection);

    var consumersSection = document.createElement('div');
    consumersSection.className = 'graph-map-detail-list';
    var consumersTitle = document.createElement('h4');
    consumersTitle.textContent = text('detailConsumersTitle');
    var consumersList = document.createElement('ul');
    var directConsumers = (adjacency.incoming[nodeId] || []).map(function (l) { return l.nodeId; });
    renderDetailList(consumersList, directConsumers, text('detailListEmpty'));
    consumersSection.appendChild(consumersTitle);
    consumersSection.appendChild(consumersList);
    detailEl.appendChild(consumersSection);
  }

  function renderViewModeControl() {
    if (!viewModeSelect) return;
    viewModeSelect.innerHTML = '';
    VIEW_MODES.forEach(function (mode) {
      var option = document.createElement('option');
      option.value = mode;
      option.textContent = text('viewMode' + mode.charAt(0).toUpperCase() + mode.slice(1));
      if (mode === defaultViewMode) option.selected = true;
      viewModeSelect.appendChild(option);
    });
  }

  function applyTypeFilter() {
    if (!graph) return;
    graph.refresh();
    renderLegend();
  }

  function renderFilterPanel() {
    if (!filterPanelEl || !allNodeTypeCounts) return;
    filterPanelEl.innerHTML = '';

    var actions = document.createElement('div');
    actions.className = 'graph-map-filter-panel-actions';
    var allBtn = document.createElement('button');
    allBtn.type = 'button';
    allBtn.textContent = text('filterAll');
    allBtn.addEventListener('click', function () {
      activeNodeTypes = new Set(Object.keys(allNodeTypeCounts));
      applyTypeFilter();
      renderFilterPanel();
    });
    var noneBtn = document.createElement('button');
    noneBtn.type = 'button';
    noneBtn.textContent = text('filterNone');
    noneBtn.addEventListener('click', function () {
      activeNodeTypes = new Set();
      applyTypeFilter();
      renderFilterPanel();
    });
    actions.appendChild(allBtn);
    actions.appendChild(noneBtn);
    filterPanelEl.appendChild(actions);

    Object.keys(allNodeTypeCounts)
      .sort(function (a, b) { return allNodeTypeCounts[b] - allNodeTypeCounts[a]; })
      .forEach(function (nodeType) {
        var row = document.createElement('div');
        row.className = 'graph-map-filter-row';
        var checkboxId = 'graphMapFilter_' + nodeType;

        var checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.id = checkboxId;
        checkbox.checked = activeNodeTypes.has(nodeType);
        checkbox.addEventListener('change', function () {
          if (checkbox.checked) {
            activeNodeTypes.add(nodeType);
          } else {
            activeNodeTypes.delete(nodeType);
          }
          applyTypeFilter();
        });

        var label = document.createElement('label');
        label.setAttribute('for', checkboxId);
        label.textContent = nodeType;

        var count = document.createElement('span');
        count.className = 'graph-map-filter-count';
        count.textContent = String(allNodeTypeCounts[nodeType]);

        row.appendChild(checkbox);
        row.appendChild(label);
        row.appendChild(count);
        filterPanelEl.appendChild(row);
      });
  }

  function toggleFilterPanel(forceState) {
    if (!filterButton || !filterPanelEl) return;
    var next = typeof forceState === 'boolean' ? forceState : filterPanelEl.hidden;
    filterPanelEl.hidden = !next;
    filterButton.setAttribute('aria-expanded', String(next));
  }

  function computeVisibleTypeCounts() {
    var counts = {};
    if (!nodesById) return counts;
    Object.keys(nodesById).forEach(function (id) {
      var node = nodesById[id];
      if (!nodeVisibilityFor(node)) return;
      var isObject = isObjectId(id);
      var typeValue = isObject ? node.source_type : node.node_type;
      var key = (isObject ? 'object:' : 'item:') + (typeValue || '');
      counts[key] = (counts[key] || 0) + 1;
    });
    return counts;
  }

  // ExternalOrigin nodes all share one node_type, but real color now
  // varies per source_type (SQL/SharePoint/Dataverse/...) -- a flat
  // legend row would either show one misleading averaged swatch or just
  // the generic portal color, hiding that real variety. Broken out
  // separately from computeVisibleTypeCounts() (which only tracks the
  // top-level node_type/source_type keys) so the legend can render every
  // distinct origin type its own row, inside a collapsible group instead
  // of one flat row -- requested explicitly: "un subíndice... con un + para
  // abrir y verlo porque si no la lista será muy larga."
  function computeVisibleExternalOriginSourceTypeCounts() {
    var counts = {};
    if (!nodesById) return counts;
    Object.keys(nodesById).forEach(function (id) {
      var node = nodesById[id];
      if (node.node_type !== 'ExternalOrigin' || !nodeVisibilityFor(node)) return;
      var key = node.source_type || '';
      counts[key] = (counts[key] || 0) + 1;
    });
    return counts;
  }

  var externalOriginLegendExpanded = false;

  function renderLegend() {
    if (!legendEl) return;
    legendEl.innerHTML = '';
    var lang = currentLang();
    var counts = computeVisibleTypeCounts();
    var keys = Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; });
    keys.forEach(function (key) {
      var isObject = key.indexOf('object:') === 0;
      var typeValue = key.slice(key.indexOf(':') + 1);

      if (!isObject && typeValue === 'ExternalOrigin') {
        legendEl.appendChild(renderExternalOriginLegendGroup(counts[key], lang));
        return;
      }

      var meta = (isObject ? SOURCE_TYPE_META[typeValue] : NODE_TYPE_META[typeValue]) || DEFAULT_TYPE_META;

      var row = document.createElement('div');
      row.className = 'graph-map-legend-row';

      var swatch = document.createElement('span');
      swatch.className = 'graph-map-legend-swatch gm-shape-' + meta.shape;
      swatch.style.backgroundColor = meta.color;

      var label = document.createElement('span');
      label.className = 'graph-map-legend-row-label';
      label.textContent = meta[lang] || typeValue;

      var count = document.createElement('span');
      count.className = 'graph-map-legend-row-count';
      count.textContent = String(counts[key]);

      row.appendChild(swatch);
      row.appendChild(label);
      row.appendChild(count);
      legendEl.appendChild(row);
    });
  }

  function renderExternalOriginLegendGroup(totalCount, lang) {
    var baseMeta = NODE_TYPE_META.ExternalOrigin;
    var details = document.createElement('details');
    details.className = 'graph-map-legend-origin-group';
    details.open = externalOriginLegendExpanded;
    details.addEventListener('toggle', function () {
      externalOriginLegendExpanded = details.open;
    });

    var summary = document.createElement('summary');
    summary.className = 'graph-map-legend-row graph-map-legend-origin-summary';
    var swatch = document.createElement('span');
    swatch.className = 'graph-map-legend-swatch gm-shape-' + baseMeta.shape;
    swatch.style.backgroundColor = baseMeta.color;
    var label = document.createElement('span');
    label.className = 'graph-map-legend-row-label';
    label.textContent = baseMeta[lang] || 'ExternalOrigin';
    var count = document.createElement('span');
    count.className = 'graph-map-legend-row-count';
    count.textContent = String(totalCount);
    summary.appendChild(swatch);
    summary.appendChild(label);
    summary.appendChild(count);
    details.appendChild(summary);

    var sourceCounts = computeVisibleExternalOriginSourceTypeCounts();
    var sourceKeys = Object.keys(sourceCounts).sort(function (a, b) { return sourceCounts[b] - sourceCounts[a]; });
    sourceKeys.forEach(function (sourceType) {
      var meta = SOURCE_TYPE_META[sourceType] || DEFAULT_TYPE_META;
      var row = document.createElement('div');
      row.className = 'graph-map-legend-row graph-map-legend-origin-subrow';
      var subSwatch = document.createElement('span');
      subSwatch.className = 'graph-map-legend-swatch gm-shape-' + baseMeta.shape;
      subSwatch.style.backgroundColor = meta.color;
      var subLabel = document.createElement('span');
      subLabel.className = 'graph-map-legend-row-label';
      subLabel.textContent = meta[lang] || sourceType || '?';
      var subCount = document.createElement('span');
      subCount.className = 'graph-map-legend-row-count';
      subCount.textContent = String(sourceCounts[sourceType]);
      row.appendChild(subSwatch);
      row.appendChild(subLabel);
      row.appendChild(subCount);
      details.appendChild(row);
    });

    return details;
  }

  function selectFromSearch(nodeId) {
    if (!graph || !allNodesById) return;
    if (!nodesById[nodeId]) {
      // Isolated node (workspace, or an item with no captured lineage) --
      // not drawn by default (see loadAndRender), so add it just-in-time
      // instead of the search panel dead-ending on something it lists but
      // can't show.
      var nodeDef = allNodesById[nodeId];
      if (!nodeDef) return;
      var data = graph.graphData();
      graph.graphData({ nodes: data.nodes.concat([flattenNode(nodeDef)]), links: data.links });
      rebuildNodesById();
    }
    selectNode(nodeId);
  }

  function matchesQuery(node, needle) {
    if ((node.data.label || '').toLowerCase().indexOf(needle) !== -1) return true;
    var tags = node.data.tags;
    if (tags && tags.length) {
      for (var i = 0; i < tags.length; i++) {
        if (tags[i].toLowerCase().indexOf(needle) !== -1) return true;
      }
    }
    return false;
  }

  function renderSearchResults(query) {
    if (!searchResultsEl || !allNodesById) return;
    var needle = query.trim().toLowerCase();
    var matches = [];
    for (var id in allNodesById) {
      if (!needle || matchesQuery(allNodesById[id], needle)) {
        matches.push(allNodesById[id]);
        if (matches.length > SEARCH_RESULT_LIMIT) break;
      }
    }
    matches.sort(function (a, b) {
      return (a.data.label || '').localeCompare(b.data.label || '');
    });

    searchResultsEl.innerHTML = '';
    if (matches.length === 0) {
      var empty = document.createElement('p');
      empty.className = 'graph-map-search-empty';
      empty.textContent = needle ? text('searchEmpty') : text('searchHint');
      searchResultsEl.appendChild(empty);
      return;
    }

    var shown = matches.slice(0, SEARCH_RESULT_LIMIT);
    var fragment = document.createDocumentFragment();
    shown.forEach(function (node) {
      var item = document.createElement('button');
      item.type = 'button';
      item.className = 'graph-map-search-result';
      item.setAttribute('role', 'option');
      item.dataset.nodeId = node.data.id;

      var label = document.createElement('span');
      label.className = 'graph-map-result-label';
      label.textContent = node.data.label;
      item.appendChild(label);

      var type = document.createElement('span');
      type.className = 'graph-map-result-type';
      type.textContent = node.data.node_type;
      item.appendChild(type);

      item.addEventListener('click', function () {
        selectFromSearch(node.data.id);
      });
      fragment.appendChild(item);
    });
    searchResultsEl.appendChild(fragment);

    if (matches.length > SEARCH_RESULT_LIMIT) {
      var more = document.createElement('p');
      more.className = 'graph-map-search-empty';
      more.textContent = text('searchMore')(matches.length - SEARCH_RESULT_LIMIT);
      searchResultsEl.appendChild(more);
    }
  }

  // Cytoscape-shaped element ({data: {...}}) -> flat ForceGraph3D node/link
  // object. `__data` keeps the original flat data payload attached (used by
  // export/adjacency-rebuild code, which used to just call node.data()).
  function flattenNode(el) {
    var flat = {};
    for (var k in el.data) flat[k] = el.data[k];
    flat.__data = el.data;
    return flat;
  }

  function flattenLink(el) {
    var flat = {};
    for (var k in el.data) flat[k] = el.data[k];
    flat.source = el.data.source;
    flat.target = el.data.target;
    flat.__data = el.data;
    return flat;
  }

  // H.5's "gravitational clustering" relied on Cytoscape compound parent/
  // child nodes, a concept ForceGraph3D has no equivalent for. Reimplemented
  // here as real (if visually subtle) synthetic links from each item to its
  // workspace -- d3-force-3d's own link force then does the actual pulling,
  // no custom physics needed. Excluded from adjacency/upstream-downstream
  // traversal (__synthetic flag) so they never appear as real dependencies
  // in the detail panel or exports.
  function buildParentLinks(nodes) {
    var links = [];
    nodes.forEach(function (n) {
      if (n.data.parent) {
        links.push({
          data: {
            id: 'parent::' + n.data.id,
            source: n.data.id,
            target: n.data.parent,
            __synthetic: true,
          },
        });
      }
    });
    return links;
  }

  function loadAndRender() {
    if (loadState === 'loading' || loadState === 'loaded') return;
    loadState = 'loading';
    statusMessage('loading');
    window.GraphMapData.loadItemGraph()
      .then(function (rawGraph) {
        loadState = 'loaded';
        hideStatusMessage();

        allNodesById = {};
        rawGraph.nodes.forEach(function (node) {
          allNodesById[node.data.id] = node;
        });

        // Default view: connected nodes only (see build_graph_map_index.py
        // for why) -- the isolated ~15% (mostly workspace nodes with no
        // lineage participation) stay reachable via the search/index panel,
        // just not drawn on the canvas by default.
        var connectedNodeEls = rawGraph.nodes.filter(function (node) {
          return node.data.is_connected;
        });
        var connectedIds = {};
        connectedNodeEls.forEach(function (n) { connectedIds[n.data.id] = true; });
        var connectedEdgeEls = rawGraph.edges.filter(function (e) {
          return connectedIds[e.data.source] && connectedIds[e.data.target];
        });

        // adjacency is built BEFORE createGraph() since nodeVal() (node
        // size, driven by real connectivity/"influence") reads it.
        adjacency = window.GraphMapData.buildAdjacency(connectedEdgeEls.map(function (e) { return e; }));

        var nodes = connectedNodeEls.map(flattenNode);
        var links = connectedEdgeEls.map(flattenLink).concat(buildParentLinks(connectedNodeEls).map(flattenLink));

        createGraph(nodes, links);
        renderSearchResults('');

        allNodeTypeCounts = {};
        connectedNodeEls.forEach(function (node) {
          var t = node.data.node_type;
          allNodeTypeCounts[t] = (allNodeTypeCounts[t] || 0) + 1;
        });
        activeNodeTypes = new Set(Object.keys(allNodeTypeCounts));
        renderFilterPanel();
        renderLegend();
        renderViewModeControl();
      })
      .catch(function (error) {
        loadState = 'error';
        statusMessage('loadError');
        // eslint-disable-next-line no-console
        console.error('[GraphMap] fallo cargando el grafo:', error);
      });
  }

  function renderLabels() {
    if (titleEl) titleEl.textContent = text('title');
    if (button) button.title = text('buttonTitle');
    if (buttonLabelEl) buttonLabelEl.textContent = text('buttonLabel');
    if (closeButton) closeButton.setAttribute('aria-label', text('closeLabel'));
    if (searchInput) searchInput.placeholder = text('searchPlaceholder');
    if (filterButton) filterButton.textContent = text('filterButton');
    var viewModeLabelEl = document.getElementById('graphMapViewModeLabel');
    if (viewModeLabelEl) viewModeLabelEl.textContent = text('viewModeLabel');
    if (resetButton) resetButton.textContent = text('resetButton');
    if (fitButton) fitButton.textContent = text('fitButton');
    if (exportJsonButton) exportJsonButton.textContent = text('exportJsonButton');
    if (exportPngButton) exportPngButton.textContent = text('exportPngButton');
    if (allNodesById) renderSearchResults(searchInput ? searchInput.value : '');
    if (allNodeTypeCounts) renderFilterPanel();
    if (allNodeTypeCounts) renderLegend();
    if (allNodeTypeCounts) renderViewModeControl();
    renderBreadcrumbs();
    if (selectedNodeId && nodesById && nodesById[selectedNodeId]) {
      renderDetailPanel(
        selectedNodeId,
        window.GraphMapData.traverse(adjacency, selectedNodeId, 'upstream'),
        window.GraphMapData.traverse(adjacency, selectedNodeId, 'downstream')
      );
    }
  }

  // See the reveal-animation comment inside open() for why this exists --
  // guarantees .graph-map-view is never left visually/interactively
  // clipped, regardless of whether the animation played, was skipped, or
  // ended in some way the class-removal-on-next-open path wouldn't catch.
  function clearRevealClip() {
    view.classList.remove('graph-map-view-reveal-in');
    view.style.clipPath = '';
    view.style.removeProperty('--reveal-x');
    view.style.removeProperty('--reveal-y');
  }

  function open(event) {
    if (isOpen) return;
    // Roadmap Fase 4 (2026-08-31): DagView is a sibling full-screen overlay
    // living right next to this one's own toolbar button -- never both at
    // once (see dag-view.js's own symmetric guard on ITS open()).
    if (window.DagView) window.DagView.close();
    isOpen = true;
    otherMainSections().forEach(function (el) {
      el.hidden = true;
    });
    if (backdropEl) backdropEl.hidden = false;
    view.hidden = false;
    // Circular reveal from wherever the Grafo button was clicked (2026-08-
    // 18) -- same "grows forward from the click" request as the .modal-
    // panel open animation in app.js, just a clip-path circle instead of a
    // scale since this view fills nearly the whole screen rather than
    // sitting as a small centered card. clearRevealClip (below) forcibly
    // drops the class + any inline clip-path once the animation ends (or
    // immediately, if it never validly started) -- belt-and-suspenders so
    // a stuck/partial clip-path can never leave the 3D view unclickable,
    // which is exactly what happened live (2026-08-18) before this guard:
    // an animation-end listener is far more reliable than trusting every
    // browser to always revert clip-path to none on its own once a
    // fill-mode:none animation completes.
    view.classList.remove('graph-map-view-reveal-in');
    clearRevealClip();
    var rect = view.getBoundingClientRect();
    var canRevealFromClick = event && typeof event.clientX === 'number' && rect.width > 0 && rect.height > 0;
    if (canRevealFromClick) {
      var originX = ((event.clientX - rect.left) / rect.width) * 100;
      var originY = ((event.clientY - rect.top) / rect.height) * 100;
      view.style.setProperty('--reveal-x', originX + '%');
      view.style.setProperty('--reveal-y', originY + '%');
      void view.offsetWidth;
      view.classList.add('graph-map-view-reveal-in');
      view.addEventListener('animationend', clearRevealClip, { once: true });
      // Absolute fallback in case animationend never fires for any reason
      // (reduced-motion browsers that skip straight past it, a tab
      // backgrounded mid-animation, etc.) -- comfortably longer than the
      // animation's own 380ms.
      setTimeout(clearRevealClip, 600);
    }
    button.setAttribute('aria-pressed', 'true');
    renderLabels();
    if (graph) {
      var rect = canvas.getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0) graph.width(rect.width).height(rect.height);
      fitView();
    } else {
      loadAndRender();
    }
  }

  function close() {
    if (!isOpen) return;
    isOpen = false;
    clearRevealClip();
    view.hidden = true;
    if (backdropEl) backdropEl.hidden = true;
    otherMainSections().forEach(function (el) {
      el.hidden = false;
    });
    button.setAttribute('aria-pressed', 'false');
    hideTooltip();
  }

  function toggle(event) {
    if (isOpen) {
      close();
    } else {
      open(event);
    }
  }

  function onLanguageChange() {
    // The button itself lives in the main toolbar, outside this view, so
    // its visible label needs to stay in sync even while Graph Map Mode
    // is closed -- unlike everything else renderLabels() touches, which
    // is only ever visible while isOpen.
    if (button) button.title = text('buttonTitle');
    if (buttonLabelEl) buttonLabelEl.textContent = text('buttonLabel');
    if (!isOpen) return;
    renderLabels();
  }

  // The CSS variables in graph-map.css already react to data-theme/system
  // preference on their own -- this hook only needs to touch what CSS can't
  // reach: the WebGL canvas background color, drawn by Three.js.
  function onThemeChange() {
    if (!graph) return;
    graph.backgroundColor(graphMapBackgroundColor());
  }

  function init() {
    button = document.getElementById('graphMapButton');
    buttonLabelEl = document.getElementById('graphMapButtonLabel');
    closeButton = document.getElementById('graphMapCloseButton');
    view = document.getElementById('graphMapView');
    backdropEl = document.getElementById('graphMapBackdrop');
    canvas = document.getElementById('graphMapCanvas');
    engineEl = document.getElementById('graphMapEngine');
    titleEl = document.getElementById('graphMapTitle');
    searchInput = document.getElementById('graphMapSearchInput');
    searchResultsEl = document.getElementById('graphMapSearchResults');
    detailEl = document.getElementById('graphMapDetail');
    viewModeSelect = document.getElementById('graphMapViewModeSelect');
    filterButton = document.getElementById('graphMapFilterButton');
    filterPanelEl = document.getElementById('graphMapFilterPanel');
    legendEl = document.getElementById('graphMapLegend');
    tooltipEl = document.getElementById('graphMapTooltip');
    resetButton = document.getElementById('graphMapResetButton');
    fitButton = document.getElementById('graphMapFitButton');
    exportJsonButton = document.getElementById('graphMapExportJsonButton');
    exportPngButton = document.getElementById('graphMapExportPngButton');
    breadcrumbsEl = document.getElementById('graphMapBreadcrumbs');
    if (!button || !closeButton || !view || !canvas || !engineEl) return;

    button.title = text('buttonTitle');
    if (buttonLabelEl) buttonLabelEl.textContent = text('buttonLabel');
    button.addEventListener('click', toggle);
    closeButton.addEventListener('click', close);
    if (backdropEl) backdropEl.addEventListener('click', close);
    document.addEventListener('keydown', function (evt) {
      if (evt.key === 'Escape' && isOpen) close();
    });
    if (searchInput) {
      searchInput.placeholder = text('searchPlaceholder');
      searchInput.addEventListener('input', function () {
        renderSearchResults(searchInput.value);
      });
    }
    if (viewModeSelect) {
      viewModeSelect.addEventListener('change', function () {
        defaultViewMode = viewModeSelect.value;
        if (selectedNodeId) selectNode(selectedNodeId, { center: false });
      });
    }
    if (filterButton) {
      filterButton.textContent = text('filterButton');
      filterButton.addEventListener('click', function () {
        toggleFilterPanel();
      });
      document.addEventListener('click', function (evt) {
        if (!filterPanelEl || filterPanelEl.hidden) return;
        if (filterPanelEl.contains(evt.target) || filterButton.contains(evt.target)) return;
        toggleFilterPanel(false);
      });
    }
    if (resetButton) {
      resetButton.textContent = text('resetButton');
      resetButton.addEventListener('click', resetView);
    }
    if (fitButton) {
      fitButton.textContent = text('fitButton');
      fitButton.addEventListener('click', fitView);
    }
    if (exportJsonButton) {
      exportJsonButton.textContent = text('exportJsonButton');
      exportJsonButton.addEventListener('click', exportJson);
    }
    if (exportPngButton) {
      exportPngButton.textContent = text('exportPngButton');
      exportPngButton.addEventListener('click', exportPng);
    }
  }

  init();

  window.GraphMap = {
    open: open,
    close: close,
    toggle: toggle,
    onLanguageChange: onLanguageChange,
    onThemeChange: onThemeChange,
  };
})();
