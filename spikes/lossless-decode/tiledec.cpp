// Argent spike, lossless-decode. Measurement prototype, not shipped code.
//
// tiledec is a from-spec, tile-parallel decoder for the lossless-JPEG raw stream in
// Sony lossless-compressed L files, written from ITU-T T.81 (the lossless process,
// SOF3, Annex H) and the TIFF 6.0 tag layout. It contains no code from LibRaw or
// dcraw; LibRaw's unpacked buffer is only the reference that --compare checks against.
// It handles the single-sample Bayer L stream, refuses the YCbCr M and S streams, has
// an unexercised restart-interval path, and is not hardened against bad input.
// README.md in this folder has the build, the runs and the measured numbers.
//
// Build: clang++ -O3 -std=c++17 tiledec.cpp -o tiledec

// tiledec: from-spec decoder for the tiled lossless-JPEG raw stream in Sony
// lossless-compressed ARW (Bayer, "L" size). Written from ITU-T T.81 (lossless
// process, SOF3, Annex H) and the TIFF 6.0 tag layout, not from any decoder's source.
//
// Each tile is an independent LJPEG stream, so the tiles are decoded on a pool of
// T threads into one raw_width x raw_height uint16 buffer. This measures whether
// intra-frame parallelism can get one frame's decompression under the 150 ms budget.
//
// usage: tiledec <file.arw> [--threads T] [--iters N] [--warmup N]
//                [--compare libraw_dump.raw] [--out out.raw]
//
// Output: one "ITER" line per timed iteration and a "SUMMARY" JSON line.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static double now_ms()
{
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

// ---------------------------------------------------------------- TIFF walk

struct RawIfd
{
  uint32_t width = 0, height = 0, tile_w = 0, tile_h = 0;
  uint32_t compression = 0, samples = 0, bps = 0, photometric = 0;
  std::vector<uint32_t> tile_offsets, tile_counts;
};

struct TiffReader
{
  const uint8_t *d; size_t n; bool le;
  uint16_t u16(size_t o) const { return le ? (uint16_t)(d[o] | d[o + 1] << 8) : (uint16_t)(d[o] << 8 | d[o + 1]); }
  uint32_t u32(size_t o) const { return le ? (uint32_t)d[o] | (uint32_t)d[o + 1] << 8 | (uint32_t)d[o + 2] << 16 | (uint32_t)d[o + 3] << 24
                                           : (uint32_t)d[o] << 24 | (uint32_t)d[o + 1] << 16 | (uint32_t)d[o + 2] << 8 | (uint32_t)d[o + 3]; }
  static size_t type_size(uint16_t t) { switch (t) { case 1: case 2: case 6: case 7: return 1; case 3: case 8: return 2; case 4: case 9: case 11: case 13: return 4; case 5: case 10: case 12: return 8; default: return 1; } }

  // Returns the array of integer values for a tag entry at offset e.
  std::vector<uint32_t> values(size_t e) const
  {
    uint16_t type = u16(e + 2); uint32_t count = u32(e + 4);
    size_t sz = type_size(type) * (size_t)count;
    size_t data = sz <= 4 ? e + 8 : u32(e + 8);
    std::vector<uint32_t> v;
    if (data + sz > n || count > (1u << 24)) return v;
    v.reserve(count);
    for (uint32_t i = 0; i < count; i++)
    {
      if (type == 3) v.push_back(u16(data + 2 * i));
      else if (type == 4 || type == 13) v.push_back(u32(data + 4 * i));
      else if (type == 1) v.push_back(d[data + i]);
      else break;
    }
    return v;
  }

  // Walks one IFD; fills r if it is a tiled raw IFD; recurses into SubIFDs. Returns next IFD offset.
  uint32_t walk(uint32_t off, RawIfd &r, int depth) const
  {
    if (off + 2 > n || depth > 4) return 0;
    uint16_t cnt = u16(off);
    RawIfd cand; std::vector<uint32_t> subs;
    for (uint16_t i = 0; i < cnt; i++)
    {
      size_t e = off + 2 + 12 * (size_t)i;
      if (e + 12 > n) break;
      uint16_t tag = u16(e);
      switch (tag)
      {
      case 0x100: { auto v = values(e); if (!v.empty()) cand.width = v[0]; break; }
      case 0x101: { auto v = values(e); if (!v.empty()) cand.height = v[0]; break; }
      case 0x102: { auto v = values(e); if (!v.empty()) cand.bps = v[0]; break; }
      case 0x103: { auto v = values(e); if (!v.empty()) cand.compression = v[0]; break; }
      case 0x106: { auto v = values(e); if (!v.empty()) cand.photometric = v[0]; break; }
      case 0x115: { auto v = values(e); if (!v.empty()) cand.samples = v[0]; break; }
      case 0x142: { auto v = values(e); if (!v.empty()) cand.tile_w = v[0]; break; }
      case 0x143: { auto v = values(e); if (!v.empty()) cand.tile_h = v[0]; break; }
      case 0x144: cand.tile_offsets = values(e); break;
      case 0x145: cand.tile_counts = values(e); break;
      case 0x14a: subs = values(e); break;
      default: break;
      }
    }
    if (cand.compression == 7 && !cand.tile_offsets.empty() && r.tile_offsets.empty()) r = cand;
    for (uint32_t s : subs) walk(s, r, depth + 1);
    size_t nx = off + 2 + 12 * (size_t)cnt;
    return nx + 4 <= n ? u32(nx) : 0;
  }
};

// ---------------------------------------------------------------- LJPEG tile

struct Huff
{
  // 16-bit lookahead: len[code16] = code length (0 = invalid), sym[code16] = SSSS.
  std::vector<uint8_t> len, sym;
  bool built = false;
  void build(const uint8_t *bits /*16*/, const uint8_t *vals, int nvals)
  {
    len.assign(65536, 0); sym.assign(65536, 0);
    uint32_t code = 0; int k = 0;
    for (int L = 1; L <= 16; L++)
    {
      for (int i = 0; i < bits[L - 1]; i++)
      {
        if (k >= nvals) break;
        uint32_t lo = code << (16 - L), hi = (code + 1) << (16 - L);
        if (hi > 65536) hi = 65536;
        for (uint32_t c = lo; c < hi; c++) { len[c] = (uint8_t)L; sym[c] = vals[k]; }
        code++; k++;
      }
      code <<= 1;
    }
    built = true;
  }
};

struct BitReader
{
  const uint8_t *p, *end;
  uint64_t buf = 0; int nbits = 0; bool marker = false;
  BitReader(const uint8_t *a, const uint8_t *b) : p(a), end(b) {}
  inline void refill()
  {
    while (nbits <= 56)
    {
      uint32_t b = 0;
      if (!marker && p < end)
      {
        b = *p;
        if (b == 0xFF)
        {
          uint32_t nx = p + 1 < end ? p[1] : 0xD9;
          if (nx == 0x00) p += 2;          // stuffed 0xFF data byte
          else { marker = true; b = 0; }   // a marker: feed zeros from here on
        }
        else p++;
      }
      buf |= (uint64_t)b << (56 - nbits);
      nbits += 8;
    }
  }
  inline uint32_t peek(int n) { return (uint32_t)(buf >> (64 - n)); }
  inline void consume(int n) { buf <<= n; nbits -= n; }
  // Byte-align and skip an RSTn marker, for restart intervals.
  void restart()
  {
    buf = 0; nbits = 0; marker = false;
    while (p + 1 < end && !(p[0] == 0xFF && p[1] >= 0xD0 && p[1] <= 0xD7)) p++;
    if (p + 1 < end) p += 2;
  }
};

struct TileInfo
{
  int precision = 0, lines = 0, samples_per_line = 0, ncomp = 0;
  int predictor = 0, pt = 0, restart_interval = 0;
  int ntables = 0;
  bool ok = false; const char *error = "";
};

// Decodes one LJPEG tile whose bytes are [s, s+n) into out, a raw buffer of pitch
// 'pitch' uint16, at raw origin (ox, oy). For ncomp == 4 the four components of an
// MCU form the 2x2 Bayer quad (c0 top-left, c1 top-right, c2 bottom-left, c3 bottom-right).
static TileInfo decode_tile(const uint8_t *s, size_t n, uint16_t *out, size_t pitch, int ox, int oy, int clip_w, int clip_h)
{
  TileInfo ti;
  Huff tables[4];
  int comp_table[4] = {0, 0, 0, 0};
  size_t i = 0;
  if (n < 4 || s[0] != 0xFF || s[1] != 0xD8) { ti.error = "no SOI"; return ti; }
  i = 2;
  const uint8_t *scan = nullptr;
  while (i + 4 <= n)
  {
    if (s[i] != 0xFF) { i++; continue; }
    uint8_t m = s[i + 1];
    if (m == 0xFF) { i++; continue; }
    if (m == 0xD9) break;
    uint32_t L = (uint32_t)(s[i + 2] << 8 | s[i + 3]);
    if (i + 2 + L > n) { ti.error = "segment overruns tile"; return ti; }
    const uint8_t *seg = s + i + 4; uint32_t len = L - 2;
    if (m == 0xC4) // DHT
    {
      uint32_t k = 0;
      while (k + 17 <= len)
      {
        int tc = seg[k] >> 4, th = seg[k] & 15; (void)tc;
        const uint8_t *bits = seg + k + 1; int nv = 0;
        for (int b = 0; b < 16; b++) nv += bits[b];
        if (k + 17 + nv > len || th > 3) { ti.error = "bad DHT"; return ti; }
        tables[th].build(bits, seg + k + 17, nv); ti.ntables++;
        k += 17 + nv;
      }
    }
    else if (m == 0xC3) // SOF3, lossless
    {
      ti.precision = seg[0]; ti.lines = seg[1] << 8 | seg[2]; ti.samples_per_line = seg[3] << 8 | seg[4]; ti.ncomp = seg[5];
      if (ti.ncomp < 1 || ti.ncomp > 4) { ti.error = "unsupported component count"; return ti; }
      for (int c = 0; c < ti.ncomp; c++)
      {
        int hv = seg[6 + 3 * c + 1];
        if (hv != 0x11) { ti.error = "subsampled components unsupported"; return ti; }
      }
    }
    else if (m == 0xDD) // DRI
    {
      ti.restart_interval = seg[0] << 8 | seg[1];
    }
    else if (m == 0xDA) // SOS
    {
      int ns = seg[0];
      if (ns != ti.ncomp) { ti.error = "non-interleaved scans unsupported"; return ti; }
      for (int c = 0; c < ns; c++) comp_table[c] = seg[1 + 2 * c + 1] >> 4;
      ti.predictor = seg[1 + 2 * ns];
      ti.pt = seg[1 + 2 * ns + 2] & 15;
      scan = seg + len;
      break;
    }
    else if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) { ti.error = "not a lossless SOF"; return ti; }
    i += 2 + L;
  }
  if (!scan || ti.ncomp == 0) { ti.error = "no SOS/SOF"; return ti; }
  for (int c = 0; c < ti.ncomp; c++) if (!tables[comp_table[c]].built) { ti.error = "missing Huffman table"; return ti; }
  if (ti.predictor < 1 || ti.predictor > 7) { ti.error = "bad predictor"; return ti; }

  const int X = ti.samples_per_line, Y = ti.lines, N = ti.ncomp;
  const int init = 1 << (ti.precision - ti.pt - 1);
  // Component plane geometry in the raw buffer: for N == 4 each component is a
  // 2x2 sub-lattice, so neighbours in the plane are 2 raw pixels apart.
  const int sx = (N == 4) ? 2 : (N == 2 ? 2 : 1), sy = (N == 4) ? 2 : 1;
  std::vector<uint16_t> rowbuf; // only used when the tile would overrun the raw buffer
  BitReader br(scan, s + n);
  int mcus_since_restart = 0; bool first_line = true;
  for (int y = 0; y < Y; y++)
  {
    for (int x = 0; x < X; x++)
    {
      if (ti.restart_interval && mcus_since_restart == ti.restart_interval)
      {
        br.restart(); mcus_since_restart = 0; first_line = true; // T.81 H.2.3 style: new interval predicts as a first line
      }
      for (int c = 0; c < N; c++)
      {
        const Huff &h = tables[comp_table[c]];
        br.refill();
        uint32_t idx = br.peek(16);
        int L = h.len[idx];
        if (!L) { ti.error = "invalid Huffman code"; return ti; }
        int ssss = h.sym[idx];
        br.consume(L);
        int diff;
        if (ssss == 0) diff = 0;
        else if (ssss == 16) diff = 32768;
        else
        {
          uint32_t v = br.peek(ssss); br.consume(ssss);
          diff = (int)v;
          if (v < (1u << (ssss - 1))) diff -= (1 << ssss) - 1;
        }
        // Raw position of this sample.
        int rx = ox + x * sx + (N == 4 ? (c & 1) : (N == 2 ? c : 0));
        int ry = oy + y * sy + (N == 4 ? (c >> 1) : 0);
        uint16_t *cur = out + (size_t)ry * pitch + rx;
        int pred;
        if (first_line) pred = (x == 0) ? init : cur[-sx];
        else if (x == 0) pred = cur[-(ptrdiff_t)sy * (ptrdiff_t)pitch];
        else
        {
          int Ra = cur[-sx], Rb = cur[-(ptrdiff_t)sy * (ptrdiff_t)pitch], Rc = cur[-(ptrdiff_t)sy * (ptrdiff_t)pitch - sx];
          switch (ti.predictor)
          {
          case 1: pred = Ra; break;
          case 2: pred = Rb; break;
          case 3: pred = Rc; break;
          case 4: pred = Ra + Rb - Rc; break;
          case 5: pred = Ra + ((Rb - Rc) >> 1); break;
          case 6: pred = Rb + ((Ra - Rc) >> 1); break;
          default: pred = (Ra + Rb) >> 1; break;
          }
        }
        *cur = (uint16_t)((pred + diff) & 0xFFFF);
      }
      mcus_since_restart++;
    }
    first_line = false;
  }
  if (ti.pt)
  {
    int tw = X * sx, th = Y * sy;
    for (int ry = 0; ry < th; ry++) for (int rx = 0; rx < tw; rx++) out[(size_t)(oy + ry) * pitch + ox + rx] <<= ti.pt;
  }
  (void)clip_w; (void)clip_h;
  ti.ok = true;
  return ti;
}

