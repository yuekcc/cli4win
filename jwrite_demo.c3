import std::io;

import jwrite;

fn void main()
{
    JwControl jwc @noinit;

    char[1024] buf @noinit;
    char* p = &buf;
    jwrite::open(&jwc, p, 1024, JwNodeType.JW_OBJECT, 1);
    jwrite::add_key(&jwc, "tool_choice");
    jwrite::add_string(&jwc, "auto");
    jwrite::add_key(&jwc, "tools");
    jwrite::add_array(&jwc);
        jwrite::add_object(&jwc);
            jwrite::add_key(&jwc, "type");
            jwrite::add_string(&jwc, "function");
            jwrite::add_key(&jwc, "function");
            jwrite::add_object(&jwc);
                jwrite::add_key(&jwc, "name");
                jwrite::add_string(&jwc, "execute_command");
                jwrite::add_key(&jwc, "description");
                jwrite::add_string(&jwc, "Execute shell command. Use 'cmd /c as runner on Windows 11.'");
                jwrite::add_key(&jwc, "parameters");
                jwrite::add_object(&jwc);
                    jwrite::add_key(&jwc, "type");
                    jwrite::add_string(&jwc, "object");
                    jwrite::add_key(&jwc, "properties");
                    jwrite::add_object(&jwc);
                        jwrite::add_key(&jwc, "command");
                        jwrite::add_object(&jwc);
                            jwrite::add_key(&jwc, "type");
                            jwrite::add_string(&jwc, "string");
                            jwrite::add_key(&jwc, "description");
                            jwrite::add_string(&jwc, "only support on command line. use '&&' to concat two or more commands");
                            jwrite::end(&jwc);
                        jwrite::end(&jwc);
                    jwrite::add_key(&jwc, "required");
                    jwrite::add_array(&jwc);
                        jwrite::add_string(&jwc, "command");
                        jwrite::end(&jwc);
                    jwrite::end(&jwc);
                jwrite::end(&jwc);
            jwrite::end(&jwc);
        jwrite::end(&jwc);

    int err = jwrite::close(&jwc);

    io::printfn("result code = %d", err);

    io::printfn("%s", (ZString)buf[:1024]);
}