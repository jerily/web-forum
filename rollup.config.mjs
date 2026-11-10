import fs from "node:fs";
import { nodeResolve } from "@rollup/plugin-node-resolve";

export default {
  input: "frontend/markdown-editor.js",
  output: { file: "assets/markdown-editor.bundle.js", format: "iife" },
  plugins: [
    nodeResolve({ browser: true, exportConditions: ["production"] }),
    {
      name: "svg-text",
      load(id) {
        if (id.endsWith(".svg")) {
          return `export default ${JSON.stringify(fs.readFileSync(id, "utf8"))};`;
        }
      },
    },
  ],
};
