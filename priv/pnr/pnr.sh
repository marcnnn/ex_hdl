#!/bin/sh
# Runs inside the exhdl-pnr image: place and route a yosys JSON netlist for
# xc7z020clg400-1, optionally write a bitstream.
#
#   pnr.sh WORKDIR FREQ_MHZ SEED BITSTREAM(0|1)
#
# Expects WORKDIR/top.json and WORKDIR/top.xdc, leaves nextpnr.log,
# top.fasm and (with BITSTREAM=1) top.frames and top.bit there.
set -e
dir=$1 freq=$2 seed=$3 bit=$4
part=xc7z020clg400-1
db=/opt/prjxray-db/zynq7

cd "$dir"
nextpnr-xilinx --chipdb /opt/chipdb/xc7z020.bin --xdc top.xdc --json top.json \
  --fasm top.fasm --freq "$freq" --seed "$seed" > nextpnr.log 2>&1 || {
  tail -40 nextpnr.log
  exit 1
}

if [ "$bit" = 1 ]; then
  PYTHONPATH=/opt/prjxray:/opt/prjxray/third_party/fasm /opt/venv/bin/python \
    /opt/prjxray/utils/fasm2frames.py --db-root "$db/$part/.." --part "$part" top.fasm > top.frames
  xc7frames2bit --part_file "$db/$part/part.yaml" --part_name "$part" \
    --frm_file top.frames --output_file top.bit
fi
