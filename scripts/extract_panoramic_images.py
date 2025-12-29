#!/usr/bin/env python3
"""
Extract panoramic images from E57 point cloud files.

This script extracts embedded spherical/panoramic images from E57 files
and saves them to a 'panoramas' subfolder along with their metadata.
"""

import os
import sys
import argparse
from pathlib import Path
import json
import gc

import pye57


def get_meta_from_node(node):
    """Recursively extract metadata from a pye57 node into a plain dict."""
    result = {}
    for field in pye57.utils.get_fields(node):
        child = node[field]
        try:
            if isinstance(child, pye57.libe57.BlobNode):
                # blobs are the images written separately
                continue
            elif hasattr(child, "value"):
                result[field] = child.value()
            elif isinstance(child, pye57.libe57.StructureNode):
                result[field] = get_meta_from_node(child)
        except Exception:
            # tolerate unexpected node behavior, store a string representation
            print(f"Warning: could not extract field '{field}', storing string representation.", file=sys.stderr)
            result[field] = str(child)
    return result


def extract_panoramas(source: Path, output: Path) -> int:
    """
    Extract panoramic images from an E57 file.
    
    Args:
        source: Path to the E57 file
        output: Output directory (panoramas will be saved to output/panoramas/)
    
    Returns:
        Number of images extracted
    """
    if not source.exists() or not source.is_file():
        print(f"Source file {source} does not exist or is not a file.", file=sys.stderr)
        return 0

    # Create output directory with 'panoramas' subfolder
    panoramas_dir = output / "panoramas"
    panoramas_dir.mkdir(parents=True, exist_ok=True)

    try:
        e57 = pye57.E57(source.as_posix())
    except Exception as e:
        print(f"Error opening E57 file: {e}", file=sys.stderr)
        return 0

    imf = e57.image_file
    root = imf.root()
    
    try:
        images2D = pye57.utils.get_node(root, "images2D")
    except Exception:
        print("No images2D node found in E57 file. No panoramic images to extract.")
        return 0

    if images2D is None or len(images2D) == 0:
        print("No panoramic images found in E57 file.")
        return 0

    images2D_meta_data = []
    total = len(images2D)
    extracted_count = 0
    
    for i in range(total):
        pct = (i + 1) * 100.0 / total
        print(f"Processing images {pct:6.2f}% ({i+1}/{total})", end="\r", flush=True)
        
        try:
            image2D = images2D[i]
            image2D_meta = get_meta_from_node(image2D)
            images2D_meta_data.append(image2D_meta)

            # Try to extract spherical representation (most common for panoramas)
            jpg = None
            representation = None
            if "sphericalRepresentation" in pye57.utils.get_fields(image2D):
                representation = image2D["sphericalRepresentation"]
                if "jpegImage" in pye57.utils.get_fields(representation):
                    jpg = representation["jpegImage"]
            
            # Fallback to other representations if spherical not found
            if jpg is None and "visualReferenceRepresentation" in pye57.utils.get_fields(image2D):
                representation = image2D["visualReferenceRepresentation"]
                if "jpegImage" in pye57.utils.get_fields(representation):
                    jpg = representation["jpegImage"]
            
            if jpg is None and "pinholeRepresentation" in pye57.utils.get_fields(image2D):
                representation = image2D["pinholeRepresentation"]
                if "jpegImage" in pye57.utils.get_fields(representation):
                    jpg = representation["jpegImage"]
            
            if jpg is not None:
                byteCount = jpg.byteCount()
                bytes_data = bytearray(byteCount)
                jpg.read(bytes_data, 0, byteCount)

                # Use name from metadata or generate one
                image_name = image2D_meta.get('name', f'image_{i:04d}.jpg')
                if not image_name.lower().endswith(('.jpg', '.jpeg')):
                    image_name += '.jpg'

                with open(panoramas_dir / image_name, "wb") as f:
                    f.write(bytes_data)
                extracted_count += 1
                
                # Free memory immediately after writing to disk
                del bytes_data
            else:
                print(f"\nWarning: Could not find JPEG image for image2D[{i}]", file=sys.stderr)
            
            # Clean up references to free memory
            del jpg, representation, image2D
                
        except Exception as e:
            print(f"\nWarning: Failed to extract image {i}: {e}", file=sys.stderr)
            continue
        
        # Periodically force garbage collection to free memory
        if (i + 1) % 50 == 0:
            gc.collect()

    print()  # New line after progress indicator
    
    # Save metadata
    if images2D_meta_data:
        with open(panoramas_dir / "metadata.json", "w") as f:
            json.dump(images2D_meta_data, f, indent=4)

    print(f"Extracted {extracted_count} images to '{panoramas_dir}'.")
    return extracted_count


def main():
    parser = argparse.ArgumentParser(
        description="Extract panoramic images from E57 files."
    )
    
    parser.add_argument(
        "--source",
        required=True,
        type=Path,
        help="Path to the source point cloud (E57).",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Directory where the extracted images will be written to (in 'panoramas' subfolder).",
    )

    args = parser.parse_args()
    
    count = extract_panoramas(args.source, args.output)
    sys.exit(0 if count >= 0 else 1)


if __name__ == "__main__":
    main()