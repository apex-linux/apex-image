# Fedora's bootc base image, as documented in
# https://docs.fedoraproject.org/en-US/bootc/base-images/.
ARG BASE=quay.io/fedora/fedora-bootc:45
# How many CPUs the compiling stages use; scripts/build.sh sets it.
ARG CPUS=2

# Runs each component repository's `just install <destdir>` contract, into
# /out, and with the flavor argument into /out-<flavor>. The repositories are
# fetched by scripts/components.sh into build/components.
FROM ${BASE} AS components
LABEL org.opencontainers.image.source="https://github.com/apex-linux/apex-image"
RUN --mount=type=bind,source=image/common,target=/run/common \
    --mount=type=bind,source=image/components,target=/run/apex-components \
    /run/apex-components/install.sh tools
# The fetched commits: a new commit rebuilds the layer below.
ARG COMPONENTS=""
RUN --mount=type=bind,source=image/common,target=/run/common \
    --mount=type=bind,source=image/components,target=/run/apex-components \
    --mount=type=bind,source=build/components,target=/run/components \
    echo "Components: ${COMPONENTS}" \
    && /run/apex-components/install.sh install

# Fedora's libfprint, rebuilt with apex-hardware's patches for the ELAN
# 04f3:0c6e reader, or nothing if they no longer apply.
FROM ${BASE} AS libfprint
LABEL org.opencontainers.image.source="https://github.com/apex-linux/apex-image"
ARG CPUS
# A hash of the patch series: a change rebuilds the layer below.
ARG LIBFPRINT_PATCHES=""
RUN --mount=type=bind,source=image/common,target=/run/common \
    --mount=type=bind,source=image/libfprint,target=/run/libfprint \
    --mount=type=bind,source=build/components,target=/run/components \
    echo "%_smp_ncpus_max ${CPUS}" >/etc/rpm/macros.apex-cpus \
    && echo "Patches: ${LIBFPRINT_PATCHES}" \
    && /run/libfprint/build.sh

# The NVIDIA open kernel module for the base image's kernel.
FROM ${BASE} AS nvidia-kmod
LABEL org.opencontainers.image.source="https://github.com/apex-linux/apex-image"
ARG CPUS
# negativo17's repository metadata: a new driver rebuilds the layer below.
ARG NVIDIA_REPO=""
RUN --mount=type=bind,source=image/common,target=/run/common \
    --mount=type=bind,source=image/nvidia,target=/run/nvidia \
    echo "%_smp_ncpus_max ${CPUS}" >/etc/rpm/macros.apex-cpus \
    && echo "negativo17: ${NVIDIA_REPO}" \
    && /run/nvidia/kmod.sh

FROM ${BASE} AS apex

# Set first so that every layer carries it: `just clean` finds Apex's
# images, intermediate layers included, by this label.
LABEL org.opencontainers.image.source="https://github.com/apex-linux/apex-image" \
      org.opencontainers.image.title="Apex Linux" \
      containers.bootc="1"

# Only image/desktop is mounted: a change elsewhere keeps this slow layer
# cached.
RUN --mount=type=bind,source=image/common,target=/run/common \
    --mount=type=bind,source=image/desktop,target=/run/desktop \
    /run/desktop/install.sh

RUN --mount=type=bind,from=libfprint,source=/rpms,target=/run/libfprint-rpms \
    --mount=type=bind,source=image/libfprint,target=/run/libfprint \
    /run/libfprint/install.sh

# Components come after the desktop, so that a component change does not
# reinstall it.
COPY --from=components /out/ /
RUN --mount=type=bind,source=image/common,target=/run/common \
    --mount=type=bind,source=image/components,target=/run/apex-components \
    /run/apex-components/requires.sh \
    && /run/apex-components/post-install.sh

# Fingerprint in PAM, after fprintd-pam is certainly installed.
RUN --mount=type=bind,source=image/system,target=/run/system \
    /run/system/fingerprint.sh

# Apex Linux, a Fedora derivative, in os-release.
RUN --mount=type=bind,source=image/identity,target=/run/identity \
    /run/identity/os-release.sh

RUN bootc container lint

# The nvidia flavor: the base image plus the NVIDIA driver and the hardware
# files for it, for machines with an NVIDIA GPU.
FROM apex AS apex-nvidia
LABEL org.opencontainers.image.title="Apex Linux (NVIDIA)"
ARG NVIDIA_REPO=""
RUN --mount=type=bind,source=image/common,target=/run/common \
    --mount=type=bind,source=image/nvidia,target=/run/nvidia \
    --mount=type=bind,from=nvidia-kmod,source=/rpms,target=/run/kmod \
    echo "negativo17: ${NVIDIA_REPO}" \
    && /run/nvidia/install.sh
COPY --from=components /out-nvidia/ /
RUN --mount=type=bind,source=image/common,target=/run/common \
    --mount=type=bind,source=image/components,target=/run/apex-components \
    /run/apex-components/requires.sh \
    && /run/apex-components/post-install.sh
RUN bootc container lint
