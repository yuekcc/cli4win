module win;

import std::os::process;
import std::io;
import std::io::path;
import std::os::win32;

macro cast_int(Win32_HINSTANCE instance)
{
    return (int)(iptr)instance;
}

// 激活并显示窗口
// 如果窗口最小化、最大化或排列，系统会将其还原到其原始大小和位置。应用程序应在首次显示窗口时指定此标志
const SW_NORMAL = 1; 

extern fn Win32_HINSTANCE shell_execute(
    Win32_HWND hwnd,
    Win32_LPCWSTR lpOperation,
    Win32_LPCWSTR lpFile,
    Win32_LPCWSTR lpParameters,
    Win32_LPCWSTR lpDirectory,
    Win32_INT32 nShowCmd,
) @cname("ShellExecuteW");

fn bool shell_exec(String work_dir, String target, String parameters) 
{
    $if env::DEBUG_SYMBOLS:
        io::printfn("target: %s", target);
        io::printfn("work_dir: %s", work_dir);
        io::printfn("parameters: %s", parameters);
    $endif

    $if !env::WIN32:
        io::eprintfn("Only work in Windows");
        return false;
    $endif

    String operation = "open";
    Win32_HINSTANCE result = shell_execute(
        null, // hwnd
        operation.to_temp_utf16()!!, // lpOperation
        target.to_temp_utf16()!!, // lpFile
        parameters.to_temp_utf16()!!, // lpParameters
        work_dir.to_temp_utf16()!!, // lpDirectory
        SW_NORMAL, // nShowCmd
    );

    if (cast_int(result) > 32) 
    {
        return true;
    }

    io::eprintfn("Failed to open file (%d)", cast_int(result));
    return false;
}
