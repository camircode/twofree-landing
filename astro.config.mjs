import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import { env } from "node:process";

export default defineConfig({
  integrations: [sitemap()],
  output: "static",
  site: env.PUBLIC_SITE_URL || "http://localhost:4321",
});
