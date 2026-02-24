#!/usr/bin/env node

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const ROOT_DIR = path.dirname(path.dirname(SCRIPT_PATH));
const HELPER_PATH = path.join(ROOT_DIR, "native", "macos_brightness.swift");
const PACKAGE_JSON = JSON.parse(fs.readFileSync(path.join(ROOT_DIR, "package.json"), "utf8"));
const VERSION = PACKAGE_JSON.version;

function printHelp() {
  console.log(`night v${VERSION}

Keep Mac awake, dim display + keyboard to 0, then restore on key press.

Usage:
  night [options]

Options:
  --no-display      Do not change display brightness
  --no-keyboard     Do not change keyboard backlight brightness
  --no-caffeinate   Do not run caffeinate -i
  -h, --help        Show help
  -v, --version     Show version

Behavior:
  1) (optional) start caffeinate -i
  2) set keyboard brightness to 0
  3) set display brightness to 0
  4) wait for any key press
  5) restore brightness and stop caffeinate
`);
}

function fail(message, code = 1) {
  console.error(`night: ${message}`);
  process.exit(code);
}

function parseArgs(argv) {
  const config = {
    noDisplay: false,
    noKeyboard: false,
    noCaffeinate: false,
    help: false,
    version: false,
  };

  for (const token of argv) {
    switch (token) {
      case "-h":
      case "--help":
        config.help = true;
        break;
      case "-v":
      case "--version":
        config.version = true;
        break;
      case "--no-display":
        config.noDisplay = true;
        break;
      case "--no-keyboard":
        config.noKeyboard = true;
        break;
      case "--no-caffeinate":
        config.noCaffeinate = true;
        break;
      default:
        throw new Error(`Unknown option '${token}'`);
    }
  }

  if (!config.help && !config.version && config.noDisplay && config.noKeyboard && config.noCaffeinate) {
    throw new Error("Nothing to do: all actions are disabled.");
  }

  return config;
}

function commandForError(command, args) {
  return [command, ...args].map((item) => JSON.stringify(item)).join(" ");
}

async function runCommand(command, args, { allowNonZero = false } = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      env: process.env,
    });

    let stdout = "";
    let stderr = "";
    let settled = false;

    const finishResolve = (value) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(value);
    };

    const finishReject = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      reject(error);
    };

    if (child.stdout) {
      child.stdout.on("data", (chunk) => {
        stdout += String(chunk);
      });
    }

    if (child.stderr) {
      child.stderr.on("data", (chunk) => {
        stderr += String(chunk);
      });
    }

    child.on("error", (error) => {
      const wrapped = new Error(`Failed to start ${commandForError(command, args)}: ${error.message}`);
      wrapped.code = error.code;
      finishReject(wrapped);
    });

    child.on("close", (code, signal) => {
      if (code === 0 || allowNonZero) {
        finishResolve({ code, signal, stdout, stderr });
        return;
      }
      const suffix = stderr.trim().length > 0 ? `: ${stderr.trim()}` : "";
      finishReject(
        new Error(
          `${commandForError(command, args)} exited with code ${code}${
            signal ? ` (signal ${signal})` : ""
          }${suffix}`,
        ),
      );
    });
  });
}

function parseUnitValue(raw, label) {
  const value = Number.parseFloat(String(raw).trim());
  if (!Number.isFinite(value)) {
    throw new Error(`Could not parse ${label} from '${String(raw).trim()}'`);
  }
  if (value < 0 || value > 1) {
    throw new Error(`${label} out of range [0,1]: ${value}`);
  }
  return value;
}

function formatUnitValue(value) {
  return Number(value).toFixed(6);
}

async function runHelper(args) {
  try {
    const result = await runCommand("swift", [HELPER_PATH, ...args]);
    return result.stdout.trim();
  } catch (error) {
    if (error && error.code === "ENOENT") {
      throw new Error(
        "swift command not found. Install Xcode Command Line Tools (xcode-select --install).",
      );
    }
    throw error;
  }
}

