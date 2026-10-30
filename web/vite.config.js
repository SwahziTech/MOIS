import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

// each build gets its own service worker version, so a new deploy reaches the installed app
const stampServiceWorker = () => ({
  name: 'stamp-service-worker',
  apply: 'build',
  closeBundle() {
    const file = resolve('dist/sw.js')
    writeFileSync(file, readFileSync(file, 'utf8').replaceAll('__BUILD__', Date.now().toString(36)))
  },
})

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), stampServiceWorker()],
  // Dev port: PORT from the environment when set (e.g. a preview tool
  // assigning a free port), otherwise Vite's default 5173
  server: process.env.PORT ? { port: Number(process.env.PORT), strictPort: true } : undefined,
})
