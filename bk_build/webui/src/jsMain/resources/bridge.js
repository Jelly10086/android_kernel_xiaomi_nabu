(function (global) {
  let callbackCounter = 0;

  global.bkExec = function (command) {
    return new Promise(function (resolve, reject) {
      const callbackName = "bk_exec_" + Date.now() + "_" + callbackCounter++;
      global[callbackName] = function (errno, stdout, stderr) {
        delete global[callbackName];
        resolve({ errno: errno, stdout: stdout, stderr: stderr });
      };
      try {
        ksu.exec(command, JSON.stringify({
          cwd: "/data/adb/modules/bk-control"
        }), callbackName);
      } catch (error) {
        delete global[callbackName];
        reject(error);
      }
    });
  };

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'";
  }

  global.bkExportLog = async function (command) {
    const result = await global.bkExec(command);
    if (result.errno !== 0) return result;

    const values = {};
    result.stdout.split(/\r?\n/).forEach(function (line) {
      const separator = line.indexOf("=");
      if (separator > 0) values[line.slice(0, separator)] = line.slice(separator + 1);
    });
    if (!values.name || !values.path) {
      return { errno: 5, stdout: "", stderr: "日志导出信息无效" };
    }

    const opened = await global.bkExec(
      "/data/adb/modules/bk-control/bkctl open-log " + shellQuote(values.name)
    );
    if (opened.errno !== 0) {
      await global.bkExec(
        "/data/adb/modules/bk-control/bkctl cleanup-log " + shellQuote(values.name)
      );
      return opened;
    }
    return opened;
  };

  global.bkReducedMotion = function () {
    return global.matchMedia("(prefers-reduced-motion: reduce)").matches;
  };

  global.bkThemeSeed = function () {
    const value = getComputedStyle(document.documentElement)
      .getPropertyValue("--primary")
      .trim();
    const match = /^#([0-9a-f]{6})/i.exec(value);
    return match ? ((0xff000000 | parseInt(match[1], 16)) | 0) : 0;
  };
})(globalThis);
