#define NIM_INTBITS 64
/* GENERATED CODE. DO NOT EDIT. */

#ifdef __cplusplus
#  if __cplusplus >= 201103L
#    /* nullptr is more type safe (less implicit conversions than 0) */
#    define NIM_NIL nullptr
#  else
#    // both `((void*)0)` and `NULL` would cause codegen to emit
#    // error: assigning to 'Foo *' from incompatible type 'void *'
#    // but codegen could be fixed if need. See also potential caveat regarding
#    // NULL.
#    // However, `0` causes other issues, see #13798
#    define NIM_NIL 0
#  endif
#else
#  include <stdbool.h>
#  define NIM_NIL NULL
#endif

#ifdef __cplusplus
#define NB8 bool
#elif (defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901)
// see #13798: to avoid conflicts for code emitting `#include <stdbool.h>`
#define NB8 _Bool
#else
typedef unsigned char NB8; // best effort
#endif

typedef unsigned char NC8;

typedef float NF32;
typedef double NF64;
#if defined(__BORLANDC__) || defined(_MSC_VER)
typedef signed char NI8;
typedef signed short int NI16;
typedef signed int NI32;
typedef __int64 NI64;
/* XXX: Float128? */
typedef unsigned char NU8;
typedef unsigned short int NU16;
typedef unsigned int NU32;
typedef unsigned __int64 NU64;
#elif defined(HAVE_STDINT_H)
#ifndef USE_NIM_NAMESPACE
#  include <stdint.h>
#endif
typedef int8_t NI8;
typedef int16_t NI16;
typedef int32_t NI32;
typedef int64_t NI64;
typedef uint8_t NU8;
typedef uint16_t NU16;
typedef uint32_t NU32;
typedef uint64_t NU64;
#elif defined(HAVE_CSTDINT)
#ifndef USE_NIM_NAMESPACE
#  include <cstdint>
#endif
typedef std::int8_t NI8;
typedef std::int16_t NI16;
typedef std::int32_t NI32;
typedef std::int64_t NI64;
typedef std::uint8_t NU8;
typedef std::uint16_t NU16;
typedef std::uint32_t NU32;
typedef std::uint64_t NU64;
#else
/* Unknown compiler/version, do our best */
#ifdef __INT8_TYPE__
typedef __INT8_TYPE__ NI8;
#else
typedef signed char NI8;
#endif
#ifdef __INT16_TYPE__
typedef __INT16_TYPE__ NI16;
#else
typedef signed short int NI16;
#endif
#ifdef __INT32_TYPE__
typedef __INT32_TYPE__ NI32;
#else
typedef signed int NI32;
#endif
#ifdef __INT64_TYPE__
typedef __INT64_TYPE__ NI64;
#else
typedef long long int NI64;
#endif
/* XXX: Float128? */
#ifdef __UINT8_TYPE__
typedef __UINT8_TYPE__ NU8;
#else
typedef unsigned char NU8;
#endif
#ifdef __UINT16_TYPE__
typedef __UINT16_TYPE__ NU16;
#else
typedef unsigned short int NU16;
#endif
#ifdef __UINT32_TYPE__
typedef __UINT32_TYPE__ NU32;
#else
typedef unsigned int NU32;
#endif
#ifdef __UINT64_TYPE__
typedef __UINT64_TYPE__ NU64;
#else
typedef unsigned long long int NU64;
#endif
#endif

#ifdef NIM_INTBITS
#  if NIM_INTBITS == 64
typedef NI64 NI;
typedef NU64 NU;
#  elif NIM_INTBITS == 32
typedef NI32 NI;
typedef NU32 NU;
#  elif NIM_INTBITS == 16
typedef NI16 NI;
typedef NU16 NU;
#  elif NIM_INTBITS == 8
typedef NI8 NI;
typedef NU8 NU;
#  else
#    error "invalid bit width for int"
#  endif
#endif

#define NIM_TRUE true
#define NIM_FALSE false

#define _GNU_SOURCE

// Include math.h to use `NAN` that should be defined in C compilers supports C99.
#include <math.h>

// Define NAN in case math.h doesn't define it.
// NAN definition copied from math.h included in the Windows SDK version 10.0.14393.0
#ifndef NAN
#  ifndef _HUGE_ENUF
#    define _HUGE_ENUF  1e+300  // _HUGE_ENUF*_HUGE_ENUF must overflow
#  endif
#  define NAN_INFINITY ((float)(_HUGE_ENUF * _HUGE_ENUF))
#  define NAN ((float)(NAN_INFINITY * 0.0F))
#endif

#ifndef INF
#  ifdef INFINITY
#    define INF INFINITY
#  elif defined(HUGE_VAL)
#    define INF  HUGE_VAL
#  elif defined(_MSC_VER)
#    include <float.h>
#    define INF (DBL_MAX+DBL_MAX)
#  else
#    define INF (1.0 / 0.0)
#  endif
#endif

#if defined(__GNUC__) || defined(_MSC_VER)
#  define IL64(x) x##LL
#else /* works only without LL */
#  define IL64(x) ((NI64)x)
#endif


/* ------------ ignore typical warnings in Nim-generated files ------------- */
#if defined(__GNUC__) || defined(__clang__)
#  pragma GCC diagnostic ignored "-Wswitch-bool"
#  pragma GCC diagnostic ignored "-Wformat"
#  pragma GCC diagnostic ignored "-Wpointer-sign"
#  if defined(__clang__)
#    pragma GCC diagnostic ignored "-Wincompatible-pointer-types-discards-qualifiers"
#  else
#    pragma GCC diagnostic ignored "-Wdiscarded-qualifiers"
#  endif
#endif



/* ------------------------------------------------------------------- */
#ifdef  __cplusplus
#  define NIM_EXTERNC extern "C"
#else
#  define NIM_EXTERNC
#endif

