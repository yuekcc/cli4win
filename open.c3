import std::io;
import std::io::path;
import win;
import std::os::win32;

fn int open_uri(String cwd, String uri) @inline
{
    return win::shell_exec(cwd, uri, "") ? 0 : 1;
}

fn int open_file(String cwd, String file_path, int argc, ZString* argv) @inline
{
    @pool()
    {
        Path? target = path::new(tmem, file_path);
        if (catch reason = target)
        {
            io::eprintfn("Error, invalid path. Input = %s", file_path);
            return 1;
        }

        if (!path::exists(target))
        {        
            io::eprintfn("Error, file not found. File path = %s", target);
            return 1;
        }

        DString parameter = dstring::new(tmem);
        if (argc > 2)
        {
            for (usz i = 2; argv[i] != null; i++)
            {
                parameter.append(argv[i].str_view());
                parameter.append(" ");
            }
        }


        return win::shell_exec(cwd, target.str_view(), parameter.str_view()) ? 0 : 1;
    };
}


fn int main(int argc, ZString* argv)
{
    Path cwd = path::cwd(mem)!!;

    // 目标默认为当前目录
    String target_file = ".";
    if (argc > 1)
    {
        target_file = argv[1].str_view();
    }

    // 直接打开 URL
    if (target_file.starts_with("http:") || target_file.starts_with("https:") || target_file.starts_with("mailto:"))
    {
        return open_uri(cwd.str_view(), target_file);
    }

    return open_file(cwd.str_view(), target_file, argc, argv);
}

