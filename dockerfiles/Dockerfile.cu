FROM oai-gnb:latest

#ENV USE_ADDITIONAL_OPTIONS "--sa -E --rfsim"

HEALTHCHECK --interval=10s --timeout=5s --retries=5 CMD pgrep nr-softmodem || exit 1
# Base commands to let the container be configured for Mininet integration
RUN apt update --fix-missing && apt upgrade -y && \
    apt-get install apt-utils net-tools iputils-ping -y && \
    apt-get install bash bash-completion ethtool -y && \
    apt-get  install iproute2 busybox-static iperf -y && \
    apt-get  install stress-ng curl tcpdump netcat-openbsd -y && \
    apt-get install  libssl-dev libsctp-dev telnet -y && \
    apt-get  clean && \
    rm -rf /var/lib/apt/lists/*

COPY ./dockerfiles/volumes/gnb-cu.sa.band78.106prb.conf /opt/oai-gnb/etc/gnb.conf

# Original CMD ["/opt/oai-gnb/bin/nr-softmodem" "-O" "/opt/oai-gnb/etc/gnb.conf","--sa", "-E", "--rfsim"]
ENTRYPOINT [""]
CMD ["sh", "-c", "sleep infinity"]
