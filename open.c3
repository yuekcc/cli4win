import std::io;
import std::io::path;
import win;
import std::os::win32;

fn int main(int argc, char** argv)
{
    if (argc < 2)
    {
        Path exe_name = path::new(allocator::heap(), ZString.str_view((ZString)argv[0]))!!;
        io::eprintfn("Usage: %s <FILE_PATH>", exe_name.basename());
        return 1;
    }

    String target_name = ZString.str_view((ZString)argv[1]);
    target_name = path::normalize(target_name)!!;

    Path cwd = path::cwd(allocator::heap())!!;

    DString parameter = dstring::new(allocator::heap());
    for (usz i = 2; i < argc; i++)
    {
        parameter.append(ZString.str_view((ZString)argv[i]));
        parameter.append(" ");
    }

    return win::shell_exec(cwd.str_view(), target_name, parameter.str_view()) ? 0 : 1;
}

