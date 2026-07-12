// runtime.c — runtime mínima do lex, embutida no lex e linkada em todo
// binário. Sustenta os template literals e os tipos dinâmicos da linguagem
// (string helpers, arrays, maps e JSON): tudo vive numa ARENA de strings por
// thread (bump allocator em blocos). Numa thread de spawn, o thunk libera a
// arena quando a função termina — no servidor, isso significa "uma arena por
// requisição, liberada inteira no fim", estilo Apache.

#if defined(__wasm__) || defined(LEX_NATIVE_FREESTANDING) || defined(LEX_WIN_FREESTANDING)
// ===========================================================================
// Alvos FREESTANDING (sem libc): wasm (browser/WASI), nativo via syscalls
// (Linux) e nativo via Win32 API (Windows). A runtime se AUTO-SUPRE — alocador
// próprio, mem*/str*/ctype próprios,
// e a família printf roteando para UM sink: __lex_host_write(fd, p, n). No wasm
// esse sink é um import do host (lex.write); no nativo freestanding é a syscall
// write. mem*/str*/ctype/strtoll/strtod e printf/snprintf abaixo são COMPARTI-
// LHADOS pelos dois; o que difere (sink, alocador, SO) fica nos #if internos.
// ===========================================================================
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__wasm__)
// Saída: o host fornece este import. fd 1 = stdout, 2 = stderr.
__attribute__((import_module("lex"), import_name("write")))
extern void __lex_host_write(int fd, const char *p, int n);

// wasm é single-thread por enquanto: a "arena por thread" vira um static só.
#define LEX_TLS

// strlen/malloc/free também são chamados via FFI/spawn (libc.lex, thunk) com
// ABI i64, mas o uso INTERNO da runtime usa o ABI natural do wasm32 (ponteiro/
// size_t = i32). Para os dois conviverem no mesmo símbolo: aqui o uso interno é
// redirecionado para lexw_*; os símbolos públicos `strlen`/`malloc`/`free` (ABI
// i64) são definidos no fim do arquivo, convertendo para o ABI natural.
#define strlen lexw_strlen
#define malloc lexw_malloc
#define free lexw_free

// --- bump allocator sobre a memória linear (cresce com memory.grow) ---------
extern unsigned char __heap_base; // símbolo do linker: primeiro byte livre
static uintptr_t lex_brk = 0;

#ifdef LEX_WASM_THREADS
// Com Web Workers compartilhando a memória linear, o bump allocator (e o
// memory.grow) precisa ser serializado — um spinlock atômico basta (o caminho
// crítico é curtíssimo). Os atomics vêm de -matomics.
static volatile int lex_brk_lock = 0;
static void lex_lock(volatile int *l) {
    while (__atomic_exchange_n(l, 1, __ATOMIC_ACQUIRE)) { /* spin */ }
}
static void lex_unlock(volatile int *l) {
    __atomic_store_n(l, 0, __ATOMIC_RELEASE);
}
#endif

static void *lex_sbrk(size_t n) {
#ifdef LEX_WASM_THREADS
    lex_lock(&lex_brk_lock);
#endif
    if (lex_brk == 0) lex_brk = (uintptr_t)&__heap_base;
    uintptr_t cur = (lex_brk + 7) & ~(uintptr_t)7; // mantém i64/ptr alinhados
    uintptr_t need = cur + n;
    void *ret = (void *)cur;
    size_t have = (size_t)__builtin_wasm_memory_size(0) * 65536;
    if (need > have) {
        size_t pages = (need - have + 65535) / 65536;
        if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) {
            ret = (void *)0;
        } else {
            lex_brk = need;
        }
    } else {
        lex_brk = need;
    }
#ifdef LEX_WASM_THREADS
    lex_unlock(&lex_brk_lock);
#endif
    return ret;
}
void *malloc(size_t n) { return lex_sbrk(n ? n : 1); }
void free(void *p) { (void)p; } // bump: a liberação é coletiva (arena_free)
void *calloc(size_t a, size_t b) {
    size_t n = a * b;
    unsigned char *p = (unsigned char *)lex_sbrk(n ? n : 1);
    if (p) for (size_t i = 0; i < n; i++) p[i] = 0;
    return p;
}
void *realloc(void *old, size_t n) {
    // bump: aloca novo e copia (não sabe o tamanho antigo — copia o novo n,
    // seguro porque os usos só crescem o buffer)
    unsigned char *r = (unsigned char *)lex_sbrk(n ? n : 1);
    if (r && old) for (size_t i = 0; i < n; i++) r[i] = ((unsigned char *)old)[i];
    return r;
}

#elif defined(LEX_NATIVE_FREESTANDING) // ---- Linux: syscalls cruas, sem libc -

// A "arena por thread" NÃO usa _Thread_local aqui (montar TLS — %fs/tpidr — num
// binário sem CRT é frágil e específico por arch). Em vez disso, lex_arena_slot()
// (seção de SO, abaixo) resolve a arena por tid, com um caminho rápido single-
// thread. Logo LEX_TLS é vazio e lex_arena vira uma macro (ver decl da arena).
#define LEX_TLS

// --- camada de syscall (Linux x86_64 e aarch64) -----------------------------
#if defined(__x86_64__)
static long lex_syscall6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
    long ret;
    register long r10 __asm__("r10") = a4;
    register long r8  __asm__("r8")  = a5;
    register long r9  __asm__("r9")  = a6;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(n), "D"(a1), "S"(a2), "d"(a3), "r"(r10), "r"(r8), "r"(r9)
                     : "rcx", "r11", "memory");
    return ret;
}
#define SYS_read 0
#define SYS_write 1
#define SYS_close 3
#define SYS_lseek 8
#define SYS_mmap 9
#define SYS_munmap 11
#define SYS_nanosleep 35
#define SYS_socket 41
#define SYS_connect 42
#define SYS_accept 43
#define SYS_sendto 44
#define SYS_recvfrom 45
#define SYS_bind 49
#define SYS_listen 50
#define SYS_setsockopt 54
#define SYS_clone 56
#define SYS_exit 60
#define SYS_exit_group 231
#define SYS_futex 202
#define SYS_getdents64 217
#define SYS_openat 257
#define SYS_mkdirat 258
#define SYS_unlinkat 263
#define SYS_renameat2 316
#define SYS_statx 332
#define SYS_gettid 186
#elif defined(__aarch64__)
static long lex_syscall6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a1;
    register long x1 __asm__("x1") = a2;
    register long x2 __asm__("x2") = a3;
    register long x3 __asm__("x3") = a4;
    register long x4 __asm__("x4") = a5;
    register long x5 __asm__("x5") = a6;
    __asm__ volatile("svc #0"
                     : "=r"(x0)
                     : "r"(x8), "0"(x0), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                     : "memory");
    return x0;
}
#define SYS_read 63
#define SYS_write 64
#define SYS_close 57
#define SYS_lseek 62
#define SYS_mmap 222
#define SYS_munmap 215
#define SYS_nanosleep 101
#define SYS_socket 198
#define SYS_connect 203
#define SYS_accept 202
#define SYS_sendto 206
#define SYS_recvfrom 207
#define SYS_bind 200
#define SYS_listen 201
#define SYS_setsockopt 208
#define SYS_clone 220
#define SYS_exit 93
#define SYS_exit_group 94
#define SYS_futex 98
#define SYS_getdents64 61
#define SYS_openat 56
#define SYS_mkdirat 34
#define SYS_unlinkat 35
#define SYS_renameat2 276
#define SYS_statx 291
#define SYS_gettid 178
#else
#error "lex freestanding nativo: arquitetura nao suportada (use x86_64 ou aarch64)"
#endif

#define lex_sc0(n)             lex_syscall6((long)(n),0,0,0,0,0,0)
#define lex_sc1(n,a)           lex_syscall6((long)(n),(long)(a),0,0,0,0,0)
#define lex_sc2(n,a,b)         lex_syscall6((long)(n),(long)(a),(long)(b),0,0,0,0)
#define lex_sc3(n,a,b,c)       lex_syscall6((long)(n),(long)(a),(long)(b),(long)(c),0,0,0)
#define lex_sc4(n,a,b,c,d)     lex_syscall6((long)(n),(long)(a),(long)(b),(long)(c),(long)(d),0,0)
#define lex_sc5(n,a,b,c,d,e)   lex_syscall6((long)(n),(long)(a),(long)(b),(long)(c),(long)(d),(long)(e),0)
#define lex_sc6(n,a,b,c,d,e,f) lex_syscall6((long)(n),(long)(a),(long)(b),(long)(c),(long)(d),(long)(e),(long)(f))

// sink do printf: mesma assinatura do import wasm. Escreve via syscall.
static void __lex_host_write(int fd, const char *p, int n) {
    if (n > 0) lex_sc3(SYS_write, fd, p, n);
}

// --- alocador real (estilo K&R) sobre mmap ----------------------------------
// O bump do wasm nunca libera; aqui free() precisa funcionar de verdade (um
// servidor faz muitos alloc/free por requisição). Lista livre circular ordenada
// por endereço, com coalescência de vizinhos; morecore pede páginas via mmap.
// Protegida por um spinlock — todas as threads compartilham a mesma VM.
typedef long lex_Align;
union lex_header {
    struct {
        union lex_header *ptr; // próximo bloco livre
        size_t size;           // tamanho deste bloco, em unidades de header
    } s;
    lex_Align x; // força alinhamento do payload
};
typedef union lex_header LexHeader;

static LexHeader lex_base;       // âncora vazia da lista livre
static LexHeader *lex_freep = 0; // ponto de entrada na lista livre
static volatile int lex_malloc_lock = 0;

static void lex_spin_lock(volatile int *l) {
    while (__sync_lock_test_and_set(l, 1))
        while (*l) __asm__ volatile("" ::: "memory");
}
static void lex_spin_unlock(volatile int *l) { __sync_lock_release(l); }

#define LEX_NALLOC 4096 // unidades mínimas pedidas ao SO por vez

// insere um bloco na lista livre (SEM travar — chamador já tem o lock)
static void lex_free_nolock(void *ap) {
    LexHeader *bp = (LexHeader *)ap - 1, *p;
    for (p = lex_freep; !(bp > p && bp < p->s.ptr); p = p->s.ptr)
        if (p >= p->s.ptr && (bp > p || bp < p->s.ptr)) break; // ponta da lista
    if (bp + bp->s.size == p->s.ptr) { // coalesce com o vizinho de cima
        bp->s.size += p->s.ptr->s.size;
        bp->s.ptr = p->s.ptr->s.ptr;
    } else {
        bp->s.ptr = p->s.ptr;
    }
    if (p + p->s.size == bp) { // coalesce com o vizinho de baixo
        p->s.size += bp->s.size;
        p->s.ptr = bp->s.ptr;
    } else {
        p->s.ptr = bp;
    }
    lex_freep = p;
}

static LexHeader *lex_morecore(size_t nu) {
    if (nu < LEX_NALLOC) nu = LEX_NALLOC;
    size_t bytes = nu * sizeof(LexHeader);
    // mmap(NULL, bytes, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
    long p = lex_sc6(SYS_mmap, 0, (long)bytes, 0x3, 0x22, -1, 0);
    if (p < 0 && p > -4096) return 0; // mmap falhou (erro em [-4095,-1])
    LexHeader *up = (LexHeader *)p;
    up->s.size = nu;
    lex_free_nolock((void *)(up + 1));
    return lex_freep;
}

void free(void *ap) {
    if (!ap) return;
    lex_spin_lock(&lex_malloc_lock);
    lex_free_nolock(ap);
    lex_spin_unlock(&lex_malloc_lock);
}

void *malloc(size_t nbytes) {
    if (nbytes == 0) nbytes = 1;
    size_t nunits = (nbytes + sizeof(LexHeader) - 1) / sizeof(LexHeader) + 1;
    lex_spin_lock(&lex_malloc_lock);
    LexHeader *prevp = lex_freep;
    if (prevp == 0) { // primeira chamada: lista livre vazia, só a âncora
        lex_base.s.ptr = lex_freep = prevp = &lex_base;
        lex_base.s.size = 0;
    }
    for (LexHeader *p = prevp->s.ptr;; prevp = p, p = p->s.ptr) {
        if (p->s.size >= nunits) { // grande o bastante
            if (p->s.size == nunits) {
                prevp->s.ptr = p->s.ptr;
            } else { // corta a cauda
                p->s.size -= nunits;
                p += p->s.size;
                p->s.size = nunits;
            }
            lex_freep = prevp;
            lex_spin_unlock(&lex_malloc_lock);
            return (void *)(p + 1);
        }
        if (p == lex_freep) { // deu a volta: pede mais ao SO
            if ((p = lex_morecore(nunits)) == 0) {
                lex_spin_unlock(&lex_malloc_lock);
                return 0;
            }
        }
    }
}

void *calloc(size_t a, size_t b) {
    size_t n = a * b;
    unsigned char *p = (unsigned char *)malloc(n ? n : 1);
    if (p) for (size_t i = 0; i < n; i++) p[i] = 0;
    return p;
}
void *realloc(void *old, size_t n) {
    if (!old) return malloc(n ? n : 1);
    void *r = malloc(n ? n : 1);
    if (r) {
        size_t oldsz = (((LexHeader *)old - 1)->s.size - 1) * sizeof(LexHeader);
        size_t cp = oldsz < n ? oldsz : n;
        for (size_t i = 0; i < cp; i++) ((unsigned char *)r)[i] = ((unsigned char *)old)[i];
        free(old);
    }
    return r;
}

#else // ---- Windows: Win32 API (kernel32), sem libc nem CRT -----------------

// A "arena por thread" usa lex_arena_slot() (busca por GetCurrentThreadId),
// igual ao Linux — sem TLS manual. LEX_TLS fica vazio.
#define LEX_TLS

// Tipos mínimos do Win32 (x64). Evitamos windows.h: declaramos só o que usamos.
typedef unsigned long LEX_DWORD;
typedef int LEX_BOOL;
typedef void *LEX_HANDLE;
typedef unsigned long long LEX_SIZE_T;

// kernel32: chamadas via __declspec(dllimport) — o clang gera a ABI MS x64 e o
// lld-link resolve pelas import libs geradas com llvm-lib (sem mingw).
__declspec(dllimport) LEX_HANDLE GetStdHandle(LEX_DWORD nStdHandle);
__declspec(dllimport) LEX_BOOL WriteFile(LEX_HANDLE, const void *, LEX_DWORD, LEX_DWORD *, void *);
__declspec(dllimport) LEX_HANDLE GetProcessHeap(void);
__declspec(dllimport) void *HeapAlloc(LEX_HANDLE, LEX_DWORD, LEX_SIZE_T);
__declspec(dllimport) LEX_BOOL HeapFree(LEX_HANDLE, LEX_DWORD, void *);
__declspec(dllimport) void *HeapReAlloc(LEX_HANDLE, LEX_DWORD, void *, LEX_SIZE_T);

#define LEX_STD_OUTPUT ((LEX_DWORD)-11)
#define LEX_STD_ERROR ((LEX_DWORD)-12)
#define LEX_HEAP_ZERO 0x8

// sink do printf: mesma assinatura do import wasm. Escreve no console via Win32.
static void __lex_host_write(int fd, const char *p, int n) {
    if (n <= 0) return;
    LEX_HANDLE h = GetStdHandle(fd == 2 ? LEX_STD_ERROR : LEX_STD_OUTPUT);
    LEX_DWORD wrote = 0;
    WriteFile(h, p, (LEX_DWORD)n, &wrote, 0);
}

