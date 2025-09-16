import std::io::path;
import std::io;

const CSI = "\x1B[";
const SGR_RESET = CSI +++ "0m";
const BLUE = "34m";
const YELLOW = "34m";

macro String @color(String $color, String $str)
{
    return CSI +++ $color +++ $str +++ SGR_RESET;
}

fn String short_view(Path cwd)
{
    String work_dir = cwd.str_view().replace(allocator::mem, "\\", "/");
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

fn int main(int argc, char** argv)
{
    Path cwd = path::cwd(allocator::mem)!!;

    io::printf(@color(BLUE, "%s"), short_view(cwd));
    io::print("\n\r");
    return 0;
}