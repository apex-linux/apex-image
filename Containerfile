# Fedora's bootc base image, as documented in
# https://docs.fedoraproject.org/en-US/bootc/base-images/.
ARG BASE=quay.io/fedora/fedora-bootc:45

# Runs each component repository's `just install <destdir>` contract. The
# repositories are fetched by scripts/components.sh into build/components.
FROM ${BASE} AS components
LABEL org.opencontainers.image.source="https://github.com/apex-linux/apex-image"
RUN --mount=type=bind,source=image/components,target=/run/apex-components \
    /run/apex-components/install.sh tools
# The fetched commits: a new commit rebuilds the layer below.
ARG COMPONENTS=""
RUN --mount=type=bind,source=image/components,target=/run/apex-components \
    --mount=type=bind,source=build/components,target=/run/components \
    echo "Components: ${COMPONENTS}" \
    && /run/apex-components/install.sh install

FROM ${BASE}

# Set first so that every layer carries it: `just clean` finds Apex's
# images, intermediate layers included, by this label.
LABEL org.opencontainers.image.source="https://github.com/apex-linux/apex-image" \
      org.opencontainers.image.title="Apex Linux" \
      containers.bootc="1"

# Only image/desktop is mounted: a change elsewhere keeps this slow layer
# cached.
RUN --mount=type=bind,source=image/desktop,target=/run/desktop \
    /run/desktop/install.sh

# Components come last, so that a component change does not reinstall the
# desktop.
COPY --from=components /out/ /

# Apex Linux, a Fedora derivative, in os-release.
RUN --mount=type=bind,source=image/identity,target=/run/identity \
    /run/identity/os-release.sh

RUN bootc container lint
