import * as THREE from "three";

/** Placeholder scene. The planner should replace this with a photoreal ocean. */
export function createBeach(el) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x87b8d4);
  scene.fog = new THREE.Fog(0x87b8d4, 40, 280);

  const camera = new THREE.PerspectiveCamera(55, 1, 0.1, 2000);
  camera.position.set(0, 6, 28);
  camera.lookAt(0, 1, 0);

  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  el.appendChild(renderer.domElement);

  const sun = new THREE.DirectionalLight(0xfff1d0, 2.2);
  sun.position.set(-30, 40, 10);
  scene.add(sun);
  scene.add(new THREE.HemisphereLight(0x9ecbff, 0xc2a06a, 0.7));

  const sand = new THREE.Mesh(
    new THREE.PlaneGeometry(400, 400),
    new THREE.MeshStandardMaterial({ color: 0xd8c08a, roughness: 0.95 })
  );
  sand.rotation.x = -Math.PI / 2;
  scene.add(sand);

  const water = new THREE.Mesh(
    new THREE.PlaneGeometry(400, 220, 80, 40),
    new THREE.MeshStandardMaterial({
      color: 0x1a6a7a,
      roughness: 0.15,
      metalness: 0.35,
    })
  );
  water.rotation.x = -Math.PI / 2;
  water.position.set(0, 0.2, -90);
  scene.add(water);

  const clock = new THREE.Clock();
  let frame = 0;

  function resize() {
    const w = el.clientWidth || window.innerWidth;
    const h = el.clientHeight || window.innerHeight;
    camera.aspect = w / Math.max(h, 1);
    camera.updateProjectionMatrix();
    renderer.setSize(w, h, false);
  }
  resize();
  window.addEventListener("resize", resize);

  function tick() {
    frame = requestAnimationFrame(tick);
    const t = clock.getElapsedTime();
    camera.position.x = Math.sin(t * 0.08) * 4;
    renderer.render(scene, camera);
  }
  tick();

  return {
    dispose() {
      cancelAnimationFrame(frame);
      window.removeEventListener("resize", resize);
      renderer.dispose();
      if (renderer.domElement.parentNode) {
        renderer.domElement.parentNode.removeChild(renderer.domElement);
      }
    },
  };
}
