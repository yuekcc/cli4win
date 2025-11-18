import std::io;
import std::encoding::json;
import std::collections::object;
import std::collections::list;
import cmd;

const SYSTEM_PROMPT = `You are an AI assistant with Napoleon Dynamite's personality. 
Say things like 'Gosh!', 'Sweet!', 'Idiot!', and be awkwardly enthusiastic. 
For multi-step tasks, chain commands with && (e.g., 'echo content > file.py && python3 file.py'). 
Use execute_command for shell tasks. Answer questions in Napoleon's quirky style. 
User is on Windows 11. 尽量使用简体中文回答`;

struct Message {
    String role;
    String content;
    Object* tool_calls;
}

alias ChatMessageList = List{Message};

faultdef EMPTY_RESPONSE;

macro String error_message(String $format)
{
    return Ansi.RED +++ $format +++ Ansi.RESET;
}

macro String system_message(String $format)
{
    return Ansi.BRIGHT_BLACK +++ $format +++ Ansi.RESET;
}


fn Message? extract_response(Allocator allocator, String response)
{
    io::printfn(system_message("server response: %s"), response);

    Object* res = json::parse_string(allocator, response)!;
    Object* choices = res.get("choices")!;

    Object* last_choice = choices.get_at(0);
    if (try message = last_choice.get("message"))
    {
        String? role = message.get_string("role");
        String? content = message.get_string("content");
        Object*? tool_calls = message.get("tool_calls");
        if (try tool_calls) {
            return {
                .role = (role ?? "assistant").copy(allocator),
                .content = (content ?? "").copy(allocator),
                .tool_calls = tool_calls,
            }; 
        }
        else
        {
            return {
                .role = (role ?? "assistant").copy(allocator),
                .content = content.copy(allocator),
            };
        }
    }

    return EMPTY_RESPONSE?;
}

fn void print_history(ChatMessageList history)
{
    foreach (&record : history)
    {
        io::printfn("# %s", record.role);
        io::printfn("%s\n", record.content.trim());
    }
}

fn String? send_messages(Allocator allocator, ChatMessageList history) {

    List{String} messages;
    messages.init(tmem);

    foreach (i, &record : history)
    {
        messages.push(string::format(tmem, "messages[%d][role]=%s", i, record.role));
        messages.push(string::format(tmem, "messages[%d][content]=%s", i, record.content));
    }

    String[] base_cmd = {
        "xh",
        "post",
        "http://127.0.0.1:9981/v1/chat/completions",
        "--stream",
        "--ignore-stdin",
        "tool_choice=auto",
        "tools[0][type]=function",
        "tools[0][function][name]=execute_command",
        "tools[0][function][description]=\"Execute shell command. Use 'cmd /c as runner on Windows 11.'\"",
        "tools[0][function][parameters][type]=object",
        "tools[0][function][parameters][properties][command][type]=string",
        "tools[0][function][parameters][required][0]=command",
    };

    String[] final_cmd = array::concat(tmem, base_cmd, messages.array_view());

    io::printn(system_message("waiting for reply ..."));

    String? result = cmd::execute_to_string(tmem, final_cmd);
    if (try result) 
    {
        return result.copy(allocator);
    }
    else
    {
        return EMPTY_RESPONSE?;
    }
}

faultdef EXECUTE_COMMAND_ERROR;

fn Message? execute_command(Allocator allocator, Object* tool_calls)
{
    @pool()
    {
        Object* function_call = tool_calls.get_at(0);
        io::printfn(system_message("find function_call declares: %s"), function_call);

        if (function_call)
        {
            Object* function_call_details = function_call.get("function")!;
            // io::printfn("function_call_details decl: %s", function_call_details);

            // TODO 异常处理

            String function_name = function_call_details.get_string("name")!;
            String arguments = function_call_details.get_string("arguments")!;

            Object* res = json::parse_string(tmem, arguments)!;
            if (try String command = res.get_string("command"))
            {
                io::printfn(system_message("Execute command: %s"), command);

                $if env::WIN32:
                String[] cmd = {
                    "cmd",
                    "/c",
                    command
                };
                $else
                String[] cmd = {
                    "sh",
                    "/c",
                    command
                };
                $endif

                cmd::CommandResult cmd_result = cmd::execute(tmem, cmd)!;
                io::printfn(system_message("Command output:\n%s"), cmd_result.output);

                String message;
                if (cmd_result.code == 0)
                {
                    message = cmd_result.output.copy(allocator);
                }
                else
                {
                    message = string::format(
                        allocator, 
                        "Execute command failed.\nMaybe your should try in another way command.\nExecute command line: %s.\nReturn code is %d\nand feedback: %s", 
                        command,
                        cmd_result.code, 
                        cmd_result.output);
                }

                return {
                    .role = "tool",
                    .content = message,
                };
            }
        }

        return EXECUTE_COMMAND_ERROR?;
    };
}

fn void main()
{
    ChatMessageList message_list;
    message_list.init(mem);

    message_list.push({
        .role = "system",
        .content = SYSTEM_PROMPT,
    });

    bool calling_tools = false;

    int retry_on_error = 0;
    while LOOP: (true)
    {    
        @pool()
        {
            if (!calling_tools)
            {
                io::print(Ansi.BOLD +++ Ansi.GREEN +++ ">>> ");
                String? input = io::treadline();
                io::print(Ansi.RESET);
                if (try input)
                {
                    message_list.push({
                        .role = "user",
                        .content = input.copy(mem),
                    });
                }
            }

            if (try String reply = send_messages(tmem, message_list))
            {
                if (try Message message = extract_response(tmem, reply))
                {
                    io::printfn("%s", message.content);
                    if (message.tool_calls != null)
                    {
                        Message? tool_response = execute_command(tmem, message.tool_calls);
                        if (catch err = tool_response)
                        {
                            io::printfn(error_message("Execute command failed, %s"), err);
                            message_list.push({
                                .role= "tool",
                                .content = string::format(mem, "execute command with cmd /c failed, for %s", err)
                            });
                            calling_tools = true;
                        }
                        else
                        {
                            message_list.push(tool_response);
                            calling_tools = true;
                        }
                    } else {
                        calling_tools = false;
                        message_list.push(message);
                    }
                }
            }
            else
            {
                io::printn(error_message("BAD RESPONSE"));
                retry_on_error += 1;

                if (retry_on_error > 5)
                {
                    io::printn(error_message("retry more than 5 times, force exit"));
                    print_history(message_list);
                    break LOOP;
                }

            }
            io::print("\n");
        };
    }
}
