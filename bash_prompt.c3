import std::io::path;
import std::io;
import std::core::string::conv;
import std::os::process;
import std::os::env;
import std::os::win32;
import cmd;

// Platform-native line ends. On Windows the CRT is in text mode and widens
// every '\n' to "\r\n" on write, so the constant stays a single '\n' (a literal
// "\r\n" would be doubled into "\r\r\n"). POSIX has no text mode, so '\n' is
// emitted verbatim.
const NEW_LINE = "\n";

macro String style(String $style, String $str)
{
	return $style +++ $str +++ Ansi.RESET;
}

faultdef
	GIT_ROOT_NOT_FOUND, PARSE_DIFF_STATE_FAILED
;

// Existence check that avoids std::io::path::exists.
//
// On Windows `path::exists` calls `PathFileExistsW`, which drags in SHLWAPI.dll.
// We only need it to locate the `.git` directory, so use GetFileAttributesExW
// (KERNEL32) instead and keep the import list minimal. `GetFileAttributesExW`
// also resolves device names such as "NUL"/"CON", matching the C3 semantics.
fn bool path_exists(String path)
{
	@pool()
	{
		Win32_FILE_ATTRIBUTE_DATA data;
		return (bool)win32::getFileAttributesExW(
			path.to_temp_utf16()!!,
			Win32_GET_FILEEX_INFO_LEVELS.STANDARD,
			&data);
	};
}

struct Repo
{
	Path root;
	Allocator allocator;
}

fn bool? Repo.try_init(&self, Allocator allocator, Path cwd)
{
	self.allocator = allocator;

	@pool()
	{
		Path target = cwd;
		for (;;)
		{
			Path git_dir = target.append(tmem, ".git")!;
			if (path_exists(git_dir))
			{
				self.root = path::new(self.allocator, git_dir.parent())!;
				return true;
			}

			if (try parent = target.parent())
			{
				target = parent;
			}
			else
			{
				break;
			}
		}
	};

	return false;
}

fn void Repo.free(&self)
{
	alloc::free(self.allocator, self.root);
}


fn String Repo.run_git(Repo* self, Allocator allocator, String[] command_line)
{
	String[] final_command_line = array::concat(
		tmem,
		(String[]) { "git", "-C", self.root, "--no-optional-locks", "--no-pager" },
		command_line
	);
	String? result = cmd::execute_to_string(tmem, final_command_line);
	if (try result)
	{
		return result.trim().copy(allocator);
	}

	return "";
}

fn String Repo.branch_name(Repo* self, Allocator allocator)
{
	if (try head_file = self.root.tappend(".git/HEAD"))
	{
		String content = (String)file::load_temp(head_file) ?? "";
		return content.treplace("ref: refs/heads/", "").trim().copy(allocator);
	}
	else
	{
		return "";
	}
}

fn sz count_changed_files(String output)
{
	if (output.len == 0)
	{
		return 0;
	}

	String[] lines = output.split(tmem, "\n");
	return lines.len;
}

fn sz Repo.file_changes(Repo* self)
{
	// git --no-pager --no-optional-locks status --porcelain
	String output = self.run_git(tmem, { "status", "--porcelain" });
	return count_changed_files(output);
}

fn void print_env_xxx(DString* out, ZString* environ)
{
	for (usz i = 0; environ[i] != null; i++)
	{
		String env = environ[i].str_view();
		if (env.starts_with("BP_ENV_"))
		{
			String[] xs = env.split(tmem, "=");
			// Need at least "KEY=VALUE": a malformed entry without '=' splits
			// into a single element, so reading xs[1] would be out of bounds.
			if (xs.len > 1)
			{
				out.appendf(style(Ansi.ITALIC, " (%s)"), xs[1]);
			}
		}
	}
}

fn void print_git(DString* out, Path cwd, bool show_changes)
{
	Repo repo  = { };
	bool ready = repo.try_init(tmem, cwd) ?? false;
	if (!ready)
	{
		return;
	}

	out.appendf(" @ " +++ style(Ansi.YELLOW, "%s"), repo.branch_name(tmem));

	// Counting changed files spawns `git status --porcelain`, so it is opt-in:
	// only run it when `--git` was given.
	if (show_changes)
	{
		sz changed_files = repo.file_changes();
		if (changed_files > 0)
		{
			out.appendf(style(Ansi.RED, " <%d>"), changed_files);
		}
	}
}

