import sys, time
sys.path.insert(0, __import__("os").path.dirname(__file__))
import dvbt_rx
t = time.perf_counter()
dvbt_rx.main(sys.argv[1], sys.argv[2])
dt = time.perf_counter() - t
n = __import__("os").path.getsize(sys.argv[1]) // 8
print(f"gr-dtv RX: {n} samples in {dt:.2f} s = {n / dt / 1e6:.2f} Msamples/s")
