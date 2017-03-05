putn(n) {
 extrn outbyte;
 if (!n) {
  outbyte('0');
  return 1;
 }
 auto pow, n2, ch;
 ch = 0;
 if (n < 0) {
  outbyte('-');
  ch++;
  n = -n;
 }
 n2 = n / 10;
 pow = 1;
 while (n2) {
  pow =* 10;
  n2 =/ 10;
 }
 while (pow) {
  outbyte('0' + (n / pow));
  n =% pow;
  pow =/ 10;
  ch++;
 }
 return ch;
}