import std::io;

fn void main()
{
    String content = (String)file::load_temp(".git/HEAD") ?? "";
    String[] paths = content.tsplit("/");
    io::printfn("%s", paths[paths.len - 1]);
}