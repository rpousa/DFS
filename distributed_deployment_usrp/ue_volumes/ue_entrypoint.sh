#!/bin/bash

set -uo pipefail

PREFIX=/opt/oai-nr-ue
CONFIGFILE=$PREFIX/etc/nr-ue.conf

echo "=================================="
echo "/proc/sys/kernel/core_pattern=$(cat /proc/sys/kernel/core_pattern)"

if [ ! -f $CONFIGFILE ]; then
  echo "No configuration file $CONFIGFILE found: attempting to find YAML config"
  YAML_CONFIGFILE=$PREFIX/etc/nr-ue.yaml
  if [ ! -f $YAML_CONFIGFILE ]; then
    echo "No configuration file $YAML_CONFIGFILE found. Please mount either at $CONFIGFILE or $YAML_CONFIGFILE"
    exit 255
  fi
  CONFIGFILE=$YAML_CONFIGFILE
fi

echo "=================================="
echo "== Configuration file:"
cat $CONFIGFILE

# Load the USRP binaries
echo "=================================="
echo "== Load USRP binaries"
if [[ -v USE_B2XX ]]; then
    $PREFIX/bin/uhd_images_downloader.py -t b2xx
elif [[ -v USE_X3XX ]]; then
    $PREFIX/bin/uhd_images_downloader.py -t x3xx
elif [[ -v USE_N3XX ]]; then
    $PREFIX/bin/uhd_images_downloader.py -t n3xx
fi

# in case we have conf file, append
new_args=()
while [[ $# -gt 0 ]]; do
  new_args+=("$1")
  shift
done

new_args+=("-O")
new_args+=("$CONFIGFILE")

# enable printing of stack traces on assert
# export OAI_GDBSTACKS=1

# echo "=================================="
# echo "== Starting NR UE soft modem"
# if [[ -v USE_ADDITIONAL_OPTIONS ]]; then
#     echo "Additional option(s): ${USE_ADDITIONAL_OPTIONS}"
#     for word in ${USE_ADDITIONAL_OPTIONS}; do
#         new_args+=("$word")
#     done
#     echo "${new_args[@]}"
#     exec "${new_args[@]}"
# else
#     echo "${new_args[@]}"
#     exec "${new_args[@]}"
# fi
    


echo "=================================="
echo "== Starting NR UE soft modem"

# ==================================================
# ADD DEBUGGING SUPPORT
# DEBUG=1      → start under gdb
# DEBUG=server → start under gdbserver (port 2000)
# ==================================================

UE_BIN="${new_args[0]}"
UE_ARGS=("${new_args[@]:1}")

if [[ -v USE_ADDITIONAL_OPTIONS ]]; then
    echo "Additional option(s): ${USE_ADDITIONAL_OPTIONS}"
    for word in ${USE_ADDITIONAL_OPTIONS}; do
        UE_ARGS+=("$word")
    done
fi

if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "🚀 Starting UE in GDB mode"
    echo "gdb --args $UE_BIN ${UE_ARGS[*]}"
    exec gdb --args "$UE_BIN" "${UE_ARGS[@]}"

elif [[ "${DEBUG:-0}" == "server" ]]; then
    echo "🚀 Starting UE in gdbserver mode on port 2000"
    echo "gdbserver 0.0.0.0:2000 $UE_BIN ${UE_ARGS[*]}"
    exec gdbserver 0.0.0.0:2000 "$UE_BIN" "${UE_ARGS[@]}"

else
    echo "$UE_BIN ${UE_ARGS[*]}"
    exec "$UE_BIN" "${UE_ARGS[@]}"

fi
