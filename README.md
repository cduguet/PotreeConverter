
# About

PotreeConverter generates an octree LOD structure for streaming and real-time rendering of massive point clouds. The results can be viewed in web browsers with [Potree](https://github.com/potree/potree) or as a desktop application with [PotreeDesktop](https://github.com/potree/PotreeDesktop).

Version 2.0 is a complete rewrite with following differences over the previous version 1.7:

* About 10 to 50 times faster than PotreeConverter 1.7 on SSDs.
* Produces a total of 3 files instead of thousands to tens of millions of files. The reduction of the number of files improves file system operations such as copy, delete and upload to servers from hours and days to seconds and minutes.
* Better support for standard LAS attributes and arbitrary extra attributes. Full support (e.g. int64 and uint64) in development.
* Optional compression is not yet available in the new converter but on the roadmap for a future update.

Altough the converter made a major step to version 2.0, the format it produces is also supported by Potree 1.7. The Potree viewer is scheduled to make the major step to version 2.0 in 2021, with a rewrite in WebGPU.

# Docker Usage

A Docker image is provided for easy conversion of point clouds, including E57 files with panoramic images. The converter includes resilient features like checkpoint/resume and automatic retry logic.

## Building the Docker Image

```bash
docker build -t potree-converter .
```

## Quick Start (Recommended for Large Files)

For large E57 files (10GB+), use this command with memory and shared memory settings:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -m 24g \
  --shm-size=2g \
  -v /path/to/data:/data \
  potree-converter convert.sh /data/input.e57 /data/output
```

Or use the provided docker-compose file for even easier operation.

## File Permissions

By default, Docker containers run as root, which means output files will be owned by root and you may not be able to delete them without `sudo`. To ensure output files are owned by your user, use the `--user` flag:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v /path/to/data:/data \
  potree-converter convert.sh /data/input.e57 /data/output
```

This passes your current user ID and group ID to the container, so all created files will be owned by you.

**With docker-compose:**
```bash
docker compose run --rm --user "$(id -u):$(id -g)" potree convert.sh /data/input.e57 /data/output
```

## Converting Point Clouds

### Basic Usage (LAS/LAZ files)

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --shm-size=1g \
  -v /path/to/data:/data \
  potree-converter convert.sh /data/input.las /data/output
```

### Converting E57 Files with Panoramic Images

E57 files can contain embedded panoramic images. The converter will automatically extract these images to a `panoramas/` subfolder in the output directory.

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --shm-size=2g \
  -v /path/to/data:/data \
  potree-converter convert.sh /data/input.e57 /data/output
```

**Output structure:**
```
output/
├── metadata.json
├── octree.bin
├── hierarchy.bin
└── panoramas/
    ├── image_001.jpg
    ├── image_002.jpg
    ├── ...
    └── metadata.json  (contains pose, rotation, sensor info for each image)
```

### Resilient Conversion (Checkpoint/Resume)

The converter automatically saves checkpoints after completing each step. If conversion fails (e.g., due to memory limits), you can simply re-run the same command and it will **skip completed steps**.

**Steps that are checkpointed:**
1. Panoramic image extraction (from E57) - only checkpointed on success or when no images exist
2. E57 to LAS conversion
3. PotreeConverter processing

**Important:** Panorama extraction checkpoints are only created when:
- At least one image was successfully extracted, OR
- The E57 file contains no panoramic images (nothing to extract)

If panorama extraction fails due to errors (permission denied, disk full, etc.), the checkpoint is NOT created, allowing the step to be retried.

**Example: Resume after failure**
```bash
# First run - fails due to memory
docker run --rm --user "$(id -u):$(id -g)" -v /data:/data potree-converter convert.sh /data/large.e57 /data/output
# Output: "PotreeConverter failed... Checkpoints saved."

# Second run - skips panorama extraction and E57 conversion, retries PotreeConverter
docker run --rm --user "$(id -u):$(id -g)" -m 32g --shm-size=2g -v /data:/data potree-converter convert.sh /data/large.e57 /data/output
# Output: "[INFO] Skipping panorama extraction (already completed)"
#         "[INFO] Skipping E57→LAS conversion (already completed)"
#         "STEP 3: Running PotreeConverter..."
```

**Force restart from scratch:**
```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e FORCE_RESTART=true \
  -v /path/to/data:/data \
  potree-converter convert.sh /data/input.e57 /data/output
```

### Exit Codes

The converter uses specific exit codes to indicate different failure modes:

| Exit Code | Description |
|-----------|-------------|
| 0 | Success |
| 1 | Invalid arguments |
| 2 | Input file not found |
| 3 | Output directory creation failed |
| 4 | Panorama extraction failed (all images failed) |
| 5 | E57 to LAS conversion failed |
| 6 | PotreeConverter failed |
| 7 | Permission error |

These exit codes can be used in scripts to handle different failure scenarios appropriately.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_RETRIES` | 3 | Number of retry attempts for PotreeConverter |
| `RETRY_DELAY` | 5 | Delay between retries (seconds) |
| `FORCE_RESTART` | false | Set to `true` to ignore checkpoints |

Example with custom retry settings:
```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e MAX_RETRIES=5 \
  -e RETRY_DELAY=10 \
  -v /path/to/data:/data \
  potree-converter convert.sh /data/input.e57 /data/output
```

### Memory Requirements for Large Files

Large E57 files (10GB+) require significant memory for conversion. The PotreeConverter processes points in memory, so larger files need more RAM.

**Important:** On macOS and Windows, Docker Desktop has a memory limit that must be configured in Docker Desktop settings BEFORE running the container. The `-m` flag only sets an upper bound but cannot exceed Docker Desktop's configured limit.

**Recommended settings based on file size:**

| File Size | Memory (`-m`) | Shared Memory (`--shm-size`) |
|-----------|---------------|------------------------------|
| < 5 GB    | 8 GB          | 1 GB                         |
| 5-15 GB   | 16-24 GB      | 2 GB                         |
| 15-30 GB  | 32-48 GB      | 4 GB                         |
| > 30 GB   | 64+ GB        | 8 GB                         |

**Why shared memory (`--shm-size`) matters:**
- Default Docker shared memory is only 64MB
- PotreeConverter and PDAL use shared memory for inter-process communication
- Insufficient shared memory can cause crashes or performance issues

Example with full memory configuration:
```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -m 32g \
  --shm-size=4g \
  -v /path/to/data:/data \
  potree-converter convert.sh /data/input.e57 /data/output
```

### Extracting Only Panoramic Images

If you only need to extract panoramic images from an E57 file (without point cloud conversion):

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v /path/to/data:/data \
  potree-converter python3 /usr/local/bin/extract_panoramic_images.py \
    --source /data/input.e57 \
    --output /data/output
```

The panorama extractor has its own exit codes:
- `0` - Success (at least one image extracted)
- `1` - No images found in E57 file (not an error)
- `2` - Error opening or reading E57 file
- `3` - Error writing output files (permission denied, disk full, etc.)
- `4` - Invalid arguments or source file not found

### Direct PotreeConverter Usage

To use PotreeConverter directly with more options:

```bash
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --shm-size=2g \
  -v /path/to/data:/data \
  potree-converter PotreeConverter /data/input.las -o /data/output -m poisson
```

Available sampling methods:
- `poisson` (default): Poisson-disk sampling for even point distribution
- `random`: Random sampling

## Docker Compose (Recommended)

For convenience, you can use docker-compose with preconfigured settings:

```yaml
# docker-compose.yml
version: '3.8'
services:
  potree:
    build: .
    image: potree-converter
    shm_size: '4gb'
    volumes:
      - ./data:/data
    environment:
      - MAX_RETRIES=3
      - RETRY_DELAY=5
    deploy:
      resources:
        limits:
          memory: 32G
```

Run with (note the `--user` flag for proper file permissions):
```bash
docker compose run --rm --user "$(id -u):$(id -g)" potree convert.sh /data/input.e57 /data/output
```

## macOS Docker Desktop Memory Settings

On macOS, Docker Desktop has default memory limits. To increase memory:

1. Open Docker Desktop
2. Go to **Settings** (gear icon)
3. Select **Resources**
4. Adjust **Memory** slider to desired value (e.g., 24GB or more)
5. Click **Apply & Restart**

**Note:** On Apple Silicon Macs, you may need to allocate more memory than on Intel Macs due to architecture differences.

# Publications

* [Potree: Rendering Large Point Clouds in Web Browsers](https://www.cg.tuwien.ac.at/research/publications/2016/SCHUETZ-2016-POT/SCHUETZ-2016-POT-thesis.pdf)
* [Fast Out-of-Core Octree Generation for Massive Point Clouds](https://www.cg.tuwien.ac.at/research/publications/2020/SCHUETZ-2020-MPC/), _Schütz M., Ohrhallinger S., Wimmer M._

# Getting Started

1. Download windows binaries or
    * Download source code
	* Install [CMake](https://cmake.org/) 3.16 or later
	* Create and jump into folder "build"
	    ```
	    mkdir build
	    cd build
	    ```
	* run 
	    ```
	    cmake ../
	    ```
	* On linux, run: ```make```
	* On windows, open Visual Studio 2019 Project ./Converter/Converter.sln and compile it in release mode
2. run ```PotreeConverter.exe <input> -o <outputDir>```
    * Optionally specify the sampling strategy:
	* Poisson-disk sampling (default): ```PotreeConverter.exe <input> -o <outputDir> -m poisson```
	* Random sampling: ```PotreeConverter.exe <input> -o <outputDir> -m random```

In Potree, modify one of the examples with following load command:

```javascript
let url = "../pointclouds/D/temp/test/metadata.json";
Potree.loadPointCloud(url).then(e => {
	let pointcloud = e.pointcloud;
	let material = pointcloud.material;

	material.activeAttributeName = "rgba";
	material.minSize = 2;
	material.pointSizeType = Potree.PointSizeType.ADAPTIVE;

	viewer.scene.addPointCloud(pointcloud);
	viewer.fitToScreen();
});

```

# Alternatives

PotreeConverter 2.0 produces a very different format than previous iterations. If you find issues, you can still try previous converters or alternatives:

<table>
	<tr>
		<th></th>
		<th>PotreeConverter 2.0</th>
		<th><a href="https://github.com/potree/PotreeConverter/releases/tag/1.7">PotreeConverter 1.7</a></th>
		<th><a href="https://entwine.io/">Entwine</a></th>
	</tr>
	<tr>
		<th>license</th>
		<td>
			free, BSD 2-clause
		</td>
		<td>
			free, BSD 2-clause
		</td>
		<td>
			free, LGPL
		</td>
	</tr>
	<tr>
		<th>#generated files</th>
		<td>
			3 files total
		</td>
		<td>
			1 per node
		</td>
		<td>
			1 per node
		</td>
	</tr>
	<tr>
		<th>compression</th>
		<td>
			none (TODO)
		</td>
		<td>
			LAZ (optional)
		</td>
		<td>
			LAZ
		</td>
	</tr>
</table>

Performance comparison (Ryzen 2700, NVMe SSD):

![](./docs/images/performance_chart.png)

# License 

PotreeConverter is available under the [BSD 2-clause license](./LICENSE).