// First UTF-8 codepoint of `s`, kept whole so a surrogate pair (e.g. an emoji)
// is never split. Falls back to the first byte when the string is empty or the
// sequence is invalid. Mirrors the Odin/Zig ports, which keep one Unicode
// scalar value rather than the first UTF-16 code unit the old code used.
fn String first_codepoint(String s)
{
	if (s.len == 0)
	{
		return s;
	}

	sz read = s.len < 4 ? s.len : 4;
	if (catch conv::utf8_to_char32(&s[0], &read))
	{
		return s[:1];
	}

	return s[:read];
}

fn String short_view(Allocator allocator, String work_dir, bool use_short_name)
{
	String home = "";
	if (try home_env = env::get_home_dir(tmem))
	{
		home = home_env.replace(tmem, "\\", "/");
	}

	if (home.len > 0 && work_dir.starts_with(home))
	{
		work_dir = work_dir.replace(tmem, home, "~");
	}

	String[] paths = work_dir.split(tmem, "/");

	DString buf = dstring::new(tmem);
	for (usz i = 0; i < paths.len; i++)
	{
		if (i == 0)
		{
			buf.append(paths[i]);
			buf.append("/");
		}
		else if (i == (paths.len - 1))
		{
			buf.append(paths[i]);
		}
		else
		{
			if (use_short_name)
			{
				buf.append(first_codepoint(paths[i]));
			}
			else
			{
				buf.append(paths[i]);
			}

			buf.append("/");
		}
	}

	return buf.copy_str(allocator);
}

fn void print_cwd(DString* out, Path cwd, bool use_short_name)
{
	String cwd_str = cwd.replace(tmem, "\\", "/");
	out.appendf(style(Ansi.BLUE +++ Ansi.BOLD, "%s"), short_view(tmem, cwd_str, use_short_name));
}

struct CommandLineFlag
{
	bool use_short_name;
	bool show_git;
	bool show_env_xxx;
	bool show_init;
	bool show_help;
	String exe_name;
}

fn CommandLineFlag* CommandLineFlag.init(&self, ZString* argv)
{
	for (usz i = 0; argv[i] != null; i++)
	{
		String flag = argv[i].str_view();

		if (i == 0)
		{
			self.exe_name = flag;
			continue;
		}

		if (flag == "--short")
		{
			self.use_short_name = true;
			continue;
		}
		else if (flag == "--git")
		{
			self.show_git = true;
			continue;
		}
		else if (flag == "--venv")
		{
			self.show_env_xxx = true;
			continue;
		}
		else if (flag == "--init")
		{
			self.show_init = true;
			continue;
		}
		else if (flag == "--help" || flag == "-h")
		{
			self.show_help = true;
			continue;
		}
	}

	return self;
}

fn void main() @export("_main") => unreachable();
fn int _main(int argc, ZString* argv, ZString* environ) @export("main")
{
	CommandLineFlag flag;
	flag.init(argv);

	if (flag.show_help)
	{
		io::printn(
			"bash_prompt, a PROMPT_COMMAND\nflags:\n"
				+++ "\t--short: enable short dir name\n"
				+++ "\t--git: show changed file count (spawns git status)\n"
				+++ "\t--venv: show BP_ENV_XXX for multi version programs\n"
				+++ "\t--init: print init script. To quick setup, run: bash_prompt --init >> ~/.bashrc\n"
				+++ "\t--help: print this message"
		);
		return 0;
	}

	if (flag.show_init)
	{
		Path exe_name = path::new(tmem, flag.exe_name)!!;
		io::printf("\nPROMPT_COMMAND=\"%s --short --venv\"; export PROMPT_COMMAND; PS1=\"\\$ \";", exe_name.basename());
		return 0;
	}

	if (try cwd = path::cwd(tmem))
	{
		DString buf = dstring::new(tmem);
		buf.append(NEW_LINE);

		print_cwd(&buf, cwd, flag.use_short_name);
		print_git(&buf, cwd, flag.show_git);

		if (flag.show_env_xxx)
		{
			print_env_xxx(&buf, environ);
		}

		buf.append(NEW_LINE);
		io::print(buf.str_view());
	}

	return 0;
}
