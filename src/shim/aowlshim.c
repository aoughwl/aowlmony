/* aowlshim - the native trampoline that lets our parser and semchecker be
   reached on Windows.

   nimony's findTool(name) (src/lib/tooldirs.nim) only ever tests
   `name & ExeExt` in the current directory before falling back to its own
   bin/.  On Windows ExeExt is ".exe", and Windows will not exec a shell
   script under that name however it is spelled - so the bash `nifler` and
   `nimsem` shims the driver stages are not "found and failed", they are
   never looked at, and every run silently degrades to nimony's own nifler
   and nimsem.  A pure passthrough (the hexer shim) can dodge this by
   staging the real binary under the name nimony looks for; the nifler and
   nimsem shims cannot, because they carry routing logic:

     nifler  the user's own module goes to aowlparser, the standard library
             to the real nifler, and the --deps import sidecar is still the
             real nifler's job (aowlparser emits none).
     nimsem  a plain single-module `m` is aowlsem's, with nimsem's argv
             translated to aowlsem's; a cyclic module GROUP and every other
             subcommand stay nimony's.  The `x` indexer is mechanical and is
             reused as-is.

   So the routing has to live in something Windows will exec under the name
   `nifler.exe`.  This is that: one small program, staged twice, which picks
   its role from argv[0] and takes its wiring from the environment the
   driver already exports.  It is the logic of shimScript() and
   semShimScript() in bin/aowlmony, which remain the POSIX path.

   Wiring (set by the driver, inherited through nimony):
     AOWLSHIM_NIFLER   real nifler         AOWLSHIM_PARSER  aowlparser
     AOWLSHIM_NIMSEM   real nimsem         AOWLSHIM_SEM     aowlsem
     AOWLSHIM_LIB      nimony's lib/ dir   NIFRW_USER       user module(s),
                                                            PATH-separated

   Built on demand by the driver; see buildShimExe() in bin/aowlmony.  */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <limits.h>
#include <unistd.h>
#include <sys/wait.h>
#endif

#define MAXARG 512

static void die(const char *msg) {
  fprintf(stderr, "aowlshim: %s\n", msg);
  exit(127);
}

static char *xstrdup(const char *s) {
  char *r = strdup(s ? s : "");
  if (!r) die("out of memory");
  return r;
}

static const char *envOr(const char *name, const char *dflt) {
  const char *v = getenv(name);
  return (v && *v) ? v : dflt;
}

/* AOWLSHIM_DEBUG=<file> appends every invocation and the routing decision it
   led to.  A shim that silently defers is indistinguishable from a shim that
   was never reached, and telling those two apart from the outside cost a
   whole session once already. */
static void trace(const char *fmt, ...) {
  const char *f = getenv("AOWLSHIM_DEBUG");
  FILE *fp;
  va_list ap;
  if (!f || !*f) return;
  fp = fopen(f, "a");
  if (!fp) return;
  va_start(ap, fmt);
  vfprintf(fp, fmt, ap);
  va_end(ap);
  fputc('\n', fp);
  fclose(fp);
}

/* ---------- paths ---------------------------------------------------- */

/* Canonical form for comparing two spellings of the same file: absolute,
   and on Windows separator- and case-folded.  A user module reaches us as
   whatever nimony chose to pass; NIFRW_USER is what the driver resolved.
   Comparing the raw strings would make isUserModule a coin flip. */
static char *canon(const char *p) {
  char buf[4096];
  if (!p || !*p) return xstrdup("");
#ifdef _WIN32
  if (!GetFullPathNameA(p, (DWORD)sizeof(buf), buf, NULL)) return xstrdup(p);
  {
    char *q;
    for (q = buf; *q; q++) {
      if (*q == '/') *q = '\\';
      *q = (char)tolower((unsigned char)*q);
    }
  }
#else
  if (!realpath(p, buf)) return xstrdup(p);
#endif
  return xstrdup(buf);
}

static int endsWith(const char *s, const char *suf) {
  size_t n = strlen(s), m = strlen(suf);
  if (m > n) return 0;
#ifdef _WIN32
  return _stricmp(s + n - m, suf) == 0;
#else
  return strcmp(s + n - m, suf) == 0;
#endif
}

static const char *baseName(const char *p) {
  const char *b = p, *q;
  for (q = p; *q; q++)
    if (*q == '/' || *q == '\\') b = q + 1;
  return b;
}

/* ---------- running a child ------------------------------------------ */

#ifdef _WIN32
/* Quote one argument the way the CRT's command-line parser will undo it.
   Every path here lives under C:\Users\<name>\, so a join-on-spaces would
   eventually split one in half. */
