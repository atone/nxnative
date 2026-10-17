// NSP extraction: nx_extract <prod.keys> <base NSP> <update NSP or -> <output dir> [base RomFS dir to compare against] [--manifest]
// Writes <output dir>/ExeFS and <output dir>/RomFS (the merged RomFS when there is an update); with a base RomFS dir, files whose content matches it become APFS clones (no new space).
// --manifest: the RomFS is not written, only a list <output dir>/romfs_manifest.tsv (path, size, first 32 bytes), for surveying a new game (a large game's RomFS is well over 10 GB).
// Add-on content: nx_extract <prod.keys> --aoc <DLC NSP> <output dir> writes the RomFS of the DLC's data NCA to <output dir> (the packing script puts it at aoc/<index>/, the host mounts it through DM_AOC_DIR).
// Title keys come from the common tickets (.tik) inside the NSPs, so only prod.keys is needed; key values are never printed.
// XCI (cartridge dumps) are accepted wherever an NSP is: the NCAs come from the secure partition. One XCI can hold the base game, an update and DLC together, and an update's NCAs carry the
// base game's title ID in their headers, so contents are told apart by the content meta (CNMT) records: base = Application, update = Patch (the highest version), DLC = AddOnContent.
// The same XCI may be given as base and update; --aoc takes an optional DLC title ID.
// nx_extract <prod.keys> --list <NSP or XCI> lists the content meta records: type, title ID, version (for the packing script and for checking a dump).
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using LibHac.Common;
using LibHac.Common.Keys;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Spl;
using LibHac.Tools.Fs;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using LibHac.Tools.FsSystem.RomFs;
using LibHac.Tools.Ncm;
using LibHac.Ncm;
using ContentType = LibHac.Ncm.ContentType;
using Path = System.IO.Path;

static class P {
    [DllImport("libc", SetLastError = true)] static extern int clonefile(string src, string dst, uint flags);

