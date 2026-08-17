import OceanScene from './OceanScene';

export default function App() {
  return (
    <main class="landing">
      <OceanScene />
      <section class="hero">
        <p class="eyebrow">Tidefall</p>
        <h1>Where the ocean meets the beach</h1>
        <p class="lede">
          A photo-real landing page: three.js water, sky, and a sand shoreline
          under a SolidJS shell.
        </p>
        <a class="cta" href="#stay">Stay on the shore</a>
      </section>
    </main>
  );
}
