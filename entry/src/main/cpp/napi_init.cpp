// TukuRW native —— ArkTS 侧只用 fs.openSync(uri, READ_WRITE) 拿 fd，之后对该文件的
// 一切操作（stat/read/变换/write/ftruncate/fsync/校验）都在这里用 POSIX syscall 完成。
//
// 原理：媒体 URI 通路由媒体库 DataShare 扩展把【真实文件 fd】回传，所以
//       pread/pwrite/ftruncate/fsync 全部可用（裸路径 FUSE 上 ftruncate=ENOSYS/38）。
// 约定：所有函数第一个入参都是 ArkTS 传来的 fd(int)；返回一行/多行日志文本（错误抛 napi error）。
#include "napi/native_api.h"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

std::string ErrnoStr(int e)
{
    return std::string(strerror(e)) + "(" + std::to_string(e) + ")";
}

std::string Hex(uint32_t v)
{
    char buf[16];
    snprintf(buf, sizeof(buf), "%x", v);
    return std::string(buf);
}

std::string HexHead(const std::vector<uint8_t> &v, size_t n)
{
    static const char *d = "0123456789abcdef";
    std::string out;
    size_t lim = v.size() < n ? v.size() : n;
    for (size_t i = 0; i < lim; ++i) {
        out.push_back(d[(v[i] >> 4) & 0xF]);
        out.push_back(d[v[i] & 0xF]);
    }
    return out;
}

// 与 ArkTS 侧原实现一致：s = (s*31 + byte) mod 2^32
uint32_t Sum32(const std::vector<uint8_t> &v)
{
    uint32_t s = 0;
    for (uint8_t b : v) {
        s = s * 31u + b;
    }
    return s;
}

struct Args {
    std::vector<napi_value> vals;
    size_t count = 0;
};

bool GetArgs(napi_env env, napi_callback_info info, size_t maxArgs, Args *a)
{
    a->vals.resize(maxArgs);
    size_t argc = maxArgs;
    if (napi_get_cb_info(env, info, &argc, a->vals.data(), nullptr, nullptr) != napi_ok) {
        return false;
    }
    a->count = argc;
    return true;
}

std::string ArgStr(napi_env env, const Args &a, size_t i)
{
    if (i >= a.count || a.vals[i] == nullptr) {
        return {};
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, a.vals[i], nullptr, 0, &len) != napi_ok) {
        return {};
    }
    std::string s(len, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, a.vals[i], &s[0], len + 1, &copied) != napi_ok) {
        return {};
    }
    s.resize(copied);
    return s;
}

long long ArgNum(napi_env env, const Args &a, size_t i)
{
    if (i >= a.count || a.vals[i] == nullptr) {
        return 0;
    }
    double d = 0;
    if (napi_get_value_double(env, a.vals[i], &d) != napi_ok) {
        return 0;
    }
    return static_cast<long long>(d);
}

napi_value Str(napi_env env, const std::string &s)
{
    napi_value v = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

napi_value Fail(napi_env env, const std::string &msg)
{
    napi_throw_error(env, nullptr, msg.c_str());
    return nullptr;
}

// ---------------- fd / 文件基础操作 ----------------

bool PreadAll(int fd, std::vector<uint8_t> *buf, std::string *err)
{
    struct stat st;
    if (fstat(fd, &st) != 0) {
        *err = "fstat FAIL errno=" + ErrnoStr(errno);
        return false;
    }
    buf->assign(static_cast<size_t>(st.st_size), 0);
    size_t off = 0;
    while (off < buf->size()) {
        ssize_t n = pread(fd, buf->data() + off, buf->size() - off, static_cast<off_t>(off));
        if (n < 0) {
            *err = "pread FAIL off=" + std::to_string(off) + " errno=" + ErrnoStr(errno);
            return false;
        }
        if (n == 0) {
            break;
        }
        off += static_cast<size_t>(n);
    }
    buf->resize(off);
    return true;
}

bool PwriteAll(int fd, const uint8_t *data, size_t len, std::string *err)
{
    size_t off = 0;
    while (off < len) {
        ssize_t n = pwrite(fd, data + off, len - off, static_cast<off_t>(off));
        if (n <= 0) {
            *err = "pwrite FAIL off=" + std::to_string(off) + " errno=" + ErrnoStr(errno);
            return false;
        }
        off += static_cast<size_t>(n);
    }
    return true;
}

bool ReadFileAll(const std::string &path, std::vector<uint8_t> *buf, std::string *err)
{
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        *err = "open(" + path + ") FAIL errno=" + ErrnoStr(errno);
        return false;
    }
    bool ok = PreadAll(fd, buf, err);
    close(fd);
    return ok;
}

