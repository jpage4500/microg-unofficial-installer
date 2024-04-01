#!/usr/bin/env sh
# @name Android device profile generator
# @brief It can automatically generate a device profile (usable by microG) from a device connected via adb.
# @author ale5000
# Get the latest version from here: https://github.com/micro5k/microg-unofficial-installer/tree/main/utils

# SPDX-FileCopyrightText: (c) 2023 ale5000
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileType: SOURCE

# shellcheck disable=SC3043 # In POSIX sh, local is undefined

set -u
# shellcheck disable=SC3040,SC3041,SC2015
{
  # Unsupported set options may cause the shell to exit (even without set -e), so first try them in a subshell to avoid this issue
  (set -o posix 2> /dev/null) && set -o posix || true
  (set +H 2> /dev/null) && set +H || true
  (set -o pipefail) && set -o pipefail || true
}

readonly SCRIPT_NAME='Android device profile generator'
readonly SCRIPT_SHORTNAME='Device ProfGen'
readonly SCRIPT_VERSION='1.7'

{
  readonly xml_comment_start='<!--' # Workaround for history substitution of Bash: don't insert ! directly in the printf but use a variable.
  readonly xml_comment_end='-->'
}

show_status_msg()
{
  printf 1>&2 '\033[1;32m%s\033[0m\n' "${*}"
}

show_warn()
{
  printf 1>&2 '\033[0;33m%s\033[0m\n' "WARNING: ${*}"
}

show_error()
{
  printf 1>&2 '\033[1;31m%s\033[0m\n' "ERROR: ${*}"
}

show_negative_info()
{
  printf 1>&2 '\033[1;32m%s\033[1;31m%s\033[0m\n' "${1:?}" "${2:?}"
}

pause_if_needed()
{
  # shellcheck disable=SC3028 # In POSIX sh, SHLVL is undefined
  if test "${CI:-false}" = 'false' && test "${SHLVL:-}" = '1' && test -t 0 && test -t 1 && test -t 2; then
    printf 1>&2 '\n\033[1;32m%s\033[0m' 'Press any key to exit...' || true
    # shellcheck disable=SC3045
    IFS='' read 1>&2 -r -s -n 1 _ || true
    printf 1>&2 '\n' || true
  fi
}

verify_adb()
{
  if command -v adb 1> /dev/null; then
    return 0
  fi

  if test "${OS:-}" = 'Windows_NT'; then
    # Set the path of Android SDK if not already set
    if test -z "${ANDROID_SDK_ROOT:-}" && test -n "${LOCALAPPDATA:-}" && test -e "${LOCALAPPDATA:?}/Android/Sdk"; then
      export ANDROID_SDK_ROOT="${LOCALAPPDATA:?}/Android/Sdk"
    fi
  fi

  if test -n "${ANDROID_SDK_ROOT:-}"; then
    local _pathsep
    if test "$(uname -o 2> /dev/null | LC_ALL=C tr '[:upper:]' '[:lower:]' || true)" = 'ms/windows'; then
      _pathsep=';' # BusyBox-w32
    else
      _pathsep=':' # Other shells on Windows
    fi

    # shellcheck disable=SC2123
    export PATH="${ANDROID_SDK_ROOT:?}/platform-tools${_pathsep:?}${PATH}"

    if command -v adb 1> /dev/null; then
      return 0
    fi
  fi

  show_error 'adb is NOT available'
  pause_if_needed
  exit 1
}

start_adb_server()
{
  adb 2> /dev/null 'start-server' || true
}

adb_get_serial()
{
  adb 'get-serialno'
}

is_recovery()
{
  if test "$(adb 2> /dev/null -s "${1:?}" 'get-state' || true)" = 'recovery'; then
    return 0
  fi
  return 1
}

verify_device_status()
{
  if is_recovery "${1:?}"; then
    DEVICE_IN_RECOVERY='true'
  else
    DEVICE_IN_RECOVERY='false'
  fi
}

wait_connection()
{
  show_status_msg 'Waiting for the device...'
  if test "${DEVICE_IN_RECOVERY:?}" = 'true'; then
    adb -s "${1:?}" 'wait-for-recovery'
  else
    adb -s "${1:?}" 'wait-for-device'
  fi
}

