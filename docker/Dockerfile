# OpenTina unified build environment (Ubuntu 24.04), aligned with typical host deps
# (gcc-aarch64-linux-gnu, genimage, U-Boot host tools, etc.).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
	OPENTINA_IN_DOCKER=1

RUN apt-get update && apt-get install -y --no-install-recommends \
	bc bison build-essential bzip2 ca-certificates cpio curl \
	device-tree-compiler dosfstools fakeroot file flex g++-aarch64-linux-gnu \
	gcc-aarch64-linux-gnu genimage git libgnutls28-dev libssl-dev \
	make mtools patch perl python3 python3-dev python3-setuptools rsync \
	swig u-boot-tools unzip wget xz-utils \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
