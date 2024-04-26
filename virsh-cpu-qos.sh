#!/bin/bash

# Configuration
monitor_folder="/var/vm_cpu_qos/vm_cpu_monitor"
log_file="/var/vm_cpu_qos/vm_cpu_log.log"
host_cpu_threshold=400    # Total host CPU threshold to start limiting VMs (e.g., for 4 cores, 400%)
vm_cpu_high_threshold=50  # VM CPU usage high threshold
vm_cpu_low_threshold=50   # VM CPU usage low threshold
burst_score_cap=100       # Max burst score a VM can accumulate
score_increase_factor=2   # Increment for score when high threshold exceeded
score_decrease_factor=1   # Decrement for score when below low threshold
limit_duration=20         # Score threshold for limiting
restore_duration=20       # Score threshold for restoring
quota_per_vcore=20        # CPU quota percentage per vCore when limiting
quota_per_vcore_orig=100  # CPU quota percentage per vCore without limit


# Create directory and log file if they don't exist
mkdir -p $monitor_folder
touch $log_file

# Check host CPU usage
total_host_cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{total += $1} END {print 100-total}')
host_cpu_count=$(grep -c ^processor /proc/cpuinfo)
normalized_host_cpu_usage=$(echo "scale=2; $total_host_cpu_usage * $host_cpu_count" | bc)

# Function to log messages
log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $log_file
}

# Process each VM
virsh list --name | while read vm; do
    if [[ -z "$vm" ]]; then
        continue
    fi

    # Files for storing VM data
    score_file="${monitor_folder}/${vm}_score"
    state_file="${monitor_folder}/${vm}_state"
    [[ ! -f $score_file ]] && echo "0" > $score_file
    [[ ! -f $state_file ]] && echo "unlimited" > $state_file
    burst_score=$(cat $score_file)
    last_state=$(cat $state_file)

    # Get VM CPU usage
    # First get the each CPU PID from virsh
    vm_pid=$(ps -ef | grep qemu | grep ${vm} | awk '{print $2}')
    # for each CPU PID accumulate the total CPU usage
    vm_cpu_usage=0
    cpu_usage=$(top -bn1 | grep -w "$vm_pid" | awk '{print $9}'| head -n 1) 
    vm_cpu_usage=$(echo "$vm_cpu_usage + ${cpu_usage:-0}" | bc)
    echo "${vm} CPU: ${vm_cpu_usage}"
    # Update burst score
    # Ensure vm_cpu_usage is a number; if not, set it to 0
    if (( $(echo "$vm_cpu_usage > $vm_cpu_high_threshold" | bc -l) )); then
      burst_score=$((burst_score + score_increase_factor))
      burst_score=$((burst_score > burst_score_cap ? burst_score_cap : burst_score))
      echo $burst_score > $score_file
      echo "${vm} increase burst_score: ${burst_score}"
    elif (( $(echo "$vm_cpu_usage < $vm_cpu_low_threshold" | bc -l) )); then
      burst_score=$((burst_score - score_decrease_factor))
      #burst_score lower limit is 0
      burst_score=$((burst_score < 0 ? 0 : burst_score))
      echo $burst_score > $score_file
      echo "${vm} decrease burst_score: ${burst_score}"
    fi
    # Get the number of vCores for the VM and calculate the quota
    vcores=$(virsh dominfo $vm | grep 'CPU(s)' | awk '{print $2}')
    new_quota=$(($vcores * quota_per_vcore * 1000))
    orig_quota=$(($vcores * quota_per_vcore_orig * 1000))

    # Check host CPU usage and apply limits
    if (( $(echo "$normalized_host_cpu_usage > $host_cpu_threshold" | bc -l) )); then
        if [[ $burst_score -ge $limit_duration && $last_state == "unlimited" ]]; then
            virsh schedinfo $vm --set vcpu_quota=$new_quota --live
            virsh schedinfo $vm --set global_quota=$new_quota --live
            echo "limited" > $state_file
            log_action "Limited $vm to $new_quota ($vcores vCores)"
        fi
    fi
    if [[ $burst_score -le $restore_duration && $last_state == "limited" ]]; then
        virsh schedinfo $vm --set vcpu_quota=$orig_quota --live
        virsh schedinfo $vm --set global_quota=$orig_quota --live
        echo "unlimited" > $state_file
        log_action "Restored $vm to full capacity"
    fi
done
