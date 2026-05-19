FROM debian:bookworm-slim
ARG ZFS_EXPORTER_VERSION=2.3.10
# zfsutils-linux lives in `contrib` (OpenZFS is CDDL-licensed).
RUN sed -i 's/Components: main/Components: main contrib/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl zfsutils-linux \
 && curl -fsSL "https://github.com/pdf/zfs_exporter/releases/download/v${ZFS_EXPORTER_VERSION}/zfs_exporter-${ZFS_EXPORTER_VERSION}.linux-amd64.tar.gz" \
    | tar -xzC /tmp \
 && mv /tmp/zfs_exporter-*/zfs_exporter /usr/local/bin/zfs_exporter \
 && apt-get purge -y --auto-remove curl \
 && rm -rf /tmp/zfs_exporter-* /var/lib/apt/lists/*
USER nobody
EXPOSE 9134
ENTRYPOINT ["/usr/local/bin/zfs_exporter"]
