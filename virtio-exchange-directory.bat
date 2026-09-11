@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM  功能：扫描指定文件夹下的三级子目录，把其中的文件移动到
REM        「第一级 <-> 第三级」互换后的新目录中
REM
REM  原结构： 根\A\B\C\file.txt
REM  新结构： 根\C\B\A\file.txt
REM
REM  用法：swap_dirs.bat [目标文件夹]
REM        不带参数时使用当前目录
REM ============================================================

set "ROOT=%~1"
if not defined ROOT set "ROOT=%CD%"

pushd "%ROOT%" 2>nul
if errorlevel 1 (
    echo [错误] 无法进入目录: %ROOT%
    pause
    exit /b 1
)

echo 工作目录: %CD%
echo.

set "LIST=%TEMP%\swap_%RANDOM%_%RANDOM%.txt"
type nul > "%LIST%"

REM ---------- 第一步：扫描并生成任务清单 ----------
echo [1/2] 正在扫描三级子目录中的文件...
set /a N=0

for /d %%A in (*) do (
    for /d %%B in ("%%A\*") do (
        for /d %%C in ("%%B\*") do (
            if /i not "%%~nxA"=="%%~nxC" (
                for %%F in ("%%C\*") do (
                    >>"%LIST%" echo "%%F"^|%%~nxC\%%~nxB\%%~nxA
                    set /a N+=1
                )
            )
        )
    )
)

echo       共找到 !N! 个文件。
if !N! EQU 0 (
    del "%LIST%" >nul 2>nul
    popd
    echo 没有需要处理的文件。
    pause
    exit /b 0
)

REM ---------- 第二步：创建新目录并移动文件 ----------
echo.
echo [2/2] 正在创建新目录并移动文件...

for /f "usebackq eol=| delims=| tokens=1,2" %%a in ("%LIST%") do (
    if not exist "%%~b" (
        md "%%~b" 2>nul
        echo   新建目录: "%%~b"
    )
    move /y "%%~a" "%%~b\" >nul 2>nul
    if errorlevel 1 (
        echo   [失败] "%%~a"
    ) else (
        echo   移动: "%%~a"  --^>  "%%~b\"
    )
)

del "%LIST%" >nul 2>nul

echo.
echo ============ 完成 ============
popd
pause
endlocal