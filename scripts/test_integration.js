import { unlinkSync, readdirSync, existsSync } from "node:fs";
import { spawn } from "bun";
import { join } from "node:path";

const SOCKET = "test_integration.sock";
const PID_FILE = `${SOCKET}.pid`;
const SOCKET_SIMPLE = "test_simple.sock";
const JAR = "target/daemon-1.0.0.jar";
const CLI = join(process.cwd(), "zig-out", "bin", "zig_cli_daemon.exe");
const JAVA_EXE = process.env.JAVA_HOME ? join(process.env.JAVA_HOME, "bin", "java.exe") : "java";

function Log(msg, color = "\x1b[36m") {
    console.log(`${color}[TEST] ${msg}\x1b[0m`);
}

function checkExists(path) {
    try {
        return existsSync(path) || readdirSync(".").includes(path);
    } catch {
        return false;
    }
}

function safeUnlink(path) {
    try { if (checkExists(path)) unlinkSync(path); } catch (e) {}
}

async function cleanup() {
    Log("Cleaning up stale files...");
    safeUnlink(SOCKET);
    safeUnlink(PID_FILE);
    safeUnlink(SOCKET_SIMPLE);
}

async function waitForSocket(path, timeoutMs = 5000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        if (checkExists(path)) return true;
        await new Promise(r => setTimeout(r, 200));
    }
    return false;
}

async function runCli(args, inputStr = null) {
    const proc = spawn([CLI, ...args], {
        stdin: inputStr ? Buffer.from(inputStr, "utf8") : "ignore",
        stdout: "pipe",
        stderr: "pipe",
    });

    const output = (await new Response(proc.stdout).text()).trim().replace(/\r\n/g, "\n");
    const errors = await new Response(proc.stderr).text();
    const exitCode = await proc.exited;

    return { output, errors, exitCode };
}

async function runTest() {
    Log("Starting Integration Test (Bun Native Edition)...");

    await cleanup();

    // --- 1. Test Advanced Mode ---
    Log("Starting Advanced Mode Java Daemon...");
    const advancedDaemon = spawn([JAVA_EXE, `-Ddaemon.sock=${SOCKET}`, "-jar", JAR], {
        stdout: "inherit",
        stderr: "inherit",
    });
    advancedDaemon.unref();

    Log("Waiting for advanced daemon socket...");
    if (!(await waitForSocket(SOCKET))) {
        advancedDaemon.kill();
        throw new Error("Timed out waiting for advanced daemon socket.");
    }

    Log("Verifying Advanced Mode (UTF-8 Uppercase)...");
    const inputAdvanced = "hèllo daemon";
    const expectedAdvanced = "STATUS\nHÈLLO DAEMON";
    const adv = await runCli(["--daemon-socket", SOCKET, "--quiet", "--", "status"], inputAdvanced);

    if (adv.exitCode !== 0 || adv.output !== expectedAdvanced) {
        Log(`FAILED Advanced: ExitCode ${adv.exitCode}`, "\x1b[31m");
        Log(`Expected '${expectedAdvanced.replace(/\n/g, "\\n")}', got '${adv.output.replace(/\n/g, "\\n")}'`, "\x1b[31m");
        if (adv.errors) Log(`CLI Errors:\n${adv.errors}`, "\x1b[90m");
        advancedDaemon.kill();
        process.exit(1);
    }
    Log("Advanced Mode SUCCESS.");

    // --- 2. Test Simple Mode ---
    Log("Starting Simple Mode Java Daemon...");
    const simpleDaemon = spawn([JAVA_EXE, `-Ddaemon.sock=${SOCKET_SIMPLE}`, "-cp", JAR, "hr.hrg.daemon.simple.Main"], {
        stdout: "inherit",
        stderr: "inherit",
    });
    simpleDaemon.unref();

    Log("Waiting for simple daemon socket...");
    if (!(await waitForSocket(SOCKET_SIMPLE))) {
        simpleDaemon.kill();
        throw new Error("Timed out waiting for simple daemon socket.");
    }

    Log("Verifying Simple Mode...");
    const inputSimple = "simple world";
    const expectedSimple = "SIMPLE WORLD";
    const simple = await runCli(["--daemon-socket", SOCKET_SIMPLE, "--mode", "simple", "--quiet", "--", "status"], inputSimple);

    if (simple.exitCode !== 0 || simple.output !== expectedSimple) {
        Log(`FAILED Simple: ExitCode ${simple.exitCode}`, "\x1b[31m");
        Log(`Expected '${expectedSimple}', got '${simple.output}'`, "\x1b[31m");
        if (simple.errors) Log(`CLI Errors (Simple):\n${simple.errors}`, "\x1b[90m");
        simpleDaemon.kill();
        process.exit(1);
    }
    Log("Simple Mode SUCCESS.");

    // --- 3. Shutdown ---
    Log("Stopping Advanced Daemon via --restart...");
    await runCli(["--daemon-socket", SOCKET, "--restart"]);

    Log("Stopping Simple Daemon via __SHUTDOWN__ signal...");
    await runCli(["--daemon-socket", SOCKET_SIMPLE, "--mode", "simple", "--body", "__SHUTDOWN__", "--", "status"]);

    // Final Cleanup Check
    await new Promise(r => setTimeout(r, 1000));
    const stale = [];
    if (checkExists(SOCKET)) stale.push(SOCKET);
    if (checkExists(PID_FILE)) stale.push(PID_FILE);
    if (checkExists(SOCKET_SIMPLE)) stale.push(SOCKET_SIMPLE);
    
    if (stale.length > 0) Log(`Warning: Stale files remain: ${stale.join(", ")}`, "\x1b[33m");

    Log("Full Integration Test PASSED.", "\x1b[32m");
    process.exit(0);
}

runTest().catch(err => {
    console.error(err);
    process.exit(1);
});
