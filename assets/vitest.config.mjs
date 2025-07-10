import { defineConfig } from "vitest/config";

export default defineConfig({
  esbuild: { jsx: "automatic" },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./js/test-setup.js"],
    include: ["js/**/*.test.{js,jsx}"],
  },
});
