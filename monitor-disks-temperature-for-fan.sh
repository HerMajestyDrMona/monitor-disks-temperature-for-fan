#!/bin/bash

trap disablefans exit

BASIC_SLEEP=1
UPDATE_TIME=10
CACHE_INTERVAL=60 # Interval for caching temperature values (to avoid too frequent smartctl calls)
RELOAD_INTERVAL=120 # How often to reload available disks and their name (df -h call)
TEMPERATURE_EXPIRE_SECONDS=300 # When no disks were active and temperature returns -1, then how long to let it run.
FAN_PWM="/sys/class/hwmon/hwmon2/pwm1"
MIN_TEMP=40     # Lower bound of temperature range
MAX_TEMP=55     # Upper bound of temperature range
MIN_FAN_SPEED=40  # Minimum fan speed
DISKS_TO_MONITOR=("/srv/dev-disk-by-uuid-x" "/srv/dev-disk-by-uuid-y" "/srv/dev-disk-by-uuid-z")

declare -a FOUND_DISKS=()
declare -A DISK_STATS_PREVIOUS
declare -A DISK_STATS
declare -A DISK_STATS
declare -A ACTIVE_DISKS
declare -A ACTIVE_DISKS_CACHED
declare -A LAST_UPDATED
CURRENT_TEMPERATURE=-1

function disablefans() {
	echo 0 > "$FAN_PWM"
}

function find_and_extract_disks() {
    FOUND_DISKS=()
    df_output=$(df -h)
    for disk in "${DISKS_TO_MONITOR[@]}"; do
        while IFS= read -r line; do
            if [[ $line == *"$disk"* ]]; then # Check if the line contains the disk
                disk_path=$(echo "$line" | awk '{print $1}')  # Extract the first field (disk path)
                disk_name=$(basename "$disk_path")
                disk_base=${disk_name%?}        
                FOUND_DISKS+=("$disk_base")
                break
            fi
        done <<< "$df_output"
    done
}

function get_disk_stats() {
    while IFS= read -r line; do
        disk_name=$(echo "$line" | awk '{print $3}')  # Use awk for more reliable field extraction
        #echo "line: $line"
        #echo "disk_name: $disk_name"  
        for found_disk in "${FOUND_DISKS[@]}"; do
            if [[ "$disk_name" == "$found_disk" ]]; then
				substring_after_disk_name="${line##*$disk_name }"
                DISK_STATS["$disk_name"]="$substring_after_disk_name"
                #stats=$(echo "$line" | cut -d ' ' -f 4-)
                #DISK_STATS["$disk_name"]="$stats"
                break  
            fi
        done
    done < /proc/diskstats
}

