import std::io::path;
import std::io;
import std::os::process;

const NEW_LINE = "\r\n";
const CSI = "\x1B[";
const SGR_RESET = CSI +++ "0m";
const RED = "31m";
const YELLOW = "33m";
const BLUE = "34m";

macro String @color(String $color, String $str)
{
    return CSI +++ $color +++ $str +++ SGR_RESET;
}

faultdef
    GIT_ROOT_NOT_FOUND,
    PARSE_DIFF_STATE_FAILED;

fn Path? find_git_root(Path cwd)
{
    Path target = cwd;
    for (;;)
    {
        Path git_dir = target.tappend(".git")!;
        if (path::exists(git_dir))
        {
            return target;
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

    return GIT_ROOT_NOT_FOUND?;
}

struct Repo
{
    Path root;
}

struct DiffState
{
    uint files_changed;
    uint insertions;
    uint deletions;
}

fn String Repo.run_git(Repo *self, String[] command_line) {
    char[1024] buf @noinit;

    String[] final_command_line = array::tconcat((String[]){ "git", "-C", self.root.str_view() }, command_line);
    String? result = process::execute_stdout_to_buffer(&buf, final_command_line);
    if (try str = result) {
        return str;
    }

    return "";
}

fn String Repo.branch_name(Repo *self)
{
    return self.run_git({ "rev-parse", "--abbrev-ref", "HEAD" });
}

fn DiffState Repo.changes(Repo *self)
{
    DiffState result = {};

    String output = self.run_git({ "diff", "--shortstat", "HEAD" });
    if (output.len == 0) {
        return result;
    }

    String[] lines = output.tsplit("\n");

    for (usz i = 0; i < lines.len; i++)
    {
        if (try lines[i].index_of("file"))
        {
            String[] tokens = lines[i].tsplit(" ");
            uint num = 0;
            
            for (usz j = 0; j < tokens.len; j++) 
            {
                String token = tokens[j];
                if (try num_ = token.to_uint()) {
                    num = num_;
                    continue;
                }

                if (try token.index_of("file"))
                {
                    result.files_changed = num;
                    continue;
                }
                else if (try token.index_of("insertions"))
                {
                    result.insertions = num;
                    continue;
                }
                else if (try token.index_of("deletions"))
                {
                    result.deletions = num;
                    continue;
                }
            }
            return result;
        }
    }

    return result;
}

fn void print_env_xxx(ZString* environ)
{
    for (usz i = 0; environ[i] != null; i++)
    {
        String env = environ[i].str_view();
        if (env.starts_with("BP_ENV_"))
        {
            String[] xs = env.tsplit("=");
            if (xs.len > 0)
            {
                io::printf(" (%s)", xs[1]);
            }
        }
    }
}

fn void print_git(Path cwd)
{
    if (try git_root = find_git_root(cwd))
    {
        Repo repo = {.root = git_root };
        io::printf(" @ " +++ @color(YELLOW, "%s"), repo.branch_name());

        DiffState diff_state = repo.changes();
        if (diff_state.files_changed > 0)
        {
            io::printf(@color(RED, "*"));
            io::printf(" +%d, -%d", diff_state.insertions, diff_state.deletions);
        }
    }
}


fn String short_view(String work_dir, bool use_short_name)
{
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

    return buf.str_view();
}

fn void print_cwd(Path cwd, bool use_short_name)
{
    String cwd_str = cwd.str_view().treplace("\\", "/");
    io::printf(@color(BLUE, "%s"), short_view(cwd_str, use_short_name));
}

struct CommandLineFlag
{
    bool use_short_name;
    bool show_env_xxx;
}

fn CommandLineFlag parse_argv(ZString* argv)
{
    CommandLineFlag cli = {};

    for (usz i = 0; argv[i] != null; i++) {
        String flag = argv[i].str_view();

        if (flag == "--short")
        {
            cli.use_short_name = true;
            continue;
        }

        if (flag == "--venv")
        {
            cli.show_env_xxx = true;
            continue;
        }
    }

    return cli;
}

fn void main() @export("_main") => unreachable();
fn int _main(int argc, ZString* argv, ZString* environ) @export("main")
{
    CommandLineFlag flag = parse_argv(argv);

    if (try cwd = path::tcwd())
    {
        io::printf(NEW_LINE);
        print_cwd(cwd, flag.use_short_name);
        print_git(cwd);

        if (flag.show_env_xxx)
        {
            print_env_xxx(environ);
        }

        io::print(NEW_LINE);
    }

    return 0;
}
