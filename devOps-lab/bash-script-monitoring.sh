#!/bin/bash

# Linux Server Monitor for Debian-based Systems
# Author: System Administrator
# Version: 1.0
# Description: Comprehensive monitoring script for Debian servers

# Configuration
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/server-monitor.log"
EMAIL_ALERT=""  # Set email for alerts (optional)
CPU_THRESHOLD=80
MEMORY_THRESHOLD=80
DISK_THRESHOLD=85
LOAD_THRESHOLD=2.0

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local status="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$status" in
        "OK")
            echo -e "${GREEN}[OK]${NC} $message"
            ;;
        "WARNING")
            echo -e "${YELLOW}[WARNING]${NC} $message"
            ;;
        "CRITICAL")
            echo -e "${RED}[CRITICAL]${NC} $message"
            ;;
        "INFO")
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
    esac
    
    # Log to file if logging is enabled
    if [[ "$ENABLE_LOGGING" == "true" ]]; then
        echo "[$timestamp] [$status] $message" >> "$LOG_FILE"
    fi
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 && "$1" != "--no-root" ]]; then
        print_status "WARNING" "Some checks require root privileges for full functionality"
        echo "Run with sudo for complete monitoring or use --no-root flag"
    fi
}

# Function to get system information
get_system_info() {
    echo -e "\n${BLUE}=== SYSTEM INFORMATION ===${NC}"
    
    local hostname=$(hostname)
    local kernel=$(uname -r)
    local os_info=$(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
    local uptime=$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}')
    local last_boot=$(who -b 2>/dev/null | awk '{print $3,$4}' || uptime -s 2>/dev/null || echo "Unknown")
    
    print_status "INFO" "Hostname: $hostname"
    print_status "INFO" "OS: $os_info"
    print_status "INFO" "Kernel: $kernel"
    print_status "INFO" "Uptime: $uptime"
    print_status "INFO" "Last boot: $last_boot"
}

