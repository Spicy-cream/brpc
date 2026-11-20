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

if (( $# < 2 || $# > 4 )); then
    echo "Usage: $0 server|client <server IPv4> [URMA port] [TCP port]" >&2
    echo "       $0 server-tcp|client-tcp <server IPv4> [TCP port]" >&2
    exit 2
fi
role=$1
host=$2
urma_port=${3:-8931}
tcp_port=${4:-8932}
budget_minutes=57
case "$role" in
    server|client) ;;
    server-tcp|client-tcp)
        (( $# <= 3 )) || exit 2
        tcp_port=${3:-8933}
        budget_minutes=45
        ;;
    *) echo 'Choose server, client, server-tcp or client-tcp' >&2; exit 2 ;;
esac
server=build-bench-roll/benchmark_fb_server
client=build-bench-roll/benchmark_fb_client
if [[ ! -x $server || ! -x $client ]]; then
    echo 'Run from the bRPC checkout with build-bench-roll already built' >&2
    exit 1
fi

unset BRPC_FB_DIAG
out="logs/urma-perf-$role-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
echo "Log directory: $out"
git rev-parse HEAD >"$out/revision.txt"
urma=(--use_urma=true --urma_device="${BRPC_URMA_DEVICE:-bonding_dev_0}"
      --urma_bonding_mode=0 --urma_bonding_level=0 --urma_buffer_size=4096
      --urma_max_sge=1 --urma_use_polling=false --urma_recv_zerocopy=false
      --urma_trace_wr_limit=0 --urma_trace_rolling_dir=)

if [[ $role == server || $role == server-tcp ]]; then
    listen_filter="sport = :$tcp_port"
    if [[ $role == server ]]; then
        listen_filter+=" or sport = :$urma_port"
    fi
    if [[ -n $(ss -H -ltn "$listen_filter") ]]; then
        echo 'A benchmark port is already in use' >&2
        exit 1
    fi
    nohup "$server" --listen_addr="$host:$tcp_port" --allow_remote \
        --duration_s=5400 --v=0 --use_urma=false >"$out/tcp.log" 2>&1 </dev/null &
    pids=("$!")
    server_logs=("$out/tcp.log")
    if [[ $role == server ]]; then
        nohup "$server" --listen_addr="$host:$urma_port" --allow_remote \
            --duration_s=5400 --v=0 "${urma[@]}" >"$out/urma.log" 2>&1 </dev/null &
        pids+=("$!")
        server_logs+=("$out/urma.log")
    fi
    for attempt in {1..25}; do
        if [[ $(grep -l BRPC_FB_READY "${server_logs[@]}" | wc -l) -eq ${#server_logs[@]} ]]; then
            grep -h BRPC_FB_READY "${server_logs[@]}"
            exit 0
        fi
        if ! kill -0 "${pids[@]}" 2>/dev/null; then break; fi
        sleep 1
    done
    tail -n 6 "${server_logs[@]}"
    kill "${pids[@]}" 2>/dev/null || true
    exit 1
fi
deadline=$((SECONDS + budget_minutes * 60))
common=(--allow_remote --connection_type=single --thread_num=1 --attachment_size=0
        --timeout_ms=70000)
sizes=(32 64 256 1024 2048 4096 8192 16384 65536 262144 1048576 2097152 4194304 8388608)
printf 'mode\tbytes\tround\texit\tpath\n' >"$out/status.tsv"

run_case() {
    local mode=$1 bytes=$2 round=$3 port=$urma_port protocol=fb_rpc rc=0 path=urma_ok pid
    local file="$out/$mode-$bytes-r$round"
    local transport=("${urma[@]}")
    case "$mode" in
        *-pb) protocol=baidu_std ;;
    esac
    case "$mode" in
        tcp-*) port=$tcp_port; transport=(--use_urma=false); path=tcp ;;
    esac
    timeout -k 4s 80s "$client" --server="$host:$port" "${common[@]}" "${transport[@]}" \
        --protocol="$protocol" --request_size="$bytes" --warmup_s=5 --duration_s=20 --v=0 \
        >"$file.log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        ss -tin state established "dst $host:$port" || true
        sleep 2
    done >"$file.tcp"
    wait "$pid" || rc=$?

    if [[ $mode == urma-* ]]; then
        if ! grep -q 'URMA initialized' "$file.log" || ! awk -F'[[:space:]:]+' '
            {
                if (/bytes_sent:/ && /bytes_received:/) ++samples;
                for (i=1; i<NF; ++i)
                    if ($i ~ /^bytes_(sent|received)$/ && $(i+1)>256) bulk=1;
            }
            END { exit (bulk || samples<2) }
        ' "$file.tcp"; then
            path=unverified
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$mode" "$bytes" "$round" "$rc" "$path" >>"$out/status.tsv"
    if (( rc != 0 )) || [[ $path == unverified ]]; then
        printf '%s %s B r%s: exit=%s path=%s\n' "$mode" "$bytes" "$round" "$rc" "$path"
    fi
}

for round in 1 2 3; do
    case "$role:$round" in
        client:1) order=(urma-fb urma-pb tcp-fb) ;;
        client:2) order=(urma-pb tcp-fb urma-fb) ;;
        client:3) order=(tcp-fb urma-fb urma-pb) ;;
        client-tcp:2) order=(tcp-pb tcp-fb) ;;
        client-tcp:*) order=(tcp-fb tcp-pb) ;;
    esac
    for bytes in "${sizes[@]}"; do
        if [[ $role == client-tcp ]]; then
            order=("${order[1]}" "${order[0]}")
        fi
        for mode in "${order[@]}"; do
            (( deadline - SECONDS >= 87 )) || break 3
            run_case "$mode" "$bytes" "$round"
        done
        echo "Sweep $round/3, $bytes B complete"
    done
