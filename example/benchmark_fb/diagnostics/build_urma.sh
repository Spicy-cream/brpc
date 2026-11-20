#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

if (( $# != 1 )); then
    echo "Usage: $0 <previous URMA benchmark checkout>" >&2
    exit 2
fi
previous=$(cd "$1" && pwd)
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
sys="$previous/build-system/CMakeCache.txt"
bench="$previous/build-bench/CMakeCache.txt"
cache() { sed -n "s/^$2:[^=]*=//p" "$1"; }

ui=$(cache "$sys" URMA_INCLUDE_PATH)
ub=$(cache "$sys" URMA_BOND_INCLUDE_PATH)
ul=$(cache "$sys" URMA_LIB)
fb=$(cache "$bench" FLATBUFFERS_INCLUDE_DIR)
fc=$(cache "$bench" FLATC_EXECUTABLE)
bfc=$(cache "$bench" BRPC_FLATC_EXECUTABLE)
for file in "$ui/urma_api.h" "$ub/urma_ubagg.h" "$ul" "$fb/flatbuffers/base.h" "$fc" "$bfc"; do
    if [[ ! -r $file ]]; then
        printf 'Missing dependency: %s\n' "$file" >&2
        exit 1
    fi
done
if [[ ! -x $fc || ! -x $bfc ]]; then
    echo 'flatc and brpc_flatc must be executable' >&2
    exit 1
fi
export LD_LIBRARY_PATH="$(dirname "$ul")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cd "$repo"
mkdir -p logs
log="logs/build-rolling-$(date +%Y%m%d-%H%M%S).log"
run() {
    "$@" >>"$log" 2>&1 || { tail -n 15 "$log"; echo "Build log $log"; exit 1; }
}
jobs=${BRPC_BUILD_JOBS:-4}
printf 'Revision %s\n' "$(git rev-parse HEAD)"
echo 'Building bRPC with the system URMA provider'
run cmake -S . -B build-system -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$repo/install-roll" -DCMAKE_INSTALL_LIBDIR=lib64 \
    -DWITH_URMA=ON -DURMA_USE_MOCK=OFF -DDOWNLOAD_URMA_HEADERS=OFF \
    -DWITH_FLATBUFFERS=ON -DBUILD_UNIT_TESTS=OFF -DBUILD_BRPC_TOOLS=OFF \
    -DURMA_INCLUDE_PATH="$ui" -DURMA_BOND_INCLUDE_PATH="$ub" \
    -DURMA_LIB="$ul" -DFLATBUFFERS_INCLUDE_DIR="$fb"
run cmake --build build-system --parallel "$jobs"
run cmake --install build-system

echo 'Building the rolling-trace benchmark'
run cmake -S example/benchmark_fb -B build-bench-roll -DCMAKE_BUILD_TYPE=Release \
    -DBRPC_ROOT="$repo/install-roll" -DBRPC_EXTRA_LIBRARIES="$ul" \
    -DFLATBUFFERS_INCLUDE_DIR="$fb" -DFLATC_EXECUTABLE="$fc" \
    -DBRPC_FLATC_EXECUTABLE="$bfc"
run cmake --build build-bench-roll --target benchmark_fb_server benchmark_fb_client --parallel "$jobs"
for bin in benchmark_fb_server benchmark_fb_client; do
    loaded=$(ldd "build-bench-roll/$bin" | awk '/liburma\.so/ && $2 == "=>" {print $3; exit}')
    if [[ ! "$loaded" -ef "$ul" ]]; then
        printf '%s did not load %s\n' "$bin" "$ul" >&2
        exit 1
    fi
    printf '%s liburma=%s\n' "$bin" "$loaded"
done
echo "Build complete. Log $log"
