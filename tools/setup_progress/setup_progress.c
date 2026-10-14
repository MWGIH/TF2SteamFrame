/*
 * setup_progress.exe: shows a progress bar while the mod's asset_patcher.exe builds the game assets
 * on the first VR launch.
 *
 *   setup_progress.exe <log file> <asset_patcher.exe> [arguments...]
 *
 * asset_patcher.exe reports "progress <read bytes> <total bytes>" lines on its standard output,
 * which the Windows installer turns into its progress bar. Run directly under Proton, those lines
 * show up raw in a console window. This runs it with its output captured, draws a bar with a
 * percentage in its own console window instead, and writes every other line to the log file.
 * The exit code is asset_patcher.exe's.
 *
 * Build (CI checks lib/setup_progress.exe is exactly this):
 *   x86_64-w64-mingw32-gcc -O2 -s -municode -Wall -Wl,--no-insert-timestamp -o lib/setup_progress.exe tools/setup_progress/setup_progress.c
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define BAR_WIDTH 40

static HANDLE out;

static void say(const char *s)
{
    DWORD n;
    WriteFile(out, s, (DWORD)strlen(s), &n, NULL);
}

/* Append one argument to a command line, quoted the way CommandLineToArgvW reads it back */
static void append_arg(wchar_t *cmd, const wchar_t *arg)
{
    size_t len = wcslen(cmd);
    const wchar_t *p;
    if (len) cmd[len++] = L' ';
    cmd[len++] = L'"';
    for (p = arg;; p++) {
        unsigned slashes = 0;
        while (*p == L'\\') { p++; slashes++; }
        if (!*p) { while (slashes--) { cmd[len++] = L'\\'; cmd[len++] = L'\\'; } break; }
        if (*p == L'"') { slashes = slashes * 2 + 1; }
        while (slashes--) cmd[len++] = L'\\';
        cmd[len++] = *p;
    }
    cmd[len++] = L'"';
    cmd[len] = 0;
}

static void draw(double fraction, long long done, long long total)
{
    char line[160], bar[BAR_WIDTH + 1];
    int filled, i;
    if (fraction < 0) fraction = 0;
    if (fraction > 1) fraction = 1;
    filled = (int)(fraction * BAR_WIDTH + 0.5);
    for (i = 0; i < BAR_WIDTH; i++) bar[i] = i < filled ? '#' : '-';
    bar[BAR_WIDTH] = 0;
    if (total > 0)
        snprintf(line, sizeof line, "\r  [%s] %3d%%   %.2f of %.2f GB   ", bar, (int)(fraction * 100),
                 done / 1073741824.0, total / 1073741824.0);
    else
        snprintf(line, sizeof line, "\r  [%s] %3d%%   ", bar, (int)(fraction * 100));
    say(line);
}

int wmain(int argc, wchar_t **argv)
{
    SECURITY_ATTRIBUTES sa = { sizeof sa, NULL, TRUE };
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    HANDLE log, rd, wr;
    wchar_t *cmd;
    size_t size = 1;
    char buf[4096], line[1024];
    size_t used = 0;
    int last = -1, i;
    long long last_total = 0;
    DWORD n, w, code = 1;

    out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (argc < 3) {
        say("usage: setup_progress.exe <log file> <program> [arguments...]\r\n");
        return 2;
    }
    SetConsoleTitleW(L"Titanfall 2 VR setup");

    log = CreateFileW(argv[1], GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (log == INVALID_HANDLE_VALUE) log = NULL;

    for (i = 2; i < argc; i++) size += wcslen(argv[i]) * 2 + 3;
    cmd = calloc(size, sizeof *cmd);
    if (!cmd) return 1;
    for (i = 2; i < argc; i++) append_arg(cmd, argv[i]);

    if (!CreatePipe(&rd, &wr, &sa, 0)) return 1;
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);

    memset(&si, 0, sizeof si);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.hStdOutput = wr;
    si.hStdError = log ? log : wr;

    say("\r\n  Titanfall 2 VR: building the mod's game files.\r\n"
        "  This happens only on the first launch and takes a few minutes.\r\n"
        "  The game starts by itself when it's done.\r\n\r\n");
    draw(0, 0, 0);

    if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        snprintf(buf, sizeof buf, "\r\n\r\n  Couldn't start the asset builder (error %lu).\r\n", GetLastError());
        say(buf);
        if (log) WriteFile(log, buf, (DWORD)strlen(buf), &n, NULL);
        return 1;
    }
    CloseHandle(wr);

    while (ReadFile(rd, buf, sizeof buf, &n, NULL) && n) {
        DWORD k;
        for (k = 0; k < n; k++) {
            char c = buf[k];
            if (c != '\n' && used < sizeof line - 1) {
                if (c != '\r') line[used++] = c;
                continue;
            }
            line[used] = 0;
            used = 0;
            if (!strncmp(line, "progress ", 9)) {
                long long done = 0, total = 0;
                if (sscanf(line + 9, "%lld %lld", &done, &total) == 2 && total > 0) {
                    double f = (double)done / total;
                    int pct = (int)(f * 1000);
                    last_total = total;
                    if (pct != last) { last = pct; draw(f, done, total); }
                }
            } else if (log && line[0]) {
                WriteFile(log, line, (DWORD)strlen(line), &w, NULL);
                WriteFile(log, "\r\n", 2, &w, NULL);
            }
        }
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    if (code == 0) {
        if (last != 1000) draw(1, last_total, last_total);
        say("\r\n\r\n  Done. Starting Titanfall 2 VR...\r\n");
    } else {
        snprintf(buf, sizeof buf, "\r\n\r\n  Building the game files failed (exit code %lu).\r\n", code);
        say(buf);
    }
    if (log) {
        snprintf(buf, sizeof buf, "asset_patcher exit code %lu\r\n", code);
        WriteFile(log, buf, (DWORD)strlen(buf), &n, NULL);
        CloseHandle(log);
    }
    return (int)code;
}
