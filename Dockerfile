FROM hashicorp/vault:1.21.2

RUN apk add --no-cache bash curl jq

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY config/vault.hcl.template /opt/vault-bootstrap/vault.hcl.template
COPY policies /opt/vault-bootstrap/policies

RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8200 8201
VOLUME ["/vault/data", "/vault/file"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
