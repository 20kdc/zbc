mkdir temp
lua zbc.lua core.lex -- core.par < test.b > temp/test.ast
lua zbc.lua pass.consteval -I -C -B -DWORD_CHARS 4 -DWORD_VALS 4 < temp/test.ast > temp/test-st2.ast
diff -u temp/test.ast temp/test-st2.ast > temp/cnstdiff.diff
lua graph.lua < temp/test-st2.ast > temp/test.dot
dot -Tsvg temp/test.dot > temp/test.svg
lua zbc.lua output.zpu < temp/test-st2.ast
