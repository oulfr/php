#!/bin/bash

# Configuration
PIDFILE="/var/run/process-slice-manager.pid"
LOG_FILE="/var/log/process-slice-manager.log"
CGROUP_V1_CPU="/sys/fs/cgroup/cpu"
CGROUP_V1_MEMORY="/sys/fs/cgroup/memory"
CGROUP_V2_BASE="/sys/fs/cgroup"
POLL_INTERVAL=2
UNLIMITED_BYTES=$((1024 * 1024 * 1024 * 1024))
CGROUP_VERSION=1

# Check cgroup version and set paths
check_cgroup_version() {
    log "INFO" "Checking cgroup version"
    if [ -f "/sys/fs/cgroup/cgroup.controllers" ]; then
        CGROUP_VERSION=2
        
        # Enable controllers in root group
        echo "+cpu" > /sys/fs/cgroup/cgroup.subtree_control || log "ERROR" "Failed to enable cpu controller in cgroup v2"
        #echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control || log "ERROR" "Failed to enable cpuset controller in cgroup v2"
        #echo "+io" > /sys/fs/cgroup/cgroup.subtree_control || log "ERROR" "Failed to enable io controller in cgroup v2"
        echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control || log "ERROR" "Failed to enable memory controller in cgroup v2"
        
        local available_controllers
        available_controllers=$(cat /sys/fs/cgroup/cgroup.controllers)
        if [[ ! "$available_controllers" =~ "cpu" ]] || [[ ! "$available_controllers" =~ "memory" ]]; then
            log "ERROR" "Required controllers (cpu, memory) not available in cgroup v2"
            exit 1
        fi
        log "INFO" "Cgroup v2 detected and configured - Using unified hierarchy"
    else
        CGROUP_VERSION=1
        log "INFO" "Cgroup v1 detected - Using legacy hierarchy"
    fi
}

# Declare associative arrays
declare -A USER_DATA
declare -A PACKAGE_DATA

# Ensure dependencies are available
REQUIRED_CMDS=("jq" "ps")
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed." >&2
        exit 1
    fi
done

# Logging function with levels
log() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [$level] $message" >> "$LOG_FILE"
}

# Convert memory value to bytes
convert_memory_limit() {
    local limit="$1"
    local value="${limit//[!0-9]/}" # Extract numeric value
    local unit="${limit//[0-9]/}"  # Extract unit
    case "${unit^^}" in
        "K") echo $((value * 1024)) ;;
        "M") echo $((value * 1024 * 1024)) ;;
        "G") echo $((value * 1024 * 1024 * 1024)) ;;
        "T") echo $((value * 1024 * 1024 * 1024 * 1024)) ;;
        "") echo "$value" ;; # If no unit, assume bytes
        *) echo "Invalid unit: $unit" >&2; return 1 ;; # Error handling for invalid units
    esac
}