    static int Main(string[] a) {
        bool manifest = Array.IndexOf(a, "--manifest") >= 0; a = Array.FindAll(a, s => s != "--manifest");
        if (a.Length >= 3 && a[1] == "--list") return List(ExternalKeyReader.ReadKeyFile(a[0]), a[2]);
        if (a.Length < 4) { Console.Error.WriteLine("用法 | usage: nx_extract <prod.keys> <base.nsp|.xci> <update.nsp|.xci|-> <out dir> [base RomFS dir] [--manifest]\n       nx_extract <prod.keys> --aoc <dlc.nsp|.xci> <out dir> [DLC title ID]\n       nx_extract <prod.keys> --list <file.nsp|.xci>"); return 2; }
        KeySet ks = ExternalKeyReader.ReadKeyFile(a[0]);
        if (a[1] == "--aoc") return Aoc(ks, a[2], a[3], a.Length > 4 ? Convert.ToUInt64(a[4], 16) : 0);
        var basePkg = OpenPkg(ks, a[1]); var updPkg = a[2] == "-" ? null : a[2] == a[1] ? basePkg : OpenPkg(ks, a[2]);
        Content baseC = Best(basePkg, ContentMetaType.Application, 0) ?? throw new Exception("基础包里没有本体（Application）| no base game (Application) in the base package");
        Content updC = updPkg == null ? null : Best(updPkg, ContentMetaType.Patch, 0) ?? throw new Exception("更新包里没有更新（Patch）| no update (Patch) in the update package");
        Nca baseProg = baseC.Get(ContentType.Program) ?? throw new Exception("本体里没有程序 NCA | no Program NCA in the base game");
        Nca updProg = updC == null ? null : updC.Get(ContentType.Program) ?? throw new Exception("更新里没有程序 NCA | no Program NCA in the update");
        if (updC != null) Console.WriteLine($"更新版本号 | update version v{updC.Version}");
        Nca ctrl = (updC ?? baseC).Get(ContentType.Control);
        Console.WriteLine($"标题 | title {baseC.Id:x16}" + (updC != null ? $"，更新 | update {updC.Id:x16}" : ""));
        string outDir = a[3], cmpDir = a.Length > 4 ? a[4] : null;
        if (ctrl != null) {   // control data (NACP): display version and game name; a raw copy goes to <output dir>/control.nacp for naming the app
            byte[] nacp = Nacp(ctrl);
            Console.WriteLine($"显示版本 | display version {System.Text.Encoding.ASCII.GetString(nacp, 0x3060, 0x10).TrimEnd('\0')}");
            Console.WriteLine($"名称 | name {TitleName(nacp)}");
            Directory.CreateDirectory(outDir); File.WriteAllBytes(Path.Combine(outDir, "control.nacp"), nacp);
            var (icon, lang) = Icon(ctrl);   // the game icon for the app icon, saved as <output dir>/icon.jpg (build_ipa.sh picks it up)
            if (icon != null) { File.WriteAllBytes(Path.Combine(outDir, "icon.jpg"), icon); Console.WriteLine($"图标 | icon {lang}（{icon.Length} 字节 | bytes）"); }
            else Console.WriteLine("控制数据里没有图标 | no icon in the control data");
        }
        // Code section: the update's ExeFS is complete; opening it layered over the base gives the same result
        IFileSystem exefs = updProg != null ? baseProg.OpenFileSystemWithPatch(updProg, NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid) : baseProg.OpenFileSystem(NcaSectionType.Code, IntegrityCheckLevel.ErrorOnInvalid);
        Copy(exefs, Path.Combine(outDir, "ExeFS"), null);
        string[] mods = Directory.GetFiles(Path.Combine(outDir, "ExeFS")); Array.Sort(mods, StringComparer.Ordinal);
        foreach (string p in mods) {   // build ID of every NSO module (main, sdk, subsdk*, rtld...)
            if (new FileInfo(p).Length < 0x50) continue;
            byte[] h = new byte[0x50]; using (var f = File.OpenRead(p)) f.ReadExactly(h);
            if (h[0] == 'N' && h[1] == 'S' && h[2] == 'O' && h[3] == '0') Console.WriteLine($"{Path.GetFileName(p)} 构建号 | build id {Convert.ToHexString(h, 0x40, 16).ToLowerInvariant()}");
        }
        IStorage romfs = updProg != null ? baseProg.OpenStorageWithPatch(updProg, NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid) : baseProg.OpenStorage(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        if (manifest) Manifest(new RomFsFileSystem(romfs), Path.Combine(outDir, "romfs_manifest.tsv"));
        else Copy(new RomFsFileSystem(romfs), Path.Combine(outDir, "RomFS"), cmpDir);
        return 0;
    }

    // DLC NSP: one data NCA (content type PublicData / Data) + a meta NCA + the ticket; only the data NCA's RomFS is written. An XCI can hold several: give the title ID
    static int Aoc(KeySet ks, string nsp, string outDir, ulong want) {
        Content c = Best(OpenPkg(ks, nsp), ContentMetaType.AddOnContent, want) ?? throw new Exception("包里没有（这个标题号的）DLC | no DLC (with this title ID) in the package");
        Nca data = c.Get(ContentType.Data) ?? throw new Exception("DLC 里没有数据 NCA | no data NCA in the DLC");
        Console.WriteLine($"追加内容 | add-on content {data.Header.TitleId:x16}");
        Directory.CreateDirectory(outDir);
        Copy(new RomFsFileSystem(data.OpenStorage(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid)), outDir, null);
        return 0;
    }

    // One content meta record (CNMT): its type, title ID, version and NCAs by content type
    sealed class Content {
        public ContentMetaType Type; public ulong Id; public uint Version; public Dictionary<ContentType, Nca> Ncas = new();
        public Nca Get(ContentType t) => Ncas.TryGetValue(t, out Nca n) ? n : null;
    }
    // The record of that type (and title ID, when not 0) with the highest version: an XCI with an update keeps both versions of each DLC
    static Content Best(List<Content> l, ContentMetaType t, ulong id) { Content b = null; foreach (Content c in l) if (c.Type == t && (id == 0 || c.Id == id) && (b == null || c.Version > b.Version)) b = c; return b; }
    // Open an NSP (PFS0) or an XCI (its secure partition, HFS0), import the common tickets, read every content meta record and attach its NCAs (named <content ID>.nca)
    static List<Content> OpenPkg(KeySet ks, string path) {
        var storage = new LocalStorage(path, FileAccess.Read);
        IFileSystem pfs;
        byte[] magic = new byte[4]; storage.Read(0x100, magic).ThrowIfFailure();
        if (System.Text.Encoding.ASCII.GetString(magic) == "HEAD") {   // XCI: the card header's magic sits at 0x100
            var xci = new Xci(ks, storage);
            if (!xci.HasPartition(XciPartitionType.Secure)) throw new Exception("XCI 没有安全分区 | the XCI has no secure partition");
            pfs = xci.OpenPartition(XciPartitionType.Secure);
        } else { var p = new PartitionFileSystem(); p.Initialize(storage).ThrowIfFailure(); pfs = p; }
        var ncas = new Dictionary<string, Nca>(StringComparer.OrdinalIgnoreCase);
        foreach (DirectoryEntryEx e in pfs.EnumerateEntries("*", SearchOptions.Default)) {
            using var f = new UniqueRef<IFile>();
            pfs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            IStorage st = f.Release().AsStorage();
            if (e.Name.EndsWith(".tik", StringComparison.OrdinalIgnoreCase)) {
                byte[] t = new byte[0x2c0]; st.Read(0, t).ThrowIfFailure();
                if (t[0x281] != 0) { Console.Error.WriteLine($"【红】{e.Name} 不是通用票据，标题密钥要另给 | is not a common ticket; supply the title key separately"); continue; }
                ks.ExternalKeySet.Add(new RightsId(t.AsSpan(0x2a0, 0x10)), new AccessKey(t.AsSpan(0x180, 0x10))).ThrowIfFailure();
            } else if (e.Name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase)) ncas[e.Name.Substring(0, 32)] = new Nca(ks, st);
        }
        var list = new List<Content>();
        foreach (Nca meta in ncas.Values) {
            if (meta.Header.ContentType != NcaContentType.Meta) continue;
            IFileSystem mfs = meta.OpenFileSystem(0, IntegrityCheckLevel.ErrorOnInvalid);
            foreach (DirectoryEntryEx e in mfs.EnumerateEntries("*.cnmt", SearchOptions.Default)) {
                using var f = new UniqueRef<IFile>();
                mfs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
                var cnmt = new Cnmt(f.Release().AsStream());
                var c = new Content { Type = cnmt.Type, Id = cnmt.TitleId, Version = cnmt.TitleVersion.Version };
                foreach (CnmtContentEntry ce in cnmt.ContentEntries)
                    if (ncas.TryGetValue(Convert.ToHexString(ce.NcaId), out Nca n)) c.Ncas[ce.Type] = n;
                list.Add(c);
            }
        }
        return list;
    }
    // Contents of a package: one line per content meta record (type, title ID, version, display version of its control data, content types present)
    static int List(KeySet ks, string path) {
        foreach (Content c in OpenPkg(ks, path)) {
            Nca ctl = c.Get(ContentType.Control); string disp = "";
            if (ctl != null) try { disp = System.Text.Encoding.ASCII.GetString(Nacp(ctl), 0x3060, 0x10).TrimEnd('\0'); } catch (Exception) { disp = "?"; }
            Console.WriteLine($"{c.Type}\t{c.Id:x16}\tv{c.Version}\t{disp}\t{string.Join(",", c.Ncas.Keys)}");
        }
        return 0;
    }

