FROM node:20-alpine AS builder

WORKDIR /app

COPY package.json ./
RUN npm install

COPY . .
RUN npm run build

# Runtime: nginx serving the static build
FROM nginx:1.27-alpine

# non-root nginx
RUN addgroup -S appgroup && adduser -S appuser -G appgroup \
    && chown -R appuser:appgroup /var/cache/nginx /var/run /var/log/nginx \
    && touch /var/run/nginx.pid && chown appuser:appgroup /var/run/nginx.pid

COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

USER appuser

EXPOSE 80
