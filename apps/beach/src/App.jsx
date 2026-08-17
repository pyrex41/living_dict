import { onCleanup, onMount } from "solid-js";
import { createBeach } from "./beach.js";

export function App() {
  let host;
  onMount(() => {
    const world = createBeach(host);
    onCleanup(() => world.dispose());
  });
  return <div ref={host} style={{ width: "100%", height: "100%" }} />;
}