    // Icon: the control data holds one 256x256 JPEG per language (/icon_<language>.dat). Use the English one (American, then British); if neither exists, take the first in NACP language order
    static readonly string[] IconLangs = { "AmericanEnglish", "BritishEnglish", "Japanese", "French", "German", "LatinAmericanSpanish", "Spanish", "Italian",
                                           "Dutch", "CanadianFrench", "Portuguese", "Russian", "Korean", "TraditionalChinese", "SimplifiedChinese", "BrazilianPortuguese" };
    static (byte[], string) Icon(Nca ctrl) {
        IFileSystem fs = ctrl.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        foreach (string lang in IconLangs) {
            using var f = new UniqueRef<IFile>();
            if (fs.OpenFile(ref f.Ref, $"/icon_{lang}.dat".ToU8Span(), OpenMode.Read).IsFailure()) continue;
            f.Get.GetSize(out long n).ThrowIfFailure();
            byte[] v = new byte[n]; f.Get.Read(out _, 0, v, ReadOption.None).ThrowIfFailure();
            return (v, lang);
        }
        return (null, null);
    }
    static byte[] Nacp(Nca ctrl) {   // the whole control.nacp (0x4000 bytes)
        IFileSystem fs = ctrl.OpenFileSystem(NcaSectionType.Data, IntegrityCheckLevel.ErrorOnInvalid);
        using var f = new UniqueRef<IFile>();
        fs.OpenFile(ref f.Ref, "/control.nacp".ToU8Span(), OpenMode.Read).ThrowIfFailure();
        f.Get.GetSize(out long n).ThrowIfFailure();
        byte[] v = new byte[n]; f.Get.Read(out _, 0, v, ReadOption.None).ThrowIfFailure();
        return v;
    }
    // Game name: the NACP starts with 16 language entries of 0x300 bytes each (name 0x200 + publisher 0x100); take the first non-empty one (0 = American English); DisplayVersion is at 0x3060
    //   NACPs from newer SDKs (such as Mario 1.2.1) compress these 0x3000 bytes: a u16 size + raw deflate, inflating to 32 languages × 0x300. LibHac 0.19 does not know this, so it is decoded here
    static string TitleName(byte[] nacp) {
        byte[] t = nacp; int n = nacp[0] | nacp[1] << 8;
        if (n > 0 && n <= 0x2ffe) try {
            using var z = new System.IO.Compression.DeflateStream(new MemoryStream(nacp, 2, n), System.IO.Compression.CompressionMode.Decompress);
            var m = new MemoryStream(); z.CopyTo(m);
            if (m.Length == 0x6000) t = m.ToArray();   // a wrong length means an uncompressed name that happened to inflate
        } catch (InvalidDataException) { }   // not compressed
        for (int i = 0; i < (t == nacp ? 16 : 32); i++) {
            int z = Array.IndexOf(t, (byte)0, i * 0x300, 0x200), len = (z < 0 ? i * 0x300 + 0x200 : z) - i * 0x300;
            if (len > 0) return System.Text.Encoding.UTF8.GetString(t, i * 0x300, len);
        }
        return "";
    }