// alocador: o heap do processo (kernel32) já é um malloc de verdade.
void *malloc(size_t n) { return HeapAlloc(GetProcessHeap(), 0, n ? n : 1); }
void free(void *p) { if (p) HeapFree(GetProcessHeap(), 0, p); }
void *calloc(size_t a, size_t b) {
    size_t n = a * b;
    return HeapAlloc(GetProcessHeap(), LEX_HEAP_ZERO, n ? n : 1);
}
void *realloc(void *old, size_t n) {
    if (!old) return HeapAlloc(GetProcessHeap(), 0, n ? n : 1);
    return HeapReAlloc(GetProcessHeap(), 0, old, n ? n : 1);
}

#endif // __wasm__ vs nativo freestanding (Linux/Windows)

// --- mem*/str* freestanding (o compilador também os chama em cópias de struct)
void *memcpy(void *d, const void *s, size_t n) {
    unsigned char *dd = d; const unsigned char *ss = s;
    for (size_t i = 0; i < n; i++) dd[i] = ss[i];
    return d;
}
void *memmove(void *d, const void *s, size_t n) {
    unsigned char *dd = d; const unsigned char *ss = s;
    if (dd < ss) for (size_t i = 0; i < n; i++) dd[i] = ss[i];
    else for (size_t i = n; i > 0; i--) dd[i - 1] = ss[i - 1];
    return d;
}
void *memset(void *d, int c, size_t n) {
    unsigned char *dd = d;
    for (size_t i = 0; i < n; i++) dd[i] = (unsigned char)c;
    return d;
}
size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}
int strncmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char ca = (unsigned char)a[i], cb = (unsigned char)b[i];
        if (ca != cb) return (int)ca - (int)cb;
        if (!ca) return 0;
    }
    return 0;
}
char *strstr(const char *h, const char *n) {
    if (!*n) return (char *)h;
    for (; *h; h++) {
        const char *a = h, *b = n;
        while (*a && *b && *a == *b) { a++; b++; }
        if (!*b) return (char *)h;
    }
    return (char *)0;
}

// --- ctype ASCII ------------------------------------------------------------
int toupper(int c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }
int tolower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }
int isspace(int c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

// --- strtoll / strtol / strtod minimalistas ---------------------------------
long long strtoll(const char *s, char **end, int base) {
    (void)base; // o lex só pede base 10
    while (isspace((unsigned char)*s)) s++;
    int neg = 0;
    if (*s == '+' || *s == '-') { neg = (*s == '-'); s++; }
    long long v = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    if (end) *end = (char *)s;
    return neg ? -v : v;
}
long strtol(const char *s, char **end, int base) { return (long)strtoll(s, end, base); }
double strtod(const char *s, char **end) {
    while (isspace((unsigned char)*s)) s++;
    int neg = 0;
    if (*s == '+' || *s == '-') { neg = (*s == '-'); s++; }
    double v = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    if (*s == '.') {
        s++;
        double f = 0.1;
        while (*s >= '0' && *s <= '9') { v += (*s - '0') * f; f *= 0.1; s++; }
    }
    if (*s == 'e' || *s == 'E') {
        s++;
        int eneg = 0;
        if (*s == '+' || *s == '-') { eneg = (*s == '-'); s++; }
        int e = 0;
        while (*s >= '0' && *s <= '9') { e = e * 10 + (*s - '0'); s++; }
        double p = 1;
        while (e--) p *= 10;
        if (eneg) v /= p; else v *= p;
    }
    if (end) *end = (char *)s;
    return neg ? -v : v;
}

// --- printf-família mínima --------------------------------------------------
// Cobre só os formatos que o lex emite: %s %c %d %i %u %x %X, com length l/ll,
// flag '0' e largura (ex.: %lld, %04x). printf/dprintf streamam pro host; %s
// vai direto, sem buffer, então log() de string longa não trunca.
static void lex_emit_int(int fd, char *b, int *n, unsigned long long uv, int neg,
                         int hex, int upper, int zero, int width) {
    char tmp[24];
    int ti = 0;
    const char *digs = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    unsigned base = hex ? 16u : 10u;
    if (uv == 0) tmp[ti++] = '0';
    while (uv) { tmp[ti++] = digs[uv % base]; uv /= base; }
    int total = ti + (neg ? 1 : 0);
    if (neg && zero) { if (*n == 64) { __lex_host_write(fd, b, *n); *n = 0; } b[(*n)++] = '-'; }
    for (int k = total; k < width; k++) {
        if (*n == 64) { __lex_host_write(fd, b, *n); *n = 0; }
        b[(*n)++] = zero ? '0' : ' ';
    }
    if (neg && !zero) { if (*n == 64) { __lex_host_write(fd, b, *n); *n = 0; } b[(*n)++] = '-'; }
    while (ti) {
        if (*n == 64) { __lex_host_write(fd, b, *n); *n = 0; }
        b[(*n)++] = tmp[--ti];
    }
}
static int lex_stream_fmt(int fd, const char *f, va_list ap) {
    char b[64];
    int n = 0, total = 0;
#define EMIT(ch) do { if (n == 64) { __lex_host_write(fd, b, n); n = 0; } b[n++] = (char)(ch); total++; } while (0)
    for (; *f; f++) {
        if (*f != '%') { EMIT(*f); continue; }
        f++;
        if (*f == '%') { EMIT('%'); continue; }
        int zero = 0, width = 0, lng = 0;
        while (*f == '0' || *f == '-' || *f == '+' || *f == ' ') {
            if (*f == '0') zero = 1;
            f++;
        }
        while (*f >= '0' && *f <= '9') { width = width * 10 + (*f - '0'); f++; }
        while (*f == 'l') { lng++; f++; }
        char c = *f;
        if (c == 's') {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            if (n) { __lex_host_write(fd, b, n); n = 0; } // descarrega pendentes
            size_t sl = 0; while (s[sl]) sl++;
            __lex_host_write(fd, s, (int)sl);
            total += (int)sl;
        } else if (c == 'c') {
            EMIT(va_arg(ap, int));
        } else if (c == 'd' || c == 'i') {
            long long sv = (lng >= 2) ? va_arg(ap, long long)
                         : (lng == 1) ? (long long)va_arg(ap, long)
                                      : (long long)va_arg(ap, int);
            int neg = sv < 0;
            unsigned long long uv = neg ? (unsigned long long)(-sv) : (unsigned long long)sv;
            lex_emit_int(fd, b, &n, uv, neg, 0, 0, zero, width);
            total += width;
        } else if (c == 'u' || c == 'x' || c == 'X') {
            unsigned long long uv = (lng >= 2) ? va_arg(ap, unsigned long long)
                                  : (lng == 1) ? (unsigned long long)va_arg(ap, unsigned long)
                                               : (unsigned long long)va_arg(ap, unsigned int);
            lex_emit_int(fd, b, &n, uv, 0, c != 'u', c == 'X', zero, width);
            total += width;
        } else {
            EMIT('%'); EMIT(c);
        }
    }
    if (n) __lex_host_write(fd, b, n);
    return total;
#undef EMIT
}
int printf(const char *f, ...) {
    va_list ap; va_start(ap, f);
    int r = lex_stream_fmt(1, f, ap);
    va_end(ap);
    return r;
}
int dprintf(int fd, const char *f, ...) {
    va_list ap; va_start(ap, f);
    int r = lex_stream_fmt(fd, f, ap);
    va_end(ap);
    return r;
}
// snprintf usado internamente (i64->str, escape \u): formata num buffer.
static int lex_vsnprintf(char *out, size_t cap, const char *f, va_list ap) {
    size_t n = 0;
#define PUT(ch) do { if (n + 1 < cap) out[n] = (char)(ch); n++; } while (0)
    for (; *f; f++) {
        if (*f != '%') { PUT(*f); continue; }
        f++;
        if (*f == '%') { PUT('%'); continue; }
        int zero = 0, width = 0, lng = 0;
        while (*f == '0' || *f == '-' || *f == '+' || *f == ' ') {
            if (*f == '0') zero = 1;
            f++;
        }
        while (*f >= '0' && *f <= '9') { width = width * 10 + (*f - '0'); f++; }
        while (*f == 'l') { lng++; f++; }
        char c = *f;
        if (c == 's') {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            while (*s) PUT(*s++);
        } else if (c == 'c') {
            PUT(va_arg(ap, int));
        } else {
            unsigned long long uv;
            int neg = 0, hex = (c == 'x' || c == 'X');
            if (c == 'd' || c == 'i') {
                long long sv = (lng >= 2) ? va_arg(ap, long long)
                             : (lng == 1) ? (long long)va_arg(ap, long)
                                          : (long long)va_arg(ap, int);
                neg = sv < 0;
                uv = neg ? (unsigned long long)(-sv) : (unsigned long long)sv;
            } else {
                uv = (lng >= 2) ? va_arg(ap, unsigned long long)
                   : (lng == 1) ? (unsigned long long)va_arg(ap, unsigned long)
                                : (unsigned long long)va_arg(ap, unsigned int);
            }
            char tmp[24];
            int ti = 0;
            const char *digs = (c == 'X') ? "0123456789ABCDEF" : "0123456789abcdef";
            unsigned base = hex ? 16u : 10u;
            if (uv == 0) tmp[ti++] = '0';
            while (uv) { tmp[ti++] = digs[uv % base]; uv /= base; }
            int total = ti + (neg ? 1 : 0);
            if (neg) PUT('-');
            for (int k = total; k < width; k++) PUT(zero ? '0' : ' ');
            while (ti) PUT(tmp[--ti]);
        }
    }
    if (cap) out[n < cap ? n : cap - 1] = 0;
    return (int)n;
#undef PUT
}
int snprintf(char *out, size_t cap, const char *f, ...) {
    va_list ap; va_start(ap, f);
    int r = lex_vsnprintf(out, cap, f, ap);
    va_end(ap);
    return r;
}

#else // ---- alvo nativo: libc/SO de verdade -------------------------------

#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// "arena por thread": cada thread de spawn tem a sua, liberada quando termina.
#define LEX_TLS _Thread_local

#endif // __wasm__

typedef struct LexBlock {
    struct LexBlock *prev;
    size_t cap, len;
    char dados[];
} LexBlock;

#if defined(LEX_NATIVE_FREESTANDING) || defined(LEX_WIN_FREESTANDING)
// arena por thread SEM TLS: a slot é resolvida por tid (def. na seção de SO).
// `lex_arena` vira a deref da slot — funciona tanto no caminho single-thread
// (uma global) quanto no multi-thread (tabela tid->arena).
LexBlock **lex_arena_slot(void);
#define lex_arena (*lex_arena_slot())
#else
static LEX_TLS LexBlock *lex_arena = 0;
#endif

static char *lex_alloc(size_t n) {
    n = (n + 7) & ~(size_t)7; // arredonda p/ múltiplo de 8: mantém i64/ptr alinhados
    if (n == 0) n = 8;
    if (!lex_arena || lex_arena->len + n > lex_arena->cap) {
        size_t cap = n > 4096 ? n : 4096;
        LexBlock *b = malloc(sizeof(LexBlock) + cap);
        b->prev = lex_arena;
        b->cap = cap;
        b->len = 0;
        lex_arena = b;
    }
    char *p = lex_arena->dados + lex_arena->len;
    lex_arena->len += n;
    return p;
}

// copia uma string (qualquer ponteiro transitório) para dentro da arena
static char *lex_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = lex_alloc(n);
    memcpy(r, s, n);
    return r;
}

// `${a}${b}` vira chamadas disto, dobradas da esquerda para a direita
char *__lex_concat(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    char *r = lex_alloc(la + lb + 1);
    memcpy(r, a, la);
    memcpy(r + la, b, lb);
    r[la + lb] = 0;
    return r;
}

// `${42}` — interpolação de inteiro
char *__lex_i64_to_str(long long v) {
    char *r = lex_alloc(24);
    snprintf(r, 24, "%lld", v);
    return r;
}

// reinterpreta uma célula i64 (o que a ABI do lex carrega) como double.
static double lex_bits_to_f64(long long bits) {
    union { long long i; double d; } u;
    u.i = bits;
    return u.d;
}

// `${3.14}` — formata um double. O snprintf freestanding não tem "%f", então
// montamos à mão: parte inteira + até 6 casas decimais, com zeros à direita
// aparados (mas sempre ao menos uma casa, para "2.0" não virar "2").
char *__lex_f64_to_str(long long bits) {
    double v = lex_bits_to_f64(bits);
    char *out = lex_alloc(64);
    int pos = 0;
    // NaN / infinito
    if (v != v) { out[0]='n'; out[1]='a'; out[2]='n'; out[3]=0; return out; }
    if (v < 0) { out[pos++] = '-'; v = -v; }
    if (v > 1e18) { // grande demais para a parte inteira em i64: aproxima
        const char *inf = "inf";
        for (int k = 0; inf[k]; k++) out[pos++] = inf[k];
        out[pos] = 0;
        return out;
    }
    long long ip = (long long)v;
    double frac = v - (double)ip;
    // arredonda a fração em 6 casas ANTES de formatar, propagando o vai-um
    // para a parte inteira (senão 0.9999998 viraria "0.0" em vez de "1.0").
    int digits = 6;
    long long scaled = (long long)(frac * 1000000.0 + 0.5); // 10^6, com round
    if (scaled >= 1000000) { scaled -= 1000000; ip += 1; }  // carry
    // parte inteira (já com o eventual vai-um)
    char ibuf[24];
    int n = 0;
    if (ip == 0) { ibuf[n++] = '0'; }
    else { while (ip > 0) { ibuf[n++] = (char)('0' + (int)(ip % 10)); ip /= 10; } }
    while (n > 0) out[pos++] = ibuf[--n];
    // parte fracionária
    out[pos++] = '.';
    int fstart = pos;
    char fbuf[8];
    for (int k = digits - 1; k >= 0; k--) { fbuf[k] = (char)('0' + (int)(scaled % 10)); scaled /= 10; }
    for (int k = 0; k < digits; k++) out[pos++] = fbuf[k];
    // apara zeros à direita, mas mantém pelo menos um dígito após o ponto
    while (pos > fstart + 1 && out[pos - 1] == '0') pos--;
    out[pos] = 0;
    return out;
}

// empacota um double na célula i64 que a ABI do lex carrega
static long long lex_f64_to_bits(double v) {
    union { long long i; double d; } u;
    u.d = v;
    return u.i;
}

// --- math em ponto flutuante (entrada/saída como célula i64) ----------------
long long __lex_f_floor(long long bits) {
    double v = lex_bits_to_f64(bits);
    long long t = (long long)v;
    if ((double)t > v) t--;
    return lex_f64_to_bits((double)t);
}
long long __lex_f_ceil(long long bits) {
    double v = lex_bits_to_f64(bits);
    long long t = (long long)v;
    if ((double)t < v) t++;
    return lex_f64_to_bits((double)t);
}
long long __lex_f_round(long long bits) {
    double v = lex_bits_to_f64(bits);
    double r = v < 0 ? -(double)((long long)(-v + 0.5)) : (double)((long long)(v + 0.5));
    return lex_f64_to_bits(r);
}
long long __lex_f_abs(long long bits) {
    double v = lex_bits_to_f64(bits);
    return lex_f64_to_bits(v < 0 ? -v : v);
}
long long __lex_f_sqrt(long long bits) {
    double v = lex_bits_to_f64(bits);
    if (v <= 0) return lex_f64_to_bits(0.0);
    double x = v;
    for (int i = 0; i < 50; i++) x = 0.5 * (x + v / x); // Newton
    return lex_f64_to_bits(x);
}

// --- transcendentais (séries, freestanding — sem libm) ---------------------
#define LEX_PI 3.14159265358979323846
#define LEX_LN2 0.69314718055994530942
#define LEX_LN10 2.30258509299404568402