is_all_zeros()
{
  if test -n "${1?}" && test "$(printf '%s\n' "${1:?}" | LC_ALL=C tr -d '0' || true)" = ''; then
    return 0 # True
  fi

  return 1 # False
}

is_valid_value()
{
  # ${2:-0} => 2 (Allow empty value)

  if test -z "${1?}" && test "${2:-0}" != '2'; then return 1; fi
  if test "${1?}" = 'unknown'; then return 1; fi

  return 0 # Valid
}

lc_text()
{
  printf '%s' "${1?}" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

uc_text()
{
  printf '%s' "${1?}" | LC_ALL=C tr '[:lower:]' '[:upper:]'
}

uc_first_char()
{
  printf '%s' "${1?}" | cut -c '1' | LC_ALL=C tr -d '\r\n' | LC_ALL=C tr '[:lower:]' '[:upper:]'
  printf '%s\n' "${1?}" | cut -c '2-'
}

convert_time_to_human_readable_form()
{
  LC_ALL=C date -u -d "@${1:?}" '+%a %b %d %H:%M:%S %Z %Y'
}

compare_nocase()
{
  if test "$(lc_text "${1?}" || true)" = "$(lc_text "${2?}" || true)"; then
    return 0 # True
  fi

  return 1 # False
}

contains_nocase()
{
  local _val_1 _val_2
  _val_1="$(lc_text "${1?}")"
  _val_2="$(lc_text "${2?}")"

  case "${_val_2?}" in
    *"${_val_1:?}"*) return 0 ;; # Found
    *) ;;
  esac
  return 1 # NOT found
}

is_string_nocase_starting_with()
{
  local _val_1 _val_2
  _val_1="$(lc_text "${1?}")"
  _val_2="$(lc_text "${2?}")"

  case "${_val_2?}" in
    "${_val_1:?}"*) return 0 ;; # Found
    *) ;;
  esac
  return 1 # NOT found
}

is_valid_serial()
{
  if test "${#1}" -lt 2 || is_all_zeros "${1:?}" || is_string_nocase_starting_with 'EMULATOR' "${1:?}"; then
    return 1 # NOT valid
  fi

  return 0 # Valid
}

device_getprop()
{
  adb -s "${1:?}" shell "getprop '${2:?}'" | LC_ALL=C tr -d '\r'
}

getprop_output_parse()
{
  local _value

  # Return success even if the property isn't found, it will be checked later
  _value="$(grep -m 1 -e "^\[${2:?}\]\:" "${1:?}" | LC_ALL=C tr -d '[:cntrl:]' | cut -d ':' -f '2-' -s | grep -m 1 -o -e '^[[:blank:]]\[.*\]$')" || return 0
  if test "${#_value}" -gt 3; then
    printf '%s' "${_value?}" | cut -c "3-$((${#_value} - 1))"
  fi
}

prop_output_parse()
{
  local _value

  # Return success even if the property isn't found, it will be checked later
  grep -m 1 -e "^${2:?}=" "${1:?}" | LC_ALL=C tr -d '[:cntrl:]' | cut -d '=' -f '2-' -s || return 0
}

chosen_getprop()
{
  local _val

  if test "${INPUT_TYPE:?}" = 'adb'; then
    _val="$(device_getprop "${SELECTED_DEVICE:?}" "${@}")" || return 1
  elif test "${PROP_TYPE:?}" = '1'; then
    _val="$(getprop_output_parse "${INPUT_TYPE:?}" "${@}")" || return 1
  else
    _val="$(prop_output_parse "${INPUT_TYPE:?}" "${@}")" || return 1
  fi

  if test -z "${_val?}" || test "${_val:?}" = 'unknown'; then
    return 2
  fi

  printf '%s\n' "${_val:?}"
  return 0
}

validated_chosen_getprop()
{
  local _value
  if ! _value="$(chosen_getprop "${1:?}")" || ! is_valid_value "${_value?}" "${2:-}"; then
    show_error "Invalid value for ${1:-}"
    return 1
  fi

  printf '%s\n' "${_value?}"
}

is_boot_completed()
{
  if test "${DEVICE_IN_RECOVERY:?}" = 'true' || test "$(chosen_getprop 'sys.boot_completed' || true)" = '1'; then
    return 0
  fi

  return 1
}

