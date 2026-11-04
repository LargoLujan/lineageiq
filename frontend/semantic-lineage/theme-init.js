// Applied before first paint to avoid a light-theme flash on load -- must
// stay synchronous in <head> (a deferred/async script would run after the
// first frame is already painted). Moved out of an inline <script> block
// in index.html so the server's Content-Security-Policy can
// use script-src 'self' without 'unsafe-inline'.
(function () {
  try {
    var stored = window.localStorage.getItem('fabric_lineage_theme');
    if (stored === 'light' || stored === 'dark') {
      document.documentElement.setAttribute('data-theme', stored);
    }
  } catch (e) {}
})();
