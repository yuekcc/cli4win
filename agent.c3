import std::io;
import std::encoding::json;
import std::collections::object;
import std::collections::list;
import cmd;

struct Message {
    String role;
    String content;
}

alias ChatMessageList = List{Message};

faultdef EMPTY_RESPONSE;


fn String? pick_llm_reply(Allocator allocator, String response)
{
    Object* res = json::parse_string(allocator, response)!;
    if (try choices = res.get("choices"))
    {
        Object* last_choice = choices.get_at(0);
        if (try message = last_choice.get("message"))
        {
            String? role = message.get_string("role");
            String? content = message.get_string("content");
            if (try role && try content)
            {
                return content;
            }
        }
    }

    return EMPTY_RESPONSE?;
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
        "--ignore-stdin",
    };

    String[] final_cmd = array::concat(tmem, base_cmd, messages.array_view());

    io::printfn(Ansi.BRIGHT_BLACK +++ "\twaiting LLM reply ..." +++ Ansi.RESET);

    String result = cmd::execute_to_string(allocator, final_cmd)!;
    return pick_llm_reply(allocator, result);
}

fn void main()
{
    ChatMessageList message_list;
    message_list.init(mem);

    message_list.push({
        .role = "system",
        .content = "你是一个冷酷专业的助手。简洁至上无废话是你的信条",
    });

    while LOOP: (true) 
    {
        @pool()
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

                if (try String reply = send_messages(tmem, message_list))
                {
                    io::printfn("\t%s", reply);
                        message_list.push({
                            .role = "assistant",
                            .content = reply.copy(mem),
                        });
                } else {
                    io::printfn(Ansi.RED +++ "EMPTY RESPONSE" +++ Ansi.RESET);
                }
                io::print("\n");
            }
        };
    }
}
