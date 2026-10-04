# Fed by GoReleaser (dockers_v2), which supplies prebuilt binaries in a per-platform
# context such as linux/amd64/<BINARY_NAME>. NOT a standalone build target

FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

ARG TARGETPLATFORM

# Runs unprivileged. Nothing in the image needs root.
RUN apk add --no-cache ca-certificates \
    && adduser -D -H -u 65532 <BINARY_NAME>

COPY $TARGETPLATFORM/<BINARY_NAME> /usr/local/bin/<BINARY_NAME>

USER <BINARY_NAME>

ENTRYPOINT ["/usr/local/bin/<BINARY_NAME>"]
