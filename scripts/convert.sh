#!/bin/bash
set -e

INPUT_FILE="$1"
OUTPUT_DIR="${2:-/data/output}"

if [ -z "$INPUT_FILE" ]; then
    echo "Usage: convert.sh <input_file> [output_dir]"
    echo "Supported input formats: .e57, .las, .laz"
    exit 1
fi

BASENAME=$(basename "$INPUT_FILE")
EXTENSION="${BASENAME##*.}"
NAME="${BASENAME%.*}"

# If E57, convert to LAS first
if [ "${EXTENSION,,}" = "e57" ]; then
    echo "Converting E57 to LAS..."
    TEMP_LAS="/tmp/${NAME}.las"
    pdal translate "$INPUT_FILE" "$TEMP_LAS"
    INPUT_FILE="$TEMP_LAS"
    echo "E57 converted to LAS: $TEMP_LAS"
fi

# Run PotreeConverter from its build directory
echo "Running PotreeConverter..."
cd /app/PotreeConverter/build
./PotreeConverter "$INPUT_FILE" -o "$OUTPUT_DIR"

echo "Conversion complete! Output in: $OUTPUT_DIR"