static double lex_d_floor(double x) {
    long long i = (long long)x;
    if ((double)i > x) i--;
    return (double)i;
}
static double lex_d_sin(double x) {
    // reduz para [-pi, pi]
    x = x - 2.0 * LEX_PI * lex_d_floor(x / (2.0 * LEX_PI) + 0.5);
    double term = x, sum = x, x2 = x * x;
    for (int n = 1; n < 14; n++) {
        term *= -x2 / (double)((2 * n) * (2 * n + 1));
        sum += term;
    }
    return sum;
}
static double lex_d_cos(double x) { return lex_d_sin(x + LEX_PI / 2.0); }
static double lex_d_exp(double x) {
    if (x > 709.0) return 1e308;
    if (x < -745.0) return 0.0;
    double sum = 1.0, term = 1.0;
    for (int n = 1; n < 40; n++) {
        term *= x / (double)n;
        sum += term;
        if (term < 1e-18 && term > -1e-18) break;
    }
    return sum;
}
static double lex_d_ln(double x) {
    if (x <= 0.0) return 0.0;
    int k = 0;
    while (x > 1.5) { x *= 0.5; k++; }
    while (x < 0.75) { x *= 2.0; k--; }
    double t = (x - 1.0) / (x + 1.0), t2 = t * t, sum = t, term = t;
    for (int n = 1; n < 24; n++) {
        term *= t2;
        sum += term / (double)(2 * n + 1);
    }
    return 2.0 * sum + (double)k * LEX_LN2;
}
static double lex_d_pow(double b, double e) {
    if (b == 0.0) return e == 0.0 ? 1.0 : 0.0;
    if (b < 0.0) { // base negativa: só expoente inteiro
        long long ei = (long long)e;
        double pr = lex_d_exp((double)ei * lex_d_ln(-b));
        return (ei % 2 == 0) ? pr : -pr;
    }
    return lex_d_exp(e * lex_d_ln(b));
}

long long __lex_f_sin(long long bits) { return lex_f64_to_bits(lex_d_sin(lex_bits_to_f64(bits))); }
long long __lex_f_cos(long long bits) { return lex_f64_to_bits(lex_d_cos(lex_bits_to_f64(bits))); }
long long __lex_f_tan(long long bits) {
    double x = lex_bits_to_f64(bits);
    double c = lex_d_cos(x);
    return lex_f64_to_bits(c == 0.0 ? 0.0 : lex_d_sin(x) / c);
}
long long __lex_f_exp(long long bits) { return lex_f64_to_bits(lex_d_exp(lex_bits_to_f64(bits))); }
long long __lex_f_ln(long long bits) { return lex_f64_to_bits(lex_d_ln(lex_bits_to_f64(bits))); }
long long __lex_f_log10(long long bits) {
    return lex_f64_to_bits(lex_d_ln(lex_bits_to_f64(bits)) / LEX_LN10);
}
long long __lex_f_pow(long long b, long long e) {
    return lex_f64_to_bits(lex_d_pow(lex_bits_to_f64(b), lex_bits_to_f64(e)));
}

// --- slots globais (singletons) --------------------------------------------
// lex não tem estado de módulo mutável (módulos só exportam declarações), então
// expomos um punhado de células i64 globais e persistentes — escape hatch para
// singletons (ex.: os contadores da biblioteca de testes BDD). NÃO é seguro
// entre threads (são compartilhadas, sem lock); use em código single-thread.
#define LEX_NGLOBAL 256
static long long lex_global_slots[LEX_NGLOBAL];
long long __lex_gget(long long i) {
    return (i >= 0 && i < LEX_NGLOBAL) ? lex_global_slots[i] : 0;
}
void __lex_gset(long long i, long long v) {
    if (i >= 0 && i < LEX_NGLOBAL) lex_global_slots[i] = v;
}

// bloco de struct (record): n campos de 8 bytes, na arena da thread
void *__lex_alloc(long long n_bytes) {
    return lex_alloc(n_bytes);
}

// ===========================================================================
// Memória dinâmica (heap, FORA da arena) — `alloc`/`free` do lex. Diferente da
// arena, sobrevive ao fim da thread: é o que permite buffers compartilhados
// (ex.: a sockaddr passada ao bind) e ownership manual com `defer free(p)`.
// `alloc` devolve memória zerada.
// ===========================================================================

void *__lex_heap_alloc(long long n) {
    if (n <= 0) n = 1;
    return calloc(1, (size_t)n);
}

void __lex_free(void *p) {
    free(p);
}

// monta uma sockaddr_in (16 bytes) no layout do SO ALVO, no heap (zerada).
// O layout difere por SO e ANTES era hard-coded como BSD no std/socket.lex, o
// que quebrava o bind no Linux. Centralizamos aqui, onde o #ifdef do SO vale:
//   Linux: sin_family é u16 no offset 0 (sem sin_len).
//   macOS/BSD: sin_len (=16) no offset 0, sin_family no offset 1.
// O port entra em ordem de rede (big-endian) no offset 2; sin_addr=0 (ANY).
void *lex_sockaddr_in(long long port) {
    unsigned char *a = (unsigned char *)__lex_heap_alloc(16);
#if defined(__APPLE__)
    a[0] = 16; // sin_len
    a[1] = 2;  // sin_family = AF_INET
#else
    a[0] = 2;  // sin_family (u16, little-endian) = AF_INET
    a[1] = 0;
#endif
    a[2] = (unsigned char)((port >> 8) & 0xff); // sin_port (network order)
    a[3] = (unsigned char)(port & 0xff);
    return a; // sin_addr = INADDR_ANY (0), já zerado
}

// poke/peek: leitura e escrita cruas em deslocamentos de bytes a partir de um
// ponteiro. As variantes `be` escrevem em ordem de rede (big-endian) — é o que
// monta os campos de uma sockaddr_in sem precisar de htons/htonl.
void __lex_poke8(char *p, long long off, long long v) { p[off] = (char)v; }
void __lex_poke16(char *p, long long off, long long v) {
    unsigned short x = (unsigned short)v;
    memcpy(p + off, &x, 2);
}
void __lex_poke32(char *p, long long off, long long v) {
    unsigned int x = (unsigned int)v;
    memcpy(p + off, &x, 4);
}
void __lex_poke64(char *p, long long off, long long v) { memcpy(p + off, &v, 8); }
void __lex_poke16be(char *p, long long off, long long v) {
    p[off] = (char)((v >> 8) & 0xff);
    p[off + 1] = (char)(v & 0xff);
}
void __lex_poke32be(char *p, long long off, long long v) {
    p[off] = (char)((v >> 24) & 0xff);
    p[off + 1] = (char)((v >> 16) & 0xff);
    p[off + 2] = (char)((v >> 8) & 0xff);
    p[off + 3] = (char)(v & 0xff);
}
long long __lex_peek8(unsigned char *p, long long off) { return p[off]; }
long long __lex_peek16(char *p, long long off) {
    unsigned short x;
    memcpy(&x, p + off, 2);
    return x;
}
long long __lex_peek32(char *p, long long off) {
    unsigned int x;
    memcpy(&x, p + off, 4);
    return x;
}
long long __lex_peek64(char *p, long long off) {
    long long x;
    memcpy(&x, p + off, 8);
    return x;
}

// ===========================================================================
// Buffer de string em crescimento (malloc), finalizado para dentro da arena.
// Usado por join/replace/json_stringify, onde o tamanho final é desconhecido.
// ===========================================================================

typedef struct {
    char *p;
    size_t len, cap;
} StrBuf;

static void sb_init(StrBuf *b) {
    b->cap = 64;
    b->len = 0;
    b->p = malloc(b->cap);
    b->p[0] = 0;
}
static void sb_ensure(StrBuf *b, size_t extra) {
    if (b->len + extra + 1 > b->cap) {
        while (b->len + extra + 1 > b->cap) b->cap *= 2;
        b->p = realloc(b->p, b->cap);
    }
}
static void sb_putc(StrBuf *b, char c) {
    sb_ensure(b, 1);
    b->p[b->len++] = c;
    b->p[b->len] = 0;
}
static void sb_puts(StrBuf *b, const char *s) {
    size_t l = strlen(s);
    sb_ensure(b, l);
    memcpy(b->p + b->len, s, l);
    b->len += l;
    b->p[b->len] = 0;
}
// move o conteúdo para a arena e libera o buffer temporário
static char *sb_finish(StrBuf *b) {
    char *r = lex_alloc(b->len + 1);
    memcpy(r, b->p, b->len + 1);
    free(b->p);
    return r;
}

// ===========================================================================
// Strings — helpers expostos como builtins (substring, split, etc.).
// Toda string devolvida é nova e mora na arena (NUL-terminada, estilo C).
// ===========================================================================

long long __lex_strlen(const char *s) {
    return s ? (long long)strlen(s) : 0;
}

long long __lex_str_eq(const char *a, const char *b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    return strcmp(a, b) == 0 ? 1 : 0;
}

char *__lex_substring(const char *s, long long start, long long end) {
    long long n = (long long)strlen(s);
    if (start < 0) start = 0;
    if (end > n) end = n;
    if (end < start) end = start;
    long long len = end - start;
    char *r = lex_alloc(len + 1);
    memcpy(r, s + start, len);
    r[len] = 0;
    return r;
}

long long __lex_index_of(const char *s, const char *needle) {
    const char *hit = strstr(s, needle);
    return hit ? (long long)(hit - s) : -1;
}

long long __lex_contains(const char *s, const char *needle) {
    return strstr(s, needle) ? 1 : 0;
}

long long __lex_starts_with(const char *s, const char *prefix) {
    size_t lp = strlen(prefix);
    return strncmp(s, prefix, lp) == 0 ? 1 : 0;
}

long long __lex_ends_with(const char *s, const char *suffix) {
    size_t ls = strlen(s), lf = strlen(suffix);
    if (lf > ls) return 0;
    return strcmp(s + (ls - lf), suffix) == 0 ? 1 : 0;
}

// ── flag de erro p/ fail/try/catch do compilador self-hostado ────────────────
// Modelo simples e fora-de-banda: `fail E` seta o flag e devolve sentinela; `try`
// checa após a chamada e PROPAGA (retorna da função atual com o flag ainda setado);
// `catch` checa, LIMPA e usa o fallback. Global por thread (erros não atravessam
// spawn — suficiente p/ os caminhos atuais).
static long long lex_err_flag = 0;
static long long lex_err_val = 0;
long long __lex_set_err(long long v) { lex_err_flag = 1; lex_err_val = v; return 0; }
long long __lex_has_err(void) { return lex_err_flag; }
long long __lex_take_err(void) {
    long long v = lex_err_val;
    lex_err_flag = 0;
    lex_err_val = 0;
    return v;
}

char *__lex_to_upper(const char *s) {
    char *r = lex_strdup(s);
    for (char *p = r; *p; p++) *p = (char)toupper((unsigned char)*p);
    return r;
}

char *__lex_to_lower(const char *s) {
    char *r = lex_strdup(s);
    for (char *p = r; *p; p++) *p = (char)tolower((unsigned char)*p);
    return r;
}

char *__lex_trim(const char *s) {
    while (*s && isspace((unsigned char)*s)) s++;
    long long n = (long long)strlen(s);
    while (n > 0 && isspace((unsigned char)s[n - 1])) n--;
    char *r = lex_alloc(n + 1);
    memcpy(r, s, n);
    r[n] = 0;
    return r;
}

// índice i (em bytes) como string de 1 char; "" se fora do intervalo
char *__lex_char_at(const char *s, long long i) {
    long long n = (long long)strlen(s);
    char *r = lex_alloc(2);
    if (i < 0 || i >= n) {
        r[0] = 0;
    } else {
        r[0] = s[i];
        r[1] = 0;
    }
    return r;
}

// código do byte no índice i; -1 se fora do intervalo
long long __lex_char_code(const char *s, long long i) {
    long long n = (long long)strlen(s);
    if (i < 0 || i >= n) return -1;
    return (unsigned char)s[i];
}

long long __lex_parse_int(const char *s) {
    return strtoll(s, 0, 10);
}

// parseFloat: parser de double próprio (sem libc strtod, p/ valer em todos os
// alvos, inclusive freestanding/wasm). Aceita [sinal] dígitos [.dígitos]
// [(e|E)[sinal]dígitos]; ignora espaço inicial. Texto inválido → 0.0.
// Retorna o PADRÃO DE BITS do double numa célula i64 (convenção float do lex,
// igual aos __lex_f_*), não um double — o ABI da runtime trafega tudo em i64.
long long __lex_parse_float(const char *s) {
    if (!s) return lex_f64_to_bits(0.0);
    while (*s == ' ' || *s == '\t') s++;
    int neg = 0;
    if (*s == '+' || *s == '-') { neg = (*s == '-'); s++; }
    double v = 0.0;
    while (*s >= '0' && *s <= '9') { v = v * 10.0 + (double)(*s - '0'); s++; }
    if (*s == '.') {
        s++;
        double f = 0.1;
        while (*s >= '0' && *s <= '9') { v += (double)(*s - '0') * f; f *= 0.1; s++; }
    }
    if (*s == 'e' || *s == 'E') {
        s++;
        int eneg = 0;
        if (*s == '+' || *s == '-') { eneg = (*s == '-'); s++; }
        int e = 0;
        while (*s >= '0' && *s <= '9') { e = e * 10 + (*s - '0'); s++; }
        double p = 1.0;
        for (int k = 0; k < e; k++) p *= 10.0;
        if (eneg) v /= p; else v *= p;
    }
    return lex_f64_to_bits(neg ? -v : v);
}

char *__lex_str_repeat(const char *s, long long n) {
    if (n < 0) n = 0;
    size_t l = strlen(s);
    char *r = lex_alloc(l * (size_t)n + 1);
    char *p = r;
    for (long long k = 0; k < n; k++) {
        memcpy(p, s, l);
        p += l;
    }
    *p = 0;
    return r;
}

// substitui TODAS as ocorrências de `from` por `to`
char *__lex_str_replace(const char *s, const char *from, const char *to) {
    size_t lf = strlen(from);
    if (lf == 0) return lex_strdup(s);
    StrBuf b;
    sb_init(&b);
    const char *p = s;
    const char *hit;
    while ((hit = strstr(p, from)) != 0) {
        while (p < hit) sb_putc(&b, *p++);
        sb_puts(&b, to);
        p += lf;
    }
    sb_puts(&b, p);
    return sb_finish(&b);
}

// ===========================================================================
// Arrays dinâmicos — uma lista de células i64 (qualquer valor: int, string,
// array/map/json aninhado). Cresce copiando para um buffer maior na arena.
// Layout exposto como i64 (endereço do header).
// ===========================================================================

typedef struct {
    long long len, cap;
    long long *data;
} LexArr;

LexArr *__lex_arr_new(long long cap) {
    if (cap < 4) cap = 4;
    LexArr *a = (LexArr *)lex_alloc(sizeof(LexArr));
    a->len = 0;
    a->cap = cap;
    a->data = (long long *)lex_alloc((size_t)cap * sizeof(long long));
    return a;
}

long long __lex_arr_len(LexArr *a) {
    return a ? a->len : 0;
}

void __lex_arr_push(LexArr *a, long long v) {
    if (a->len >= a->cap) {
        long long ncap = a->cap * 2;
        long long *nd = (long long *)lex_alloc((size_t)ncap * sizeof(long long));
        memcpy(nd, a->data, (size_t)a->len * sizeof(long long));
        a->data = nd;
        a->cap = ncap;
    }
    a->data[a->len++] = v;
}

long long __lex_arr_get(LexArr *a, long long i) {
    if (!a || i < 0 || i >= a->len) return 0;
    return a->data[i];
}

void __lex_arr_set(LexArr *a, long long i, long long v) {
    if (!a || i < 0) return;
    while (i >= a->cap) __lex_arr_push(a, 0); // cresce; ajusta len abaixo
    if (i >= a->len) a->len = i + 1;
    a->data[i] = v;
}

