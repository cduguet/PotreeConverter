# Dockerfile for PotreeConverter with E57 support
# This image builds PotreeConverter and includes PDAL for E57 to LAS conversion
# Features:
#   - E57 to Potree conversion via PDAL
#   - Automatic panoramic image extraction from E57 files
#   - Checkpoint/resume for resilient conversion
#   - Retry logic for handling transient failures

FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Default environment variables for resilient conversion
ENV MAX_RETRIES=3
ENV RETRY_DELAY=5
ENV FORCE_RESTART=false

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
    # Python for panorama extraction
    python3 \
    python3-pip \
    # Additional utilities
    && rm -rf /var/lib/apt/lists/*

# Install pye57 for panoramic image extraction from E57 files
RUN pip3 install pye57

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

# Copy helper scripts for converting E57 to LAS and then to Potree
RUN cp /app/PotreeConverter/scripts/convert.sh /usr/local/bin/convert.sh && \
    chmod +x /usr/local/bin/convert.sh && \
    cp /app/PotreeConverter/scripts/extract_panoramic_images.py /usr/local/bin/extract_panoramic_images.py && \
    chmod +x /usr/local/bin/extract_panoramic_images.py

# Set default working directory for data
WORKDIR /data

# Default command shows help
CMD ["bash", "-c", "cd /app/PotreeConverter/build && ./PotreeConverter --help"]