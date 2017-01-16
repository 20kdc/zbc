lua zbc.lua > test.ast
lua cnsteval.lua WORD_CHARS 4 < test.ast > test-st2.ast
diff -u test.ast test-st2.ast > cnstdiff.diff
lua graph.lua < test-st2.ast > test.dot
dot -Tsvg test.dot > test.svg
