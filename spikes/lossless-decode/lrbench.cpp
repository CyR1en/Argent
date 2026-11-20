// Argent spike, lossless-decode. Measurement prototype, not shipped code.
//
// lrbench times LibRaw's stages on one ARW (open_file, unpack, a copy of the raw
// buffer, dcraw_process, dcraw_make_mem_image) and can dump the unpacked raw buffer,
// which tiledec's --compare uses as its bit-exact reference. It links LibRaw 0.22.2,
// which is LGPL-2.1 (or CDDL-1.0). That is fine here because this tool is not
// distributed with the app; the app's own rule on LibRaw is in docs/SPEC.md.
//
// Build, with LibRaw built as README.md in this folder describes:
//   clang++ -O3 -std=c++17 -ILibRaw-0.22.2 lrbench.cpp LibRaw-0.22.2/lib/libraw.a -lz -o lrbench

// lrbench: time LibRaw stages on one ARW.
//
// usage: lrbench <file.arw> [--qual N] [--unpack-only] [--iters N] [--warmup N]
//                           [--green] [--mem] [--raw-color] [--tag T]
//
// Stages timed per iteration (wall clock, std::chrono::steady_clock):
//   open_ms     LibRaw::open_file()          metadata parse
//   unpack_ms   LibRaw::unpack()             decompression into raw_image / image
//   copy_ms     memcpy of the raw buffer     stands in for the upload to a Metal buffer
//   process_ms  LibRaw::dcraw_process()      black, WB, demosaic (user_qual), colour
//   mem_ms      LibRaw::dcraw_make_mem_image 16-bit RGB output buffer (only with --mem)
//
// Prints one "ITER" line per timed iteration and a final "SUMMARY" JSON line.

#include "libraw/libraw.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/time.h>
#include <vector>

