import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    // local dev: proxy /api/* to the backend services
    proxy: {
      '/api/products': 'http://localhost:8080',
      '/api/categories': 'http://localhost:8080',
      '/api/orders': 'http://localhost:7878',
    }
  }
})
