# syntax=docker/dockerfile:1
FROM ghcr.io/gleam-lang/gleam:1.18.1-erlang-alpine AS build

WORKDIR /app
RUN apk add --no-cache sqlite-dev gcc musl-dev

COPY gleam.toml manifest.toml ./
COPY src src
RUN gleam export erlang-shipment

FROM erlang:27-alpine AS runtime

RUN apk add --no-cache sqlite-libs openssl \
  && adduser -D -u 10001 vectum \
  && mkdir -p /data /config \
  && chown -R vectum:vectum /data /config

WORKDIR /app
COPY --from=build /app/build/erlang-shipment /app
COPY examples/minimal.toml /config/router.toml

ENV VECTUM_CONFIG=/config/router.toml
USER vectum
EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