function parseDisplaySnapshot(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`Could not parse display snapshot JSON: ${error.message}`);
  }
  if (!Array.isArray(parsed) || parsed.length === 0) {
    throw new Error("Display snapshot is empty.");
  }

  const entries = [];
  for (const item of parsed) {
    const id = String(item?.id ?? "").trim();
    if (id.length === 0) {
      throw new Error("Display snapshot contains entry with missing id.");
    }
    const value = parseUnitValue(item?.value, `display brightness for ${id}`);
    entries.push({ id, value });
  }
  return entries;
}

async function getDisplaySnapshot() {
  return parseDisplaySnapshot(await runHelper(["display-all-get"]));
}

async function setAllDisplaysBrightness(value) {
  await runHelper(["display-all-set", formatUnitValue(value)]);
}

async function setDisplayBrightnessById(id, value) {
  await runHelper(["display-one-set", id, formatUnitValue(value)]);
}

async function setDisplayBrightness(value) {
  await runHelper(["display-set", formatUnitValue(value)]);
}

async function getKeyboardBrightness() {
  return parseUnitValue(await runHelper(["keyboard-get"]), "keyboard brightness");
}

async function setKeyboardBrightness(value) {
  await runHelper(["keyboard-set", formatUnitValue(value)]);
}

async function getKeyboardAuto() {
  const raw = (await runHelper(["keyboard-auto-get"]))?.trim();
  if (raw === "0" || raw === "1") {
    return Number(raw);
  }
  throw new Error(`Could not parse keyboard auto-brightness state from '${raw}'`);
}

async function setKeyboardAuto(enabled) {
  await runHelper(["keyboard-auto-set", enabled ? "1" : "0"]);
}

async function startCaffeinate() {
  const child = spawn("caffeinate", ["-i"], {
    stdio: "ignore",
    env: process.env,
  });

  return await new Promise((resolve, reject) => {
    let settled = false;

    const cleanup = () => {
      child.removeListener("spawn", onSpawn);
      child.removeListener("error", onError);
      child.removeListener("exit", onExit);
    };

    const onSpawn = () => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      resolve(child);
    };

    const onError = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      if (error && error.code === "ENOENT") {
        reject(new Error("caffeinate command not found."));
        return;
      }
      reject(new Error(`Failed to start caffeinate -i: ${error.message}`));
    };

    const onExit = (code, signal) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(new Error(`caffeinate exited immediately (code=${code}, signal=${signal ?? "none"}).`));
    };

    child.once("spawn", onSpawn);
    child.once("error", onError);
    child.once("exit", onExit);
  });
}

async function stopCaffeinate(child) {
  if (!child) {
    return;
  }
  if (child.exitCode !== null || child.killed) {
    return;
  }

  await new Promise((resolve) => {
    let resolved = false;
    const finish = () => {
      if (resolved) {
        return;
      }
      resolved = true;
      resolve();
    };

    const forceTimer = setTimeout(() => {
      if (child.exitCode === null) {
        try {
          child.kill("SIGKILL");
        } catch {
          // ignored
        }
      }
    }, 1500);

    const settleTimer = setTimeout(() => {
      clearTimeout(forceTimer);
      finish();
    }, 2500);

    child.once("exit", () => {
      clearTimeout(forceTimer);
      clearTimeout(settleTimer);
      finish();
    });

    try {
      child.kill("SIGTERM");
    } catch {
      clearTimeout(forceTimer);
      clearTimeout(settleTimer);
      finish();
    }
  });
}

function setRawMode(enabled) {
  if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== "function") {
    return;
  }
  process.stdin.setRawMode(enabled);
  if (enabled) {
    process.stdin.resume();
  } else {
    process.stdin.pause();
  }
}

