# The edge gateway of an Oliva stack: one Caddy that routes /api, /health and
# /.well-known/mercure to the backend, and everything else to the frontend.
# Pinned to the same caddy tag as frontend/Dockerfile, so deps.sh reports one
# caddy, not two (see base_images in scripts/oliva/deps.sh).
FROM caddy:2.11.9

# CSP knob (decision 8 of E-unbundle-roles): one base policy lives in the
# Caddyfile below; dev adds 'unsafe-inline' to style-src via this env var. Empty
# in prod (this default). The dev overlay sets it to "'unsafe-inline'".
ENV GATEWAY_CSP_STYLE_EXTRA=

COPY Caddyfile /etc/caddy/Caddyfile
COPY app.d/ /etc/caddy/app.d/

# The caddy image is Alpine and ships wget, not curl. Hit /gateway-health
# (answered locally, never proxied), not /health (which proxies to the backend).
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=5s \
  CMD wget -q -O- http://localhost/gateway-health > /dev/null 2>&1 || exit 1
