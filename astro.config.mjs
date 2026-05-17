import { defineConfig } from "astro/config";

import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
    base: process.env["BASE_URL"] ?? "/",
    output: "static",
    security: {
        csp: {
            algorithm: "SHA-384",
        },
    },
    prefetch: {
        prefetchAll: true,
        defaultStrategy: "hover",
    },
    image: {
        responsiveStyles: true,
        layout: "constrained",
    },
    vite: {
        plugins: [tailwindcss()],
    },
});