#if defined(WIN32) || defined(_WIN32) /* only Windows has this mess... */
#  define N_LIB_PRIVATE
#  define N_CDECL(rettype, name) rettype __cdecl name
#  define N_STDCALL(rettype, name) rettype __stdcall name
#  define N_SYSCALL(rettype, name) rettype __syscall name
#  define N_FASTCALL(rettype, name) rettype __fastcall name
#  define N_THISCALL(rettype, name) rettype __thiscall name
#  define N_SAFECALL(rettype, name) rettype __stdcall name
/* function pointers with calling convention: */
#  define N_CDECL_PTR(rettype, name) rettype (__cdecl *name)
#  define N_STDCALL_PTR(rettype, name) rettype (__stdcall *name)
#  define N_SYSCALL_PTR(rettype, name) rettype (__syscall *name)
#  define N_FASTCALL_PTR(rettype, name) rettype (__fastcall *name)
#  define N_THISCALL_PTR(rettype, name) rettype (__thiscall *name)
#  define N_SAFECALL_PTR(rettype, name) rettype (__stdcall *name)

#  ifdef __EMSCRIPTEN__
#    define N_LIB_EXPORT  NIM_EXTERNC __declspec(dllexport) __attribute__((used))
#    define N_LIB_EXPORT_VAR  __declspec(dllexport) __attribute__((used))
#  else
#    define N_LIB_EXPORT  NIM_EXTERNC __declspec(dllexport)
#    define N_LIB_EXPORT_VAR  __declspec(dllexport)
#  endif
#  define N_LIB_IMPORT  extern __declspec(dllimport)
#else
#  define N_LIB_PRIVATE __attribute__((visibility("hidden")))
#  if defined(__GNUC__)
#    define N_CDECL(rettype, name) rettype name
#    define N_STDCALL(rettype, name) rettype name
#    define N_SYSCALL(rettype, name) rettype name
#    define N_FASTCALL(rettype, name) __attribute__((fastcall)) rettype name
#    define N_SAFECALL(rettype, name) rettype name
/*   function pointers with calling convention: */
#    define N_CDECL_PTR(rettype, name) rettype (*name)
#    define N_STDCALL_PTR(rettype, name) rettype (*name)
#    define N_SYSCALL_PTR(rettype, name) rettype (*name)
#    define N_FASTCALL_PTR(rettype, name) __attribute__((fastcall)) rettype (*name)
#    define N_SAFECALL_PTR(rettype, name) rettype (*name)
#  else
#    define N_CDECL(rettype, name) rettype name
#    define N_STDCALL(rettype, name) rettype name
#    define N_SYSCALL(rettype, name) rettype name
#    define N_FASTCALL(rettype, name) rettype name
#    define N_SAFECALL(rettype, name) rettype name
/*   function pointers with calling convention: */
#    define N_CDECL_PTR(rettype, name) rettype (*name)
#    define N_STDCALL_PTR(rettype, name) rettype (*name)
#    define N_SYSCALL_PTR(rettype, name) rettype (*name)
#    define N_FASTCALL_PTR(rettype, name) rettype (*name)
#    define N_SAFECALL_PTR(rettype, name) rettype (*name)
#  endif
#  ifdef __EMSCRIPTEN__
#    define N_LIB_EXPORT NIM_EXTERNC __attribute__((visibility("default"), used))
#    define N_LIB_EXPORT_VAR  __attribute__((visibility("default"), used))
#  else
#    define N_LIB_EXPORT NIM_EXTERNC __attribute__((visibility("default")))
#    define N_LIB_EXPORT_VAR  __attribute__((visibility("default")))
#  endif
#  define N_LIB_IMPORT  extern
#endif

#if defined(__BORLANDC__) || defined(_MSC_VER) || defined(WIN32) || defined(_WIN32)
/* these compilers have a fastcall so use it: */
#  define N_NIMCALL(rettype, name) rettype __fastcall name
#  define N_NIMCALL_PTR(rettype, name) rettype (__fastcall *name)
#else
#  define N_NIMCALL(rettype, name) rettype name /* no modifier */
#  define N_NIMCALL_PTR(rettype, name) rettype (*name)
#endif

#define N_NOCONV(rettype, name) rettype name
/* specify no calling convention */
#define N_NOCONV_PTR(rettype, name) rettype (*name)

/* calling convention mess ----------------------------------------------- */
#if defined(__GNUC__) || defined(__TINYC__)
  /* these should support C99's inline */
#  define N_INLINE(rettype, name) inline rettype name
#elif defined(__BORLANDC__) || defined(_MSC_VER)
/* Borland's compiler is really STRANGE here; note that the __fastcall
   keyword cannot be before the return type, but __inline cannot be after
   the return type, so we do not handle this mess in the code generator
   but rather here. */
#  define N_INLINE(rettype, name) __inline rettype name
#else /* others are less picky: */
#  define N_INLINE(rettype, name) rettype __inline name
#endif

#define N_INLINE_PTR(rettype, name) rettype (*name)

#if defined(__GNUC__) || defined(__ICC__)
#  define N_NOINLINE __attribute__((__noinline__))
#elif defined(_MSC_VER)
#  define N_NOINLINE __declspec(noinline)
#else
#  define N_NOINLINE
#endif

#define N_NOINLINE_PTR(rettype, name) rettype (*name)

#if defined(_MSC_VER)
#  define NIM_ALIGN(x)  __declspec(align(x))
#  define NIM_ALIGNOF(x) __alignof(x)
#else
#  define NIM_ALIGN(x)  __attribute__((aligned(x)))
#  define NIM_ALIGNOF(x) __alignof__(x)
#endif

#include <stddef.h>


/*
  NIM_THREADVAR declaration based on
  https://stackoverflow.com/questions/18298280/how-to-declare-a-variable-as-thread-local-portably
*/
#if defined _WIN32
#  if defined _MSC_VER || defined __BORLANDC__
#    define NIM_THREADVAR __declspec(thread)
#  else
#    define NIM_THREADVAR __thread
#  endif
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112 && !defined __STDC_NO_THREADS__
#  define NIM_THREADVAR _Thread_local
#elif defined _WIN32 && ( \
       defined _MSC_VER || \
       defined __ICL || \
       defined __BORLANDC__ )
