# monitor-disks-temperature-for-fan
A simple bash script for monitoring the temperature of selected disks, ensuring they remain in sleep mode to minimize unnecessary wake-ups, and controlling the fan based on the gathered temperature data.

## How does it work?
I made this script for my Odroid N2 device (used for many things, including being a NAS of external hard drives). You need to edit the values of variables in `monitor-disks-temperature-for-fan.sh` for your own needs.

The program is getting the selected device node names (`/dev/sd...`) from their mount point from the output of `df -h` command, e.g.:
```
DISKS_TO_MONITOR=("/srv/dev-disk-by-uuid-x" "/srv/dev-disk-by-uuid-y" "/srv/dev-disk-by-uuid-z")
```
After that it monitors (by default every 10 seconds) if there was any activity on the disks, by reading `/proc/diskstats`.
If there was any activity, it checks the active disks' temperature using `smartctl` (by default it caches it for 60 seconds to prevent too many calls).
Thanks to that the disks that are currently in the sleep mode won't be woken up.
The program then sets the selected fan speed based on the maximum temperature from all monitored disks. By default the `MIN_TEMP=40`, `MAX_TEMP=55` and `MIN_FAN_SPEED=40` (range 0-255). So if the maximum temperature from all disks is 40 °C, it will start the fan at speed 40, but if the temperature is 55 °C or higher, the fan will run with the full speed (255). The temperatures in the middle (41-54) are adjusting the fan speed linearly. Obviously if you use a different fan than Odroid's N2 "pwm-fan" you need to modify the script for your own configuration. 
The default sleep times in this script are pretty long. It has no performance impact at all.


## Requirments:
```
apt install screen smartmontools
```

## Autostart:
You can add it to autostart with `crontab -e`:
```
@reboot /usr/bin/screen -dmS disksfan /path/to/script/monitor-disks-temperature-for-fan.sh
```
Then resume the screen if you need:
```
screen -r disksfan
```
