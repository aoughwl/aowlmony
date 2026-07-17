import std/syncio

# int64 that overflows: fast mode (JS number) loses precision, faithful
# (BigInt) wraps exactly like native — a --faithful discriminator.
var a: int64 = 9223372036854775807'i64   # INT64_MAX
echo a
var b: int64 = a + 1'i64                  # wraps to INT64_MIN faithfully
echo b
