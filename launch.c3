import std::io;
import std::io::path;
import std::io::file;
import std::encoding::json;
import std::collections::object;
import std::os::win32;

import win;

fn int real_main(int argc, String arg0)
{
    Path exe_name = path::new(allocator::mem, arg0)!!;
    Path full_path = exe_name.absolute(allocator::mem)!!;
    String install_dir = full_path.dirname();

    String config_path = path::normalize(string::tformat("%s/%s.json", install_dir, exe_name.basename()))!!;
    // io::printfn("%s", config_path);

    File config_file = file::open(config_path, "r")!!;
    defer config_file.close()!!;

    Path cwd = path::cwd(allocator::mem)!!;

    Object* config = json::parse(allocator::mem, &config_file)!!;
    String command = path::normalize(config.get_string("command")!!)!!;
    bool change_dir = config.get_bool("changeDir")!!;
    
    DString flags = dstring::new(allocator::mem);
    for (usz i = 0; i < config.get("args").get_len()!!; i++)
    {
        String flag = config.get("args").get_string_at(i)!!;
        if (change_dir && flag == "$CWD")
        {
            flag = cwd.str_view();
        }

        flags.append(flag);
        flags.append(" ");
    }

    io::printfn("cwd: %s", cwd.str_view());
    io::printfn("command: %s", command);
    io::printfn("flags: %s", flags.str_view());

     win::shell_exec(
        change_dir ? install_dir : cwd.str_view(), 
        command, 
        flags.str_view()
    );

    return 0;
}

// fn int main(int argc, char** argv)
// {
//     String arg0 = ZString.str_view((ZString)argv[0]);
//     return real_main(argc, arg0);
// }
fn int main(
    Win32_HINSTANCE hInstance,
    Win32_HINSTANCE hPrevInstance,
    String[] argv,
    int nCmdShow
) @winmain @if(env::WIN32)
{
    int argc = argv.len;
    String arg0 = argv[0];
    return real_main(argc, arg0);
}

fn void main() @if(!env::WIN32)
{
    io::printfn("only work on windows");
}