last_monitorng_loop_time=0
last_reload_time=0
last_time_found_any_temperature=0
previous_speed=-1
SPEED=0
# Main monitoring loop
while true; do
    current_time=$(date +%s)
	if (( current_time - last_monitorng_loop_time >= UPDATE_TIME )); then
		last_monitorng_loop_time=$current_time
		
		# Check if it's time to reload
		if (( current_time - last_reload_time >= RELOAD_INTERVAL )); then
			find_and_extract_disks  
			echo "Disks reloaded at $(date):"
			reloaded=""  # Initialize the variable
			for disk in "${FOUND_DISKS[@]}"; do
				reloaded+=" $disk"
			done
			reloaded="${reloaded# }"
			echo $reloaded
			last_reload_time=$current_time 
		fi

		get_disk_stats
		
		for disk in "${!DISK_STATS[@]}"; do
			if [[ -n "${DISK_STATS_PREVIOUS[$disk]}" ]]; then # Check if previous stats exist
				if [[ "${DISK_STATS_PREVIOUS[$disk]}" != "${DISK_STATS[$disk]}" ]]; then
				#echo "Disk Stats != Previous Disk Stats:"
				#echo "${DISK_STATS[$disk]}"
				#echo "${DISK_STATS_PREVIOUS[$disk]}"
					ACTIVE_DISKS["$disk"]="true"
				else
					ACTIVE_DISKS["$disk"]="false"
				fi
			else
				ACTIVE_DISKS["$disk"]="false"
			fi
			DISK_STATS_PREVIOUS["$disk"]="${DISK_STATS[$disk]}" 
		done
		
		# Get temperature for active disks
		for disk in "${!ACTIVE_DISKS[@]}"; do
			#echo "Disk: $disk is: ${ACTIVE_DISKS[$disk]}"
			if [[ "${ACTIVE_DISKS[$disk]}" == "true" ]]; then
				if [[ -z "${LAST_UPDATED[$disk]}" ]] || (( current_time - LAST_UPDATED[$disk] >= CACHE_INTERVAL )); then
					LAST_UPDATED["$disk"]=$(date +%s)
					temp_output=$(sudo smartctl -A -T permissive /dev/$disk | grep -E "(Temperature(_Celsius)?|Temperature_Celsius):?\s*([0-9]+)")
					echo "Temp from Smart: $temp_output"
					if [[ -n "$temp_output" ]]; then
						if [[ $temp_output == *"Temperature_Celsius"* ]]; then
							temperature=$(echo "$temp_output" | awk '{print $10}') 
						else
							temperature=$(echo "$temp_output" | awk '{print $(NF-1)}')
						fi                
						#ACTIVE_DISKS["$disk"]="$temperature"
						ACTIVE_DISKS_CACHED["$disk"]="$temperature"
						last_time_found_any_temperature=$(date +%s)
					else
						#ACTIVE_DISKS["$disk"]="N/A"
						ACTIVE_DISKS_CACHED["$disk"]="N/A"
					fi
				#else
					#echo "Temperature in cache! Not calling smart this time!"
				fi
			elif [[ "${ACTIVE_DISKS[$disk]}" == "false" ]]; then	
				if [[ -z "${LAST_UPDATED[$disk]}" ]] || (( current_time - LAST_UPDATED[$disk] >= CACHE_INTERVAL )); then
					ACTIVE_DISKS_CACHED["$disk"]="false"
				fi
			fi
		done
		
		max_temp=-1
		found_temps=0
		for disk in "${!ACTIVE_DISKS_CACHED[@]}"; do
			if [[ "${ACTIVE_DISKS_CACHED[$disk]}" != "false" ]]; then
				temp="${ACTIVE_DISKS_CACHED[$disk]}" # Extract temperature for clarity
				# Check if the temperature is a valid number and higher than the current max
				if [[ "$temp" != "N/A" ]] && (( temp > max_temp )); then
					max_temp="$temp"
				fi

				echo "$disk: $temp"
				found_temps=$((found_temps + 1))
			fi
		done

		echo "Max_Temperature: $max_temp"
		echo "Found_Temperatures: $found_temps"
		
		if [[ $max_temp -ne -1 ]]; then
			CURRENT_TEMPERATURE=$max_temp
		else
			time_diff=$(( current_time - last_time_found_any_temperature ))
			if [[ $time_diff -gt $TEMPERATURE_EXPIRE_SECONDS ]]; then  # 300 seconds = 5 minutes
				CURRENT_TEMPERATURE=-1 
			fi
		fi
		#echo "Current Reference Temperature: $CURRENT_TEMPERATURE"

		if [[ $CURRENT_TEMPERATURE -ne -1 ]]; then
			if (( CURRENT_TEMPERATURE >= MIN_TEMP && CURRENT_TEMPERATURE <= MAX_TEMP )); then
			# Calculate fan SPEED linearly within the temperature range
			temp_range=$(( MAX_TEMP - MIN_TEMP ))
			speed_range=$(( 255 - MIN_FAN_SPEED ))
			SPEED=$(( MIN_FAN_SPEED + (CURRENT_TEMPERATURE - MIN_TEMP) * speed_range / temp_range ))
			elif (( CURRENT_TEMPERATURE > MAX_TEMP )); then
				SPEED=255
			else
				# Disable the fan when below the temperature range
				SPEED=0
			fi
		else
			# Disable the fan:
			SPEED=0
		fi
	fi
	echo "Max Temperature: $CURRENT_TEMPERATURE. Fan Speed [0-255]: $SPEED"
	#echo $SPEED | sudo tee "$FAN_PWM"
	echo $SPEED > "$FAN_PWM"
	
    sleep $BASIC_SLEEP
done

