@echo off
setlocal
set SCRIPT_DIR=%~dp0
set CLANG_EXE=%SCRIPT_DIR%clang.exe
set SYSROOT=%SCRIPT_DIR%sysroot
"%CLANG_EXE%" -target aarch64-linux-ohos --sysroot="%SYSROOT%" -D__MUSL__ %*