#  define NIM_THREADVAR __declspec(thread)
#elif defined(__TINYC__) || defined(__GENODE__)
#  define NIM_THREADVAR
/* note that ICC (linux) and Clang are covered by __GNUC__ */
#elif defined __GNUC__ || \
       defined __SUNPRO_C || \
       defined __xlC__
#  define NIM_THREADVAR __thread
#else
#  error "Cannot define NIM_THREADVAR"
#endif

/* define NIM_STATIC_ASSERT */
#if defined(__cplusplus)
#define NIM_STATIC_ASSERT(x, msg) static_assert((x), msg)
#else
#define NIM_STATIC_ASSERT(x, msg) _Static_assert((x), msg)
#endif

// Test to see if Nim and the C compiler agree on the size of a pointer.
NIM_STATIC_ASSERT(sizeof(NI) == sizeof(void*) && NIM_INTBITS == sizeof(NI)*8, "Pointer size mismatch between Nim and C/C++ backend. You probably need to setup the backend compiler for target CPU.");

N_INLINE(NB8, _Qlengc_div_sll_overflow)(long long int a, long long int b, long long int *res) {
  if (b == 0) {
    *res = 0;
    return NIM_TRUE;
  }
  if (a == (long long int)(((unsigned long long int)1) << (sizeof(long long int) * 8 - 1)) && b == -1) {
    *res = a;
    return NIM_TRUE;
  }
  *res = a / b;
  return NIM_FALSE;
}

N_INLINE(NB8, _Qlengc_div_sl_overflow)(long int a, long int b, long int *res) {
  if (b == 0) {
    *res = 0;
    return NIM_TRUE;
  }
  if (a == (long int)(((unsigned long int)1) << (sizeof(long int) * 8 - 1)) && b == -1) {
    *res = a;
    return NIM_TRUE;
  }
  *res = a / b;
  return NIM_FALSE;
}

N_INLINE(NB8, _Qlengc_div_ull_overflow)(unsigned long long int a, unsigned long long int b, unsigned long long int *res) {
  if (b == 0) {
    *res = 0;
    return NIM_TRUE; /* Overflow: division by zero */
  }
  *res = a / b;
  return NIM_FALSE;
}

N_INLINE(NB8, _Qlengc_div_ul_overflow)(unsigned long int a, unsigned long int b, unsigned long int *res) {
  if (b == 0) {
    *res = 0;
    return NIM_TRUE;
  }
  *res = a / b;
  return NIM_FALSE;
}

N_INLINE(NB8, _Qlengc_mod_sll_overflow)(long long int a, long long int b, long long int *res) {
  if (b == 0) {
    *res = 0;
    return NIM_TRUE;
  }
  if (a == (long long int)(((unsigned long long int)1) << (sizeof(long long int) * 8 - 1)) && b == -1) {
    *res = 0;
    return NIM_TRUE;
  }
  *res = a % b;
  return NIM_FALSE;
}

N_INLINE(NB8, _Qlengc_mod_sl_overflow)(long int a, long int b, long int *res) {
  if (b == 0) {
    *res = 0;
    return NIM_TRUE;
  }
  if (a == (long int)(((unsigned long int)1) << (sizeof(long int) * 8 - 1)) && b == -1) {
    *res = 0;
    return NIM_TRUE;
  }
  *res = a % b;
  return NIM_FALSE;
}

N_INLINE(NB8, _Qlengc_mod_ull_overflow)(unsigned long long int a, unsigned long long int b, unsigned long long int *res) {
  if (b == 0) {
    *res = 0;
    return NIM_TRUE;
  }
  *res = a % b;
  return NIM_FALSE;
}

N_INLINE(NB8, _Qlengc_mod_ul_overflow)(unsigned long int a, unsigned long int b, unsigned long int *res) {
  if (b == 0) {
    *res = 0;
    return NIM_TRUE;
  }
  *res = a % b;
  return NIM_FALSE;
}
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <dlfcn.h>
typedef struct LongString_0_sysvq0asl LongString_0_sysvq0asl;
typedef struct Rtti_0_sysvq0asl Rtti_0_sysvq0asl;
typedef struct CoroutineBase_0_sysvq0asl CoroutineBase_0_sysvq0asl;
typedef struct Continuation_0_sysvq0asl Continuation_0_sysvq0asl;
typedef struct Exception_0_sysvq0asl Exception_0_sysvq0asl;
typedef struct LongString_0_sysvq0asl{
  NI64 fullLen_0;
  NI64 rc_0;
  NI64 capImpl_0;
  NC8 data_0[];}
LongString_0_sysvq0asl;
typedef struct string_0_sysvq0asl{
  NU64 bytes_0;
  LongString_0_sysvq0asl* more_0;}
string_0_sysvq0asl;
typedef struct RootObj_0_sysvq0asl{
  Rtti_0_sysvq0asl* vt_00;}
RootObj_0_sysvq0asl;
typedef struct mi_stat_count_t{
  NI64 total_0;
  NI64 peak_0;
  NI64 current_0;}
mi_stat_count_t;
typedef struct mi_stats_t{
  int version_0;
  mi_stat_count_t pages_0;
  mi_stat_count_t reserved_0;
  mi_stat_count_t committed_0;
  mi_stat_count_t reset_0;
  mi_stat_count_t purged_0;
  mi_stat_count_t pageQ_committed_0;
  mi_stat_count_t pagesQ_abandoned_0;
  mi_stat_count_t threads_0;
  mi_stat_count_t mallocQ_normal_0;
  mi_stat_count_t mallocQ_huge_0;
  mi_stat_count_t mallocQ_requested_0;}
mi_stats_t;
typedef struct Rtti_0_sysvq0asl{
  NI64 dl_0;
  NU32* dy_0;
  void* mt_0[];}
