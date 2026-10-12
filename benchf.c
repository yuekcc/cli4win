// Process-startup microbenchmark (accurate variant).
// Uses CreateProcessW with flags=0 (like Python/CreateProcess defaults) and
// redirects the child's std handles to NUL, so per-launch cost is not inflated
// by CREATE_NO_WINDOW console setup.
//   bench.exe <iterations> <cwd> <exe> [args...]
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: bench <iters> <cwd> <exe> [args...]\n"); return 2; }
    int iters = atoi(argv[1]);
    const char *cwd = argv[2];

    wchar_t cmdW[4096]; cmdW[0] = 0;
    for (int i = 3; i < argc; i++) {
        if (i > 3) wcscat(cmdW, L" ");
        wchar_t w[1024]; MultiByteToWideChar(CP_ACP, 0, argv[i], -1, w, 1024);
        wcscat(cmdW, L"\""); wcscat(cmdW, w); wcscat(cmdW, L"\"");
    }
    wchar_t cwdW[1024]; MultiByteToWideChar(CP_ACP, 0, cwd, -1, cwdW, 1024);

    SECURITY_ATTRIBUTES sa = {sizeof(sa), NULL, TRUE};
    HANDLE nul = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);

    LARGE_INTEGER freq; QueryPerformanceFrequency(&freq);
    double *ts = malloc(sizeof(double) * iters);

    for (int i = -30; i < iters; i++) {
        STARTUPINFOW si; ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = si.hStdOutput = si.hStdError = nul;
        PROCESS_INFORMATION pi; ZeroMemory(&pi, sizeof(pi));
        LARGE_INTEGER a, b; QueryPerformanceCounter(&a);
        if (!CreateProcessW(NULL, cmdW, NULL, NULL, TRUE, 0, NULL, cwdW, &si, &pi)) {
            fprintf(stderr, "fail %lu\n", GetLastError()); return 3;
        }
        WaitForSingleObject(pi.hProcess, INFINITE);
        QueryPerformanceCounter(&b);
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        if (i >= 0) ts[i] = (double)(b.QuadPart - a.QuadPart) * 1000.0 / freq.QuadPart;
    }
    qsort(ts, iters, sizeof(double), cmp_double);
    double sum = 0; for (int i = 0; i < iters; i++) sum += ts[i];
    printf("min=%.3f p50=%.3f mean=%.3f p95=%.3f\n",
           ts[0], ts[iters/2], sum/iters, ts[(int)(0.95*(iters-1))]);
    return 0;
}