check_boot_completed()
{
  is_boot_completed || {
    show_error 'The device has not finished booting yet!!!'
    pause_if_needed
    exit 1
  }
}

get_and_check_prop()
{
  local _val

  if _val="$(chosen_getprop "${@}")" && is_valid_value "${_val?}"; then
    printf '%s' "${_val:?}"
    return 0
  fi
  return 1
}

get_mod_version()
{
  local _val

  if _val="$(chosen_getprop 'ro.modversion')" && test -n "${_val?}" && test "${_val:?}" != 'xiaomi''.eu_miui''os''.cz_miui''polska''.pl'; then
    :
  elif _val="$(chosen_getprop 'ro.mod.version')" && test -n "${_val?}"; then
    :
  else
    return 1
  fi

  printf '%s\n' "${_val:?}" | cut -d 'v' -f '2-'
  return 0
}

generate_rom_info()
{
  local _mod_version
  local _real_build_time _verify_emulator _temp_value
  _verify_emulator='false'

  ROM_VERSION=''
  ROM_INFO='unknown'
  IS_EMU='false'
  EMU_NAME=''
  REAL_SECURITY_PATCH=''

  _mod_version="$(get_mod_version)"

  if ROM_VERSION="$(get_and_check_prop 'ro.rr.version')"; then
    if test -n "${_mod_version?}"; then
      ROM_VERSION="${_mod_version?}"
    else
      ROM_VERSION="$(printf '%s\n' "${ROM_VERSION?}" | cut -d 'v' -f '2-')"
    fi
    ROM_INFO="Resurrection Remix v${ROM_VERSION?} - ${BUILD_VERSION_RELEASE?}"
  elif ROM_VERSION="$(get_and_check_prop 'ro.du.version')"; then
    if test -n "${_mod_version?}"; then
      ROM_VERSION="${_mod_version?}"
    else
      ROM_VERSION="$(printf '%s\n' "${ROM_VERSION?}" | cut -d 'v' -f '2-')"
    fi
    ROM_INFO="Dirty Unicorns v${ROM_VERSION?} - ${BUILD_VERSION_RELEASE?}"
  elif ROM_VERSION="$(get_and_check_prop 'ro.lineage.build.version')" || ROM_VERSION="$(get_and_check_prop 'ro.cm.build.version')" || ROM_VERSION="$(get_and_check_prop 'ro.lineage.version')" || ROM_VERSION="$(get_and_check_prop 'ro.cm.version')"; then
    if _temp_value="$(chosen_getprop 'ro.elegal.url')" && test -n "${_temp_value?}"; then
      ROM_INFO="/e/ OS v${ROM_VERSION:?} - ${BUILD_VERSION_RELEASE?}"
    elif compare_nocase "$(chosen_getprop 'ro.lineage.releasetype' || true)" 'microG'; then
      ROM_INFO="LineageOS for microG v${ROM_VERSION:?} - ${BUILD_VERSION_RELEASE?}"
    else
      ROM_INFO="LineageOS v${ROM_VERSION:?} - ${BUILD_VERSION_RELEASE?}"
    fi
  elif test -n "${_mod_version?}"; then
    ROM_VERSION="${_mod_version?}"
    ROM_INFO="Android MOD v${ROM_VERSION?} - ${BUILD_VERSION_RELEASE?}"
  elif ROM_VERSION="$(get_and_check_prop 'ro.miui.ui.version.name')"; then # Xiaomi
    if _temp_value="$(chosen_getprop 'ro.build.version.incremental')" && _temp_value="$(printf '%s\n' "${_temp_value?}" | grep -m 1 -o -e 'V[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*' | cut -d 'V' -f '2-' -s)" && test -n "${_temp_value?}"; then
      _temp_value="${_temp_value%.}"
      ROM_VERSION="${_temp_value:?}"
    else
      ROM_VERSION="$(printf '%s\n' "${ROM_VERSION:?}" | cut -d 'V' -f '2-')"
    fi
    ROM_INFO="MIUI v${ROM_VERSION:?} - ${BUILD_VERSION_RELEASE?}"
  elif ROM_VERSION="$(get_and_check_prop 'ro.build.version.emui')"; then # Huawei
    ROM_VERSION="$(printf '%s\n' "${ROM_VERSION:?}" | cut -d '_' -f '2-')"
    ROM_INFO="EMUI v${ROM_VERSION:?} - ${BUILD_VERSION_RELEASE?}"

    if _real_build_time="$(get_and_check_prop 'ro.huawei.build.date.utc')"; then
      TEXT_BUILD_TIME_HUMAN="${TEXT_BUILD_TIME_HUMAN?} - Real: $(convert_time_to_human_readable_form "${_real_build_time:?}")"
    fi

    if REAL_SECURITY_PATCH="$(get_and_check_prop 'ro.huawei.build.version.security_patch')"; then
      REAL_SECURITY_PATCH=" ${xml_comment_start:?} Real security patch: ${REAL_SECURITY_PATCH:-} ${xml_comment_end:?}"
    fi
  else
    ROM_VERSION=''
    ROM_INFO="Android ${BUILD_VERSION_RELEASE?}"
    _verify_emulator='true'
  fi

  if test "${_verify_emulator?}" = 'true'; then
    if EMU_NAME="$(chosen_getprop 'ro.boot.qemu.avd_name' | LC_ALL=C tr -- '_' ' ')" && test -n "${EMU_NAME?}"; then
      IS_EMU='true'
    elif EMU_NAME="$(chosen_getprop 'ro.kernel.qemu.avd_name' | LC_ALL=C tr -- '_' ' ')" && test -n "${EMU_NAME?}"; then
      IS_EMU='true'
    elif LEAPD_VERSION="$(chosen_getprop 'ro.leapdroid.version')" && test -n "${LEAPD_VERSION?}"; then
      IS_EMU='true'
      EMU_NAME='Leapdroid'
    else
      EMU_NAME=''
    fi
  fi
}