Rtti_0_sysvq0asl;
typedef struct Single_0_sysvq0asl{
  NU32 bits_0;}
Single_0_sysvq0asl;
typedef struct FloatingDecimal32_0_sysvq0asl{
  NU32 digits_0;
  NI64 exponent_0;}
FloatingDecimal32_0_sysvq0asl;
typedef struct Double_0_sysvq0asl{
  NU64 bits_0;}
Double_0_sysvq0asl;
typedef struct uint64x2_0_sysvq0asl{
  NU64 hi_0;
  NU64 lo_0;}
uint64x2_0_sysvq0asl;
typedef struct MulCmp_0_sysvq0asl{
  NU64 mul_0;
  NU64 cmp_0;}
MulCmp_0_sysvq0asl;
typedef struct FloatingDecimal64_0_sysvq0asl{
  NU64 significand_0;
  NI64 exponent_0;}
FloatingDecimal64_0_sysvq0asl;
typedef NU8 ErrorCode_0_sysvq0asl;

#define Success_0_sysvq0asl ((NU8)IL64(0))
#define OverflowError_0_sysvq0asl ((NU8)IL64(1))
#define Failure_0_sysvq0asl ((NU8)IL64(2))
#define BugError_0_sysvq0asl ((NU8)IL64(3))
#define IndexError_0_sysvq0asl ((NU8)IL64(4))
#define RangeError_0_sysvq0asl ((NU8)IL64(5))
#define OverlapError_0_sysvq0asl ((NU8)IL64(6))
#define SyntaxError_0_sysvq0asl ((NU8)IL64(7))
#define OutOfMemError_0_sysvq0asl ((NU8)IL64(8))
#define DiskFullError_0_sysvq0asl ((NU8)IL64(9))
#define StackOverflow_0_sysvq0asl ((NU8)IL64(10))
#define IOError_0_sysvq0asl ((NU8)IL64(11))
#define ValueError_0_sysvq0asl ((NU8)IL64(12))
#define KeyError_0_sysvq0asl ((NU8)IL64(13))
#define EndOfStreamError_0_sysvq0asl ((NU8)IL64(14))
#define SkipError_0_sysvq0asl ((NU8)IL64(15))
#define FullError_0_sysvq0asl ((NU8)IL64(16))
#define EmptyError_0_sysvq0asl ((NU8)IL64(17))
#define BusyError_0_sysvq0asl ((NU8)IL64(18))
#define DeadResource_0_sysvq0asl ((NU8)IL64(19))
#define ResourceExhaustedError_0_sysvq0asl ((NU8)IL64(20))
#define DescriptorExhaustedError_0_sysvq0asl ((NU8)IL64(21))
#define PermissionDenied_0_sysvq0asl ((NU8)IL64(22))
#define RetryError_0_sysvq0asl ((NU8)IL64(23))
#define TimeoutError_0_sysvq0asl ((NU8)IL64(24))
#define InterruptedError_0_sysvq0asl ((NU8)IL64(25))
#define DeadlockError_0_sysvq0asl ((NU8)IL64(26))
#define LockedError_0_sysvq0asl ((NU8)IL64(27))
#define FormatMismatch_0_sysvq0asl ((NU8)IL64(28))
#define AlreadyConnected_0_sysvq0asl ((NU8)IL64(29))
#define AddressNotAvailable_0_sysvq0asl ((NU8)IL64(30))
#define AddressFamilyUnsupported_0_sysvq0asl ((NU8)IL64(31))
#define BadOperation_0_sysvq0asl ((NU8)IL64(32))
#define AbortedOperation_0_sysvq0asl ((NU8)IL64(33))
#define UnimplementedOperation_0_sysvq0asl ((NU8)IL64(34))
#define AlreadyInProgress_0_sysvq0asl ((NU8)IL64(35))
#define NameTooLong_0_sysvq0asl ((NU8)IL64(36))
#define NameExists_0_sysvq0asl ((NU8)IL64(37))
#define NameNotFound_0_sysvq0asl ((NU8)IL64(38))
#define ContentTooLong_0_sysvq0asl ((NU8)IL64(39))
#define BadDescriptor_0_sysvq0asl ((NU8)IL64(40))
#define BadExecutable_0_sysvq0asl ((NU8)IL64(41))
#define BadLink_0_sysvq0asl ((NU8)IL64(42))
#define BadProtocol_0_sysvq0asl ((NU8)IL64(43))
#define ProtocolError_0_sysvq0asl ((NU8)IL64(44))
#define ReadonlyProtection_0_sysvq0asl ((NU8)IL64(45))
#define SegFault_0_sysvq0asl ((NU8)IL64(46))
#define DiskCorruption_0_sysvq0asl ((NU8)IL64(47))
#define Disconnected_0_sysvq0asl ((NU8)IL64(48))
#define RefusedConnection_0_sysvq0asl ((NU8)IL64(49))
#define UnreachableHost_0_sysvq0asl ((NU8)IL64(50))
#define UnrecoverableState_0_sysvq0asl ((NU8)IL64(51))
#define AuthenticationRequired_0_sysvq0asl ((NU8)IL64(52))
#define RedirectError_0_sysvq0asl ((NU8)IL64(53))
#define Reserved1_0_sysvq0asl ((NU8)IL64(54))
#define Reserved2_0_sysvq0asl ((NU8)IL64(55))
#define Reserved3_0_sysvq0asl ((NU8)IL64(56))
#define Reserved4_0_sysvq0asl ((NU8)IL64(57))
#define Reserved5_0_sysvq0asl ((NU8)IL64(58))
#define Reserved6_0_sysvq0asl ((NU8)IL64(59))
#define Reserved7_0_sysvq0asl ((NU8)IL64(60))
#define Reserved8_0_sysvq0asl ((NU8)IL64(61))
#define Reserved9_0_sysvq0asl ((NU8)IL64(62))
typedef N_NIMCALL_PTR(Continuation_0_sysvq0asl,  X60Qt_0_IAptrSX43oroutineX42ase0sysvq0aslZSX43ontinuation0R22AnimcallZAfalseZAR61_sysvq0asl)(CoroutineBase_0_sysvq0asl*);
typedef struct Continuation_0_sysvq0asl{
  X60Qt_0_IAptrSX43oroutineX42ase0sysvq0aslZSX43ontinuation0R22AnimcallZAfalseZAR61_sysvq0asl fn_0;
  CoroutineBase_0_sysvq0asl* env_0;}