async function waitForWakeTrigger() {
  if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== "function") {
    throw new Error("night requires an interactive TTY to capture key presses.");
  }

  setRawMode(true);
  return await new Promise((resolve) => {
    const cleanup = () => {
      process.stdin.removeListener("data", onData);
      process.removeListener("SIGINT", onSigInt);
      process.removeListener("SIGTERM", onSigTerm);
      process.removeListener("SIGHUP", onSigHup);
      setRawMode(false);
    };

    const finish = (result) => {
      cleanup();
      resolve(result);
    };

    const onData = () => {
      finish({ reason: "key" });
    };

    const onSigInt = () => {
      finish({ reason: "signal", signal: "SIGINT" });
    };

    const onSigTerm = () => {
      finish({ reason: "signal", signal: "SIGTERM" });
    };

    const onSigHup = () => {
      finish({ reason: "signal", signal: "SIGHUP" });
    };

    process.stdin.on("data", onData);
    process.on("SIGINT", onSigInt);
    process.on("SIGTERM", onSigTerm);
    process.on("SIGHUP", onSigHup);
  });
}

async function executeNight(config) {
  if (process.platform !== "darwin") {
    throw new Error("night currently supports macOS only.");
  }
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    throw new Error("night must be run from an interactive terminal (TTY).");
  }

  const state = {
    displayBefore: [],
    displayDimmed: false,
    keyboardBefore: null,
    keyboardDimmed: false,
    keyboardAutoBefore: null,
    keyboardAutoChanged: false,
  };

  let caffeinate = null;
  let wake = { reason: "unknown" };
  let displayPinTimer = null;

  if (!config.noDisplay) {
    state.displayBefore = await getDisplaySnapshot();
  }
  if (!config.noKeyboard) {
    state.keyboardBefore = await getKeyboardBrightness();
    state.keyboardAutoBefore = await getKeyboardAuto();
  }

  try {
    if (!config.noCaffeinate) {
      caffeinate = await startCaffeinate();
      console.log(`caffeinate -i started (pid ${caffeinate.pid})`);
    }

    if (!config.noKeyboard) {
      if (state.keyboardAutoBefore === 1) {
        await setKeyboardAuto(false);
        state.keyboardAutoChanged = true;
      }
      await setKeyboardBrightness(0);
      state.keyboardDimmed = true;
    }

    if (!config.noDisplay) {
      await setAllDisplaysBrightness(0);
      state.displayDimmed = true;
      let displayPinInFlight = false;
      displayPinTimer = setInterval(() => {
        if (displayPinInFlight) {
          return;
        }
        displayPinInFlight = true;
        setAllDisplaysBrightness(0)
          .catch(() => {
            // best-effort pinning while waiting
          })
          .finally(() => {
            displayPinInFlight = false;
          });
      }, 2000);
      displayPinTimer.unref();
    }

    console.log("Night mode active. Press any key to restore and exit.");
    wake = await waitForWakeTrigger();
  } finally {
    const restoreErrors = [];

    if (displayPinTimer) {
      clearInterval(displayPinTimer);
      displayPinTimer = null;
    }

    if (state.displayDimmed && state.displayBefore.length > 0) {
      try {
        for (const entry of state.displayBefore) {
          await setDisplayBrightnessById(entry.id, entry.value);
        }
      } catch (error) {
        restoreErrors.push(`display restore failed: ${error.message}`);
      }
    }

    if (state.keyboardDimmed && state.keyboardBefore !== null) {
      try {
        await setKeyboardBrightness(state.keyboardBefore);
      } catch (error) {
        restoreErrors.push(`keyboard restore failed: ${error.message}`);
      }
    }

    if (state.keyboardAutoChanged && state.keyboardAutoBefore !== null) {
      try {
        await setKeyboardAuto(state.keyboardAutoBefore === 1);
      } catch (error) {
        restoreErrors.push(`keyboard auto restore failed: ${error.message}`);
      }
    }

    try {
      await stopCaffeinate(caffeinate);
    } catch (error) {
      restoreErrors.push(`failed to stop caffeinate: ${error.message}`);
    }

    if (restoreErrors.length > 0) {
      throw new Error(restoreErrors.join(" | "));
    }
  }

  if (wake.reason === "signal") {
    console.log(`Restored state after ${wake.signal}.`);
  } else {
    console.log("Restored state.");
  }
}

async function main() {
  const config = parseArgs(process.argv.slice(2));
  if (config.help) {
    printHelp();
    return;
  }
  if (config.version) {
    console.log(VERSION);
    return;
  }
  await executeNight(config);
}

await main().catch((error) => {
  fail(error.message || String(error));
});
