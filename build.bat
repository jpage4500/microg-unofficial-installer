@REM SPDX-FileCopyrightText: (c) 2016-2019, 2021 ale5000
@REM SPDX-License-Identifier: GPL-3.0-or-later
@REM SPDX-FileType: SOURCE

@echo off

SETLOCAL 2> nul
CHCP 858 >nul || ECHO "Changing the codepage failed"
"%~dp0tools\win\busybox.exe" sh "%~dp0build.sh" %*
ENDLOCAL 2> nul
SET "EXIT_CODE=%ERRORLEVEL%"

IF NOT "%~1" == "Gradle" PAUSE > nul

IF %EXIT_CODE% NEQ 0 EXIT /B %EXIT_CODE%
SET "EXIT_CODE="