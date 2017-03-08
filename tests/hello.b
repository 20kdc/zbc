main() {
 auto nbuf[8];
 puts("What is your name? ");
 gets(nbuf);
 puts("Hello ");
 puts(nbuf);
 puts("!*n");
}

puts(str) {
 extrn outbyte;
 auto c, i;
 i = 0;
 // Notably, specification is deliberately broken here,
 //  as it is better to use \x00 as a string terminator.
 // This will be a pattern between ZBC backends,
 //  though it should be configurable in some manner.
 while ((c = char(str, i++)) != '*e') {
  outbyte(c);
 }
}

gets(str) {
 auto i, c;
 extrn inbyte;
 i = 0;
 while ((c = inbyte()) != 10)
  lchar(str, i++, c);
 lchar(str, i, '*e');
}