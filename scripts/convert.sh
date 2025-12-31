#!/bin/bash

# PotreeConverter with E57 support - Resilient conversion script
# Features:
#   - Checkpoint/resume: skips already completed steps
#   - Retry logic: retries failed PotreeConverter with backoff
#   - Graceful degradation: panoramas are preserved even if conversion fails
#   - Proper error handling with meaningful exit codes
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - Input file not found
#   3 - Output directory creation failed
#   4 - Panorama extraction failed (all images failed)
#   5 - E57 to LAS conversion failed
#   6 - PotreeConverter failed
#   7 - Permission error

set -o pipefail

INPUT_FILE="$1"
OUTPUT_DIR="${2:-/data/output}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"

# Exit codes
EXIT_SUCCESS=0
EXIT_INVALID_ARGS=1
EXIT_INPUT_NOT_FOUND=2
EXIT_OUTPUT_DIR_FAILED=3
EXIT_PANORAMA_FAILED=4
EXIT_E57_LAS_FAILED=5
EXIT_POTREE_FAILED=6
EXIT_PERMISSION_ERROR=7

# Color output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

if [ -z "$INPUT_FILE" ]; then
    echo "Usage: convert.sh <input_file> [output_dir]"
    echo ""
    echo "Supported input formats: .e57, .las, .laz"
    echo ""
    echo "Environment variables:"
    echo "  MAX_RETRIES   - Number of retry attempts for PotreeConverter (default: 3)"
    echo "  RETRY_DELAY   - Delay between retries in seconds (default: 5)"
    echo "  FORCE_RESTART - Set to 'true' to ignore checkpoints and restart from scratch"
    echo ""
    echo "For proper file permissions when running in Docker, use:"
    echo "  docker run --rm --user \$(id -u):\$(id -g) -v /data:/data potree-converter convert.sh /data/input.e57 /data/output"
    echo ""
    echo "Exit codes:"
    echo "  0 - Success"
    echo "  1 - Invalid arguments"
    echo "  2 - Input file not found"
    echo "  3 - Output directory creation failed"
    echo "  4 - Panorama extraction failed (all images failed)"
    echo "  5 - E57 to LAS conversion failed"
    echo "  6 - PotreeConverter failed"
    echo "  7 - Permission error"
    exit $EXIT_INVALID_ARGS
fi

# Validate input file exists
if [ ! -f "$INPUT_FILE" ]; then
    log_error "Input file not found: $INPUT_FILE"
    exit $EXIT_INPUT_NOT_FOUND
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASENAME=$(basename "$INPUT_FILE")
EXTENSION="${BASENAME##*.}"
NAME="${BASENAME%.*}"

# Create output directory with proper error handling
if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
    log_error "Failed to create output directory: $OUTPUT_DIR"
    log_error "Check permissions - you may need to run with --user \$(id -u):\$(id -g)"
    exit $EXIT_OUTPUT_DIR_FAILED
fi

# Test write permissions
if ! touch "$OUTPUT_DIR/.write_test" 2>/dev/null; then
    log_error "No write permission to output directory: $OUTPUT_DIR"
    log_error "Check permissions - you may need to run with --user \$(id -u):\$(id -g)"
    exit $EXIT_PERMISSION_ERROR
fi
rm -f "$OUTPUT_DIR/.write_test"

# Checkpoint directory for tracking progress
CHECKPOINT_DIR="${OUTPUT_DIR}/.checkpoints"
if ! mkdir -p "$CHECKPOINT_DIR" 2>/dev/null; then
    log_error "Failed to create checkpoint directory: $CHECKPOINT_DIR"
    exit $EXIT_OUTPUT_DIR_FAILED
fi

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
    if touch "$1" 2>/dev/null; then
        log_info "Checkpoint saved: $1"
    else
        log_warn "Failed to save checkpoint: $1"
    fi
}

# Function to clear checkpoints if FORCE_RESTART is set
if [ "$FORCE_RESTART" = "true" ]; then
    log_info "FORCE_RESTART is set - clearing all checkpoints..."
    rm -rf "$CHECKPOINT_DIR"
    mkdir -p "$CHECKPOINT_DIR"
fi

