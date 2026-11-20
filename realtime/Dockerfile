# The realtime hub: the official Mercure image with Oliva's own Caddyfile (compat mode,
# bolt history cap, admin on localhost) and a startup guard for the publisher key.
# Pinned: a floating tag would change the Mercure/Caddy runtime without notice, and compat
# mode depends on THIS image's deprecated_* build tags (E-unbundle-roles, watch item).
FROM dunglas/mercure:v1.1.6

# The list of publicly known secrets is Oliva's (scripts/oliva/ since 1.12.0). It reaches this
# build through a named build context (compose build.additional_contexts / bake contexts),
# so there is one copy, not two (E-unbundle-roles, decided over duplicating it).
# `oliva` is a named build context, not a FROM alias — DL3022 is a false positive here.
# hadolint ignore=DL3022
COPY --from=oliva known-public-secrets.sha256 /usr/local/share/oliva/known-public-secrets.sha256

COPY Caddyfile /etc/caddy/Caddyfile
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/realtime-entrypoint

# The image has no entrypoint (its CMD is `caddy run …`). Wrap it so an empty, placeholder
# or publicly known key stops the hub instead of coming up without a real key. The image's
# own HEALTHCHECK (wget /mercure/health/ready on 127.0.0.1:2019) is inherited unchanged.
ENTRYPOINT ["realtime-entrypoint"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
