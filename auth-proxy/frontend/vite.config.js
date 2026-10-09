import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  // Namespaced so the built assets don't collide with KasmVNC's own "/assets/*"
  // paths once auth-proxy is proxying authenticated traffic through to it.
  base: "/_login/",
  build: {
    outDir: "dist",
  },
});