long long __lex_arr_pop(LexArr *a) {
    if (!a || a->len == 0) return 0;
    return a->data[--a->len];
}

LexArr *__lex_arr_slice(LexArr *a, long long start, long long end) {
    long long n = a ? a->len : 0;
    if (start < 0) start = 0;
    if (end > n) end = n;
    if (end < start) end = start;
    LexArr *r = __lex_arr_new(end - start);
    for (long long i = start; i < end; i++) __lex_arr_push(r, a->data[i]);
    return r;
}

// junta os elementos (tratados como ponteiros de string) com `sep`
char *__lex_arr_join(LexArr *a, const char *sep) {
    StrBuf b;
    sb_init(&b);
    for (long long i = 0; i < (a ? a->len : 0); i++) {
        if (i) sb_puts(&b, sep);
        const char *s = (const char *)a->data[i];
        sb_puts(&b, s ? s : "");
    }
    return sb_finish(&b);
}

// quebra `s` em pedaços separados por `sep`; devolve um array de strings.
// sep vazio devolve [s].
LexArr *__lex_split(const char *s, const char *sep) {
    LexArr *r = __lex_arr_new(4);
    size_t ls = strlen(sep);
    if (ls == 0) {
        __lex_arr_push(r, (long long)lex_strdup(s));
        return r;
    }
    const char *p = s;
    const char *hit;
    while ((hit = strstr(p, sep)) != 0) {
        long long len = (long long)(hit - p);
        char *piece = lex_alloc(len + 1);
        memcpy(piece, p, len);
        piece[len] = 0;
        __lex_arr_push(r, (long long)piece);
        p = hit + ls;
    }
    __lex_arr_push(r, (long long)lex_strdup(p));
    return r;
}

// ===========================================================================
// Map — dicionário de chave string → célula i64. Busca linear (suficiente
// para objetos JSON e configs pequenas). Chaves são copiadas para a arena.
// ===========================================================================

typedef struct {
    long long len, cap;
    char **keys;
    long long *vals;
} LexMap;

LexMap *__lex_map_new(void) {
    LexMap *m = (LexMap *)lex_alloc(sizeof(LexMap));
    m->len = 0;
    m->cap = 8;
    m->keys = (char **)lex_alloc((size_t)m->cap * sizeof(char *));
    m->vals = (long long *)lex_alloc((size_t)m->cap * sizeof(long long));
    return m;
}

long long __lex_map_len(LexMap *m) {
    return m ? m->len : 0;
}

static long long map_find(LexMap *m, const char *k) {
    for (long long i = 0; i < m->len; i++) {
        if (strcmp(m->keys[i], k) == 0) return i;
    }
    return -1;
}

void __lex_map_set(LexMap *m, const char *k, long long v) {
    long long at = map_find(m, k);
    if (at >= 0) {
        m->vals[at] = v;
        return;
    }
    if (m->len >= m->cap) {
        long long ncap = m->cap * 2;
        char **nk = (char **)lex_alloc((size_t)ncap * sizeof(char *));
        long long *nv = (long long *)lex_alloc((size_t)ncap * sizeof(long long));
        memcpy(nk, m->keys, (size_t)m->len * sizeof(char *));
        memcpy(nv, m->vals, (size_t)m->len * sizeof(long long));
        m->keys = nk;
        m->vals = nv;
        m->cap = ncap;
    }
    m->keys[m->len] = lex_strdup(k);
    m->vals[m->len] = v;
    m->len++;
}

long long __lex_map_get(LexMap *m, const char *k) {
    if (!m) return 0;
    long long at = map_find(m, k);
    return at >= 0 ? m->vals[at] : 0;
}

long long __lex_map_has(LexMap *m, const char *k) {
    if (!m) return 0;
    return map_find(m, k) >= 0 ? 1 : 0;
}

LexArr *__lex_map_keys(LexMap *m) {
    LexArr *r = __lex_arr_new(m ? m->len : 0);
    for (long long i = 0; i < (m ? m->len : 0); i++) {
        __lex_arr_push(r, (long long)m->keys[i]);
    }
    return r;
}

// ===========================================================================
// JSON — valor dinâmico (tagged union) + parser e serializador.
// tag: 0=null 1=bool 2=número(i64) 3=string 4=array 5=objeto
// payload: bool→0/1 · número→o i64 · string→char* · array→LexArr* · obj→LexMap*
// Os elementos de array/objeto são, eles mesmos, LexJson* (guardados como i64).
// ===========================================================================

enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ, J_FLOAT };

typedef struct {
    long long tag;
    long long payload;
} LexJson;

static LexJson *json_make(long long tag, long long payload) {
    LexJson *j = (LexJson *)lex_alloc(sizeof(LexJson));
    j->tag = tag;
    j->payload = payload;
    return j;
}

// construtores expostos (montar JSON no código lex)
LexJson *__lex_json_null(void) { return json_make(J_NULL, 0); }
LexJson *__lex_json_bool(long long b) { return json_make(J_BOOL, b ? 1 : 0); }
LexJson *__lex_json_num(long long n) { return json_make(J_NUM, n); }
// float: o payload guarda o padrão de bits do double (a célula i64 do lex)
LexJson *__lex_json_float(long long bits) { return json_make(J_FLOAT, bits); }
LexJson *__lex_json_str(const char *s) { return json_make(J_STR, (long long)lex_strdup(s)); }
LexJson *__lex_json_array(void) { return json_make(J_ARR, (long long)__lex_arr_new(4)); }
LexJson *__lex_json_object(void) { return json_make(J_OBJ, (long long)__lex_map_new()); }

void __lex_json_push(LexJson *arr, LexJson *v) {
    if (arr && arr->tag == J_ARR) __lex_arr_push((LexArr *)arr->payload, (long long)v);
}
void __lex_json_set(LexJson *obj, const char *k, LexJson *v) {
    if (obj && obj->tag == J_OBJ) __lex_map_set((LexMap *)obj->payload, k, (long long)v);
}

long long __lex_json_typeof(LexJson *j) { return j ? j->tag : J_NULL; }
long long __lex_json_is_null(LexJson *j) { return (!j || j->tag == J_NULL) ? 1 : 0; }

LexJson *__lex_json_get(LexJson *j, const char *key) {
    if (!j || j->tag != J_OBJ) return __lex_json_null();
    LexMap *m = (LexMap *)j->payload;
    long long at = map_find(m, key);
    return at >= 0 ? (LexJson *)m->vals[at] : __lex_json_null();
}

LexJson *__lex_json_at(LexJson *j, long long i) {
    if (!j || j->tag != J_ARR) return __lex_json_null();
    LexArr *a = (LexArr *)j->payload;
    if (i < 0 || i >= a->len) return __lex_json_null();
    return (LexJson *)a->data[i];
}

long long __lex_json_len(LexJson *j) {
    if (!j) return 0;
    if (j->tag == J_ARR) return ((LexArr *)j->payload)->len;
    if (j->tag == J_OBJ) return ((LexMap *)j->payload)->len;
    if (j->tag == J_STR) return (long long)strlen((const char *)j->payload);
    return 0;
}

long long __lex_json_as_int(LexJson *j) {
    if (!j) return 0;
    if (j->tag == J_NUM || j->tag == J_BOOL) return j->payload;
    if (j->tag == J_FLOAT) return (long long)lex_bits_to_f64(j->payload);
    if (j->tag == J_STR) return strtoll((const char *)j->payload, 0, 10);
    return 0;
}

long long __lex_json_as_bool(LexJson *j) {
    if (!j) return 0;
    if (j->tag == J_BOOL || j->tag == J_NUM) return j->payload ? 1 : 0;
    return 0;
}

// igualdade estrutural de dois valores json/any (por VALOR, não por endereço):
// número/float comparam numericamente; string por conteúdo; array/objeto
// recursivamente. É o que faz `expect(x).toBe(y)` servir p/ qualquer tipo.
long long __lex_json_eq(LexJson *a, LexJson *b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    long long ta = a->tag, tb = b->tag;
    // número e float são comparáveis entre si (como double)
    if ((ta == J_NUM || ta == J_FLOAT) && (tb == J_NUM || tb == J_FLOAT)) {
        double av = (ta == J_FLOAT) ? lex_bits_to_f64(a->payload) : (double)a->payload;
        double bv = (tb == J_FLOAT) ? lex_bits_to_f64(b->payload) : (double)b->payload;
        return av == bv ? 1 : 0;
    }
    if (ta != tb) return 0;
    switch (ta) {
        case J_NULL: return 1;
        case J_BOOL:
        case J_NUM: return a->payload == b->payload ? 1 : 0;
        case J_FLOAT: return lex_bits_to_f64(a->payload) == lex_bits_to_f64(b->payload) ? 1 : 0;
        case J_STR: return strcmp((const char *)a->payload, (const char *)b->payload) == 0 ? 1 : 0;
        case J_ARR: {
            LexArr *aa = (LexArr *)a->payload;
            LexArr *bb = (LexArr *)b->payload;
            if (aa->len != bb->len) return 0;
            for (long long i = 0; i < aa->len; i++) {
                if (!__lex_json_eq((LexJson *)aa->data[i], (LexJson *)bb->data[i])) return 0;
            }
            return 1;
        }
        case J_OBJ: {
            LexMap *am = (LexMap *)a->payload;
            LexMap *bm = (LexMap *)b->payload;
            if (am->len != bm->len) return 0;
            for (long long i = 0; i < am->len; i++) {
                long long j = map_find(bm, am->keys[i]);
                if (j < 0) return 0;
                if (!__lex_json_eq((LexJson *)am->vals[i], (LexJson *)bm->vals[j])) return 0;
            }
            return 1;
        }
    }
    return 0;
}

// lê um valor json como double (devolve o padrão de bits na célula i64)
long long __lex_json_as_float(LexJson *j) {
    if (!j) return lex_f64_to_bits(0.0);
    if (j->tag == J_FLOAT) return j->payload;
    if (j->tag == J_NUM) return lex_f64_to_bits((double)j->payload);
    if (j->tag == J_STR) return lex_f64_to_bits(strtod((const char *)j->payload, 0));
    return lex_f64_to_bits(0.0);
}

// escreve uma string JSON entre aspas, com escapes
static void json_write_str(StrBuf *b, const char *s) {
    sb_putc(b, '"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
            case '"': sb_puts(b, "\\\""); break;
            case '\\': sb_puts(b, "\\\\"); break;
            case '\n': sb_puts(b, "\\n"); break;
            case '\t': sb_puts(b, "\\t"); break;
            case '\r': sb_puts(b, "\\r"); break;
            default:
                if (c < 0x20) {
                    char tmp[8];
                    snprintf(tmp, 8, "\\u%04x", c);
                    sb_puts(b, tmp);
                } else {
                    sb_putc(b, (char)c);
                }
        }
    }
    sb_putc(b, '"');
}

static void json_write(StrBuf *b, LexJson *j) {
    if (!j) {
        sb_puts(b, "null");
        return;
    }
    switch (j->tag) {
        case J_NULL: sb_puts(b, "null"); break;
        case J_BOOL: sb_puts(b, j->payload ? "true" : "false"); break;
        case J_NUM: {
            char tmp[24];
            snprintf(tmp, 24, "%lld", (long long)j->payload);
            sb_puts(b, tmp);
            break;
        }
        case J_FLOAT: {
            char *s = __lex_f64_to_str(j->payload);
            sb_puts(b, s);
            break;
        }
        case J_STR: json_write_str(b, (const char *)j->payload); break;
        case J_ARR: {
            LexArr *a = (LexArr *)j->payload;
            sb_putc(b, '[');
            for (long long i = 0; i < a->len; i++) {
                if (i) sb_putc(b, ',');
                json_write(b, (LexJson *)a->data[i]);
            }
            sb_putc(b, ']');
            break;
        }
        case J_OBJ: {
            LexMap *m = (LexMap *)j->payload;
            sb_putc(b, '{');
            for (long long i = 0; i < m->len; i++) {
                if (i) sb_putc(b, ',');
                json_write_str(b, m->keys[i]);
                sb_putc(b, ':');
                json_write(b, (LexJson *)m->vals[i]);
            }
            sb_putc(b, '}');
            break;
        }
    }
}

char *__lex_json_stringify(LexJson *j) {
    StrBuf b;
    sb_init(&b);
    json_write(&b, j);
    return sb_finish(&b);
}

// devolve uma string para o valor: string crua, ou a forma textual do escalar
char *__lex_json_as_str(LexJson *j) {
    if (!j) return lex_strdup("null");
    switch (j->tag) {
        case J_STR: return (char *)j->payload;
        case J_NUM: return __lex_i64_to_str(j->payload);
        case J_FLOAT: return __lex_f64_to_str(j->payload);
        case J_BOOL: return lex_strdup(j->payload ? "true" : "false");
        case J_NULL: return lex_strdup("null");
        default: return __lex_json_stringify(j);
    }
}

// --- parser recursivo descendente -----------------------------------------

static void jskip(const char **p) {
    while (**p && isspace((unsigned char)**p)) (*p)++;
}

static LexJson *jvalue(const char **p);

static LexJson *jstring(const char **p) {
    (*p)++; // pula aspas de abertura
    StrBuf b;
    sb_init(&b);
    while (**p && **p != '"') {
        if (**p == '\\') {
            (*p)++;
            char c = **p;
            switch (c) {
                case 'n': sb_putc(&b, '\n'); break;
                case 't': sb_putc(&b, '\t'); break;
                case 'r': sb_putc(&b, '\r'); break;
                case 'b': sb_putc(&b, '\b'); break;
                case 'f': sb_putc(&b, '\f'); break;
                case '/': sb_putc(&b, '/'); break;
                case '"': sb_putc(&b, '"'); break;
                case '\\': sb_putc(&b, '\\'); break;
                case 'u': {
                    // só o plano básico: lê 4 hexa e emite o code point como UTF-8
                    char hex[5] = {0};
                    for (int k = 0; k < 4 && (*p)[1]; k++) hex[k] = *(++(*p));
                    long cp = strtol(hex, 0, 16);
                    if (cp < 0x80) {
                        sb_putc(&b, (char)cp);
                    } else if (cp < 0x800) {
                        sb_putc(&b, (char)(0xC0 | (cp >> 6)));
                        sb_putc(&b, (char)(0x80 | (cp & 0x3F)));
                    } else {
                        sb_putc(&b, (char)(0xE0 | (cp >> 12)));
                        sb_putc(&b, (char)(0x80 | ((cp >> 6) & 0x3F)));
                        sb_putc(&b, (char)(0x80 | (cp & 0x3F)));
                    }
                    break;
                }
                default: sb_putc(&b, c);
            }
            if (**p) (*p)++;
        } else {
            sb_putc(&b, **p);
            (*p)++;
        }
    }
    if (**p == '"') (*p)++;
    return json_make(J_STR, (long long)sb_finish(&b));
}

