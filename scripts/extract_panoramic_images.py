#!/usr/bin/env python3
"""
Extract panoramic images from E57 point cloud files.

This script extracts embedded spherical/panoramic images from E57 files
and saves them to a 'panoramas' subfolder along with their metadata.

Exit codes:
    0 - Success (at least one image extracted)
    1 - No images found in E57 file (not an error, just no panoramas)
    2 - Error opening or reading E57 file
    3 - Error writing output files (permission denied, disk full, etc.)
    4 - Invalid arguments or source file not found
"""

import os
import sys
import argparse
from pathlib import Path
import json
import gc
import traceback

try:
    import pye57
except ImportError as e:
    print(f"ERROR: Failed to import pye57: {e}", file=sys.stderr)
    print("Please install pye57: pip install pye57", file=sys.stderr)
    sys.exit(2)


# Exit codes
EXIT_SUCCESS = 0
EXIT_NO_IMAGES = 1
EXIT_E57_ERROR = 2
EXIT_WRITE_ERROR = 3
EXIT_INVALID_ARGS = 4


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


class ExtractionResult:
    """Result of panorama extraction operation."""
    def __init__(self):
        self.extracted_count = 0
        self.failed_count = 0
        self.total_count = 0
        self.errors = []
    
    @property
    def success(self):
        """Returns True if at least one image was successfully extracted."""
        return self.extracted_count > 0
    
    @property
    def partial_success(self):
        """Returns True if some images were extracted but some failed."""
        return self.extracted_count > 0 and self.failed_count > 0