Continuation_0_sysvq0asl;
typedef struct CoroutineBase_0_sysvq0asl{
  RootObj_0_sysvq0asl Q;
  Continuation_0_sysvq0asl caller_0;
  CoroutineBase_0_sysvq0asl* callee_0;}
CoroutineBase_0_sysvq0asl;
typedef NU8 TypeOfMode_0_sysvq0asl;

#define typeOfProc_0_sysvq0asl ((NU8)IL64(0))
#define typeOfIter_0_sysvq0asl ((NU8)IL64(1))
typedef struct Exception_0_sysvq0asl{
  RootObj_0_sysvq0asl Q;
  string_0_sysvq0asl msg_0;}
Exception_0_sysvq0asl;
typedef struct openArray_0_Ijk0jkw1_sysvq0asl{
  NC8* a_0;
  NI64 len_0;}
openArray_0_Ijk0jkw1_sysvq0asl;
typedef struct HSlice_0_I6e0t4q1_sysvq0asl{
  NI64 a_0;
  NI64 b_0;}
HSlice_0_I6e0t4q1_sysvq0asl;
typedef struct HSlice_0_Ii5kgy01_sysvq0asl{
  NI64 a_0;
  NI64 b_0;}
HSlice_0_Ii5kgy01_sysvq0asl;
typedef struct X60Qt_0_IArefSX52ootX4fbj0sysvq0asl_sysvq0asl{
  NI r_00;
  RootObj_0_sysvq0asl d_00;}
X60Qt_0_IArefSX52ootX4fbj0sysvq0asl_sysvq0asl;
typedef struct X60Qt_0_IAarraySstring0sysvq0aslS10_sysvq0asl{
  string_0_sysvq0asl a[IL64(10)];}
X60Qt_0_IAarraySstring0sysvq0aslS10_sysvq0asl;
typedef N_NIMCALL_PTR(void,  X60Qt_0_ISEAnimcallZAfalseZAR11_sysvq0asl)(void);
typedef struct X60Qt_0_IAarrayAuS8ZS256_sysvq0asl{
  NU8 a[IL64(256)];}
X60Qt_0_IAarrayAuS8ZS256_sysvq0asl;
typedef N_NIMCALL_PTR(void,  X60Qt_0_IAiS64ZSEAnimcallZAfalseZAR17_sysvq0asl)(NI64);
typedef struct X60Qt_0_IAarrayAiS8ZS100_sysvq0asl{
  NI8 a[IL64(100)];}
X60Qt_0_IAarrayAiS8ZS100_sysvq0asl;
typedef struct X60Qt_0_IAarrayAcS8ZS200_sysvq0asl{
  NC8 a[IL64(200)];}
X60Qt_0_IAarrayAcS8ZS200_sysvq0asl;
typedef struct X60Qt_0_IAarrayAuS64ZS77_sysvq0asl{
  NU64 a[IL64(77)];}
X60Qt_0_IAarrayAuS64ZS77_sysvq0asl;
typedef struct X60Qt_0_IAarraySuint64x20sysvq0aslS619_sysvq0asl{
  uint64x2_0_sysvq0asl a[IL64(619)];}
X60Qt_0_IAarraySuint64x20sysvq0aslS619_sysvq0asl;
typedef struct X60Qt_0_IAarraySX4dulX43mp0sysvq0aslS25_sysvq0asl{
  MulCmp_0_sysvq0asl a[IL64(25)];}
X60Qt_0_IAarraySX4dulX43mp0sysvq0aslS25_sysvq0asl;
typedef struct X60Qt_0_IAarrayAcS8ZS16_sysvq0asl{
  NC8 a[IL64(16)];}
X60Qt_0_IAarrayAcS8ZS16_sysvq0asl;
typedef struct X60Qt_0_IAarrayAcS8ZS65_sysvq0asl{
  NC8 a[IL64(65)];}
X60Qt_0_IAarrayAcS8ZS65_sysvq0asl;
typedef N_NIMCALL_PTR(Continuation_0_sysvq0asl,  X60Qt_0_ISX43ontinuation0sysvq0aslSR0AnimcallZAfalseZAR37_sysvq0asl)(Continuation_0_sysvq0asl);
typedef N_NIMCALL_PTR(void,  X60Qt_0_IAptrSX43oroutineX42ase0sysvq0aslZSEAnimcallZAfalseZAR44_sysvq0asl)(CoroutineBase_0_sysvq0asl*);
typedef struct X60Qt_0_IArefSX45xception0sysvq0asl_sysvq0asl{
  NI r_00;
  Exception_0_sysvq0asl d_00;}
X60Qt_0_IArefSX45xception0sysvq0asl_sysvq0asl;
typedef N_NIMCALL_PTR(void,  X60Qt_0_ISX45xception0sysvq0aslSEAnimcallZAfalseZAR33_sysvq0asl)(Exception_0_sysvq0asl*);
N_CDECL(void*, mi_malloc)(size_t size_7);
N_CDECL(void, mi_free)(void* p_7);
static inline void arcInc_0_sysvq0asl(NI64* memLoc_0);
static inline NB8 arcDec_0_sysvq0asl(NI64* memLoc_1);
void raiseIndexError3_0_Ice8haj1_sysvq0asl(NI64 i_65, NI64 a_45, NI64 b_34);
void raiseIndexError3_0_Ils6gq61_sysvq0asl(NU64 i_66, NU64 a_46, NU64 b_35);
LongString_0_sysvq0asl const strlit_0_I15539159382304113184_sysvq0asl = {
  .fullLen_0 = IL64(27), .rc_0 = IL64(0), .capImpl_0 = IL64(0), .data_0 = "invalid object conversion: "}
