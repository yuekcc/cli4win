module cmd;
import std::os::process;
import std::io;

fn String? execute_to_string(Allocator allocator, String[] command_line)
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
    
    isz return_code = process.join()!;
    $if env::DEBUG_SYMBOLS:
    if (return_code != 0)
    {
        io::printfn("return code = %d", return_code);
    }
    $endif

    @pool()
    {
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

            result.append((String)buf[:len]);
        }

        if (allocator == tmem)
        {
            return result.str_view();
        }

        return result.copy_str(allocator);
    };
}

fn void test_execute_to_string() @test
{
    String[] final_command_line = {"curl", "-k", "https://www.baidu.com"};
    String result = cmd::execute_to_string(tmem, final_command_line)!!;

    // io::printfn("%s", result);
    assert(result.contains("<html>") && result.contains("</html>"));
}


fn void test_non_zero_return_code() @test
{
    String[] final_command_line = {"curl", "-k"};
    String result = cmd::execute_to_string(tmem, final_command_line)!!;

    io::printfn("%s", result);
    assert(result.contains("no URL specified"));
}
