#!/usr/bin/env python3
# Vulkan games' SPIR-V shaders → one Metal library + a resource table for the host's Vulkan layer (dm/gfx/vk/hle_vk.m). Hades ships its 74 shaders as SPIR-V files
# (RomFS Content/EffectsForgeSwitch/*.vert / *.frag); the game hands the same words to vkCreateShaderModule, so a shader is found again by the hash of its SPIR-V.
# Per shader:
#   · key = sha256(SPIR-V words)[:16] (hex); the Metal function is vk_<key>
#   · its descriptor bindings are renumbered per kind (uniform / storage buffers → [[buffer(n)]], images → [[texture(n)]], samplers → [[sampler(n)]], n from 0 in binding order)
#     by rewriting the Binding decorations in a copy of the SPIR-V, then translated with spirv-cross --msl-decoration-binding: the slots stay below Metal's limits whatever the
#     game's set / binding numbers are (Hades uses set 1 bindings up to 49), and the table records which (set, binding) each slot came from
#   · vertex shaders get --flip-vert-y: Vulkan's clip space has y pointing down, Metal's up, and the viewports stay as the game gives them
#   · vertex buffers are bound by the host from slot 30 downwards (30 - Vulkan binding), above every shader's buffer slots
#   · only resources the translated entry point takes are listed (a declared but unused one has no Metal slot to bind)
# Output: <out>/vk/vk_shaders.metallib and <out>/vk/vk_shaders.tsv; --ios <dir> also writes <dir>/vk/ with an iPhone library (same table)
# Table rows: key <TAB> stage (vert / frag) <TAB> resources, space-separated kind:set.binding=slot (u uniform buffer, b storage buffer, t image, s sampler, c combined image sampler = texture and sampler slot n)
# Usage: vk_shaders.py <RomFS dir> <out dir> [--ios <dir>]
import concurrent.futures as cf, hashlib, json, os, re, struct, subprocess, sys, tempfile

MAGIC = 0x07230203
OP_DECORATE, DEC_BINDING, DEC_SET = 71, 33, 34
KINDS = {'ubos': 'u', 'ssbos': 'b', 'separate_images': 't', 'images': 't', 'separate_samplers': 's', 'textures': 'c'}
SLOT_CLASS = {'u': 'buffer', 'b': 'buffer', 't': 'texture', 's': 'sampler', 'c': 'texture'}

def red(msg): sys.exit('【红】' + msg)

def spirv_files(root):
    for d, _, fs in os.walk(root):
        for f in sorted(fs):
            p = os.path.join(d, f)
            with open(p, 'rb') as fh: head = fh.read(4)
            if len(head) == 4 and struct.unpack('<I', head)[0] == MAGIC: yield p

def decorations(words):
    """variable id → {'set': n, 'binding': n, 'binding_at': word index of the binding value}"""
    out, i = {}, 5
    while i < len(words):
        op, n = words[i] & 0xffff, words[i] >> 16
        if n == 0: red('SPIR-V 指令长度为 0')
        if op == OP_DECORATE and n >= 4:
            v = out.setdefault(words[i + 1], {})
            if words[i + 2] == DEC_BINDING: v['binding'], v['binding_at'] = words[i + 3], i + 3
            elif words[i + 2] == DEC_SET: v['set'] = words[i + 3]
        i += n
    return out

