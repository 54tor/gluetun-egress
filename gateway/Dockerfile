FROM alpine:latest

RUN apk add --no-cache iproute2 nftables curl su-exec

COPY rules.nft /etc/gateway/rules.nft
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
