#!/sbin/sh
# SPDX-FileCopyrightText: (c) 2022 ale5000
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileType: SOURCE

override_applet()
{
  # shellcheck disable=SC2139
  alias "${1}"="${OVERRIDE_DIR:?}/${1}"  # This expands when defined, not when used (it is intended)
  return "${?}"
}

unset OUR_TEMP_DIR
unset BB_GLOBBING
unset FUNCNAME
unset HOSTNAME
unset LINENO
unset OPTIND
unset OLDPWD

IFS=' 	
'
PS1='\w \$ '
PS2='> '
PS4='+ '

# Ensure that the overridden commands are preferred over BusyBox applets
export BB_OVERRIDE_APPLETS='mount umount chown' || exit 125
override_applet mount || exit 124
override_applet umount || exit 124
override_applet chown || exit 124

unset -f override_applet
unset OVERRIDE_DIR

export TEST_INSTALL=true

# shellcheck source=SCRIPTDIR/../zip-content/META-INF/com/google/android/update-binary.sh
. "${TMPDIR:?}/update-binary" || exit "${?}"
