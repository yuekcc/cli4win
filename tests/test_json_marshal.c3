import std::io;
import std::collections::object;
import json;

struct FunctionParameterDef {
    String type;
    String description;
}

struct ExecuteCommandParameterDef {
    FunctionParameterDef command;
}


struct ParametersDef {
    String type;
    String[] required;
    ExecuteCommandParameterDef properties;
}


struct FunctionDef {
    String name;
    String description;
    ParametersDef parameters;
}

struct Tool {
    String type;
    FunctionDef function;
}


fn void main()
{
    Tool bash = {
        .type = "function",
        .function = {
            .name = "execute_command",
            .description = "Run shell commands in the terminal, ensuring proper handling and security measures.Before using this tool, verify that the command is not one of the banned commands: rm, make. User is using BASH as shell. DO NOT need to try in other shell when get error.",
            .parameters = {
                .type = "object",
                .required = {"command"},
                .properties = {
                    .command = {
                        .type = "string",
                        .description = "The command to execute. 需要执行的命令"
                    }
                }
            }
        }
    };

    DString buf = dstring::new(tmem);
    json::marshal(bash, &buf)!!;


    io::printfn("%s", buf.str_view());
}