// ---------------------------------------------------------------- main

int main(int argc, char **argv)
{
  if (argc < 2) { fprintf(stderr, "usage: tiledec <file.arw> [--threads T] [--iters N] [--warmup N] [--compare dump.raw] [--out out.raw]\n"); return 2; }
  const char *path = argv[1];
  int threads = (int)std::thread::hardware_concurrency(), iters = 5, warmup = 1;
  std::string compare, outpath;
  for (int a = 2; a < argc; a++)
  {
    std::string s = argv[a];
    if (s == "--threads" && a + 1 < argc) threads = atoi(argv[++a]);
    else if (s == "--iters" && a + 1 < argc) iters = atoi(argv[++a]);
    else if (s == "--warmup" && a + 1 < argc) warmup = atoi(argv[++a]);
    else if (s == "--compare" && a + 1 < argc) compare = argv[++a];
    else if (s == "--out" && a + 1 < argc) outpath = argv[++a];
    else { fprintf(stderr, "unknown arg %s\n", argv[a]); return 2; }
  }

  int fd = open(path, O_RDONLY);
  if (fd < 0) { perror("open"); return 1; }
  struct stat st; fstat(fd, &st);
  size_t fsize = (size_t)st.st_size;
  const uint8_t *data = (const uint8_t *)mmap(nullptr, fsize, PROT_READ, MAP_PRIVATE, fd, 0);
  if (data == MAP_FAILED) { perror("mmap"); return 1; }

  std::vector<double> t_parse, t_decode, t_total;
  RawIfd r;
  TileInfo first_ti;
  std::vector<uint16_t> out;
  size_t pitch = 0; int tiles_x = 0, tiles_y = 0, ntiles = 0;
  std::string err;
  double t_read_ms = 0;

  for (int it = 0; it < warmup + iters; it++)
  {
    double t0 = now_ms();
    r = RawIfd();
    TiffReader tr{data, fsize, data[0] == 'I'};
    uint32_t off = tr.u32(4);
    int guard = 0;
    while (off && guard++ < 8) off = tr.walk(off, r, 0);
    if (r.tile_offsets.empty()) { err = "no tiled compression-7 IFD found"; break; }
    if (r.samples != 1) { err = "samples per pixel != 1 (YCbCr M/S not handled by this prototype)"; break; }
    tiles_x = (r.width + r.tile_w - 1) / r.tile_w; tiles_y = (r.height + r.tile_h - 1) / r.tile_h; ntiles = tiles_x * tiles_y;
    if ((int)r.tile_offsets.size() < ntiles || (int)r.tile_counts.size() < ntiles) { err = "tile tables short"; break; }
    pitch = (size_t)tiles_x * r.tile_w;
    size_t need = pitch * (size_t)tiles_y * r.tile_h;
    if (out.size() != need) out.assign(need, 0); // allocated once; a pool would do the same
    double t1 = now_ms();

    std::atomic<int> next{0};
    std::vector<TileInfo> infos(ntiles);
    std::vector<std::thread> pool;
    int T = std::max(1, threads);
    for (int t = 0; t < T; t++)
      pool.emplace_back([&]() {
        for (;;)
        {
          int k = next.fetch_add(1);
          if (k >= ntiles) break;
          int tx = k % tiles_x, ty = k / tiles_x;
          size_t o = r.tile_offsets[k], c = r.tile_counts[k];
          if (o + c > fsize) { infos[k].error = "tile beyond EOF"; continue; }
          infos[k] = decode_tile(data + o, c, out.data(), pitch, tx * r.tile_w, ty * r.tile_h, r.width, r.height);
        }
      });
    for (auto &th : pool) th.join();
    double t2 = now_ms();
    for (int k = 0; k < ntiles; k++) if (!infos[k].ok) { err = std::string("tile ") + std::to_string(k) + ": " + infos[k].error; break; }
    if (!err.empty()) break;
    first_ti = infos[0];
    if (it >= warmup) { t_parse.push_back(t1 - t0); t_decode.push_back(t2 - t1); t_total.push_back(t2 - t0); printf("ITER %d parse=%.2f decode=%.2f total=%.2f threads=%d\n", it - warmup, t1 - t0, t2 - t1, t2 - t0, T); }
    else printf("WARM %d parse=%.2f decode=%.2f total=%.2f threads=%d\n", it, t1 - t0, t2 - t1, t2 - t0, T);
    fflush(stdout);
  }

  // Cost of pulling the compressed bytes through the CPU once (page cache -> user copy),
  // to show the input-side memory cost separately from the decode.
  {
    std::vector<uint8_t> tmp(fsize);
    double a = now_ms(); memcpy(tmp.data(), data, fsize); double b = now_ms();
    t_read_ms = b - a;
  }

  long long mismatches = -1; long long compared = 0;
  if (!compare.empty() && err.empty())
  {
    FILE *fp = fopen(compare.c_str(), "rb");
    if (fp)
    {
      std::vector<uint16_t> ref((size_t)r.width * r.height);
      size_t got = fread(ref.data(), sizeof(uint16_t), ref.size(), fp); fclose(fp);
      if (got == ref.size())
      {
        mismatches = 0;
        for (uint32_t y = 0; y < r.height; y++)
          for (uint32_t x = 0; x < r.width; x++)
          { compared++; if (ref[(size_t)y * r.width + x] != out[(size_t)y * pitch + x]) mismatches++; }
      }
      else err = "compare file size mismatch";
    }
    else err = "cannot open compare file";
  }
  if (!outpath.empty() && err.empty())
  {
    FILE *fp = fopen(outpath.c_str(), "wb");
    for (uint32_t y = 0; y < r.height; y++) fwrite(out.data() + (size_t)y * pitch, sizeof(uint16_t), r.width, fp);
    fclose(fp);
  }

  auto med = [](std::vector<double> v) { if (v.empty()) return 0.0; std::sort(v.begin(), v.end()); size_t n = v.size(); return n % 2 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]); };
  printf("SUMMARY {\"file\":\"%s\",\"threads\":%d,\"iters\":%zu,\"raw_w\":%u,\"raw_h\":%u,\"tile_w\":%u,\"tile_h\":%u,\"tiles\":%d,"
         "\"bps\":%u,\"samples\":%u,\"photometric\":%u,\"ljpeg_precision\":%d,\"ljpeg_lines\":%d,\"ljpeg_samples_per_line\":%d,\"ljpeg_components\":%d,"
         "\"predictor\":%d,\"point_transform\":%d,\"restart_interval\":%d,\"huffman_tables\":%d,"
         "\"med_parse_ms\":%.2f,\"med_decode_ms\":%.2f,\"med_total_ms\":%.2f,\"file_memcpy_ms\":%.2f,\"file_bytes\":%zu,"
         "\"compared\":%lld,\"mismatches\":%lld,\"err\":\"%s\"}\n",
         path, threads, t_total.size(), r.width, r.height, r.tile_w, r.tile_h, ntiles,
         r.bps, r.samples, r.photometric, first_ti.precision, first_ti.lines, first_ti.samples_per_line, first_ti.ncomp,
         first_ti.predictor, first_ti.pt, first_ti.restart_interval, first_ti.ntables,
         med(t_parse), med(t_decode), med(t_total), t_read_ms, fsize,
         compared, mismatches, err.c_str());
  munmap((void *)data, fsize); close(fd);
  return err.empty() ? 0 : 1;
}
