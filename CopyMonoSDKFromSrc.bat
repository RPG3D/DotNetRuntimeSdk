@echo off
rem CopySDKFromSrc.bat
rem Copy Mono SDK artifacts from dotnet/runtime build output into this SDK
rem repository's platform subdirectory (Win64).
rem
rem This script does NOT build dotnet/runtime - it only copies pre-built artifacts.
rem Use this in CI workflows where the build step is done separately.
rem
rem Usage:
rem   CopySDKFromSrc.bat <dotnet-src-dir> [build-type]
rem
rem Arguments:
rem   dotnet-src-dir   Path to the dotnet/runtime repository root (must be already built).
rem   build-type       Debug (default) | Release
rem
rem Example:
rem   CopySDKFromSrc.bat C:\Code\DotNet
rem   CopySDKFromSrc.bat C:\Code\DotNet Release

setlocal enabledelayedexpansion

rem -- Arguments -------------------------------------------------------------------
if "%~1"=="" (
    echo Error: dotnet source directory is required. >&2
    echo Usage: %~nx0 ^<dotnet-src-dir^> [build-type] >&2
    exit /b 1
)

set "DOTNET_SRC=%~f1"
set "SDK_DIR=%~dp0"
rem Remove trailing backslash from SDK_DIR
if "%SDK_DIR:~-1%"=="\" set "SDK_DIR=%SDK_DIR:~0,-1%"

rem Build type: Debug (default) or Release
set "BUILD_TYPE_RAW=%~2"
if "%BUILD_TYPE_RAW%"=="" set "BUILD_TYPE_RAW=Debug"
echo %BUILD_TYPE_RAW% | findstr /i "Debug Release" >nul
if errorlevel 1 (
    echo Error: unknown build-type '%BUILD_TYPE_RAW%'. Use Debug or Release. >&2
    exit /b 1
)
rem Normalize to title-case (Debug / Release)
set "BUILD_TYPE=Debug"
if /i "%BUILD_TYPE_RAW%"=="Release" set "BUILD_TYPE=Release"

set "PLATFORM=Win64"

echo === CopySDKFromSrc ===
echo   Source    : %DOTNET_SRC%
echo   Platform  : %PLATFORM%
echo   Build type: %BUILD_TYPE%
echo   SDK dir   : %SDK_DIR%
echo.

rem -- Copy artifacts --------------------------------------------------------------
rem SDK directory layout:
rem   MonoSDK\
rem     Win64\  include\  lib\  bin\  runtime\
rem     include\  (shared mono headers)

set "SRC_ARTIFACTS=%DOTNET_SRC%\artifacts"
set "MONO_TRIPLE=windows.x64.%BUILD_TYPE%"
set "RUNTIME_TFM=net10.0-windows-%BUILD_TYPE%-x64"
set "DEST=%SDK_DIR%\Win64"

if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%"

echo ^>^>^> Copying artifacts into SDK directory...

rem Use robocopy for reliable copy (handles nested dirs correctly)
rem Note: robocopy returns exit codes 0-7 (all indicate success); code >=8 is error.
rem /NFL /NDL suppress file/directory listing for cleaner CI logs.

set "ROBOCOPY_ERROR=0"

robocopy "%SRC_ARTIFACTS%\obj\mono\%MONO_TRIPLE%\out\include\mono-2.0" "%DEST%\include" /E /NFL /NDL
if errorlevel 8 set "ROBOCOPY_ERROR=1"

robocopy "%SRC_ARTIFACTS%\obj\mono\%MONO_TRIPLE%\out\lib" "%DEST%\lib" /E /NFL /NDL
if errorlevel 8 set "ROBOCOPY_ERROR=1"

robocopy "%SRC_ARTIFACTS%\obj\mono\%MONO_TRIPLE%\out\bin" "%DEST%\bin" /E /NFL /NDL
if errorlevel 8 set "ROBOCOPY_ERROR=1"

robocopy "%SRC_ARTIFACTS%\bin\runtime\%RUNTIME_TFM%" "%DEST%\runtime" /E /NFL /NDL
if errorlevel 8 set "ROBOCOPY_ERROR=1"

robocopy "%SRC_ARTIFACTS%\bin\mono\%MONO_TRIPLE%\IL" "%DEST%\runtime" /E /NFL /NDL
if errorlevel 8 set "ROBOCOPY_ERROR=1"

if "%ROBOCOPY_ERROR%"=="1" (
    echo ERROR: One or more robocopy source directories not found. >&2
    echo Check that dotnet/runtime was built with configuration: %BUILD_TYPE% >&2
    exit /b 1
)

rem Flatten: if include\mono-2.0\ exists, move contents up
if exist "%DEST%\include\mono-2.0" (
    robocopy "%DEST%\include\mono-2.0" "%DEST%\include" /E /MOV /NFL /NDL
    rmdir /s /q "%DEST%\include\mono-2.0"
)

rem Flatten: if lib\lib\ exists, move contents up
if exist "%DEST%\lib\lib" (
    robocopy "%DEST%\lib\lib" "%DEST%\lib" /E /MOV /NFL /NDL
    rmdir /s /q "%DEST%\lib\lib"
)

rem Flatten: if bin\bin\ exists, move contents up
if exist "%DEST%\bin\bin" (
    robocopy "%DEST%\bin\bin" "%DEST%\bin" /E /MOV /NFL /NDL
    rmdir /s /q "%DEST%\bin\bin"
)

rem Flatten: if runtime\%RUNTIME_TFM%\ exists, move contents up
if exist "%DEST%\runtime\%RUNTIME_TFM%" (
    robocopy "%DEST%\runtime\%RUNTIME_TFM%" "%DEST%\runtime" /E /MOV /NFL /NDL
    rmdir /s /q "%DEST%\runtime\%RUNTIME_TFM%"
)

rem Update shared include\ (mono headers are platform-independent)
if exist "%SDK_DIR%\include" rmdir /s /q "%SDK_DIR%\include"
robocopy "%SRC_ARTIFACTS%\obj\mono\%MONO_TRIPLE%\out\include\mono-2.0" "%SDK_DIR%\include" /E /NFL /NDL

rem -- Write VERSION.txt into the platform directory ------------------------------
for /f "delims=" %%b in ('git -C "%DOTNET_SRC%" rev-parse --abbrev-ref HEAD 2^>nul') do set "DOTNET_BRANCH=%%b"
for /f "delims=" %%c in ('git -C "%DOTNET_SRC%" rev-parse --short HEAD 2^>nul')      do set "DOTNET_COMMIT=%%c"
for /f "delims=" %%r in ('git -C "%DOTNET_SRC%" remote get-url origin 2^>nul')       do set "DOTNET_REMOTE=%%r"

(
    echo dotnet/runtime source
    echo   repo:   %DOTNET_REMOTE%
    echo   branch: %DOTNET_BRANCH%
    echo   commit: %DOTNET_COMMIT%
    echo.
    echo Platform: Windows ^(x64^)
    echo Build type: %BUILD_TYPE%
) > "%DEST%\VERSION.txt"

echo ^>^>^> Done. SDK updated at: %DEST%
endlocal
