module cmd;
import std::os::process;
import std::io;

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

fn void test_execute_to_string() @test
{
    String[] final_command_line = {"curl", "-k", "https://www.baidu.com"};
    String? result = cmd::execute_to_string(final_command_line);

    if (catch err = result)
    {
        io::printfn("Error, %s", err);
        return;
    }

    io::printfn("%s", result);
}