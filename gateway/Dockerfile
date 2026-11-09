FROM alpine:latest

ARG VERSION=dev
ARG SOURCE=https://github.com/54tor/gluetun-egress
# Le label source lie le paquet GHCR au dépôt : sans lui, GITHUB_TOKEN reçoit « permission_denied: write_package ».
LABEL org.opencontainers.image.title="gluetun-egress-gateway" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.source="${SOURCE}" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache iproute2 nftables curl su-exec

COPY rules.nft /etc/gateway/rules.nft
COPY vpn-check.sh /usr/local/share/gateway/vpn-check.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
