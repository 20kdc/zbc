// I, 20kdc, release this file into the public domain.
// No warranty is provided, implied or otherwise.

main() {
 extrn inbyte, outbyte, putn;
 auto a, n;
 auto ama[4];
 n = 0;
 while (1) {
  a = inbyte();
  switch (a) {
   case 'a':
    outbyte('A');
   // The fallthrough should mean this switch can't be sanely optimized. For now.
   case 'b':
    outbyte('B');
    break;
   case 'c':
    outbyte('C');
    putn(++n);
    outbyte('C');
    putn(n++);
    break;
   case 10:
    break;
   case '.':
    putn(n);
    break;
   case '#':
    putn(ama[n]++);
    break;
   case '+':
    outbyte('K');
    n++;
    break;
   default:
    outbyte('?');
    break;
  }
  outbyte(10);
 }
 outbyte('X');
}