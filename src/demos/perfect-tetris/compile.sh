#!/usr/bin/env bash
set -euo pipefail
# cd to dir of this script
cd $( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

zig build -Doptimize=ReleaseSmall -p ../../../public