parse_devices_list()
{
  local _file

  if test "${EMU_NAME?}" = 'Leapdroid'; then return 2; fi

  # shellcheck disable=SC3028
  if test -n "${UTILS_DATA_DIR:-}" && test -e "${UTILS_DATA_DIR:?}/device-list.csv"; then
    _file="${UTILS_DATA_DIR:?}/device-list.csv"
  elif test -n "${BASH_SOURCE:-}" && _file="$(dirname "${BASH_SOURCE:?}")/data/device-list.csv" && test -e "${_file:?}"; then # Expanding an array without an index gives the first element (it is intended)
    :
  elif test -n "${0:-}" && _file="$(dirname "${0:?}")/data/device-list.csv" && test -e "${_file:?}"; then
    :
  elif test -e './data/device-list.csv'; then
    _file='./data/device-list.csv'
  elif test -e './device-list.csv'; then
    _file='./device-list.csv'
  else
    show_warn 'THE DEVICE LIST IS MISSING! Use dl-device-list.sh'
    return 99
  fi

  if grep -m 1 -i -e "^${BUILD_MANUFACTURER?},.*,${BUILD_DEVICE?},${BUILD_MODEL?}$" -- "${_file:?}" | cut -d ',' -f '2' -s; then
    return 0
  elif grep -m 1 -i -e "^${BUILD_BRAND?},.*,${BUILD_DEVICE?},${BUILD_MODEL?}$" -- "${_file:?}" | cut -d ',' -f '2' -s; then
    return 1
  fi

  return 2
}

