#!/usr/bin/env python3
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

import argparse
from pathlib import Path
import re
import struct


parser = argparse.ArgumentParser(description="Read a finished URMA diagnostic connection's checkpoints")
parser.add_argument("log", type=Path)
parser.add_argument("--port", type=int, help="Client source port on either node")
parser.add_argument("--tx-seq", type=int)
parser.add_argument("--rx-seq", type=int)
args = parser.parse_args()
log = args.log.read_text(errors="replace")
port = args.port
if port is None:
    failure = re.search(r"source_port=([1-9][0-9]*)", log)
    if failure:
        port = int(failure[1])

records = struct.Struct("=QQII")
ring = re.compile(r"URMA_TRACE_RING dir=(tx|rx) path=(\S+) on .*?addr=([^}\s]+)")
found = False
for direction, path, addr in ring.findall(log):
    if port is not None and str(port) not in addr.split(":")[-2:]:
        continue
    found = True
    seqs = {seq: (size, crc) for seq, size, crc, _ in records.iter_unpack(Path(path).read_bytes()) if seq}
    target = args.tx_seq if direction == "tx" else args.rx_seq
    if target is None and seqs:
        target = max(seqs)
    value = seqs.get(target)
    if value:
        print(f"dir={direction} seq={target} bytes={value[0]} crc={value[1]} addr={addr}")
    elif seqs:
        print(f"dir={direction} seq={target} missing range={min(seqs)}..{max(seqs)} addr={addr}")
    else:
        print(f"dir={direction} empty addr={addr}")
if not found:
    raise SystemExit("No matching rolling trace files in the log")