;
LongString_0_sysvq0asl const strlit_0_I14281474217946372742_sysvq0asl = {
  .fullLen_0 = IL64(35), .rc_0 = IL64(0), .capImpl_0 = IL64(0), .data_0 = "cannot dispatch; dispatcher is nil\012"}
;
LongString_0_sysvq0asl const strlit_0_I16690852185662743073_sysvq0asl = {
  .fullLen_0 = IL64(16), .rc_0 = IL64(0), .capImpl_0 = IL64(0), .data_0 = "could not load: "}
;
LongString_0_sysvq0asl const strlit_0_I10604297744791418982_sysvq0asl = {
  .fullLen_0 = IL64(18), .rc_0 = IL64(0), .capImpl_0 = IL64(0), .data_0 = "could not import: "}
;
LongString_0_sysvq0asl const strlit_0_I11614695157650328859_sysvq0asl = {
  .fullLen_0 = IL64(21), .rc_0 = IL64(0), .capImpl_0 = IL64(0), .data_0 = "index out of bounds: "}
;
X60Qt_0_ISEAnimcallZAfalseZAR11_sysvq0asl gExitFlush_0_sysvq0asl;
__thread NI64 missingBytes_0_sysvq0asl;
X60Qt_0_IAiS64ZSEAnimcallZAfalseZAR17_sysvq0asl oomHandler_0_sysvq0asl;
__thread X60Qt_0_IArefSX45xception0sysvq0asl_sysvq0asl* exc_0_sysvq0asl;
NB8 X60QiniGuard_0_sysvq0asl;
N_NIMCALL(void, nimNoopFlush_0_sysvq0asl)(void){
  }
void nimFlushStdStreams(void){
  gExitFlush_0_sysvq0asl();}
static inline void copyMem_0_sysvq0asl(void* dest_4, void* src_3, NI64 size_3){
  memcpy(dest_4, src_3, ((size_t)size_3));}
void* alloc_0_sysvq0asl(NI64 size_10){
  void* result_30;
  void* X60Qx_73 = mi_malloc(((size_t)size_10));
  result_30 = X60Qx_73;
  return result_30;}
void dealloc_0_sysvq0asl(void* p_10){
  mi_free(p_10);}
N_NIMCALL(void, continueAfterOutOfMem_0_sysvq0asl)(NI64 size_14){
  if (missingBytes_0_sysvq0asl < ((NI64)(((NI64)IL64(9223372036854775807)) - size_14))){
    missingBytes_0_sysvq0asl = ((NI64)(missingBytes_0_sysvq0asl + size_14));}
  else {
    missingBytes_0_sysvq0asl = ((NI64)IL64(9223372036854775807));}}
static inline NI64 ssLenOf_0_sysvq0asl(NU64 bytes_0){
  NI64 result_57;
  result_57 = ((NI64)((NU64)(bytes_0 & 255ull)));
  return result_57;}
static inline NI64 len_4_sysvq0asl(string_0_sysvq0asl s_32){
  NI64 result_60;
  result_60 = ((NI64)(*((NU8*)(&s_32.bytes_0))));
  if (((NI64)IL64(14)) < result_60){
    result_60 = (*s_32.more_0).fullLen_0;}
  return result_60;}
static inline NC8* readRawData_0_sysvq0asl(string_0_sysvq0asl* s_37, NI64 start_0){
  NC8* result_65;
  if (((NI64)IL64(14)) < ((NI64)(*((NU8*)(&(*s_37).bytes_0))))){
    result_65 = ((NC8*)((NU64)(((NU64)(&(*(*s_37).more_0).data_0[IL64(0)])) + ((NU64)start_0))));}
  else {
    result_65 = ((NC8*)((NU64)(((NU64)((NC8*)((NU64)(((NU64)(&(*s_37).bytes_0)) + 1ull)))) + ((NU64)start_0))));}
  return result_65;}
static inline void nimStrWasMoved(string_0_sysvq0asl* s_38){
  (*s_38).bytes_0 = ((NU64)IL64(0));}
static inline void nimStrDestroy(string_0_sysvq0asl s_39){
  if (((NI64)(*((NU8*)(&s_39.bytes_0)))) == ((NI64)IL64(255))){
    NB8 X60Qx_80 = arcDec_0_sysvq0asl((&(*s_39.more_0).rc_0));
    if (X60Qx_80){
      dealloc_0_sysvq0asl(((void*)s_39.more_0));}}}
void nimStrCopy(string_0_sysvq0asl* dest_9, string_0_sysvq0asl src_6){
  NI64 ssrc_0 = ((NI64)(*((NU8*)(&src_6.bytes_0))));
  if (ssrc_0 <= ((NI64)IL64(14))){
    NI64 sdest_0 = ((NI64)(*((NU8*)(&(*dest_9).bytes_0))));
    if (sdest_0 == ((NI64)IL64(255))){
      NB8 X60Qx_81 = arcDec_0_sysvq0asl((&(*(*dest_9).more_0).rc_0));
      if (X60Qx_81){
        dealloc_0_sysvq0asl(((void*)(*dest_9).more_0));}}
    copyMem_0_sysvq0asl(((void*)(&(*dest_9).bytes_0)), ((void*)(&src_6.bytes_0)), sizeof(string_0_sysvq0asl));}
  else {
    if ((&(*dest_9)) == (&src_6)){
      return;}
    NI64 sdest_1 = ((NI64)(*((NU8*)(&(*dest_9).bytes_0))));
    if (sdest_1 == ((NI64)IL64(255))){
      NB8 X60Qx_82 = arcDec_0_sysvq0asl((&(*(*dest_9).more_0).rc_0));
      if (X60Qx_82){
        dealloc_0_sysvq0asl(((void*)(*dest_9).more_0));}}
    if (ssrc_0 == ((NI64)IL64(255))){
      arcInc_0_sysvq0asl((&(*src_6.more_0).rc_0));}
    copyMem_0_sysvq0asl(((void*)(&(*dest_9).bytes_0)), ((void*)(&src_6.bytes_0)), sizeof(string_0_sysvq0asl));}}
