FROM node:18-slim AS base
WORKDIR /usr/src/app
RUN command -v yarn || npm install --global yarn
COPY package.json ./
ARG NODE_ENV
RUN yarn install --production=false

# Development Stage
FROM base AS development
EXPOSE 3000
CMD ["yarn", "run", "dev"]

# Production Stage
FROM base AS builder
COPY . .
RUN yarn run build

FROM caddy:2.8.4 AS production
WORKDIR /usr/share/caddy
COPY --from=builder /usr/src/app/dist /usr/share/caddy
COPY --link Caddyfile /etc/caddy/Caddyfile
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile"]

