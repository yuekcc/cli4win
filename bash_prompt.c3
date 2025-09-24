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

fn String short_view(String work_dir)
{
    String[] paths = work_dir.split(allocator::mem, "/");

    DString buf = dstring::new(allocator::mem);
    for (usz i = 0; i<paths.len; i++)
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
            WString name = paths[i].to_wstring(allocator::mem)!!;
            buf.append(string::from_utf16(allocator::mem, name[:1])!!);
            buf.append("/");
        }
    }

    return buf.str_view();
}

faultdef
    GIT_ROOT_NOT_FOUND,
    PARSE_DIFF_STATE_FAILED;

fn Path? find_git_root(Path cwd, String cwd_str)
{
    String[] paths = cwd_str.tsplit("/");

    Path target = cwd;
    for (usz i = 0; i < paths.len; i++)
    {
        Path git_dir = target.tappend(".git")!;
        if (path::exists(git_dir))
        {
            return target;
        }
        target = target.parent()!;
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
    for (usz i = 0; environ[i] != null; i++) {
        String env = environ[i].str_view();
        if (env.starts_with("BP_ENV_")) {
            String[] xs = env.tsplit("=");
            if (xs.len > 0)
            {
                io::printf(" (%s)", xs[1]);
            }
        }
    }
}

fn void main() @export("_main") => unreachable();
fn int _main(int argc, ZString* argv, ZString* environ) @export("main")
{
    Path cwd = path::cwd(allocator::mem)!!;
    String cwd_str = cwd.str_view().replace(allocator::mem, "\\", "/");
    io::printf(NEW_LINE);
    io::printf(@color(BLUE, "%s"), short_view(cwd_str));

    if (try git_root = find_git_root(cwd, cwd_str))
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

    print_env_xxx(environ);

    io::print(NEW_LINE);
    return 0;
}