static inline string_0_sysvq0asl nimStrDup(string_0_sysvq0asl s_40){
  string_0_sysvq0asl result_66;
  NI64 X60Qx_83 = ssLenOf_0_sysvq0asl(s_40.bytes_0);
  if (X60Qx_83 == ((NI64)IL64(255))){
    arcInc_0_sysvq0asl((&(*s_40.more_0).rc_0));}
  result_66 = (string_0_sysvq0asl){
    .bytes_0 = s_40.bytes_0, .more_0 = s_40.more_0}
  ;
  return result_66;}
static inline NI64 len_5_sysvq0asl(NC8* a_10){
  NI64 result_67;
  NI64 X60Qx_14;
  if (((void*)a_10) == NIM_NIL){
    X60Qx_14 = IL64(0);}
  else {
    size_t X60Qx_84 = strlen(a_10);
    X60Qx_14 = ((NI64)X60Qx_84);}
  result_67 = X60Qx_14;
  return result_67;}
string_0_sysvq0asl borrowCStringUnsafe_0_sysvq0asl(NC8* s_59, NI64 l_0){
  string_0_sysvq0asl result_101;
  nimStrWasMoved((&result_101));
  nimStrDestroy(result_101);
  result_101 = (string_0_sysvq0asl){
    .bytes_0 = 0ull, .more_0 = NIM_NIL}
  ;
  if (l_0 <= IL64(0)){
    return result_101;}
  if (l_0 <= ((NI64)IL64(14))){
    (*((NU8*)(&result_101.bytes_0))) = ((NU8)l_0);
    copyMem_0_sysvq0asl(((void*)((NC8*)((NU64)(((NU64)(&result_101.bytes_0)) + 1ull)))), ((void*)s_59), l_0);}
  else {
    void* X60Qx_170 = alloc_0_sysvq0asl(((NI64)(((NI64)IL64(24)) + l_0)));
    LongString_0_sysvq0asl* p_23 = ((LongString_0_sysvq0asl*)X60Qx_170);
    if ((!(p_23 == NIM_NIL))){
      (*p_23).rc_0 = IL64(0);
      (*p_23).fullLen_0 = l_0;
      (*p_23).capImpl_0 = l_0;
      copyMem_0_sysvq0asl(((void*)(&(*p_23).data_0[IL64(0)])), ((void*)s_59), l_0);
      result_101.more_0 = p_23;
      (*((NU8*)(&result_101.bytes_0))) = ((NU8)((NI64)IL64(255)));
      copyMem_0_sysvq0asl(((void*)((NC8*)((NU64)(((NU64)(&result_101.bytes_0)) + 1ull)))), ((void*)(&(*p_23).data_0[IL64(0)])), ((NI64)IL64(7)));}
    else {
      oomHandler_0_sysvq0asl(((NI64)(((NI64)IL64(24)) + l_0)));
      result_101.bytes_0 = ((NU64)21760775509248519ull);
      result_101.more_0 = NIM_NIL;}}
  return result_101;}
string_0_sysvq0asl nimBorrowCStringUnsafe(NC8* s_60){
  string_0_sysvq0asl result_102;
  nimStrWasMoved((&result_102));
  nimStrDestroy(result_102);
  NI64 X60Qx_171 = len_5_sysvq0asl(s_60);
  string_0_sysvq0asl X60Qx_172 = borrowCStringUnsafe_0_sysvq0asl(s_60, X60Qx_171);
  result_102 = X60Qx_172;
  return result_102;}
static inline void arcInc_0_sysvq0asl(NI64* memLoc_0){
  NI64 X60Qx_177 = __atomic_add_fetch((&(*memLoc_0)), IL64(1), __ATOMIC_SEQ_CST);}
static inline NB8 arcDec_0_sysvq0asl(NI64* memLoc_1){
  NB8 result_118;
  NI64 X60Qx_178 = __atomic_sub_fetch((&(*memLoc_1)), IL64(1), __ATOMIC_SEQ_CST);
  result_118 = (X60Qx_178 < IL64(0));
  return result_118;}
void writeErr_0_sysvq0asl(NI64 x_311){
  fprintf(stderr, "%lld", x_311);}
void writeErr_1_sysvq0asl(NU64 x_312){
  fprintf(stderr, "%llu", x_312);}
void writeErr_2_sysvq0asl(string_0_sysvq0asl s_66){
  NC8* X60Qx_180 = readRawData_0_sysvq0asl((&s_66), IL64(0));
  NI64 X60Qx_181 = len_4_sysvq0asl(s_66);
  NU64 X60Qx_182 = fwrite(((void*)X60Qx_180), 1ull, ((NU64)X60Qx_181), stderr);}
void writeErr_3_sysvq0asl(NC8* s_67){
  NI64 X60Qx_183 = len_5_sysvq0asl(s_67);
  NU64 X60Qx_184 = fwrite(((void*)s_67), 1ull, ((NU64)X60Qx_183), stderr);}
static inline NI64 nimIcheckAB(NI64 i_18, NI64 a_32, NI64 b_18){
  NI64 result_120;
  NB8 X60Qx_185;
  if (a_32 <= i_18){
    X60Qx_185 = (i_18 <= b_18);}
  else {
    X60Qx_185 = NIM_FALSE;}
  if (X60Qx_185){
    result_120 = ((NI64)(i_18 - a_32));}
  else {
    result_120 = IL64(0);
    raiseIndexError3_0_Ice8haj1_sysvq0asl(i_18, a_32, b_18);}
  return result_120;}
