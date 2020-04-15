# build
FROM crystallang/crystal:0.34.0-alpine-build as build

WORKDIR /build

COPY shard.yml /build/
COPY shard.lock /build/
RUN mkdir src
COPY ./src /build/src

RUN shards
RUN shards build carc --release --static

# prod
FROM alpine:3

WORKDIR /app
COPY ./.env.dist /app/.env
COPY --from=build /build/bin/carc /app/carc

CMD ["/app/carc"]
