import std::io;
import std::collections::object;

fn void main()
{
    Object* parameters_obj = object::new_obj(mem);
    parameters_obj.set("type", "object");

    Object* function_obj = object::new_obj(mem);
    function_obj.set("name", "execute_command");
    function_obj.set("description", "Execute shell command. Use 'cmd /c as runner on Windows 11.'");
    function_obj.set_object("parameters", parameters_obj);

    Object* tools = object::new_obj(mem);
    tools.set("type", "function");
    tools.set_object("function", function_obj);

    Object* obj = object::new_obj(mem);
    obj.set("tool_choice", "auto");
    obj.set_object("tools", tools);

    io::printfn("%s", obj);
}