generate_device_info()
{
  local _info _lenovo_device_name

  if is_valid_value "${MARKETING_DEVICE_INFO?}"; then
    _info="$(uc_first_char "${MARKETING_DEVICE_INFO:?}")"
  elif test "${OFFICIAL_STATUS:?}" -le 1 && is_valid_value "${OFFICIAL_DEVICE_INFO?}" && ! contains_nocase "${OFFICIAL_DEVICE_INFO:?}" "${BUILD_MODEL?}"; then
    _info="${OFFICIAL_DEVICE_INFO?}"
  elif compare_nocase "${BUILD_MANUFACTURER?}" 'Lenovo' && _lenovo_device_name="$(chosen_getprop 'ro.lenovo.series')" && is_valid_value "${_lenovo_device_name?}"; then
    _info="$(uc_first_char "${_lenovo_device_name:?}")"
  elif is_valid_value "${BUILD_MODEL?}"; then
    _info="${BUILD_MODEL?}"
  else
    _info="${BUILD_DEVICE?}"
  fi

  if test -n "${BUILD_BRAND?}" && ! contains_nocase " ${BUILD_BRAND:?} " " ${_info?} " && ! compare_nocase "${BUILD_BRAND:?}" 'Android'; then
    _info="$(uc_first_char "${BUILD_BRAND:?}") ${_info?}"
  fi

  if test -n "${BUILD_MANUFACTURER?}" && ! contains_nocase " ${BUILD_MANUFACTURER:?} " " ${_info?} "; then
    _info="${BUILD_MANUFACTURER:?} ${_info?}"
  fi

  printf '%s\n' "$(uc_first_char "${_info?}" || true)" | sed 's/"/\&quot;/g'
}

find_bootloader()
{
  local _val

  if _val="$(chosen_getprop 'ro.bootloader')" && is_valid_value "${_val?}"; then
    :
  elif _val="$(chosen_getprop 'ro.boot.bootloader')" && is_valid_value "${_val?}"; then
    :
  else
    show_warn 'Build.BOOTLOADER not found'
    printf '%s' 'unknown'
    return 1
  fi

  printf '%s' "${_val?}"
}

find_hardware()
{
  local _val

  if _val="$(chosen_getprop 'ro.hardware')" && is_valid_value "${_val?}"; then
    :
  elif _val="$(chosen_getprop 'ro.boot.hardware')" && is_valid_value "${_val?}"; then
    :
  else
    show_warn 'Build.HARDWARE not found'
    printf '%s' 'unknown'
    return 1
  fi

  printf '%s' "${_val?}"
}

find_radio()
{
  local _val

  if _val="$(chosen_getprop 'gsm.version.baseband')" && is_valid_value "${_val?}"; then
    :
  elif _val="$(chosen_getprop 'ril.sw_ver')" && is_valid_value "${_val?}"; then
    :
  elif _val="$(chosen_getprop 'ro.boot.radio')" && is_valid_value "${_val?}"; then
    :
  elif _val="$(chosen_getprop 'ro.baseband')" && is_valid_value "${_val?}"; then
    :
  elif _val="$(chosen_getprop 'ro.boot.baseband')" && is_valid_value "${_val?}"; then
    :
  else
    show_warn 'Build.RADIO not found'
    printf '%s' 'unknown'
    return 1
  fi

  printf '%s' "${_val?}"
}

find_serialno()
{
  local _val

  if compare_nocase "${BUILD_MANUFACTURER?}" 'Lenovo' && _val="$(chosen_getprop 'ro.lenovosn2')" && is_valid_serial "${_val?}"; then # Lenovo tablets
    :
  elif _val="$(chosen_getprop 'ril.serialnumber')" && is_valid_serial "${_val?}"; then # Samsung phones / tablets (possibly others)
    :
  elif _val="$(chosen_getprop 'ro.ril.oem.psno')" && is_valid_serial "${_val?}"; then # Xiaomi phones (possibly others)
    :
  elif _val="$(chosen_getprop 'ro.ril.oem.sno')" && is_valid_serial "${_val?}"; then # Xiaomi phones (possibly others)
    :
  elif _val="$(chosen_getprop 'ro.serialno')" && is_valid_serial "${_val?}"; then
    :
  elif _val="$(chosen_getprop 'sys.serialnumber')" && is_valid_serial "${_val?}"; then
    :
  elif _val="$(chosen_getprop 'ro.boot.serialno')" && is_valid_serial "${_val?}"; then
    :
  elif _val="$(chosen_getprop 'ro.kernel.androidboot.serialno')" && is_valid_serial "${_val?}"; then
    :
  else
    show_warn 'Serial number not found'
    return 1
  fi

  printf '%s' "${_val?}"
}

anonymize_string()
{
  printf '%s' "${1?}" | LC_ALL=C tr '[:digit:]' '0' | LC_ALL=C tr 'a-f' 'f' | LC_ALL=C tr 'g-z' 'x' | LC_ALL=C tr 'A-F' 'F' | LC_ALL=C tr 'G-Z' 'X'
}

