import std::io::path;
import std::io;
import std::os::process;

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

fn String Repo.branch_name(Repo *self)
{
    char[1024] buf @noinit;
    String result = process::execute_stdout_to_buffer(&buf, {"git", "-C", self.root.str_view(), "rev-parse", "--abbrev-ref", "HEAD"})!!;
    return result.trim();
}

fn DiffState Repo.changes(Repo *self)
{
    char[1024] buf @noinit;
    String output = process::execute_stdout_to_buffer(&buf, {"git", "-C", self.root.str_view(), "diff", "--shortstat", "HEAD"})!!;
    String[] lines = output.tsplit("\n");
    // io::printfn("git diff --shortstat HEAD output: %s", output);

    DiffState result = {};

    for (usz i = 0; i < lines.len; i++)
    {
        if (try lines[i].index_of("file"))
        {
            // io::printfn("parse line: %s", lines[i]);
            String[] tokens = lines[i].tsplit(" ");
            uint num = 0;
            
            for (usz j = 0; j < tokens.len; j++) 
            {
                String token = tokens[j];
                // io::printfn("parse token: %s", token);
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

fn int main(int argc, char** argv)
{
    Path cwd = path::cwd(allocator::mem)!!;
    String cwd_str = cwd.str_view().replace(allocator::mem, "\\", "/");
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

    io::print("\n\r");
    return 0;
}

// TODO 实现 git 调用实现
// TODO 支持 BP_ENV_XXXX 环境变量展示
