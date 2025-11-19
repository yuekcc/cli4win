import std::io;

import jwrite;

fn void main()
{
    JwControl jwc @noinit;

    char[1024] buf @noinit;
    char* p = &buf;
    jwrite::open(&jwc, p, 1024, JwNodeType.JW_OBJECT, 1);
    jwrite::add_key(&jwc, "key");
    jwrite::add_string(&jwc, "some text");
    int err = jwrite::close(&jwc);

    io::printfn("result code = %d", err);

    io::printfn("%s", (ZString)buf[:1024]);
}