std::string SizeOf(int fd)  // 供日志复用的 fstat size
{
    struct stat st;
    if (fstat(fd, &st) != 0) {
        return "?";
    }
    return std::to_string(static_cast<long long>(st.st_size));
}

// ---------------- 导出给 ArkTS 的接口 ----------------

// fsStat(fd) -> "FSTAT size=… mode=… uid=… gid=…"
napi_value FsStat(napi_env env, napi_callback_info info)
{
    Args a;
    if (!GetArgs(env, info, 1, &a) || a.count < 1) {
        return Fail(env, "fsStat(fd)");
    }
    int fd = static_cast<int>(ArgNum(env, a, 0));
    struct stat st;
    if (fstat(fd, &st) != 0) {
        return Fail(env, "fstat FAIL errno=" + ErrnoStr(errno));
    }
    char mode[8];
    snprintf(mode, sizeof(mode), "%03o", static_cast<unsigned>(st.st_mode & 07777));
    return Str(env, "FSTAT size=" + std::to_string(static_cast<long long>(st.st_size)) + " mode=" + mode +
                        " uid=" + std::to_string(static_cast<long long>(st.st_uid)) +
                        " gid=" + std::to_string(static_cast<long long>(st.st_gid)));
}

// fsRead(fd) -> "READ n=… sum32=… head=…"
napi_value FsRead(napi_env env, napi_callback_info info)
{
    Args a;
    if (!GetArgs(env, info, 1, &a) || a.count < 1) {
        return Fail(env, "fsRead(fd)");
    }
    int fd = static_cast<int>(ArgNum(env, a, 0));
    std::vector<uint8_t> buf;
    std::string err;
    if (!PreadAll(fd, &buf, &err)) {
        return Fail(env, err);
    }
    return Str(env, "READ n=" + std::to_string(buf.size()) + " sum32=" + std::to_string(Sum32(buf)) +
                        " head=" + HexHead(buf, 8));
}

