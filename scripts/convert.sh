#!/bin/bash

# PotreeConverter with E57 support - Resilient conversion script
# Features:
#   - Checkpoint/resume: skips already completed steps
#   - Retry logic: retries failed PotreeConverter with backoff
#   - Graceful degradation: panoramas are preserved even if conversion fails

INPUT_FILE="$1"
OUTPUT_DIR="${2:-/data/output}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

if [ -z "$INPUT_FILE" ]; then
    echo "Usage: convert.sh <input_file> [output_dir]"
    echo ""
    echo "Supported input formats: .e57, .las, .laz"
    echo ""
    echo "Environment variables:"
    echo "  MAX_RETRIES  - Number of retry attempts for PotreeConverter (default: 3)"
    echo "  RETRY_DELAY  - Delay between retries in seconds (default: 5)"
    echo "  FORCE_RESTART - Set to 'true' to ignore checkpoints and restart from scratch"
    echo ""
    echo "Example:"
    echo "  docker run --rm -v /data:/data potree-converter convert.sh /data/input.e57 /data/output"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASENAME=$(basename "$INPUT_FILE")
EXTENSION="${BASENAME##*.}"
NAME="${BASENAME%.*}"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Checkpoint directory for tracking progress
CHECKPOINT_DIR="${OUTPUT_DIR}/.checkpoints"
mkdir -p "$CHECKPOINT_DIR"

# Checkpoint file paths
CHECKPOINT_PANORAMAS="${CHECKPOINT_DIR}/panoramas_done"
CHECKPOINT_E57_LAS="${CHECKPOINT_DIR}/e57_to_las_done"
CHECKPOINT_POTREE="${CHECKPOINT_DIR}/potree_done"

# Store LAS file path (either original or converted from E57)
LAS_FILE="$INPUT_FILE"
TEMP_LAS=""

# Function to check if a step is completed
step_completed() {
    [ -f "$1" ]
}

# Function to mark a step as completed
mark_completed() {
    touch "$1"
    echo "✓ Checkpoint saved: $1"
}

# Function to clear checkpoints if FORCE_RESTART is set
if [ "$FORCE_RESTART" = "true" ]; then
    echo "FORCE_RESTART is set - clearing all checkpoints..."
    rm -rf "$CHECKPOINT_DIR"
    mkdir -p "$CHECKPOINT_DIR"
fi

# ============================================================================
# STEP 1: Extract panoramic images from E57 (if applicable)
# ============================================================================
if [ "${EXTENSION,,}" = "e57" ]; then
    if step_completed "$CHECKPOINT_PANORAMAS"; then
        echo "→ Skipping panorama extraction (already completed)"
    else
        echo ""
        echo "========================================="
        echo "STEP 1: Extracting panoramic images from E57"
        echo "========================================="
        python3 "${SCRIPT_DIR}/extract_panoramic_images.py" --source "$INPUT_FILE" --output "$OUTPUT_DIR"
        PANO_RESULT=$?
        if [ $PANO_RESULT -eq 0 ]; then
            mark_completed "$CHECKPOINT_PANORAMAS"
        else
            echo "Warning: Panorama extraction failed with code $PANO_RESULT"
            echo "Continuing with point cloud conversion..."
        fi
    fi

    # ========================================================================
    # STEP 2: Convert E57 to LAS
    # ========================================================================
    # Store LAS in output directory so it persists across container restarts
    INTERMEDIATE_LAS="${OUTPUT_DIR}/.intermediate/${NAME}.las"
    INTERMEDIATE_DIR="${OUTPUT_DIR}/.intermediate"
    mkdir -p "$INTERMEDIATE_DIR"
    
    if step_completed "$CHECKPOINT_E57_LAS" && [ -f "$INTERMEDIATE_LAS" ]; then
        echo "→ Skipping E57→LAS conversion (already completed)"
        LAS_FILE="$INTERMEDIATE_LAS"
    else
        echo ""
        echo "========================================="
        echo "STEP 2: Converting E57 to LAS"
        echo "========================================="
        
        # Try conversion with retry
        E57_RETRIES=3
        E57_SUCCESS=0
        for ((i=1; i<=E57_RETRIES; i++)); do
            echo "Attempt $i of $E57_RETRIES..."
            if pdal translate "$INPUT_FILE" "$INTERMEDIATE_LAS"; then
                E57_SUCCESS=1
                break
            fi
            echo "E57→LAS conversion failed, retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        done
        
        if [ $E57_SUCCESS -eq 1 ]; then
            LAS_FILE="$INTERMEDIATE_LAS"
            mark_completed "$CHECKPOINT_E57_LAS"
            echo "E57 converted to LAS: $INTERMEDIATE_LAS"
        else
            echo "ERROR: E57 to LAS conversion failed after $E57_RETRIES attempts."
            echo "Panoramic images may have been extracted to: $OUTPUT_DIR/panoramas/"
            exit 1
        fi
    fi
