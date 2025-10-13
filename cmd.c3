module cmd;
import std::os::process;

fn String? execute_to_string(String[] command_line)
{
    process::SubProcess process = process::create(
        command_line, 
        {
            .combined_stdout_stderr = true,
            .inherit_environment = true,
            .search_user_path = true,
            .no_window = true,
        }
    )!;

    process.join()!;

    DString result = dstring::new(tmem);
    usz count = 0;
    while(true)
    {
        char[512] buf @noinit;
        usz len = process.read_stdout(&buf, buf.len)!;
        if (len == 0)
        {
            break;
        }

        result.append((String)buf[:len-1]);
    }

    return result.str_view().copy(tmem);
}