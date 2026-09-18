#!/usr/bin/env python3
"""Does pce2hdmi_sd.sv's 2-line ping-pong buffer get overwritten while it is being read?

Model, straight from the RTL:
  WRITER (clk_pce): fills one buffer per SOURCE line, 2730 clk_pce = 63.700 us, then flips
                    wr_line_toggle (src/pce2hdmi_sd.sv, "new line" branch).
  READER (clk_pixel): every EVEN output line (cy[0]==0) latches line_toggle_rd =
                    ~wr_line_toggle_sync -- "the most recently COMPLETED line" -- and reads
                    that buffer across the next 2 output lines.
  720p: one output line = 1650/74.375e6 = 22.185 us, so a read lasts 44.37 us.

A collision is the writer entering the buffer the reader is currently reading.
"""
SRC_LINE = 2730 / 42.857e6          # 63.700 us
OUT_LINE = 1650 / 74.375e6          # 22.185 us
READ_LEN = 2 * OUT_LINE             # a source line is shown over 2 output lines

def run(n_buffers, frames=2, lines_per_frame=750):
    t_end = frames * lines_per_frame * OUT_LINE
    # writer: buffer index flips every SRC_LINE
    def writer_span(i):             # writes buffer (i % n) during [i*SRC, (i+1)*SRC)
        return i % n_buffers, i * SRC_LINE, (i + 1) * SRC_LINE
    collisions, reads, shows = 0, 0, {}
    t = 0.0
    while t < t_end:
        # which line has most recently COMPLETED at time t
        done = int(t / SRC_LINE) - 1
        if done < 0:
            t += READ_LEN; continue
        rd_buf = done % n_buffers
        reads += 1
        shows[done] = shows.get(done, 0) + 2        # shown for 2 output lines
        # does any writer span touching rd_buf overlap [t, t+READ_LEN)?
        for i in range(done + 1, done + 4):
            b, s, e = writer_span(i)
            if b == rd_buf and s < t + READ_LEN and e > t:
                collisions += 1
                break
        t += READ_LEN
    dist = {}
    for v in shows.values():
        dist[v] = dist.get(v, 0) + 1
    return collisions, reads, dist

for n in (2, 3, 4):
    c, r, dist = run(n)
    print(f"buffers={n}: {c:5d} collisions in {r} reads ({100*c/r:5.1f}%)   "
          f"output-lines-per-source-line: {dict(sorted(dist.items()))}")
