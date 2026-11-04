// Bridges the ES-module Three.js build to a global for graph-map.js (a
// classic script) to consume via window.THREE -- see the comment in
// index.html for why a second, separate Three.js load is needed at all.
// Moved out of an inline <script type="module"> block so the
// server's Content-Security-Policy can use script-src 'self' without
// 'unsafe-inline'.
import * as THREE from './vendor/three.module.min.js';
window.THREE = THREE;
