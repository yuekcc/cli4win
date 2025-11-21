module cmd;

import std::os::process;
import std::io;

struct CommandResult
{
    int code;
    String output;
}

fn CommandResult? execute(Allocator allocator, String[] command_line) 
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
    
    int return_code = process.join()!;
    $if env::DEBUG_SYMBOLS:
        if (return_code != 0)
        {
            io::printfn("return code = %d", return_code);
        }
    $endif

    @pool()
    {
        DString result = dstring::new(tmem);
        while(true)
        {
            char[512] buf @noinit;
            usz len = process.read_stdout(&buf, buf.len)!;
            if (len == 0)
            {
                break;
            }

            result.write(buf[:len])!;
        }

        if (allocator == tmem)
        {
            return {
                .code = return_code,
                .output = result.str_view()
            };
        }

        return {
            .code = return_code,
            .output = result.copy_str(allocator)
        };
    };
}

fn String? execute_to_string(Allocator allocator, String[] command_line)
{
    CommandResult cmd_result = execute(allocator, command_line)!;
    return cmd_result.output;
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