// fsBackup(fd, dstPath) -> "BACKUP ok path=… size=… sum32=… head=…"（读图库 fd → 写应用沙箱文件）
napi_value FsBackup(napi_env env, napi_callback_info info)
{
    Args a;
    if (!GetArgs(env, info, 2, &a) || a.count < 2) {
        return Fail(env, "fsBackup(fd, dstPath)");
    }
    int fd = static_cast<int>(ArgNum(env, a, 0));
    std::string dst = ArgStr(env, a, 1);
    std::vector<uint8_t> buf;
    std::string err;
    if (!PreadAll(fd, &buf, &err)) {
        return Fail(env, err);
    }
    int wfd = open(dst.c_str(), O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (wfd < 0) {
        return Fail(env, "open(" + dst + ") FAIL errno=" + ErrnoStr(errno));
    }
    bool ok = PwriteAll(wfd, buf.data(), buf.size(), &err);
    if (ok && fsync(wfd) != 0) {
        ok = false;
        err = "fsync(" + dst + ") FAIL errno=" + ErrnoStr(errno);
    }
    close(wfd);
    if (!ok) {
        return Fail(env, err);
    }
    return Str(env, "BACKUP ok path=" + dst + " size=" + std::to_string(buf.size()) +
                        " sum32=" + std::to_string(Sum32(buf)) + " head=" + HexHead(buf, 8));
}

// fsXor(fd, key) -> "XOR ok key=… size=… sum_before=… sum_after=… reread_sum=… VERIFY-OK|VERIFY-FAIL"
// 读全量 → 就地变换 → 写回原偏移 → fsync → 同 fd 复读校验（同一 fd 读写，避免只读打开的脱敏视图）
napi_value FsXor(napi_env env, napi_callback_info info)
{
    Args a;
    if (!GetArgs(env, info, 2, &a) || a.count < 2) {
        return Fail(env, "fsXor(fd, key)");
    }
    int fd = static_cast<int>(ArgNum(env, a, 0));
    uint8_t key = static_cast<uint8_t>(static_cast<unsigned>(ArgNum(env, a, 1)) & 0xFFu);
    std::vector<uint8_t> buf;
    std::string err;
    if (!PreadAll(fd, &buf, &err)) {
        return Fail(env, err);
    }
    uint32_t before = Sum32(buf);
    for (auto &b : buf) {
        b ^= key;
    }
    uint32_t after = Sum32(buf);
    if (!PwriteAll(fd, buf.data(), buf.size(), &err)) {
        return Fail(env, err);
    }
    if (fsync(fd) != 0) {
        return Fail(env, "fsync FAIL errno=" + ErrnoStr(errno));
    }
    std::vector<uint8_t> re;
    if (!PreadAll(fd, &re, &err)) {
        return Fail(env, err);
    }
    uint32_t reread = Sum32(re);
    return Str(env, "XOR ok key=0x" + Hex(key) + " size=" + std::to_string(buf.size()) +
                        " sum_before=0x" + Hex(before) + " sum_after=0x" + Hex(after) +
                        " reread_sum=0x" + Hex(reread) + (reread == after ? " VERIFY-OK" : " VERIFY-FAIL"));
}

// fsTruncateRewrite(fd, truncLen) -> 两行：尺寸缩到 truncLen 再改回原尺寸全量写回
// （证明 URI fd 上 ftruncate 可增可减；裸路径 FUSE 上这里是 ENOSYS/38）
napi_value FsTruncateRewrite(napi_env env, napi_callback_info info)
{
    Args a;
    if (!GetArgs(env, info, 2, &a) || a.count < 2) {
        return Fail(env, "fsTruncateRewrite(fd, truncLen)");
    }
    int fd = static_cast<int>(ArgNum(env, a, 0));
    long long truncLen = ArgNum(env, a, 1);
    std::vector<uint8_t> buf;
    std::string err;
    if (!PreadAll(fd, &buf, &err)) {
        return Fail(env, err);
    }
    size_t size = buf.size();
    uint32_t before = Sum32(buf);
    if (ftruncate(fd, static_cast<off_t>(truncLen)) != 0) {
        return Fail(env, "ftruncate(fd, " + std::to_string(truncLen) + ") FAIL errno=" + ErrnoStr(errno));
    }
    std::string out = "REWRITE truncate(fd, " + std::to_string(truncLen) + ") ok, size now=" + SizeOf(fd);
    if (ftruncate(fd, static_cast<off_t>(size)) != 0) {
        return Fail(env, "ftruncate(fd, " + std::to_string(size) + ") FAIL errno=" + ErrnoStr(errno));
    }
    if (!PwriteAll(fd, buf.data(), size, &err)) {
        return Fail(env, err);
    }
    if (fsync(fd) != 0) {
        return Fail(env, "fsync FAIL errno=" + ErrnoStr(errno));
    }
    std::vector<uint8_t> re;
    if (!PreadAll(fd, &re, &err)) {
        return Fail(env, err);
    }
    uint32_t after = Sum32(re);
    out += "\nREWRITE write back n=" + std::to_string(size) + " size after=" + SizeOf(fd) +
           " sum_before=0x" + Hex(before) + " sum_after=0x" + Hex(after) +
           (after == before && re.size() == size ? " CONTENT-IDENTICAL" : " CONTENT-DIFFERENT");
    return Str(env, out);
}

// fsRestore(fd, srcPath) -> "RESTORE ok from=… bytes=… size now=… backup_sum=… reread_sum=… VERIFY-OK|…"
napi_value FsRestore(napi_env env, napi_callback_info info)
{
    Args a;
    if (!GetArgs(env, info, 2, &a) || a.count < 2) {
        return Fail(env, "fsRestore(fd, srcPath)");
    }
    int fd = static_cast<int>(ArgNum(env, a, 0));
    std::string src = ArgStr(env, a, 1);
    std::vector<uint8_t> buf;
    std::string err;
    if (!ReadFileAll(src, &buf, &err)) {
        return Fail(env, err);
    }
    uint32_t srcSum = Sum32(buf);
    if (ftruncate(fd, static_cast<off_t>(buf.size())) != 0) {
        return Fail(env, "ftruncate(fd, " + std::to_string(buf.size()) + ") FAIL errno=" + ErrnoStr(errno));
    }
    if (!PwriteAll(fd, buf.data(), buf.size(), &err)) {
        return Fail(env, err);
    }
    if (fsync(fd) != 0) {
        return Fail(env, "fsync FAIL errno=" + ErrnoStr(errno));
    }
    std::vector<uint8_t> re;
    if (!PreadAll(fd, &re, &err)) {
        return Fail(env, err);
    }
    uint32_t rereadSum = Sum32(re);
    return Str(env, "RESTORE ok from=" + src + " bytes=" + std::to_string(buf.size()) +
                        " size now=" + SizeOf(fd) + " backup_sum=0x" + Hex(srcSum) +
                        " reread_sum=0x" + Hex(rereadSum) +
                        (rereadSum == srcSum && re.size() == buf.size() ? " VERIFY-OK" : " VERIFY-FAIL"));
}

// fsCompare(fd, srcPath) -> "FINAL backup_size=… cur_size=… backup_sum=… cur_sum=… BYTE-IDENTICAL-TO-BACKUP|…"
napi_value FsCompare(napi_env env, napi_callback_info info)
{
    Args a;
    if (!GetArgs(env, info, 2, &a) || a.count < 2) {
        return Fail(env, "fsCompare(fd, srcPath)");
    }
    int fd = static_cast<int>(ArgNum(env, a, 0));
    std::string src = ArgStr(env, a, 1);
    std::vector<uint8_t> bak;
    std::vector<uint8_t> cur;
    std::string err;
    if (!ReadFileAll(src, &bak, &err)) {
        return Fail(env, err);
    }
    if (!PreadAll(fd, &cur, &err)) {
        return Fail(env, err);
    }
    std::string out;
    bool same = bak.size() == cur.size();
    if (same) {
        for (size_t i = 0; i < bak.size(); ++i) {
            if (bak[i] != cur[i]) {
                same = false;
                out += "    首处差异 offset=" + std::to_string(i) + " backup=0x" + Hex(bak[i]) +
                       " cur=0x" + Hex(cur[i]) + "\n";
                break;
            }
        }
    }
    out += "FINAL backup_size=" + std::to_string(bak.size()) + " cur_size=" + std::to_string(cur.size()) +
           " backup_sum=0x" + Hex(Sum32(bak)) + " cur_sum=0x" + Hex(Sum32(cur)) +
           (same ? " BYTE-IDENTICAL-TO-BACKUP" : " DIFFERENT-FROM-BACKUP");
    return Str(env, out);
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "fsStat", nullptr, FsStat, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "fsRead", nullptr, FsRead, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "fsBackup", nullptr, FsBackup, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "fsXor", nullptr, FsXor, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "fsTruncateRewrite", nullptr, FsTruncateRewrite, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "fsRestore", nullptr, FsRestore, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "fsCompare", nullptr, FsCompare, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

} // namespace

static napi_module tukuRwModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterTukuRwModule(void)
{
    napi_module_register(&tukuRwModule);
}
