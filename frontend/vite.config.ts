import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    // Port 3008: avoids collision with portfolio dev (9090), nextjs (3004),
    // dashboard-frontend (3006), dashboard-backend (3007), serverless-frontend (3010).
    port: 3008,
    strictPort: true,
  },
});