def one(path, tmp, root):
    data = open(path, 'rb').read()
    if len(data) % 4: red(f'{path}：SPIR-V 长度 {len(data)} 不是 4 的倍数')
    key = hashlib.sha256(data).hexdigest()[:16]
    refl = json.loads(subprocess.run(['spirv-cross', path, '--reflect'], capture_output=True, text=True, check=True).stdout)
    eps = refl.get('entryPoints', [])
    if len(eps) != 1 or eps[0]['mode'] not in ('vert', 'frag'): red(f'{path}：入口 {eps} 不是单个顶点 / 像素着色器')
    stage = eps[0]['mode']
    words = list(struct.unpack(f'<{len(data) // 4}I', data))
    dec = decorations(words)
    by_pair = {}
    for k, kind in KINDS.items():
        for r in refl.get(k, []): by_pair[(r.get('set', 0), r['binding'])] = kind
    if refl.get('push_constants'): red(f'{path}：用了 push constant，宿主的 Vulkan 层还没有')
    slots, nxt, res = {}, {'buffer': 0, 'texture': 0, 'sampler': 0}, []
    for vid, d in sorted(dec.items(), key=lambda t: (t[1].get('set', 0), t[1].get('binding', 0))):
        if 'binding_at' not in d: continue
        pair = (d.get('set', 0), d['binding'])
        kind = by_pair.get(pair)
        if not kind: continue   # declared but unused: spirv-cross drops it
        if pair in slots: n = slots[pair]
        else:
            cls = SLOT_CLASS[kind]; n = nxt[cls]; nxt[cls] += 1
            if kind == 'c': nxt['sampler'] = max(nxt['sampler'], n + 1)
            slots[pair] = n; res.append(f'{kind}:{pair[0]}.{pair[1]}={n}')
        words[d['binding_at']] = n
    if nxt['buffer'] > 16 or nxt['texture'] > 31 or nxt['sampler'] > 16: red(f'{path}：资源槽超出 {nxt}')
    spv = os.path.join(tmp, key + '.spv'); msl = os.path.join(tmp, key + '.metal')
    open(spv, 'wb').write(struct.pack(f'<{len(words)}I', *words))
    cmd = ['spirv-cross', spv, '--msl', '--msl-version', '20300', '--msl-decoration-binding', '--rename-entry-point', 'main', f'vk_{key}', stage, '--output', msl]
    if stage == 'vert': cmd.append('--flip-vert-y')
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode: red(f'{path}：spirv-cross 失败：{r.stderr.strip()[:300]}')
    # The reflection lists every declared resource; the Metal entry point only takes the ones the shader uses (Hades' ShadowMap.frag declares a buffer it never reads,
    # which the game's own pipeline layout leaves out): keep the rows whose slot is an argument of the entry point, so the host only binds, and only reports, real ones
    src = open(msl).read(); m = re.search(r'\bvk_' + key + r'\((.*?)\)\s*\{', src, re.S)
    if not m: red(f'{path}：译出的 MSL 里找不到入口 vk_{key}')
    used = {(c, int(n)) for c, n in re.findall(r'\[\[(buffer|texture|sampler)\((\d+)\)\]\]', m.group(1))}
    res = [x for x in res if (SLOT_CLASS[x[0]], int(x.rsplit('=', 1)[1])) in used]
    return key, stage, res, msl, '/' + os.path.relpath(path, root)

def metallib(msls, out, sdk, extra):
    os.makedirs(out, exist_ok=True)
    airs = []
    def comp(m):
        a = m[:-6] + f'.{sdk}.air'
        r = subprocess.run(['xcrun', '-sdk', sdk, 'metal', '-c', '-fpreserve-invariance', *extra, m, '-o', a], capture_output=True, text=True)
        if r.returncode: red(f'{m}：metal 编译失败：{r.stderr.strip()[:400]}')
        return a
    with cf.ThreadPoolExecutor(os.cpu_count()) as ex: airs = list(ex.map(comp, msls))
    lib = os.path.join(out, 'vk_shaders.metallib')
    subprocess.run(['xcrun', '-sdk', sdk, 'metallib', *airs, '-o', lib], check=True)
    return lib

def main():
    a = sys.argv[1:]
    ios = None
    if '--ios' in a: i = a.index('--ios'); ios = a[i + 1]; del a[i:i + 2]
    if len(a) != 2: sys.exit('用法 | usage: vk_shaders.py <RomFS dir> <out dir> [--ios <dir>]')
    root, out = a
    files = list(spirv_files(root))
    if not files: red(f'{root} 里没有 SPIR-V 文件')
    with tempfile.TemporaryDirectory() as tmp:
        with cf.ThreadPoolExecutor(os.cpu_count()) as ex: rows = list(ex.map(lambda p: one(p, tmp, root), files))
        seen = {}
        for key, stage, res, msl, src in rows:
            if key in seen: continue
            seen[key] = (stage, res, msl, src)
        msls = [v[2] for v in seen.values()]
        tsv = ['# Vulkan shaders (dm/gfx/tools/vk_shaders.py): key = sha256(SPIR-V)[:16], Metal function vk_<key>; resources kind:set.binding=slot (u uniform buffer, b storage buffer, t image, s sampler, c combined)',
               '# spirv-cross ' + ' '.join((lambda r: r.stdout + r.stderr)(subprocess.run(['spirv-cross', '--revision'], capture_output=True, text=True)).split())]
        tsv += [f'{k}\t{v[0]}\t{" ".join(v[1])}\t{v[3]}' for k, v in sorted(seen.items())]
        dirs = [(os.path.join(out, 'vk'), 'macosx', [])]
        if ios: dirs.append((os.path.join(ios, 'vk'), 'iphoneos', ['-mios-version-min=18.0']))
        for d, sdk, extra in dirs:
            lib = metallib(msls, d, sdk, extra)
            open(os.path.join(d, 'vk_shaders.tsv'), 'w').write('\n'.join(tsv) + '\n')
            print(f'{sdk}: {len(seen)} 个着色器 | shaders → {lib}')

if __name__ == '__main__': main()
