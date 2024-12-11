FROM node:18-slim AS base
WORKDIR /usr/src/app
RUN npm install --global yarn
COPY package.json yarn.lock ./
RUN yarn install

# Development Stage
FROM base AS development
ENV NODE_ENV=development
EXPOSE 3000
CMD ["yarn", "run", "dev"]

# Production Stage
FROM base AS builder
COPY ./src ./src
COPY ./public ./public
RUN yarn run build

FROM caddy:2.8.4 AS production
WORKDIR /usr/share/caddy
COPY --from=builder /usr/src/app/dist /usr/share/caddy
COPY Caddyfile /etc/caddy/Caddyfile
ENV NODE_ENV=production
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile"]

