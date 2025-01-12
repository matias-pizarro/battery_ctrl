#!/usr/bin/env sh
#set -x

GET_START="BCTG"
SET_START="BCCS"
GET_STOP="BCSG"
SET_STOP="BCSS"
GET_DISCHARGE="BDSG"
SET_DISCHARGE="BDSS"
GET_INHIBIT="BICG"
SET_INHIBIT="BICS"

KERNEL_MODULES_LOADED=0
SUDO_CHECKED=false

ACPI_BATTERY_HANDLE=""

# check permissions
SUDO=""
if ! [ "$(id -u)" -eq 0 ]; then
  [ -f "$(which sudo)" ] && [ -x "$(which sudo)" ] && SUDO="$(which sudo)"
  [ -f "$(which doas)" ] && [ -x "$(which doas)" ] && SUDO="$(which doas)"
fi

__check_sudo() {
  if ! [ "$SUDO_CHECKED" = "false" ]; then
    # echo "Checking sudo"
    if [ -z "${SUDO}" ]; then
      echo "Please install sudo or doas, or re-execute again as root."
      exit 1
    fi
  else
    SUDO_CHECKED=true
  fi
}

__is_valid_threshold() {
  if ! [ "$(echo ${1} | grep -E '^[0-9]+$')" ]; then
     echo "Error: ${1} is not a valid number."
     exit 4
  fi
  if [ "${1}" -lt 0 ] || [ "${1}" -gt 99 ]; then
    echo "thresholds must be a number in the range of 0 - 99 "
    exit 7
  fi
}

__check_thresholds() {
  __is_valid_threshold "${1}"
  __is_valid_threshold "${2}"
    if [ "${1}" -ge "${2}" ]; then
      echo "The start threshold (${1}%) must be inferior to the stop threshold (${2}%)."
      exit 6
    fi
}

__load_kernel_modules() {
  if [ "$KERNEL_MODULES_LOADED" = "0" ]; then
    if [ "$(kldstat -n acpi_ibm.ko | wc -l)" -eq "0" ]; then
      __check_sudo
      echo "acpi_ibm kernel modules not loaded."
      echo "loading acpi_ibm ..."
      
      ${SUDO} kldload acpi_ibm
      
      if [ "$(kldstat -n acpi_ibm.ko | wc -l)" -eq "0" ]; then
        echo "acpi_ibm kernel modules failed to load."
      else
        KERNEL_MODULES_LOADED="$(( KERNEL_MODULES_LOADED + 1  ))"
      fi
    else
      KERNEL_MODULES_LOADED="$(( KERNEL_MODULES_LOADED + 1  ))"
    fi

    if [ "$(kldstat -n acpi_call.ko | wc -l)" -eq "0" ]; then
      __check_sudo
      echo "acpi_call kernel modules not loaded."
      echo "loading acpi_call ..."
      
      ${SUDO} kldload acpi_call
      
     if [ "$(kldstat -n acpi_call.ko | wc -l)" -eq "0" ]; then
        echo "acpi_call kernel modules failed to load."
      else
        KERNEL_MODULES_LOADED="$(( KERNEL_MODULES_LOADED + 1  ))"
      fi
    else
      KERNEL_MODULES_LOADED="$(( KERNEL_MODULES_LOADED + 1  ))"
    fi
  if [ "$KERNEL_MODULES_LOADED" = "2" ]; then
      ACPI_BATTERY_HANDLE=$(sysctl dev.acpi_ibm.0.%location | cut -f2 -d'=')
    fi
  fi
}

__acpi_battery_handle() {
  __load_kernel_modules
  echo "$(sysctl dev.acpi_ibm.0.%location | cut -f2 -d'=')"
}

__get_acpi_value() {
  __load_kernel_modules
  if [ -n "$ACPI_BATTERY_HANDLE" ]; then
    value=$(( $(acpi_call -p "${ACPI_BATTERY_HANDLE}"."${1}" -i 1) & 0xFF ))
    # if [ "$value" = "0" ]; then setvar value 100; fi
    echo "${value}"
  fi
}

__set_acpi_value() {
  __load_kernel_modules
  __check_sudo
  if [ -n "$ACPI_BATTERY_HANDLE" ]; then
    # if [ "$2" = "0" ]; then setvar value 1; fi
    # if [ "$2" = "100" ]; then setvar value 0; fi
    echo "$(${SUDO} acpi_call -p $(__acpi_battery_handle).${1} -i ${2})"
  else
    echo 99
  fi
}

__show() {
  echo

  echo "Current values:"

  DESIGN_CAPACITY="$(acpiconf -i 0 | grep "Design c" | awk '{print $3}')"
  CURRENT_CAPACITY="$(acpiconf -i 0 | grep "full c" | awk '{print $4}')"
  BATTERY_HEALTH="$(( 39610 * 100 /  57020 ))"
  echo "    battery health:         ${BATTERY_HEALTH}%"

  CURRENT_CHARGE_START_THRESHOLD=$(__get_acpi_value "${GET_START}")
  echo "    charge start threshold: ${CURRENT_CHARGE_START_THRESHOLD}%"

  CURRENT_CHARGE_STOP_THRESHOLD=$(__get_acpi_value "${GET_STOP}")
  echo "    charge stop  threshold: ${CURRENT_CHARGE_STOP_THRESHOLD}%"
}

__show_verbose() {
  echo
  /usr/bin/env acpiconf -i 0
  __show
}