done

python3 - "$out" "$role" "${sizes[@]}" <<'PY'
import csv
import json
from pathlib import Path
from statistics import median
import sys

root = Path(sys.argv[1])
tcp_only = sys.argv[2] == "client-tcp"
candidate = "tcp-fb" if tcp_only else "urma-fb"
baselines = ("tcp-pb",) if tcp_only else ("urma-pb", "tcp-fb")
eligible = {}
with (root / "status.tsv").open() as status:
    for mode, size, round_id, rc, path in list(csv.reader(status, delimiter="\t"))[1:]:
        if rc != "0" or path != ("tcp" if mode.startswith("tcp-") else "urma_ok"):
            continue
        log = root / f"{mode}-{size}-r{round_id}.log"
        for line in log.read_text(errors="replace").splitlines():
            if not line.startswith('{"mode":"timed"'):
                continue
            row = json.loads(line)
            if (row["seconds"] >= 19.5 and row["requests"] > 0 and row["failures"] == 0
                    and row["thread_num"] == row["started_threads"] == 1):
                eligible[mode, size, round_id] = row

with (root / "benefit.tsv").open("w") as output:
    report = csv.writer(output, delimiter="\t", lineterminator="\n")
    fields = ("qps", "p50_us", "p99_us")
    absolute_columns = [f"{mode}_{field}" for field in fields
                        for mode in ("tcp-fb", "tcp-pb")] if tcp_only else []
    report.writerow(["bytes", "baseline", "pairs", "qps_change", "p50_reduction",
                     "p99_reduction", *absolute_columns])
    for size in sys.argv[3:]:
        for baseline in baselines:
            pairs = []
            for round_id in ("1", "2", "3"):
                new = eligible.get((candidate, size, round_id))
                control = eligible.get((baseline, size, round_id))
                if new and control:
                    pairs.append((new, control))
            changes = []
            for field, sign in (("qps", 1), ("p50_us", -1), ("p99_us", -1)):
                results = [sign * (new[field] / control[field] - 1) for new, control in pairs
                           if control[field] > 0]
                changes.append(f"{median(results):+.1%}" if results else "NA")
            absolute = []
            if tcp_only:
                absolute = [f"{median(pair[index][field] for pair in pairs):.1f}" if pairs else "NA"
                            for field in fields for index in (0, 1)]
            report.writerow([size, baseline, f"{len(pairs)}/3", *changes, *absolute])
print(f"{len(eligible)} usable runs. Report: {root / 'benefit.tsv'}")
PY
