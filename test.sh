lua zbc.lua > test.ast
lua graph.lua < test.ast > test.dot
dot -Tsvg test.dot > test.svg
