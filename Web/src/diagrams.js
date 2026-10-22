import mermaid from 'mermaid';
import L from 'leaflet';
import { feature } from 'topojson-client';
import * as THREE from 'three';
import { STLLoader } from 'three/examples/jsm/loaders/STLLoader.js';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';

let serial = 0;
const cleanup = new Set();
window.madmdDisposeDiagrams = () => { for (const dispose of cleanup) dispose(); cleanup.clear(); };
window.madmdDiagrams = async (nodes, theme, current) => {
  window.madmdDisposeDiagrams();
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: theme === 'dark' ? 'dark' : 'default', suppressErrorRendering: true });
  for (const node of nodes) {
    if (!current()) return;
    const source = decodeURIComponent(node.dataset.source);
    try {
      if (node.dataset.kind === 'mermaid') {
        const result = await mermaid.render(`diagram-${++serial}`, source);
        if (current() && node.isConnected) { node.innerHTML = result.svg; result.bindFunctions?.(node); }
      } else if (['geojson', 'topojson'].includes(node.dataset.kind)) {
        let data = JSON.parse(source);
        if (node.dataset.kind === 'topojson') data = { type: 'FeatureCollection', features: Object.values(data.objects).flatMap(object => { const f = feature(data, object); return f.features ?? [f]; }) };
        node.replaceChildren(); node.classList.add('map');
        const map = L.map(node, { zoomControl: true, scrollWheelZoom: false, attributionControl: true });
        L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { attribution: '© OpenStreetMap', maxZoom: 19 }).addTo(map);
        const layer = L.geoJSON(data, { pointToLayer: (_, latlng) => L.circleMarker(latlng, { radius: 7 }) }).addTo(map);
        if (layer.getBounds().isValid()) map.fitBounds(layer.getBounds().pad(.15), { maxZoom: 13 }); else map.setView([0, 0], 1);
        cleanup.add(() => map.remove());
      } else {
        node.replaceChildren(); node.classList.add('model');
        const geometry = new STLLoader().parse(source); geometry.center(); geometry.computeBoundingSphere();
        const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(40, node.clientWidth / 360, .01, 10000);
        const radius = geometry.boundingSphere.radius || 1;
        camera.position.set(radius * 2, radius * 1.4, radius * 2.4); camera.lookAt(0, 0, 0);
        camera.near = radius / 100; camera.far = radius * 100; camera.updateProjectionMatrix();
        const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
        renderer.setPixelRatio(Math.min(devicePixelRatio, 2)); renderer.setSize(node.clientWidth, 360); node.append(renderer.domElement);
        const material = new THREE.MeshStandardMaterial({ color: 0x8b9bb0, roughness: .65 });
        scene.add(new THREE.Mesh(geometry, material)); scene.add(new THREE.HemisphereLight(0xffffff, 0x444444, 3));
        const light = new THREE.DirectionalLight(0xffffff, 3); light.position.set(2, 3, 4); scene.add(light);
        const controls = new OrbitControls(camera, renderer.domElement);
        const render = () => renderer.render(scene, camera); controls.addEventListener('change', render); render();
        const observer = new ResizeObserver(() => { if (!node.isConnected) return; camera.aspect = node.clientWidth / 360; camera.updateProjectionMatrix(); renderer.setSize(node.clientWidth, 360); render(); });
        observer.observe(node);
        cleanup.add(() => { observer.disconnect(); controls.dispose(); geometry.dispose(); material.dispose(); renderer.dispose(); });
      }
    } catch (error) {
      if (!current()) return;
      const message = document.createElement('div'); message.className = 'diagram-error'; message.textContent = String(error.message ?? error);
      node.append(message);
    }
  }
};
