// #include <stdio.h>

// int main(int argc, char *argv[], char *envp[]) {
//     printf("Environment Variables:\n");
//     for (int i = 0; envp[i] != NULL; i++) {
//         printf("%s\n", envp[i]);
//     }
//     return 0;
// }

import std::io;

fn void main() @export("_main") => unreachable();
fn int _main(int argc, ZString* argv, ZString* environ) @export("main")
{
  for (usz i  = 0; environ[i] != null; i++)
  {
    io::printfn("%s", environ[i]);
  }


  return 0;
}