__update_thresholds() {
  echo
  echo "Changing thresholds:"

  __check_thresholds "${START_THRESHOLD}" "${STOP_THRESHOLD}"

  PREVIOUS_START_THRESHOLD=$(__get_acpi_value "${GET_START}")
  if [ "${PREVIOUS_START_THRESHOLD}" = "${START_THRESHOLD}" ]; then
    echo "    - start threshold is already set to ${START_THRESHOLD}%"
  else
    SUCCESS_START=$(__set_acpi_value "${SET_START}" "${START_THRESHOLD}")

    if [ "${SUCCESS_START}" = "0" ]; then
      sleep 0.5
      echo "    - start threshold was changed from ${PREVIOUS_START_THRESHOLD}% to $(__get_acpi_value "${GET_START}")%"
    else 
      echo "    - failed to change start threshold from ${PREVIOUS_START_THRESHOLD}% to ${START_THRESHOLD}%"
      exit 9
    fi
  fi

  PREVIOUS_STOP_THRESHOLD=$(__get_acpi_value "${GET_STOP}")
  if [ "${PREVIOUS_STOP_THRESHOLD}" = "${STOP_THRESHOLD}" ]; then
    echo "    - stop threshold is already set to ${STOP_THRESHOLD}%"
  else
    SUCCESS_STOP=$(__set_acpi_value "${SET_STOP}" "${STOP_THRESHOLD}")

    if [ "${SUCCESS_STOP}" = "0" ]; then
      echo "    - stop threshold was changed from ${PREVIOUS_STOP_THRESHOLD}% to $(__get_acpi_value "${GET_STOP}")%"
    else 
      echo "    - failed to change stop threshold from ${PREVIOUS_STOP_THRESHOLD}% to ${STOP_THRESHOLD}%"
      exit 9
    fi
  fi
}

__usage() {
  echo ""
  echo "Usage: ${0##*/} -sv --start=<start threshold> --stop=<stop threshold> --"
  echo "  OPTIONS: -s"
  echo "           --show            print out basic battery diagnostics (apm output)"
  echo "           -sv"
  echo "           --show --verbose  print out extended battery diagnostics (apm + acpiconf) "
  echo "           --start           set thresholds at which batteries will start charging"
  echo "           --stop            set thresholds at which batteries will stop charging"
  echo "           -h"
  echo "           --help            show this hjelp summary"
  echo "  EXAMPLES:"
  echo "      # Set start and stop thresholds"
  echo "      ${0##*/} --start=40 --stop=80"
  echo ""
  echo "      # See battery diagnostics"
  echo "      ${0##*/} -sv"
}

while getopts "sv-:" opt; do
  case $opt in
    -)
        case "${OPTARG}" in
            show)
                SHOW="true"
                ;;
            verbose)
                VERBOSE="true"
                ;;
            # Known issue: when using sh nd specifying more than one long
            # option and not using the equal sign form, only the first option is read
            # e.g. ./battery_ctrl.sh --start 40 --stop 80
            start)
                START_THRESHOLD="$(eval "echo \$${OPTIND}")";
                OPTIND="$(( OPTIND + 1 ))"
                echo "Specified start threshold with '--${OPTARG}': ${START_THRESHOLD}" >&2;
                ;;
            start=*)
                START_THRESHOLD=${OPTARG#*=}
                echo "Specified start threshold with '--start=${START_THRESHOLD}'" >&2;
                ;;
            # Known issue: when using sh nd specifying more than one long
            # option and not using the equal sign form, only the first option is read
            # e.g. ./battery_ctrl.sh --start 40 --stop 80
            stop)
                STOP_THRESHOLD="$(eval "echo \$${OPTIND}")";
                OPTIND="$(( OPTIND + 1 ))"
                echo "Specified stop threshold with '--${OPTARG}': ${STOP_THRESHOLD}" >&2;
                ;;
            stop=*)
                STOP_THRESHOLD=${OPTARG#*=}
                echo "Specified stop threshold with '--stop=${STOP_THRESHOLD}'" >&2;
                ;;
            *)
                if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then
                    echo "Unknown option --${OPTARG}" >&2
                fi
                ;;
        esac;;
    s)
      SHOW="true"
      ;;
    v)
      VERBOSE="true"
      ;;
    \?)
      echo "Invalid option: -$OPTARG"
      USAGE="true"
      ;;
    :)
      echo "Option -$OPTARG requires an argument."
      USAGE="true"
      ;;
  esac
done

if [ -n "${START_THRESHOLD}" ]; then
  if [ -z "${STOP_THRESHOLD}" ]; then
    STOP_THRESHOLD=$(__get_acpi_value "${GET_STOP}")
  fi
  __update_thresholds
elif [ -n "${STOP_THRESHOLD}" ]; then
  if [ -z "${START_THRESHOLD}" ]; then
    START_THRESHOLD=$(__get_acpi_value "${GET_START}")
  fi
  __update_thresholds
fi

if [ "${SHOW}" = "true" ]; then
  if [ "${VERBOSE}" = "true" ]; then
    __show_verbose
  else
    __show
  fi
fi

if [ "${USAGE}" = "true" ]; then
  __usage
fi

exit 0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|--show)
            SHOW="true"
            shift 1
            ;;
        -v|--verbose)
            VERBOSE="true"
            shift 1
            ;;
        *)
            echo "Unknown option: $1"
            shift 1
            ;;
    esac
done

if [ "${SHOW}" = "true" ]; then
  if [ "${VERBOSE}" = "true" ]; then
    __show_verbose
  else
    __show
  fi
fi

exit 0

case "${1}" in
  (-d)            __show_verbose ;;
  (--diagnostics) __show_verbose ;;
  (-s)            __show ;;
  (--show)        __show ;;
  (-t)            __update_thresholds ;;
  (--thresholds)  __update_thresholds ;;
  (*)  __usage ;;
esac

echo

exit 0

# Copyright (C) 2023 Dr.Amr Osman, consultant of cardiology 
# License-Identifier: BSD-3-Clause