static LexJson *jvalue(const char **p) {
    jskip(p);
    char c = **p;
    if (c == '"') return jstring(p);
    if (c == '{') {
        (*p)++;
        LexJson *obj = __lex_json_object();
        LexMap *m = (LexMap *)obj->payload;
        jskip(p);
        if (**p == '}') { (*p)++; return obj; }
        while (**p) {
            jskip(p);
            if (**p != '"') break; // chave inválida: para
            LexJson *k = jstring(p);
            jskip(p);
            if (**p == ':') (*p)++;
            LexJson *v = jvalue(p);
            __lex_map_set(m, (const char *)k->payload, (long long)v);
            jskip(p);
            if (**p == ',') { (*p)++; continue; }
            if (**p == '}') { (*p)++; break; }
            break;
        }
        return obj;
    }
    if (c == '[') {
        (*p)++;
        LexJson *arr = __lex_json_array();
        LexArr *a = (LexArr *)arr->payload;
        jskip(p);
        if (**p == ']') { (*p)++; return arr; }
        while (**p) {
            LexJson *v = jvalue(p);
            __lex_arr_push(a, (long long)v);
            jskip(p);
            if (**p == ',') { (*p)++; continue; }
            if (**p == ']') { (*p)++; break; }
            break;
        }
        return arr;
    }
    if (strncmp(*p, "true", 4) == 0) { *p += 4; return json_make(J_BOOL, 1); }
    if (strncmp(*p, "false", 5) == 0) { *p += 5; return json_make(J_BOOL, 0); }
    if (strncmp(*p, "null", 4) == 0) { *p += 4; return json_make(J_NULL, 0); }
    // número: lê como double (tolera fração/expoente) e guarda como i64
    {
        char *end;
        double d = strtod(*p, &end);
        if (end == *p) { (*p)++; return json_make(J_NULL, 0); } // lixo: pula 1
        *p = end;
        return json_make(J_NUM, (long long)d);
    }
}

LexJson *__lex_json_parse(const char *s) {
    const char *p = s;
    return jvalue(&p);
}

// ===========================================================================
// Filesystem — primitivos portáveis (usam os headers reais da plataforma, o
// que resolve struct stat / dirent / flags O_* sem precisar de bitwise no lex).
// Expostos como builtins (readFile, writeFile, exists, readDir, ...). Strings
// devolvidas (conteúdo de arquivo, nomes de diretório) moram na arena.
// No wasm fica de fora: volta na fase WASI (fd_read/fd_write/path_open). No
// nativo freestanding (Linux/Windows), fs/canais/threads são implementados nas
// seções LEX_NATIVE_FREESTANDING / LEX_WIN_FREESTANDING abaixo, então este bloco
// (que usa a libc) só vale para o nativo-com-libc (host: clang+SDK).
// ===========================================================================
#if !defined(__wasm__) && !defined(LEX_NATIVE_FREESTANDING) && !defined(LEX_WIN_FREESTANDING)

// --- primitivas de host (CLI): argumentos e exec de processo --------------
// O `main` do lex não recebe argc/argv, então capturamos via um construtor do
// .init_array (macOS/glibc chamam-no com (argc, argv, envp)). Necessário para
// o compilador-em-lex (self-hosting) ler o arquivo de entrada e chamar o clang.
static int lex_host_argc = 0;
static char **lex_host_argv = 0;
__attribute__((constructor))
static void lex_capture_args(int argc, char **argv, char **envp) {
    (void)envp;
    lex_host_argc = argc;
    lex_host_argv = argv;
}
// args(): string[] — cada argv[i] (char* NUL-terminado) já é uma string lex.
long long __lex_args(void) {
    LexArr *a = __lex_arr_new(lex_host_argc > 0 ? lex_host_argc : 1);
    for (int i = 0; i < lex_host_argc; i++)
        __lex_arr_push(a, (long long)(intptr_t)lex_host_argv[i]);
    return (long long)(intptr_t)a;
}
// system(cmd): i64 — roda um comando pelo shell (p/ invocar clang/linker).
long long __lex_system(const char *cmd) { return (long long)system(cmd); }

// lê o arquivo inteiro para a arena; devolve string NUL-terminada ou 0 (erro)
char *__lex_fs_read(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return 0;
    }
    long n = ftell(f);
    if (n < 0) {
        fclose(f);
        return 0;
    }
    rewind(f);
    char *buf = lex_alloc((size_t)n + 1);
    size_t rd = fread(buf, 1, (size_t)n, f);
    buf[rd] = 0;
    fclose(f);
    return buf;
}

// readStdin(n): lê até n bytes de stdin p/ a arena; NUL-terminado; "" no EOF.
// Faz fflush(stdout) antes (padrão de servidor LSP: esvazia a resposta pendente
// antes de bloquear lendo a próxima mensagem — senão o stdout bufferizado em
// pipe trava o cliente). Só no alvo nativo-com-libc (como args/system).
char *__lex_read_stdin(long long n) {
    fflush(stdout);
    if (n < 0) n = 0;
    char *buf = lex_alloc((size_t)n + 1);
    size_t rd = fread(buf, 1, (size_t)n, stdin);
    buf[rd] = 0;
    return buf;
}

// escreve/anexa texto (NUL-terminado); devolve bytes escritos ou -1
static long long fs_put(const char *path, const char *data, int append) {
    FILE *f = fopen(path, append ? "ab" : "wb");
    if (!f) return -1;
    size_t len = strlen(data);
    size_t w = fwrite(data, 1, len, f);
    fclose(f);
    return (long long)w;
}
long long __lex_fs_write(const char *path, const char *data) { return fs_put(path, data, 0); }
long long __lex_fs_append(const char *path, const char *data) { return fs_put(path, data, 1); }

long long __lex_fs_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 ? 1 : 0;
}
long long __lex_fs_is_file(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISREG(st.st_mode) ? 1 : 0;
}
long long __lex_fs_is_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    return S_ISDIR(st.st_mode) ? 1 : 0;
}
long long __lex_fs_size(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return -1;
    return (long long)st.st_size;
}
long long __lex_fs_remove(const char *path) { return unlink(path) == 0 ? 0 : -1; }
long long __lex_fs_rename(const char *a, const char *b) { return rename(a, b) == 0 ? 0 : -1; }
long long __lex_fs_mkdir(const char *path) {
#ifdef _WIN32
    return mkdir(path) == 0 ? 0 : -1; // mingw: mkdir é de 1 argumento
#else
    return mkdir(path, 0755) == 0 ? 0 : -1;
#endif
}
long long __lex_fs_rmdir(const char *path) { return rmdir(path) == 0 ? 0 : -1; }

// lista as entradas do diretório (sem "." e "..") como string[] na arena;
// array vazio se o caminho não for um diretório acessível
LexArr *__lex_fs_list(const char *path) {
    LexArr *r = __lex_arr_new(8);
    DIR *d = opendir(path);
    if (!d) return r;
    struct dirent *e;
    while ((e = readdir(d)) != 0) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        __lex_arr_push(r, (long long)lex_strdup(e->d_name));
    }
    closedir(d);
    return r;
}

// abre um arquivo para streaming: mode 0=leitura, 1=escrita (trunca+cria),
// 2=append (cria). Devolve um fd (>=0) ou -1. read/write/close/lseek (libc)
// operam nesse fd — é o que dá leitura/escrita parcial e arquivos grandes.
long long __lex_fs_open(const char *path, long long mode) {
    int flags;
    switch (mode) {
        case 1: flags = O_WRONLY | O_CREAT | O_TRUNC; break;
        case 2: flags = O_WRONLY | O_CREAT | O_APPEND; break;
        default: flags = O_RDONLY; break;
    }
    return open(path, flags, 0644);
}

// ===========================================================================
// Canais entre threads (estilo Go) — fila FIFO bloqueante protegida por
// mutex + condvar. Vive no HEAP (não na arena), pois é compartilhado e precisa
// sobreviver ao fim da thread que o criou. Carrega valores i64 (números ou
// handles); strings montadas na arena de uma thread não atravessam com
// segurança, porque a arena some quando aquela thread termina.
// ===========================================================================

typedef struct LexChanNode {
    long long v;
    struct LexChanNode *next;
} LexChanNode;

typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t cond;
    LexChanNode *head, *tail;
    int closed;
} LexChan;

LexChan *__lex_chan_new(void) {
    LexChan *c = (LexChan *)calloc(1, sizeof(LexChan));
    pthread_mutex_init(&c->mtx, 0);
    pthread_cond_init(&c->cond, 0);
    return c;
}

void __lex_chan_send(LexChan *c, long long v) {
    if (!c) return;
    LexChanNode *n = (LexChanNode *)malloc(sizeof(LexChanNode));
    n->v = v;
    n->next = 0;
    pthread_mutex_lock(&c->mtx);
    if (c->tail) c->tail->next = n; else c->head = n;
    c->tail = n;
    pthread_cond_signal(&c->cond);
    pthread_mutex_unlock(&c->mtx);
}

// bloqueia até haver um valor; num canal fechado e vazio, devolve 0
long long __lex_chan_recv(LexChan *c) {
    if (!c) return 0;
    pthread_mutex_lock(&c->mtx);
    while (!c->head && !c->closed) pthread_cond_wait(&c->cond, &c->mtx);
    if (!c->head) {
        pthread_mutex_unlock(&c->mtx);
        return 0;
    }
    LexChanNode *n = c->head;
    c->head = n->next;
    if (!c->head) c->tail = 0;
    long long v = n->v;
    free(n);
    pthread_mutex_unlock(&c->mtx);
    return v;
}

// fecha o canal: acorda quem espera (recv num canal vazio passa a devolver 0)
long long __lex_chan_close(LexChan *c) {
    if (!c) return 0;
    pthread_mutex_lock(&c->mtx);
    c->closed = 1;
    pthread_cond_broadcast(&c->cond);
    pthread_mutex_unlock(&c->mtx);
    return 0;
}

#endif // __wasm__ (filesystem + canais voltam nas fases WASI/threads)

#ifdef __wasm__
// ===========================================================================
// Filesystem no wasm: a runtime não tem SO, então cada operação delega a um
// IMPORT do host (Node: node:fs; browser: VFS em memória), no namespace lex.*.
// Conteúdo de arquivo e nomes de diretório voltam para a arena: o host chama
// __lex_wasm_alloc para reservar o espaço na memória linear e copia os bytes.
// ===========================================================================

// Export usado pelo host para alocar na arena antes de copiar bytes p/ o wasm.
void *__lex_wasm_alloc(long long n) { return lex_alloc((size_t)(n > 0 ? n : 1)); }

#define LEX_FS_IMPORT(n) __attribute__((import_module("lex"), import_name(n)))
LEX_FS_IMPORT("fs_read")    extern char *__lex_host_fs_read(const char *path);
LEX_FS_IMPORT("fs_write")   extern long long __lex_host_fs_write(const char *p, const char *d, long long n);
LEX_FS_IMPORT("fs_append")  extern long long __lex_host_fs_append(const char *p, const char *d, long long n);
LEX_FS_IMPORT("fs_exists")  extern long long __lex_host_fs_exists(const char *p);
LEX_FS_IMPORT("fs_is_file") extern long long __lex_host_fs_is_file(const char *p);
LEX_FS_IMPORT("fs_is_dir")  extern long long __lex_host_fs_is_dir(const char *p);
LEX_FS_IMPORT("fs_size")    extern long long __lex_host_fs_size(const char *p);
LEX_FS_IMPORT("fs_remove")  extern long long __lex_host_fs_remove(const char *p);
LEX_FS_IMPORT("fs_rename")  extern long long __lex_host_fs_rename(const char *a, const char *b);
LEX_FS_IMPORT("fs_mkdir")   extern long long __lex_host_fs_mkdir(const char *p);
LEX_FS_IMPORT("fs_rmdir")   extern long long __lex_host_fs_rmdir(const char *p);
LEX_FS_IMPORT("fs_list")    extern char *__lex_host_fs_list(const char *p);
LEX_FS_IMPORT("fs_open")    extern long long __lex_host_fs_open(const char *p, long long mode);
LEX_FS_IMPORT("fd_read")    extern long long __lex_host_fd_read(long long fd, char *buf, long long n);
LEX_FS_IMPORT("fd_write")   extern long long __lex_host_fd_write(long long fd, const char *buf, long long n);
LEX_FS_IMPORT("fd_close")   extern long long __lex_host_fd_close(long long fd);
LEX_FS_IMPORT("fd_seek")    extern long long __lex_host_fd_seek(long long fd, long long off, long long whence);

// __lex_fs_* (ABI de ponteiro, via call_runtime): delegam direto ao host.
char *__lex_fs_read(const char *path) { return __lex_host_fs_read(path); }
long long __lex_fs_write(const char *p, const char *d) { return __lex_host_fs_write(p, d, (long long)strlen(d)); }
long long __lex_fs_append(const char *p, const char *d) { return __lex_host_fs_append(p, d, (long long)strlen(d)); }
long long __lex_fs_exists(const char *p) { return __lex_host_fs_exists(p); }
long long __lex_fs_is_file(const char *p) { return __lex_host_fs_is_file(p); }
long long __lex_fs_is_dir(const char *p) { return __lex_host_fs_is_dir(p); }
long long __lex_fs_size(const char *p) { return __lex_host_fs_size(p); }
long long __lex_fs_remove(const char *p) { return __lex_host_fs_remove(p); }
long long __lex_fs_rename(const char *a, const char *b) { return __lex_host_fs_rename(a, b); }
long long __lex_fs_mkdir(const char *p) { return __lex_host_fs_mkdir(p); }
long long __lex_fs_rmdir(const char *p) { return __lex_host_fs_rmdir(p); }
long long __lex_fs_open(const char *p, long long mode) { return __lex_host_fs_open(p, mode); }
// readDir: o host devolve os nomes juntos por "\n"; aqui viram string[] na arena
LexArr *__lex_fs_list(const char *path) {
    char *joined = __lex_host_fs_list(path);
    if (!joined || !joined[0]) return __lex_arr_new(0);
    return __lex_split(joined, "\n");
}

// libc por FFI (ABI i64, via declare_function): o `buf` chega como i64 — casta
// p/ ponteiro (i32 no wasm) e delega aos fds do host.
long long read(long long fd, long long buf, long long n) {
    return __lex_host_fd_read(fd, (char *)(uintptr_t)buf, n);
}
long long write(long long fd, long long buf, long long n) {
    // fd 0/1/2 (stdout/stderr — ex.: o Terminal) saem pela saída do host
    // (lex.write); fds de arquivo (>2, abertos por openFile) vão à tabela do host
    if (fd <= 2) {
        __lex_host_write((int)fd, (const char *)(uintptr_t)buf, (int)n);
        return n;
    }
    return __lex_host_fd_write(fd, (const char *)(uintptr_t)buf, n);
}
long long close(long long fd) { return __lex_host_fd_close(fd); }
long long lseek(long long fd, long long off, long long whence) {
    return __lex_host_fd_seek(fd, off, whence);
}
int usleep(long long us) { (void)us; return 0; } // sem sleep no browser: no-op

// símbolos libc PÚBLICOS para a FFI da std (terminal/http): o codegen os declara
// com ABI i64 (tudo i64). Recebem/retornam i64 e convertem para o ABI natural do
// wasm32 internamente. O uso interno da runtime continua nos lexw_* (ver topo).
#undef strlen
#undef malloc
#undef free
long long strlen(long long s) { return (long long)lexw_strlen((const char *)(uintptr_t)s); }
long long malloc(long long n) { return (long long)(uintptr_t)lexw_malloc((size_t)n); }
void free(long long p) { lexw_free((void *)(uintptr_t)p); }

// ===========================================================================
// Threads no wasm: o WebAssembly base é single-thread, então `spawn f()` roda
// SÍNCRONO (na hora, na mesma thread) e `join` devolve o resultado já calculado.
// Programas concorrentes produzem o resultado CERTO — em série, sem paralelismo.
// Paralelismo real (Web Workers + memória compartilhada + atomics) é um passo
// futuro; os canais viram uma FIFO single-thread (recv num canal vazio = 0).
// ===========================================================================

// pthread_create/join: o codegen os declara como (ptr,ptr,ptr,ptr)->i32 e
// (i64,ptr)->i32.
#define LEX_MAX_THREADS 4096

