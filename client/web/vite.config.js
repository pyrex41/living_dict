import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [svelte()],
  base: "./",
  build: {
    outDir: "../../openresty/public",
    emptyOutDir: true,
    assetsDir: "assets",
  },
  server: {
    port: 5173,
    proxy: {
      "/think": "http://127.0.0.1:8080",
      "/health": "http://127.0.0.1:8080",
    },
  },
});
