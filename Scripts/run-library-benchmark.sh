#!/bin/zsh
set -euo pipefail

output_path="${1:-Build/Quality/ProductAudit-$(date +%Y%m%d)/library-benchmark.json}"
swift run -c release LensLibraryBenchmark "$output_path"
