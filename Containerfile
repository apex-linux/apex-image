# Fedora's bootc base image, as documented in
# https://docs.fedoraproject.org/en-US/bootc/base-images/.
ARG BASE=quay.io/fedora/fedora-bootc:45
FROM ${BASE}

# Set first so that every layer carries it: `just clean` finds Apex's
# images, intermediate layers included, by this label.
LABEL org.opencontainers.image.source="https://github.com/apex-linux/apex-image" \
      org.opencontainers.image.title="Apex Linux" \
      containers.bootc="1"

RUN --mount=type=bind,source=image,target=/run/image /run/image/install.sh

RUN bootc container lint
