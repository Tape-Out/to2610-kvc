FROM ubuntu:24.04
RUN apt-get update && \
    apt-get install -y --no-install-recommends git build-essential device-tree-compiler cpio rsync file \
      wget unzip bc gawk python3 ca-certificates patch perl && \
    rm -rf /var/lib/apt/lists/*
