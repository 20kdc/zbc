// Quick test (cannot actually be executed) for Honeywell B stuff.

vectorauto() {
 auto a[4]; // auto a 4; in PDP syntax.
 a[0] = 0;
 a[1] = 1;
 a[2] = 2;
 a[3] = 3;
}

noextrn() {
 // Test for Honeywell B not caring about extrn.
 // (Essentially, it has an 'extrn-by-default' policy.)
 // This is implemented as the pass "mkextern", so the backend doesn't 
 //  have to worry about this and can rely on storage type annotations.
 nsa();
}

breaking() {
 auto a;
 a = 0;
 // Test for Honeywell B break
 while (a) {
  a--;
  if (nsa())
   break;
 }
}
