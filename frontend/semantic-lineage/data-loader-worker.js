// Downloads and parses the large lineage JSON payloads off the main thread.
// Without this, `fetch(...).then(r => r.json())` on the main thread blocks
// the tab (no scrolling, no clicks, no rendered feedback) for as long as the
// download + JSON.parse take -- multiple seconds on a colleague's home
// connection through the tunnel. Progress is reported per file so app.js can
// show real download percentages instead of a static "Loading..." label.
self.onmessage = async event => {
  const requests = (event.data && event.data.urls) || [];

  for (const request of requests) {
    const { key, url, required } = request;
    try {
      const response = await fetch(url);
      if (!response.ok) {
        if (required) throw new Error(`HTTP ${response.status} for ${url}`);
        self.postMessage({ type: 'data', key, data: null });
        continue;
      }

      // Prefer the decompressed size (see lineage_web_server.py) since
      // fetch()'s reader delivers decompressed bytes even though the raw
      // Content-Length header reflects the compressed size on the wire.
      const total = Number(response.headers.get('X-Uncompressed-Length')) ||
        Number(response.headers.get('Content-Length')) || 0;

      if (!response.body || !response.body.getReader) {
        // Streaming not supported (older browser) -- fall back to a single
        // await with no incremental progress, still off the main thread.
        const data = await response.json();
        self.postMessage({ type: 'data', key, data });
        continue;
      }

      const reader = response.body.getReader();
      const chunks = [];
      let loaded = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        loaded += value.length;
        self.postMessage({ type: 'progress', key, loaded, total });
      }

      self.postMessage({ type: 'parsing', key });
      const text = await new Blob(chunks).text();
      const data = JSON.parse(text);
      self.postMessage({ type: 'data', key, data });
    } catch (error) {
      if (required) {
        self.postMessage({ type: 'error', key, message: String((error && error.message) || error) });
        return;
      }
      self.postMessage({ type: 'data', key, data: null });
    }
  }

  self.postMessage({ type: 'complete' });
};
