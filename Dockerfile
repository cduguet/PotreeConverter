# Dockerfile for PotreeConverter with E57 support
# This image builds PotreeConverter and includes PDAL for E57 to LAS conversion

FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    libtbb-dev \
    wget \
    # PDAL for E57 to LAS conversion
    pdal \
    libpdal-dev \
    # Additional utilities
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /app

# Copy the PotreeConverter source code
COPY . /app/PotreeConverter

# Build PotreeConverter
WORKDIR /app/PotreeConverter
RUN mkdir -p build && cd build && \
    cmake .. && \
    make -j$(nproc)

# Create directories for input/output
RUN mkdir -p /data/input /data/output

# Create a symlink for PotreeConverter in /usr/local/bin
RUN ln -s /app/PotreeConverter/build/PotreeConverter /usr/local/bin/PotreeConverter

# Set default working directory for data
WORKDIR /data

# Default command shows help
CMD ["bash", "-c", "cd /app/PotreeConverter/build && ./PotreeConverter --help"]