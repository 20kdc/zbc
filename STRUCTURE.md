# ZBC Project Structure

## core

This folder is for valid passes which are absolutely required to get 
from code string to unprocessed AST.

(Which, if not using any language 
extensions like compile-time constant evaluation, should be 
non-optimally compilable by outputs.)

## output

This folder is for valid passes which turn any valid AST not using 
language extensions like compile-time constant evaluation into the
resulting assembler-ready string.

(This does not limit the pass - a pass *can* accept extensions if it wants,
this is simply not recommended when the extensions are better 
implemented via AST passes - which are universal.)

## pass

This folder is for valid passes which turn ASTs into transformed ASTs.
They can do anything they want to the AST so long as it's specified in 
 the pass description - a pass which adds tracing function calls is legitimate.

Usually, this should be used for optimizing passes, or in the case of 
 consteval, language extensions that handle parsable but "disallowed" 
 code which can be transformed into correct code anyway.

## / (root folder)

The root folder contains common Lua requirables, assorted files, and runnable programs.

`ast.lua` is a requirable.

`graph.lua` and `zbc.lua` are runnable programs.

`rot13.b`, and this file (`STRUCTURE.md`) are assorted files.
