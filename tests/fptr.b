/* Force a few different conditions */
a(b) {
 b(1); /* by pointer */
}
c(b) {
 a(b); /* by label */
}
d(b) {
 b[0](b); /* by complex pointer */
}