anonymize_serialno()
{
  local _string _prefix_length

  if test "${#1}" -lt 2; then
    show_error 'Invalid serial number'
    return 1
  fi

  _prefix_length="$((${#1} / 2))"
  if test "${_prefix_length:?}" -gt 6; then _prefix_length='6'; fi

  printf '%s' "${1:?}" | cut -c "-${_prefix_length:?}" | LC_ALL=C tr -d '[:cntrl:]'

  _string="$(printf '%s' "${1:?}" | cut -c "$((${_prefix_length:?} + 1))-" | LC_ALL=C tr -d '[:cntrl:]')"
  anonymize_string "${_string:?}"
}

main()
{
  if test "${#}" -gt 0; then
    INPUT_TYPE="${1:?}"
  else
    INPUT_TYPE='adb'
  fi

  if test "${INPUT_TYPE:?}" = 'adb'; then
    verify_adb
    start_adb_server
    SELECTED_DEVICE="$(adb_get_serial)" || {
      show_error 'Failed to get the selected device'
      pause_if_needed
      exit 1
    }
    verify_device_status "${SELECTED_DEVICE:?}"
    if test "${DEVICE_IN_RECOVERY:?}" = 'true'; then
      show_error "Recovery isn't currently supported"
      pause_if_needed
      exit 1
    fi
    wait_connection "${SELECTED_DEVICE:?}"
    show_status_msg 'Generating profile...'
    check_boot_completed
  else
    test -e "${INPUT_TYPE:?}" || {
      show_error "Input file doesn't exist => '${INPUT_TYPE:-}'"
      pause_if_needed
      exit 1
    }

    show_status_msg 'Generating profile...'
    if grep -m 1 -q -e '^\[.*\]\:[[:blank:]]\[.*\]' -- "${INPUT_TYPE:?}"; then
      PROP_TYPE='1'
      DEVICE_IN_RECOVERY='false'
      check_boot_completed
    else
      PROP_TYPE='2'
      show_error 'Profiles generated in this way will be incomplete!!!'
    fi
  fi

  # Infos:
  # - https://github.com/microg/GmsCore/blob/master/play-services-base/core/src/main/kotlin/org/microg/gms/profile/ProfileManager.kt
  # - https://android.googlesource.com/platform/frameworks/base/+/refs/heads/master/core/java/android/os/Build.java
  # - https://developer.android.com/reference/android/os/Build

  BUILD_BRAND="$(validated_chosen_getprop 'ro.product.brand')"
  BUILD_MANUFACTURER="$(validated_chosen_getprop 'ro.product.manufacturer')"
  BUILD_DEVICE="$(validated_chosen_getprop 'ro.product.device')" || BUILD_DEVICE="$(chosen_getprop 'ro.build.product')" || BUILD_DEVICE=""
  BUILD_MODEL="$(validated_chosen_getprop 'ro.product.model')"
  BUILD_VERSION_RELEASE="$(validated_chosen_getprop 'ro.build.version.release')"

  TEXT_BUILD_TIME_HUMAN=''
  if BUILD_TIME="$(validated_chosen_getprop 'ro.build.date.utc')"; then
    TEXT_BUILD_TIME_HUMAN="$(convert_time_to_human_readable_form "${BUILD_TIME:?}")"
    BUILD_TIME="${BUILD_TIME:?}000"
  fi

  generate_rom_info

  TEXT_OFFICIAL_STATUS=''
  OFFICIAL_STATUS=0
  OFFICIAL_DEVICE_INFO="$(parse_devices_list)" || OFFICIAL_STATUS="${?}"
  case "${OFFICIAL_STATUS:?}" in
    0 | 1)
      show_status_msg 'Device certified: YES'
      TEXT_OFFICIAL_STATUS=" ${xml_comment_start:?} Device certified: YES (${OFFICIAL_STATUS:?}) ${xml_comment_end:?}"
      ;;
    2)
      show_negative_info 'Device certified: ' 'NO'
      TEXT_OFFICIAL_STATUS=" ${xml_comment_start:?} Device certified: NO ${xml_comment_end:?}"
      ;;
    *) ;;
  esac

  BUILD_BOARD="$(validated_chosen_getprop 'ro.product.board')"

  BUILD_BOOTLOADER="$(find_bootloader)"
  BUILD_BOOTLOADER_EXPECT="$(chosen_getprop 'ro.build.expect.bootloader')" || BUILD_BOOTLOADER_EXPECT=''
  if is_valid_value "${BUILD_BOOTLOADER_EXPECT?}" && test "${BUILD_BOOTLOADER_EXPECT?}" != "${BUILD_BOOTLOADER?}"; then
    show_warn "Build.BOOTLOADER does NOT match, current: ${BUILD_BOOTLOADER:-}, expected: ${BUILD_BOOTLOADER_EXPECT:-}"
  fi

  BUILD_CPU_ABI="$(validated_chosen_getprop 'ro.product.cpu.abi')"
  BUILD_CPU_ABI2="$(validated_chosen_getprop 'ro.product.cpu.abi2' 2)"
  BUILD_DISPLAY="$(validated_chosen_getprop 'ro.build.display.id')"
  BUILD_FINGERPRINT="$(validated_chosen_getprop 'ro.build.fingerprint')"
  BUILD_HARDWARE="$(find_hardware)"
  BUILD_HOST="$(validated_chosen_getprop 'ro.build.host')"
  BUILD_ID="$(validated_chosen_getprop 'ro.build.id')"
  BUILD_PRODUCT="$(validated_chosen_getprop 'ro.product.name')" || BUILD_PRODUCT='unknown'

  BUILD_RADIO="$(find_radio)"
  BUILD_RADIO_EXPECT="$(chosen_getprop 'ro.build.expect.baseband')" || BUILD_RADIO_EXPECT=''
  if is_valid_value "${BUILD_RADIO_EXPECT?}" && test "${BUILD_RADIO_EXPECT?}" != "${BUILD_RADIO?}"; then
    show_warn "Build.RADIO does NOT match, current: ${BUILD_RADIO:-}, expected: ${BUILD_RADIO_EXPECT:-}"
  fi

  BUILD_TAGS="$(validated_chosen_getprop 'ro.build.tags')"

  BUILD_TYPE="$(validated_chosen_getprop 'ro.build.type')"
  BUILD_USER="$(validated_chosen_getprop 'ro.build.user')"
  BUILD_VERSION_CODENAME="$(validated_chosen_getprop 'ro.build.version.codename')"
  BUILD_VERSION_INCREMENTAL="$(validated_chosen_getprop 'ro.build.version.incremental')"
  BUILD_VERSION_SECURITY_PATCH="$(validated_chosen_getprop 'ro.build.version.security_patch' 2)"
  BUILD_VERSION_SDK="$(validated_chosen_getprop 'ro.build.version.sdk')" # ToDO: If not numeric or empty return 0
  BUILD_VERSION_DEVICE_INITIAL_SDK_INT="$(chosen_getprop 'ro.product.first_api_level')"
  BUILD_SUPPORTED_ABIS="$(validated_chosen_getprop 'ro.product.cpu.abilist' 2)" # ToDO: Auto-generate it if missing

  BUILD_DESCRIPTION="$(validated_chosen_getprop 'ro.build.description')"
  TEXT_ADDITIONAL_INFO="ro.build.description: ${BUILD_DESCRIPTION?}"

  ANON_SERIAL_NUMBER=''
  if SERIAL_NUMBER="$(find_serialno)"; then
    show_status_msg "Serial number: ${SERIAL_NUMBER:-}"
    ANON_SERIAL_NUMBER="$(anonymize_serialno "${SERIAL_NUMBER:?}")"
  fi

  XML_ID="${BUILD_PRODUCT:?}_${BUILD_VERSION_SDK:?}"

  if test "${IS_EMU:?}" = 'true'; then
    DEVICE_INFO="Emulator - ${EMU_NAME?}"
    XML_ID="emu_${XML_ID:?}"
  else
    MARKETING_DEVICE_INFO="$(chosen_getprop 'ro.config.marketing_name')" || MARKETING_DEVICE_INFO=''
    DEVICE_INFO="$(generate_device_info)"
  fi

  printf 1>&2 '\n'
  printf '%s\n' "<?xml version=\"1.0\" encoding=\"utf-8\"?>