#ifdef LEX_WASM_THREADS
// ---- THREADS REAIS: cada `spawn` vira um Web Worker que compartilha a memória
// linear. O host (web/threads-host.mjs) atende o import `lex.spawn`: cria um
// Worker, instancia o MESMO módulo com a memória compartilhada, ajusta a pilha
// daquela thread (__stack_pointer) e chama o thunk pelo índice na tabela. O
// resultado e o "done" são escritos na memória compartilhada; `join` faz busy-
// wait atômico no slot de status (correto em Node/Worker, que progride em outra
// thread do SO). Resultados >32 bits truncam (o ABI do thunk é void* = i32).
__attribute__((import_module("lex"), import_name("spawn")))
extern void __lex_host_spawn(int fn_idx, void *arg, volatile int *status,
                             long long *res, void *stack_top);

static volatile int lex_thr_status[LEX_MAX_THREADS]; // 0 = rodando, 1 = pronto
static long long lex_thr_res[LEX_MAX_THREADS];
static long long lex_thr_next = 1;
static volatile int lex_tid_lock = 0;

int pthread_create(long long *tid, void *attr, void *(*fn)(void *), void *arg) {
    (void)attr;
    lex_lock(&lex_tid_lock);
    long long h = lex_thr_next++;
    lex_unlock(&lex_tid_lock);
    if (h <= 0 || h >= LEX_MAX_THREADS) {
        if (tid) *tid = 0;
        return 1;
    }
    __atomic_store_n(&lex_thr_status[h], 0, __ATOMIC_RELEASE);
    lex_thr_res[h] = 0;
    // pilha própria da thread (wasm cresce para baixo: topo = base + tamanho)
    const size_t STACK = (size_t)1 << 18; // 256 KiB por thread
    char *stk = (char *)lex_sbrk(STACK);
    void *stack_top = (void *)(stk + STACK);
    int idx = (int)(uintptr_t)fn; // ponteiro de função = índice na tabela
    __lex_host_spawn(idx, arg, &lex_thr_status[h], &lex_thr_res[h], stack_top);
    if (tid) *tid = h;
    return 0;
}
int pthread_join(long long tid, void **retval) {
    if (tid > 0 && tid < LEX_MAX_THREADS) {
        // busy-wait: o Worker roda noutra thread do SO e marca o status (release);
        // o load com acquire garante que o resultado já está visível.
        while (__atomic_load_n(&lex_thr_status[tid], __ATOMIC_ACQUIRE) == 0) {
            /* spin */
        }
        if (retval) *retval = (void *)(uintptr_t)lex_thr_res[tid];
    } else if (retval) {
        *retval = 0;
    }
    return 0;
}
int pthread_detach(long long tid) { (void)tid; return 0; }

#else // ---- single-thread: roda o thunk na hora e guarda o retorno -----------

static void *lex_thread_res[LEX_MAX_THREADS];
static long long lex_thread_next = 1; // 0 = handle inválido

int pthread_create(long long *tid, void *attr, void *(*fn)(void *), void *arg) {
    (void)attr;
    long long h = lex_thread_next++;
    void *res = fn(arg); // single-thread: executa já, na mesma thread
    if (h > 0 && h < LEX_MAX_THREADS) lex_thread_res[h] = res;
    if (tid) *tid = h;
    return 0;
}
int pthread_join(long long tid, void **retval) {
    if (retval) *retval = (tid > 0 && tid < LEX_MAX_THREADS) ? lex_thread_res[tid] : 0;
    return 0;
}
// spawn fire-and-forget desanexa a "thread"; síncrono: nada a fazer
int pthread_detach(long long tid) { (void)tid; return 0; }

#endif // LEX_WASM_THREADS

// Canais single-thread: FIFO simples (sem mutex/condvar — não há outra thread).
// send enfileira; recv desenfileira ou devolve 0 se vazio (não bloqueia).
typedef struct LexChanNode {
    long long v;
    struct LexChanNode *next;
} LexChanNode;
typedef struct {
    LexChanNode *head, *tail;
    int closed;
} LexChan;

LexChan *__lex_chan_new(void) { return (LexChan *)calloc(1, sizeof(LexChan)); }
void __lex_chan_send(LexChan *c, long long v) {
    if (!c) return;
    LexChanNode *n = (LexChanNode *)lexw_malloc(sizeof(LexChanNode));
    n->v = v;
    n->next = 0;
    if (c->tail) c->tail->next = n; else c->head = n;
    c->tail = n;
}
long long __lex_chan_recv(LexChan *c) {
    if (!c || !c->head) return 0; // vazio: sem bloqueio possível (single-thread)
    LexChanNode *n = c->head;
    c->head = n->next;
    if (!c->head) c->tail = 0;
    return n->v;
}
long long __lex_chan_close(LexChan *c) {
    if (c) c->closed = 1;
    return 0;
}
#endif // __wasm__ (filesystem + threads por host imports)

#ifdef LEX_NATIVE_FREESTANDING
// ===========================================================================
// Camada de SISTEMA OPERACIONAL do nativo freestanding (Linux): filesystem,
// rede, threads e canais por SYSCALLS — sem libc. Espelha o bloco nativo-com-
// libc acima, mas falando direto com o kernel; o _start próprio entra aqui.
// ===========================================================================

// memcmp: o compilador pode emiti-lo; os demais mem*/str* vêm do bloco shared.
int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = a, *y = b;
    for (size_t i = 0; i < n; i++)
        if (x[i] != y[i]) return (int)x[i] - (int)y[i];
    return 0;
}

// --- arena por thread sem TLS: tabela tid -> arena --------------------------
// Caminho rápido: enquanto nenhuma thread foi criada, usa uma única global (a
// thread principal). Ao 1º spawn, passa a indexar por tid (gettid). Isso evita
// montar TLS (%fs/tpidr) à mão num binário sem CRT.
#define LEX_ARENA_SLOTS 4096
static LexBlock *lex_arena_main = 0;
static long lex_main_tid = 0;
static volatile int lex_any_threads = 0;
static volatile int lex_arena_lock = 0;
static struct { long tid; LexBlock *arena; } lex_arena_tab[LEX_ARENA_SLOTS];

LexBlock **lex_arena_slot(void) {
    if (!lex_any_threads) return &lex_arena_main;
    long tid = lex_sc0(SYS_gettid);
    if (tid == lex_main_tid) return &lex_arena_main;
    lex_spin_lock(&lex_arena_lock);
    int freei = -1;
    for (int i = 0; i < LEX_ARENA_SLOTS; i++) {
        if (lex_arena_tab[i].tid == tid) {
            lex_spin_unlock(&lex_arena_lock);
            return &lex_arena_tab[i].arena;
        }
        if (freei < 0 && lex_arena_tab[i].tid == 0) freei = i;
    }
    if (freei < 0) { // tabela cheia: degrada para a arena principal (raro)
        lex_spin_unlock(&lex_arena_lock);
        return &lex_arena_main;
    }
    lex_arena_tab[freei].tid = tid;
    lex_arena_tab[freei].arena = 0;
    LexBlock **r = &lex_arena_tab[freei].arena;
    lex_spin_unlock(&lex_arena_lock);
    return r;
}
static void lex_arena_drop(long tid) {
    lex_spin_lock(&lex_arena_lock);
    for (int i = 0; i < LEX_ARENA_SLOTS; i++)
        if (lex_arena_tab[i].tid == tid) {
            lex_arena_tab[i].tid = 0;
            lex_arena_tab[i].arena = 0;
            break;
        }
    lex_spin_unlock(&lex_arena_lock);
}

// --- mutex / condvar por futex (estilo Drepper) -----------------------------
typedef struct { int v; } pthread_mutex_t;
typedef struct { int seq; } pthread_cond_t;
#define LEX_FUTEX_WAIT 0
#define LEX_FUTEX_WAKE 1
static int lex_futex(volatile int *a, int op, int val) {
    return (int)lex_sc6(SYS_futex, (long)a, op, val, 0, 0, 0);
}
int pthread_mutex_init(pthread_mutex_t *m, void *a) { (void)a; m->v = 0; return 0; }
int pthread_mutex_destroy(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_lock(pthread_mutex_t *m) {
    int c = __sync_val_compare_and_swap(&m->v, 0, 1);
    if (c != 0) {
        if (c != 2) c = __sync_lock_test_and_set(&m->v, 2);
        while (c != 0) {
            lex_futex(&m->v, LEX_FUTEX_WAIT, 2);
            c = __sync_lock_test_and_set(&m->v, 2);
        }
    }
    return 0;
}
int pthread_mutex_unlock(pthread_mutex_t *m) {
    if (__sync_fetch_and_sub(&m->v, 1) != 1) {
        m->v = 0;
        lex_futex(&m->v, LEX_FUTEX_WAKE, 1);
    }
    return 0;
}
int pthread_cond_init(pthread_cond_t *c, void *a) { (void)a; c->seq = 0; return 0; }
int pthread_cond_destroy(pthread_cond_t *c) { (void)c; return 0; }
int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) {
    int seq = c->seq;
    pthread_mutex_unlock(m);
    lex_futex(&c->seq, LEX_FUTEX_WAIT, seq); // acorda espúrio é ok (callers em loop)
    pthread_mutex_lock(m);
    return 0;
}
int pthread_cond_signal(pthread_cond_t *c) {
    __sync_fetch_and_add(&c->seq, 1);
    lex_futex(&c->seq, LEX_FUTEX_WAKE, 1);
    return 0;
}
int pthread_cond_broadcast(pthread_cond_t *c) {
    __sync_fetch_and_add(&c->seq, 1);
    lex_futex(&c->seq, LEX_FUTEX_WAKE, 0x7fffffff);
    return 0;
}

// --- threads reais via clone + futex ----------------------------------------
typedef struct {
    int tid_futex;     // !=0 enquanto roda; o kernel zera + acorda no exit (ctid)
    void *(*fn)(void *);
    void *arg;
    void *retval;
    void *stack;       // base do mmap (munmap no join)
    size_t stack_sz;
} LexThread;

// asm (por arch): roda no contexto novo. (tramp, stack_top, flags, tcb, ctid).
extern long __lex_clone(void *tramp, void *stack_top, long flags, void *tcb, int *ctid);

static void lex_thread_tramp(void *p) {
    LexThread *t = (LexThread *)p;
    long tid = lex_sc0(SYS_gettid);
    // o thunk do spawn (codegen) já chama __lex_arena_free ao final; aqui só
    // soltamos o slot da arena desta thread depois que fn retorna.
    t->retval = t->fn(t->arg);
    lex_arena_drop(tid);
}

// flags do clone: VM|FS|FILES|SIGHAND|THREAD|SYSVSEM|PARENT_SETTID|CHILD_CLEARTID
#define LEX_CLONE_FLAGS (0x100 | 0x200 | 0x400 | 0x800 | 0x10000 | 0x40000 | 0x100000 | 0x200000)

int pthread_create(long long *tid, void *attr, void *(*fn)(void *), void *arg) {
    (void)attr;
    lex_any_threads = 1;
    size_t ssz = 1 << 20; // 1 MiB de stack por thread
    long m = lex_sc6(SYS_mmap, 0, (long)ssz, 0x3, 0x22, -1, 0);
    if (m < 0 && m > -4096) return -1;
    char *stack = (char *)m;
    LexThread *t = (LexThread *)malloc(sizeof(LexThread));
    if (!t) { lex_sc2(SYS_munmap, (long)stack, (long)ssz); return -1; }
    t->fn = fn; t->arg = arg; t->retval = 0;
    t->stack = stack; t->stack_sz = ssz; t->tid_futex = -1;
    long r = __lex_clone((void *)lex_thread_tramp, stack + ssz,
                         (long)(LEX_CLONE_FLAGS), t, &t->tid_futex);
    if (r < 0) { free(t); lex_sc2(SYS_munmap, (long)stack, (long)ssz); return -1; }
    if (tid) *tid = (long long)(uintptr_t)t;
    return 0;
}
int pthread_join(long long tid, void **retval) {
    LexThread *t = (LexThread *)(uintptr_t)tid;
    if (!t) { if (retval) *retval = 0; return 0; }
    int v;
    while ((v = t->tid_futex) != 0) lex_futex(&t->tid_futex, LEX_FUTEX_WAIT, v);
    if (retval) *retval = t->retval;
    lex_sc2(SYS_munmap, (long)t->stack, (long)t->stack_sz);
    free(t);
    return 0;
}
int pthread_detach(long long tid) { (void)tid; return 0; } // fire-and-forget

// --- canais (FIFO bloqueante: mutex + condvar, como no nativo-libc) ---------
typedef struct LexChanNode { long long v; struct LexChanNode *next; } LexChanNode;
typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t cond;
    LexChanNode *head, *tail;
    int closed;
} LexChan;

LexChan *__lex_chan_new(void) {
    LexChan *c = (LexChan *)calloc(1, sizeof(LexChan));
    pthread_mutex_init(&c->mtx, 0);
    pthread_cond_init(&c->cond, 0);
    return c;
}
void __lex_chan_send(LexChan *c, long long v) {
    if (!c) return;
    LexChanNode *n = (LexChanNode *)malloc(sizeof(LexChanNode));
    n->v = v; n->next = 0;
    pthread_mutex_lock(&c->mtx);
    if (c->tail) c->tail->next = n; else c->head = n;
    c->tail = n;
    pthread_cond_signal(&c->cond);
    pthread_mutex_unlock(&c->mtx);
}
long long __lex_chan_recv(LexChan *c) {
    if (!c) return 0;
    pthread_mutex_lock(&c->mtx);
    while (!c->head && !c->closed) pthread_cond_wait(&c->cond, &c->mtx);
    if (!c->head) { pthread_mutex_unlock(&c->mtx); return 0; }
    LexChanNode *n = c->head;
    c->head = n->next;
    if (!c->head) c->tail = 0;
    long long v = n->v;
    free(n);
    pthread_mutex_unlock(&c->mtx);
    return v;
}
long long __lex_chan_close(LexChan *c) {
    if (!c) return 0;
    pthread_mutex_lock(&c->mtx);
    c->closed = 1;
    pthread_cond_broadcast(&c->cond);
    pthread_mutex_unlock(&c->mtx);
    return 0;
}

// --- filesystem por syscalls (openat/statx/getdents64; *at + statx p/ portar
//     x86_64 e aarch64 com a MESMA lista de syscalls, só mudando os números) -
#define LEX_AT_FDCWD -100
#define LEX_O_RDONLY 0
#define LEX_O_WRONLY 1
#define LEX_O_CREAT 0x40
#define LEX_O_TRUNC 0x200
#define LEX_O_APPEND 0x400
// (O_DIRECTORY tem valor diferente por arch — x86_64=0x10000, aarch64=0x4000 —
// então não o usamos: abrimos a pasta com O_RDONLY e deixamos o getdents64
// falhar sozinho se não for diretório. Fica independente de arquitetura.)

char *__lex_fs_read(const char *path) {
    long fd = lex_sc4(SYS_openat, LEX_AT_FDCWD, path, LEX_O_RDONLY, 0);
    if (fd < 0) return 0;
    long sz = lex_sc3(SYS_lseek, fd, 0, 2 /*SEEK_END*/);
    lex_sc3(SYS_lseek, fd, 0, 0 /*SEEK_SET*/);
    if (sz < 0) { lex_sc1(SYS_close, fd); return 0; }
    char *buf = lex_alloc((size_t)sz + 1);
    long off = 0;
    while (off < sz) {
        long r = lex_sc3(SYS_read, fd, buf + off, sz - off);
        if (r <= 0) break;
        off += r;
    }
    buf[off] = 0;
    lex_sc1(SYS_close, fd);
    return buf;
}
static long long lex_fs_put(const char *path, const char *data, int append) {
    int flags = append ? (LEX_O_WRONLY | LEX_O_CREAT | LEX_O_APPEND)
                       : (LEX_O_WRONLY | LEX_O_CREAT | LEX_O_TRUNC);
    long fd = lex_sc4(SYS_openat, LEX_AT_FDCWD, path, flags, 0644);
    if (fd < 0) return -1;
    size_t len = strlen(data), off = 0;
    while (off < len) {
        long w = lex_sc3(SYS_write, fd, data + off, len - off);
        if (w <= 0) { lex_sc1(SYS_close, fd); return -1; }
        off += (size_t)w;
    }
    lex_sc1(SYS_close, fd);
    return (long long)len;
}
long long __lex_fs_write(const char *p, const char *d) { return lex_fs_put(p, d, 0); }
long long __lex_fs_append(const char *p, const char *d) { return lex_fs_put(p, d, 1); }