# ============================================================================
# STEP 1: Extract panoramic images from E57 (if applicable)
# ============================================================================
PANORAMA_EXTRACTED=false
if [ "${EXTENSION,,}" = "e57" ]; then
    if step_completed "$CHECKPOINT_PANORAMAS"; then
        log_info "Skipping panorama extraction (already completed)"
        PANORAMA_EXTRACTED=true
    else
        echo ""
        echo "========================================="
        echo "STEP 1: Extracting panoramic images from E57"
        echo "========================================="
        python3 "${SCRIPT_DIR}/extract_panoramic_images.py" --source "$INPUT_FILE" --output "$OUTPUT_DIR"
        PANO_RESULT=$?
        
        # Exit codes from extract_panoramic_images.py:
        #   0 - Success (at least one image extracted)
        #   1 - No images found in E57 file (not an error, just no panoramas)
        #   2 - Error opening or reading E57 file
        #   3 - Error writing output files (permission denied, disk full, etc.)
        #   4 - Invalid arguments or source file not found
        
        case $PANO_RESULT in
            0)
                log_info "Panorama extraction completed successfully"
                mark_completed "$CHECKPOINT_PANORAMAS"
                PANORAMA_EXTRACTED=true
                ;;
            1)
                log_info "No panoramic images found in E57 file (this is OK)"
                # Mark as completed since there's nothing to extract
                mark_completed "$CHECKPOINT_PANORAMAS"
                ;;
            2)
                log_error "Failed to read E57 file for panorama extraction"
                log_warn "Continuing with point cloud conversion..."
                # Don't mark checkpoint - allow retry
                ;;
            3)
                log_error "Failed to write panorama files (permission or disk error)"
                log_error "Check permissions - you may need to run with --user \$(id -u):\$(id -g)"
                # Don't mark checkpoint - this is a real error that should be retried
                ;;
            4)
                log_error "Invalid arguments for panorama extraction"
                # Don't mark checkpoint
                ;;
            *)
                log_error "Panorama extraction failed with unexpected code: $PANO_RESULT"
                log_warn "Continuing with point cloud conversion..."
                # Don't mark checkpoint
                ;;
        esac
    fi

    # ========================================================================
    # STEP 2: Convert E57 to LAS with bounding box repair
    # ========================================================================
    # Store LAS in output directory so it persists across container restarts
    INTERMEDIATE_LAS="${OUTPUT_DIR}/.intermediate/${NAME}.las"
    INTERMEDIATE_LAS_FIXED="${OUTPUT_DIR}/.intermediate/${NAME}_fixed.las"
    INTERMEDIATE_DIR="${OUTPUT_DIR}/.intermediate"
    
    if ! mkdir -p "$INTERMEDIATE_DIR" 2>/dev/null; then
        log_error "Failed to create intermediate directory: $INTERMEDIATE_DIR"
        exit $EXIT_OUTPUT_DIR_FAILED
    fi
    
    if step_completed "$CHECKPOINT_E57_LAS" && [ -f "$INTERMEDIATE_LAS" ]; then
        log_info "Skipping E57→LAS conversion (already completed)"
        LAS_FILE="$INTERMEDIATE_LAS"
    else
        echo ""
        echo "========================================="
        echo "STEP 2: Converting E57 to LAS"
        echo "========================================="
        
        # Try conversion with retry
        E57_RETRIES=3
        E57_SUCCESS=0
        E57_LAST_ERROR=""
        for ((i=1; i<=E57_RETRIES; i++)); do
            log_info "Attempt $i of $E57_RETRIES..."
            
            # Capture both stdout and stderr
            E57_OUTPUT=$(pdal translate "$INPUT_FILE" "$INTERMEDIATE_LAS" 2>&1)
            E57_RESULT=$?
            
            if [ $E57_RESULT -eq 0 ] && [ -f "$INTERMEDIATE_LAS" ]; then
                E57_SUCCESS=1
                break
            fi
            
            E57_LAST_ERROR="$E57_OUTPUT"
            log_warn "E57→LAS conversion failed (exit code: $E57_RESULT)"
            
            if [ $i -lt $E57_RETRIES ]; then
                log_info "Retrying in $RETRY_DELAY seconds..."
                sleep $RETRY_DELAY
            fi
        done
        
        if [ $E57_SUCCESS -eq 1 ]; then
            log_info "E57 converted to LAS: $INTERMEDIATE_LAS"
            
            # ================================================================
            # STEP 2b: Repair bounding box
            # ================================================================
            # E57 files often have incorrect bounding boxes that cause
            # PotreeConverter to fail. We use PDAL to recalculate the
            # bounding box from actual point data.
            echo ""
            log_info "Repairing LAS bounding box..."
            
            # Create a PDAL pipeline to recalculate bounds
            PIPELINE_JSON="${INTERMEDIATE_DIR}/repair_bounds.json"
            cat > "$PIPELINE_JSON" << 'PIPELINE_EOF'
{
    "pipeline": [
        {
            "type": "readers.las",
            "filename": "INPUT_FILE_PLACEHOLDER"
        },
        {
            "type": "filters.stats"
        },
        {
            "type": "writers.las",
            "filename": "OUTPUT_FILE_PLACEHOLDER",
            "forward": "all",
            "minor_version": 4,
            "dataformat_id": 6
        }
    ]
}
PIPELINE_EOF
            
            # Replace placeholders with actual paths
            sed -i "s|INPUT_FILE_PLACEHOLDER|${INTERMEDIATE_LAS}|g" "$PIPELINE_JSON"
            sed -i "s|OUTPUT_FILE_PLACEHOLDER|${INTERMEDIATE_LAS_FIXED}|g" "$PIPELINE_JSON"
            
            # Run PDAL pipeline to recalculate bounds
            REPAIR_OUTPUT=$(pdal pipeline "$PIPELINE_JSON" 2>&1)
            REPAIR_RESULT=$?
            
            if [ $REPAIR_RESULT -eq 0 ] && [ -f "$INTERMEDIATE_LAS_FIXED" ]; then
                # Replace original with fixed version
                mv "$INTERMEDIATE_LAS_FIXED" "$INTERMEDIATE_LAS"
                log_info "Bounding box repaired successfully"
            else
                log_warn "Bounding box repair failed, trying alternative method..."
                log_warn "PDAL output: $REPAIR_OUTPUT"
                
                # Alternative: Use pdal translate with filters.stats
                REPAIR_OUTPUT2=$(pdal translate "$INTERMEDIATE_LAS" "$INTERMEDIATE_LAS_FIXED" \
                    --filter filters.stats 2>&1)
                REPAIR_RESULT2=$?
                
                if [ $REPAIR_RESULT2 -eq 0 ] && [ -f "$INTERMEDIATE_LAS_FIXED" ]; then
                    mv "$INTERMEDIATE_LAS_FIXED" "$INTERMEDIATE_LAS"
                    log_info "Bounding box repaired with alternative method"
                else
                    log_warn "Bounding box repair failed, continuing with original file"
                    log_warn "PotreeConverter may fail if bounding box is invalid"
                fi
            fi
            
            # Clean up pipeline file
            rm -f "$PIPELINE_JSON"
            
            LAS_FILE="$INTERMEDIATE_LAS"
            mark_completed "$CHECKPOINT_E57_LAS"
        else
            log_error "E57 to LAS conversion failed after $E57_RETRIES attempts"
            if [ -n "$E57_LAST_ERROR" ]; then
                log_error "Last error: $E57_LAST_ERROR"
            fi
            
            if [ "$PANORAMA_EXTRACTED" = true ]; then
                log_info "Panoramic images were extracted to: $OUTPUT_DIR/panoramas/"
            fi
            
            exit $EXIT_E57_LAS_FAILED
        fi
    fi