${xml_comment_start:?}
    SPDX-FileCopyrightText: none
    SPDX-License-Identifier: CC0-1.0
${xml_comment_end:?}

<profile name=\"${DEVICE_INFO?} (${ROM_INFO:?})\" product=\"${BUILD_PRODUCT:?}\" sdk=\"${BUILD_VERSION_SDK:?}\" id=\"${XML_ID:?}\" auto=\"true\">
    ${xml_comment_start:?} Generated by ${SCRIPT_SHORTNAME:?} v${SCRIPT_VERSION:?} of ale5000 ${xml_comment_end:?}${TEXT_OFFICIAL_STATUS?}
    <data key=\"Build.BOARD\" value=\"${BUILD_BOARD?}\" />
    <data key=\"Build.BOOTLOADER\" value=\"${BUILD_BOOTLOADER?}\" />
    <data key=\"Build.BRAND\" value=\"${BUILD_BRAND?}\" />
    <data key=\"Build.CPU_ABI\" value=\"${BUILD_CPU_ABI?}\" />
    <data key=\"Build.CPU_ABI2\" value=\"${BUILD_CPU_ABI2?}\" />
    <data key=\"Build.DEVICE\" value=\"${BUILD_DEVICE?}\" />
    ${xml_comment_start:?} ${TEXT_ADDITIONAL_INFO?} ${xml_comment_end:?}
    <data key=\"Build.DISPLAY\" value=\"${BUILD_DISPLAY?}\" />
    <data key=\"Build.FINGERPRINT\" value=\"${BUILD_FINGERPRINT?}\" />
    <data key=\"Build.HARDWARE\" value=\"${BUILD_HARDWARE?}\" />
    <data key=\"Build.HOST\" value=\"${BUILD_HOST?}\" />
    <data key=\"Build.ID\" value=\"${BUILD_ID?}\" />
    <data key=\"Build.MANUFACTURER\" value=\"${BUILD_MANUFACTURER?}\" />
    <data key=\"Build.MODEL\" value=\"${BUILD_MODEL?}\" />
    <data key=\"Build.PRODUCT\" value=\"${BUILD_PRODUCT:?}\" />
    <data key=\"Build.RADIO\" value=\"${BUILD_RADIO?}\" />
    <data key=\"Build.TAGS\" value=\"${BUILD_TAGS?}\" />
    <data key=\"Build.TIME\" value=\"${BUILD_TIME?}\" /> ${xml_comment_start:?} ${TEXT_BUILD_TIME_HUMAN?} ${xml_comment_end:?}
    <data key=\"Build.TYPE\" value=\"${BUILD_TYPE?}\" />
    <data key=\"Build.USER\" value=\"${BUILD_USER?}\" />
    <data key=\"Build.VERSION.CODENAME\" value=\"${BUILD_VERSION_CODENAME?}\" />
    <data key=\"Build.VERSION.INCREMENTAL\" value=\"${BUILD_VERSION_INCREMENTAL?}\" />
    <data key=\"Build.VERSION.RELEASE\" value=\"${BUILD_VERSION_RELEASE?}\" />
    <data key=\"Build.VERSION.SECURITY_PATCH\" value=\"${BUILD_VERSION_SECURITY_PATCH?}\" />${REAL_SECURITY_PATCH?}
    <data key=\"Build.VERSION.SDK\" value=\"${BUILD_VERSION_SDK:?}\" />
    <data key=\"Build.VERSION.SDK_INT\" value=\"${BUILD_VERSION_SDK:?}\" />
    <data key=\"Build.VERSION.DEVICE_INITIAL_SDK_INT\" value=\"${BUILD_VERSION_DEVICE_INITIAL_SDK_INT?}\" />
    <data key=\"Build.SUPPORTED_ABIS\" value=\"${BUILD_SUPPORTED_ABIS?}\" />

    <serial template=\"${ANON_SERIAL_NUMBER?}\" />
</profile>"
}

show_status_msg "${SCRIPT_NAME:?} v${SCRIPT_VERSION:?} by ale5000"
if test "${#}" -gt 0; then
  main "${@}"
else
  main
fi
pause_if_needed