static double now_ms()
{
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

static double wall_epoch_s()
{
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return tv.tv_sec + tv.tv_usec * 1e-6;
}

static double median(std::vector<double> v)
{
  if (v.empty()) return 0;
  std::sort(v.begin(), v.end());
  size_t n = v.size();
  return n % 2 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}

struct Iter
{
  double open_ms = 0, unpack_ms = 0, copy_ms = 0, process_ms = 0, mem_ms = 0;
  double total_ms = 0;
};

int main(int argc, char **argv)
{
  if (argc < 2)
  {
    fprintf(stderr, "usage: lrbench <file.arw> [--qual N] [--unpack-only] [--iters N] [--warmup N] [--green] [--mem] [--raw-color] [--tag T]\n");
    return 2;
  }
  const char *path = argv[1];
  int qual = 0;
  bool unpack_only = false, want_green = false, want_mem = false, raw_color = false;
  int iters = 5, warmup = 1;
  std::string tag = "", dump_path = "";
  for (int i = 2; i < argc; i++)
  {
    std::string a = argv[i];
    if (a == "--qual" && i + 1 < argc) qual = atoi(argv[++i]);
    else if (a == "--unpack-only") unpack_only = true;
    else if (a == "--iters" && i + 1 < argc) iters = atoi(argv[++i]);
    else if (a == "--warmup" && i + 1 < argc) warmup = atoi(argv[++i]);
    else if (a == "--green") want_green = true;
    else if (a == "--mem") want_mem = true;
    else if (a == "--raw-color") raw_color = true;
    else if (a == "--tag" && i + 1 < argc) tag = argv[++i];
    else if (a == "--dump" && i + 1 < argc) dump_path = argv[++i];
    else { fprintf(stderr, "unknown arg %s\n", argv[i]); return 2; }
  }

  std::vector<Iter> timed;
  std::string decoder_name, model, make, cdesc;
  unsigned filters = 0;
  int colors = 0;
  int raw_w = 0, raw_h = 0, w = 0, h = 0, iw = 0, ih = 0, top = 0, left = 0;
  unsigned black = 0, maximum = 0;
  unsigned cblack[6] = {0, 0, 0, 0, 0, 0};
  float cam_mul[4] = {0, 0, 0, 0};
  int out_w = 0, out_h = 0, out_colors = 0, out_bits = 0;
  size_t raw_bytes = 0;
  double green_mean = -1, green_mean_libraw_black = -1;
  long long green_count = 0;
  int last_err = 0;
  std::string last_err_stage;
  double t_first_timed_start = 0, t_last_end = 0;
  volatile unsigned long long sink = 0;

  for (int it = 0; it < warmup + iters; it++)
  {
    bool is_timed = it >= warmup;
    Iter r;
    LibRaw lr;
    lr.imgdata.params.use_camera_wb = 1;
    lr.imgdata.params.output_bps = 16;
    lr.imgdata.params.no_auto_bright = 1;
    lr.imgdata.params.gamm[0] = 1.0;
    lr.imgdata.params.gamm[1] = 1.0;
    lr.imgdata.params.half_size = 0;
    lr.imgdata.params.user_qual = qual;
    if (raw_color) lr.imgdata.params.output_color = 0;

    double t_begin = now_ms();
    if (is_timed && t_first_timed_start == 0) t_first_timed_start = wall_epoch_s();

    double t0 = now_ms();
    int e = lr.open_file(path);
    double t1 = now_ms();
    r.open_ms = t1 - t0;
    if (e != LIBRAW_SUCCESS)
    {
      last_err = e; last_err_stage = "open_file";
      fprintf(stderr, "open_file: %s\n", LibRaw::strerror(e));
      break;
    }

    libraw_decoder_info_t di;
    lr.get_decoder_info(&di);
    decoder_name = di.decoder_name ? di.decoder_name : "?";
    make = lr.imgdata.idata.make;
    model = lr.imgdata.idata.model;
    cdesc = lr.imgdata.idata.cdesc;
    filters = lr.imgdata.idata.filters;
    colors = lr.imgdata.idata.colors;
    raw_w = lr.imgdata.sizes.raw_width; raw_h = lr.imgdata.sizes.raw_height;
    w = lr.imgdata.sizes.width; h = lr.imgdata.sizes.height;
    top = lr.imgdata.sizes.top_margin; left = lr.imgdata.sizes.left_margin;

    double t2 = now_ms();
    e = lr.unpack();
    double t3 = now_ms();
    r.unpack_ms = t3 - t2;
    if (e != LIBRAW_SUCCESS)
    {
      last_err = e; last_err_stage = "unpack";
      fprintf(stderr, "unpack: %s\n", LibRaw::strerror(e));
      break;
    }

    black = lr.imgdata.color.black;
    maximum = lr.imgdata.color.maximum;
    for (int k = 0; k < 6; k++) cblack[k] = lr.imgdata.color.cblack[k];
    for (int k = 0; k < 4; k++) cam_mul[k] = lr.imgdata.color.cam_mul[k];
    iw = lr.imgdata.sizes.iwidth; ih = lr.imgdata.sizes.iheight;

    // Copy of whatever unpack produced: raw_image (Bayer), color3_image, or image (legacy decoders).
    {
      const void *src = nullptr; size_t bytes = 0;
      if (lr.imgdata.rawdata.raw_image) { src = lr.imgdata.rawdata.raw_image; bytes = (size_t)lr.imgdata.sizes.raw_pitch * raw_h; }
      else if (lr.imgdata.rawdata.color3_image) { src = lr.imgdata.rawdata.color3_image; bytes = (size_t)lr.imgdata.sizes.raw_pitch * raw_h; }
      else if (lr.imgdata.image) { src = lr.imgdata.image; bytes = (size_t)raw_w * raw_h * 4 * sizeof(ushort); }
      raw_bytes = bytes;
      if (src && bytes)
      {
        std::vector<unsigned char> dst(bytes);
        double c0 = now_ms();
        memcpy(dst.data(), src, bytes);
        double c1 = now_ms();
        r.copy_ms = c1 - c0;
        sink += dst[bytes / 2];
      }
    }

    if (!dump_path.empty() && it == 0 && lr.imgdata.rawdata.raw_image)
    {
      FILE *fp = fopen(dump_path.c_str(), "wb");
      if (fp)
      {
        size_t pitch = lr.imgdata.sizes.raw_pitch / sizeof(ushort);
        for (int row = 0; row < raw_h; row++)
          fwrite(lr.imgdata.rawdata.raw_image + (size_t)row * pitch, sizeof(ushort), raw_w, fp);
        fclose(fp);
        fprintf(stderr, "dumped raw_image %dx%d ushort to %s\n", raw_w, raw_h, dump_path.c_str());
      }
    }

    if (want_green && it == 0 && lr.imgdata.rawdata.raw_image && filters)
    {
      // Mean green of the visible area after black subtraction, over (16383-512),
      // and also over LibRaw's own (maximum - black).
      const ushort *raw = lr.imgdata.rawdata.raw_image;
      size_t pitch = lr.imgdata.sizes.raw_pitch / sizeof(ushort);
      double sum = 0; long long n = 0, nsat = 0, nbelow = 0; unsigned mn = 65535, mx = 0;
      for (int row = 0; row < h; row++)
        for (int col = 0; col < w; col++)
        {
          int c = lr.FC(row, col);
          if (cdesc[c] != 'G') continue;
          unsigned v = raw[(size_t)(row + top) * pitch + (col + left)];
          sum += v; n++;
          if (v >= 16383) nsat++;
          if (v < 512) nbelow++;
          if (v < mn) mn = v;
          if (v > mx) mx = v;
        }
      green_count = n;
      double mean_dn = sum / (double)n;
      green_mean = (mean_dn - 512.0) / (16383.0 - 512.0);
      green_mean_libraw_black = (mean_dn - (double)black) / ((double)maximum - (double)black);
      fprintf(stderr, "green: n=%lld mean_dn=%.3f (dn-512)/15871=%.6f (dn-black)/(max-black)=%.6f sat(>=16383)=%lld (%.5f) below512=%lld min=%u max=%u\n",
              n, mean_dn, green_mean, green_mean_libraw_black, nsat, (double)nsat / n, nbelow, mn, mx);
      // Mean over the Apple-sized crop (7008 x 4672, centred) for a like-for-like scene mean.
      {
        int cw = 7008, ch = 4672; int r0 = (h - ch) / 2, c0 = (w - cw) / 2;
        double s2 = 0; long long n2 = 0;
        if (r0 >= 0 && c0 >= 0)
        {
          for (int row = r0; row < r0 + ch; row++)
            for (int col = c0; col < c0 + cw; col++)
            {
              if (cdesc[lr.FC(row, col)] != 'G') continue;
              s2 += raw[(size_t)(row + top) * pitch + (col + left)]; n2++;
            }
          fprintf(stderr, "green centred 7008x4672 crop: n=%lld mean (dn-512)/15871=%.6f\n", n2, (s2 / n2 - 512.0) / 15871.0);
        }
      }
    }

    if (!unpack_only)
    {
      double t4 = now_ms();
      e = lr.dcraw_process();
      double t5 = now_ms();
      r.process_ms = t5 - t4;
      if (e != LIBRAW_SUCCESS)
      {
        last_err = e; last_err_stage = "dcraw_process";
        fprintf(stderr, "dcraw_process: %s\n", LibRaw::strerror(e));
        break;
      }
      iw = lr.imgdata.sizes.iwidth; ih = lr.imgdata.sizes.iheight;
      if (want_mem)
      {
        double t6 = now_ms();
        int ec = 0;
        libraw_processed_image_t *img = lr.dcraw_make_mem_image(&ec);
        double t7 = now_ms();
        r.mem_ms = t7 - t6;
        if (img)
        {
          out_w = img->width; out_h = img->height; out_colors = img->colors; out_bits = img->bits;
          sink += img->data[img->data_size / 2];
          LibRaw::dcraw_clear_mem(img);
        }
        else
        {
          last_err = ec; last_err_stage = "dcraw_make_mem_image";
          fprintf(stderr, "dcraw_make_mem_image: %s\n", LibRaw::strerror(ec));
        }
      }
    }
    r.total_ms = now_ms() - t_begin;
    lr.recycle();
    if (is_timed)
    {
      timed.push_back(r);
      t_last_end = wall_epoch_s();
      printf("ITER %d open=%.2f unpack=%.2f copy=%.2f process=%.2f mem=%.2f total=%.2f\n",
             it - warmup, r.open_ms, r.unpack_ms, r.copy_ms, r.process_ms, r.mem_ms, r.total_ms);
    }
    else
    {
      printf("WARM %d open=%.2f unpack=%.2f copy=%.2f process=%.2f mem=%.2f total=%.2f\n",
             it, r.open_ms, r.unpack_ms, r.copy_ms, r.process_ms, r.mem_ms, r.total_ms);
    }
    fflush(stdout);
  }

  std::vector<double> o, u, c, p, m, t;
  for (auto &r : timed) { o.push_back(r.open_ms); u.push_back(r.unpack_ms); c.push_back(r.copy_ms); p.push_back(r.process_ms); m.push_back(r.mem_ms); t.push_back(r.total_ms); }

  printf("SUMMARY {\"tag\":\"%s\",\"file\":\"%s\",\"qual\":%d,\"unpack_only\":%s,\"iters\":%zu,"
         "\"decoder\":\"%s\",\"make\":\"%s\",\"model\":\"%s\",\"cdesc\":\"%s\",\"filters\":\"0x%08x\",\"colors\":%d,"
         "\"raw_w\":%d,\"raw_h\":%d,\"width\":%d,\"height\":%d,\"iwidth\":%d,\"iheight\":%d,\"top\":%d,\"left\":%d,"
         "\"black\":%u,\"maximum\":%u,\"cblack\":[%u,%u,%u,%u,%u,%u],\"cam_mul\":[%.4f,%.4f,%.4f,%.4f],"
         "\"out_w\":%d,\"out_h\":%d,\"out_colors\":%d,\"out_bits\":%d,\"raw_bytes\":%zu,"
         "\"green_mean\":%.6f,\"green_mean_libraw\":%.6f,\"green_count\":%lld,"
         "\"med_open_ms\":%.2f,\"med_unpack_ms\":%.2f,\"med_copy_ms\":%.2f,\"med_process_ms\":%.2f,\"med_mem_ms\":%.2f,\"med_total_ms\":%.2f,"
         "\"err\":%d,\"err_stage\":\"%s\",\"err_text\":\"%s\",\"t_first\":%.6f,\"t_last\":%.6f}\n",
         tag.c_str(), path, qual, unpack_only ? "true" : "false", timed.size(),
         decoder_name.c_str(), make.c_str(), model.c_str(), cdesc.c_str(), filters, colors,
         raw_w, raw_h, w, h, iw, ih, top, left,
         black, maximum, cblack[0], cblack[1], cblack[2], cblack[3], cblack[4], cblack[5], cam_mul[0], cam_mul[1], cam_mul[2], cam_mul[3],
         out_w, out_h, out_colors, out_bits, raw_bytes,
         green_mean, green_mean_libraw_black, green_count,
         median(o), median(u), median(c), median(p), median(m), median(t),
         last_err, last_err_stage.c_str(), last_err ? LibRaw::strerror(last_err) : "",
         t_first_timed_start, t_last_end);
  return last_err ? 1 : 0;
}
