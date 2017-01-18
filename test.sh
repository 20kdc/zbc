mkdir temp
lua zbc.lua < test.b > temp/test.ast
lua cnsteval.lua -C -B -DWORD_CHARS 4 < temp/test.ast > temp/test-st2.ast
diff -u temp/test.ast temp/test-st2.ast > temp/cnstdiff.diff
lua graph.lua < temp/test-st2.ast > temp/test.dot
dot -Tsvg temp/test.dot > temp/test.svg
lua output/zpu/init.lua < temp/test-st2.ast
