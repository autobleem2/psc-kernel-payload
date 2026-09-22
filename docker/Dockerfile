# autobleem-kernel-build — extends the main autobleem-build image with the host
# tools Buildroot needs. Buildroot builds its OWN cross toolchain + glibc from
# source, so we only add generic host prerequisites here, not any cross compiler.
#
# Build on the server:  docker build -t autobleem-kernel-build -f docker/Dockerfile .
# (or just use the base autobleem-build image — build.sh works there too, this
#  image only guarantees every Buildroot host dependency is present.)
FROM autobleem-build

USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bc \
        bison \
        flex \
        cpio \
        rsync \
        unzip \
        file \
        wget \
        ca-certificates \
        git \
        make \
        gcc \
        g++ \
        patch \
        perl \
        gawk \
        diffutils \
        findutils \
        xxd \
        lz4 \
        u-boot-tools \
        libncurses-dev \
        python3 \
        ccache \
    && rm -rf /var/lib/apt/lists/*

# Buildroot must not run as root; docker/run.sh runs as the host uid:gid.