# Function to check CPU usage
check_cpu() {
    echo -e "\n${BLUE}=== CPU MONITORING ===${NC}"
    
    local cpu_count=$(nproc)
    local load_avg=$(cat /proc/loadavg | awk '{print $1}')
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 | cut -d',' -f1)
    
    # If cpu_usage is empty, try alternative method
    if [[ -z "$cpu_usage" ]]; then
        cpu_usage=$(iostat -c 1 1 2>/dev/null | tail -1 | awk '{print 100-$6}' | cut -d. -f1)
    fi
    
    # If still empty, use /proc/stat method
    if [[ -z "$cpu_usage" ]]; then
        cpu_usage=$(awk '{u=$2+$4; t=$2+$3+$4+$5; if (NR==1){u1=u; t1=t;} else print ($2+$4-u1) * 100 / (t-t1); }' <(grep 'cpu ' /proc/stat; sleep 1; grep 'cpu ' /proc/stat) | cut -d. -f1)
    fi
    
    print_status "INFO" "CPU Cores: $cpu_count"
    print_status "INFO" "Load Average (1min): $load_avg"
    print_status "INFO" "CPU Usage: ${cpu_usage:-0}%"
    
    # Check thresholds
    if (( $(echo "$load_avg > $LOAD_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
        print_status "CRITICAL" "High load average: $load_avg (threshold: $LOAD_THRESHOLD)"
    fi
    
    if [[ -n "$cpu_usage" ]] && (( cpu_usage > CPU_THRESHOLD )); then
        print_status "CRITICAL" "High CPU usage: ${cpu_usage}% (threshold: ${CPU_THRESHOLD}%)"
    fi
}

# Function to check memory usage
check_memory() {
    echo -e "\n${BLUE}=== MEMORY MONITORING ===${NC}"
    
    local mem_info=$(free -m)
    local total_mem=$(echo "$mem_info" | awk 'NR==2{print $2}')
    local used_mem=$(echo "$mem_info" | awk 'NR==2{print $3}')
    local free_mem=$(echo "$mem_info" | awk 'NR==2{print $4}')
    local available_mem=$(echo "$mem_info" | awk 'NR==2{print $7}')
    local mem_usage=$(echo "scale=1; $used_mem * 100 / $total_mem" | bc)
    
    # Swap information
    local swap_total=$(echo "$mem_info" | awk 'NR==3{print $2}')
    local swap_used=$(echo "$mem_info" | awk 'NR==3{print $3}')
    local swap_usage=0
    if [[ $swap_total -gt 0 ]]; then
        swap_usage=$(echo "scale=1; $swap_used * 100 / $swap_total" | bc)
    fi
    
    print_status "INFO" "Total Memory: ${total_mem} MB"
    print_status "INFO" "Used Memory: ${used_mem} MB (${mem_usage}%)"
    print_status "INFO" "Free Memory: ${free_mem} MB"
    print_status "INFO" "Available Memory: ${available_mem:-N/A} MB"
    print_status "INFO" "Swap Usage: ${swap_used}/${swap_total} MB (${swap_usage}%)"
    
    # Check thresholds
    if (( $(echo "$mem_usage > $MEMORY_THRESHOLD" | bc -l) )); then
        print_status "CRITICAL" "High memory usage: ${mem_usage}% (threshold: ${MEMORY_THRESHOLD}%)"
    fi
    
    if (( $(echo "$swap_usage > 50" | bc -l) )); then
        print_status "WARNING" "High swap usage: ${swap_usage}%"
    fi
}

# Function to check disk usage
check_disk() {
    echo -e "\n${BLUE}=== DISK MONITORING ===${NC}"
    
    # Check all mounted filesystems
    df -h | grep -vE '^Filesystem|tmpfs|cdrom|udev' | awk '{print $1 " " $5 " " $6}' | while read filesystem usage mountpoint; do
        usage_num=$(echo "$usage" | sed 's/%//g')
        
        if [[ $usage_num -ge $DISK_THRESHOLD ]]; then
            print_status "CRITICAL" "High disk usage on $mountpoint: $usage (threshold: ${DISK_THRESHOLD}%)"
        elif [[ $usage_num -ge 70 ]]; then
            print_status "WARNING" "Moderate disk usage on $mountpoint: $usage"
        else
            print_status "OK" "Disk usage on $mountpoint: $usage"
        fi
    done
    
    # Show disk I/O if iostat is available
    if command -v iostat &> /dev/null; then
        echo -e "\n${BLUE}Disk I/O Statistics:${NC}"
        iostat -d 1 1 | grep -E "Device|sd|hd|nvme|vd" | head -10
    fi
}

# Function to check network connectivity
check_network() {
    echo -e "\n${BLUE}=== NETWORK MONITORING ===${NC}"
    
    # Check network interfaces
    for interface in $(ls /sys/class/net/ | grep -v lo); do
        if [[ -e "/sys/class/net/$interface/operstate" ]]; then
            state=$(cat /sys/class/net/$interface/operstate)
            if [[ "$state" == "up" ]]; then
                print_status "OK" "Interface $interface is up"
            else
                print_status "WARNING" "Interface $interface is $state"
            fi
        fi
    done
    
    # Test internet connectivity
    if ping -c 1 8.8.8.8 &> /dev/null; then
        print_status "OK" "Internet connectivity is working"
    else
        print_status "CRITICAL" "No internet connectivity"
    fi
    
    # Check listening ports
    print_status "INFO" "Active listening ports:"
    netstat -tuln 2>/dev/null | grep LISTEN | head -5 | while read line; do
        echo "  $line"
    done
}

# Function to check system services
check_services() {
    echo -e "\n${BLUE}=== SERVICE MONITORING ===${NC}"
    
    # Common services to check on Debian systems
    local services=("ssh" "cron" "systemd-resolved" "networking")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            print_status "OK" "Service $service is running"
        elif systemctl list-unit-files | grep -q "$service"; then
            print_status "CRITICAL" "Service $service is not running"
        else
            print_status "INFO" "Service $service is not installed"
        fi
    done
}

# Function to check system logs for errors
check_logs() {
    echo -e "\n${BLUE}=== LOG MONITORING ===${NC}"
    
    # Check for recent critical errors in system logs
    if command -v journalctl &> /dev/null; then
        local error_count=$(journalctl --since "1 hour ago" --priority=err --no-pager -q | wc -l)
        local critical_count=$(journalctl --since "1 hour ago" --priority=crit --no-pager -q | wc -l)
        
        print_status "INFO" "Errors in last hour: $error_count"
        print_status "INFO" "Critical errors in last hour: $critical_count"
        
        if [[ $critical_count -gt 0 ]]; then
            print_status "CRITICAL" "Critical errors found in system logs"
            journalctl --since "1 hour ago" --priority=crit --no-pager -q | head -3
        fi
    fi
}

# Function to check security status
check_security() {
    echo -e "\n${BLUE}=== SECURITY MONITORING ===${NC}"
    
    # Check for available updates
    if command -v apt &> /dev/null; then
        apt list --upgradable 2>/dev/null | grep -c "upgradable" | while read update_count; do
            if [[ $update_count -gt 0 ]]; then
                print_status "WARNING" "$update_count package updates available"
            else
                print_status "OK" "System is up to date"
            fi
        done
    fi
    
    # Check failed login attempts
    if [[ -f /var/log/auth.log ]]; then
        local failed_logins=$(grep "Failed password" /var/log/auth.log | grep "$(date '+%b %d')" | wc -l)
        if [[ $failed_logins -gt 5 ]]; then
            print_status "WARNING" "$failed_logins failed login attempts today"
        else
            print_status "OK" "$failed_logins failed login attempts today"
        fi
    fi
}

# Function to generate summary report
generate_summary() {
    echo -e "\n${BLUE}=== MONITORING SUMMARY ===${NC}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    print_status "INFO" "Monitoring completed at $timestamp"
    
    if [[ "$ENABLE_LOGGING" == "true" ]]; then
        print_status "INFO" "Detailed logs saved to: $LOG_FILE"
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $SCRIPT_NAME [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help          Show this help message"
    echo "  --no-root       Run without root privilege warnings"
    echo "  --log           Enable logging to $LOG_FILE"
    echo "  --quiet         Suppress INFO messages"
    echo "  --cpu-threshold Set CPU usage threshold (default: $CPU_THRESHOLD%)"
    echo "  --mem-threshold Set memory usage threshold (default: $MEMORY_THRESHOLD%)"
    echo "  --disk-threshold Set disk usage threshold (default: $DISK_THRESHOLD%)"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME --log"
    echo "  $SCRIPT_NAME --cpu-threshold 90 --mem-threshold 85"
    echo "  sudo $SCRIPT_NAME --log"
}

# Main function
main() {
    local quiet_mode=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_usage
                exit 0
                ;;
            --no-root)
                NO_ROOT_CHECK=true
                ;;
            --log)
                ENABLE_LOGGING=true
                ;;
            --quiet)
                quiet_mode=true
                ;;
            --cpu-threshold)
                CPU_THRESHOLD="$2"
                shift
                ;;
            --mem-threshold)
                MEMORY_THRESHOLD="$2"
                shift
                ;;
            --disk-threshold)
                DISK_THRESHOLD="$2"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
        shift
    done
    
    # Check dependencies
    if ! command -v bc &> /dev/null; then
        echo "Warning: 'bc' command not found. Install with: sudo apt install bc"
    fi
    
    # Header
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}           DEBIAN LINUX SERVER MONITORING SCRIPT${NC}"
    echo -e "${BLUE}================================================================${NC}"
    
    # Check if running as root
    if [[ "$NO_ROOT_CHECK" != "true" ]]; then
        check_root
    fi
    
    # Create log directory if logging is enabled
    if [[ "$ENABLE_LOGGING" == "true" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE" 2>/dev/null || {
            print_status "WARNING" "Cannot write to log file: $LOG_FILE"
            ENABLE_LOGGING=false
        }
    fi
    
    # Run monitoring checks
    get_system_info
    check_cpu
    check_memory
    check_disk
    check_network
    check_services
    check_logs
    check_security
    generate_summary
    
    echo -e "${BLUE}================================================================${NC}"
}

# Run the script
main "$@"