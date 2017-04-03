mkdir temp
# Deal with zpu-char now so it won't show up in the diff
lua zbc.lua core.lex -- core.par -- pass.zpu-char < tests/$1.b > temp/test.ast
# Optimization pass
lua zbc.lua pass.consteval -I -C -B -DWORD_CHARS 4 -DWORD_VALS 4 -- pass.optswitch < temp/test.ast > temp/test-st2.ast
diff -u temp/test.ast temp/test-st2.ast > temp/cnstdiff.diff
lua graph.lua < temp/test-st2.ast > temp/test.dot
dot -Tsvg temp/test.dot > temp/test.svg
lua zbc.lua pass.mkextern __asm__ __asmnv__ -- output.zpu < temp/test-st2.ast
