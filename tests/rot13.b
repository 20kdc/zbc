main() {
 extrn inbyte, outbyte, rot13;
 auto b;
 while (1) {
  b = inbyte();
  if ((b >= 'a') & (b <= 'z'))
   b = rot13('a', b);
  if ((b >= 'A') & (b <= 'Z'))
   b = rot13('A', b);
  outbyte(b);
 }
}

rot13(ch, t) {
 t =- ch - 13;
 t =% 26;
 return t + ch;
}