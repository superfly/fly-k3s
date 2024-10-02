ARG BASE_IMAGE=ubuntu:22.04

FROM grafana/agent:v0.36.1 as grafana-agent
FROM docker.io/otel/opentelemetry-collector-contrib:0.83.0 as otel
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND="noninteractive"

RUN apt-get update; \
    apt-get install -yq --no-install-recommends --no-install-suggests \
    arptables ebtables iptables \
    bc \
    ca-certificates \
    ceph-common \
    coreutils \
    curl \
    dnsutils \
    gnupg \
    iperf3 \
    iproute2 \
    iptables \
    iputils-ping \
    jq \
    less \
    libcap-ng-utils \
    netcat \
    net-tools \
    nfs-common \
    nftables \
    nmap \
    open-iscsi \
    openresolv \
    procps \
    socat \
    systemd \
    systemd-timesyncd \
    tcpdump \
    traceroute \
    tzdata \
    vim \
    wget

# switching to legacy xt_tables because k3s does not support nftables
# https://docs.k3s.io/advanced#old-iptables-versions
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy; \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy; \
    update-alternatives --set arptables /usr/sbin/arptables-legacy; \
    update-alternatives --set ebtables /usr/sbin/ebtables-legacy

# disable selinux that comes bundled with ubuntu
RUN mkdir -p /etc/selinux; \
    echo "SELINUX=disabled" > /etc/selinux/config

# copy local files
ADD --chown=0:0 k3s/installer/install.sh /install_k3s.sh
ADD --chown=0:0 env/.bashrc /root/.bashrc

# copy the manifests
RUN mkdir -p /etc/kubernetes
COPY --chown=0:0 k3s/kubernetes/ /etc/kubernetes/

# add grafana agent
COPY --from=grafana-agent /bin/grafana-agent /usr/bin/grafana-agent
COPY /grafana-agent/grafana-agent.config /etc/default/grafana-agent
COPY /grafana-agent/grafana-agent.service /usr/lib/systemd/system/grafana-agent.service

# add opentelemetry
COPY --from=otel /otelcol-contrib /usr/bin/otelcol
COPY /opentelemetry/opentelemetry.config /etc/default/otelcol
COPY /opentelemetry/opentelemetry.service /usr/lib/systemd/system/otelcol.service

ADD k3s/entrypoint/run.sh /run.sh
CMD ["/run.sh"]