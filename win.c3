module win;

import std::os::process;
import std::io;
import std::io::path;
import std::os::win32;

// 1 = SW_NORMAL，激活并显示窗口。如果窗口最小化、最大化或排列，系统会将其还原到其原始大小和位置。应用程序应在首次显示窗口时指定此标志
const SHOW_CMD = 1; 

extern fn win32::Win32_HINSTANCE shellExecuteW(
    win32::Win32_HWND hwnd, 
    win32::Win32_LPCWSTR lpOperation, 
    win32::Win32_LPCWSTR lpFile, 
    win32::Win32_LPCWSTR lpParameters, 
    win32::Win32_LPCWSTR lpDirectory, 
    win32::Win32_INT32 nShowCmd,
) @extern("ShellExecuteW");

fn bool shell_exec(String work_dir, String target, String parameters) 
{
    $if env::DEBUG_SYMBOLS:
        io::printfn("target: %s", target);
        io::printfn("work_dir: %s", work_dir);
        io::printfn("parameters: %s", parameters);
    $endif

    $if env::WIN32:
        String operation = "open";
        win32::Win32_HINSTANCE res = shellExecuteW(
            null, // hwnd
            operation.to_temp_utf16()!!, // lpOperation
            target.to_temp_utf16()!!, // lpFile
            parameters.to_temp_utf16()!!, // lpParameters
            work_dir.to_temp_utf16()!!, // lpDirectory
            SHOW_CMD, // nShowCmd
        );

        if (res > (win32::Win32_HINSTANCE)32) 
        {
            return true;
        }

        io::eprintfn("Failed to open file (%d)", (int)(iptr)res);
        return false;
    $else
        io::eprintfn("Only work in Windows");
        return false;
    $endif
}
