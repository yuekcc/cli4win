import std::io::path;
import std::io;
import std::os::process;
import std::os::env;
import cmd;

const NEW_LINE = "\r\n";

macro String style(String $style, String $str)
{
	return $style +++ $str +++ Ansi.RESET;
}

faultdef
	GIT_ROOT_NOT_FOUND, PARSE_DIFF_STATE_FAILED
;

struct DiffState
{
	usz files_changed;
	usz insertions;
	usz deletions;
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
			if (path::exists(git_dir))
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
	String[] final_command_line = array::concat(tmem, (String[]) { "git", "-C", self.root }, command_line);
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

fn DiffState count_changed_lines(String output)
{
	if (output.len == 0)
	{
		return (DiffState) { };
	}

	usz files_changed;
	usz insertions;
	usz deletions;

	String[] lines = output.split(tmem, "\n");
	for (usz i = 0; i < lines.len; i++)
	{
		String[] tokens = lines[i].split(tmem, "\t");
		if (tokens.len > 2)
		{
			String added = tokens[0];
			String deleted = tokens[1];
			if (try num = added.to_uint())
			{
				insertions += num;
			}

			if (try num = deleted.to_uint())
			{
				deletions += num;
			}
		}

		files_changed += 1;
	}

	if (insertions == 0 && deletions == 0)
	{
		return (DiffState) { };
	}

	return { .files_changed = files_changed, .insertions = insertions, .deletions = deletions, };
}

struct FileDiffState
{
	usz staged;
	usz unstaged;
	usz untracked;
}

fn FileDiffState count_changed_files(String output)
{
	FileDiffState fds;

	if (output.len == 0)
	{
		return fds;
	}

	String[] lines = output.split(tmem, "\n");
	for (usz i = 0; i < lines.len; i++)
	{
		char x = lines[i][0];
		char y = lines[i][1];

		if (x != ' ' && x != '?')
		{
			fds.staged += 1;
		}
		
		if (x == '?' && y == '?')
		{
			fds.untracked += 1;
		}
		
		if (y != ' ' && y != '?')
		{
			fds.unstaged += 1;
		}
	}

	return fds;
}

fn FileDiffState Repo.file_changes(Repo* self)
{
	String output = self.run_git(tmem, { "status", "--porcelain" });
	return count_changed_files(output);
}

fn DiffState Repo.changes(Repo* self)
{
	// git status --porcelain
	String output = self.run_git(tmem, { "--no-pager", "diff", "--numstat", "HEAD" });
	return count_changed_lines(output);
	// if (output.len == 0)
	// {
	// 	return (DiffState) { };
	// }

	// usz files_changed;
	// usz insertions;
	// usz deletions;

	// String[] lines = output.split(tmem, "\n");
	// for (usz i = 0; i < lines.len; i++)
	// {
	// 	String[] tokens = lines[i].split(tmem, "\t");
	// 	if (tokens.len > 2)
	// 	{
	// 		String added = tokens[0];
	// 		String deleted = tokens[1];
	// 		if (try num = added.to_uint())
	// 		{
	// 			insertions += num;
	// 		}

	// 		if (try num = deleted.to_uint())
	// 		{
	// 			deletions += num;
	// 		}
	// 	}

	// 	files_changed += 1;
	// }

	// if (insertions == 0 && deletions == 0)
	// {
	// 	return (DiffState) { };
	// }

	// return { .files_changed = files_changed, .insertions = insertions, .deletions = deletions, };
}

fn void print_env_xxx(DString* out, ZString* environ)
{
	for (usz i = 0; environ[i] != null; i++)
	{
		String env = environ[i].str_view();
		if (env.starts_with("BP_ENV_"))
		{
			String[] xs = env.split(tmem, "=");
			if (xs.len > 0)
			{
				out.appendf(style(Ansi.ITALIC, " (%s)"), xs[1]);
			}
		}
	}
}

fn void print_git(DString* out, Path cwd)
{
	Repo repo = {};
	bool ready = repo.try_init(tmem, cwd) ?? false;
	if (!ready)
	{
		return;
	}

	out.appendf(" @ " +++ style(Ansi.YELLOW, "%s"), repo.branch_name(tmem));

	FileDiffState file_diff_state = repo.file_changes();
	if (file_diff_state.staged > 0 || file_diff_state.unstaged > 0 || file_diff_state.untracked > 0)
	{
		out.append(style(Ansi.RED, "*"));
		if (file_diff_state.staged > 0) out.appendf(" s.%d", file_diff_state.staged);
		if (file_diff_state.unstaged > 0) out.appendf(" us.%d", file_diff_state.unstaged);
		if (file_diff_state.untracked > 0) out.appendf(" ut.%d", file_diff_state.untracked);
	} 

	// DiffState diff_state = repo.changes();
	// if (diff_state.files_changed > 0)
	// {
	// 	out.append(style(Ansi.RED, "*"));
	// 	out.appendf(" +%d, -%d", diff_state.insertions, diff_state.deletions);
	// }
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
			WString name = paths[i].to_wstring(tmem)!!;
			if (use_short_name)
			{
				buf.append(string::from_utf16(tmem, name[:1])!!);
			}
			else
			{
				buf.append(string::from_utf16(tmem, name[:name.len()])!!);
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
		print_git(&buf, cwd);

		if (flag.show_env_xxx)
		{
			print_env_xxx(&buf, environ);
		}

		buf.append(NEW_LINE);
		io::print(buf.str_view());
	}

	return 0;
}