// statx: lê mode (off 28, u16) e size (off 40, u64) — layout estável da struct
static int lex_statx(const char *path, unsigned *mode, unsigned long long *size) {
    unsigned char b[256];
    long r = lex_sc5(SYS_statx, LEX_AT_FDCWD, path, 0, 0x7ff /*BASIC_STATS*/, b);
    if (r < 0) return -1;
    if (mode) { unsigned short m; memcpy(&m, b + 28, 2); *mode = m; }
    if (size) { unsigned long long s; memcpy(&s, b + 40, 8); *size = s; }
    return 0;
}
long long __lex_fs_exists(const char *p) { return lex_statx(p, 0, 0) == 0 ? 1 : 0; }
long long __lex_fs_is_file(const char *p) {
    unsigned m; if (lex_statx(p, &m, 0)) return 0;
    return (m & 0170000) == 0100000 ? 1 : 0;
}
long long __lex_fs_is_dir(const char *p) {
    unsigned m; if (lex_statx(p, &m, 0)) return 0;
    return (m & 0170000) == 0040000 ? 1 : 0;
}
long long __lex_fs_size(const char *p) {
    unsigned long long s; if (lex_statx(p, 0, &s)) return -1;
    return (long long)s;
}
long long __lex_fs_remove(const char *p) { return lex_sc3(SYS_unlinkat, LEX_AT_FDCWD, p, 0) == 0 ? 0 : -1; }
long long __lex_fs_rename(const char *a, const char *b) {
    return lex_sc5(SYS_renameat2, LEX_AT_FDCWD, a, LEX_AT_FDCWD, b, 0) == 0 ? 0 : -1;
}
long long __lex_fs_mkdir(const char *p) { return lex_sc3(SYS_mkdirat, LEX_AT_FDCWD, p, 0755) == 0 ? 0 : -1; }
long long __lex_fs_rmdir(const char *p) { return lex_sc3(SYS_unlinkat, LEX_AT_FDCWD, p, 0x200 /*AT_REMOVEDIR*/) == 0 ? 0 : -1; }
LexArr *__lex_fs_list(const char *path) {
    LexArr *r = __lex_arr_new(8);
    long fd = lex_sc4(SYS_openat, LEX_AT_FDCWD, path, LEX_O_RDONLY, 0);
    if (fd < 0) return r;
    char buf[4096];
    for (;;) {
        long n = lex_sc3(SYS_getdents64, fd, buf, sizeof(buf));
        if (n <= 0) break;
        long off = 0;
        while (off < n) {
            unsigned short reclen;
            memcpy(&reclen, buf + off + 16, 2); // linux_dirent64: d_reclen no off 16
            const char *name = buf + off + 19;   // d_name no off 19
            if (!(name[0] == '.' && (name[1] == 0 || (name[1] == '.' && name[2] == 0))))
                __lex_arr_push(r, (long long)lex_strdup(name));
            off += reclen;
        }
    }
    lex_sc1(SYS_close, fd);
    return r;
}
long long __lex_fs_open(const char *path, long long mode) {
    int flags = mode == 1 ? (LEX_O_WRONLY | LEX_O_CREAT | LEX_O_TRUNC)
              : mode == 2 ? (LEX_O_WRONLY | LEX_O_CREAT | LEX_O_APPEND)
                          : LEX_O_RDONLY;
    return lex_sc4(SYS_openat, LEX_AT_FDCWD, path, flags, 0644);
}

// --- libc pública por FFI (ABI i64 == ABI natural no 64-bit) ----------------
long long read(long long fd, void *buf, long long n) { return lex_sc3(SYS_read, fd, buf, n); }
long long write(long long fd, const void *buf, long long n) { return lex_sc3(SYS_write, fd, buf, n); }
long long close(long long fd) { return lex_sc1(SYS_close, fd); }
long long lseek(long long fd, long long off, long long whence) { return lex_sc3(SYS_lseek, fd, off, whence); }
int usleep(long long us) {
    long ts[2]; ts[0] = us / 1000000; ts[1] = (us % 1000000) * 1000; // timespec {sec,nsec}
    lex_sc2(SYS_nanosleep, ts, 0);
    return 0;
}
long long socket(long long d, long long t, long long p) { return lex_sc3(SYS_socket, d, t, p); }
long long bind(long long fd, void *a, long long l) { return lex_sc3(SYS_bind, fd, a, l); }
long long listen(long long fd, long long b) { return lex_sc2(SYS_listen, fd, b); }
long long accept(long long fd, void *a, void *l) { return lex_sc3(SYS_accept, fd, a, l); }
long long connect(long long fd, void *a, long long l) { return lex_sc3(SYS_connect, fd, a, l); }
long long setsockopt(long long fd, long long lv, long long op, void *v, long long l) {
    return lex_sc5(SYS_setsockopt, fd, lv, op, v, l);
}
__attribute__((noreturn)) void exit(int code) {
    lex_sc1(SYS_exit_group, code);
    __builtin_unreachable();
}

// --- ponto de entrada (sem CRT): _start -> __lex_start_main -> main ---------
extern int main(void);
extern void (*__init_array_start[])(void) __attribute__((weak));
extern void (*__init_array_end[])(void) __attribute__((weak));

__attribute__((used, noreturn)) void __lex_start_main(void) {
    lex_main_tid = lex_sc0(SYS_gettid);
    for (void (**f)(void) = __init_array_start; f != __init_array_end; f++)
        if (*f) (*f)();
    int code = main();
    lex_sc1(SYS_exit_group, code);
    __builtin_unreachable();
}

#if defined(__x86_64__)
__asm__(
    ".text\n"
    ".global _start\n"
    "_start:\n"
    "  xor %rbp, %rbp\n"
    "  and $-16, %rsp\n"
    "  call __lex_start_main\n"
    "  hlt\n"
    // long __lex_clone(rdi=tramp, rsi=stack_top, rdx=flags, rcx=tcb, r8=ctid)
    ".global __lex_clone\n"
    "__lex_clone:\n"
    "  and $-16, %rsi\n"
    "  sub $16, %rsi\n"
    "  mov %rdi, 0(%rsi)\n"     // salva tramp no stack do filho
    "  mov %rcx, 8(%rsi)\n"     // salva tcb
    "  mov %rdx, %rdi\n"        // flags
    "  mov %r8, %rdx\n"         // parent_tid = ctid (PARENT_SETTID: !=0 ao criar)
    "  mov %r8, %r10\n"         // child_tid  = ctid (CHILD_CLEARTID: 0 ao sair)
    "  xor %r8, %r8\n"          // tls = 0
    "  mov $56, %rax\n"         // SYS_clone (x86_64)
    "  syscall\n"
    "  test %rax, %rax\n"
    "  jz 1f\n"
    "  ret\n"                   // pai: rax = tid do filho
    "1:\n"                      // filho: rsp = stack que passamos
    "  xor %rbp, %rbp\n"
    "  pop %rax\n"              // tramp
    "  pop %rdi\n"              // tcb
    "  call *%rax\n"            // tramp(tcb)
    "  mov $60, %rax\n"         // SYS_exit (só esta thread)
    "  xor %rdi, %rdi\n"
    "  syscall\n"
    "  hlt\n"
);
#elif defined(__aarch64__)
__asm__(
    ".text\n"
    ".global _start\n"
    "_start:\n"
    "  mov x29, #0\n"
    "  mov x30, #0\n"
    "  mov x9, sp\n"
    "  and x9, x9, #-16\n"
    "  mov sp, x9\n"
    "  bl __lex_start_main\n"
    "  brk #0\n"
    // long __lex_clone(x0=tramp, x1=stack_top, x2=flags, x3=tcb, x4=ctid)
    ".global __lex_clone\n"
    "__lex_clone:\n"
    "  and x1, x1, #-16\n"
    "  sub x1, x1, #16\n"
    "  str x0, [x1, #0]\n"      // tramp
    "  str x3, [x1, #8]\n"      // tcb
    "  mov x0, x2\n"            // flags
    "  mov x2, x4\n"            // parent_tid = ctid
    "  mov x3, #0\n"            // tls = 0 (aarch64: tls vem antes do child_tid)
    // x4 = child_tid = ctid (já está)
    "  mov x8, #220\n"          // SYS_clone (aarch64)
    "  svc #0\n"
    "  cbz x0, 1f\n"
    "  ret\n"                   // pai: x0 = tid
    "1:\n"                      // filho: sp = stack que passamos
    "  mov x29, #0\n"
    "  ldr x9, [sp, #0]\n"      // tramp
    "  ldr x0, [sp, #8]\n"      // tcb
    "  blr x9\n"
    "  mov x8, #93\n"           // SYS_exit
    "  mov x0, #0\n"
    "  svc #0\n"
    "  brk #0\n"
);
#endif

#endif // LEX_NATIVE_FREESTANDING

#ifdef LEX_WIN_FREESTANDING
// ===========================================================================
// Camada de SISTEMA OPERACIONAL do nativo freestanding (Windows): filesystem,
// rede, threads e canais pela Win32 API (kernel32/ws2_32) — sem libc nem CRT.
// Paths chegam em UTF-8 e são convertidos p/ UTF-16 (a API W) com a própria
// MultiByteToWideChar. O lexWinStart próprio é o ponto de entrada.
// ===========================================================================
typedef unsigned short LEX_WCHAR;

// O MSVC/clang referencia _fltused quando a unidade usa ponto flutuante (a
// runtime usa double em strtod). Normalmente vem do CRT; sem libc, definimos.
int _fltused = 1;

__declspec(dllimport) LEX_BOOL ReadFile(LEX_HANDLE, void *, LEX_DWORD, LEX_DWORD *, void *);
__declspec(dllimport) LEX_BOOL CloseHandle(LEX_HANDLE);
__declspec(dllimport) LEX_HANDLE CreateFileW(const LEX_WCHAR *, LEX_DWORD, LEX_DWORD, void *, LEX_DWORD, LEX_DWORD, LEX_HANDLE);
__declspec(dllimport) LEX_BOOL SetFilePointerEx(LEX_HANDLE, long long, long long *, LEX_DWORD);
__declspec(dllimport) LEX_DWORD GetFileAttributesW(const LEX_WCHAR *);
__declspec(dllimport) LEX_BOOL GetFileAttributesExW(const LEX_WCHAR *, int, void *);
__declspec(dllimport) LEX_BOOL DeleteFileW(const LEX_WCHAR *);
__declspec(dllimport) LEX_BOOL MoveFileExW(const LEX_WCHAR *, const LEX_WCHAR *, LEX_DWORD);
__declspec(dllimport) LEX_BOOL CreateDirectoryW(const LEX_WCHAR *, void *);
__declspec(dllimport) LEX_BOOL RemoveDirectoryW(const LEX_WCHAR *);
__declspec(dllimport) LEX_HANDLE FindFirstFileW(const LEX_WCHAR *, void *);
__declspec(dllimport) LEX_BOOL FindNextFileW(LEX_HANDLE, void *);
__declspec(dllimport) LEX_BOOL FindClose(LEX_HANDLE);
__declspec(dllimport) int MultiByteToWideChar(unsigned, LEX_DWORD, const char *, int, LEX_WCHAR *, int);
__declspec(dllimport) int WideCharToMultiByte(unsigned, LEX_DWORD, const LEX_WCHAR *, int, char *, int, const char *, void *);
__declspec(dllimport) LEX_DWORD GetCurrentThreadId(void);
__declspec(dllimport) LEX_HANDLE CreateThread(void *, LEX_SIZE_T, LEX_DWORD (*)(void *), void *, LEX_DWORD, LEX_DWORD *);
__declspec(dllimport) LEX_DWORD WaitForSingleObject(LEX_HANDLE, LEX_DWORD);
__declspec(dllimport) void Sleep(LEX_DWORD);
__declspec(dllimport) void InitializeCriticalSection(void *);
__declspec(dllimport) void EnterCriticalSection(void *);
__declspec(dllimport) void LeaveCriticalSection(void *);
__declspec(dllimport) void DeleteCriticalSection(void *);
__declspec(dllimport) void InitializeConditionVariable(void *);
__declspec(dllimport) LEX_BOOL SleepConditionVariableCS(void *, void *, LEX_DWORD);
__declspec(dllimport) void WakeConditionVariable(void *);
__declspec(dllimport) void WakeAllConditionVariable(void *);
__declspec(dllimport) void ExitProcess(unsigned);
__declspec(dllimport) int WSAStartup(unsigned short, void *);

#define LEX_INVALID_HANDLE ((LEX_HANDLE)(long long)-1)
#define LEX_GENERIC_READ 0x80000000UL
#define LEX_GENERIC_WRITE 0x40000000UL
#define LEX_FILE_SHARE_RW 0x3
#define LEX_CREATE_ALWAYS 2
#define LEX_OPEN_EXISTING 3
#define LEX_OPEN_ALWAYS 4
#define LEX_ATTR_NORMAL 0x80
#define LEX_ATTR_DIRECTORY 0x10
#define LEX_INVALID_ATTRS 0xFFFFFFFFUL
#define LEX_MOVE_REPLACE 0x1
#define LEX_INFINITE 0xFFFFFFFFUL

// memcmp: o compilador pode emiti-lo; os demais mem*/str* vêm do bloco shared.
int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = a, *y = b;
    for (size_t i = 0; i < n; i++)
        if (x[i] != y[i]) return (int)x[i] - (int)y[i];
    return 0;
}

// __chkstk: o MSVC/clang chama isto em prólogos com frame > 1 página (4 KB),
// para tocar as guard pages na ordem. Normalmente vem do CRT; sem libc, nós o
// fornecemos (versão canônica do compiler-rt). RAX=tamanho; preserva RAX/RSP.
#if defined(__x86_64__)
__asm__(
    ".text\n"
    ".global __chkstk\n"
    "__chkstk:\n"
    "  push %rcx\n"
    "  push %rax\n"
    "  cmp $0x1000, %rax\n"
    "  lea 24(%rsp), %rcx\n"
    "  jb 1f\n"
    "2:\n"
    "  sub $0x1000, %rcx\n"
    "  test %rcx, (%rcx)\n"
    "  sub $0x1000, %rax\n"
    "  cmp $0x1000, %rax\n"
    "  ja 2b\n"
    "1:\n"
    "  sub %rax, %rcx\n"
    "  test %rcx, (%rcx)\n"
    "  pop %rax\n"
    "  pop %rcx\n"
    "  ret\n"
);
#elif defined(__aarch64__)
// ARM64 Windows: x15 = tamanho em unidades de 16 bytes. Toca as guard pages.
__asm__(
    ".text\n"
    ".global __chkstk\n"
    "__chkstk:\n"
    "  lsl x16, x15, #4\n"
    "  mov x17, sp\n"
    "1:\n"
    "  sub x17, x17, #4096\n"
    "  subs x16, x16, #4096\n"
    "  ldr xzr, [x17]\n"
    "  b.gt 1b\n"
    "  ret\n"
);
#endif

// spinlock para a tabela de arenas (threads compartilham o heap do processo)
static volatile int lex_arena_lock = 0;
static void lex_spin_lock(volatile int *l) {
    while (__sync_lock_test_and_set(l, 1))
        while (*l) __asm__ volatile("" ::: "memory");
}
static void lex_spin_unlock(volatile int *l) { __sync_lock_release(l); }