    // Copy out file by file; files identical to the same path in the compare dir become APFS clones instead
    static void Copy(IFileSystem fs, string dst, string cmpDir) {
        long n = 0, cloned = 0, bytes = 0, written = 0; byte[] buf = new byte[4 << 20], cb = new byte[4 << 20];
        foreach (DirectoryEntryEx e in fs.EnumerateEntries("*", SearchOptions.RecurseSubdirectories)) {
            string rel = e.FullPath.TrimStart('/'), op = Path.Combine(dst, rel);
            if (e.Type == DirectoryEntryType.Directory) { Directory.CreateDirectory(op); continue; }
            Directory.CreateDirectory(Path.GetDirectoryName(op)); n++; bytes += e.Size;
            using var f = new UniqueRef<IFile>();
            fs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            string cp = cmpDir == null ? null : Path.Combine(cmpDir, rel);
            if (cp != null && File.Exists(cp) && new FileInfo(cp).Length == e.Size && Same(f.Get, cp, e.Size, buf, cb)) {
                if (File.Exists(op)) File.Delete(op);
                if (clonefile(cp, op, 0) != 0) throw new IOException($"clonefile {cp} → {op} 失败 | failed: errno {Marshal.GetLastWin32Error()}");
                cloned++; continue;
            }
            using var o = File.Create(op);
            for (long off = 0; off < e.Size;) {
                f.Get.Read(out long got, off, buf.AsSpan(0, (int)Math.Min(buf.Length, e.Size - off)), ReadOption.None).ThrowIfFailure();
                if (got <= 0) throw new IOException($"读不出 | cannot read {e.FullPath} @{off}");
                o.Write(buf, 0, (int)got); off += got;
            }
            written += e.Size;
        }
        Console.WriteLine($"{dst}：{n} 个文件 {bytes / 1048576.0:F1} MB，其中 {cloned} 个与比对目录相同（克隆），新写 {written / 1048576.0:F1} MB | {n} files {bytes / 1048576.0:F1} MB, {cloned} identical to the compare dir (cloned), {written / 1048576.0:F1} MB newly written");
    }
    // List the RomFS only (path, size, first 32 bytes) without writing game files
    static void Manifest(IFileSystem fs, string path) {
        long n = 0, bytes = 0; byte[] h = new byte[32];
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        using var o = new StreamWriter(path);
        o.WriteLine("# 路径\t字节\t头 32 字节（十六进制） | path\tbytes\tfirst 32 bytes (hex)");
        foreach (DirectoryEntryEx e in fs.EnumerateEntries("*", SearchOptions.RecurseSubdirectories)) {
            if (e.Type == DirectoryEntryType.Directory) continue;
            using var f = new UniqueRef<IFile>();
            fs.OpenFile(ref f.Ref, e.FullPath.ToU8Span(), OpenMode.Read).ThrowIfFailure();
            long got = 0; int want = (int)Math.Min(h.Length, e.Size);
            if (want > 0) f.Get.Read(out got, 0, h.AsSpan(0, want), ReadOption.None).ThrowIfFailure();
            o.WriteLine($"{e.FullPath}\t{e.Size}\t{Convert.ToHexString(h, 0, (int)got).ToLowerInvariant()}");
            n++; bytes += e.Size;
        }
        Console.WriteLine($"{path}：RomFS {n} 个文件 {bytes / 1048576.0:F1} MB（只列清单）| RomFS {n} files {bytes / 1048576.0:F1} MB (manifest only)");
    }
    static bool Same(IFile f, string path, long size, byte[] buf, byte[] cb) {
        using var c = File.OpenRead(path);
        for (long off = 0; off < size;) {
            int want = (int)Math.Min(buf.Length, size - off);
            f.Read(out long got, off, buf.AsSpan(0, want), ReadOption.None).ThrowIfFailure();
            c.ReadExactly(cb, 0, (int)got);
            if (!buf.AsSpan(0, (int)got).SequenceEqual(cb.AsSpan(0, (int)got))) return false;
            off += got;
        }
        return true;
    }
}