def extract_panoramas(source: Path, output: Path) -> tuple[int, ExtractionResult]:
    """
    Extract panoramic images from an E57 file.
    
    Args:
        source: Path to the E57 file
        output: Output directory (panoramas will be saved to output/panoramas/)
    
    Returns:
        Tuple of (exit_code, ExtractionResult)
    """
    result = ExtractionResult()
    
    # Validate source file
    if not source.exists():
        print(f"ERROR: Source file does not exist: {source}", file=sys.stderr)
        return EXIT_INVALID_ARGS, result
    
    if not source.is_file():
        print(f"ERROR: Source path is not a file: {source}", file=sys.stderr)
        return EXIT_INVALID_ARGS, result

    # Create output directory with 'panoramas' subfolder
    panoramas_dir = output / "panoramas"
    try:
        panoramas_dir.mkdir(parents=True, exist_ok=True)
    except PermissionError as e:
        print(f"ERROR: Permission denied creating output directory: {panoramas_dir}", file=sys.stderr)
        print(f"Details: {e}", file=sys.stderr)
        return EXIT_WRITE_ERROR, result
    except OSError as e:
        print(f"ERROR: Failed to create output directory: {panoramas_dir}", file=sys.stderr)
        print(f"Details: {e}", file=sys.stderr)
        return EXIT_WRITE_ERROR, result

    # Open E57 file
    try:
        e57 = pye57.E57(source.as_posix())
    except Exception as e:
        print(f"ERROR: Failed to open E57 file: {source}", file=sys.stderr)
        print(f"Details: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return EXIT_E57_ERROR, result

    try:
        imf = e57.image_file
        root = imf.root()
    except Exception as e:
        print(f"ERROR: Failed to read E57 file structure: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return EXIT_E57_ERROR, result
    
    # Get images2D node
    try:
        images2D = pye57.utils.get_node(root, "images2D")
    except Exception as e:
        print(f"No images2D node found in E57 file: {e}")
        print("This E57 file does not contain panoramic images.")
        return EXIT_NO_IMAGES, result

    if images2D is None or len(images2D) == 0:
        print("No panoramic images found in E57 file.")
        return EXIT_NO_IMAGES, result

    images2D_meta_data = []
    result.total_count = len(images2D)
    
    print(f"Found {result.total_count} images in E57 file")
    
    for i in range(result.total_count):
        pct = (i + 1) * 100.0 / result.total_count
        print(f"Processing images {pct:6.2f}% ({i+1}/{result.total_count})", end="\r", flush=True)
        
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
                
                # Sanitize filename to avoid path traversal
                image_name = os.path.basename(image_name)

                try:
                    with open(panoramas_dir / image_name, "wb") as f:
                        f.write(bytes_data)
                    result.extracted_count += 1
                except PermissionError as e:
                    error_msg = f"Permission denied writing image {i}: {image_name}"
                    print(f"\nERROR: {error_msg}", file=sys.stderr)
                    result.errors.append(error_msg)
                    result.failed_count += 1
                except OSError as e:
                    error_msg = f"Failed to write image {i}: {image_name} - {e}"
                    print(f"\nERROR: {error_msg}", file=sys.stderr)
                    result.errors.append(error_msg)
                    result.failed_count += 1
                
                # Free memory immediately after writing to disk
                del bytes_data
            else:
                error_msg = f"Could not find JPEG image for image2D[{i}]"
                print(f"\nWarning: {error_msg}", file=sys.stderr)
                result.errors.append(error_msg)
                result.failed_count += 1
            
            # Clean up references to free memory
            del jpg, representation, image2D
                
        except Exception as e:
            error_msg = f"Failed to extract image {i}: {e}"
            print(f"\nERROR: {error_msg}", file=sys.stderr)
            result.errors.append(error_msg)
            result.failed_count += 1
            continue
        
        # Periodically force garbage collection to free memory
        if (i + 1) % 50 == 0:
            gc.collect()

    print()  # New line after progress indicator
    
    # Save metadata only if we extracted at least one image
    if result.extracted_count > 0 and images2D_meta_data:
        try:
            with open(panoramas_dir / "metadata.json", "w") as f:
                json.dump(images2D_meta_data, f, indent=4)
        except (PermissionError, OSError) as e:
            print(f"Warning: Failed to write metadata.json: {e}", file=sys.stderr)
            # Don't fail the whole operation for metadata

    # Print summary
    print(f"\nExtraction Summary:")
    print(f"  Total images found: {result.total_count}")
    print(f"  Successfully extracted: {result.extracted_count}")
    print(f"  Failed: {result.failed_count}")
    
    if result.extracted_count > 0:
        print(f"  Output directory: {panoramas_dir}")
    
    if result.errors:
        print(f"\nErrors encountered ({len(result.errors)}):", file=sys.stderr)
        for error in result.errors[:10]:  # Show first 10 errors
            print(f"  - {error}", file=sys.stderr)
        if len(result.errors) > 10:
            print(f"  ... and {len(result.errors) - 10} more errors", file=sys.stderr)
    
    # Determine exit code
    if result.extracted_count > 0:
        return EXIT_SUCCESS, result
    elif result.failed_count > 0:
        # Had images but all failed to extract
        return EXIT_WRITE_ERROR, result
    else:
        # No images found
        return EXIT_NO_IMAGES, result


def main():
    parser = argparse.ArgumentParser(
        description="Extract panoramic images from E57 files.",
        epilog="""
Exit codes:
  0 - Success (at least one image extracted)
  1 - No images found in E57 file (not an error, just no panoramas)
  2 - Error opening or reading E57 file
  3 - Error writing output files (permission denied, disk full, etc.)
  4 - Invalid arguments or source file not found
        """
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
    
    exit_code, result = extract_panoramas(args.source, args.output)
    
    # Print final status
    if exit_code == EXIT_SUCCESS:
        print(f"\n✓ Successfully extracted {result.extracted_count} panoramic images")
    elif exit_code == EXIT_NO_IMAGES:
        print("\n○ No panoramic images found in E57 file")
    else:
        print(f"\n✗ Extraction failed with exit code {exit_code}", file=sys.stderr)
    
    sys.exit(exit_code)


if __name__ == "__main__":
    main()