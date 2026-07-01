#!/usr/bin/fish

# 1. Dependency Check
set required_tools nvidia-smi exiftool find sort tr
set missing_tools

for tool in $required_tools
    if not command -v $tool >/dev/null
        set -a missing_tools $tool
    end
end

if test -n "$missing_tools"
    set_color red
    echo "CRITICAL ERROR: Missing dependencies detected!"
    echo "The following tools are required but not found in your PATH:"
    set_color normal
    for tool in $missing_tools
        echo "  - $tool"
    end
    echo ""
    echo "Please install the missing packages using your distribution's package manager."
    exit 1
else
    set_color green
    echo "Dependency Check Passed: All tools found ($required_tools)"
    set_color normal
end

# 2. Hardware Detection
set gpu_info (nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>/dev/null)
set arch_detected "Unknown"
set min_recommended "3.7.0"

if echo $gpu_info | grep -q "RTX 50"
    set arch_detected "Blackwell (RTX 50-series)"
    set min_recommended "4.5.0"
else if echo $gpu_info | grep -q "RTX 40"
    set arch_detected "Ada Lovelace (RTX 40-series)"
    set min_recommended "3.7.10"
else if echo $gpu_info | grep -q "RTX 30"
    set arch_detected "Ampere (RTX 30-series)"
    set min_recommended "3.5.0"
else if echo $gpu_info | grep -q "RTX 20"
    set arch_detected "Turing (RTX 20-series)"
    set min_recommended "2.5.1"
end

# 3. Dynamic Path Discovery
set mounts (find /mnt /run/media -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
set search_paths $HOME $mounts

# 4. Output Header & Legend
echo "--------------------------------------------------------------------------------"
echo "GPU: $gpu_info"
echo "Architecture: $arch_detected"
echo "Target Baseline: $min_recommended (Optimal for your hardware)"
echo "--------------------------------------------------------------------------------"
set_color green;  echo "[GREEN]  = Optimal: Version meets or exceeds hardware baseline.";
set_color yellow; echo "[YELLOW] = Suboptimal: Upgrade to $min_recommended recommended.";
set_color red;    echo "[RED]    = Error: Metadata unreadable.";
set_color normal
echo "--------------------------------------------------------------------------------"
echo "This may take a while, especially when scanning HDDs, as this takes longer depending on their size..."
sleep 10
echo -e "\033[1A\033[2K\c"

# 5. Scan & Evaluation
for file in (find $search_paths -name "nvngx_dlss.dll" 2>/dev/null)
    set raw_ver (exiftool -s3 -ProductVersion "$file" 2>/dev/null)
    # Normalize version string (commas to dots)
    set clean_ver (echo $raw_ver | tr ',' '.')

    if test -n "$clean_ver"
        # Logic check using version-aware sort
        if test "$clean_ver" = (printf "$clean_ver\n$min_recommended" | sort -V | head -n1); and test "$clean_ver" != "$min_recommended"
            set_color yellow
            printf "%-15s" "$clean_ver"
            set_color normal
            echo "| $file"
        else
            set_color green
            printf "%-15s" "$clean_ver"
            set_color normal
            echo "| $file"
        end
    else
        set_color red
        printf "%-15s" "ERROR"
        set_color normal
        echo "| $file"
    end
end

echo "--------------------------------------------------------------------------------"
echo "Scan complete."
