import cmd;
import std::io;

fn void test_execute_cat() @test
{
	String output = cmd::execute_to_string(tmem, {"cat", "cmd.c3"})!!;
	io::printfn("%s", output);
}