static inline NI64 nimIcheckB(NI64 i_19, NI64 b_19){
  NI64 result_121;
  NB8 X60Qx_186;
  if (IL64(0) <= i_19){
    X60Qx_186 = (i_19 <= b_19);}
  else {
    X60Qx_186 = NIM_FALSE;}
  if (X60Qx_186){
    result_121 = i_19;}
  else {
    result_121 = IL64(0);
    raiseIndexError3_0_Ice8haj1_sysvq0asl(i_19, IL64(0), b_19);}
  return result_121;}
static inline NU64 nimUcheckAB(NU64 i_20, NU64 a_33, NU64 b_20){
  NU64 result_122;
  result_122 = ((NU64)(i_20 - a_33));
  if (b_20 < result_122){
    raiseIndexError3_0_Ils6gq61_sysvq0asl(i_20, a_33, b_20);}
  return result_122;}
static inline NU64 nimUcheckB(NU64 i_21, NU64 b_21){
  NU64 result_123;
  result_123 = i_21;
  if (b_21 < result_123){
    raiseIndexError3_0_Ils6gq61_sysvq0asl(i_21, ((NU64)IL64(0)), b_21);}
  return result_123;}
static inline void nimInvalidObjConv(string_0_sysvq0asl name_0){
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 7235433442201987582ull, .more_0 = (&strlit_0_I15539159382304113184_sysvq0asl)}
  );
  writeErr_2_sysvq0asl(name_0);
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 2561ull, .more_0 = NIM_NIL}
  );
  exit(((NI32)IL64(1)));}
static inline void nimChckNilDisp(void* p_15){
  if (p_15 == NIM_NIL){
    writeErr_2_sysvq0asl((string_0_sysvq0asl){
      .bytes_0 = 2338616626601092094ull, .more_0 = (&strlit_0_I14281474217946372742_sysvq0asl)}
    );
    exit(((NI32)IL64(1)));}}
void procAddrError_0_sysvq0asl(NC8* name_1){
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 7935452960416293886ull, .more_0 = (&strlit_0_I10604297744791418982_sysvq0asl)}
  );
  writeErr_3_sysvq0asl(name_1);
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 2561ull, .more_0 = NIM_NIL}
  );
  exit(((NI32)IL64(1)));}
void* nimLoadLibrary(NC8* path_2){
  void* result_124;
  int flags_0 = ((NI32)IL64(2));
  void* X60Qx_187 = dlopen(path_2, flags_0);
  result_124 = X60Qx_187;
  return result_124;}
void* nimGetProcAddr(void* lib_3, NC8* name_3){
  void* result_125;
  void* X60Qx_188 = dlsym(lib_3, name_3);
  result_125 = X60Qx_188;
  if (result_125 == NIM_NIL){
    procAddrError_0_sysvq0asl(name_3);}
  return result_125;}
void* nimDynlibLoadStep(void* prev_0, NC8* cand_0){
  void* result_126;
  if ((!(prev_0 == NIM_NIL))){
    result_126 = prev_0;}
  else {
    void* X60Qx_189 = nimLoadLibrary(cand_0);
    result_126 = X60Qx_189;}
  return result_126;}
void* nimDynlibCheck(void* lib_4, NC8* path_3){
  void* result_127;
  if (lib_4 == NIM_NIL){
    writeErr_2_sysvq0asl((string_0_sysvq0asl){
      .bytes_0 = 7935452960416293886ull, .more_0 = (&strlit_0_I16690852185662743073_sysvq0asl)}
    );
    writeErr_3_sysvq0asl(path_3);
    writeErr_2_sysvq0asl((string_0_sysvq0asl){
      .bytes_0 = 2561ull, .more_0 = NIM_NIL}
    );
    exit(((NI32)IL64(1)));}
  result_127 = lib_4;
  return result_127;}
void raiseIndexError3_0_Ice8haj1_sysvq0asl(NI64 i_65, NI64 a_45, NI64 b_34){
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 8007532514336729598ull, .more_0 = (&strlit_0_I11614695157650328859_sysvq0asl)}
  );
  writeErr_0_sysvq0asl(i_65);
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 2336921205458477063ull, .more_0 = NIM_NIL}
  );
  writeErr_0_sysvq0asl(a_45);
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 3026434ull, .more_0 = NIM_NIL}
  );
  writeErr_0_sysvq0asl(b_34);
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 2561ull, .more_0 = NIM_NIL}
  );
  exit(((NI32)IL64(1)));}
void raiseIndexError3_0_Ils6gq61_sysvq0asl(NU64 i_66, NU64 a_46, NU64 b_35){
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 8007532514336729598ull, .more_0 = (&strlit_0_I11614695157650328859_sysvq0asl)}
  );
  writeErr_1_sysvq0asl(i_66);
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 2336921205458477063ull, .more_0 = NIM_NIL}
  );
  writeErr_1_sysvq0asl(a_46);
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 3026434ull, .more_0 = NIM_NIL}
  );
  writeErr_1_sysvq0asl(b_35);
  writeErr_2_sysvq0asl((string_0_sysvq0asl){
    .bytes_0 = 2561ull, .more_0 = NIM_NIL}
  );
  exit(((NI32)IL64(1)));}
void eQwasmovedQ_ArefSX45xception0sysvq0asl_0_sysvq0asl(X60Qt_0_IArefSX45xception0sysvq0asl_sysvq0asl** dest_0){
  (*dest_0) = NIM_NIL;}
void X60Qini_0_sysvq0asl(void){
  if (X60QiniGuard_0_sysvq0asl){
    return;}
  X60QiniGuard_0_sysvq0asl = NIM_TRUE;
  eQwasmovedQ_ArefSX45xception0sysvq0asl_0_sysvq0asl((&exc_0_sysvq0asl));}
static void __attribute__((constructor)) init(void) {gExitFlush_0_sysvq0asl = nimNoopFlush_0_sysvq0asl;
oomHandler_0_sysvq0asl = continueAfterOutOfMem_0_sysvq0asl;
}

