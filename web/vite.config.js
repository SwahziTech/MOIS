import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // Dev port: PORT from the environment when set (e.g. a preview tool
  // assigning a free port), otherwise Vite's default 5173
  server: process.env.PORT ? { port: Number(process.env.PORT), strictPort: true } : undefined,
})
