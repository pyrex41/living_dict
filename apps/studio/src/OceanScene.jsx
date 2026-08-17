import { onCleanup, onMount } from 'solid-js';
import * as THREE from 'three';
import { Water } from 'three/examples/jsm/objects/Water.js';
import { Sky } from 'three/examples/jsm/objects/Sky.js';

export default function OceanScene() {
  let host;

  onMount(() => {
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(55, 1, 0.1, 20000);
    camera.position.set(0, 12, 48);

    const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 0.42;
    host.appendChild(renderer.domElement);

    const sun = new THREE.Vector3();

    const waterGeometry = new THREE.PlaneGeometry(10000, 10000);
    const water = new Water(waterGeometry, {
      textureWidth: 512,
      textureHeight: 512,
      waterNormals: new THREE.TextureLoader().load(
        'https://threejs.org/examples/textures/waternormals.jpg',
        (tex) => {
          tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
        }
      ),
      sunDirection: new THREE.Vector3(),
      sunColor: 0xffffff,
      waterColor: 0x001e0f,
      distortionScale: 3.7,
      fog: false,
    });
    water.rotation.x = -Math.PI / 2;
    scene.add(water);

    const sky = new Sky();
    sky.scale.setScalar(10000);
    scene.add(sky);
    const skyUniforms = sky.material.uniforms;
    skyUniforms['turbidity'].value = 8;
    skyUniforms['rayleigh'].value = 1.6;
    skyUniforms['mieCoefficient'].value = 0.005;
    skyUniforms['mieDirectionalG'].value = 0.8;

    const pmrem = new THREE.PMREMGenerator(renderer);
    const phi = THREE.MathUtils.degToRad(88);
    const theta = THREE.MathUtils.degToRad(180);
    sun.setFromSphericalCoords(1, phi, theta);
    sky.material.uniforms['sunPosition'].value.copy(sun);
    water.material.uniforms['sunDirection'].value.copy(sun).normalize();
    scene.environment = pmrem.fromScene(sky).texture;

    const sand = new THREE.Mesh(
      new THREE.PlaneGeometry(420, 180, 80, 40),
      new THREE.MeshStandardMaterial({
        color: 0xc4a574,
        roughness: 0.92,
        metalness: 0.02,
      })
    );
    const pos = sand.geometry.attributes.position;
    for (let i = 0; i < pos.count; i++) {
      const x = pos.getX(i);
      const y = pos.getY(i);
      pos.setZ(i, Math.sin(x * 0.04) * 1.4 + Math.cos(y * 0.08) * 0.6 + y * 0.08);
    }
    sand.geometry.computeVertexNormals();
    sand.rotation.x = -Math.PI / 2;
    sand.position.set(0, 0.4, 70);
    scene.add(sand);

    const foam = new THREE.Mesh(
      new THREE.PlaneGeometry(420, 18),
      new THREE.MeshStandardMaterial({
        color: 0xe8f0f4,
        transparent: true,
        opacity: 0.35,
        roughness: 1,
      })
    );
    foam.rotation.x = -Math.PI / 2;
    foam.position.set(0, 0.55, 8);
    scene.add(foam);

    const hemi = new THREE.HemisphereLight(0x87b5ff, 0xc4a574, 0.55);
    scene.add(hemi);
    const dir = new THREE.DirectionalLight(0xffe6c2, 1.4);
    dir.position.copy(sun).multiplyScalar(100);
    scene.add(dir);

    const resize = () => {
      const w = host.clientWidth || window.innerWidth;
      const h = host.clientHeight || window.innerHeight;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    };
    resize();
    window.addEventListener('resize', resize);

    let raf;
    const tick = () => {
      water.material.uniforms['time'].value += 1.0 / 60.0;
      camera.lookAt(0, 2, 0);
      renderer.render(scene, camera);
      raf = requestAnimationFrame(tick);
    };
    tick();

    onCleanup(() => {
      cancelAnimationFrame(raf);
      window.removeEventListener('resize', resize);
      renderer.dispose();
      host.removeChild(renderer.domElement);
    });
  });

  return <div class="ocean-canvas" ref={host} aria-label="photo-real ocean and beach" />;
}
