#!/bin/bash

INPUT_FILE="$1"
OUTPUT_DIR="${2:-/data/output}"

if [ -z "$INPUT_FILE" ]; then
    echo "Usage: convert.sh <input_file> [output_dir]"
    echo "Supported input formats: .e57, .las, .laz"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASENAME=$(basename "$INPUT_FILE")
EXTENSION="${BASENAME##*.}"
NAME="${BASENAME%.*}"

# Store original E57 path for panorama extraction
ORIGINAL_E57=""
POTREE_RESULT=0

# If E57, extract panoramas first (before any heavy processing)
if [ "${EXTENSION,,}" = "e57" ]; then
    ORIGINAL_E57="$INPUT_FILE"
    
    # Extract panoramic images first (low memory operation)
    echo "Extracting panoramic images from E57..."
    python3 "${SCRIPT_DIR}/extract_panoramic_images.py" --source "$INPUT_FILE" --output "$OUTPUT_DIR"
    echo ""
    
    echo "Converting E57 to LAS..."
    TEMP_LAS="/tmp/${NAME}.las"
    pdal translate "$INPUT_FILE" "$TEMP_LAS"
    INPUT_FILE="$TEMP_LAS"
    echo "E57 converted to LAS: $TEMP_LAS"
fi

# Run PotreeConverter from its build directory
echo ""
echo "Running PotreeConverter..."
cd /app/PotreeConverter/build
./PotreeConverter "$INPUT_FILE" -o "$OUTPUT_DIR" || POTREE_RESULT=$?

echo ""
if [ $POTREE_RESULT -eq 0 ]; then
    echo "Conversion complete! Output in: $OUTPUT_DIR"
else
    echo "Warning: PotreeConverter exited with code $POTREE_RESULT"
    echo "Panoramic images were extracted successfully, but point cloud conversion may have failed."
    echo "For large files, try increasing Docker memory (see README.md)"
    exit $POTREE_RESULT
fi