fi

# ============================================================================
# STEP 3: Run PotreeConverter with retry logic
# ============================================================================
if step_completed "$CHECKPOINT_POTREE"; then
    log_info "Skipping PotreeConverter (already completed)"
    POTREE_RESULT=0
else
    echo ""
    echo "========================================="
    echo "STEP 3: Running PotreeConverter"
    echo "========================================="
    
    # Verify input file exists
    if [ ! -f "$LAS_FILE" ]; then
        log_error "LAS file not found: $LAS_FILE"
        exit $EXIT_E57_LAS_FAILED
    fi
    
    # Copy LAS to /tmp for faster I/O (container-local storage is much faster than mounted volumes)
    FAST_LAS="/tmp/${NAME}.las"
    if [ "$LAS_FILE" != "$FAST_LAS" ]; then
        log_info "Copying LAS file to fast storage for better performance..."
        if ! cp "$LAS_FILE" "$FAST_LAS" 2>/dev/null; then
            log_warn "Could not copy to fast storage, using original location"
        else
            log_info "Copied to: $FAST_LAS"
            LAS_FILE="$FAST_LAS"
        fi
    fi
    
    log_info "Input: $LAS_FILE"
    log_info "Output: $OUTPUT_DIR"
    log_info "Max retries: $MAX_RETRIES"
    echo ""

    # Check if PotreeConverter exists
    POTREE_BIN="/app/PotreeConverter/build/PotreeConverter"
    if [ ! -x "$POTREE_BIN" ]; then
        log_error "PotreeConverter not found or not executable: $POTREE_BIN"
        exit $EXIT_POTREE_FAILED
    fi

    POTREE_RESULT=1
    POTREE_LAST_ERROR=""
    
    for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
        log_info "--- Attempt $attempt of $MAX_RETRIES ---"
        
        # Clear any partial output from previous failed attempt
        # (but preserve panoramas and checkpoints)
        if [ $attempt -gt 1 ]; then
            rm -f "${OUTPUT_DIR}/metadata.json" "${OUTPUT_DIR}/octree.bin" "${OUTPUT_DIR}/hierarchy.bin" 2>/dev/null
        fi
        
        # Run PotreeConverter and capture output
        POTREE_OUTPUT=$("$POTREE_BIN" "$LAS_FILE" -o "$OUTPUT_DIR" 2>&1)
        POTREE_RESULT=$?
        
        if [ $POTREE_RESULT -eq 0 ]; then
            # Verify output files were created
            if [ -f "${OUTPUT_DIR}/metadata.json" ]; then
                mark_completed "$CHECKPOINT_POTREE"
                break
            else
                log_warn "PotreeConverter reported success but output files not found"
                POTREE_RESULT=1
            fi
        fi
        
        POTREE_LAST_ERROR="$POTREE_OUTPUT"
        
        # Check if it was an OOM kill (exit code 137)
        if [ $POTREE_RESULT -eq 137 ]; then
            echo ""
            log_error "PotreeConverter was killed (likely out of memory)"
            log_error "Current Docker memory may be insufficient for this file"
            echo ""
            echo "Solutions:"
            echo "  1. Increase Docker Desktop memory in Settings → Resources"
            echo "  2. Run with more memory: docker run --rm -m 32g --shm-size=2g ..."
            echo ""
        elif [ $POTREE_RESULT -eq 139 ]; then
            log_error "PotreeConverter crashed with segmentation fault"
        fi
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            WAIT_TIME=$((RETRY_DELAY * attempt))
            log_info "Retrying in $WAIT_TIME seconds..."
            sleep $WAIT_TIME
        fi
    done
    
    # Clean up fast storage copy
    if [ "$LAS_FILE" = "$FAST_LAS" ]; then
        rm -f "$FAST_LAS" 2>/dev/null
    fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "========================================="