fi

# ============================================================================
# STEP 3: Run PotreeConverter with retry logic
# ============================================================================
if step_completed "$CHECKPOINT_POTREE"; then
    echo "→ Skipping PotreeConverter (already completed)"
    POTREE_RESULT=0
else
    echo ""
    echo "========================================="
    echo "STEP 3: Running PotreeConverter"
    echo "========================================="
    
    # Copy LAS to /tmp for faster I/O (container-local storage is much faster than mounted volumes)
    FAST_LAS="/tmp/${NAME}.las"
    if [ "$LAS_FILE" != "$FAST_LAS" ]; then
        echo "Copying LAS file to fast storage for better performance..."
        cp "$LAS_FILE" "$FAST_LAS"
        echo "Copied to: $FAST_LAS"
        LAS_FILE="$FAST_LAS"
    fi
    
    echo "Input: $LAS_FILE"
    echo "Output: $OUTPUT_DIR"
    echo "Max retries: $MAX_RETRIES"
    echo ""

    cd /app/PotreeConverter/build
    POTREE_RESULT=1
    
    for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
        echo "--- Attempt $attempt of $MAX_RETRIES ---"
        
        # Clear any partial output from previous failed attempt
        # (but preserve panoramas and checkpoints)
        if [ $attempt -gt 1 ]; then
            rm -f "${OUTPUT_DIR}/metadata.json" "${OUTPUT_DIR}/octree.bin" "${OUTPUT_DIR}/hierarchy.bin"
        fi
        
        ./PotreeConverter "$LAS_FILE" -o "$OUTPUT_DIR"
        POTREE_RESULT=$?
        
        if [ $POTREE_RESULT -eq 0 ]; then
            mark_completed "$CHECKPOINT_POTREE"
            break
        fi
        
        # Check if it was an OOM kill (exit code 137)
        if [ $POTREE_RESULT -eq 137 ]; then
            echo ""
            echo "ERROR: PotreeConverter was killed (likely out of memory)."
            echo "Current Docker memory may be insufficient for this file."
            echo ""
            echo "Solutions:"
            echo "  1. Increase Docker Desktop memory in Settings → Resources"
            echo "  2. Run with more memory: docker run --rm -m 32g --shm-size=2g ..."
            echo ""
        fi
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            WAIT_TIME=$((RETRY_DELAY * attempt))
            echo "Retrying in $WAIT_TIME seconds..."
            sleep $WAIT_TIME
        fi
    done
    
    # Clean up fast storage copy
    rm -f "$FAST_LAS" 2>/dev/null
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "========================================="
echo "CONVERSION SUMMARY"
echo "========================================="

if [ $POTREE_RESULT -eq 0 ]; then
    echo "✓ Conversion complete!"
    echo ""
    echo "Output files:"
    ls -la "$OUTPUT_DIR"/*.json "$OUTPUT_DIR"/*.bin 2>/dev/null || echo "  (no potree files)"
    
    if [ -d "$OUTPUT_DIR/panoramas" ]; then
        PANO_COUNT=$(ls -1 "$OUTPUT_DIR/panoramas"/*.jpg 2>/dev/null | wc -l)
        echo ""
        echo "Panoramic images: $PANO_COUNT files in $OUTPUT_DIR/panoramas/"
    fi
    
    # Clean up checkpoints and intermediate files on success
    rm -rf "$CHECKPOINT_DIR"
    rm -rf "${OUTPUT_DIR}/.intermediate"
    
    echo ""
    echo "To resume from a checkpoint (if needed): re-run the same command"
    echo "To start fresh: set FORCE_RESTART=true"
else
    echo "✗ PotreeConverter failed after $MAX_RETRIES attempts (exit code: $POTREE_RESULT)"
    echo ""
    
    if [ -d "$OUTPUT_DIR/panoramas" ]; then
        PANO_COUNT=$(ls -1 "$OUTPUT_DIR/panoramas"/*.jpg 2>/dev/null | wc -l)
        echo "✓ Panoramic images were extracted: $PANO_COUNT files"
    fi
    
    echo ""
    echo "Checkpoints saved. To retry from where it failed:"
    echo "  - Just re-run the same command"
    echo "  - Completed steps will be skipped automatically"
    echo ""
    echo "To start completely fresh:"
    echo "  docker run --rm -e FORCE_RESTART=true -v /data:/data potree-converter convert.sh ..."
    echo ""
    echo "For large files, increase Docker memory:"
    echo "  - Docker Desktop: Settings → Resources → Memory"
    echo "  - Linux: docker run --rm -m 32g --shm-size=2g ..."
    
    exit $POTREE_RESULT
fi