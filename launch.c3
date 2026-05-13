import std::io;
import std::io::path;
import std::io::file;
import std::encoding::json;
import std::collections::object;
import std::os::win32;

import win;

fn int real_main(int argc, String arg0)
{
	Path exe_name = path::new(mem, arg0)!!;
	Path full_path = exe_name.absolute(mem)!!;
	Path install_path = full_path.parent()!!;

	Path config_path = install_path.tappend(string::tformat("%s.json", exe_name.basename()))!!;
	String context = (String)file::load_path(tmem, config_path)!!;


	Path cwd = path::cwd(mem)!!;

	Object* config = json::parse(mem, context)!!;
	String command = path::normalize(config.get_string("command")!!)!!;
	bool change_dir = config.get_bool("changeDir")!!;

	DString flags = dstring::new(mem);
	for (sz i = 0; i < config.get("args").get_len()!!; i++)
	{
		String flag = config.get("args").get_string_at(i)!!;
		if (change_dir && flag == "$CWD")
		{
			flag = cwd;
		}

		flags.append(flag);
		flags.append(" ");
	}

	win::shell_exec(change_dir ? install_path : cwd, command, flags.str_view());
	return 0;
}

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