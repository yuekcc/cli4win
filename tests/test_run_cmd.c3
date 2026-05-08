import std::io;
import std::os::process;

import cmd;


fn void main()
{
	// String[] final_command_line = {"bash", "-ic", "node -v 2>&1 || echo \"Node.js not installed\""};
	String[] final_command_line = { "bash", "-c", "export PATH=$PATH; node -v" };
	String? result = cmd::execute_to_string(mem, final_command_line);

	if (catch err = result)
	{
		io::printfn("Error, %s", err);
		return;
	}

	io::printfn("%s", result);
}