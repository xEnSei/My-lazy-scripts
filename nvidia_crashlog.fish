#!/usr/bin/env fish

set timestamp (date '+%Y-%m-%d_%H-%M-%S')
set outdir "$HOME/crash_logs"
set outfile "$outdir/crash_$timestamp.txt"

mkdir -p $outdir

if not test -d $outdir
    echo "Error: Could not create folder: $outdir"
    exit 1
end

echo "=== Crash Analysis $timestamp ===" | tee $outfile
echo "" | tee -a $outfile

echo "[1] Full kernel log:" | tee -a $outfile
set link1 (journalctl -b -1 -k | paste-cachyos)
echo $link1 | tee -a $outfile
echo "" | tee -a $outfile

echo "[2] Nvidia/GPU filtered:" | tee -a $outfile
set link2 (journalctl -b -1 -k | grep -iE "nvrm|xid|nvidia|drm|error|hang|timeout|panic|fault|reset|gpu" | paste-cachyos)
echo $link2 | tee -a $outfile
echo "" | tee -a $outfile

echo "[3] Last 100 lines before crash:" | tee -a $outfile
set link3 (journalctl -b -1 -k | tail -100 | paste-cachyos)
echo $link3 | tee -a $outfile
echo "" | tee -a $outfile

echo "[4] AMD Reset reason:" | tee -a $outfile
journalctl -b -1 -k | grep -i "reset reason" | tee -a $outfile
echo "" | tee -a $outfile

echo "Saved: $outfile"