static void appendQuoted(char *dst, size_t cap, const char *arg) {
  size_t n = strlen(dst);
  const char *p;
  int needs = (*arg == '\0');
  for (p = arg; *p; p++)
    if (*p == ' ' || *p == '\t' || *p == '"') { needs = 1; break; }
  if (n + strlen(arg) * 2 + 4 >= cap) die("command line too long");
  if (n) dst[n++] = ' ';
  if (!needs) { strcpy(dst + n, arg); return; }
  dst[n++] = '"';
  for (p = arg; *p; p++) {
    if (*p == '\\') {
      size_t slashes = 0, i, emit;
      while (*p == '\\') { slashes++; p++; }
      /* backslashes are literal unless they precede a quote */
      emit = (*p == '"' || *p == '\0') ? slashes * 2 : slashes;
      for (i = 0; i < emit; i++) dst[n++] = '\\';
      if (*p == '\0') break;
    }
    if (*p == '"') dst[n++] = '\\';
    dst[n++] = *p;
  }
  dst[n++] = '"';
  dst[n] = '\0';
}

static int runv(const char *exe, char **argv, int argc, const char *outfile, int quiet) {
  static char cmd[32768];
  SECURITY_ATTRIBUTES sa;
  HANDLE hOut = INVALID_HANDLE_VALUE, hNul = INVALID_HANDLE_VALUE;
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  DWORD rc = 1;
  int i;

  cmd[0] = '\0';
  appendQuoted(cmd, sizeof(cmd), exe);
  for (i = 0; i < argc; i++) appendQuoted(cmd, sizeof(cmd), argv[i]);

  sa.nLength = sizeof(sa); sa.lpSecurityDescriptor = NULL; sa.bInheritHandle = TRUE;
  ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
  si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  si.hStdError  = GetStdHandle(STD_ERROR_HANDLE);

  if (outfile) {
    hOut = CreateFileA(outfile, GENERIC_WRITE, FILE_SHARE_READ, &sa,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hOut == INVALID_HANDLE_VALUE) {
      fprintf(stderr, "aowlshim: cannot write %s\n", outfile);
      return 127;
    }
    si.hStdOutput = hOut;
  }
  if (quiet) {
    hNul = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                       OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hNul != INVALID_HANDLE_VALUE) { si.hStdOutput = hNul; si.hStdError = hNul; }
  }

  if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
    fprintf(stderr, "aowlshim: cannot run %s (error %lu)\n", exe,
            (unsigned long)GetLastError());
    if (hOut != INVALID_HANDLE_VALUE) CloseHandle(hOut);
    if (hNul != INVALID_HANDLE_VALUE) CloseHandle(hNul);
    return 127;
  }
  WaitForSingleObject(pi.hProcess, INFINITE);
  GetExitCodeProcess(pi.hProcess, &rc);
  CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
  if (hOut != INVALID_HANDLE_VALUE) CloseHandle(hOut);
  if (hNul != INVALID_HANDLE_VALUE) CloseHandle(hNul);
  return (int)rc;
}
#else
static int runv(const char *exe, char **argv, int argc, const char *outfile, int quiet) {
  char *av[MAXARG + 2];
  int n = 0, i, st = 0;
  pid_t pid;
  av[n++] = (char *)exe;
  for (i = 0; i < argc && n < MAXARG; i++) av[n++] = argv[i];
  av[n] = NULL;
  pid = fork();
  if (pid < 0) return 127;
  if (pid == 0) {
    if (outfile) { if (!freopen(outfile, "wb", stdout)) _exit(127); }
    else if (quiet) {
      if (!freopen("/dev/null", "wb", stdout)) _exit(127);
      if (!freopen("/dev/null", "wb", stderr)) _exit(127);
    }
    execv(exe, av);
    _exit(127);
  }
  waitpid(pid, &st, 0);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
#endif

/* ---------- nifler role ---------------------------------------------- */

/* NIFRW_USER holds the module(s) the driver considers the user's own,
   separated by the platform's PATH separator.  It is ';' on Windows: a ':'
   split would cut C:\... in half at the drive letter. */
static int isUserModule(const char *infile) {
  const char *users = getenv("NIFRW_USER");
  char sep, *want, *copy, *p, *e, *c;
  int hit = 0;
  if (!users || !*users || !infile || !*infile) return 0;
#ifdef _WIN32
  sep = ';';
#else
  sep = ':';
#endif
  want = canon(infile);
  copy = xstrdup(users);
  p = copy;
  while (*p) {
    e = strchr(p, sep);
    if (e) *e = '\0';
    if (*p) {
      c = canon(p);
      if (strcmp(c, want) == 0) hit = 1;
      free(c);
    }
    if (!e) break;
    p = e + 1;
  }
  free(copy); free(want);
  return hit;
}

static int roleNifler(int argc, char **argv) {
  const char *real = envOr("AOWLSHIM_NIFLER", "");
  const char *parser = envOr("AOWLSHIM_PARSER", "");
  char *pos[MAXARG];
  int nPos = 0, wantsDeps = 0, i;
  const char *infile = NULL, *outfile = NULL;

  if (!*real) die("AOWLSHIM_NIFLER is not set");

  for (i = 1; i < argc; i++) {
    char *a = argv[i];
    if (strncmp(a, "--deps", 6) == 0) { if (strcmp(a, "--deps") == 0) wantsDeps = 1; continue; }
    if (strcmp(a, "--portablePaths") == 0 || strcmp(a, "-f") == 0 ||
        strcmp(a, "--forceRebuild") == 0) continue;
    if (nPos >= MAXARG) die("too many arguments");
    if (strcmp(a, "p") == 0 || strcmp(a, "parse") == 0) { pos[nPos++] = (char *)"p"; continue; }
    if (endsWith(a, ".nim")) { infile = a; pos[nPos++] = a; continue; }
    if (endsWith(a, ".nif") || endsWith(a, ".aif")) { outfile = a; pos[nPos++] = a; continue; }
    pos[nPos++] = a;
  }

  if (!*parser || !infile || !isUserModule(infile)) {
    trace("nifler: -> real nifler (in=%s user=%s)", infile ? infile : "-",
          getenv("NIFRW_USER") ? getenv("NIFRW_USER") : "-");
    return runv(real, argv + 1, argc - 1, NULL, 0);
  }
  trace("nifler: -> aowlparser (in=%s out=%s deps=%d)", infile,
        outfile ? outfile : "-", wantsDeps);

  /* the real nifler still writes the --deps import sidecar; aowlparser emits
     none, and nimony's build graph needs one. */
  if (wantsDeps) runv(real, argv + 1, argc - 1, NULL, 1);

  /* aowlparser's [out] positional writes nothing, so the parse goes to
     stdout and is redirected onto the path nimony asked for - which also
     overwrites the .p.nif the --deps run above left behind. */
  if (outfile) {
    char *pa[3];
    pa[0] = (char *)"p"; pa[1] = (char *)infile; pa[2] = (char *)"-";
    return runv(parser, pa, 3, outfile, 0);
  }
  return runv(parser, pos, nPos, NULL, 0);
}

/* ---------- nimsem role ---------------------------------------------- */

/* The `--base:` aowlsem is given is NOT the one nimony hands nimsem.

   nifler writes every line-info file name RELATIVE TO ITS OWN CWD
   (nimony/src/nifler/bridge.nim: relativePath(..., getCurrentDir())), and
   nimsem reads them back with absolutePath() - anchored to the cwd again, so
   that round trip closes wherever the compiler runs.  aowlsem instead anchors
   them to `--base:`, which nimony derives from the DIRECTORY OF THE MAIN FILE
   ON ITS COMMAND LINE (src/lib/argsfinder.nim, determineBaseDir).  Those two
   name the same directory only when the compiler is run from the project -
   and this driver never is: it compiles from its own stage, so that nimony's
   findTool() finds our shims there.

   The visible cost was a `.compile` pragma's ${path} resolving off a directory
   the file has no relation to.  system/mimalloc.nim asks for
   ${path}/../../../vendor/mimalloc/src/static.c; anchored to the stage's
   grandparent instead of the stage, the `..` chain walked past the drive root
   and every field collapsed to a bare stem - nimony/vendor/mimalloc/src/
   static.c, unanchored, with `-DMI_STAT=1 -I` eaten off the flags beside it.
   cc then reported `No such file or directory` for a file that exists, named
   relatively, from a directory that never held it.

   Spell it with forward slashes, too.  aowlsem resolves `..` by splitting on
   '/' alone (lexicalAbsPath/collapseDots in aowlsem.nim), so a backslashed
   C:\Users\...\stage is ONE segment and the first `..` deletes the whole prefix
   rather than one directory - which is what turned an absolute path into that
   stem.  Measured on this machine: a backslashed cwd reproduces the failure
   exactly, a forward-slashed one yields the absolute path and the full flag
   string.  Dropping `--base:` is not the alternative: with no base aowlsem
   emits no `(build ...)` node at all, and the link then dies on `undefined
   reference to mi_malloc`. */
static const char *semBase(void) {
  static char buf[4096 + 8];
  char cwd[4096];
  char *q;
#ifdef _WIN32
  if (!GetCurrentDirectoryA((DWORD)sizeof(cwd), cwd)) return NULL;
#else
  if (!getcwd(cwd, sizeof(cwd))) return NULL;
#endif
  for (q = cwd; *q; q++) if (*q == '\\') *q = '/';
  snprintf(buf, sizeof(buf), "--base:%s", cwd);
  return buf;
}

static int roleNimsem(int argc, char **argv) {
  const char *real = envOr("AOWLSHIM_NIMSEM", "");
  const char *sem = envOr("AOWLSHIM_SEM", "");
  const char *lib = envOr("AOWLSHIM_LIB", "");
  const char *base = NULL, *nc = NULL, *in;
  char mode = 0;
  int seenCmd = 0, isSystem = 0, nFiles = 0, ns = 0, rc, i;
  char *files[MAXARG], *sa[MAXARG], *xa[2], *paths[MAXARG];
  char out[4096], pflag[4096];
  size_t n, sl;
  int nPaths = 0;

  if (!*real) die("AOWLSHIM_NIMSEM is not set");

  for (i = 1; i < argc; i++) {
    char *a = argv[i];
    if (!seenCmd) {
      if (strncmp(a, "--base:", 7) == 0) { /* replaced by semBase(), above */ }
      else if (strncmp(a, "--nimcache:", 11) == 0) nc = a;
      /* nimony forwards its own -p: to nimsem as --path:.  aowlsem resolves
         the import graph itself, so it needs every one of them, not just the
         stdlib below - a mod compiled against its SDK has no other way to
         find it. */
      else if (strncmp(a, "--path:", 7) == 0 || strncmp(a, "-p:", 3) == 0) {
        if (nPaths < MAXARG) paths[nPaths++] = a;
      }
      else if (strcmp(a, "m") == 0) { mode = 'm'; seenCmd = 1; }
      else if (strcmp(a, "x") == 0) { mode = 'x'; seenCmd = 1; }
      else if (strcmp(a, "e") == 0 || strcmp(a, "idetools") == 0) { mode = '?'; seenCmd = 1; }
    } else {
      if (strcmp(a, "--isSystem") == 0) isSystem = 1;
      else if (strcmp(a, "--isMain") == 0) { /* not a flag aowlsem takes */ }
      else if (nFiles < MAXARG) files[nFiles++] = a;
    }
  }

  /* Only a plain single-module `m` is ours; a cyclic module GROUP and every
     other subcommand go to nimony's nimsem verbatim. */
  if (!*sem || mode != 'm' || nFiles != 1) {
    trace("nimsem: -> real nimsem (mode=%c files=%d sem=%s)",
          mode ? mode : '-', nFiles, *sem ? sem : "-");
    return runv(real, argv + 1, argc - 1, NULL, 0);
  }

  in = files[0];
  n = strlen(in);
  sl = strlen(".p.nif");
  if (n >= sl && strcmp(in + n - sl, ".p.nif") == 0)
    snprintf(out, sizeof(out), "%.*s.s.nif", (int)(n - sl), in);
  else
    snprintf(out, sizeof(out), "%s.s.nif", in);

  snprintf(pflag, sizeof(pflag), "-p:%s", lib);

  sa[ns++] = (char *)"m";
  sa[ns++] = (char *)in;
  sa[ns++] = out;
  base = semBase();
  if (base) sa[ns++] = (char *)base;
  if (nc) sa[ns++] = (char *)nc;
  sa[ns++] = pflag;
  for (i = 0; i < nPaths && ns < MAXARG - 2; i++) sa[ns++] = paths[i];
  if (isSystem) sa[ns++] = (char *)"--noSystem";

  trace("nimsem: -> aowlsem m %s %s", in, out);
  rc = runv(sem, sa, ns, NULL, 0);
  if (rc != 0) return rc;

  /* mechanical index sidecar (.s.nif -> .s.idx.nif); a pure NIF walk, no
     semantics - nimony's own `x` stays the implementation. */
  xa[0] = (char *)"x"; xa[1] = out;
  return runv(real, xa, 2, NULL, 0);
}

/* ---------- entry ----------------------------------------------------- */

int main(int argc, char **argv) {
  char role[64], *q;
  const char *b = baseName(argv[0] ? argv[0] : "");
  const char *forced;
  size_t n = strlen(b);

  if (n >= sizeof(role)) n = sizeof(role) - 1;
  memcpy(role, b, n);
  role[n] = '\0';
  for (q = role; *q; q++) *q = (char)tolower((unsigned char)*q);
  if (endsWith(role, ".exe")) role[strlen(role) - 4] = '\0';

  /* AOWLSHIM_ROLE overrides argv[0], so the trampoline can be exercised
     directly without staging it under two names. */
  forced = getenv("AOWLSHIM_ROLE");
  if (forced && *forced) {
    strncpy(role, forced, sizeof(role) - 1);
    role[sizeof(role) - 1] = '\0';
  }

  {
    int i;
    for (i = 0; i < argc; i++) trace("%s argv[%d]=%s", role, i, argv[i]);
  }
  if (strcmp(role, "nifler") == 0) return roleNifler(argc, argv);
  if (strcmp(role, "nimsem") == 0) return roleNimsem(argc, argv);
  fprintf(stderr, "aowlshim: no role for '%s' (expected nifler or nimsem)\n", role);
  return 127;
}