# Setup cgroup v2 slice
setup_cgroup_v2_slice() {
    local package="$1"
    local cpu_quota="$2"
    local cpu_period="$3"
    local mem_limit="$4"
    local swap_limit="$5"

    # Create and setup the package directory
    local package_dir="$CGROUP_V2_BASE/$package"
    mkdir -p "$package_dir" || { log "ERROR" "Failed to create package directory for $package"; return 1; }

    # Enable controllers in package directory
    echo "+cpu" > "$package_dir/cgroup.subtree_control" || \
        log "ERROR" "Failed to enable cpu controller in $package"
    #echo "+cpuset" > "$package_dir/cgroup.subtree_control" || \
    #    log "ERROR" "Failed to enable cpuset controller in $package"
    #echo "+io" > "$package_dir/cgroup.subtree_control" || \
    #    log "ERROR" "Failed to enable io controller in $package"
    echo "+memory" > "$package_dir/cgroup.subtree_control" || \
        log "ERROR" "Failed to enable memory controller in $package"
        
    # Create and setup the tasks directory
    local tasks_dir="$package_dir/tasks"
    mkdir -p "$tasks_dir" || { log "ERROR" "Failed to create tasks directory for $package"; return 1; }

    # Set CPU limits in the tasks directory
    if [[ "$cpu_quota" != "unlimited" && "$cpu_period" != "unlimited" ]]; then
       # Convert period to microseconds based on unit
        local period_us
        if [[ "$cpu_period" =~ ms$ ]]; then
            # Convert ms to microseconds
            local ms=${cpu_period//ms/}
            period_us=$((ms * 1000))
            
        elif [[ "$cpu_period" =~ s$ ]]; then
            # Convert s to microseconds
            local s=${cpu_period//s/}
            period_us=$((s * 1000000))
        else
            # Default to 1s (1000000 µs) if no unit specified
            period_us=1000000
        fi

        # maximum period allowed is 1 second (1000000 µs)
        if (( period_us > 1000000 )); then
            period_us=1000000
        fi

        # minimum period allowed is 100ms (100000 µs)
        if (( period_us < 100000 )); then
            period_us=100000
        fi

        cpu_quota=${cpu_quota//%/}
        local quota_us=$((cpu_quota * period_us / 100))

        log "INFO" "Set CPU quota: ${quota_us}us period: ${period_us}us for $package"
        echo "$quota_us $period_us" > "$tasks_dir/cpu.max" || \
            log "ERROR" "Failed to set CPU limits for $package"
    else
        log "INFO" "Set unlimited CPU for $package"
        echo "max 100000" > "$tasks_dir/cpu.max" || \
            log "ERROR" "Failed to set unlimited CPU for $package"
    fi

    # Set Memory limits
    if [[ "$mem_limit" != "unlimited" ]]; then
        local mem_bytes
        mem_bytes=$(convert_memory_limit "$mem_limit")
        log "INFO" "Set memory limit: $mem_bytes bytes for $package"
        echo "$mem_bytes" > "$tasks_dir/memory.max" || \
            log "ERROR" "Failed to set memory limit for $package"
    else
        log "INFO" "Set unlimited memory for $package"
        echo "max" > "$tasks_dir/memory.max" || \
            log "ERROR" "Failed to set unlimited memory for $package"
    fi

    # Set Swap limits
    if [[ "$swap_limit" != "unlimited" && "$mem_limit" != "unlimited" ]]; then
        local swap_bytes
        swap_bytes=$(convert_memory_limit "$swap_limit")
        log "INFO" "Set swap limit: $swap_bytes bytes for $package"
        echo "$swap_bytes" > "$tasks_dir/memory.swap.max" || \
            log "ERROR" "Failed to set swap limit for $package"
    else
        log "INFO" "Set unlimited swap for $package"
        echo "max" > "$tasks_dir/memory.swap.max" || \
            log "ERROR" "Failed to set unlimited swap for $package"
    fi
}

# Setup cgroup v1 slice
setup_cgroup_v1_slice() {
    local package="$1"
    local cpu_quota="$2"
    local cpu_period="$3"
    local mem_limit="$4"
    local swap_limit="$5"

    # Create CPU cgroup slice
    local cpu_slice_dir="$CGROUP_V1_CPU/$package"
    mkdir -p "$cpu_slice_dir" || { log "ERROR" "Failed to create CPU slice for $package"; return 1; }

    if [[ "$cpu_quota" != "unlimited" && "$cpu_period" != "unlimited" ]]; then
        cpu_period=${cpu_period//ms/}
        cpu_quota=${cpu_quota//%/}
        local cfs_period_us=$((cpu_period * 1000))
        local cfs_quota_us=$((cfs_period_us * cpu_quota / 100))
        log "INFO" "Set CPU quota: ${cfs_quota_us}us period: ${cfs_period_us}us for $package"
        echo "$cfs_period_us" > "$cpu_slice_dir/cpu.cfs_period_us" || log "ERROR" "Failed to set CPU period for $package"
        echo "$cfs_quota_us" > "$cpu_slice_dir/cpu.cfs_quota_us" || log "ERROR" "Failed to set CPU quota for $package"
    else
        log "INFO" "Set unlimited CPU for $package"
        echo "100000" > "$cpu_slice_dir/cpu.cfs_period_us" || log "ERROR" "Failed to set CPU period for $package"
        echo "-1" > "$cpu_slice_dir/cpu.cfs_quota_us" || log "ERROR" "Failed to set unlimited CPU quota for $package"
    fi

    # Create Memory cgroup slice
    local mem_slice_dir="$CGROUP_V1_MEMORY/$package"
    mkdir -p "$mem_slice_dir" || { log "ERROR" "Failed to create Memory slice for $package"; return 1; }

    if [[ "$mem_limit" != "unlimited" ]]; then
        local mem_bytes
        mem_bytes=$(convert_memory_limit "$mem_limit")
        log "INFO" "Set memory limit: $mem_bytes bytes for $package"
        echo "$mem_bytes" > "$mem_slice_dir/memory.limit_in_bytes" || log "ERROR" "Failed to set memory limit for $package"
    else
        log "INFO" "Set unlimited memory for $package"
        echo "$UNLIMITED_BYTES" > "$mem_slice_dir/memory.limit_in_bytes" || log "ERROR" "Failed to set unlimited memory for $package"
    fi

    if [[ "$swap_limit" != "unlimited" && "$mem_limit" != "unlimited" ]]; then
        local swap_bytes
        swap_bytes=$(convert_memory_limit "$swap_limit")
        log "INFO" "Set swap limit: $swap_bytes bytes for $package"
        echo "$swap_bytes" > "$mem_slice_dir/memory.memsw.limit_in_bytes" || log "ERROR" "Failed to set swap limit for $package"
    elif [[ "$mem_limit" != "unlimited" || "$swap_limit" != "unlimited" ]]; then
        log "INFO" "Set unlimited swap for $package"
        echo "$UNLIMITED_BYTES" > "$mem_slice_dir/memory.memsw.limit_in_bytes" || log "ERROR" "Failed to set unlimited swap for $package"
    fi
}

# Setup cgroup slices
setup_cgroup_slices() {
    log "INFO" "Setting up cgroup slices for packages"
    for user in "${!USER_DATA[@]}"; do
        local data="${USER_DATA[$user]}"
        local package
        package=$(echo "$data" | jq -r '.PACKAGE')
        [[ -n "$package" && -z "${PACKAGE_DATA[$package]}" ]] || continue

        local cpu_quota
        cpu_quota=$(echo "$data" | jq -r '.CPU_QUOTA')
        local cpu_period
        cpu_period=$(echo "$data" | jq -r '.CPU_QUOTA_PERIOD')
        local mem_limit
        mem_limit=$(echo "$data" | jq -r '.MEMORY_LIMIT')
        local swap_limit
        swap_limit=$(echo "$data" | jq -r '.SWAP_LIMIT')

        log "INFO" "Package: $package - Initial values - CPU Quota: $cpu_quota, CPU Period: $cpu_period, Memory: $mem_limit, Swap: $swap_limit"

        PACKAGE_DATA["$package"]="$cpu_quota:$cpu_period:$mem_limit:$swap_limit"

        if [ "$CGROUP_VERSION" -eq 2 ]; then
            setup_cgroup_v2_slice "$package" "$cpu_quota" "$cpu_period" "$mem_limit" "$swap_limit"
        else
            setup_cgroup_v1_slice "$package" "$cpu_quota" "$cpu_period" "$mem_limit" "$swap_limit"
        fi
    done
    log "INFO" "Cgroup slices setup completed"
}

# Load user data
load_user_data() {
    log "INFO" "Loading user data"
    local users_json
    users_json=$(/usr/local/hestia/bin/v-list-users json)
    [[ -n "$users_json" ]] || { log "ERROR" "Failed to fetch user data"; return; }

    USER_DATA=()
    PACKAGE_DATA=()
    while read -r user; do
        [[ "$user" == "admin" ]] && continue
        USER_DATA["$user"]=$(echo "$users_json" | jq -c --arg user "$user" '.[$user]')
        log "INFO" "Loaded data for user: $user"
    done < <(echo "$users_json" | jq -r 'keys[]')

    setup_cgroup_slices
}

# Monitor resources
monitor_resources() {
    log "INFO" "Starting process monitoring"
    declare -A known_processes

    while true; do
        while read -r pid user comm; do
            if [[ "$user" != "root" && -z "${known_processes[$pid]}" ]]; then
                local package
                package=$(echo "${USER_DATA[$user]}" | jq -r '.PACKAGE')
                [[ -n "$package" ]] || continue

                if [ "$CGROUP_VERSION" -eq 2 ]; then
                    echo "$pid" > "$CGROUP_V2_BASE/$package/tasks/cgroup.procs" 2>/dev/null || \
                        log "ERROR" "Failed to assign PID $pid to cgroup v2"
                else
                    echo "$pid" > "$CGROUP_V1_CPU/$package/cgroup.procs" 2>/dev/null || \
                        log "ERROR" "Failed to assign PID $pid to CPU cgroup"
                    echo "$pid" > "$CGROUP_V1_MEMORY/$package/cgroup.procs" 2>/dev/null || \
                        log "ERROR" "Failed to assign PID $pid to Memory cgroup"
                fi

                known_processes["$pid"]="$user"
                log "INFO" "Assigned PID $pid ($comm) of user $user to package $package"
            fi
        done < <(ps -eo pid=,user=,comm= --no-headers)

        for pid in "${!known_processes[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                log "INFO" "Process $pid terminated"
                unset known_processes["$pid"]
            fi
        done
        sleep "$POLL_INTERVAL"
    done
}

# Cleanup
cleanup() {
    log "INFO" "Stopping service"
    rm -f "$PIDFILE"
    exit 0
}

# Main
case "$1" in
    start)
        [[ -f "$PIDFILE" ]] && { log "ERROR" "Service already running"; exit 1; }
        echo $$ > "$PIDFILE"
        trap cleanup SIGINT SIGTERM
        trap 'load_user_data' SIGHUP
        check_cgroup_version
        load_user_data
        monitor_resources
        ;;
    stop)
        [[ -f "$PIDFILE" ]] && { kill -TERM "$(cat "$PIDFILE")" && log "INFO" "Service stopped"; rm -f "$PIDFILE"; } || log "ERROR" "Service not running"
        ;;
    *)
        echo "Usage: $0 {start|stop}"
        exit 1
        ;;
esac
