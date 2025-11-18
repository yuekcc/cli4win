import std::io;
import std::os::process;

import cmd;


fn void main()
{
    String[] final_command_line = {"curl", "-k", "https://www.baidu.com"};
    String? result = cmd::execute_to_string(mem, final_command_line);

    if (catch err = result)
    {
        io::printfn("Error, %s", err);
        return;
    }

    io::printfn("%s", result);
}