// --- arena por thread sem TLS: tabela tid -> arena (GetCurrentThreadId) ------
#define LEX_ARENA_SLOTS 4096
static LexBlock *lex_arena_main = 0;
static long lex_main_tid = 0;
static volatile int lex_any_threads = 0;
static struct { long tid; LexBlock *arena; } lex_arena_tab[LEX_ARENA_SLOTS];

LexBlock **lex_arena_slot(void) {
    if (!lex_any_threads) return &lex_arena_main;
    long tid = (long)GetCurrentThreadId();
    if (tid == lex_main_tid) return &lex_arena_main;
    lex_spin_lock(&lex_arena_lock);
    int freei = -1;
    for (int i = 0; i < LEX_ARENA_SLOTS; i++) {
        if (lex_arena_tab[i].tid == tid) {
            lex_spin_unlock(&lex_arena_lock);
            return &lex_arena_tab[i].arena;
        }
        if (freei < 0 && lex_arena_tab[i].tid == 0) freei = i;
    }
    if (freei < 0) { lex_spin_unlock(&lex_arena_lock); return &lex_arena_main; }
    lex_arena_tab[freei].tid = tid;
    lex_arena_tab[freei].arena = 0;
    LexBlock **r = &lex_arena_tab[freei].arena;
    lex_spin_unlock(&lex_arena_lock);
    return r;
}
static void lex_arena_drop(long tid) {
    lex_spin_lock(&lex_arena_lock);
    for (int i = 0; i < LEX_ARENA_SLOTS; i++)
        if (lex_arena_tab[i].tid == tid) {
            lex_arena_tab[i].tid = 0;
            lex_arena_tab[i].arena = 0;
            break;
        }
    lex_spin_unlock(&lex_arena_lock);
}

// --- mutex / condvar: CRITICAL_SECTION + CONDITION_VARIABLE do Win32 --------
typedef struct { unsigned char cs[40]; } pthread_mutex_t; // sizeof(CRITICAL_SECTION) no x64
typedef struct { void *cv; } pthread_cond_t;              // CONDITION_VARIABLE = 1 ptr
int pthread_mutex_init(pthread_mutex_t *m, void *a) { (void)a; InitializeCriticalSection(m); return 0; }
int pthread_mutex_destroy(pthread_mutex_t *m) { DeleteCriticalSection(m); return 0; }
int pthread_mutex_lock(pthread_mutex_t *m) { EnterCriticalSection(m); return 0; }
int pthread_mutex_unlock(pthread_mutex_t *m) { LeaveCriticalSection(m); return 0; }
int pthread_cond_init(pthread_cond_t *c, void *a) { (void)a; InitializeConditionVariable(c); return 0; }
int pthread_cond_destroy(pthread_cond_t *c) { (void)c; return 0; }
int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) { SleepConditionVariableCS(c, m, LEX_INFINITE); return 0; }
int pthread_cond_signal(pthread_cond_t *c) { WakeConditionVariable(c); return 0; }
int pthread_cond_broadcast(pthread_cond_t *c) { WakeAllConditionVariable(c); return 0; }

// --- threads via CreateThread -----------------------------------------------
typedef struct {
    LEX_HANDLE handle;
    void *(*fn)(void *);
    void *arg;
    void *retval;
} LexThread;

static LEX_DWORD lex_thread_tramp(void *p) {
    LexThread *t = (LexThread *)p;
    long tid = (long)GetCurrentThreadId();
    // o thunk do spawn (codegen) já chama __lex_arena_free ao final
    t->retval = t->fn(t->arg);
    lex_arena_drop(tid);
    return 0;
}
int pthread_create(long long *tid, void *attr, void *(*fn)(void *), void *arg) {
    (void)attr;
    lex_any_threads = 1;
    LexThread *t = (LexThread *)malloc(sizeof(LexThread));
    if (!t) return -1;
    t->fn = fn; t->arg = arg; t->retval = 0;
    LEX_DWORD wtid = 0;
    t->handle = CreateThread(0, 0, lex_thread_tramp, t, 0, &wtid);
    if (!t->handle) { free(t); return -1; }
    if (tid) *tid = (long long)(uintptr_t)t;
    return 0;
}
int pthread_join(long long tid, void **retval) {
    LexThread *t = (LexThread *)(uintptr_t)tid;
    if (!t) { if (retval) *retval = 0; return 0; }
    WaitForSingleObject(t->handle, LEX_INFINITE);
    if (retval) *retval = t->retval;
    CloseHandle(t->handle);
    free(t);
    return 0;
}
int pthread_detach(long long tid) {
    LexThread *t = (LexThread *)(uintptr_t)tid;
    if (t && t->handle) CloseHandle(t->handle); // a thread segue; TCB vaza (raro)
    return 0;
}

// --- canais (FIFO bloqueante: mutex + condvar) ------------------------------
typedef struct LexChanNode { long long v; struct LexChanNode *next; } LexChanNode;
typedef struct {
    pthread_mutex_t mtx;
    pthread_cond_t cond;
    LexChanNode *head, *tail;
    int closed;
} LexChan;
LexChan *__lex_chan_new(void) {
    LexChan *c = (LexChan *)calloc(1, sizeof(LexChan));
    pthread_mutex_init(&c->mtx, 0);
    pthread_cond_init(&c->cond, 0);
    return c;
}
void __lex_chan_send(LexChan *c, long long v) {
    if (!c) return;
    LexChanNode *n = (LexChanNode *)malloc(sizeof(LexChanNode));
    n->v = v; n->next = 0;
    pthread_mutex_lock(&c->mtx);
    if (c->tail) c->tail->next = n; else c->head = n;
    c->tail = n;
    pthread_cond_signal(&c->cond);
    pthread_mutex_unlock(&c->mtx);
}
long long __lex_chan_recv(LexChan *c) {
    if (!c) return 0;
    pthread_mutex_lock(&c->mtx);
    while (!c->head && !c->closed) pthread_cond_wait(&c->cond, &c->mtx);
    if (!c->head) { pthread_mutex_unlock(&c->mtx); return 0; }
    LexChanNode *n = c->head;
    c->head = n->next;
    if (!c->head) c->tail = 0;
    long long v = n->v;
    free(n);
    pthread_mutex_unlock(&c->mtx);
    return v;
}
long long __lex_chan_close(LexChan *c) {
    if (!c) return 0;
    pthread_mutex_lock(&c->mtx);
    c->closed = 1;
    pthread_cond_broadcast(&c->cond);
    pthread_mutex_unlock(&c->mtx);
    return 0;
}

// --- filesystem pela Win32 (UTF-8 -> UTF-16) --------------------------------
#define LEX_CP_UTF8 65001
static void lex_widen(const char *utf8, LEX_WCHAR *w, int wcap) {
    int r = MultiByteToWideChar(LEX_CP_UTF8, 0, utf8, -1, w, wcap);
    if (r <= 0) w[0] = 0; // falha: string vazia
}
char *__lex_fs_read(const char *path) {
    LEX_WCHAR w[1024]; lex_widen(path, w, 1024);
    LEX_HANDLE h = CreateFileW(w, LEX_GENERIC_READ, LEX_FILE_SHARE_RW, 0, LEX_OPEN_EXISTING, LEX_ATTR_NORMAL, 0);
    if (h == LEX_INVALID_HANDLE) return 0;
    long long sz = 0; SetFilePointerEx(h, 0, &sz, 2 /*END*/); SetFilePointerEx(h, 0, 0, 0 /*BEGIN*/);
    char *buf = lex_alloc((size_t)sz + 1);
    LEX_DWORD off = 0;
    while ((long long)off < sz) {
        LEX_DWORD got = 0;
        if (!ReadFile(h, buf + off, (LEX_DWORD)(sz - off), &got, 0) || got == 0) break;
        off += got;
    }
    buf[off] = 0;
    CloseHandle(h);
    return buf;
}
static long long lex_fs_put(const char *path, const char *data, int append) {
    LEX_WCHAR w[1024]; lex_widen(path, w, 1024);
    LEX_HANDLE h = CreateFileW(w, LEX_GENERIC_WRITE, LEX_FILE_SHARE_RW, 0,
                               append ? LEX_OPEN_ALWAYS : LEX_CREATE_ALWAYS, LEX_ATTR_NORMAL, 0);
    if (h == LEX_INVALID_HANDLE) return -1;
    if (append) SetFilePointerEx(h, 0, 0, 2 /*END*/);
    size_t len = strlen(data), off = 0;
    while (off < len) {
        LEX_DWORD wrote = 0;
        if (!WriteFile(h, data + off, (LEX_DWORD)(len - off), &wrote, 0) || wrote == 0) { CloseHandle(h); return -1; }
        off += wrote;
    }
    CloseHandle(h);
    return (long long)len;
}
long long __lex_fs_write(const char *p, const char *d) { return lex_fs_put(p, d, 0); }
long long __lex_fs_append(const char *p, const char *d) { return lex_fs_put(p, d, 1); }
long long __lex_fs_exists(const char *p) {
    LEX_WCHAR w[1024]; lex_widen(p, w, 1024);
    return GetFileAttributesW(w) != LEX_INVALID_ATTRS ? 1 : 0;
}
long long __lex_fs_is_file(const char *p) {
    LEX_WCHAR w[1024]; lex_widen(p, w, 1024);
    LEX_DWORD a = GetFileAttributesW(w);
    return (a != LEX_INVALID_ATTRS && !(a & LEX_ATTR_DIRECTORY)) ? 1 : 0;
}
long long __lex_fs_is_dir(const char *p) {
    LEX_WCHAR w[1024]; lex_widen(p, w, 1024);
    LEX_DWORD a = GetFileAttributesW(w);
    return (a != LEX_INVALID_ATTRS && (a & LEX_ATTR_DIRECTORY)) ? 1 : 0;
}
long long __lex_fs_size(const char *p) {
    LEX_WCHAR w[1024]; lex_widen(p, w, 1024);
    unsigned char info[36]; // WIN32_FILE_ATTRIBUTE_DATA: size high@28, low@32
    if (!GetFileAttributesExW(w, 0, info)) return -1;
    unsigned hi, lo; memcpy(&hi, info + 28, 4); memcpy(&lo, info + 32, 4);
    return (long long)(((unsigned long long)hi << 32) | lo);
}
long long __lex_fs_remove(const char *p) {
    LEX_WCHAR w[1024]; lex_widen(p, w, 1024);
    return DeleteFileW(w) ? 0 : -1;
}
long long __lex_fs_rename(const char *a, const char *b) {
    LEX_WCHAR wa[1024], wb[1024]; lex_widen(a, wa, 1024); lex_widen(b, wb, 1024);
    return MoveFileExW(wa, wb, LEX_MOVE_REPLACE) ? 0 : -1;
}
long long __lex_fs_mkdir(const char *p) {
    LEX_WCHAR w[1024]; lex_widen(p, w, 1024);
    return CreateDirectoryW(w, 0) ? 0 : -1;
}
long long __lex_fs_rmdir(const char *p) {
    LEX_WCHAR w[1024]; lex_widen(p, w, 1024);
    return RemoveDirectoryW(w) ? 0 : -1;
}
LexArr *__lex_fs_list(const char *path) {
    LexArr *r = __lex_arr_new(8);
    // monta "<path>\*" em UTF-16
    LEX_WCHAR w[1024]; lex_widen(path, w, 1020);
    int wl = 0; while (w[wl]) wl++;
    if (wl && w[wl - 1] != '\\' && w[wl - 1] != '/') w[wl++] = '\\';
    w[wl++] = '*'; w[wl] = 0;
    unsigned char fd[592]; // WIN32_FIND_DATAW: cFileName (WCHAR[260]) no offset 44
    LEX_HANDLE h = FindFirstFileW(w, fd);
    if (h == LEX_INVALID_HANDLE) return r;
    do {
        const LEX_WCHAR *name = (const LEX_WCHAR *)(fd + 44);
        if (name[0] == '.' && (name[1] == 0 || (name[1] == '.' && name[2] == 0))) continue;
        char utf8[1024];
        int n = WideCharToMultiByte(LEX_CP_UTF8, 0, name, -1, utf8, sizeof(utf8), 0, 0);
        if (n > 0) __lex_arr_push(r, (long long)lex_strdup(utf8));
    } while (FindNextFileW(h, fd));
    FindClose(h);
    return r;
}
long long __lex_fs_open(const char *path, long long mode) {
    LEX_WCHAR w[1024]; lex_widen(path, w, 1024);
    LEX_HANDLE h;
    if (mode == 1)
        h = CreateFileW(w, LEX_GENERIC_WRITE, LEX_FILE_SHARE_RW, 0, LEX_CREATE_ALWAYS, LEX_ATTR_NORMAL, 0);
    else if (mode == 2) {
        h = CreateFileW(w, LEX_GENERIC_WRITE, LEX_FILE_SHARE_RW, 0, LEX_OPEN_ALWAYS, LEX_ATTR_NORMAL, 0);
        if (h != LEX_INVALID_HANDLE) SetFilePointerEx(h, 0, 0, 2 /*END*/);
    } else
        h = CreateFileW(w, LEX_GENERIC_READ, LEX_FILE_SHARE_RW, 0, LEX_OPEN_EXISTING, LEX_ATTR_NORMAL, 0);
    return h == LEX_INVALID_HANDLE ? -1 : (long long)(uintptr_t)h;
}

// --- libc pública por FFI (HANDLEs; fd 1/2 = stdout/stderr) -----------------
long long write(long long fd, const void *buf, long long n) {
    LEX_HANDLE h = (fd == 1) ? GetStdHandle(LEX_STD_OUTPUT)
                 : (fd == 2) ? GetStdHandle(LEX_STD_ERROR)
                             : (LEX_HANDLE)(uintptr_t)fd;
    LEX_DWORD wrote = 0;
    return WriteFile(h, buf, (LEX_DWORD)n, &wrote, 0) ? (long long)wrote : -1;
}
long long read(long long fd, void *buf, long long n) {
    LEX_HANDLE h = (fd == 0) ? GetStdHandle((LEX_DWORD)-10) : (LEX_HANDLE)(uintptr_t)fd;
    LEX_DWORD got = 0;
    return ReadFile(h, buf, (LEX_DWORD)n, &got, 0) ? (long long)got : -1;
}
long long close(long long fd) { return CloseHandle((LEX_HANDLE)(uintptr_t)fd) ? 0 : -1; }
long long lseek(long long fd, long long off, long long whence) {
    long long pos = 0;
    return SetFilePointerEx((LEX_HANDLE)(uintptr_t)fd, off, &pos, (LEX_DWORD)whence) ? pos : -1;
}
int usleep(long long us) { Sleep((LEX_DWORD)(us / 1000)); return 0; }

// --- ponto de entrada (sem CRT): lexWinStart -> main ------------------------
extern int main(void);
__declspec(dllexport) void lexWinStart(void) {
    unsigned char wsadata[512]; // WSADATA (~408 bytes) — habilita sockets (ws2_32)
    WSAStartup(0x0202, wsadata); // MAKEWORD(2,2); inócuo se o programa não usar rede
    lex_main_tid = (long)GetCurrentThreadId();
    int code = main();
    ExitProcess((unsigned)code);
}
#endif // LEX_WIN_FREESTANDING

// chamada pelo thunk do spawn quando a thread termina
void __lex_arena_free(void) {
#ifndef __wasm__
    while (lex_arena) {
        LexBlock *p = lex_arena->prev;
        free(lex_arena);
        lex_arena = p;
    }
#endif
    // no wasm (single-thread) a arena é única e vive até o fim do programa:
    // o spawn roda síncrono na mesma thread, então não se libera nada aqui.
}
