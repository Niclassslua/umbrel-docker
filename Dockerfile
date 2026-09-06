# syntax=docker/dockerfile:1

ARG YQ_VERSION=4.24.5
ARG NODE_VERSION=22.13.0
ARG DEBIAN_VERSION=bookworm
ARG RCLONE_VERSION=1.74.4

FROM node:${NODE_VERSION}-${DEBIAN_VERSION} AS source

ARG VERSION_ARG="0.0"
WORKDIR /repo
ADD https://github.com/getumbrel/umbrel.git#${VERSION_ARG} /repo
COPY ./scripts/patch-umbrel.js /tmp/patch-umbrel.js
RUN node /tmp/patch-umbrel.js /repo

# Install pnpm (for older umbrel tags that still use it in packages/ui)
RUN --mount=type=cache,target=/root/.npm \
    npm install -g pnpm@8

#########################################################################
# ui build stage
#########################################################################

FROM node:${NODE_VERSION}-${DEBIAN_VERSION} AS ui-build

# Set the working directory
WORKDIR /app

# Needed for tags using pnpm in packages/ui
RUN --mount=type=cache,target=/root/.npm \
    npm install -g pnpm@8

# Copy UI package and umbreld source paths used by different ui import styles.
COPY --from=source /repo/packages/ui/ .
COPY --from=source /repo/packages/umbreld/source /packages/umbreld/source
COPY --from=source /repo/packages/umbreld/source /umbreld/source

RUN rm -rf node_modules || true

# Install dependencies and build (pnpm for <=1.5.0, npm for master/newer)
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.local/share/pnpm/store \
    if [ -f pnpm-lock.yaml ]; then \
      pnpm install && pnpm run build; \
    elif [ -f package-lock.json ]; then \
      npm ci && npm run build; \
    else \
      npm install && npm run build; \
    fi

#########################################################################
# backend build stage
#########################################################################

FROM node:${NODE_VERSION}-${DEBIAN_VERSION} AS be-build

COPY --from=source /repo/packages/umbreld /opt/umbreld
COPY --from=ui-build /app/dist /opt/umbreld/ui
WORKDIR /opt/umbreld
RUN chmod +x /opt/umbreld/source/modules/apps/legacy-compat/app-script

# Install the dependencies
RUN rm -rf node_modules || true

# Build the app
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.cache/node-gyp \
    npm clean-install --omit dev && npm link

#########################################################################
# umbrelos build stage
#########################################################################

FROM debian:${DEBIAN_VERSION}-slim AS umbrelos
ENV NODE_ENV=production

# We need to duplicate this such that we can also use the argument below.
ARG TARGETARCH=amd64
ARG YQ_VERSION
ARG NODE_VERSION
ARG RCLONE_VERSION

ARG VERSION_ARG="0.0"
ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
  set -eu \
  && apt-get update -y \
  && apt-get --no-install-recommends -y install sudo iproute2 iputils-ping curl ca-certificates procps whois dbus avahi-daemon avahi-utils samba smbclient cifs-utils wsdd2 nftables \
  && apt-get --no-install-recommends -y install python3 jq rsync gettext-base gnupg openssl tini unzip imagemagick \
  && apt-get --no-install-recommends -y install qemu-system-x86 qemu-system-arm qemu-utils libvirt-daemon-system libvirt-clients dnsmasq-base swtpm swtpm-tools cloud-image-utils ovmf qemu-efi-aarch64 \
  && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
  && apt-get update -y \
  && apt-get --no-install-recommends -y install docker-ce-cli docker-compose-plugin \
  && rm -rf /tmp/* /var/tmp/* \
  && NODE_ARCH=$(dpkg --print-architecture | sed 's/amd64/x64/') \
  && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" -o node.tar.gz \
  && tar -xz -f node.tar.gz -C /usr/local --strip-components=1 \
  && rm -rf node.tar.gz \
  && curl -fsLo /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_$(dpkg --print-architecture)" \
  && chmod +x /usr/local/bin/yq \
  && RCLONE_ARCH=$(dpkg --print-architecture) \
  && curl -fsSL "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-${RCLONE_ARCH}.zip" -o rclone.zip \
  && unzip -j -o rclone.zip "*/rclone" -d /usr/local/bin \
  && chmod +x /usr/local/bin/rclone \
  && rm -rf rclone.zip \
  && echo "$VERSION_ARG" > /run/version \
  && addgroup --gid 1000 umbrel \
  && adduser --uid 1000 --gid 1000 --gecos "" --disabled-password umbrel \
  && echo "umbrel:umbrel" | chpasswd \
  && usermod -aG sudo umbrel \
  # libvirt's per-VM mount namespace, AppArmor labeling, and cgroup management
  # all fail inside a Docker container (masked/read-only /proc and /sys/fs/cgroup
  # paths, restricted namespace nesting). None of these are needed on top of the
  # container's own isolation, so disable them for the QEMU driver.
  && printf '%s\n' 'namespaces = []' 'security_driver = "none"' 'cgroup_controllers = []' >> /etc/libvirt/qemu.conf

# Install umbreld
COPY --chmod=755 ./entry.sh /run/
COPY --from=be-build --chmod=755 /opt/umbreld /opt/umbreld

VOLUME /data
EXPOSE 80 443 139 445 3702/tcp 3702/udp 5355/tcp 5355/udp

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