echo "CONVERSION SUMMARY"
echo "========================================="

if [ $POTREE_RESULT -eq 0 ]; then
    echo -e "${GREEN}✓ Conversion complete!${NC}"
    echo ""
    echo "Output files:"
    ls -la "$OUTPUT_DIR"/*.json "$OUTPUT_DIR"/*.bin 2>/dev/null || echo "  (no potree files)"
    
    if [ -d "$OUTPUT_DIR/panoramas" ]; then
        PANO_COUNT=$(find "$OUTPUT_DIR/panoramas" -maxdepth 1 -name "*.jpg" -type f 2>/dev/null | wc -l)
        echo ""
        echo "Panoramic images: $PANO_COUNT files in $OUTPUT_DIR/panoramas/"
    fi
    
    # Clean up checkpoints and intermediate files on success
    rm -rf "$CHECKPOINT_DIR" 2>/dev/null
    rm -rf "${OUTPUT_DIR}/.intermediate" 2>/dev/null
    
    echo ""
    echo "To resume from a checkpoint (if needed): re-run the same command"
    echo "To start fresh: set FORCE_RESTART=true"
    
    exit $EXIT_SUCCESS
else
    echo -e "${RED}✗ PotreeConverter failed after $MAX_RETRIES attempts (exit code: $POTREE_RESULT)${NC}"
    echo ""
    
    if [ -n "$POTREE_LAST_ERROR" ]; then
        echo "Last error output:"
        echo "$POTREE_LAST_ERROR" | tail -20
        echo ""
    fi
    
    if [ -d "$OUTPUT_DIR/panoramas" ]; then
        PANO_COUNT=$(find "$OUTPUT_DIR/panoramas" -maxdepth 1 -name "*.jpg" -type f 2>/dev/null | wc -l)
        if [ "$PANO_COUNT" -gt 0 ]; then
            echo -e "${GREEN}✓ Panoramic images were extracted: $PANO_COUNT files${NC}"
        fi
    fi
    
    echo ""
    echo "Checkpoints saved. To retry from where it failed:"
    echo "  - Just re-run the same command"
    echo "  - Completed steps will be skipped automatically"
    echo ""
    echo "To start completely fresh:"
    echo "  docker run --rm -e FORCE_RESTART=true --user \$(id -u):\$(id -g) -v /data:/data potree-converter convert.sh ..."
    echo ""
    echo "For large files, increase Docker memory:"
    echo "  - Docker Desktop: Settings → Resources → Memory"
    echo "  - Linux: docker run --rm -m 32g --shm-size=2g ..."
    
    exit $EXIT_POTREE_FAILED
fi