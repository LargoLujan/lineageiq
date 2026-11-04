// A 2D DAG lineage
// diagram -- Purview's own lineage view is always anchored to ONE asset
// with upstream/downstream hops, not a whole-catalog explorer (that's
// already Graph Map Mode's job, in 3D). This is deliberately its own
// independent module, same architectural boundary graph-map.js already
// keeps from app.js (no shared state, no reach into app.js's detail panel
// or `state` -- confirmed by reading graph-map.js first: it never touches
// app.js internals either, clicking a node there re-anchors/inspects
// within its own view instead). Clicking a node here re-anchors the
// diagram on it instead, so exploring lineage is "walk the DAG" rather
// than "jump back to the main app".
//
// Data comes entirely from the REST API this project already exposes --
// GET /api/items (search) and GET /api/related-elements (bounded-hop
// upstream/downstream traversal, already used by mcp_server.py's own
// get_related_elements tool) -- no new backend route for this phase.
// /api/related-elements doesn't carry an item_type field, only
// qualified_name/hops/relationship_type/confidence/via/technical_id/
// workspace_id/fabric_url (see catalog._get_related_elements) -- node
// coloring below parses item_type out of the qualified_name's own
// documented "Workspace / Item Type / Item Name" shape instead of adding
// a backend field just for this.
//
// Layout: dagre.min.js (frontend/semantic-lineage/vendor/dagre.min.js,
// MIT), originally vendored for Planning Mode's card placement but
// never actually invoked there -- that view ended up using its own
// hand-rolled column/wave layout instead (see app.js's buildPlanningGraph
// area), leaving dagre loaded on every page for nothing. This is the
// first real dagre.layout() call in the project: real network-simplex
// rank assignment + median-heuristic crossing reduction, left-to-right
// (rankdir 'LR'), same "arrows always point downstream" convention
// Planning Mode already established. Rendered as plain SVG (crisp at any
// zoom, no extra library) rather than reusing 3d-force-graph/Three.js --
// this view has nothing 3D about it, pulling in a WebGL stack for a flat
// diagram would be pure waste.
(function () {
  'use strict';

  var isOpen = false;
  var currentAnchor = null; // qualified_name string
  var anchorHistory = []; // previous anchors, for the back button -- named to avoid shadowing window.history
  var maxHops = 2;
  var searchDebounceHandle = null;
  var loadToken = 0; // guards against a slow fetch resolving after a newer one started

  var pan = { x: 40, y: 40 };
  var scale = 1;
  var isPanning = false;
  var panStart = null;

  var els = {};

  // document.documentElement.lang is kept current by app.js's setLanguage()
  // on every switch (see index.html's <html lang="en">, the default) --
  // reading it live here means no separate sync mechanism is needed beyond
  // the onLanguageChange() hook re-rendering already-visible text below.
  function lang() {
    return (document.documentElement.lang || 'en').startsWith('en') ? 'en' : 'es';
  }

  var TEXT = {
    title: { es: 'Diagrama de linaje', en: 'Lineage diagram' },
    hops: { es: 'Saltos', en: 'Hops' },
    back: { es: '← Volver', en: '← Back' },
    fit: { es: 'Encajar', en: 'Fit' },
    searchPlaceholder: { es: 'Buscar un item para empezar…', en: 'Search for an item to start…' },
    loading: { es: 'Cargando linaje…', en: 'Loading lineage…' },
    loadError: { es: 'No se pudo cargar. Inténtalo de nuevo.', en: 'Could not load. Try again.' },
    empty: { es: 'Busca un item arriba a la izquierda para ver su diagrama de linaje.', en: 'Search for an item on the top left to see its lineage diagram.' },
    ambiguous: { es: 'Hay varios items con ese nombre -- elige uno:', en: 'Several items match that name -- pick one:' },
    notFound: { es: 'No se encontró ningún item con ese nombre.', en: 'No item matched that name.' },
    noRelations: { es: 'Este item no tiene dependencias directas registradas en ese número de saltos.', en: "This item has no dependencies recorded within that many hops." },
  };

  function text(key) {
    return (TEXT[key] || {})[lang()] || key;
  }

  // Same "Workspace / Item Type / Item Name" convention documented across
  // this project's own qualified_name docstrings (e.g. get_item_lineage) --
  // parsed here rather than added as a new API field just for node color.
  function itemTypeFromQualifiedName(qualifiedName) {
    var parts = (qualifiedName || '').split(' / ');
    return parts.length >= 3 ? parts[1] : '';
  }

  function itemNameFromQualifiedName(qualifiedName) {
    var parts = (qualifiedName || '').split(' / ');
    return parts.length >= 3 ? parts.slice(2).join(' / ') : (qualifiedName || '');
  }

  function workspaceFromQualifiedName(qualifiedName) {
    var parts = (qualifiedName || '').split(' / ');
    return parts.length >= 1 ? parts[0] : '';
  }

  // Small, deliberately independent palette -- NOT imported from
  // graph-map.js's own NODE_TYPE_META (a closure-private variable there,
  // never exposed on window.GraphMap, and keyed by node_type strings from
  // the full graph JSON rather than the item_type segment parsed above,
  // which don't reliably match 1:1). A close, not identical, family of
  // colors is enough for this view's purpose.
  var TYPE_COLORS = {
    Notebook: '#2f6fed',
    DataPipeline: '#a855f7',
    SemanticModel: '#f59e0b',
    Report: '#ef4444',
    PaginatedReport: '#ef4444',
    Dashboard: '#ef4444',
    Lakehouse: '#0d9488',
    Warehouse: '#0d9488',
    Dataflow: '#22c55e',
    CopyJob: '#22c55e',
    Eventstream: '#06b6d4',
    KQLDatabase: '#06b6d4',
    KQLQueryset: '#06b6d4',
    KQLDashboard: '#06b6d4',
    Reflex: '#06b6d4',
    UserDataFunction: '#8b5cf6',
    VariableLibrary: '#94a3b8',
  };
  var DEFAULT_COLOR = '#6b7280';
  var ANCHOR_COLOR = '#111827';

  function colorForType(itemType) {
    return TYPE_COLORS[itemType] || DEFAULT_COLOR;
  }

  function truncate(str, max) {
    if (!str) return '';
    return str.length > max ? str.slice(0, max - 1) + '…' : str;
  }

  function otherMainSections() {
    return [
      document.querySelector('.modebar'),
      document.querySelector('.metrics'),
      document.getElementById('workspaceShell'),
    ].filter(Boolean);
  }

  function renderLabels() {
    if (els.title) els.title.textContent = text('title');
    if (els.hopsLabel) els.hopsLabel.textContent = text('hops');
    if (els.backButton) els.backButton.textContent = text('back');
    if (els.fitButton) els.fitButton.textContent = text('fit');
    if (els.searchInput) els.searchInput.placeholder = text('searchPlaceholder');
    if (els.buttonLabel) els.buttonLabel.textContent = lang() === 'es' ? 'Flujo' : 'Flow';
    if (els.button) els.button.title = text('title');
  }

  function showStatus(message) {
    if (!els.status) return;
    els.status.hidden = false;
    els.status.textContent = message;
  }

  function hideStatus() {
    if (els.status) els.status.hidden = true;
  }

  function clearSvg() {
    if (els.zoomGroup) els.zoomGroup.innerHTML = '';
  }

  function svgEl(tag, attrs) {
    var el = document.createElementNS('http://www.w3.org/2000/svg', tag);
    Object.keys(attrs || {}).forEach(function (key) {
      el.setAttribute(key, attrs[key]);
    });
    return el;
  }

  function applyTransform() {
    if (els.zoomGroup) {
      els.zoomGroup.setAttribute('transform', 'translate(' + pan.x + ',' + pan.y + ') scale(' + scale + ')');
    }
  }

  function resetView() {
    pan = { x: 40, y: 40 };
    scale = 1;
    applyTransform();
  }

  function fitToContent(layoutWidth, layoutHeight) {
    if (!els.canvas) return;
    var rect = els.canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0 || layoutWidth <= 0 || layoutHeight <= 0) return;
    var padding = 40;
    var fitScale = Math.min(
      (rect.width - padding * 2) / layoutWidth,
      (rect.height - padding * 2) / layoutHeight,
      1.3
    );
    scale = Math.max(0.1, fitScale);
    pan = {
      x: (rect.width - layoutWidth * scale) / 2,
      y: (rect.height - layoutHeight * scale) / 2,
    };
    applyTransform();
  }

  var NODE_WIDTH = 190;
  var NODE_HEIGHT = 52;

  function buildDagFromRelatedElements(result) {
    // result: {qualified_name, upstream: [...], downstream: [...]} -- see
    // catalog._get_related_elements. Upstream entries mean "this feeds
    // `via`" (dependency convention documented there), so their edge is
    // drawn qualified_name -> via; downstream entries mean "`via` feeds
    // this", edge via -> qualified_name. Both conventions read left-to-
    // right as "data flows this way" once laid out with rankdir LR.
    var nodesById = {};
    var edges = [];
    var anchor = result.qualified_name;
    nodesById[anchor] = { id: anchor, hops: 0 };

    (result.upstream || []).forEach(function (entry) {
      if (!nodesById[entry.qualified_name]) nodesById[entry.qualified_name] = { id: entry.qualified_name, hops: entry.hops };
      edges.push({ source: entry.qualified_name, target: entry.via, relationship_type: entry.relationship_type, confidence: entry.confidence });
    });
    (result.downstream || []).forEach(function (entry) {
      if (!nodesById[entry.qualified_name]) nodesById[entry.qualified_name] = { id: entry.qualified_name, hops: entry.hops };
      edges.push({ source: entry.via, target: entry.qualified_name, relationship_type: entry.relationship_type, confidence: entry.confidence });
    });

    return { anchor: anchor, nodes: Object.keys(nodesById).map(function (id) { return nodesById[id]; }), edges: edges };
  }

  function renderDag(dag) {
    clearSvg();
    if (dag.nodes.length <= 1) {
      showStatus(text('noRelations'));
      return;
    }
    hideStatus();

    var g = new window.dagre.graphlib.Graph();
    g.setGraph({ rankdir: 'LR', nodesep: 28, ranksep: 90, marginx: 0, marginy: 0 });
    g.setDefaultEdgeLabel(function () { return {}; });
    dag.nodes.forEach(function (node) {
      g.setNode(node.id, { width: NODE_WIDTH, height: NODE_HEIGHT });
    });
    dag.edges.forEach(function (edge) {
      // Two items can be linked by more than one relationship_type --
      // dagre.setEdge with the same (v, w) and no name overwrites the
      // previous one, which is fine here: this view draws connectivity,
      // not a full multigraph, and graph-map.js's own edge de-dup on the
      // 3D side already establishes that "one visible edge per pair" is
      // an acceptable simplification in this project.
      g.setEdge(edge.source, edge.target);
    });
    window.dagre.layout(g);

    var layout = g.graph();
    dag.nodes.forEach(function (node) {
      var pos = g.node(node.id);
      var isAnchor = node.id === dag.anchor;
      var itemType = itemTypeFromQualifiedName(node.id);
      var group = svgEl('g', {
        class: 'dag-node' + (isAnchor ? ' dag-node-anchor' : ''),
        transform: 'translate(' + (pos.x - NODE_WIDTH / 2) + ',' + (pos.y - NODE_HEIGHT / 2) + ')',
        tabindex: '0',
        role: 'button',
      });
      group.dataset.qualifiedName = node.id;
      var rect = svgEl('rect', {
        width: NODE_WIDTH, height: NODE_HEIGHT, rx: 8,
        class: 'dag-node-rect',
        style: 'fill:' + (isAnchor ? ANCHOR_COLOR : '#ffffff') + ';stroke:' + colorForType(itemType) + ';',
      });
      var accent = svgEl('rect', { width: 5, height: NODE_HEIGHT, rx: 2, class: 'dag-node-accent', style: 'fill:' + colorForType(itemType) + ';' });
      var title = svgEl('title', {});
      title.textContent = node.id;
      var nameText = svgEl('text', { x: 14, y: 21, class: 'dag-node-name' + (isAnchor ? ' dag-node-name-anchor' : '') });
      nameText.textContent = truncate(itemNameFromQualifiedName(node.id), 24);
      var subText = svgEl('text', { x: 14, y: 38, class: 'dag-node-sub' + (isAnchor ? ' dag-node-sub-anchor' : '') });
      subText.textContent = truncate([itemType, workspaceFromQualifiedName(node.id)].filter(Boolean).join(' · '), 30);
      group.appendChild(rect);
      group.appendChild(accent);
      group.appendChild(title);
      group.appendChild(nameText);
      group.appendChild(subText);
      group.addEventListener('click', function () { setAnchor(node.id, true); });
      group.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setAnchor(node.id, true); }
      });
      els.zoomGroup.appendChild(group);
    });

    g.edges().forEach(function (edgeId) {
      var edge = g.edge(edgeId);
      var points = edge.points || [];
      if (points.length < 2) return;
      var d = 'M ' + points[0].x + ' ' + points[0].y + ' ' +
        points.slice(1).map(function (p) { return 'L ' + p.x + ' ' + p.y; }).join(' ');
      var path = svgEl('path', { d: d, class: 'dag-edge', 'marker-end': 'url(#dagViewArrow)' });
      els.zoomGroup.insertBefore(path, els.zoomGroup.firstChild); // edges painted behind nodes
    });

    fitToContent(layout.width, layout.height);
  }

  function setAnchor(qualifiedName, pushHistory) {
    if (!qualifiedName) return;
    if (pushHistory && currentAnchor && currentAnchor !== qualifiedName) anchorHistory.push(currentAnchor);
    currentAnchor = qualifiedName;
    if (els.backButton) els.backButton.hidden = anchorHistory.length === 0;
    if (els.searchInput) els.searchInput.value = itemNameFromQualifiedName(qualifiedName);
    if (els.searchResults) els.searchResults.innerHTML = '';

    var token = ++loadToken;
    clearSvg();
    showStatus(text('loading'));
    var url = '/api/related-elements?qualified_name=' + encodeURIComponent(qualifiedName) + '&direction=both&max_hops=' + maxHops + '&limit=150';
    fetch(url)
      .then(function (response) { return response.json(); })
      .then(function (result) {
        if (token !== loadToken) return; // a newer request already superseded this one
        if (!result.found) {
          if (result.reason === 'ambiguous_query' && (result.candidates || []).length) {
            renderCandidates(result.candidates);
          } else {
            showStatus(text('notFound'));
          }
          return;
        }
        renderDag(buildDagFromRelatedElements(result));
      })
      .catch(function () {
        if (token !== loadToken) return;
        showStatus(text('loadError'));
      });
  }

  function renderCandidates(candidates) {
    clearSvg();
    showStatus(text('ambiguous'));
    if (!els.searchResults) return;
    els.searchResults.innerHTML = candidates.map(function (c, index) {
      return '<button type="button" class="graph-map-search-result" data-dag-candidate="' + index + '">' +
        escapeHtmlLocal(itemNameFromQualifiedName(c.qualified_name)) + ' <small>' + escapeHtmlLocal(c.item_type || '') + '</small></button>';
    }).join('');
    els.searchResults.querySelectorAll('[data-dag-candidate]').forEach(function (button, index) {
      button.addEventListener('click', function () { setAnchor(candidates[index].qualified_name, true); });
    });
  }

  function escapeHtmlLocal(value) {
    var div = document.createElement('div');
    div.textContent = value == null ? '' : String(value);
    return div.innerHTML;
  }

  function searchItems(query) {
    var trimmed = (query || '').trim();
    if (trimmed.length < 2) {
      if (els.searchResults) els.searchResults.innerHTML = '';
      return;
    }
    fetch('/api/items?query=' + encodeURIComponent(trimmed) + '&limit=12')
      .then(function (response) { return response.ok ? response.json() : { items: [] }; })
      .then(function (payload) {
        var items = payload.items || [];
        if (!els.searchResults) return;
        els.searchResults.innerHTML = items.map(function (item, index) {
          return '<button type="button" class="graph-map-search-result" data-dag-result="' + index + '">' +
            escapeHtmlLocal(item.item_name || itemNameFromQualifiedName(item.qualified_name)) +
            ' <small>' + escapeHtmlLocal(item.item_type || '') + '</small></button>';
        }).join('');
        els.searchResults.querySelectorAll('[data-dag-result]').forEach(function (button, index) {
          button.addEventListener('click', function () { setAnchor(items[index].qualified_name, true); });
        });
      })
      .catch(function () { /* best-effort, same as app.js's own qualified-name autocomplete */ });
  }

  function clearRevealClip() {
    if (!els.view) return;
    els.view.classList.remove('graph-map-view-reveal-in');
    els.view.style.clipPath = '';
    els.view.style.removeProperty('--reveal-x');
    els.view.style.removeProperty('--reveal-y');
  }

  function open(event) {
    if (isOpen) return;
    if (window.GraphMap) window.GraphMap.close(); // never both overlays at once, see index.html's own comment
    isOpen = true;
    otherMainSections().forEach(function (el) { el.hidden = true; });
    if (els.backdrop) els.backdrop.hidden = false;
    els.view.hidden = false;

    els.view.classList.remove('graph-map-view-reveal-in');
    clearRevealClip();
    var rect = els.view.getBoundingClientRect();
    var canReveal = event && typeof event.clientX === 'number' && rect.width > 0 && rect.height > 0;
    if (canReveal) {
      var originX = ((event.clientX - rect.left) / rect.width) * 100;
      var originY = ((event.clientY - rect.top) / rect.height) * 100;
      els.view.style.setProperty('--reveal-x', originX + '%');
      els.view.style.setProperty('--reveal-y', originY + '%');
      void els.view.offsetWidth;
      els.view.classList.add('graph-map-view-reveal-in');
      els.view.addEventListener('animationend', clearRevealClip, { once: true });
      setTimeout(clearRevealClip, 600);
    }
    if (els.button) els.button.setAttribute('aria-pressed', 'true');
    renderLabels();
    if (currentAnchor) {
      // Reopening after a previous close: the last diagram is still in the
      // DOM (close() never clears it) -- re-fit to it instead of resetting
      // to a blank origin, so reopening doesn't look like it lost its place.
      var box = els.zoomGroup && els.zoomGroup.getBBox ? els.zoomGroup.getBBox() : null;
      if (box && box.width > 0) fitToContent(box.width + box.x * 2, box.height + box.y * 2);
      else resetView();
    } else {
      showStatus(text('empty'));
      resetView();
    }
    if (els.searchInput) setTimeout(function () { els.searchInput.focus(); }, 50);
  }

  function close() {
    if (!isOpen) return;
    isOpen = false;
    clearRevealClip();
    els.view.hidden = true;
    if (els.backdrop) els.backdrop.hidden = true;
    otherMainSections().forEach(function (el) { el.hidden = false; });
    if (els.button) els.button.setAttribute('aria-pressed', 'false');
  }

  function toggle(event) {
    if (isOpen) close(); else open(event);
  }

  function onWheel(event) {
    event.preventDefault();
    var rect = els.canvas.getBoundingClientRect();
    var mouseX = event.clientX - rect.left;
    var mouseY = event.clientY - rect.top;
    var factor = event.deltaY < 0 ? 1.12 : 1 / 1.12;
    var newScale = Math.min(3, Math.max(0.15, scale * factor));
    // Zoom toward the cursor, not the canvas origin.
    pan.x = mouseX - ((mouseX - pan.x) / scale) * newScale;
    pan.y = mouseY - ((mouseY - pan.y) / scale) * newScale;
    scale = newScale;
    applyTransform();
  }

  function onPointerDown(event) {
    if (event.target.closest('.dag-node')) return; // let node clicks through, not a pan-start
    isPanning = true;
    panStart = { x: event.clientX - pan.x, y: event.clientY - pan.y };
    els.canvas.classList.add('dag-view-canvas-panning');
  }

  function onPointerMove(event) {
    if (!isPanning) return;
    pan = { x: event.clientX - panStart.x, y: event.clientY - panStart.y };
    applyTransform();
  }

  function onPointerUp() {
    isPanning = false;
    if (els.canvas) els.canvas.classList.remove('dag-view-canvas-panning');
  }

  function wireEvents() {
    els.button = document.getElementById('dagViewButton');
    els.buttonLabel = document.getElementById('dagViewButtonLabel');
    els.backdrop = document.getElementById('dagViewBackdrop');
    els.view = document.getElementById('dagView');
    els.title = document.getElementById('dagViewTitle');
    els.closeButton = document.getElementById('dagViewCloseButton');
    els.hopsLabel = document.getElementById('dagViewHopsLabel');
    els.hopsSelect = document.getElementById('dagViewHopsSelect');
    els.backButton = document.getElementById('dagViewBackButton');
    els.fitButton = document.getElementById('dagViewFitButton');
    els.searchInput = document.getElementById('dagViewSearchInput');
    els.searchResults = document.getElementById('dagViewSearchResults');
    els.canvas = document.getElementById('dagViewCanvas');
    els.status = document.getElementById('dagViewStatus');
    els.svg = document.getElementById('dagViewSvg');
    els.zoomGroup = document.getElementById('dagViewZoomGroup');

    if (!els.button || !els.view) return; // markup missing -- nothing to wire

    els.button.addEventListener('click', toggle);
    if (els.closeButton) els.closeButton.addEventListener('click', close);
    if (els.backdrop) els.backdrop.addEventListener('click', close);
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && isOpen) close();
    });

    if (els.searchInput) {
      els.searchInput.addEventListener('input', function () {
        if (searchDebounceHandle) clearTimeout(searchDebounceHandle);
        var value = els.searchInput.value;
        searchDebounceHandle = setTimeout(function () { searchItems(value); }, 220);
      });
    }

    if (els.hopsSelect) {
      els.hopsSelect.addEventListener('change', function () {
        maxHops = Number(els.hopsSelect.value) || 2;
        if (currentAnchor) setAnchor(currentAnchor, false);
      });
    }

    if (els.backButton) {
      els.backButton.addEventListener('click', function () {
        var previous = anchorHistory.pop();
        if (els.backButton) els.backButton.hidden = anchorHistory.length === 0;
        if (previous) setAnchor(previous, false);
      });
    }

    if (els.fitButton) {
      els.fitButton.addEventListener('click', function () {
        var box = els.zoomGroup.getBBox ? els.zoomGroup.getBBox() : null;
        if (box && box.width > 0) fitToContent(box.width + box.x * 2, box.height + box.y * 2);
        else resetView();
      });
    }

    if (els.canvas) {
      els.canvas.addEventListener('wheel', onWheel, { passive: false });
      els.canvas.addEventListener('mousedown', onPointerDown);
      window.addEventListener('mousemove', onPointerMove);
      window.addEventListener('mouseup', onPointerUp);
    }

    renderLabels();
  }

  function onLanguageChange() {
    renderLabels();
  }

  function onThemeChange() {
    // Pure CSS (dag-view.css reads the same theme tokens styles.css/
    // graph-map.css already define) -- nothing to do in JS.
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', wireEvents);
  } else {
    wireEvents();
  }

  window.DagView = {
    open: open,
    close: close,
    toggle: toggle,
    onLanguageChange: onLanguageChange,
    onThemeChange: onThemeChange,
  };
})();
