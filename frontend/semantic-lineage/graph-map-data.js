// Graph Map Mode -- data layer.
//
// Deliberately separate from graph-map.js (rendering/interactions/state):
// this file's only job is fetching the pre-built graph indices
// backend/scripts/build_graph_map_index.py produces and handing back Cytoscape-ready
// elements, plus the object-level detail for one item on demand.
//
// Two files, not one -- data/graph-map-index.json (item level: workspaces +
// every Fabric item type, a few MB at most) is what the default view loads;
// data/graph-map-index-objects.json (table/view/column level, tens of MB
// on a large tenant) is an order of magnitude bigger and only fetched
// the first time a caller actually asks for one item's object-level detail
// -- see graph_map_index-objects.json's own `by_item_id` index, built
// server-side specifically so that lookup doesn't need a client-side scan
// over every edge.
(function () {
  'use strict';

  var itemGraphPromise = null;
  var objectGraphPromise = null;

  function fetchJson(path) {
    return fetch(path, { cache: 'no-store' }).then(function (response) {
      if (!response.ok) {
        throw new Error('No se pudo cargar ' + path + ' (HTTP ' + response.status + ')');
      }
      return response.json();
    });
  }

  window.GraphMapData = {
    /**
     * Resolves to { nodes, edges, summary } (Cytoscape element shape) for
     * the default, item-level graph. Fetched once and cached -- callers
     * don't need their own caching.
     */
    loadItemGraph: function () {
      if (!itemGraphPromise) {
        itemGraphPromise = fetchJson('./data/graph-map-index.json');
      }
      return itemGraphPromise;
    },

    /**
     * Resolves to { nodes, edges, by_item_id } for every source object
     * (table/view/stored procedure/file/etc.) and its edges into items.
     * Only fetch this when a caller actually needs object-level detail
     * (the focused graph) -- it's an order of magnitude bigger than the item graph.
     */
    loadObjectGraph: function () {
      if (!objectGraphPromise) {
        objectGraphPromise = fetchJson('./data/graph-map-index-objects.json');
      }
      return objectGraphPromise;
    },

    /**
     * Object-level nodes/edges touching one specific item, resolved via
     * loadObjectGraph()'s own by_item_id index -- O(1) lookup once the
     * (cached) object graph has loaded, not a re-scan per call.
     */
    getObjectEdgesForItem: function (itemQualifiedName) {
      return this.loadObjectGraph().then(function (objectGraph) {
        var edgeIndices = objectGraph.by_item_id[itemQualifiedName] || [];
        var edges = edgeIndices.map(function (index) {
          return objectGraph.edges[index];
        });
        var nodeIds = {};
        edges.forEach(function (edge) {
          nodeIds[edge.data.source] = true;
        });
        var nodes = objectGraph.nodes.filter(function (node) {
          return nodeIds[node.data.id];
        });
        return { nodes: nodes, edges: edges };
      });
    },

    /**
     * Build source->targets and target->sources adjacency maps from a list
     * of Cytoscape edge elements, once, so selection never has to
     * scan the full edge list per click -- it just walks these maps.
     * Returns { outgoing, incoming }, each nodeId -> [{ edgeId, nodeId }].
     */
    buildAdjacency: function (edges) {
      var outgoing = {};
      var incoming = {};
      edges.forEach(function (edge) {
        var edgeId = edge.data.id;
        var source = edge.data.source;
        var target = edge.data.target;
        (outgoing[source] = outgoing[source] || []).push({ edgeId: edgeId, nodeId: target });
        (incoming[target] = incoming[target] || []).push({ edgeId: edgeId, nodeId: source });
      });
      return { outgoing: outgoing, incoming: incoming };
    },

    /**
     * Every node/edge reachable from startId, transitively, following
     * either outgoing edges ("upstream" -- what this node depends on/reads
     * from/uses, i.e. its own sources) or incoming edges ("downstream" --
     * what depends on/reads from/uses this node, i.e. its consumers).
     * Every edge in this project's dependency data is recorded
     * from=consumer -> to=provider (verified live, e.g. "SQLEndpoint
     * depends_on Lakehouse" is stored as from=SQLEndpoint, to=Lakehouse --
     * the endpoint depends on the lakehouse, not the other way round), so
     * "what X depends on" is reached by following X's own outgoing edges,
     * not incoming ones. Bounded by the actual reachable subgraph, not the
     * whole graph, so it stays cheap even on a large adjacency map.
     */
    traverse: function (adjacency, startId, direction) {
      var linkMap = direction === 'upstream' ? adjacency.outgoing : adjacency.incoming;
      var visitedNodes = {};
      var visitedEdges = {};
      var queue = [startId];
      visitedNodes[startId] = true;
      while (queue.length) {
        var current = queue.shift();
        var links = linkMap[current] || [];
        for (var i = 0; i < links.length; i++) {
          visitedEdges[links[i].edgeId] = true;
          if (!visitedNodes[links[i].nodeId]) {
            visitedNodes[links[i].nodeId] = true;
            queue.push(links[i].nodeId);
          }
        }
      }
      delete visitedNodes[startId];
      return { nodes: Object.keys(visitedNodes), edges: Object.keys(visitedEdges) };
    },
  };
})();
