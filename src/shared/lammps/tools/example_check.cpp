// Runs one LAMMPS script through the Atomify bridge the way the example
// checks do (see check-examples.sh), and prints the result as one JSON line.
//
//   example_check <script> [--steps N] [--timeout S] [--threads T] [--continue 1]
//
// Run it in the example's working copy. The script runs until its input
// completes, or until N steps after the first run (or minimization) started,
// whichever comes first; after S wall clock seconds it is cancelled. T > 1
// runs LAMMPS on T OpenMP threads. With --continue 1 a script that ends
// keeps integrating, as the apps do (continueAfterScript), so scripts
// without a run are measured too. The LAMMPS output goes to
// atomify-check.log in the working directory.
//
// Output: {"status":"ok|failed|timeout","reason":"completed|steps|...",
//          "atoms":N,"steps":N,"seconds":S,"error":"...","line":"...",
//          "threads":T,"used_threads":U,"steps_per_second":R}
// U is the thread count the last run chose for its system.
// R is the rate from the first observed run until the end (0 if unknown).

#include "atomify_lammps.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>

namespace {

std::string json(const std::string &text)
{
  std::string out = "\"";
  for (unsigned char c : text) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
          out += buffer;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out + "\"";
}

void drain(atomify_sim *sim, std::ofstream &log)
{
  char buffer[1 << 14];
  for (size_t n; (n = atomify_sim_read_output(sim, buffer, sizeof(buffer))) > 0;) log.write(buffer, n);
}

// The first line of a LAMMPS error message, without the "ERROR: " prefix.
std::string summary(const std::string &message)
{
  std::string line = message.substr(0, message.find('\n'));
  if (line.rfind("ERROR: ", 0) == 0) line = line.substr(7);
  return line;
}

}    // namespace

int main(int argc, char **argv)
{
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <script> [--steps N] [--timeout S] [--threads T]\n", argv[0]);
    return 2;
  }
  const std::string script = argv[1];
  long long max_steps = 100;
  double timeout = 120.0;
  int threads = 1;
  bool continue_after = false;
  for (int i = 2; i + 1 < argc; i += 2) {
    if (!std::strcmp(argv[i], "--steps")) max_steps = std::atoll(argv[i + 1]);
    else if (!std::strcmp(argv[i], "--timeout")) timeout = std::atof(argv[i + 1]);
    else if (!std::strcmp(argv[i], "--threads")) threads = std::atoi(argv[i + 1]);
    else if (!std::strcmp(argv[i], "--continue")) continue_after = std::atoi(argv[i + 1]) != 0;
  }

  const auto start = std::chrono::steady_clock::now();
  const auto seconds = [&] { return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count(); };
  std::ofstream log("atomify-check.log");
  atomify_sim *sim = atomify_sim_create_threaded(0, threads);
  if (!sim) {
    std::printf("{\"status\":\"failed\",\"reason\":\"engine\",\"atoms\":0,\"steps\":0,\"seconds\":0,"
                "\"error\":\"LAMMPS could not be started\",\"line\":\"\"}\n");
    return 1;
  }
  atomify_sim_set_publish_interval(sim, 0.02);

  std::atomic<int> status{-1};
  std::thread worker([&] {
    int result = atomify_sim_run_file(sim, script.c_str());
    if (result == ATOMIFY_OK && continue_after) result = atomify_sim_command(sim, "run 1000000000");
    status = result;
  });

  long long atoms = 0, steps = 0, run_start = -1, first_step = -1;
  double first_seconds = 0;
  std::string reason;
  while (status.load() < 0) {
    atomify_snapshot snapshot;
    if (atomify_sim_snapshot_lock(sim, &snapshot)) {
      atoms = snapshot.natoms;
      if (run_start < 0 && snapshot.run_mode != ATOMIFY_RUN_IDLE)
        run_start = snapshot.timestep - snapshot.run_step;
      if (run_start >= 0) steps = snapshot.timestep - run_start;
      if (first_step < 0 && run_start >= 0) {
        first_step = snapshot.timestep;
        first_seconds = seconds();
      }
      atomify_sim_snapshot_unlock(sim);
    }
    drain(sim, log);
    if (reason.empty() && run_start >= 0 && steps >= max_steps) {
      reason = "steps";
      atomify_sim_cancel(sim);
    } else if (reason.empty() && seconds() > timeout) {
      reason = "timeout";
      atomify_sim_cancel(sim);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  worker.join();

  std::string result, error, line;
  if (status == ATOMIFY_OK) {
    // The final state, also for scripts without a run.
    atomify_sim_publish(sim);
    atomify_snapshot snapshot;
    if (atomify_sim_snapshot_lock(sim, &snapshot)) {
      atoms = snapshot.natoms;
      // A run that ended between two polls was never seen: count from step 0.
      steps = snapshot.timestep - (run_start >= 0 ? run_start : 0);
      atomify_sim_snapshot_unlock(sim);
    }
    result = "ok";
    reason = "completed";
  } else if (status == ATOMIFY_CANCELLED && reason == "steps") {
    result = "ok";
  } else if (status == ATOMIFY_CANCELLED) {
    result = "timeout";
    reason = "timeout";
  } else {
    result = "failed";
    reason = "error";
    error = summary(atomify_sim_last_error(sim));
    line = atomify_sim_last_error_line(sim);
  }
  drain(sim, log);
  const double elapsed = seconds();
  const long long run_steps = first_step >= 0 && run_start >= 0 ? run_start + steps - first_step : 0;
  const double rate = run_steps > 0 && elapsed > first_seconds ? run_steps / (elapsed - first_seconds) : 0;
  const int used_threads = atomify_sim_threads(sim);
  atomify_sim_destroy(sim);

  std::printf("{\"status\":%s,\"reason\":%s,\"atoms\":%lld,\"steps\":%lld,\"seconds\":%.2f,\"error\":%s,\"line\":%s,"
              "\"threads\":%d,\"used_threads\":%d,\"steps_per_second\":%.2f}\n",
              json(result).c_str(), json(reason).c_str(), atoms, steps, elapsed, json(error).c_str(),
              json(line).c_str(), threads, used_threads, rate);
  return result == "ok" ? 0 : 1;
}
