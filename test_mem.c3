import std::io;

fn void in_pool(Allocator allocator)
{
    @pool() 
    {
        io::printfn("in_pool, check result: %s", allocator == tmem);
    };
}

fn void no_pool(Allocator allocator)
{
    io::printfn("no_pool, check result: %s", allocator == tmem);
}


fn void main()
{
   in_pool(tmem); 
   no_pool(tmem);
}
